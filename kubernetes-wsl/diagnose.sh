#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
NO_LOG=false
RUN_MODE="diagnostic"
CONFIG_ARGUMENT=""

usage() {
  cat <<EOF
Uso:
  sudo bash $0 [cluster.env]
  sudo bash $0 --repair-dry-run [cluster.env]
  sudo bash $0 --repair [cluster.env]
  sudo bash $0 --no-log [cluster.env]

Modos:
  padrão             diagnóstico somente leitura, com log persistente
  --repair-dry-run   mostra até três ações seguras, sem alterar a configuração
  --repair           tenta recuperar a cadeia crítica; máximo de 3 ações e 5 minutos
  --no-log           diagnóstico somente leitura sem criar arquivo de log
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --no-log)
      NO_LOG=true
      ;;
    --repair-dry-run)
      [[ "${RUN_MODE}" == "diagnostic" ]] \
        || { printf 'ERRO: informe apenas um modo de execução.\n' >&2; exit 2; }
      RUN_MODE="repair-dry-run"
      ;;
    --repair)
      [[ "${RUN_MODE}" == "diagnostic" ]] \
        || { printf 'ERRO: informe apenas um modo de execução.\n' >&2; exit 2; }
      RUN_MODE="repair"
      ;;
    --*)
      printf 'ERRO: opção desconhecida: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
    *)
      [[ -z "${CONFIG_ARGUMENT}" ]] \
        || { printf 'ERRO: informe no máximo um arquivo cluster.env.\n' >&2; exit 2; }
      CONFIG_ARGUMENT="$1"
      ;;
  esac
  shift
done

if [[ "${NO_LOG}" == "true" && "${RUN_MODE}" != "diagnostic" ]]; then
  printf 'ERRO: modos de recuperação exigem log persistente; remova --no-log.\n' >&2
  exit 2
fi

if [[ "${EUID}" -ne 0 ]]; then
  printf 'ERRO: execute dentro do Ubuntu WSL: sudo bash %s [opcoes] [cluster.env]\n' "$0" >&2
  exit 1
fi

if [[ -n "${CONFIG_ARGUMENT}" ]]; then
  K8S_CONFIG_FILE="$(realpath -- "${CONFIG_ARGUMENT}")"
  export K8S_CONFIG_FILE
fi

# Preserva o ambiente recebido para detectar proxy corporativo sem o bypass.
DIAGNOSTIC_ORIGINAL_NO_PROXY="${NO_PROXY:-}"
DIAGNOSTIC_ORIGINAL_no_proxy="${no_proxy:-}"
export DIAGNOSTIC_ORIGINAL_NO_PROXY DIAGNOSTIC_ORIGINAL_no_proxy

# shellcheck source=scripts/lib/common.sh
source "${ROOT_DIR}/scripts/lib/common.sh"
# shellcheck source=scripts/lib/health.sh
source "${ROOT_DIR}/scripts/lib/health.sh"
# shellcheck source=scripts/lib/repair.sh
source "${ROOT_DIR}/scripts/lib/repair.sh"

require_command timeout

if ! is_true "${NO_LOG}"; then
  start_persistent_log "${RUN_MODE}"
fi

# O diagnóstico continua depois de cada falha para montar um panorama completo.
trap - ERR

diagnostic_failures=0
diagnostic_warnings=0
repair_exit=0

record_failure() {
  ((diagnostic_failures += 1))
}

record_warning() {
  ((diagnostic_warnings += 1))
}

run_state_check() {
  local step="$1" step_path="$2" check_argument="${3---check}"
  local output exit_code started_at="${SECONDS}"
  log_event INFO "${step}" checking "validando estado esperado pelo cluster.env"

  if [[ -n "${check_argument}" ]]; then
    if output="$(timeout --signal=TERM "${DIAGNOSTIC_CHECK_TIMEOUT_SECONDS}s" \
      bash "${step_path}" "${check_argument}" 2>&1)"; then
      exit_code=0
    else
      exit_code=$?
    fi
  elif output="$(timeout --signal=TERM "${DIAGNOSTIC_CHECK_TIMEOUT_SECONDS}s" \
    bash "${step_path}" 2>&1)"; then
    exit_code=0
  else
    exit_code=$?
  fi

  [[ -z "${output}" ]] || printf '%s\n' "${output}"
  if (( exit_code == 0 )); then
    log_event INFO "${step}" compliant \
      "duration_seconds=$((SECONDS - started_at))"
  else
    record_failure
    if (( exit_code == 124 )); then
      log_event ERROR "${step}" timeout \
        "a verificação excedeu ${DIAGNOSTIC_CHECK_TIMEOUT_SECONDS}s"
    else
      log_event ERROR "${step}" divergent \
        "codigo=${exit_code} duration_seconds=$((SECONDS - started_at))"
    fi
  fi
}

