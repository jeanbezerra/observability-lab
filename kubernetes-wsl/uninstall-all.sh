#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_ARGUMENT=""
UNINSTALL_MODE=""

usage() {
  cat >&2 <<EOF
Uso:
  sudo bash $0 [cluster.env] --dry-run
  sudo bash $0 [cluster.env] --yes

  --dry-run  mostra exatamente o que seria removido, sem alterar o cluster
  --yes      confirma a remoção do estado/configuração e das imagens Kubernetes
EOF
}

if [[ "${EUID}" -ne 0 ]]; then
  printf 'ERRO: execute dentro do Ubuntu WSL com sudo.\n' >&2
  usage
  exit 1
fi

for argument in "$@"; do
  case "${argument}" in
    --dry-run|--yes)
      if [[ -n "${UNINSTALL_MODE}" ]]; then
        printf 'ERRO: informe somente um entre --dry-run e --yes.\n' >&2
        usage
        exit 2
      fi
      UNINSTALL_MODE="${argument}"
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --*)
      printf 'ERRO: opção desconhecida: %s\n' "${argument}" >&2
      usage
      exit 2
      ;;
    *)
      if [[ -n "${CONFIG_ARGUMENT}" ]]; then
        printf 'ERRO: informe no máximo um cluster.env.\n' >&2
        usage
        exit 2
      fi
      CONFIG_ARGUMENT="${argument}"
      ;;
  esac
done

if [[ -z "${UNINSTALL_MODE}" ]]; then
  printf 'ERRO: a confirmação explícita --dry-run ou --yes é obrigatória.\n' >&2
  usage
  exit 2
fi

if [[ -n "${CONFIG_ARGUMENT}" ]]; then
  K8S_CONFIG_FILE="$(realpath -- "${CONFIG_ARGUMENT}")"
  export K8S_CONFIG_FILE
fi

# shellcheck source=scripts/lib/common.sh
source "${ROOT_DIR}/scripts/lib/common.sh"

for service_variable in WSL_NODE_IP_SERVICE HEADLAMP_FORWARD_SERVICE GATEWAY_FORWARD_SERVICE; do
  service_name="${!service_variable}"
  [[ "${service_name}" =~ ^[A-Za-z0-9_.@-]+\.service$ ]] \
    || die "${service_variable} contém um nome de unidade systemd inseguro: ${service_name}."
done
valid_ipv4 "${NODE_IP}" || die "NODE_IP inválido: ${NODE_IP}."

if [[ "${UNINSTALL_MODE}" == "--yes" ]]; then
  LOG_KIND="uninstall"
else
  LOG_KIND="uninstall-dry-run"
fi
start_persistent_log "${LOG_KIND}"

UNINSTALL_COMPLETED=false
CURRENT_PHASE="startup"

on_uninstall_exit() {
  local exit_code="$1"
  trap - EXIT ERR
  if is_true "${UNINSTALL_COMPLETED}"; then
    log_event INFO uninstaller success \
      "mode=${UNINSTALL_MODE} log=${BOOTSTRAP_LOG_FILE}"
  else
    log_event ERROR uninstaller failed \
      "mode=${UNINSTALL_MODE} phase=${CURRENT_PHASE} codigo=${exit_code} log=${BOOTSTRAP_LOG_FILE}"
  fi
  finish_persistent_log
  exit "${exit_code}"
}

trap 'on_uninstall_exit "$?"' EXIT

if command -v flock >/dev/null 2>&1; then
  exec 9>/run/lock/k8s-wsl-bootstrap.lock
  flock -n 9 || die "já existe uma instalação ou remoção do cluster em andamento."
fi

DRY_RUN=true
[[ "${UNINSTALL_MODE}" == "--yes" ]] && DRY_RUN=false

remove_file() {
  local target="$1"
  if [[ ! -e "${target}" && ! -L "${target}" ]]; then
    log_event INFO cleanup skipped "ausente: ${target}"
    return 0
  fi
  log_event INFO cleanup removing "arquivo=${target}"
  if ! is_true "${DRY_RUN}"; then
    rm -f -- "${target}"
  fi
}

