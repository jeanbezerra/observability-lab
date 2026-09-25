#!/usr/bin/env bash

# Recuperação controlada. Deve ser carregada depois de common.sh e health.sh.

readonly REPAIR_MAX_ATTEMPTS=3
readonly REPAIR_HARD_TIMEOUT_SECONDS=300

declare -Ag REPAIR_EXECUTED_ACTIONS=()
declare -ag REPAIR_HISTORY_ATTEMPTS=()
declare -ag REPAIR_HISTORY_COMPONENTS=()
declare -ag REPAIR_HISTORY_ACTIONS=()
declare -ag REPAIR_HISTORY_RESULTS=()

REPAIR_DRY_RUN=false
REPAIR_STARTED_SECONDS=0
REPAIR_TOTAL_TIMEOUT_SECONDS=300
REPAIR_RECOVERED=false
REPAIR_BLOCKED_REASON=""

repair_reset() {
  REPAIR_EXECUTED_ACTIONS=()
  REPAIR_HISTORY_ATTEMPTS=()
  REPAIR_HISTORY_COMPONENTS=()
  REPAIR_HISTORY_ACTIONS=()
  REPAIR_HISTORY_RESULTS=()
  REPAIR_STARTED_SECONDS="${SECONDS}"
  REPAIR_RECOVERED=false
  REPAIR_BLOCKED_REASON=""

  REPAIR_TOTAL_TIMEOUT_SECONDS="$(duration_to_seconds "${CLUSTER_OPERATION_TIMEOUT}" 2>/dev/null || printf '300')"
  if (( REPAIR_TOTAL_TIMEOUT_SECONDS > REPAIR_HARD_TIMEOUT_SECONDS )); then
    REPAIR_TOTAL_TIMEOUT_SECONDS="${REPAIR_HARD_TIMEOUT_SECONDS}"
  fi
  if (( REPAIR_TOTAL_TIMEOUT_SECONDS < 1 )); then
    REPAIR_TOTAL_TIMEOUT_SECONDS=1
  fi
}

repair_remaining_seconds() {
  local elapsed=$((SECONDS - REPAIR_STARTED_SECONDS)) remaining
  remaining=$((REPAIR_TOTAL_TIMEOUT_SECONDS - elapsed))
  (( remaining > 0 )) || remaining=0
  printf '%s\n' "${remaining}"
}

repair_attempt_budget() {
  local attempt="$1" remaining desired
  remaining="$(repair_remaining_seconds)"
  case "${attempt}" in
    1) desired=45 ;;
    2) desired=90 ;;
    *) desired="${remaining}" ;;
  esac
  (( desired <= remaining )) || desired="${remaining}"
  printf '%s\n' "${desired}"
}

repair_record_history() {
  REPAIR_HISTORY_ATTEMPTS+=("$1")
  REPAIR_HISTORY_COMPONENTS+=("$2")
  REPAIR_HISTORY_ACTIONS+=("$3")
  REPAIR_HISTORY_RESULTS+=("$4")
}

repair_acquire_lock() {
  command -v flock >/dev/null 2>&1 || {
    REPAIR_BLOCKED_REASON="flock não está disponível"
    return 1
  }
  exec {REPAIR_LOCK_FD}>/run/lock/k8s-wsl-bootstrap.lock
  if ! flock -n "${REPAIR_LOCK_FD}"; then
    REPAIR_BLOCKED_REASON="há uma instalação, remoção ou recuperação em andamento"
    return 1
  fi
}

