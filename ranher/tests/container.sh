#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "${root}" <<'PY'
from pathlib import Path
import copy, json, os, subprocess, sys, tempfile
root=Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix='rancher-container-tests-') as directory:
    work=Path(directory);scripts=work/'scripts';(scripts/'lib').mkdir(parents=True)
    (scripts/'30-install-rancher.sh').write_text((root/'scripts/30-install-rancher.sh').read_text())
    (scripts/'lib/common.sh').write_text(r'''
set -Eeuo pipefail
umask 027
RANCHER_DATA_DIR="$WORK/rancher"
RANCHER_VERSION=v2.15.2
RANCHER_CONTAINER_NAME=rancher-server
RANCHER_BACKEND_PORT=8080
TLS_CA_FILE="${TEST_CA-$WORK/ca.crt}"
require_root() { :; }
validate_config() { :; }
check_requested() { [[ "${1:-}" == --check ]]; }
log() { printf '%s\n' "$*"; }
die() { printf '%s\n' "$*" >&2; exit 1; }
docker() {
  printf '%s\n' "$*" >> "$WORK/trace"
  if [[ "$1" == container ]]; then [[ "${TEST_EXISTS:-true}" == true ]]; return; fi
  if [[ "$1" == inspect && "${2:-}" == -f ]]; then printf '%s\n' "${TEST_RUNNING:-true}"; return; fi
  if [[ "$1" == inspect ]]; then cat "$WORK/inspect.json"; return; fi
}
''')
    current={'Config':{'Image':'rancher/rancher:v2.15.2','Cmd':[],'Env':['SECRET_SENTINEL_MUST_NOT_LEAK']},
             'HostConfig':{'Privileged':True,'RestartPolicy':{'Name':'unless-stopped'},'PortBindings':{'80/tcp':[{'HostIp':'127.0.0.1','HostPort':'8080'}]}},
             'Mounts':[{'Destination':'/var/lib/rancher','Source':str(work/'rancher/data'),'RW':True},
                       {'Destination':'/etc/rancher/ssl/cacerts.pem','Source':str(work/'ca.crt'),'RW':False}]}
    count=0
    def run(ok,document=None,check=True,**extra):
        global count
        (work/'inspect.json').write_text(json.dumps([document or current]));(work/'trace').write_text('')
        result=subprocess.run(['bash',str(scripts/'30-install-rancher.sh')]+(['--check'] if check else []),env=dict(os.environ,WORK=str(work),**extra),text=True,capture_output=True)
        assert (result.returncode==0)==ok,(extra,result.stdout,result.stderr)
        assert 'SECRET_SENTINEL_MUST_NOT_LEAK' not in result.stdout+result.stderr
        count+=1;return (work/'trace').read_text()
    trace=run(True);assert 'start ' not in trace and 'run ' not in trace and not (work/'rancher').exists()
    run(False,TEST_RUNNING='false')
    trace=run(True,check=False);assert 'start rancher-server' in trace and 'run ' not in trace
    for field in ['image','data','privileged','public-port','other-port','ca-rw']:
        broken=copy.deepcopy(current)
        if field=='image':broken['Config']['Image']='rancher/rancher:v2.15.3'
        elif field=='data':broken['Mounts'][0]['Source']='/other/data'
        elif field=='privileged':broken['HostConfig']['Privileged']=False
        elif field=='public-port':broken['HostConfig']['PortBindings']['80/tcp'][0]['HostIp']='0.0.0.0'
        elif field=='other-port':broken['HostConfig']['PortBindings']['443/tcp']=[{'HostIp':'0.0.0.0','HostPort':'443'}]
        elif field=='ca-rw':broken['Mounts'][1]['RW']=True
        trace=run(False,broken);assert 'start ' not in trace and 'run ' not in trace and 'rm ' not in trace
    trace=run(False,TEST_EXISTS='false');assert 'pull ' not in trace and 'run ' not in trace
    trace=run(True,check=False,TEST_EXISTS='false');assert '127.0.0.1:8080:80' in trace and 'CATTLE_AGENT_TLS_MODE=strict' in trace and 'America/Sao_Paulo' in trace
    trace=run(True,check=False,TEST_EXISTS='false',TEST_CA='');assert '--no-cacerts' in trace and 'CATTLE_AGENT_TLS_MODE=system-store' in trace
    print('PASS:',count,'container scenarios; no replacement, loopback, CA, secret-safe diagnostics and read-only checks')
PY
