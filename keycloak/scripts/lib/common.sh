#!/usr/bin/env bash
# shellcheck disable=SC2034 # Variáveis deste arquivo são consumidas pelos scripts que o importam.

set -Eeuo pipefail
umask 027

LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd -- "${LIB_DIR}/.." && pwd)"
PROJECT_DIR="$(cd -- "${SCRIPTS_DIR}/.." && pwd)"

if [[ -n "${KEYCLOAK_CONFIG_FILE:-}" ]]; then
  [[ -r "${KEYCLOAK_CONFIG_FILE}" ]] || {
    printf 'ERRO: arquivo de configuração não pode ser lido: %s\n' "${KEYCLOAK_CONFIG_FILE}" >&2
    exit 1
  }
  # O arquivo é configuração shell e deve ser controlado pelo administrador.
  # shellcheck source=/dev/null
  source "${KEYCLOAK_CONFIG_FILE}"
elif [[ -r "${PROJECT_DIR}/keycloak.env" ]]; then
  # shellcheck source=/dev/null
  source "${PROJECT_DIR}/keycloak.env"
fi

if [[ -n "${KEYCLOAK_SECRETS_FILE:-}" ]]; then
  [[ -r "${KEYCLOAK_SECRETS_FILE}" ]] || {
    printf 'ERRO: arquivo de segredos não pode ser lido: %s\n' "${KEYCLOAK_SECRETS_FILE}" >&2
    exit 1
  }
  # shellcheck source=/dev/null
  source "${KEYCLOAK_SECRETS_FILE}"
elif [[ -r "${PROJECT_DIR}/secrets.env" ]]; then
  KEYCLOAK_SECRETS_FILE="${PROJECT_DIR}/secrets.env"
  # shellcheck source=/dev/null
  source "${KEYCLOAK_SECRETS_FILE}"
fi

KEYCLOAK_VERSION="${KEYCLOAK_VERSION:-26.7.1}"
KEYCLOAK_SHA256="${KEYCLOAK_SHA256:-d3bb3da0e4bf574db0c857f92b272da90575dc97aa26c41329c9d4399200974c}"
KEYCLOAK_DOWNLOAD_URL="${KEYCLOAK_DOWNLOAD_URL:-https://github.com/keycloak/keycloak/releases/download/${KEYCLOAK_VERSION}/keycloak-${KEYCLOAK_VERSION}.tar.gz}"
JAVA_PACKAGE="${JAVA_PACKAGE:-openjdk-25-jre-headless}"
POSTGRESQL_MAJOR="${POSTGRESQL_MAJOR:-18}"
KEYCLOAK_HOSTNAME="${KEYCLOAK_HOSTNAME:-}"
KEYCLOAK_SERVER_IP="${KEYCLOAK_SERVER_IP:-}"
KEYCLOAK_HTTPS_PORT="${KEYCLOAK_HTTPS_PORT:-8443}"
if [[ "${KEYCLOAK_HTTPS_PORT}" == "443" ]]; then
  KEYCLOAK_EXTERNAL_URL="${KEYCLOAK_EXTERNAL_URL:-https://${KEYCLOAK_HOSTNAME}}"
else
  KEYCLOAK_EXTERNAL_URL="${KEYCLOAK_EXTERNAL_URL:-https://${KEYCLOAK_HOSTNAME}:${KEYCLOAK_HTTPS_PORT}}"
