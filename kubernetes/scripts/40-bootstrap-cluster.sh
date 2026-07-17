#!/usr/bin/env bash

# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_root
require_command kubeadm
require_command kubectl
ensure_state_dir

node_ip="$(detect_node_ip)"
node_name="$(effective_node_name)"

if [[ ! -f "${KUBECONFIG_ADMIN}" ]]; then
  log "Inicializando o control plane ${node_name} em ${node_ip}."
  extra_sans=("${node_ip}" "${node_name}")
  [[ -z "${DASHBOARD_PUBLIC_IP}" ]] || extra_sans+=("${DASHBOARD_PUBLIC_IP}")
  [[ -z "${DASHBOARD_DNS_NAME}" ]] || extra_sans+=("${DASHBOARD_DNS_NAME}")
  sans_csv="$(IFS=,; printf '%s' "${extra_sans[*]}")"

  kubeadm init \
    --node-name "${node_name}" \
    --apiserver-advertise-address "${node_ip}" \
    --apiserver-cert-extra-sans "${sans_csv}" \
    --pod-network-cidr "${POD_NETWORK_CIDR}" \
    --service-cidr "${SERVICE_CIDR}" \
    --cri-socket unix:///run/containerd/containerd.sock \
    | tee "${BOOTSTRAP_STATE_DIR}/kubeadm-init.log"
  chmod 0600 "${BOOTSTRAP_STATE_DIR}/kubeadm-init.log"
else
  log "Cluster já inicializado; preservando ${KUBECONFIG_ADMIN}."
fi

retry 20 3 kube get --raw=/readyz >/dev/null || die "API Server não ficou pronto."

primary_group="$(id -gn "${ADMIN_USER}")"
admin_home="$(getent passwd "${ADMIN_USER}" | cut -d: -f6)"
[[ -n "${admin_home}" ]] || die "home do usuário ${ADMIN_USER} não encontrado."
install -d -o "${ADMIN_USER}" -g "${primary_group}" -m 0700 "${admin_home}/.kube"
install -o "${ADMIN_USER}" -g "${primary_group}" -m 0600 "${KUBECONFIG_ADMIN}" "${admin_home}/.kube/config"

if is_true "${SINGLE_NODE}"; then
  log "Liberando o control plane para executar workloads (cluster de nó único)."
  kube taint nodes --all node-role.kubernetes.io/control-plane- >/dev/null 2>&1 || true
  kube taint nodes --all node-role.kubernetes.io/master- >/dev/null 2>&1 || true
fi

log "Control plane inicializado e kubeconfig entregue a ${ADMIN_USER}."

