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

on_install_exit() {
  local exit_code="$1"
  trap - EXIT ERR
  if is_true "${INSTALL_COMPLETED}"; then
    log_event INFO installer success \
      "run_id=${BOOTSTRAP_RUN_ID} log=${BOOTSTRAP_LOG_FILE}"
  else
    log_event ERROR installer failed \
      "run_id=${BOOTSTRAP_RUN_ID} phase=${CURRENT_PHASE} codigo=${exit_code}"
    if is_true "${DIAGNOSTIC_ON_ERROR}"; then
      log_event INFO diagnostic started \
        "executando diagnóstico automático no mesmo transcript"
      if ! K8S_DIAGNOSTIC_PARENT_LOG="${BOOTSTRAP_LOG_FILE}" \
        bash "${ROOT_DIR}/diagnose.sh" --no-log; then
        log_event WARNING diagnostic issues-found \
          "o diagnóstico confirmou estados pendentes; consulte o relatório acima"
      fi
    fi
    log_event ERROR installer log-available "log=${BOOTSTRAP_LOG_FILE}"
  fi
  exit "${exit_code}"
}

trap 'on_install_exit "$?"' EXIT

if command -v flock >/dev/null 2>&1; then
  exec 9>/run/lock/k8s-wsl-bootstrap.lock
  flock -n 9 || die "já existe outra execução do instalador em andamento."
fi

log_event INFO installer started \
  "config=${K8S_CONFIG_FILE:-${ROOT_DIR}/cluster.env} fingerprint=$(desired_state_fingerprint)"

CURRENT_PHASE="00-preflight"
phase_started="${SECONDS}"
log_event INFO "${CURRENT_PHASE}" running "validando host e cluster.env"
bash "${ROOT_DIR}/scripts/00-preflight.sh"
mark_step_complete "00-preflight"
log_event INFO "${CURRENT_PHASE}" compliant "duration_seconds=$((SECONDS - phase_started))"

steps=(
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
  CURRENT_PHASE="${step_name}"
  phase_started="${SECONDS}"
  printf '\n'
  log_event INFO "${step_name}" checking "validando estado real"
  if bash "${step_path}" --check; then
    log_event INFO "${step_name}" compliant "nenhuma alteração necessária"
  else
    log_event WARNING "${step_name}" reconciling "estado divergente; aplicando configuração"
    bash "${step_path}"
    bash "${step_path}" --check \
      || die "${step} terminou, mas a verificação pós-execução ainda falha."
    log_event INFO "${step_name}" reconciled "verificação pós-execução aprovada"
  fi
  mark_step_complete "${step_name}"
  log_event INFO "${step_name}" completed "duration_seconds=$((SECONDS - phase_started))"
done

CURRENT_PHASE="90-verify"
phase_started="${SECONDS}"
printf '\n'
log_event INFO "${CURRENT_PHASE}" running "executando verificação funcional final"
bash "${ROOT_DIR}/scripts/90-verify.sh"
mark_step_complete "90-verify"
log_event INFO "${CURRENT_PHASE}" compliant "duration_seconds=$((SECONDS - phase_started))"

printf '\nInstalação concluída. Abra https://localhost:%s/?lng=%s no Windows.\n' \
  "${DASHBOARD_LOCAL_PORT}" "${DASHBOARD_DEFAULT_LANGUAGE}"
if systemctl is-active --quiet "${GATEWAY_FORWARD_SERVICE}"; then
  printf 'Gateway API pronto e aberto somente em http://localhost:%s. Use windows\\75-close-gateway-port.cmd para fechar.\n' \
    "${GATEWAY_LOCAL_PORT}"
else
  printf 'Gateway API pronto e fechado no Windows. Use windows\\25-open-gateway-port.cmd para abrir http://localhost:%s.\n' \
    "${GATEWAY_LOCAL_PORT}"
fi

printf 'Log completo: %s\n' "${BOOTSTRAP_LOG_FILE}"
INSTALL_COMPLETED=true