safe_remove_tree() {
  local requested_target="$1" resolved_target
  resolved_target="$(realpath -m -- "${requested_target}")"
  case "${resolved_target}" in
    /etc/kubernetes|/var/lib/etcd|/var/lib/kubelet|/var/lib/cni|/run/flannel|/var/lib/k8s-wsl-bootstrap/steps) ;;
    *) die "recusa de segurança ao remover diretório não autorizado: ${requested_target} -> ${resolved_target}." ;;
  esac
  if [[ ! -e "${resolved_target}" && ! -L "${resolved_target}" ]]; then
    log_event INFO cleanup skipped "ausente: ${resolved_target}"
    return 0
  fi
  log_event INFO cleanup removing "diretorio=${resolved_target}"
  if ! is_true "${DRY_RUN}"; then
    rm -rf --one-file-system -- "${resolved_target}"
  fi
}

disable_service() {
  local service_name="$1" enabled_state active_state
  enabled_state="$(systemctl is-enabled "${service_name}" 2>/dev/null || true)"
  active_state="$(systemctl is-active "${service_name}" 2>/dev/null || true)"
  log_event INFO "systemd/${service_name}" stopping \
    "enabled=${enabled_state:-unknown} active=${active_state:-unknown}"
  if ! is_true "${DRY_RUN}"; then
    systemctl disable --now "${service_name}" >/dev/null 2>&1 || true
  fi
}

is_installer_kubeconfig() {
  local candidate="$1"
  [[ -r "${candidate}" ]] || return 1
  if [[ -r "${KUBECONFIG_ADMIN}" ]] && cmp -s "${candidate}" "${KUBECONFIG_ADMIN}"; then
    return 0
  fi
  grep -Fq "server: https://${NODE_IP}:6443" "${candidate}" \
    && grep -Eq '^current-context:[[:space:]]+kubernetes-admin@kubernetes[[:space:]]*$' "${candidate}"
}

validate_target_identity() {
  local marker_found=false cluster_state_found=false existing_node_ip actual_nodes
  local node_ip_unit="/etc/systemd/system/${WSL_NODE_IP_SERVICE}"

  if [[ -r "${node_ip_unit}" ]] \
    && grep -Fq 'Stable loopback address for the local Kubernetes node on WSL 2' "${node_ip_unit}" \
    && grep -Fq "${NODE_IP}/32" "${node_ip_unit}"; then
    marker_found=true
  fi
  if [[ -d "${BOOTSTRAP_STATE_DIR}/steps" ]]; then
    marker_found=true
  fi

  if [[ -r /etc/kubernetes/manifests/kube-apiserver.yaml ]]; then
    cluster_state_found=true
    existing_node_ip="$(sed -n 's/^[[:space:]]*-[[:space:]]*--advertise-address=//p' \
      /etc/kubernetes/manifests/kube-apiserver.yaml | head -n 1)"
    [[ -z "${existing_node_ip}" || "${existing_node_ip}" == "${NODE_IP}" ]] \
      || die "o control plane encontrado usa ${existing_node_ip}, mas cluster.env define NODE_IP=${NODE_IP}; remoção recusada."
  fi
  if [[ -d /var/lib/etcd/member || -r "${KUBECONFIG_ADMIN}" ]]; then
    cluster_state_found=true
  fi

  if [[ -r "${KUBECONFIG_ADMIN}" ]] \
    && command -v kubectl >/dev/null 2>&1 \
    && actual_nodes="$(kubectl --kubeconfig "${KUBECONFIG_ADMIN}" \
      --request-timeout="${KUBERNETES_REQUEST_TIMEOUT_SECONDS}s" \
      get nodes -o name 2>/dev/null)"; then
    grep -Fxq "node/${NODE_NAME}" <<<"${actual_nodes}" \
      || die "o cluster ativo não contém NODE_NAME=${NODE_NAME}; remoção recusada."
  fi

  if is_true "${cluster_state_found}" && ! is_true "${marker_found}"; then
    die "há estado Kubernetes, mas nenhum marcador de kubernetes-wsl foi encontrado; remoção recusada por segurança."
  fi
  log_event INFO safety target-validated \
    "project_marker=${marker_found} cluster_state=${cluster_state_found} node=${NODE_NAME}/${NODE_IP}"
}