repair_validate_target() {
  local marker_found=false existing_node_ip kubeconfig_server actual_nodes
  local node_ip_unit="/etc/systemd/system/${WSL_NODE_IP_SERVICE}"

  if [[ -r "${node_ip_unit}" ]] \
    && grep -Fq 'Stable loopback address for the local Kubernetes node on WSL 2' "${node_ip_unit}" \
    && grep -Fq "${NODE_IP}/32" "${node_ip_unit}"; then
    marker_found=true
  fi
  [[ -d "${BOOTSTRAP_STATE_DIR}/steps" ]] && marker_found=true
  if ! is_true "${marker_found}"; then
    REPAIR_BLOCKED_REASON="nenhum marcador confiável do projeto foi encontrado"
    return 1
  fi

  if [[ -r /etc/kubernetes/manifests/kube-apiserver.yaml ]]; then
    existing_node_ip="$(sed -n 's/^[[:space:]]*-[[:space:]]*--advertise-address=//p' \
      /etc/kubernetes/manifests/kube-apiserver.yaml | head -n 1)"
    if [[ -n "${existing_node_ip}" && "${existing_node_ip}" != "${NODE_IP}" ]]; then
      REPAIR_BLOCKED_REASON="manifest do API Server usa ${existing_node_ip}, mas cluster.env define ${NODE_IP}"
      return 1
    fi
  elif ss -H -ltn 'sport = :6443' 2>/dev/null | grep -q .; then
    REPAIR_BLOCKED_REASON="porta 6443 está ocupada sem um manifest reconhecido do API Server"
    return 1
  fi

  if [[ -r "${KUBECONFIG_ADMIN}" ]]; then
    kubeconfig_server="$(sed -n 's/^[[:space:]]*server:[[:space:]]*https:\/\/\([^:]*\):6443[[:space:]]*$/\1/p' \
      "${KUBECONFIG_ADMIN}" | head -n 1)"
    if [[ -n "${kubeconfig_server}" && "${kubeconfig_server}" != "${NODE_IP}" ]]; then
      REPAIR_BLOCKED_REASON="admin.conf aponta para ${kubeconfig_server}, mas NODE_IP=${NODE_IP}"
      return 1
    fi
  fi

  if is_true "${HEALTH_API_CLIENT_READY}"; then
    actual_nodes="$(health_kubectl get nodes -o name 2>/dev/null || true)"
    if [[ -n "${actual_nodes}" ]] && ! grep -Fxq "node/${NODE_NAME}" <<<"${actual_nodes}"; then
      REPAIR_BLOCKED_REASON="a API ativa não contém NODE_NAME=${NODE_NAME}"
      return 1
    fi
  fi

  log_event INFO repair target-validated \
    "node=${NODE_NAME}/${NODE_IP}; marker=${marker_found}; api_client=${HEALTH_API_CLIENT_READY}"
}

repair_etcd_has_unsafe_error() {
  local container_id logs
  container_id="$(health_static_container_ids etcd true | head -n 1)"
  [[ -n "${container_id}" ]] || return 1
  logs="$(health_crictl logs --tail=200 "${container_id}" 2>&1 || true)"
  grep -Eiq 'corrupt|crc mismatch|panic.*wal|database space exceeded|no space left on device' <<<"${logs}"
}

repair_safety_gate() {
  local primary="$1"
  case "${primary}" in
    certificates)
      REPAIR_BLOCKED_REASON="certificados ausentes ou expirados exigem intervenção explícita"
      return 1
      ;;
    static-manifests)
      REPAIR_BLOCKED_REASON="manifests estáticos ausentes não serão regenerados automaticamente"
      return 1
      ;;
    admin-kubeconfig)
      REPAIR_BLOCKED_REASON="admin.conf ausente ou inválido não será recriado automaticamente"
      return 1
      ;;
    host)
      if [[ "${HEALTH_STATUS[host]:-}" == "FAILED" ]]; then
        REPAIR_BLOCKED_REASON="pré-requisito crítico do host falhou: ${HEALTH_REASON[host]:-desconhecido}"
        return 1
      fi
      ;;
    etcd)
      if repair_etcd_has_unsafe_error; then
        REPAIR_BLOCKED_REASON="logs do etcd indicam corrupção, falta de espaço ou limite de banco"
        return 1
      fi
      ;;
  esac
}

repair_action_candidates() {
  local component="$1"
  case "${component}" in
    host)
      if [[ "${HEALTH_REASON[host]:-}" == *hostname* || "${HEALTH_REASON[host]:-}" == *timezone* ]]; then
        printf '%s\n' standardize-system
      fi
      ;;
    node-ip) printf '%s\n' restart-node-ip reconcile-host ;;
    containerd) printf '%s\n' restart-containerd reconcile-containerd restart-runtime-chain ;;
    kubelet) printf '%s\n' restart-kubelet restart-runtime-chain recreate-exited-control-plane ;;
    etcd|kube-apiserver|controller-manager|scheduler)
      printf '%s\n' restart-kubelet restart-runtime-chain recreate-exited-control-plane
      ;;
    proxy-bypass) printf '%s\n' standardize-system ;;
    flannel) printf '%s\n' restart-flannel reconcile-network restart-network-stack ;;
    node-ready) printf '%s\n' restart-kubelet restart-flannel reconcile-network ;;
    kube-proxy) printf '%s\n' restart-kube-proxy restart-network-stack reconcile-network ;;
    coredns) printf '%s\n' restart-coredns reconcile-network restart-network-stack ;;
    *) return 0 ;;
  esac
}

