#!/usr/bin/env bash
set -Eeuo pipefail
umask 027
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
[[ "${EUID}" -eq 0 && $# -le 1 ]] || { printf 'Uso: sudo bash %s [rancher.env]\n' "$0" >&2; exit 1; }
RANCHER_CONFIG_FILE="$(realpath -m -- "${1:-${ROOT_DIR}/rancher.env}")"
export RANCHER_CONFIG_FILE
if [[ ! -f "${RANCHER_CONFIG_FILE}" ]]; then install -m 0600 "${ROOT_DIR}/.env.example" "${RANCHER_CONFIG_FILE}"; fi
# shellcheck source=scripts/lib/common.sh
source "${ROOT_DIR}/scripts/lib/common.sh"
if [[ -z "${RANCHER_FQDN}" || -z "${SERVER_IP}" ]]; then
  [[ -t 0 ]] || die 'Configure RANCHER_FQDN e SERVER_IP no arquivo local antes da execução não interativa.'
  if [[ -z "${RANCHER_FQDN}" ]]; then read -r -p 'Hostname DNS do Rancher (sem https://): ' RANCHER_FQDN; fi
  if [[ -z "${SERVER_IP}" ]]; then read -r -p 'IPv4 da máquina Rancher: ' SERVER_IP; fi
  # Append safely shell-escaped values, preserving optional local settings.
  printf '\nRANCHER_FQDN=%q\nSERVER_IP=%q\n' "${RANCHER_FQDN}" "${SERVER_IP}" >>"${RANCHER_CONFIG_FILE}"
fi
chmod 0600 "${RANCHER_CONFIG_FILE}"
export RANCHER_FQDN SERVER_IP
exec 9>/run/lock/rancher-bootstrap.lock
flock -n 9 || die 'Outro instalador Rancher está em execução.'
host_preflight
validate_config
install -d -m 0700 /var/log/rancher-bootstrap
logfile="/var/log/rancher-bootstrap/deploy-$(date '+%Y%m%d-%H%M%S%z')-$$.log"
touch "${logfile}"; chmod 0600 "${logfile}"
exec > >(tee -a "${logfile}") 2>&1
trap 'log "Falha na linha ${LINENO}; log=${logfile}. Corrija e execute novamente; dados existentes são preservados."' ERR
for stage in 00-preflight 10-install-docker 20-configure-tls 30-install-rancher 40-configure-nginx 50-configure-firewall 90-verify; do
  log "Etapa ${stage}"
  stage_path="${ROOT_DIR}/scripts/${stage}.sh"
  if [[ "${stage}" == 00-preflight || "${stage}" == 90-verify ]]; then
    bash "${stage_path}"
  elif bash "${stage_path}" --check; then
    log "${stage}: estado já conforme."
  else
    bash "${stage_path}"
    bash "${stage_path}" --check
  fi
done
log "Rancher instalado e validado: https://${RANCHER_FQDN}; log=${logfile}"
if [[ -n "${TLS_CA_FILE}" ]]; then log "CA pública para clientes/agentes: ${TLS_CA_FILE}"; fi
