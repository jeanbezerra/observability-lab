#!/usr/bin/env bash

set -Eeuo pipefail
umask 027

LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd -- "${LIB_DIR}/.." && pwd)"
PROJECT_DIR="$(cd -- "${SCRIPTS_DIR}/.." && pwd)"

if [[ -n "${K8S_CONFIG_FILE:-}" ]]; then
  if [[ ! -r "${K8S_CONFIG_FILE}" ]]; then
    printf 'ERRO: arquivo de configuração não pode ser lido: %s\n' "${K8S_CONFIG_FILE}" >&2
    exit 1
  fi
  # O arquivo é configuração shell e deve ser controlado pelo administrador.
  # shellcheck source=/dev/null
  source "${K8S_CONFIG_FILE}"
elif [[ -r "${PROJECT_DIR}/cluster.env" ]]; then
  # shellcheck source=/dev/null
  source "${PROJECT_DIR}/cluster.env"
fi

KUBERNETES_MINOR="${KUBERNETES_MINOR:-v1.36}"
POD_NETWORK_CIDR="${POD_NETWORK_CIDR:-10.244.0.0/16}"
SERVICE_CIDR="${SERVICE_CIDR:-10.96.0.0/12}"
NODE_IP="${NODE_IP:-}"
NODE_NAME="${NODE_NAME:-}"
ADMIN_USER="${ADMIN_USER:-${SUDO_USER:-k8sadmin}}"
ADMIN_GROUP="${ADMIN_GROUP:-k8s-operators}"
SINGLE_NODE="${SINGLE_NODE:-true}"
DASHBOARD_NAMESPACE="${DASHBOARD_NAMESPACE:-kubernetes-dashboard}"
DASHBOARD_NODE_PORT="${DASHBOARD_NODE_PORT:-30443}"
DASHBOARD_ALLOWED_CIDR="${DASHBOARD_ALLOWED_CIDR:-0.0.0.0/0}"
DASHBOARD_DNS_NAME="${DASHBOARD_DNS_NAME:-}"
DASHBOARD_PUBLIC_IP="${DASHBOARD_PUBLIC_IP:-}"
DASHBOARD_CERT_DAYS="${DASHBOARD_CERT_DAYS:-825}"
HEADLAMP_IMAGE="${HEADLAMP_IMAGE:-ghcr.io/headlamp-k8s/headlamp:v0.43.0}"
DASHBOARD_ROLLOUT_TIMEOUT="${DASHBOARD_ROLLOUT_TIMEOUT:-10m}"
CREATE_ADMIN_SERVICE_ACCOUNT="${CREATE_ADMIN_SERVICE_ACCOUNT:-true}"
DEFAULT_TOKEN_DURATION="${DEFAULT_TOKEN_DURATION:-8h}"
FLANNEL_VERSION="${FLANNEL_VERSION:-v0.28.4}"
FLANNEL_SHA256="${FLANNEL_SHA256:-d078019743c5e0194ce965125fc80ef00af0c1661ec9e12396311f1cfec860a2}"
ENABLE_UFW="${ENABLE_UFW:-true}"
SSH_PORT="${SSH_PORT:-22}"
ALLOW_UNSUPPORTED_OS="${ALLOW_UNSUPPORTED_OS:-false}"
AUTO_REPAIR_PARTIAL_CLUSTER="${AUTO_REPAIR_PARTIAL_CLUSTER:-true}"
KUBECONFIG_ADMIN="${KUBECONFIG_ADMIN:-/etc/kubernetes/admin.conf}"
BOOTSTRAP_STATE_DIR="${BOOTSTRAP_STATE_DIR:-/var/lib/k8s-bootstrap}"

readonly LIB_DIR SCRIPTS_DIR PROJECT_DIR

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

command_minor_version() {
  local command_name="$1"
  local output
  case "${command_name}" in
    kubeadm) output="$(kubeadm version -o short 2>/dev/null || true)" ;;
    kubelet) output="$(kubelet --version 2>/dev/null | awk '{print $2}' || true)" ;;
    kubectl) output="$(kubectl version --client -o json 2>/dev/null | sed -n 's/.*"gitVersion"[[:space:]]*:[[:space:]]*"\(v[0-9]*\.[0-9]*\).*".*/\1/p' || true)" ;;
    crictl) output="$(crictl --version 2>/dev/null | awk '{print $NF}' || true)" ;;
    *) return 1 ;;
  esac
  if [[ "${command_name}" == "kubectl" ]]; then
    printf '%s\n' "${output}"
  else
    sed -n 's/^\(v[0-9]*\.[0-9]*\).*/\1/p' <<<"${output}"
  fi
}

is_true() {
  case "${1,,}" in
    1|true|yes|sim|on) return 0 ;;
    *) return 1 ;;
  esac
}

