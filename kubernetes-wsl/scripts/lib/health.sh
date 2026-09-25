#!/usr/bin/env bash

# Biblioteca somente leitura. Deve ser carregada depois de scripts/lib/common.sh.
# Os estados globais abaixo são consumidos pelo orquestrador e por repair.sh.
# shellcheck disable=SC2034

readonly HEALTH_CRI_ENDPOINT="unix:///run/containerd/containerd.sock"

declare -ag HEALTH_COMPONENTS=(
  host
  node-ip
  containerd
  kubelet
  certificates
  static-manifests
  etcd
  kube-apiserver
  admin-kubeconfig
  proxy-bypass
  controller-manager
  scheduler
  flannel
  node-ready
  kube-proxy
  coredns
  envoy
  headlamp
)

declare -ag HEALTH_REPAIR_COMPONENTS=(
  host
  node-ip
  containerd
  kubelet
  certificates
  static-manifests
  etcd
  kube-apiserver
  admin-kubeconfig
  proxy-bypass
  controller-manager
  scheduler
  flannel
  node-ready
  kube-proxy
  coredns
)

declare -Ag HEALTH_PRIORITY=()
declare -Ag HEALTH_STATUS=()
declare -Ag HEALTH_DEPENDENCY=()
declare -Ag HEALTH_REASON=()
declare -Ag HEALTH_EVIDENCE=()

HEALTH_API_DIRECT_READY=false
HEALTH_API_CLIENT_READY=false
HEALTH_API_NORMAL_READY=false

health_compact_text() {
  tr '\r\n\t' '   ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' | cut -c1-500
}

health_record() {
  local component="$1" priority="$2" status="$3" dependency="$4" reason="$5" evidence="${6:-}"
  HEALTH_PRIORITY["${component}"]="${priority}"
  HEALTH_STATUS["${component}"]="${status}"
  HEALTH_DEPENDENCY["${component}"]="${dependency}"
  HEALTH_REASON["${component}"]="${reason}"
  HEALTH_EVIDENCE["${component}"]="${evidence}"
}

health_reset() {
  HEALTH_PRIORITY=()
  HEALTH_STATUS=()
  HEALTH_DEPENDENCY=()
  HEALTH_REASON=()
  HEALTH_EVIDENCE=()
  HEALTH_API_DIRECT_READY=false
  HEALTH_API_CLIENT_READY=false
  HEALTH_API_NORMAL_READY=false
}

health_dependency_unavailable() {
  local dependency="$1" status
  [[ -n "${dependency}" ]] || return 1
  status="${HEALTH_STATUS["${dependency}"]:-UNKNOWN}"
  [[ "${status}" == "FAILED" || "${status}" == "BLOCKED" || "${status}" == "UNKNOWN" ]]
}

health_blocked() {
  local component="$1" priority="$2" dependency="$3"
  health_record "${component}" "${priority}" BLOCKED "${dependency}" \
    "dependência ${dependency} não está saudável" \
    "dependency_status=${HEALTH_STATUS["${dependency}"]:-UNKNOWN}"
}

health_crictl() {
  timeout --signal=TERM "${KUBERNETES_REQUEST_TIMEOUT_SECONDS}s" \
    crictl --runtime-endpoint="${HEALTH_CRI_ENDPOINT}" \
      --image-endpoint="${HEALTH_CRI_ENDPOINT}" \
      --timeout="${KUBERNETES_REQUEST_TIMEOUT_SECONDS}s" "$@"
}

health_kubectl() {
  timeout --signal=TERM "${KUBERNETES_REQUEST_TIMEOUT_SECONDS}s" \
    env NO_PROXY="${K8S_NO_PROXY}" no_proxy="${K8S_NO_PROXY}" \
    kubectl --kubeconfig "${KUBECONFIG_ADMIN}" \
      --request-timeout="${KUBERNETES_REQUEST_TIMEOUT_SECONDS}s" "$@"
}