fi
TLS_MODE="${TLS_MODE:-self-signed}"
TLS_CERT_FILE="${TLS_CERT_FILE:-}"
TLS_KEY_FILE="${TLS_KEY_FILE:-}"
TLS_CA_FILE="${TLS_CA_FILE:-}"
TLS_CERT_DAYS="${TLS_CERT_DAYS:-825}"
KEYCLOAK_DB_NAME="${KEYCLOAK_DB_NAME:-keycloak}"
KEYCLOAK_DB_USER="${KEYCLOAK_DB_USER:-keycloak}"
KEYCLOAK_DB_POOL_INITIAL_SIZE="${KEYCLOAK_DB_POOL_INITIAL_SIZE:-5}"
KEYCLOAK_DB_POOL_MIN_SIZE="${KEYCLOAK_DB_POOL_MIN_SIZE:-5}"
KEYCLOAK_DB_POOL_MAX_SIZE="${KEYCLOAK_DB_POOL_MAX_SIZE:-20}"
KEYCLOAK_JAVA_HEAP="${KEYCLOAK_JAVA_HEAP:--Xms512m -Xmx1536m}"
KEYCLOAK_ADMIN_USER="${KEYCLOAK_ADMIN_USER:-idp-admin}"
KEYCLOAK_BOOTSTRAP_USER="${KEYCLOAK_BOOTSTRAP_USER:-bootstrap-admin}"
OIDC_REALM="${OIDC_REALM:-platform}"
OIDC_REALM_DISPLAY_NAME="${OIDC_REALM_DISPLAY_NAME:-Plataforma}"
OIDC_CLIENT_ID="${OIDC_CLIENT_ID:-kubernetes}"
OIDC_VIEWER_GROUP="${OIDC_VIEWER_GROUP:-k8s-viewers}"
OIDC_ADMIN_GROUP="${OIDC_ADMIN_GROUP:-k8s-admins}"
HEADLAMP_EXTERNAL_URL="${HEADLAMP_EXTERNAL_URL:-}"
KUBECTL_OIDC_REDIRECT_URI="${KUBECTL_OIDC_REDIRECT_URI:-http://localhost:8000}"
KEYCLOAK_ALLOWED_CIDRS="${KEYCLOAK_ALLOWED_CIDRS:-0.0.0.0/0}"
SSH_ALLOWED_CIDRS="${SSH_ALLOWED_CIDRS:-0.0.0.0/0}"
SSH_PORT="${SSH_PORT:-22}"
ENABLE_UFW="${ENABLE_UFW:-true}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"
BACKUP_ON_CALENDAR="${BACKUP_ON_CALENDAR:-*-*-* 02:15:00}"
ALLOW_UNSUPPORTED_OS="${ALLOW_UNSUPPORTED_OS:-false}"

KEYCLOAK_DB_PASSWORD="${KEYCLOAK_DB_PASSWORD:-}"
KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-}"
KEYCLOAK_BOOTSTRAP_PASSWORD="${KEYCLOAK_BOOTSTRAP_PASSWORD:-}"
OIDC_CLIENT_SECRET="${OIDC_CLIENT_SECRET:-}"

KEYCLOAK_USER="keycloak"
KEYCLOAK_GROUP="keycloak"
KEYCLOAK_HOME="/opt/keycloak"
KEYCLOAK_VERSION_HOME="/opt/keycloak-${KEYCLOAK_VERSION}"
KEYCLOAK_CONFIG_DIR="/etc/keycloak"
KEYCLOAK_TLS_DIR="/etc/keycloak/tls"
KEYCLOAK_DATA_DIR="/var/lib/keycloak"
KEYCLOAK_BACKUP_DIR="/var/backups/keycloak"
KEYCLOAK_STATE_DIR="/var/lib/keycloak-bootstrap"
KEYCLOAK_DB_URL="jdbc:postgresql://127.0.0.1:5432/${KEYCLOAK_DB_NAME}"
OIDC_ISSUER_URL="${KEYCLOAK_EXTERNAL_URL}/realms/${OIDC_REALM}"
HEADLAMP_OIDC_CALLBACK_URL="${HEADLAMP_EXTERNAL_URL%/}/oidc-callback"

readonly LIB_DIR SCRIPTS_DIR PROJECT_DIR KEYCLOAK_USER KEYCLOAK_GROUP

log() {
  printf '\033[1;34m[%s]\033[0m %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

warn() {
  printf '\033[1;33m[AVISO]\033[0m %s\n' "$*" >&2
}

die() {
  printf '\033[1;31m[ERRO]\033[0m %s\n' "$*" >&2
  exit 1
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "execute este script como root (use sudo)."
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "comando obrigatório não encontrado: $1"
}

check_requested() {
  [[ "${1:-}" == "--check" ]]
}

check_pending() {
  printf '\033[1;33m[PENDENTE]\033[0m %s\n' "$*" >&2
}

package_is_installed() {
  local package_status
  package_status="$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null || true)"
  [[ "${package_status}" == *" ok installed" ]]
}

is_true() {
  case "${1,,}" in
    1|true|yes|sim|on) return 0 ;;
    *) return 1 ;;
  esac
}

