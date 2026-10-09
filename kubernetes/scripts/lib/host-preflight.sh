#!/usr/bin/env bash
# Shared source; vendored into each installer so folders remain independent.

export TZ=America/Sao_Paulo
export SYSTEM_TIMEZONE=America/Sao_Paulo
SYSTEM_NTP_SERVERS="${SYSTEM_NTP_SERVERS:-0.br.pool.ntp.org 1.br.pool.ntp.org 2.br.pool.ntp.org 3.br.pool.ntp.org}"
NTP_SYNC_TIMEOUT_SECONDS="${NTP_SYNC_TIMEOUT_SECONDS:-120}"
HOST_DISK_AUTO_EXPAND="${HOST_DISK_AUTO_EXPAND:-true}"
HOST_PREFLIGHT_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HOST_PREFLIGHT_CALL_MODE="${1:-}"

host_fail() { printf '[%s] ERRO de pré-instalação: %s\n' "$(date --iso-8601=seconds)" "$*" >&2; return 1; }
host_is_wsl() { grep -Eqi 'microsoft|wsl' /proc/sys/kernel/osrelease /proc/version 2>/dev/null; }

host_write_config() {
  local destination="$1" content="$2" directory temporary
  directory="$(dirname -- "${destination}")"
  install -d -m 0755 "${directory}"
  temporary="$(mktemp "${directory}/.installer-time.XXXXXX")"
  printf '%s\n' "${content}" >"${temporary}"
  if [[ -f "${destination}" ]] && cmp -s "${temporary}" "${destination}"; then
    rm -f -- "${temporary}"
    return 1  # No restart when configuration already matches.
  fi
  if [[ -f "${destination}" ]]; then
    install -d -m 0700 /var/lib/installer-host/backups
    cp -p -- "${destination}" "/var/lib/installer-host/backups/$(basename -- "${destination}").$(date '+%Y%m%d-%H%M%S%z').$$"
  fi
  chmod 0644 "${temporary}"
  mv -f -- "${temporary}" "${destination}"
}