valid_ipv4() {
  local address="$1"
  local IFS='.'
  local octets=()
  local octet
  read -r -a octets <<<"${address}"
  [[ "${#octets[@]}" -eq 4 ]] || return 1
  for octet in "${octets[@]}"; do
    [[ "${octet}" =~ ^[0-9]{1,3}$ ]] || return 1
    (( 10#${octet} <= 255 )) || return 1
  done
}

valid_ipv4_cidr() {
  local cidr="$1"
  local address="${cidr%/*}"
  local prefix="${cidr##*/}"
  [[ "${cidr}" == */* && "${prefix}" =~ ^[0-9]{1,2}$ ]] || return 1
  (( 10#${prefix} <= 32 )) || return 1
  valid_ipv4 "${address}"
}

detect_node_ip() {
  local detected
  if [[ -n "${NODE_IP}" ]]; then
    printf '%s\n' "${NODE_IP}"
    return
  fi

  detected="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}')"
  if [[ -z "${detected}" ]]; then
    detected="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  [[ -n "${detected}" ]] || die "não foi possível detectar NODE_IP; defina-o em cluster.env."
  printf '%s\n' "${detected}"
}

effective_node_name() {
  if [[ -n "${NODE_NAME}" ]]; then
    printf '%s\n' "${NODE_NAME}"
  else
    hostname -s | tr '[:upper:]' '[:lower:]'
  fi
}

kube() {
  kubectl --kubeconfig "${KUBECONFIG_ADMIN}" "$@"
}

ensure_state_dir() {
  install -d -o root -g root -m 0700 "${BOOTSTRAP_STATE_DIR}"
}

desired_state_fingerprint() {
  printf '%s\n' \
    "KUBERNETES_MINOR=${KUBERNETES_MINOR}" \
    "POD_NETWORK_CIDR=${POD_NETWORK_CIDR}" \
    "SERVICE_CIDR=${SERVICE_CIDR}" \
    "NODE_IP=${NODE_IP}" \
    "NODE_NAME=${NODE_NAME}" \
    "ADMIN_USER=${ADMIN_USER}" \
    "ADMIN_GROUP=${ADMIN_GROUP}" \
    "SINGLE_NODE=${SINGLE_NODE}" \
    "DASHBOARD_NAMESPACE=${DASHBOARD_NAMESPACE}" \
    "DASHBOARD_NODE_PORT=${DASHBOARD_NODE_PORT}" \
    "DASHBOARD_ALLOWED_CIDR=${DASHBOARD_ALLOWED_CIDR}" \
    "DASHBOARD_DNS_NAME=${DASHBOARD_DNS_NAME}" \
    "DASHBOARD_PUBLIC_IP=${DASHBOARD_PUBLIC_IP}" \
    "HEADLAMP_IMAGE=${HEADLAMP_IMAGE}" \
    "CREATE_ADMIN_SERVICE_ACCOUNT=${CREATE_ADMIN_SERVICE_ACCOUNT}" \
    "FLANNEL_VERSION=${FLANNEL_VERSION}" \
    "ENABLE_UFW=${ENABLE_UFW}" \
    | sha256sum | awk '{print $1}'
}

mark_step_complete() {
  local step="$1"
  local steps_dir="${BOOTSTRAP_STATE_DIR}/steps"
  local state_file="${steps_dir}/${step}.state"
  local temporary_state
  ensure_state_dir
  install -d -o root -g root -m 0700 "${steps_dir}"
  temporary_state="$(mktemp "${steps_dir}/.${step}.XXXXXX")"
  {
    printf 'completed_at=%q\n' "$(date --iso-8601=seconds)"
    printf 'config_fingerprint=%q\n' "$(desired_state_fingerprint)"
  } >"${temporary_state}"
  chmod 0600 "${temporary_state}"
  mv -f -- "${temporary_state}" "${state_file}"
  printf '%s\n' "${step}" >"${BOOTSTRAP_STATE_DIR}/last-successful-step"
  chmod 0600 "${BOOTSTRAP_STATE_DIR}/last-successful-step"
}

retry() {
  local attempts="$1"
  local delay="$2"
  shift 2
  local count=1
  until "$@"; do
    if (( count >= attempts )); then
      return 1
    fi
    warn "tentativa ${count}/${attempts} falhou; tentando novamente em ${delay}s."
    sleep "${delay}"
    ((count++))
  done
}

duration_to_seconds() {
  local duration="$1"
  local value="${duration%?}"
  local unit="${duration: -1}"
  [[ "${value}" =~ ^[0-9]+$ ]] || return 1
  case "${unit}" in
    s) printf '%s\n' "${value}" ;;
    m) printf '%s\n' "$((value * 60))" ;;
    h) printf '%s\n' "$((value * 3600))" ;;
    *) return 1 ;;
  esac
}

on_error() {
  local exit_code="$1"
  local failed_command="$2"
  local failed_line="$3"
  local failed_source="$4"
  trap - ERR
  printf '\033[1;31m[ERRO]\033[0m %s:%s falhou (código %s). Comando: %s\n' \
    "$(basename -- "${failed_source}")" "${failed_line}" "${exit_code}" "${failed_command}" >&2
  exit "${exit_code}"
}

trap 'on_error "$?" "$BASH_COMMAND" "$LINENO" "${BASH_SOURCE[0]:-$0}"' ERR