count_cri_images() {
  local image_ids
  command -v crictl >/dev/null 2>&1 || { printf 'indisponível\n'; return 0; }
  if ! image_ids="$(crictl --runtime-endpoint=unix:///run/containerd/containerd.sock \
    --image-endpoint=unix:///run/containerd/containerd.sock \
    --timeout="${KUBERNETES_REQUEST_TIMEOUT_SECONDS}s" images -q 2>/dev/null)"; then
    printf 'indisponível\n'
    return 0
  fi
  if [[ -z "${image_ids}" ]]; then
    printf '0\n'
  else
    sort -u <<<"${image_ids}" | awk 'END {print NR}'
  fi
}

cleanup_cri() {
  local endpoint="unix:///run/containerd/containerd.sock"
  local remaining_images=() image_references=()
  if ! command -v crictl >/dev/null 2>&1; then
    die "crictl não está disponível; não é possível confirmar a limpeza das imagens Kubernetes."
  fi
  if [[ ! -S /run/containerd/containerd.sock ]]; then
    log_event WARNING containerd starting "socket ausente; tentando iniciar o runtime preservado"
    systemctl start containerd
  fi
  [[ -S /run/containerd/containerd.sock ]] \
    || die "containerd não iniciou; as imagens Kubernetes não puderam ser removidas."

  log_event INFO cri cleanup "removendo containers e sandboxes do namespace CRI"
  crictl --runtime-endpoint="${endpoint}" --timeout="${KUBERNETES_REQUEST_TIMEOUT_SECONDS}s" \
    rm --all --force || warn "alguns containers CRI já estavam ausentes ou não puderam ser removidos."
  crictl --runtime-endpoint="${endpoint}" --timeout="${KUBERNETES_REQUEST_TIMEOUT_SECONDS}s" \
    rmp --all --force || warn "alguns sandboxes CRI já estavam ausentes ou não puderam ser removidos."
  crictl --runtime-endpoint="${endpoint}" --image-endpoint="${endpoint}" \
    --timeout="${KUBERNETES_REQUEST_TIMEOUT_SECONDS}s" rmi --all \
    || warn "a primeira tentativa de remover todas as imagens CRI não foi completa."

  mapfile -t remaining_images < <(
    crictl --runtime-endpoint="${endpoint}" --image-endpoint="${endpoint}" \
      --timeout="${KUBERNETES_REQUEST_TIMEOUT_SECONDS}s" images -q 2>/dev/null | sort -u
  )
  if (( ${#remaining_images[@]} > 0 )) && command -v ctr >/dev/null 2>&1; then
    log_event WARNING cri retry \
      "${#remaining_images[@]} imagens ainda registradas; removendo referências do namespace k8s.io"
    mapfile -t image_references < <(ctr --namespace k8s.io images list -q 2>/dev/null || true)
    if (( ${#image_references[@]} > 0 )); then
      ctr --namespace k8s.io images remove "${image_references[@]}" || true
    fi
    mapfile -t remaining_images < <(
      crictl --runtime-endpoint="${endpoint}" --image-endpoint="${endpoint}" \
        --timeout="${KUBERNETES_REQUEST_TIMEOUT_SECONDS}s" images -q 2>/dev/null | sort -u
    )
  fi
  (( ${#remaining_images[@]} == 0 )) \
    || die "a limpeza terminou com ${#remaining_images[@]} imagens ainda registradas no CRI."
  log_event INFO cri cleaned "nenhuma imagem permanece registrada no runtime Kubernetes"
}

admin_home="$(getent passwd "${ADMIN_USER}" | cut -d: -f6)"
root_home="$(getent passwd root | cut -d: -f6)"
[[ -n "${admin_home}" && "${admin_home}" == /* && "${admin_home}" != "/" ]] \
  || die "home inseguro ou ausente para ADMIN_USER=${ADMIN_USER}."
[[ -n "${root_home}" && "${root_home}" == /* && "${root_home}" != "/" ]] \
  || die "home inseguro ou ausente para o usuário root."

admin_kubeconfig="${admin_home}/.kube/config"
root_kubeconfig="${root_home}/.kube/config"
admin_kubeconfig_managed=false
root_kubeconfig_managed=false
is_installer_kubeconfig "${admin_kubeconfig}" && admin_kubeconfig_managed=true
is_installer_kubeconfig "${root_kubeconfig}" && root_kubeconfig_managed=true

validate_target_identity

log_event INFO uninstaller plan \
  "config=${K8S_CONFIG_FILE:-${ROOT_DIR}/cluster.env} node=${NODE_NAME}/${NODE_IP} cri_images=$(count_cri_images)"
cat <<EOF

Será removido:
  - estado kubeadm, control plane, etcd, kubelet, CNI e Flannel;
  - unidades systemd e arquivos auxiliares criados por kubernetes-wsl;
  - kubeconfigs/CA reconhecidos como cópias deste cluster;
  - configuração específica do crictl e do repositório Kubernetes;
  - todos os containers, sandboxes e imagens gerenciados pelo CRI/containerd k8s.io.

Será preservado:
  - todos os pacotes APT, inclusive kubelet, kubeadm, kubectl, CNI e containerd;
  - configuração geral, serviço e dados não Kubernetes do containerd;
  - Helm, holds do APT, offline-cache, backups e logs de auditoria;
  - configurações do Linux não pertencentes a este projeto.

Alvos específicos de configuração/estado:
  /etc/kubernetes
  /var/lib/etcd
  /var/lib/kubelet
  /var/lib/cni
  /run/flannel
  /etc/cni/net.d/10-flannel.conflist
  /etc/systemd/system/${WSL_NODE_IP_SERVICE}
  /etc/systemd/system/${HEADLAMP_FORWARD_SERVICE}
  /etc/systemd/system/${GATEWAY_FORWARD_SERVICE}
  /etc/systemd/system/kubelet.service.d/05-k8s-wsl-node-ip.conf
  /etc/sysctl.d/99-kubernetes-wsl.conf
  /usr/local/sbin/k8s-gateway-local-forward
  /etc/crictl.yaml
  /etc/apt/sources.list.d/kubernetes.list[.disabled]
  /etc/apt/keyrings/kubernetes-apt-keyring.gpg
EOF

if is_true "${DRY_RUN}"; then
  log_event INFO uninstaller dry-run "nenhuma alteração foi realizada"
  UNINSTALL_COMPLETED=true
  exit 0
fi

CURRENT_PHASE="stop-services"
disable_service "${HEADLAMP_FORWARD_SERVICE}"
disable_service "${GATEWAY_FORWARD_SERVICE}"
disable_service kubelet.service

CURRENT_PHASE="kubeadm-reset"
if command -v kubeadm >/dev/null 2>&1; then
  log_event INFO kubeadm resetting "executando reset controlado do nó"
  if ! kubeadm reset --force --cleanup-tmp-dir \
    --cri-socket unix:///run/containerd/containerd.sock; then
    warn "kubeadm reset não concluiu; a limpeza explícita continuará sobre os alvos conhecidos."
  fi
else
  warn "kubeadm não está disponível; a limpeza explícita continuará."
fi

CURRENT_PHASE="runtime-cleanup"
cleanup_cri

CURRENT_PHASE="network-cleanup"
disable_service "${WSL_NODE_IP_SERVICE}"
ip address del "${NODE_IP}/32" dev lo >/dev/null 2>&1 || true
for network_interface in flannel.1 cni0; do
  if ip link show "${network_interface}" >/dev/null 2>&1; then
    log_event INFO network removing "interface=${network_interface}"
    ip link delete "${network_interface}"
  fi
done

CURRENT_PHASE="configuration-cleanup"
remove_file "/etc/systemd/system/${HEADLAMP_FORWARD_SERVICE}"
remove_file "/etc/systemd/system/${GATEWAY_FORWARD_SERVICE}"
remove_file "/etc/systemd/system/${WSL_NODE_IP_SERVICE}"
remove_file "/etc/systemd/system/kubelet.service.d/05-k8s-wsl-node-ip.conf"
remove_file "/etc/sysctl.d/99-kubernetes-wsl.conf"
remove_file "/usr/local/sbin/k8s-gateway-local-forward"
remove_file "/etc/crictl.yaml"
remove_file "/etc/apt/sources.list.d/kubernetes.list"
remove_file "/etc/apt/sources.list.d/kubernetes.list.disabled"
remove_file "/etc/apt/keyrings/kubernetes-apt-keyring.gpg"
remove_file "/etc/cni/net.d/10-flannel.conflist"
remove_file "/etc/cni/net.d/10-flannel.conf"

if is_true "${admin_kubeconfig_managed}"; then
  remove_file "${admin_kubeconfig}"
elif [[ -e "${admin_kubeconfig}" ]]; then
  warn "${admin_kubeconfig} não foi reconhecido como cópia deste cluster e foi preservado."
fi
remove_file "${admin_home}/.kube/headlamp-ca.crt"

if is_true "${root_kubeconfig_managed}"; then
  remove_file "${root_kubeconfig}"
elif [[ -e "${root_kubeconfig}" ]]; then
  warn "${root_kubeconfig} não foi reconhecido como cópia deste cluster e foi preservado."
fi

safe_remove_tree /etc/kubernetes
safe_remove_tree /var/lib/etcd
safe_remove_tree /var/lib/kubelet
safe_remove_tree /var/lib/cni
safe_remove_tree /run/flannel

if [[ "$(realpath -m -- "${BOOTSTRAP_STATE_DIR}")" == "/var/lib/k8s-wsl-bootstrap" ]]; then
  safe_remove_tree /var/lib/k8s-wsl-bootstrap/steps
  remove_file /var/lib/k8s-wsl-bootstrap/last-successful-step
  remove_file /var/lib/k8s-wsl-bootstrap/kubeadm-init.log
else
  warn "BOOTSTRAP_STATE_DIR customizado foi preservado por segurança: ${BOOTSTRAP_STATE_DIR}."
fi

systemctl daemon-reload
systemctl reset-failed kubelet.service "${HEADLAMP_FORWARD_SERVICE}" \
  "${GATEWAY_FORWARD_SERVICE}" "${WSL_NODE_IP_SERVICE}" >/dev/null 2>&1 || true

CURRENT_PHASE="verification"
for removed_tree in /etc/kubernetes /var/lib/etcd /var/lib/kubelet /var/lib/cni /run/flannel; do
  [[ ! -e "${removed_tree}" ]] || die "o diretório ainda existe após a limpeza: ${removed_tree}."
done
systemctl is-active --quiet kubelet.service \
  && die "kubelet ainda está ativo após a limpeza."
[[ "$(count_cri_images)" == "0" ]] \
  || die "a verificação final ainda encontrou imagens no runtime Kubernetes."

log_event INFO uninstaller completed \
  "estado Kubernetes removido; pacotes Linux, containerd, Helm, cache, backups e logs preservados"
printf '\nAmbiente Kubernetes resetado. Log completo: %s\n' "${BOOTSTRAP_LOG_FILE}"
printf 'Para recriar o cluster: sudo bash install-all.sh cluster.env\n'
UNINSTALL_COMPLETED=true