host_clock() {
  local mode="$1" service config expected changed=false deadline server windows_path
  [[ "${NTP_SYNC_TIMEOUT_SECONDS}" =~ ^[1-9][0-9]{0,3}$ ]] \
    || { host_fail 'NTP_SYNC_TIMEOUT_SECONDS deve estar entre 1 e 9999.'; return 1; }
  for server in ${SYSTEM_NTP_SERVERS}; do
    [[ "${server}" =~ ^[a-zA-Z0-9][a-zA-Z0-9.:-]*$ ]] \
      || { host_fail 'SYSTEM_NTP_SERVERS contém um endereço inválido.'; return 1; }
  done
  [[ -n "${SYSTEM_NTP_SERVERS//[[:space:]]/}" ]] || { host_fail 'Informe servidores NTP.'; return 1; }
  [[ -f /usr/share/zoneinfo/America/Sao_Paulo ]] || { host_fail 'Fuso America/Sao_Paulo ausente na imagem.'; return 1; }
  if host_is_wsl; then
    if ! command -v powershell.exe >/dev/null || ! command -v wslpath >/dev/null; then
      host_fail 'WSL exige interoperabilidade Windows para validar Windows Time.'; return 1
    fi
    windows_path="$(wslpath -w "${HOST_PREFLIGHT_LIB_DIR}/windows-time.ps1")"
    powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "${windows_path}" \
      -Mode "${mode}" -NtpServers "${SYSTEM_NTP_SERVERS}" -TimeoutSeconds "${NTP_SYNC_TIMEOUT_SECONDS}" \
      || { host_fail 'Windows Time não foi validado; execute windows-time.ps1 -Mode apply em PowerShell Administrador.'; return 1; }
    if [[ "${mode}" == apply ]]; then
      ln -sfn /usr/share/zoneinfo/America/Sao_Paulo /etc/localtime
      printf 'America/Sao_Paulo\n' >/etc/timezone
    fi
    [[ "$(readlink -f /etc/localtime)" == /usr/share/zoneinfo/America/Sao_Paulo ]] \
      || { host_fail 'Fuso Linux do WSL ainda não foi configurado.'; return 1; }
    local windows_epoch linux_epoch drift
    windows_epoch="$(powershell.exe -NoProfile -NonInteractive -Command '[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()' | tr -d '\r[:space:]')"
    linux_epoch="$(date +%s)"
    [[ "${windows_epoch}" =~ ^[0-9]+$ ]] || { host_fail 'Horário Windows indisponível.'; return 1; }
    drift=$((linux_epoch - windows_epoch)); (( drift < 0 )) && drift=$((-drift))
    (( drift <= 5 )) || { host_fail 'Relógio WSL diverge do Windows; reinicie a distribuição WSL.'; return 1; }
    return 0
  fi
  command -v timedatectl >/dev/null && [[ "$(ps -p 1 -o comm= | tr -d '[:space:]')" == systemd ]] \
    || { host_fail 'A imagem precisa de systemd e timedatectl operacionais.'; return 1; }
  if [[ "${mode}" == apply ]]; then
    timedatectl set-timezone America/Sao_Paulo || return 1
  fi
  [[ "$(timedatectl show -p Timezone --value)" == America/Sao_Paulo ]] \
    || { host_fail 'Timezone do host não é America/Sao_Paulo.'; return 1; }
  if command -v chronyc >/dev/null && systemctl cat chrony.service >/dev/null 2>&1; then
    service=chrony.service
    config=/etc/chrony/chrony.conf
    expected=$'# BEGIN installer-host Brazil NTP\n'
    for server in ${SYSTEM_NTP_SERVERS}; do expected+="pool ${server} iburst prefer"$'\n'; done
    expected+='# END installer-host Brazil NTP'
    if [[ "${mode}" == apply ]]; then
      # Preserve non-source directives; disable other sources so Brazil is selected.
      local planned
      planned="$(python3 - "${config}" "${expected}" <<'PY'
from pathlib import Path
import re, sys
text = Path(sys.argv[1]).read_text()
text = re.sub(r'(?ms)^# BEGIN installer-host Brazil NTP\n.*?^# END installer-host Brazil NTP\n?', '', text)
text = re.sub(r'(?m)^(\s*(?:server|pool|peer|sourcedir)\s+.*)$', r'# installer-host disabled-source: \1', text)
print(text.rstrip() + '\n\n' + sys.argv[2])
PY
)" || return 1
      if host_write_config "${config}" "${planned}"; then changed=true; fi
      # Includes may carry administrator settings; preserve them, but do not
      # accept an included source outside the configured Brazil servers.
    fi
    grep -Fq '# BEGIN installer-host Brazil NTP' "${config}" \
      || { host_fail 'Chrony não está configurado para NTP brasileiro.'; return 1; }
    local configured
    configured="$(sed -n '/^# BEGIN installer-host Brazil NTP$/,/^# END installer-host Brazil NTP$/p' "${config}")"
    [[ "${configured}" == "${expected}" ]] || { host_fail 'Fontes Chrony diferem da configuração brasileira.'; return 1; }
    local effective effective_source
    effective="$(chronyd -p -f "${config}")" || { host_fail 'Configuração Chrony inválida.'; return 1; }
    while read -r effective_source; do
      [[ " ${SYSTEM_NTP_SERVERS} " == *" ${effective_source} "* ]] \
        || { host_fail 'Um include Chrony contém outra fonte NTP; revise o include e o backup antes de instalar.'; return 1; }
    done < <(printf '%s\n' "${effective}" | awk '$1 == "pool" || $1 == "server" || $1 == "peer" { print $2 }')
    if [[ "${mode}" == apply ]]; then
      systemctl enable --now "${service}" >/dev/null || return 1
      if [[ "${changed}" == true ]]; then systemctl restart "${service}" || return 1; fi
    fi
  elif systemctl cat systemd-timesyncd.service >/dev/null 2>&1; then
    service=systemd-timesyncd.service
    config=/etc/systemd/timesyncd.conf.d/90-installer-brazil.conf
    expected="[Time]"$'\n'"NTP=${SYSTEM_NTP_SERVERS}"$'\n'"FallbackNTP="
    if [[ "${mode}" == apply ]]; then
      if host_write_config "${config}" "${expected}"; then changed=true; fi
      timedatectl set-ntp true || return 1
      systemctl enable --now "${service}" >/dev/null || return 1
      if [[ "${changed}" == true ]]; then systemctl restart "${service}" || return 1; fi
    fi
    [[ -r "${config}" && "$(cat "${config}")" == "${expected}" ]] \
      || { host_fail 'systemd-timesyncd não está configurado para NTP brasileiro.'; return 1; }
  else
    host_fail 'Prepare chrony (Ubuntu 26.04) ou systemd-timesyncd na imagem antes de instalar.'; return 1
  fi
  systemctl is-active --quiet "${service}" || { host_fail 'Serviço NTP não está ativo.'; return 1; }
  deadline=$((SECONDS + NTP_SYNC_TIMEOUT_SECONDS))
  while :; do
    if [[ "$(timedatectl show -p NTPSynchronized --value)" == yes ]]; then
      if [[ "${service}" == chrony.service ]]; then
        # The kernel sync flag alone can still refer to an older source.
        local selected_chrony
        selected_chrony="$(chronyc -N sources | awk '$1 == "^*" { print $2; exit }')"
        if [[ -n "${selected_chrony}" && " ${SYSTEM_NTP_SERVERS} " == *" ${selected_chrony} "* ]] \
          && chronyc waitsync 1 0.5 0 1 >/dev/null 2>&1; then break; fi
      else
        local selected_name
        selected_name="$(timedatectl show-timesync -p ServerName --value 2>/dev/null || true)"
        for server in ${SYSTEM_NTP_SERVERS}; do [[ "${selected_name}" == "${server}" ]] && break 2; done
      fi
    fi
    if [[ "${mode}" != apply ]] || (( SECONDS >= deadline )); then
      host_fail 'NTP brasileiro sem sincronização confirmada. Confira DNS e UDP/123 antes de instalar.'; return 1
    fi
    sleep 2
  done
}