repair_plan_action() {
  local component="$1" candidate
  while IFS= read -r candidate; do
    [[ -n "${candidate}" ]] || continue
    if [[ -z "${REPAIR_EXECUTED_ACTIONS[${candidate}]+executed}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done < <(repair_action_candidates "${component}")
  return 1
}

repair_run_stage() {
  local budget="$1" stage="$2"
  timeout --signal=TERM --kill-after=5s "${budget}s" \
    bash "${SCRIPTS_DIR}/${stage}"
}

repair_restart_service() {
  local service_name="$1"
  systemctl reset-failed "${service_name}" >/dev/null 2>&1 || true
  timeout --signal=TERM 30s systemctl restart "${service_name}"
}

repair_wait_for_containerd() {
  local deadline=$((SECONDS + 20))
  until [[ -S /run/containerd/containerd.sock ]] && health_crictl info >/dev/null 2>&1; do
    (( SECONDS < deadline )) || return 1
    sleep 2
  done
}

repair_restart_runtime_chain() {
  repair_restart_service containerd.service || return 1
  repair_wait_for_containerd || return 1
  repair_restart_service kubelet.service
}

repair_recreate_exited_control_plane() {
  local runtime_name container_id removed=0
  for runtime_name in etcd kube-apiserver kube-controller-manager kube-scheduler; do
    while IFS= read -r container_id; do
      [[ -n "${container_id}" ]] || continue
      health_crictl rm --force "${container_id}" >/dev/null
      ((removed += 1))
    done < <(health_crictl ps -a --state exited --name "${runtime_name}" -q 2>/dev/null || true)
  done
  log_event INFO repair cleanup "containers estáticos encerrados removidos=${removed}"
  repair_restart_service kubelet.service
}

repair_execute_action() {
  local action="$1" budget="$2"
  case "${action}" in
    standardize-system)
      repair_run_stage "${budget}" 05-standardize-system.sh || return 1
      DIAGNOSTIC_ORIGINAL_NO_PROXY="${K8S_NO_PROXY}"
      DIAGNOSTIC_ORIGINAL_no_proxy="${K8S_NO_PROXY}"
      export DIAGNOSTIC_ORIGINAL_NO_PROXY DIAGNOSTIC_ORIGINAL_no_proxy
      ;;
    restart-node-ip) repair_restart_service "${WSL_NODE_IP_SERVICE}" ;;
    reconcile-host) repair_run_stage "${budget}" 10-prepare-host.sh ;;
    restart-containerd)
      repair_restart_service containerd.service && repair_wait_for_containerd
      ;;
    reconcile-containerd) repair_run_stage "${budget}" 20-install-containerd.sh ;;
    restart-kubelet) repair_restart_service kubelet.service ;;
    restart-runtime-chain) repair_restart_runtime_chain ;;
    recreate-exited-control-plane) repair_recreate_exited_control_plane ;;
    restart-flannel)
      health_kubectl -n kube-flannel rollout restart daemonset/kube-flannel-ds
      ;;
    restart-kube-proxy)
      health_kubectl -n kube-system rollout restart daemonset/kube-proxy
      ;;
    restart-coredns)
      health_kubectl -n kube-system rollout restart deployment/coredns
      ;;
    reconcile-network) repair_run_stage "${budget}" 50-install-network.sh ;;
    restart-network-stack)
      health_kubectl -n kube-flannel rollout restart daemonset/kube-flannel-ds || return 1
      health_kubectl -n kube-system rollout restart daemonset/kube-proxy || return 1
      health_kubectl -n kube-system rollout restart deployment/coredns
      ;;
    *)
      log_event ERROR repair failed "ação desconhecida: ${action}"
      return 1
      ;;
  esac
}

repair_wait_for_progress() {
  local original_component="$1" wait_seconds="$2" started_at="${SECONDS}" current_primary sleep_seconds remaining
  while (( SECONDS - started_at < wait_seconds )); do
    remaining=$((wait_seconds - (SECONDS - started_at)))
    sleep_seconds=5
    (( sleep_seconds <= remaining )) || sleep_seconds="${remaining}"
    (( sleep_seconds > 0 )) || break
    sleep "${sleep_seconds}"
    health_run_checks
    if health_core_healthy; then
      return 0
    fi
    current_primary="$(health_first_repair_issue || true)"
    if [[ -n "${current_primary}" && "${current_primary}" != "${original_component}" ]]; then
      return 2
    fi
    if [[ "${HEALTH_STATUS["${original_component}"]:-UNKNOWN}" == "HEALTHY" ]]; then
      return 2
    fi
  done
  return 1
}

repair_render_summary() {
  local index final_status="unresolved"
  is_true "${REPAIR_DRY_RUN}" && final_status="dry-run"
  is_true "${REPAIR_RECOVERED}" && final_status="recovered"
  [[ -n "${REPAIR_BLOCKED_REASON}" ]] && final_status="blocked"
  log_event SUMMARY repair "${final_status}" \
    "tentativas=${#REPAIR_HISTORY_ACTIONS[@]}/${REPAIR_MAX_ATTEMPTS} duração=$((SECONDS - REPAIR_STARTED_SECONDS))s limite=${REPAIR_TOTAL_TIMEOUT_SECONDS}s"
  for index in "${!REPAIR_HISTORY_ACTIONS[@]}"; do
    log_event RESULT "repair/${REPAIR_HISTORY_COMPONENTS[index]}" "${REPAIR_HISTORY_RESULTS[index]}" \
      "tentativa=${REPAIR_HISTORY_ATTEMPTS[index]}/${REPAIR_MAX_ATTEMPTS} ação=${REPAIR_HISTORY_ACTIONS[index]}"
  done
  if [[ -n "${REPAIR_BLOCKED_REASON}" ]]; then
    log_event RESULT repair blocked "${REPAIR_BLOCKED_REASON}"
  fi
}

