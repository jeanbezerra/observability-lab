#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "${root}" <<'PY'
from pathlib import Path
import json, os, subprocess, sys, tempfile
root=Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix='rancher-verify-tests-') as directory:
    work=Path(directory);scripts=work/'scripts';(scripts/'lib').mkdir(parents=True)
    subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-keyout',str(work/'key'),
                    '-out',str(work/'ca.crt'),'-days','1','-subj','/CN=Ephemeral Test CA'],
                   check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    # Keep the certificate public; no real credential or network is used.
    (scripts/'90-verify.sh').write_text((root/'scripts/90-verify.sh').read_text())
    (scripts/'lib/common.sh').write_text(r'''
set -Eeuo pipefail
RANCHER_FQDN=rancher.hml.example
RANCHER_VERSION=v2.15.2
RANCHER_CONTAINER_NAME=rancher-server
RANCHER_START_TIMEOUT_SECONDS=0
TLS_CA_FILE="${TEST_CA-$WORK/ca.crt}"
require_root() { :; }
validate_config() { :; }
host_preflight() { [[ "$1" == --check ]]; }
systemctl() { return 0; }
nginx() { return 0; }
log() { printf '%s\n' "$*"; }
die() { printf '%s\n' "$*" >&2; exit 1; }
curl() {
  [[ "$1" == --disable ]] || return 90
  local url="${@: -1}" ca=false item
  for item in "$@"; do
    case "$item" in --cacert) ca=true;; --insecure|-k|--location|-L) return 91;; esac
  done
  [[ -z "$TLS_CA_FILE" || "$ca" == true ]] || return 92
  printf '%s\n' "$url" >> "$WORK/trace"
  case "$url" in
    */ping) printf '%s\n' "${TEST_PING:-pong}" ;;
    */rancherversion) printf '{"Version":"%s"}\n' "${TEST_VERSION:-v2.15.2}" ;;
    */v3/settings/cacerts) python3 -c 'import json,pathlib,sys;print(json.dumps({"value":pathlib.Path(sys.argv[1]).read_text() if sys.argv[2]=="same" else "INVALID_CA"}))' "$WORK/ca.crt" "${TEST_CA_RESULT:-same}" ;;
    */agent-tls-mode) return 93;; # Authentication is required for this setting.
    *) return 94;;
  esac
}
docker() {
  [[ "$*" == 'exec rancher-server kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml get settings.management.cattle.io agent-tls-mode -o json' ]] || return 95
  printf '{"default":"%s","value":""}\n' "${TEST_AGENT_MODE:-strict}"
}
''')
    count=0
    def run(ok,**extra):
        global count
        (work/'trace').write_text('')
        result=subprocess.run(['bash',str(scripts/'90-verify.sh')],env=dict(os.environ,WORK=str(work),**extra),text=True,capture_output=True)
        assert (result.returncode==0)==ok,(extra,result.stdout,result.stderr)
        assert '/agent-tls-mode' not in (work/'trace').read_text()
        count+=1
    run(True)
    run(False,TEST_PING='not-pong')
    run(False,TEST_VERSION='v2.15.3')
    run(False,TEST_CA_RESULT='other')
    run(False,TEST_AGENT_MODE='system-store')
    run(True,TEST_CA='',TEST_AGENT_MODE='system-store')
    print('PASS:',count,'verification scenarios; strict TLS flags, pong, version, CA and authenticated local agent mode')
PY
