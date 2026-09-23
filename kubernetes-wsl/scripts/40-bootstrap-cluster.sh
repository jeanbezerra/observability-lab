#!/usr/bin/env bash

# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_root
require_command kubeadm
require_command kubectl

node_ip="$(detect_node_ip)"
node_name="$(effective_node_name)"
kubernetes_version="$(kubeadm version -o short)"

api_server_ready() {
  [[ -r "${KUBECONFIG_ADMIN}" ]] \
    && kube --request-timeout=5s get --raw=/readyz >/dev/null 2>&1
}

kubelet_settings_ok() {
  [[ -r /var/lib/kubelet/config.yaml ]] || return 1
  grep -Eq '^cgroupDriver:[[:space:]]*systemd[[:space:]]*$' /var/lib/kubelet/config.yaml \
    && grep -Eq '^failSwapOn:[[:space:]]*false[[:space:]]*$' /var/lib/kubelet/config.yaml \
    && grep -Eq '^[[:space:]]*swapBehavior:[[:space:]]*NoSwap[[:space:]]*$' /var/lib/kubelet/config.yaml \
    && grep -Fq -- "--node-ip=${node_ip}" /var/lib/kubelet/kubeadm-flags.env
}

cluster_settings_ok() {
  local cluster_configuration internal_ip
  cluster_configuration="$(kube -n kube-system get configmap kubeadm-config \
    -o jsonpath='{.data.ClusterConfiguration}' 2>/dev/null)"
  grep -Eq "^[[:space:]]*podSubnet:[[:space:]]*['\"]?${POD_NETWORK_CIDR//./\.}['\"]?[[:space:]]*$" \
    <<<"${cluster_configuration}" || return 1
  grep -Eq "^[[:space:]]*serviceSubnet:[[:space:]]*['\"]?${SERVICE_CIDR//./\.}['\"]?[[:space:]]*$" \
    <<<"${cluster_configuration}" || return 1
  internal_ip="$(kube get node "${node_name}" \
    -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)"
  [[ "${internal_ip}" == "${node_ip}" ]] || return 1
  grep -Fq -- "--advertise-address=${node_ip}" /etc/kubernetes/manifests/kube-apiserver.yaml \
    || return 1
  kubelet_settings_ok
}

cluster_state_ok() {
  local admin_home root_home
  [[ -r "${KUBECONFIG_ADMIN}" ]] || {
    check_pending "cluster ainda não possui ${KUBECONFIG_ADMIN}."
    return 1
  }
  api_server_ready || {
    check_pending "API Server não está pronto."
    return 1
  }
  cluster_settings_ok || {
    check_pending "nome/IP estável, CIDRs ou configuração de swap do cluster divergem."
    return 1
  }
  admin_home="$(getent passwd "${ADMIN_USER}" | cut -d: -f6)"
  if [[ -z "${admin_home}" || ! -r "${admin_home}/.kube/config" ]] \
    || ! cmp -s "${KUBECONFIG_ADMIN}" "${admin_home}/.kube/config"; then
      check_pending "kubeconfig de ${ADMIN_USER} está ausente ou desatualizado."
      return 1
  fi
  [[ "$(stat -c '%U:%a' "${admin_home}/.kube/config" 2>/dev/null)" == "${ADMIN_USER}:600" ]] || {
    check_pending "dono ou modo do kubeconfig de ${ADMIN_USER} está incorreto."
    return 1
  }
  root_home="$(getent passwd root | cut -d: -f6)"
  [[ -n "${root_home}" && -r "${root_home}/.kube/config" ]] \
    && cmp -s "${KUBECONFIG_ADMIN}" "${root_home}/.kube/config" || return 1
  if is_true "${SINGLE_NODE}"; then
    if kube get node "${node_name}" -o jsonpath='{.spec.taints[*].key}' 2>/dev/null \
      | tr ' ' '\n' | grep -Eq '^node-role\.kubernetes\.io/(control-plane|master)$'; then
      check_pending "control plane ainda possui taint que impede workloads no nó único."
      return 1
    fi
  fi
}

render_kubeadm_config() {
  cat <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: "${node_ip}"
  bindPort: 6443
nodeRegistration:
  name: "${node_name}"
  criSocket: unix:///run/containerd/containerd.sock
  ignorePreflightErrors:
    - Swap
  kubeletExtraArgs:
    - name: node-ip
      value: "${node_ip}"
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: "${kubernetes_version}"
apiServer:
  certSANs:
    - "${node_ip}"
    - "${node_name}"
    - "localhost"
    - "127.0.0.1"
networking:
  podSubnet: "${POD_NETWORK_CIDR}"
  serviceSubnet: "${SERVICE_CIDR}"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
failSwapOn: false
memorySwap:
  swapBehavior: NoSwap
shutdownGracePeriod: 30s
shutdownGracePeriodCriticalPods: 15s
EOF
}