repair_run() {
  local attempt primary action budget action_started wait_budget action_result wait_result remaining
  repair_reset

  if ! repair_acquire_lock; then
    log_event ERROR repair blocked "${REPAIR_BLOCKED_REASON}"
    repair_render_summary
    return 1
  fi
  if ! repair_validate_target; then
    log_event ERROR repair blocked "${REPAIR_BLOCKED_REASON}"
    repair_render_summary
    return 1
  fi

  if health_core_healthy; then
    REPAIR_RECOVERED=true
    log_event INFO repair healthy "nenhuma ação necessária"
    repair_render_summary
    return 0
  fi

  for ((attempt = 1; attempt <= REPAIR_MAX_ATTEMPTS; attempt++)); do
    remaining="$(repair_remaining_seconds)"
    if (( remaining <= 0 )); then
      REPAIR_BLOCKED_REASON="orçamento total de ${REPAIR_TOTAL_TIMEOUT_SECONDS}s esgotado"
      break
    fi

    primary="$(health_first_repair_issue || true)"
    if [[ -z "${primary}" ]]; then
      REPAIR_RECOVERED=true
      break
    fi
    if ! repair_safety_gate "${primary}"; then
      log_event ERROR "repair/${primary}" blocked "${REPAIR_BLOCKED_REASON}"
      break
    fi
    if ! action="$(repair_plan_action "${primary}")"; then
      if is_true "${REPAIR_DRY_RUN}" && (( ${#REPAIR_HISTORY_ACTIONS[@]} > 0 )); then
        log_event INFO "repair/${primary}" dry-run \
          "plano esgotado para ${primary}; nenhuma ação adicional seria executada"
        break
      fi
      REPAIR_BLOCKED_REASON="nenhuma ação automática segura permanece para ${primary}"
      log_event ERROR "repair/${primary}" blocked "${REPAIR_BLOCKED_REASON}"
      break
    fi

    budget="$(repair_attempt_budget "${attempt}")"
    (( budget > 0 )) || {
      REPAIR_BLOCKED_REASON="sem tempo restante para a tentativa ${attempt}"
      break
    }
    REPAIR_EXECUTED_ACTIONS["${action}"]=1
    health_capture_failure_evidence "tentativa ${attempt}/${REPAIR_MAX_ATTEMPTS} · ${primary}" "${primary}"
    log_event WARNING "repair/${primary}" running \
      "tentativa=${attempt}/${REPAIR_MAX_ATTEMPTS} ação=${action} orçamento=${budget}s dry_run=${REPAIR_DRY_RUN}"

    if is_true "${REPAIR_DRY_RUN}"; then
      repair_record_history "${attempt}" "${primary}" "${action}" dry-run
      continue
    fi

    action_started="${SECONDS}"
    if repair_execute_action "${action}" "${budget}"; then
      action_result=executed
    else
      action_result=failed
    fi
    wait_budget=$((budget - (SECONDS - action_started)))
    (( wait_budget > 0 )) || wait_budget=1

    wait_result=1
    if [[ "${action_result}" == "executed" ]]; then
      if repair_wait_for_progress "${primary}" "${wait_budget}"; then
        wait_result=0
      else
        wait_result=$?
      fi
    else
      health_run_checks
    fi

    if health_core_healthy; then
      REPAIR_RECOVERED=true
      repair_record_history "${attempt}" "${primary}" "${action}" recovered
      health_render_section
      break
    fi
    if (( wait_result == 2 )); then
      repair_record_history "${attempt}" "${primary}" "${action}" progressed
    else
      repair_record_history "${attempt}" "${primary}" "${action}" "${action_result}"
    fi
    health_render_section
  done

  if is_true "${REPAIR_DRY_RUN}"; then
    log_event INFO repair dry-run "plano concluído; nenhuma alteração foi realizada"
    repair_render_summary
    return 0
  fi
  if is_true "${REPAIR_RECOVERED}"; then
    log_event INFO repair success "cadeia crítica recuperada"
    repair_render_summary
    return 0
  fi
  [[ -n "${REPAIR_BLOCKED_REASON}" ]] \
    || REPAIR_BLOCKED_REASON="três ações distintas foram executadas sem recuperar a cadeia crítica"
  log_event ERROR repair unhealthy "${REPAIR_BLOCKED_REASON}"
  repair_render_summary
  return 1
}
