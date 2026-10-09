#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 - "${root}" <<'PY'
from pathlib import Path
import os, subprocess, sys, tempfile

root=Path(sys.argv[1]); source=(root/'installer-common/host-preflight.sh').read_text()
with tempfile.TemporaryDirectory(prefix='installer-clock-tests-') as directory:
    work=Path(directory); config=work/'chrony.conf'; timesync=work/'timesync/90-installer-brazil.conf'; trace=work/'trace'
    source=source.replace('/etc/chrony/chrony.conf',str(config)).replace('/etc/systemd/timesyncd.conf.d/90-installer-brazil.conf',str(timesync)).replace('/var/lib/installer-host/backups',str(work/'backups'))
    (work/'host.sh').write_text(source)
    harness=r'''
set -Eeuo pipefail
source "$WORK/host.sh"
host_is_wsl() { return 1; }
ps() { printf 'systemd\n'; }
timedatectl() {
  case "$1:$2" in
    show:-p)
      case "$3" in
        Timezone) printf '%s\n' "${MOCK_ZONE:-America/Sao_Paulo}" ;;
        NTPSynchronized) printf '%s\n' "${MOCK_SYNC:-yes}" ;;
      esac ;;
    show-timesync:-p) printf '%s\n' "${MOCK_SERVER:-0.br.pool.ntp.org}" ;;
    *) printf '%s\n' "timedatectl $*" >> "$WORK/trace" ;;
  esac
}
systemctl() {
  if [[ "$1" == cat ]]; then
    [[ "$2" == "${MOCK_SERVICE:-chrony.service}" ]]; return
  fi
  if [[ "$1" == is-active ]]; then return 0; fi
  printf '%s\n' "systemctl $*" >> "$WORK/trace"
}
chronyc() {
  if [[ "$1" == waitsync ]]; then [[ "${MOCK_CORRECTION:-ok}" == ok ]]; return; fi
  printf '^* %s 1 6 377 1 -5us\n' "${MOCK_CHRONY_SOURCE:-0.br.pool.ntp.org}"
}
chronyd() {
  cat "$WORK/chrony.conf"
  [[ "${MOCK_BAD_INCLUDE:-false}" != true ]] || printf 'server other.example iburst\n'
}
host_clock "${MOCK_MODE:-apply}"
[[ "${MOCK_REPEAT:-false}" != true ]] || host_clock apply
'''
    (work/'runner.sh').write_text(harness)
    def run(**extra):
        env=dict(os.environ,WORK=str(work),**extra)
        result=subprocess.run(['bash',str(work/'runner.sh')],env=env,text=True,capture_output=True)
        return result
    count=0
    def expect(ok,**extra):
        global count
        result=run(**extra)
        assert (result.returncode==0)==ok,(extra,result.stdout,result.stderr)
        count+=1
        return result
    config.write_text('pool original.example iburst\nsourcedir /run/chrony-dhcp\nconfdir /etc/chrony/conf.d\nmakestep 1.0 3\nrtcsync\n')
    expect(True,MOCK_REPEAT='true')
    text=config.read_text()
    assert '# installer-host disabled-source: pool original.example' in text
    assert '# installer-host disabled-source: sourcedir /run/chrony-dhcp' in text
    assert 'confdir /etc/chrony/conf.d' in text and 'makestep 1.0 3' in text and 'rtcsync' in text
    assert trace.read_text().count('systemctl restart chrony.service')==1
    assert list((work/'backups').iterdir())
    before=config.read_bytes();trace.unlink()
    expect(True,MOCK_MODE='check')
    assert config.read_bytes()==before and not trace.exists(), 'check changed services/config'
    expect(False,MOCK_MODE='check',MOCK_ZONE='UTC')
    expect(False,MOCK_MODE='check',MOCK_SYNC='no')
    expect(False,MOCK_MODE='check',MOCK_CHRONY_SOURCE='ntp.ubuntu.com')
    expect(False,MOCK_MODE='check',MOCK_CORRECTION='large')
    expect(False,MOCK_MODE='check',MOCK_BAD_INCLUDE='true')
    expect(False,MOCK_MODE='check',SYSTEM_NTP_SERVERS='$(malicious)')
    expect(True,MOCK_SERVICE='systemd-timesyncd.service')
    before=timesync.read_bytes();trace.unlink()
    expect(True,MOCK_SERVICE='systemd-timesyncd.service',MOCK_MODE='check')
    assert timesync.read_bytes()==before and not trace.exists()
    expect(False,MOCK_SERVICE='systemd-timesyncd.service',MOCK_MODE='check',MOCK_SERVER='ntp.other.example')
    expect(False,NTP_SYNC_TIMEOUT_SECONDS='0')
    print('PASS:',count,'clock scenarios; configuration, real synchronization, read-only checks and idempotence')
PY
