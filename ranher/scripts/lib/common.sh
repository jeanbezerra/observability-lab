#!/usr/bin/env bash
# shellcheck disable=SC2034
set -Eeuo pipefail
umask 027
PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ -n "${RANCHER_CONFIG_FILE:-}" ]]; then
  [[ -r "${RANCHER_CONFIG_FILE}" ]] || { printf 'ERRO: configuração Rancher ausente.\n' >&2; exit 1; }
  # shellcheck source=/dev/null
  source "${RANCHER_CONFIG_FILE}"
elif [[ -r "${PROJECT_DIR}/rancher.env" ]]; then
  # shellcheck source=/dev/null
  source "${PROJECT_DIR}/rancher.env"
fi
# shellcheck source=host-preflight.sh
source "${PROJECT_DIR}/scripts/lib/host-preflight.sh"
HOST_REQUIRE_VM=true
RANCHER_FQDN="${RANCHER_FQDN:-}"
SERVER_IP="${SERVER_IP:-}"
RANCHER_VERSION="${RANCHER_VERSION:-v2.15.2}"
RANCHER_DATA_DIR="${RANCHER_DATA_DIR:-/opt/rancher}"
RANCHER_CONTAINER_NAME="${RANCHER_CONTAINER_NAME:-rancher-server}"
RANCHER_BACKEND_PORT="${RANCHER_BACKEND_PORT:-8080}"
TLS_MODE="${TLS_MODE:-private-ca}"
TLS_CERT_FILE="${TLS_CERT_FILE:-}"
TLS_KEY_FILE="${TLS_KEY_FILE:-}"
TLS_CA_FILE="${TLS_CA_FILE:-}"
TLS_CERT_DAYS="${TLS_CERT_DAYS:-397}"
ENABLE_UFW="${ENABLE_UFW:-false}"
SSH_PORT="${SSH_PORT:-22}"
RANCHER_START_TIMEOUT_SECONDS="${RANCHER_START_TIMEOUT_SECONDS:-600}"
PKI_DIR="${RANCHER_DATA_DIR}/pki"
log() { printf '[%s] %s\n' "$(date --iso-8601=seconds)" "$*"; }
die() { log "ERRO: $*" >&2; exit 1; }
require_root() {
  [[ "${EUID}" -eq 0 ]] || die 'Execute como root (sudo).'
  [[ "${HOST_PREFLIGHT_CALL_MODE}" == '' || "${HOST_PREFLIGHT_CALL_MODE}" == --check ]] || die 'A etapa aceita somente --check ou nenhum argumento.'
  host_preflight_for_stage
}
check_requested() { [[ "${1:-}" == --check ]]; }
validate_config() {
  python3 - "${RANCHER_FQDN}" "${SERVER_IP}" <<'PY'
import ipaddress, re, socket, subprocess, json, sys
host, raw_ip = sys.argv[1:]
if len(host) > 253 or '.' not in host or any(not re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', s) for s in host.split('.')):
    raise SystemExit('RANCHER_FQDN deve ser um hostname DNS válido, sem URL/caminho.')
address = str(ipaddress.IPv4Address(raw_ip))
local = {a['local'] for i in json.loads(subprocess.check_output(['ip', '-j', '-4', 'address'])) for a in i['addr_info']}
if address not in local: raise SystemExit('SERVER_IP precisa estar atribuído à máquina Rancher.')
answers = {a[4][0] for a in socket.getaddrinfo(host, 443, type=socket.SOCK_STREAM)}
if address not in answers: raise SystemExit('O DNS Rancher precisa apontar para SERVER_IP antes de instalar.')
PY
  [[ "${RANCHER_VERSION}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'RANCHER_VERSION exige vX.Y.Z estável.'
  [[ "${RANCHER_DATA_DIR}" =~ ^/[a-zA-Z0-9_./-]+$ && "${RANCHER_DATA_DIR}" != / && "${RANCHER_DATA_DIR}" != *..* ]] \
    || die 'RANCHER_DATA_DIR exige caminho absoluto dedicado sem espaços ou ..'
  [[ "${RANCHER_CONTAINER_NAME}" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || die 'Nome de container inválido.'
  [[ "${RANCHER_BACKEND_PORT}" =~ ^[1-9][0-9]{0,4}$ ]] || die 'Porta backend inválida.'
  (( RANCHER_BACKEND_PORT >= 1024 && RANCHER_BACKEND_PORT <= 65535 )) || die 'Porta backend inválida.'
  [[ "${TLS_CERT_DAYS}" =~ ^[1-9][0-9]{0,2}$ ]] || die 'TLS_CERT_DAYS deve estar entre 1 e 397.'
  (( TLS_CERT_DAYS <= 397 )) || die 'TLS_CERT_DAYS deve estar entre 1 e 397.'
  [[ "${RANCHER_START_TIMEOUT_SECONDS}" =~ ^[1-9][0-9]{0,3}$ ]] || die 'Timeout Rancher inválido.'
  [[ "${SSH_PORT}" =~ ^[1-9][0-9]{0,4}$ ]] || die 'SSH_PORT inválida.'
  (( SSH_PORT <= 65535 )) || die 'SSH_PORT inválida.'
  [[ "${ENABLE_UFW}" == true || "${ENABLE_UFW}" == false ]] || die 'ENABLE_UFW exige true/false.'
  [[ "${TLS_MODE}" == private-ca || "${TLS_MODE}" == provided ]] || die 'TLS_MODE exige private-ca/provided.'
  if [[ "${TLS_MODE}" == provided ]]; then
    for path in "${TLS_CERT_FILE}" "${TLS_KEY_FILE}"; do
      [[ "${path}" =~ ^/[a-zA-Z0-9_./-]+$ && -f "${path}" ]] || die 'TLS provided exige arquivos PEM em caminhos absolutos seguros.'
    done
    [[ -z "${TLS_CA_FILE}" || ( "${TLS_CA_FILE}" =~ ^/[a-zA-Z0-9_./-]+$ && -f "${TLS_CA_FILE}" ) ]] \
      || die 'TLS_CA_FILE deve estar vazio ou apontar para uma cadeia PEM válida.'
  fi
}