health_probe_host() {
  local disk_available_kib inode_used_percent memory_available_kib current_hostname current_timezone
  local -a failures=() degradations=()

  systemd_is_pid1 || failures+=("systemd não é PID 1")
  [[ -r /sys/fs/cgroup/cgroup.controllers ]] || failures+=("cgroup v2 indisponível")

  disk_available_kib="$(df -Pk / 2>/dev/null | awk 'NR == 2 {print $4}')"
  if [[ "${disk_available_kib}" =~ ^[0-9]+$ ]] && (( disk_available_kib < 1048576 )); then
    failures+=("menos de 1 GiB livre em /")
  fi
  inode_used_percent="$(df -Pi / 2>/dev/null | awk 'NR == 2 {gsub(/%/, "", $5); print $5}')"
  if [[ "${inode_used_percent}" =~ ^[0-9]+$ ]] && (( inode_used_percent >= 95 )); then
    failures+=("uso de inodes em ${inode_used_percent}%")
  fi
  memory_available_kib="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null)"
  if [[ "${memory_available_kib}" =~ ^[0-9]+$ ]] && (( memory_available_kib < 262144 )); then
    degradations+=("menos de 256 MiB de memória disponível")
  fi

  current_hostname="$(hostname 2>/dev/null || true)"
  current_timezone="$(timedatectl show --property=Timezone --value 2>/dev/null || true)"
  [[ "${current_hostname}" == "${NODE_NAME}" ]] \
    || degradations+=("hostname=${current_hostname:-desconhecido}, esperado=${NODE_NAME}")
  [[ "${current_timezone}" == "${SYSTEM_TIMEZONE}" ]] \
    || degradations+=("timezone=${current_timezone:-desconhecido}, esperado=${SYSTEM_TIMEZONE}")

  if (( ${#failures[@]} > 0 )); then
    health_record host P0 FAILED "" "${failures[*]}" \
      "disk_available_kib=${disk_available_kib:-unknown} inode_used=${inode_used_percent:-unknown}% memory_available_kib=${memory_available_kib:-unknown}"
  elif (( ${#degradations[@]} > 0 )); then
    health_record host P0 DEGRADED "" "${degradations[*]}" \
      "disk_available_kib=${disk_available_kib:-unknown} inode_used=${inode_used_percent:-unknown}% memory_available_kib=${memory_available_kib:-unknown}"
  else
    health_record host P0 HEALTHY "" "host Linux atende aos pré-requisitos críticos" \
      "disk_available_kib=${disk_available_kib:-unknown} inode_used=${inode_used_percent:-unknown}% memory_available_kib=${memory_available_kib:-unknown}"
  fi
}

health_probe_node_ip() {
  local route
  if health_dependency_unavailable host; then
    health_blocked node-ip P0 host
    return
  fi
  if ! systemctl is-active --quiet "${WSL_NODE_IP_SERVICE}"; then
    health_record node-ip P0 FAILED host "${WSL_NODE_IP_SERVICE} não está ativo" \
      "active=$(systemctl is-active "${WSL_NODE_IP_SERVICE}" 2>/dev/null || true)"
    return
  fi
  if ! ip -4 address show dev lo 2>/dev/null | grep -Fq "${NODE_IP}/32"; then
    health_record node-ip P0 FAILED host "NODE_IP=${NODE_IP}/32 não está presente em lo" "interface=lo"
    return
  fi
  route="$(ip route get "${NODE_IP}" 2>&1 | health_compact_text || true)"
  if ! grep -Eq "(^|[[:space:]])local[[:space:]].*dev[[:space:]]+lo([[:space:]]|$)" <<<"${route}"; then
    health_record node-ip P0 FAILED host "rota local de NODE_IP não aponta para lo" "${route:-rota ausente}"
    return
  fi
  health_record node-ip P0 HEALTHY host "endereço estável e rota local estão ativos" "${route}"
}

health_probe_containerd() {
  local cri_error
  if health_dependency_unavailable node-ip; then
    health_blocked containerd P1 node-ip
    return
  fi
  if ! systemctl is-active --quiet containerd.service; then
    health_record containerd P1 FAILED node-ip "containerd.service não está ativo" \
      "active=$(systemctl is-active containerd.service 2>/dev/null || true)"
    return
  fi
  if [[ ! -S /run/containerd/containerd.sock ]]; then
    health_record containerd P1 FAILED node-ip "socket CRI do containerd está ausente" \
      "socket=/run/containerd/containerd.sock"
    return
  fi
  if ! command -v crictl >/dev/null 2>&1; then
    health_record containerd P1 FAILED node-ip "crictl não está instalado" "command=crictl"
    return
  fi
  if ! cri_error="$(health_crictl info 2>&1 >/dev/null)"; then
    cri_error="$(health_compact_text <<<"${cri_error}")"
    health_record containerd P1 FAILED node-ip "CRI não respondeu" "${cri_error:-erro sem mensagem}"
    return
  fi
  health_record containerd P1 HEALTHY node-ip "containerd e CRI responderam" \
    "socket=/run/containerd/containerd.sock"
}

health_probe_kubelet() {
  local response
  if health_dependency_unavailable containerd; then
    health_blocked kubelet P1 containerd
    return
  fi
  if ! systemctl is-active --quiet kubelet.service; then
    health_record kubelet P1 FAILED containerd "kubelet.service não está ativo" \
      "active=$(systemctl is-active kubelet.service 2>/dev/null || true)"
    return
  fi
  if [[ ! -r /var/lib/kubelet/config.yaml ]]; then
    health_record kubelet P1 FAILED containerd "configuração do kubelet está ausente" \
      "file=/var/lib/kubelet/config.yaml"
    return
  fi
  response="$(curl --noproxy '*' -fsS --connect-timeout 3 --max-time 5 \
    http://127.0.0.1:10248/healthz 2>&1 || true)"
  if [[ "${response}" != "ok" ]]; then
    health_record kubelet P1 FAILED containerd "endpoint de saúde do kubelet não respondeu ok" \
      "response=$(health_compact_text <<<"${response:-sem resposta}")"
    return
  fi
  health_record kubelet P1 HEALTHY containerd "kubelet respondeu em 127.0.0.1:10248" "healthz=ok"
}

health_probe_certificates() {
  local certificate
  local -a required_certificates=(
    /etc/kubernetes/pki/apiserver.crt
    /etc/kubernetes/pki/apiserver-kubelet-client.crt
    /etc/kubernetes/pki/front-proxy-client.crt
    /etc/kubernetes/pki/etcd/server.crt
    /etc/kubernetes/pki/etcd/peer.crt
  )
  local -a missing=() expired=()

  if health_dependency_unavailable kubelet; then
    health_blocked certificates P2 kubelet
    return
  fi
  if ! command -v openssl >/dev/null 2>&1; then
    health_record certificates P2 UNKNOWN kubelet "openssl não está disponível" "command=openssl"
    return
  fi
  for certificate in "${required_certificates[@]}"; do
    if [[ ! -r "${certificate}" ]]; then
      missing+=("${certificate}")
    elif ! openssl x509 -checkend 0 -noout -in "${certificate}" >/dev/null 2>&1; then
      expired+=("${certificate}")
    fi
  done
  if (( ${#missing[@]} > 0 )); then
    health_record certificates P2 FAILED kubelet "certificados obrigatórios estão ausentes" "${missing[*]}"
  elif (( ${#expired[@]} > 0 )); then
    health_record certificates P2 FAILED kubelet "certificados expirados foram detectados" "${expired[*]}"
  else
    health_record certificates P2 HEALTHY kubelet "certificados essenciais existem e estão válidos" \
      "checked=${#required_certificates[@]}"
  fi
}

health_probe_static_manifests() {
  local component manifest
  local -a missing=()
  if health_dependency_unavailable certificates; then
    health_blocked static-manifests P2 certificates
    return
  fi
  for component in etcd kube-apiserver kube-controller-manager kube-scheduler; do
    manifest="/etc/kubernetes/manifests/${component}.yaml"
    [[ -s "${manifest}" ]] || missing+=("${manifest}")
  done
  if (( ${#missing[@]} > 0 )); then
    health_record static-manifests P2 FAILED certificates "manifests estáticos estão ausentes" "${missing[*]}"
  else
    health_record static-manifests P2 HEALTHY certificates "quatro manifests estáticos estão presentes" \
      "path=/etc/kubernetes/manifests"
  fi
}

health_static_container_ids() {
  local component="$1" include_stopped="${2:-false}"
  if is_true "${include_stopped}"; then
    health_crictl ps -a --name "${component}" -q 2>/dev/null || true
  else
    health_crictl ps --name "${component}" -q 2>/dev/null || true
  fi
}

health_probe_static_container() {
  local component="$1" priority="$2" dependency="$3" runtime_name="${4:-$1}"
  local running_id last_id
  if health_dependency_unavailable "${dependency}"; then
    health_blocked "${component}" "${priority}" "${dependency}"
    return
  fi
  running_id="$(health_static_container_ids "${runtime_name}" false | head -n 1)"
  if [[ -n "${running_id}" ]]; then
    health_record "${component}" "${priority}" HEALTHY "${dependency}" \
      "container estático está em execução" "container_id=${running_id}"
    return
  fi
  last_id="$(health_static_container_ids "${runtime_name}" true | head -n 1)"
  if [[ -n "${last_id}" ]]; then
    health_record "${component}" "${priority}" FAILED "${dependency}" \
      "container estático não está em execução" "last_container_id=${last_id}"
  else
    health_record "${component}" "${priority}" FAILED "${dependency}" \
      "nenhum container estático foi criado" "component=${runtime_name}"
  fi
}

health_probe_apiserver() {
  local running_id response
  if health_dependency_unavailable etcd; then
    health_blocked kube-apiserver P2 etcd
    return
  fi
  running_id="$(health_static_container_ids kube-apiserver false | head -n 1)"
  if [[ -z "${running_id}" ]]; then
    health_record kube-apiserver P2 FAILED etcd "kube-apiserver não está em execução" \
      "last_container_id=$(health_static_container_ids kube-apiserver true | head -n 1)"
    return
  fi
  response="$(curl --noproxy '*' -ksS --connect-timeout 3 \
    --max-time "${KUBERNETES_REQUEST_TIMEOUT_SECONDS}" \
    "https://${NODE_IP}:6443/readyz" 2>&1 || true)"
  if [[ "${response}" == "ok" ]]; then
    HEALTH_API_DIRECT_READY=true
    health_record kube-apiserver P2 HEALTHY etcd "API Server respondeu diretamente sem proxy" \
      "container_id=${running_id} readyz=ok"
  else
    health_record kube-apiserver P2 FAILED etcd "API Server está em execução, mas não ficou pronto" \
      "readyz=$(health_compact_text <<<"${response:-sem resposta}")"
  fi
}

health_probe_api_client() {
  local normal_error forced_error
  if health_dependency_unavailable kube-apiserver; then
    health_blocked admin-kubeconfig P2 kube-apiserver
    health_blocked proxy-bypass P0 admin-kubeconfig
    return
  fi
  if [[ ! -r "${KUBECONFIG_ADMIN}" ]]; then
    health_record admin-kubeconfig P2 FAILED kube-apiserver "admin.conf está ausente" \
      "file=${KUBECONFIG_ADMIN}"
    health_blocked proxy-bypass P0 admin-kubeconfig
    return
  fi
  if ! forced_error="$(health_kubectl get --raw=/readyz 2>&1 >/dev/null)"; then
    health_record admin-kubeconfig P2 FAILED kube-apiserver \
      "kubectl não acessou a API mesmo com NO_PROXY forçado" \
      "$(health_compact_text <<<"${forced_error:-erro sem mensagem}")"
    health_blocked proxy-bypass P0 admin-kubeconfig
    return
  fi
  HEALTH_API_CLIENT_READY=true
  health_record admin-kubeconfig P2 HEALTHY kube-apiserver "admin.conf autenticou na API" \
    "file=${KUBECONFIG_ADMIN}"

  if normal_error="$(timeout --signal=TERM "${KUBERNETES_REQUEST_TIMEOUT_SECONDS}s" \
    env NO_PROXY="${DIAGNOSTIC_ORIGINAL_NO_PROXY:-}" \
      no_proxy="${DIAGNOSTIC_ORIGINAL_no_proxy:-}" \
      kubectl --kubeconfig "${KUBECONFIG_ADMIN}" \
        --request-timeout="${KUBERNETES_REQUEST_TIMEOUT_SECONDS}s" \
        get --raw=/readyz 2>&1 >/dev/null)"; then
    HEALTH_API_NORMAL_READY=true
    health_record proxy-bypass P0 HEALTHY admin-kubeconfig \
      "cliente herdado não desvia a API local pelo proxy" "NO_PROXY efetivo"
  elif [[ -r /etc/profile.d/k8s-wsl-no-proxy.sh ]] \
    && grep -Fq "${NODE_IP}" /etc/profile.d/k8s-wsl-no-proxy.sh \
    && [[ -r /etc/systemd/system/containerd.service.d/20-k8s-wsl-no-proxy.conf ]] \
    && grep -Fq "${NODE_IP}" /etc/systemd/system/containerd.service.d/20-k8s-wsl-no-proxy.conf \
    && [[ -r /etc/systemd/system/kubelet.service.d/20-k8s-wsl-no-proxy.conf ]] \
    && grep -Fq "${NODE_IP}" /etc/systemd/system/kubelet.service.d/20-k8s-wsl-no-proxy.conf; then
    health_record proxy-bypass P0 HEALTHY admin-kubeconfig \
      "bypass local está persistido e os clientes do projeto o forçam" \
      "ambiente herdado isolado falhou, mas a padronização gerenciada está presente"
  else
    health_record proxy-bypass P0 FAILED admin-kubeconfig \
      "API direta funciona, mas o ambiente herdado falha sem o bypass padronizado" \
      "$(health_compact_text <<<"${normal_error:-erro sem mensagem}")"
  fi
}

health_probe_daemonset() {
  local component="$1" priority="$2" dependency="$3" namespace="$4" name="$5"
  local counts desired ready updated
  if health_dependency_unavailable "${dependency}"; then
    health_blocked "${component}" "${priority}" "${dependency}"
    return
  fi
  if ! counts="$(health_kubectl -n "${namespace}" get daemonset "${name}" \
    -o jsonpath='{.status.desiredNumberScheduled} {.status.numberReady} {.status.updatedNumberScheduled}' \
    2>/dev/null)"; then
    health_record "${component}" "${priority}" FAILED "${dependency}" \
      "DaemonSet ${namespace}/${name} não foi encontrado" "resource=daemonset/${name}"
    return
  fi
  read -r desired ready updated <<<"${counts}"
  if [[ -n "${desired}" && "${desired}" != "0" && "${desired}" == "${ready}" && "${desired}" == "${updated}" ]]; then
    health_record "${component}" "${priority}" HEALTHY "${dependency}" \
      "DaemonSet está pronto" "desired=${desired} ready=${ready} updated=${updated}"
  else
    health_record "${component}" "${priority}" FAILED "${dependency}" \
      "DaemonSet não está pronto" "desired=${desired:-0} ready=${ready:-0} updated=${updated:-0}"
  fi
}

health_probe_deployment() {
  local component="$1" priority="$2" dependency="$3" namespace="$4" name="$5"
  local counts desired ready updated
  if health_dependency_unavailable "${dependency}"; then
    health_blocked "${component}" "${priority}" "${dependency}"
    return
  fi
  if ! counts="$(health_kubectl -n "${namespace}" get deployment "${name}" \
    -o jsonpath='{.status.replicas} {.status.readyReplicas} {.status.updatedReplicas}' \
    2>/dev/null)"; then
    health_record "${component}" "${priority}" FAILED "${dependency}" \
      "Deployment ${namespace}/${name} não foi encontrado" "resource=deployment/${name}"
    return
  fi
  read -r desired ready updated <<<"${counts}"
  if [[ -n "${desired}" && "${desired}" != "0" && "${desired}" == "${ready}" && "${desired}" == "${updated}" ]]; then
    health_record "${component}" "${priority}" HEALTHY "${dependency}" \
      "Deployment está pronto" "desired=${desired} ready=${ready} updated=${updated}"
  else
    health_record "${component}" "${priority}" FAILED "${dependency}" \
      "Deployment não está pronto" "desired=${desired:-0} ready=${ready:-0} updated=${updated:-0}"
  fi
}

health_probe_node_ready() {
  local ready_status conditions
  if health_dependency_unavailable flannel; then
    health_blocked node-ready P4 flannel
    return
  fi
  if ! ready_status="$(health_kubectl get node "${NODE_NAME}" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"; then
    health_record node-ready P4 FAILED flannel \
      "Node ${NODE_NAME} não foi encontrado na API" "resource=node/${NODE_NAME}"
    return
  fi
  conditions="$(health_kubectl get node "${NODE_NAME}" \
    -o jsonpath='{range .status.conditions[*]}{.type}={.status}:{.reason};{end}' \
    2>/dev/null | health_compact_text || true)"
  if [[ "${ready_status}" == "True" ]]; then
    health_record node-ready P4 HEALTHY flannel "Node está Ready na API" \
      "${conditions:-Ready=True}"
  else
    health_record node-ready P4 FAILED flannel "Node não está Ready na API" \
      "ready=${ready_status:-ausente}; conditions=${conditions:-indisponíveis}"
  fi
}

health_run_checks() {
  health_reset
  health_probe_host
  health_probe_node_ip
  health_probe_containerd
  health_probe_kubelet
  health_probe_certificates
  health_probe_static_manifests
  health_probe_static_container etcd P2 static-manifests
  health_probe_apiserver
  health_probe_api_client
  health_probe_static_container controller-manager P3 kube-apiserver kube-controller-manager
  health_probe_static_container scheduler P3 kube-apiserver kube-scheduler
  if health_dependency_unavailable admin-kubeconfig; then
    health_blocked flannel P4 admin-kubeconfig
  else
    health_probe_daemonset flannel P4 scheduler kube-flannel kube-flannel-ds
  fi
  if [[ "${HEALTH_STATUS[flannel]:-}" == "HEALTHY" && ! -s /run/flannel/subnet.env ]]; then
    health_record flannel P4 FAILED scheduler "Flannel está pronto na API, mas subnet.env está ausente" \
      "file=/run/flannel/subnet.env"
  fi
  health_probe_node_ready
  health_probe_daemonset kube-proxy P4 node-ready kube-system kube-proxy
  health_probe_deployment coredns P4 kube-proxy kube-system coredns
  health_probe_deployment envoy P5 coredns "${ENVOY_GATEWAY_NAMESPACE}" envoy-gateway
  health_probe_deployment headlamp P5 coredns "${DASHBOARD_NAMESPACE}" headlamp
}

health_first_repair_issue() {
  local component status
  for component in "${HEALTH_REPAIR_COMPONENTS[@]}"; do
    status="${HEALTH_STATUS["${component}"]:-UNKNOWN}"
    if [[ "${status}" == "FAILED" || "${status}" == "DEGRADED" || "${status}" == "UNKNOWN" ]]; then
      printf '%s\n' "${component}"
      return 0
    fi
  done
  return 1
}

health_core_healthy() {
  local component
  for component in "${HEALTH_REPAIR_COMPONENTS[@]}"; do
    [[ "${HEALTH_STATUS["${component}"]:-UNKNOWN}" == "HEALTHY" ]] || return 1
  done
}

health_issue_count() {
  local component count=0 status
  for component in "${HEALTH_COMPONENTS[@]}"; do
    status="${HEALTH_STATUS["${component}"]:-UNKNOWN}"
    [[ "${status}" == "HEALTHY" ]] || ((count += 1))
  done
  printf '%s\n' "${count}"
}

health_render_section() {
  local component status priority dependency reason evidence level
  log_event STAGE critical-health priority "Saúde dos serviços prioritários"
  for component in "${HEALTH_COMPONENTS[@]}"; do
    status="${HEALTH_STATUS["${component}"]:-UNKNOWN}"
    priority="${HEALTH_PRIORITY["${component}"]:-P?}"
    dependency="${HEALTH_DEPENDENCY["${component}"]:-none}"
    reason="${HEALTH_REASON["${component}"]:-sem resultado}"
    evidence="${HEALTH_EVIDENCE["${component}"]:-}"
    case "${status}" in
      HEALTHY) level=INFO ;;
      FAILED) level=ERROR ;;
      *) level=WARNING ;;
    esac
    log_event "${level}" "health/${priority}/${component}" "${status,,}" \
      "${reason}; dependency=${dependency}${evidence:+; evidence=${evidence}}"
  done
}

health_capture_failure_evidence() {
  local label="$1" focus="${2:-unknown}" component container_id
  log_event STAGE health-evidence "${label}" \
    "Evidências direcionadas antes da ação; componente=${focus}"

  case "${focus}" in
    host)
      hostnamectl 2>&1 || true
      timedatectl 2>&1 || true
      df -h / 2>&1 || true
      df -ih / 2>&1 || true
      free -h 2>&1 || true
      return
      ;;
    node-ip)
      systemctl --no-pager --full status "${WSL_NODE_IP_SERVICE}" 2>&1 || true
      journalctl -u "${WSL_NODE_IP_SERVICE}" -b --no-pager \
        -n "${DIAGNOSTIC_TAIL_LINES}" 2>&1 || true
      ip -4 address show dev lo 2>&1 || true
      ip route get "${NODE_IP}" 2>&1 || true
      return
      ;;
    containerd)
      systemctl --no-pager --full status containerd.service 2>&1 || true
      journalctl -u containerd.service -b --no-pager \
        -n "${DIAGNOSTIC_TAIL_LINES}" 2>&1 || true
      health_crictl info 2>&1 || true
      health_crictl ps -a 2>&1 || true
      return
      ;;
    flannel|node-ready|kube-proxy|coredns)
      health_kubectl -n kube-flannel get daemonset,pod -o wide 2>&1 || true
      health_kubectl -n kube-system get daemonset/kube-proxy deployment/coredns,pod -o wide 2>&1 || true
      health_kubectl get events -A --field-selector type=Warning \
        --sort-by='.lastTimestamp' 2>&1 | tail -n "${DIAGNOSTIC_TAIL_LINES}" || true
      return
      ;;
  esac

  systemctl --no-pager --full status containerd.service kubelet.service 2>&1 || true
  journalctl -u containerd.service -u kubelet.service -b --no-pager \
    -n "${DIAGNOSTIC_TAIL_LINES}" 2>&1 || true
  ss -H -lntp 2>/dev/null | grep -E ':(2379|2380|6443|10248|10250)([[:space:]]|$)' || true

  if command -v crictl >/dev/null 2>&1 && [[ -S /run/containerd/containerd.sock ]]; then
    health_crictl ps -a 2>&1 || true
    for component in etcd kube-apiserver kube-controller-manager kube-scheduler; do
      container_id="$(health_static_container_ids "${component}" true | head -n 1)"
      [[ -n "${container_id}" ]] || continue
      log_event INFO "evidence/${component}" collected "container_id=${container_id}; últimas linhas"
      health_crictl logs --tail="${DIAGNOSTIC_TAIL_LINES}" "${container_id}" 2>&1 || true
    done
  fi

  if command -v kubeadm >/dev/null 2>&1 && [[ -d /etc/kubernetes/pki ]]; then
    kubeadm certs check-expiration 2>&1 || true
  fi
  curl --noproxy '*' -ksS --connect-timeout 3 \
    --max-time "${KUBERNETES_REQUEST_TIMEOUT_SECONDS}" \
    "https://${NODE_IP}:6443/readyz?verbose" 2>&1 || true
}