show_service_evidence() {
  local service_name="$1"
  systemctl status "${service_name}" --no-pager -l 2>&1 \
    | tail -n "${DIAGNOSTIC_TAIL_LINES}" || true
  journalctl -u "${service_name}" -b --no-pager \
    -n "${DIAGNOSTIC_TAIL_LINES}" 2>&1 || true
}

config_source="${K8S_CONFIG_FILE:-${ROOT_DIR}/cluster.env}"
[[ -r "${config_source}" ]] || config_source="defaults internos (cluster.env ausente)"
log_event HEADER diagnostic "${RUN_MODE}" "Diagnóstico e saúde do Kubernetes WSL"
log_event INFO diagnostic started \
  "modo=${RUN_MODE} config=${config_source} fingerprint=$(desired_state_fingerprint) parent_log=${K8S_DIAGNOSTIC_PARENT_LOG:-none}"
log_event INFO configuration effective \
  "node=${NODE_NAME}/${NODE_IP} kubernetes=${KUBERNETES_MINOR} pod_cidr=${POD_NETWORK_CIDR} service_cidr=${SERVICE_CIDR} artifact_mode=${ARTIFACT_MODE}"
log_event INFO configuration effective \
  "hostname=$(hostname 2>/dev/null || true)/${NODE_NAME} timezone=$(timedatectl show --property=Timezone --value 2>/dev/null || true)/${SYSTEM_TIMEZONE} no_proxy=${K8S_NO_PROXY}"
log_event INFO diagnostic context \
  "recuperacao_maxima=${REPAIR_MAX_ATTEMPTS} limite_total=min(${CLUSTER_OPERATION_TIMEOUT},300s) politica=sem-reset-sem-renovacao-de-certificados-sem-exclusao-de-dados"

log_event STAGE critical-health checking "Avaliando a cadeia crítica antes das verificações gerais"
health_run_checks
health_render_section

if [[ "${RUN_MODE}" == "diagnostic" ]] && ! health_core_healthy; then
  initial_primary="$(health_first_repair_issue || true)"
  health_capture_failure_evidence inicial "${initial_primary:-unknown}"
fi

case "${RUN_MODE}" in
  repair-dry-run)
    REPAIR_DRY_RUN=true
    if repair_run; then
      repair_exit=0
    else
      repair_exit=$?
    fi
    health_run_checks
    health_render_section
    ;;
  repair)
    REPAIR_DRY_RUN=false
    if repair_run; then
      repair_exit=0
    else
      repair_exit=$?
    fi
    health_run_checks
    health_render_section
    ;;
esac

if health_core_healthy; then
  log_event INFO critical-health healthy \
    "cadeia_critica=saudavel; problemas_totais=$(health_issue_count)"
else
  record_failure
  primary_issue="$(health_first_repair_issue || true)"
  log_event ERROR critical-health unhealthy \
    "primeiro_componente=${primary_issue:-desconhecido}; problemas_totais=$(health_issue_count); repair_exit=${repair_exit}"
fi

log_event STAGE desired-state checking "Validando todas as etapas declaradas pelo cluster.env"
run_state_check "00-preflight" "${ROOT_DIR}/scripts/00-preflight.sh" ""

state_steps=(
  05-standardize-system.sh
  10-prepare-host.sh
  20-install-containerd.sh
  30-install-kubernetes.sh
  40-bootstrap-cluster.sh
  50-install-network.sh
  52-install-helm.sh
  55-install-gateway.sh
  60-install-dashboard.sh
  70-configure-local-access.sh
  75-configure-gateway-access.sh
)

for step in "${state_steps[@]}"; do
  run_state_check "${step%.sh}" "${ROOT_DIR}/scripts/${step}"
done

log_event STAGE systemd checking "Serviços gerenciados pelo deploy"
required_services=(
  "${WSL_NODE_IP_SERVICE}"
  containerd
  kubelet
  "${HEADLAMP_FORWARD_SERVICE}"
)
for service_name in "${required_services[@]}"; do
  enabled_state="$(systemctl is-enabled "${service_name}" 2>/dev/null || true)"
  active_state="$(systemctl is-active "${service_name}" 2>/dev/null || true)"
  if [[ "${enabled_state}" == "enabled" && "${active_state}" == "active" ]]; then
    log_event INFO "systemd/${service_name}" healthy \
      "enabled=${enabled_state} active=${active_state}"
  else
    record_failure
    log_event ERROR "systemd/${service_name}" unhealthy \
      "enabled=${enabled_state:-unknown} active=${active_state:-unknown}"
    show_service_evidence "${service_name}"
  fi
