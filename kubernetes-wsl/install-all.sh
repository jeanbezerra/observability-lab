#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${EUID}" -ne 0 ]]; then
  printf 'ERRO: execute dentro do Ubuntu WSL: sudo bash %s [cluster.env]\n' "$0" >&2
  exit 1
fi

if [[ $# -gt 1 ]]; then
  printf 'Uso: sudo bash %s [cluster.env]\n' "$0" >&2
  exit 2
fi

if [[ $# -eq 1 ]]; then
  K8S_CONFIG_FILE="$(realpath -- "$1")"
  export K8S_CONFIG_FILE
fi

# Os scripts são chamados via bash para também funcionar quando o repositório
# está em DrvFS (/mnt/c), onde bits POSIX de execução podem não ser preservados.
# shellcheck source=scripts/lib/common.sh
source "${ROOT_DIR}/scripts/lib/common.sh"

start_persistent_log deploy

INSTALL_COMPLETED=false
CURRENT_PHASE="startup"
CURRENT_PHASE_LABEL="Inicialização do instalador"
CURRENT_PHASE_STARTED="${SECONDS}"
INSTALL_STARTED_SECONDS="${SECONDS}"
STEP_SEQUENCE=0
STEP_TOTAL=13
LAST_RECORDED_PHASE=""
DIAGNOSTIC_LOG_FILE=""
declare -a SUMMARY_PHASES=()
declare -a SUMMARY_LABELS=()
declare -a SUMMARY_RESULTS=()
declare -a SUMMARY_DURATIONS=()

declare -A STEP_LABELS=(
  [05-standardize-system]="Padronizar hostname, timezone e NO_PROXY"
  [10-prepare-host]="Preparar o host WSL e a rede do nó"
  [20-install-containerd]="Configurar o runtime containerd"
  [30-install-kubernetes]="Validar pacotes e ferramentas Kubernetes"
  [40-bootstrap-cluster]="Inicializar ou validar o control plane"
  [50-install-network]="Configurar Flannel e CoreDNS"
  [52-install-helm]="Instalar e validar o Helm"
  [55-install-gateway]="Configurar Gateway API e Envoy Gateway"
  [60-install-dashboard]="Configurar o Headlamp"
  [70-configure-local-access]="Publicar o Headlamp somente em localhost"
  [75-configure-gateway-access]="Preparar o acesso local ao Gateway"
)

record_phase_result() {
  local phase="$1" label="$2" result="$3" duration="$4"
  SUMMARY_PHASES+=("${phase}")
  SUMMARY_LABELS+=("${label}")
  SUMMARY_RESULTS+=("${result}")
  SUMMARY_DURATIONS+=("${duration}")
  LAST_RECORDED_PHASE="${phase}"
}

start_phase() {
  local phase="$1" label="$2" stage_position
  CURRENT_PHASE="${phase}"
  CURRENT_PHASE_LABEL="${label}"
  CURRENT_PHASE_STARTED="${SECONDS}"
  ((STEP_SEQUENCE += 1))
  printf -v stage_position '%02d/%02d' "${STEP_SEQUENCE}" "${STEP_TOTAL}"
  log_event STAGE "${phase}" "${stage_position}" "${label}"
}

finish_phase() {
  local result="$1" message="$2" duration
  duration=$((SECONDS - CURRENT_PHASE_STARTED))
  record_phase_result "${CURRENT_PHASE}" "${CURRENT_PHASE_LABEL}" "${result}" "${duration}"
  log_event INFO "${CURRENT_PHASE}" "${result}" "${message}; duração=${duration}s"
}

print_install_context() {
  local config_path os_name cache_description
  config_path="${K8S_CONFIG_FILE:-${ROOT_DIR}/cluster.env}"
  os_name="$(. /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-desconhecido}")"
  if artifact_mode_is_offline; then
    cache_description="offline (${ARTIFACT_CACHE_DIR})"
  else
    cache_description="${ARTIFACT_MODE}"
  fi

  log_event HEADER installer "${BOOTSTRAP_RUN_ID}" "Kubernetes WSL · instalação e reconciliação"
  log_event INFO environment context \
    "host=$(hostname) os=${os_name} kernel=$(uname -r) arch=$(uname -m)"
  log_event INFO configuration context \
    "arquivo=${config_path} fingerprint=$(desired_state_fingerprint)"
  log_event INFO cluster desired \
    "node=${NODE_NAME}/${NODE_IP} kubernetes=${KUBERNETES_MINOR} pods=${POD_NETWORK_CIDR} services=${SERVICE_CIDR}"
  log_event INFO system desired \
    "hostname=${NODE_NAME} timezone=${SYSTEM_TIMEZONE} timeout_cluster=${CLUSTER_OPERATION_TIMEOUT} timeout_kubeadm=${KUBEADM_INIT_TIMEOUT}"
  log_event INFO proxy desired \
    "NO_PROXY=${K8S_NO_PROXY}"
  log_event INFO artifacts context \
    "modo=${cache_description} helm=${HELM_VERSION} flannel=${FLANNEL_VERSION} envoy=${ENVOY_GATEWAY_VERSION}"
  log_event INFO logger context \
    "arquivo=${BOOTSTRAP_LOG_FILE} atalho=${BOOTSTRAP_LOG_DIR}/latest-deploy.log"
}

collect_failure_diagnostic() {
  local diagnostic_exit=0 latest_diagnostic
  log_event INFO diagnostic running "coletando evidências em relatório separado"
  if K8S_DIAGNOSTIC_PARENT_LOG="${BOOTSTRAP_LOG_FILE}" \
    bash "${ROOT_DIR}/diagnose.sh" >/dev/null 2>&1; then
    diagnostic_exit=0
  else
    diagnostic_exit=$?
  fi
  latest_diagnostic="$(readlink -f -- "${BOOTSTRAP_LOG_DIR}/latest-diagnostic.log" 2>/dev/null || true)"
  if [[ -n "${latest_diagnostic}" && -r "${latest_diagnostic}" ]]; then
    DIAGNOSTIC_LOG_FILE="${latest_diagnostic}"
    log_event WARNING diagnostic collected \
      "resultado=${diagnostic_exit} relatório=${DIAGNOSTIC_LOG_FILE}"
  else
    log_event ERROR diagnostic unavailable \
      "não foi possível localizar o relatório de diagnóstico"
  fi
}

print_install_summary() {
  local final_status="$1" exit_code="$2" total_duration index
  total_duration=$((SECONDS - INSTALL_STARTED_SECONDS))
  log_event SUMMARY installer "${final_status}" \
    "etapas=${#SUMMARY_PHASES[@]}/${STEP_TOTAL} duração_total=${total_duration}s código=${exit_code}"
  for index in "${!SUMMARY_PHASES[@]}"; do
    log_event RESULT "${SUMMARY_PHASES[index]}" "${SUMMARY_RESULTS[index]}" \
      "${SUMMARY_LABELS[index]} · ${SUMMARY_DURATIONS[index]}s"
  done
  log_event RESULT installer "${final_status}" \
    "total=${total_duration}s · log=${BOOTSTRAP_LOG_FILE}"
  if [[ -n "${DIAGNOSTIC_LOG_FILE}" ]]; then
    log_event RESULT diagnostic collected "relatório=${DIAGNOSTIC_LOG_FILE}"
  fi
}

on_install_exit() {
  local exit_code="$1"
  trap - EXIT ERR
  if is_true "${INSTALL_COMPLETED}"; then
    log_event INFO access success \
      "Headlamp: https://localhost:${DASHBOARD_LOCAL_PORT}/?lng=${DASHBOARD_DEFAULT_LANGUAGE}"
    if systemctl is-active --quiet "${GATEWAY_FORWARD_SERVICE}"; then
      log_event INFO access success \
        "Gateway aberto somente em http://localhost:${GATEWAY_LOCAL_PORT}"
    else
      log_event INFO access closed \
        "Gateway fechado; use windows\\25-open-gateway-port.cmd para abrir a porta ${GATEWAY_LOCAL_PORT}"
    fi
    print_install_summary success "${exit_code}"
  else
    if [[ "${LAST_RECORDED_PHASE}" != "${CURRENT_PHASE}" ]]; then
      record_phase_result "${CURRENT_PHASE}" "${CURRENT_PHASE_LABEL}" failed \
        "$((SECONDS - CURRENT_PHASE_STARTED))"
    fi
    log_event ERROR installer failed \
      "run_id=${BOOTSTRAP_RUN_ID} phase=${CURRENT_PHASE} codigo=${exit_code}"
    if is_true "${DIAGNOSTIC_ON_ERROR}"; then
      collect_failure_diagnostic
    fi
    log_event ERROR installer next-action \
      "corrija a primeira etapa com falha e execute novamente; log=${BOOTSTRAP_LOG_FILE}"
    print_install_summary failed "${exit_code}"
  fi
  finish_persistent_log
  exit "${exit_code}"
}

trap 'on_install_exit "$?"' EXIT

if command -v flock >/dev/null 2>&1; then
  exec 9>/run/lock/k8s-wsl-bootstrap.lock
  flock -n 9 || die "já existe outra execução do instalador em andamento."
fi

print_install_context

start_phase "00-preflight" "Validar o host e o cluster.env"
log_event INFO "${CURRENT_PHASE}" running "verificando WSL, recursos, rede e configuração"
bash "${ROOT_DIR}/scripts/00-preflight.sh"
mark_step_complete "00-preflight"
finish_phase validated "Host e configuração aprovados"

steps=(
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

for step in "${steps[@]}"; do
  step_path="${ROOT_DIR}/scripts/${step}"
  step_name="${step%.sh}"
  start_phase "${step_name}" "${STEP_LABELS[$step_name]}"
  log_event INFO "${step_name}" checking "validando estado real"
  if bash "${step_path}" --check; then
    phase_result=compliant
    phase_message="Estado já estava correto; nenhuma alteração necessária"
  else
    log_event WARNING "${step_name}" reconciling "estado divergente; aplicando configuração"
    bash "${step_path}"
    bash "${step_path}" --check \
      || die "${step} terminou, mas a verificação pós-execução ainda falha."
    phase_result=reconciled
    phase_message="Configuração aplicada e verificação pós-execução aprovada"
  fi
  mark_step_complete "${step_name}"
  finish_phase "${phase_result}" "${phase_message}"
done

start_phase "90-verify" "Executar a validação funcional final"
log_event INFO "${CURRENT_PHASE}" running "executando verificação funcional final"
bash "${ROOT_DIR}/scripts/90-verify.sh"
mark_step_complete "90-verify"
finish_phase validated "Cluster e acessos funcionais validados"
INSTALL_COMPLETED=true