if check_requested "${1:-}"; then
  if cluster_state_ok; then
    exit 0
  fi
  exit 1
fi

ensure_state_dir
systemctl is-active --quiet "${WSL_NODE_IP_SERVICE}" \
  || die "${WSL_NODE_IP_SERVICE} precisa estar ativo antes do bootstrap."
ip -4 address show dev lo | grep -Fq "${node_ip}/32" \
  || die "o endereço estável ${node_ip}/32 não está ativo."

if [[ -r "${KUBECONFIG_ADMIN}" ]]; then
  log "Cluster já inicializado; validando o control plane existente."
  if ! api_server_ready; then
    warn "API Server não respondeu; reiniciando containerd e kubelet uma vez."
    systemctl restart containerd
    systemctl restart kubelet
    if ! retry 20 3 api_server_ready; then
      systemctl --no-pager --full status containerd kubelet >&2 || true
      journalctl -u kubelet --no-pager -n 100 >&2 || true
      die "o cluster existente não voltou; ele foi preservado e kubeadm reset não foi executado."
    fi
  fi
  cluster_settings_ok \
    || die "o cluster existente não usa NODE_IP=${node_ip}, NODE_NAME=${node_name}, os CIDRs ou a política de swap esperada. Esses campos imutáveis não serão alterados automaticamente."
else
  partial_cluster=false
  [[ -f /etc/kubernetes/manifests/kube-apiserver.yaml ]] && partial_cluster=true
  [[ -d /var/lib/etcd/member ]] && partial_cluster=true

  if is_true "${partial_cluster}"; then
    is_true "${AUTO_REPAIR_PARTIAL_CLUSTER}" \
      || die "há resíduos de kubeadm init. Ative AUTO_REPAIR_PARTIAL_CLUSTER=true para reparar esse estado parcial."
    if retry 5 3 curl -ksS --connect-timeout 3 --max-time 5 \
      -o /dev/null "https://${node_ip}:6443/readyz"; then
      die "a API responde sem admin.conf; o instalador não resetará um control plane possivelmente ativo."
    fi
    warn "estado parcial sem admin.conf detectado; salvando /etc/kubernetes antes do reset controlado."
    install -d -o root -g root -m 0700 "${BOOTSTRAP_STATE_DIR}/backups"
    if [[ -d /etc/kubernetes ]]; then
      tar -C / -czf "${BOOTSTRAP_STATE_DIR}/backups/partial-kubernetes.$(date '+%Y%m%d%H%M%S').tar.gz" \
        etc/kubernetes
    fi
    kubeadm reset -f --cri-socket unix:///run/containerd/containerd.sock
    rm -f -- /etc/cni/net.d/10-flannel.conflist /etc/cni/net.d/10-flannel.conf
  fi

  kubeadm_config="$(mktemp)"
  trap 'rm -f -- "${kubeadm_config}"' EXIT
  render_kubeadm_config >"${kubeadm_config}"
  chmod 0600 "${kubeadm_config}"
  log "Inicializando o control plane ${node_name} no endereço estável ${node_ip}."
  kubeadm init --config "${kubeadm_config}" \
    | tee "${BOOTSTRAP_STATE_DIR}/kubeadm-init.log"
  chmod 0600 "${BOOTSTRAP_STATE_DIR}/kubeadm-init.log"
fi

retry 20 3 kube get --raw=/readyz >/dev/null || die "API Server não ficou pronto."

primary_group="$(id -gn "${ADMIN_USER}")"
admin_home="$(getent passwd "${ADMIN_USER}" | cut -d: -f6)"
[[ -n "${admin_home}" ]] || die "home de ${ADMIN_USER} não encontrado."
install -d -o "${ADMIN_USER}" -g "${primary_group}" -m 0700 "${admin_home}/.kube"
install -o "${ADMIN_USER}" -g "${primary_group}" -m 0600 \
  "${KUBECONFIG_ADMIN}" "${admin_home}/.kube/config"

root_home="$(getent passwd root | cut -d: -f6)"
[[ -n "${root_home}" ]] || die "home do usuário root não encontrado."
install -d -o root -g root -m 0700 "${root_home}/.kube"
install -o root -g root -m 0600 "${KUBECONFIG_ADMIN}" "${root_home}/.kube/config"

if is_true "${SINGLE_NODE}"; then
  kube taint nodes --all node-role.kubernetes.io/control-plane- >/dev/null 2>&1 || true
  kube taint nodes --all node-role.kubernetes.io/master- >/dev/null 2>&1 || true
fi

cluster_state_ok || die "o bootstrap terminou, mas o estado do cluster ainda está incompleto."
log "Control plane WSL inicializado; swap do host foi tolerado sem disponibilizá-lo aos Pods."