done

gateway_enabled="$(systemctl is-enabled "${GATEWAY_FORWARD_SERVICE}" 2>/dev/null || true)"
gateway_active="$(systemctl is-active "${GATEWAY_FORWARD_SERVICE}" 2>/dev/null || true)"
if [[ "${gateway_enabled}" == "enabled" && "${gateway_active}" != "active" ]]; then
  record_failure
  log_event ERROR "systemd/${GATEWAY_FORWARD_SERVICE}" unhealthy \
    "o acesso opcional está habilitado, mas não está ativo"
  show_service_evidence "${GATEWAY_FORWARD_SERVICE}"
elif [[ "${gateway_active}" == "active" ]]; then
  log_event INFO "systemd/${GATEWAY_FORWARD_SERVICE}" healthy \
    "enabled=${gateway_enabled:-unknown} active=${gateway_active}; acesso opcional aberto"
else
  log_event INFO "systemd/${GATEWAY_FORWARD_SERVICE}" closed \
    "enabled=${gateway_enabled:-unknown} active=${gateway_active:-unknown}; acesso opcional fechado"
fi

failed_units="$(systemctl --failed --no-legend --plain 2>/dev/null || true)"
if [[ -n "${failed_units}" ]]; then
  record_warning
  log_event WARNING systemd failed-units "há unidades systemd em falha no WSL"
  printf '%s\n' "${failed_units}"
fi

log_event STAGE kubernetes checking "Inventário, workloads e eventos de erro"
if health_kubectl get --raw='/readyz' >/dev/null 2>&1; then
  health_kubectl get nodes -o wide 2>&1 || true
  health_kubectl get pods -A -o wide 2>&1 || true
  health_kubectl get gatewayclass,gateway -A 2>&1 || true

  mapfile -t pod_rows < <(health_kubectl get pods -A --no-headers 2>/dev/null || true)
  for pod_row in "${pod_rows[@]}"; do
    read -r pod_namespace pod_name pod_ready pod_status _ <<<"${pod_row}"
    ready_count="${pod_ready%/*}"
    container_count="${pod_ready#*/}"
    if [[ "${pod_status}" == "Running" && "${ready_count}" == "${container_count}" ]] \
      || [[ "${pod_status}" == "Completed" ]]; then
      continue
    fi
    record_failure
    log_event ERROR "pod/${pod_namespace}/${pod_name}" unhealthy \
      "ready=${pod_ready} status=${pod_status}"
    health_kubectl -n "${pod_namespace}" describe pod "${pod_name}" 2>&1 \
      | tail -n "${DIAGNOSTIC_TAIL_LINES}" || true
    health_kubectl -n "${pod_namespace}" logs "${pod_name}" --all-containers=true \
      --prefix --tail="${DIAGNOSTIC_TAIL_LINES}" 2>&1 || true
    health_kubectl -n "${pod_namespace}" logs "${pod_name}" --all-containers=true \
      --prefix --previous --tail="${DIAGNOSTIC_TAIL_LINES}" 2>&1 || true
  done

  warning_events="$(health_kubectl get events -A --field-selector type=Warning \
    --sort-by='.lastTimestamp' 2>/dev/null | tail -n "${DIAGNOSTIC_TAIL_LINES}" || true)"
  if [[ -n "${warning_events}" && "${warning_events}" != "No resources found"* ]]; then
    record_warning
    log_event WARNING kubernetes warning-events \
      "últimos eventos Warning (podem incluir ocorrências já recuperadas)"
    printf '%s\n' "${warning_events}"
  fi
else
  record_failure
  log_event ERROR kubernetes api-unavailable \
    "API Server não respondeu usando ${KUBECONFIG_ADMIN}"
  show_service_evidence kubelet
  show_service_evidence containerd
fi

if (( diagnostic_failures == 0 )); then
  log_event SUMMARY diagnostic healthy \
    "failures=0 warnings=${diagnostic_warnings} modo=${RUN_MODE} log=${BOOTSTRAP_LOG_FILE:-${K8S_DIAGNOSTIC_PARENT_LOG:-stdout}}"
  finish_persistent_log
  exit 0
fi

log_event SUMMARY diagnostic unhealthy \
  "failures=${diagnostic_failures} warnings=${diagnostic_warnings} modo=${RUN_MODE} log=${BOOTSTRAP_LOG_FILE:-${K8S_DIAGNOSTIC_PARENT_LOG:-stdout}}"
finish_persistent_log
exit 1