host_preflight() (
  set -Eeuo pipefail
  local mode=apply
  [[ "${1:-}" == --check || "${1:-}" == check ]] && mode=check
  [[ "${EUID}" -eq 0 ]] || { host_fail 'Execute o pré-instalação como root.'; exit 1; }
  if ! command -v python3 >/dev/null || ! command -v flock >/dev/null; then
    host_fail 'Python 3 e flock precisam estar presentes na imagem antes de instalar.'; exit 1
  fi
  # Reject unsupported hosts before changing their clock or block devices.
  # shellcheck source=/dev/null
  source /etc/os-release
  [[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" == 26.04 ]] || {
    [[ "${ALLOW_UNSUPPORTED_OS:-false}" == true ]] \
      || { host_fail 'Prepare uma imagem Ubuntu 26.04 LTS antes de instalar.'; exit 1; }
  }
  if host_is_wsl; then
    [[ "${HOST_REQUIRE_VM:-false}" != true ]] || { host_fail 'Esta variante exige VM externa; use kubernetes-wsl dentro do WSL.'; exit 1; }
  else
    [[ "${HOST_REQUIRE_WSL:-false}" != true ]] || { host_fail 'Esta variante exige Ubuntu no WSL 2.'; exit 1; }
  fi
  exec 8>/run/lock/installer-host-preflight.lock
  flock -w 30 8 || { host_fail 'Outra verificação/expansão de host está em andamento.'; exit 1; }
  host_clock "${mode}"
  local -a arguments=(--auto-expand "${HOST_DISK_AUTO_EXPAND}")
  [[ "${mode}" == check ]] && arguments+=(--check)
  python3 "${HOST_PREFLIGHT_LIB_DIR}/host-storage.py" "${arguments[@]}"
  printf '[%s] Host aprovado: America/Sao_Paulo, NTP sincronizado e disco raiz aproveitado.\n' "$(date --iso-8601=seconds)"
)

host_preflight_for_stage() {
  case "${0##*/}" in
    [0-9][0-9]-*.sh|prepare-offline-bundle.sh) host_preflight "${HOST_PREFLIGHT_CALL_MODE}" ;;
  esac
}
