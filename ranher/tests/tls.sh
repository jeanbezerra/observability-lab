#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "${root}" <<'PY'
from pathlib import Path
import os, shutil, subprocess, sys, tempfile

root=Path(sys.argv[1]);source=(root/'scripts/20-configure-tls.sh').read_text()
with tempfile.TemporaryDirectory(prefix='rancher-tls-tests-') as directory:
    work=Path(directory);scripts=work/'scripts';lib=scripts/'lib';lib.mkdir(parents=True)
    pki=work/'pki';pki.mkdir();config=work/'rancher.env';config.write_text('')
    source=source.replace('/var/lib/rancher-bootstrap/backups',str(work/'backups'))
    (scripts/'20-configure-tls.sh').write_text(source)
    (lib/'common.sh').write_text(r'''
set -Eeuo pipefail
umask 027
export TZ=America/Sao_Paulo
PKI_DIR="$TEST_PKI"
RANCHER_FQDN="${TEST_HOST:-rancher.hml.example}"
SERVER_IP=192.0.2.10
TLS_MODE="${TEST_MODE:-private-ca}"
TLS_CERT_DAYS=397
TLS_CA_FILE="${TEST_CA:-}"
TLS_CERT_FILE="${TEST_CERT:-}"
TLS_KEY_FILE="${TEST_KEY:-}"
RANCHER_CONFIG_FILE="$TEST_CONFIG"
require_root() { :; }
validate_config() { :; }
check_requested() { [[ "${1:-}" == --check ]]; }
log() { printf '%s\n' "$*"; }
die() { printf '%s\n' "$*" >&2; exit 1; }
chown() { :; }
install() {
  local -a args=()
  while (( $# )); do
    case "$1" in -o|-g) shift 2;; *) args+=("$1");shift;; esac
  done
  command install "${args[@]}"
}
''')
    def run(check=False,**extra):
        env=dict(os.environ,TEST_PKI=str(pki),TEST_CONFIG=str(config),**extra)
        return subprocess.run(['bash',str(scripts/'20-configure-tls.sh')]+(['--check'] if check else []),env=env,text=True,capture_output=True)
    r=run();assert r.returncode==0,(r.stdout,r.stderr)
    ca=(pki/'root-ca.crt').read_bytes();key=(pki/'server.key').read_bytes();leaf=(pki/'server.crt').read_bytes()
    r=run(TEST_CA=str(pki/'root-ca.crt'),TEST_CERT=str(pki/'server.crt'),TEST_KEY=str(pki/'server.key'));assert r.returncode==0,(r.stdout,r.stderr)
    assert ca==(pki/'root-ca.crt').read_bytes() and key==(pki/'server.key').read_bytes() and leaf==(pki/'server.crt').read_bytes()
    before_config=config.read_bytes()
    r=run(check=True,TEST_CA=str(pki/'root-ca.crt'),TEST_CERT=str(pki/'server.crt'),TEST_KEY=str(pki/'server.key'));assert r.returncode==0,(r.stdout,r.stderr)
    assert before_config==config.read_bytes() and leaf==(pki/'server.crt').read_bytes()
    r=run(check=True,TEST_HOST='new.hml.example',TEST_CA=str(pki/'root-ca.crt'),TEST_CERT=str(pki/'server.crt'),TEST_KEY=str(pki/'server.key'))
    assert r.returncode!=0 and leaf==(pki/'server.crt').read_bytes(),'check renewed certificate'
    r=run(TEST_HOST='new.hml.example');assert r.returncode==0,(r.stdout,r.stderr)
    assert ca==(pki/'root-ca.crt').read_bytes() and key==(pki/'server.key').read_bytes()
    assert leaf!=(pki/'server.crt').read_bytes(),'Changed hostname must renew leaf certificate'
    r=run(TEST_HOST='wrong.hml.example',TEST_MODE='provided',TEST_CA=str(pki/'root-ca.crt'),TEST_CERT=str(pki/'server.crt'),TEST_KEY=str(pki/'server.key'))
    assert r.returncode!=0,'Provided certificate with wrong hostname accepted'
    (pki/'server.key').unlink();r=run();assert r.returncode!=0 and (pki/'root-ca.crt').read_bytes()==ca,'Incomplete PKI was overwritten'
    print('PASS: 7 TLS scenarios; creation, reuse, read-only check, hostname renewal, hostname rejection and incomplete PKI preservation')
PY
