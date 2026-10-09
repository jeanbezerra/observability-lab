#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
[[ $# -le 1 ]] || { printf 'Uso: bash %s [cluster.env]\n' "$0" >&2; exit 2; }
config_file="$(realpath -m -- "${1:-${ROOT_DIR}/cluster.env}")"
created=false
if [[ ! -e "${config_file}" ]]; then
  install -m 0600 "${ROOT_DIR}/.env.example" "${config_file}"
  created=true
fi
export K8S_CONFIG_FILE="${config_file}"
# shellcheck source=scripts/lib/common.sh
source "${ROOT_DIR}/scripts/lib/common.sh"

prompt_value() {
  local label="$1" suggestion="${2:-}" answer
  [[ -t 0 ]] || die "configuração incompleta: preencha NODE_IP e RANCHER_URL em ${config_file} para execução não interativa."
  printf '%s%s: ' "${label}" "${suggestion:+ [${suggestion}]}" >&2
  IFS= read -r answer || die "entrada encerrada antes de concluir a configuração."
  printf '%s' "${answer:-${suggestion}}"
}

changed=false
if [[ -z "${NODE_IP}" ]]; then
  suggested_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}' || true)"
  NODE_IP="$(prompt_value 'IPv4 da VM acessível pela rede HML' "${suggested_ip}")"
  changed=true
fi
if ! valid_ipv4 "${NODE_IP}" || ! node_ip_is_local_physical "${NODE_IP}"; then
  die "NODE_IP=${NODE_IP} precisa ser um IPv4 presente em uma interface da VM (sem loopback)."
fi

if [[ -z "${RANCHER_URL}" ]]; then
  RANCHER_URL="$(prompt_value 'URL HTTPS do Rancher na máquina externa (ex.: https://rancher.empresa.local)')"
  changed=true
fi
valid_https_url "${RANCHER_URL}" || die "RANCHER_URL precisa ser https://HOST[:PORTA], sem credenciais ou caminhos."
RANCHER_URL="${RANCHER_URL%/}"

if [[ -z "${HEADLAMP_HOST}" ]]; then
  HEADLAMP_HOST="${NODE_IP}"
fi
valid_endpoint_host "${HEADLAMP_HOST}" || die "HEADLAMP_HOST precisa ser DNS ou IPv4, sem esquema ou porta."

if is_true "${changed}"; then
  {
    printf '\n# Parâmetros coletados durante a instalação.\n'
    printf 'NODE_IP=%q\nRANCHER_URL=%q\nHEADLAMP_HOST=%q\n' "${NODE_IP}" "${RANCHER_URL}" "${HEADLAMP_HOST}"
  } >>"${config_file}"
fi
chmod 0600 "${config_file}"
if is_true "${created}" && [[ -n "${SUDO_USER:-}" ]]; then
  chown "${SUDO_USER}:$(id -gn "${SUDO_USER}")" "${config_file}"
fi
printf 'Configuração HML: %s\n' "${config_file}"