valid_ipv4() {
  local address="$1" IFS='.' octet
  local octets=()
  read -r -a octets <<<"${address}"
  [[ "${#octets[@]}" -eq 4 ]] || return 1
  for octet in "${octets[@]}"; do
    [[ "${octet}" =~ ^[0-9]{1,3}$ ]] || return 1
    (( 10#${octet} <= 255 )) || return 1
  done
}

valid_ipv4_cidr() {
  local cidr="$1" address="${1%/*}" prefix="${1##*/}"
  [[ "${cidr}" == */* && "${prefix}" =~ ^[0-9]{1,2}$ ]] || return 1
  (( 10#${prefix} <= 32 )) || return 1
  valid_ipv4 "${address}"
}

ensure_state_dir() {
  install -d -o root -g root -m 0700 "${KEYCLOAK_STATE_DIR}"
}

secret_hash() {
  printf '%s' "$1" | sha256sum | awk '{print $1}'
}

desired_state_fingerprint() {
  printf '%s\n' \
    "KEYCLOAK_VERSION=${KEYCLOAK_VERSION}" \
    "KEYCLOAK_SHA256=${KEYCLOAK_SHA256}" \
    "POSTGRESQL_MAJOR=${POSTGRESQL_MAJOR}" \
    "KEYCLOAK_EXTERNAL_URL=${KEYCLOAK_EXTERNAL_URL}" \
    "TLS_MODE=${TLS_MODE}" \
    "KEYCLOAK_DB_NAME=${KEYCLOAK_DB_NAME}" \
    "KEYCLOAK_DB_USER=${KEYCLOAK_DB_USER}" \
    "KEYCLOAK_DB_PASSWORD_SHA256=$(secret_hash "${KEYCLOAK_DB_PASSWORD}")" \
    "OIDC_REALM=${OIDC_REALM}" \
    "OIDC_CLIENT_ID=${OIDC_CLIENT_ID}" \
    "OIDC_CLIENT_SECRET_SHA256=$(secret_hash "${OIDC_CLIENT_SECRET}")" \
    "HEADLAMP_EXTERNAL_URL=${HEADLAMP_EXTERNAL_URL}" \
    "KEYCLOAK_ALLOWED_CIDRS=${KEYCLOAK_ALLOWED_CIDRS}" \
    "ENABLE_UFW=${ENABLE_UFW}" \
    | sha256sum | awk '{print $1}'
}

mark_step_complete() {
  local step="$1" steps_dir="${KEYCLOAK_STATE_DIR}/steps" temporary_state
  ensure_state_dir
  install -d -o root -g root -m 0700 "${steps_dir}"
  temporary_state="$(mktemp "${steps_dir}/.${step}.XXXXXX")"
  {
    printf 'completed_at=%q\n' "$(date --iso-8601=seconds)"
    printf 'config_fingerprint=%q\n' "$(desired_state_fingerprint)"
  } >"${temporary_state}"
  chmod 0600 "${temporary_state}"
  mv -f -- "${temporary_state}" "${steps_dir}/${step}.state"
}

retry() {
  local attempts="$1" delay="$2" count=1
  shift 2
  until "$@"; do
    if (( count >= attempts )); then
      return 1
    fi
    warn "tentativa ${count}/${attempts} falhou; tentando novamente em ${delay}s."
    sleep "${delay}"
    ((count++))
  done
}

systemd_quote() {
  local value="$1"
  [[ "${value}" != *$'\n'* && "${value}" != *$'\r'* ]] \
    || die "segredos e opções do systemd não podem conter quebras de linha."
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "${value}"
}

curl_keycloak() {
  curl --fail --silent --show-error --connect-timeout 5 --max-time 20 \
    --cacert "${KEYCLOAK_TLS_DIR}/ca.crt" "$@"
}

on_error() {
  local exit_code="$1" failed_command="$2" failed_line="$3" failed_source="$4"
  trap - ERR
  printf '\033[1;31m[ERRO]\033[0m %s:%s falhou (código %s). Comando: %s\n' \
    "$(basename -- "${failed_source}")" "${failed_line}" "${exit_code}" "${failed_command}" >&2
  exit "${exit_code}"
}

trap 'on_error "$?" "$BASH_COMMAND" "$LINENO" "${BASH_SOURCE[0]:-$0}"' ERR
