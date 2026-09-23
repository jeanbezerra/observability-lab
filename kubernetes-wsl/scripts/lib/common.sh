#!/usr/bin/env bash

set -Eeuo pipefail
umask 027

LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd -- "${LIB_DIR}/.." && pwd)"
PROJECT_DIR="$(cd -- "${SCRIPTS_DIR}/.." && pwd)"

if [[ -n "${K8S_CONFIG_FILE:-}" ]]; then
  [[ -r "${K8S_CONFIG_FILE}" ]] \
    || { printf 'ERRO: arquivo de configuração não pode ser lido: %s\n' "${K8S_CONFIG_FILE}" >&2; exit 1; }
  # O arquivo é configuração shell e deve ser controlado pelo usuário local.
  # shellcheck source=/dev/null
  source "${K8S_CONFIG_FILE}"
elif [[ -r "${PROJECT_DIR}/cluster.env" ]]; then
  # shellcheck source=/dev/null
  source "${PROJECT_DIR}/cluster.env"
fi

KUBERNETES_MINOR="${KUBERNETES_MINOR:-v1.36}"
POD_NETWORK_CIDR="${POD_NETWORK_CIDR:-10.244.0.0/16}"
SERVICE_CIDR="${SERVICE_CIDR:-10.96.0.0/12}"
NODE_IP="${NODE_IP:-10.254.254.1}"
NODE_NAME="${NODE_NAME:-kubernetes-wsl}"
ADMIN_USER="${ADMIN_USER:-${SUDO_USER:-}}"
if [[ -z "${ADMIN_USER}" ]]; then
  ADMIN_USER="$(getent passwd 2>/dev/null | awk -F: '$3 == 1000 {print $1; exit}')"
fi
ADMIN_USER="${ADMIN_USER:-k8sadmin}"
SINGLE_NODE="${SINGLE_NODE:-true}"
DASHBOARD_NAMESPACE="${DASHBOARD_NAMESPACE:-kubernetes-dashboard}"
DASHBOARD_LOCAL_PORT="${DASHBOARD_LOCAL_PORT:-30443}"
DASHBOARD_CERT_DAYS="${DASHBOARD_CERT_DAYS:-825}"
DASHBOARD_DEFAULT_LANGUAGE="${DASHBOARD_DEFAULT_LANGUAGE:-pt}"
HEADLAMP_IMAGE="${HEADLAMP_IMAGE:-ghcr.io/headlamp-k8s/headlamp:v0.45.0}"
DASHBOARD_ROLLOUT_TIMEOUT="${DASHBOARD_ROLLOUT_TIMEOUT:-10m}"
FLANNEL_VERSION="${FLANNEL_VERSION:-v0.28.8}"
FLANNEL_SHA256="${FLANNEL_SHA256:-4148e659a834b51fc9aadc429281c6e80c97e0e25475faacd4cc857dbd16f21b}"
ALLOW_UNSUPPORTED_OS="${ALLOW_UNSUPPORTED_OS:-false}"
ALLOW_LOW_RESOURCES="${ALLOW_LOW_RESOURCES:-false}"
AUTO_REPAIR_PARTIAL_CLUSTER="${AUTO_REPAIR_PARTIAL_CLUSTER:-true}"
KUBECONFIG_ADMIN="${KUBECONFIG_ADMIN:-/etc/kubernetes/admin.conf}"
BOOTSTRAP_STATE_DIR="${BOOTSTRAP_STATE_DIR:-/var/lib/k8s-wsl-bootstrap}"
WSL_NODE_IP_SERVICE="${WSL_NODE_IP_SERVICE:-k8s-wsl-node-ip.service}"
HEADLAMP_FORWARD_SERVICE="${HEADLAMP_FORWARD_SERVICE:-k8s-headlamp-local.service}"

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
  [[ "${EUID}" -eq 0 ]] || die "execute este script dentro do WSL com sudo."
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
  local command_name="$1" output
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

is_wsl2() {
  grep -Eqi 'microsoft-standard-WSL2|WSL2' /proc/sys/kernel/osrelease /proc/version 2>/dev/null
}

systemd_is_pid1() {
  [[ "$(ps -p 1 -o comm= 2>/dev/null | tr -d '[:space:]')" == "systemd" ]]
}

valid_ipv4() {
  local address="$1" IFS='.' octets=() octet
  read -r -a octets <<<"${address}"
  [[ "${#octets[@]}" -eq 4 ]] || return 1
  for octet in "${octets[@]}"; do
    [[ "${octet}" =~ ^[0-9]{1,3}$ ]] || return 1
    (( 10#${octet} <= 255 )) || return 1
  done
}

valid_ipv4_cidr() {
  local cidr="$1" address prefix
  address="${cidr%/*}"
  prefix="${cidr##*/}"
  [[ "${cidr}" == */* && "${prefix}" =~ ^[0-9]{1,2}$ ]] || return 1
  (( 10#${prefix} <= 32 )) || return 1
  valid_ipv4 "${address}"
}

ipv4_to_integer() {
  local IFS='.' octets=()
  read -r -a octets <<<"$1"
  printf '%u\n' "$(( (10#${octets[0]} << 24) + (10#${octets[1]} << 16) + (10#${octets[2]} << 8) + 10#${octets[3]} ))"
}

cidr_contains_ipv4() {
  local cidr="$1" address="$2" prefix network address_integer mask
  prefix="${cidr##*/}"
  network="$(ipv4_to_integer "${cidr%/*}")"
  address_integer="$(ipv4_to_integer "${address}")"
  if (( prefix == 0 )); then
    mask=0
  else
    mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
  fi
  (( (network & mask) == (address_integer & mask) ))
}

detect_node_ip() {
  printf '%s\n' "${NODE_IP}"
}

effective_node_name() {
  printf '%s\n' "${NODE_NAME}"
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
    "SINGLE_NODE=${SINGLE_NODE}" \
    "DASHBOARD_NAMESPACE=${DASHBOARD_NAMESPACE}" \
    "DASHBOARD_LOCAL_PORT=${DASHBOARD_LOCAL_PORT}" \
    "DASHBOARD_DEFAULT_LANGUAGE=${DASHBOARD_DEFAULT_LANGUAGE}" \
    "HEADLAMP_IMAGE=${HEADLAMP_IMAGE}" \
    "FLANNEL_VERSION=${FLANNEL_VERSION}" \
    | sha256sum | awk '{print $1}'
}

mark_step_complete() {
  local step="$1" steps_dir="${BOOTSTRAP_STATE_DIR}/steps" state_file temporary_state
  state_file="${steps_dir}/${step}.state"
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

duration_to_seconds() {
  local duration="$1" value unit
  value="${duration%?}"
  unit="${duration: -1}"
  [[ "${value}" =~ ^[0-9]+$ ]] || return 1
  case "${unit}" in
    s) printf '%s\n' "${value}" ;;
    m) printf '%s\n' "$((value * 60))" ;;
    h) printf '%s\n' "$((value * 3600))" ;;
    *) return 1 ;;
  esac
}

on_error() {
  local exit_code="$1" failed_command="$2" failed_line="$3" failed_source="$4"
  trap - ERR
  printf '\033[1;31m[ERRO]\033[0m %s:%s falhou (código %s). Comando: %s\n' \
    "$(basename -- "${failed_source}")" "${failed_line}" "${exit_code}" "${failed_command}" >&2
  exit "${exit_code}"
}

trap 'on_error "$?" "$BASH_COMMAND" "$LINENO" "${BASH_SOURCE[0]:-$0}"' ERR
