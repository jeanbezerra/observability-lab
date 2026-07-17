#!/usr/bin/env bash

# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_root
require_command kubeadm
require_command kubectl

node_ip="$(detect_node_ip)"
node_name="$(effective_node_name)"

api_server_ready() {
  [[ -r "${KUBECONFIG_ADMIN}" ]] \
    && kube --request-timeout=5s get --raw=/readyz >/dev/null 2>&1
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
  [[ "${internal_ip}" == "${node_ip}" ]]
}

cluster_state_ok() {
  local admin_home
  [[ -r "${KUBECONFIG_ADMIN}" ]] || {
    check_pending "cluster ainda não possui ${KUBECONFIG_ADMIN}."
    return 1
  }
  api_server_ready || {
    check_pending "API Server não está pronto."
    return 1
  }
  cluster_settings_ok || {
    check_pending "nome/IP do nó ou CIDRs imutáveis diferem da configuração do cluster existente."
    return 1
  }
  id "${ADMIN_USER}" >/dev/null 2>&1 || {
    check_pending "usuário ${ADMIN_USER} não existe."
    return 1
  }
  admin_home="$(getent passwd "${ADMIN_USER}" | cut -d: -f6)"
  [[ -r "${admin_home}/.kube/config" ]] \
    && cmp -s "${KUBECONFIG_ADMIN}" "${admin_home}/.kube/config" || {
      check_pending "kubeconfig de ${ADMIN_USER} está ausente ou desatualizado."
      return 1
    }
  [[ "$(stat -c '%U:%a' "${admin_home}/.kube/config" 2>/dev/null)" == "${ADMIN_USER}:600" ]] || {
    check_pending "dono ou modo do kubeconfig de ${ADMIN_USER} está incorreto."
    return 1
  }
  if is_true "${SINGLE_NODE}"; then
    if kube get node "${node_name}" -o jsonpath='{.spec.taints[*].key}' 2>/dev/null \
      | tr ' ' '\n' | grep -Eq '^node-role\.kubernetes\.io/(control-plane|master)$'; then
      check_pending "control plane ainda possui taint que impede workloads no cluster de nó único."
      return 1
    fi
  fi
}

if check_requested "${1:-}"; then
  if cluster_state_ok; then
    exit 0
  fi
  exit 1
fi

ensure_state_dir

if [[ -r "${KUBECONFIG_ADMIN}" ]]; then
  log "Cluster já inicializado; validando o control plane existente."
  if ! api_server_ready; then
    warn "API Server existente não respondeu; reiniciando apenas containerd e kubelet antes de uma nova tentativa."
    systemctl restart containerd
    systemctl restart kubelet
    if ! retry 20 3 api_server_ready; then
      systemctl --no-pager --full status containerd kubelet >&2 || true
      journalctl -u kubelet --no-pager -n 100 >&2 || true
      die "o cluster possui ${KUBECONFIG_ADMIN}, mas o API Server não voltou. O instalador preservou o cluster e não executou kubeadm reset."
    fi
  fi
  cluster_settings_ok \
    || die "NODE_NAME, NODE_IP, POD_NETWORK_CIDR ou SERVICE_CIDR difere do cluster já inicializado. Esses campos não serão alterados nem resetados automaticamente. Restaure os valores usados na criação ou planeje uma migração."
else
  partial_cluster=false
  [[ -f /etc/kubernetes/manifests/kube-apiserver.yaml ]] && partial_cluster=true
  [[ -d /var/lib/etcd/member ]] && partial_cluster=true

  if is_true "${partial_cluster}"; then
    if ! is_true "${AUTO_REPAIR_PARTIAL_CLUSTER}"; then
      die "resíduos de uma inicialização interrompida foram encontrados. Ative AUTO_REPAIR_PARTIAL_CLUSTER=true para permitir o kubeadm reset desse estado parcial."
    fi
    if command -v curl >/dev/null 2>&1 \
      && retry 5 3 curl -ksS --connect-timeout 3 --max-time 5 \
        -o /dev/null https://127.0.0.1:6443/readyz; then
      die "o API Server local está respondendo sem admin.conf. O instalador não resetará um control plane potencialmente ativo; recupere ${KUBECONFIG_ADMIN} a partir do backup antes de continuar."
    fi
    warn "estado parcial sem admin.conf detectado; salvando configuração e executando kubeadm reset antes de reiniciar o bootstrap."
    install -d -o root -g root -m 0700 "${BOOTSTRAP_STATE_DIR}/backups"
    if [[ -d /etc/kubernetes ]]; then
      tar -C / -czf "${BOOTSTRAP_STATE_DIR}/backups/partial-kubernetes.$(date '+%Y%m%d%H%M%S').tar.gz" \
        etc/kubernetes
    fi
    kubeadm reset -f --cri-socket unix:///run/containerd/containerd.sock
    rm -f -- /etc/cni/net.d/10-flannel.conflist /etc/cni/net.d/10-flannel.conf
  fi

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

cluster_state_ok || die "o bootstrap terminou, mas o estado do cluster ainda está incompleto."
log "Control plane inicializado e kubeconfig entregue a ${ADMIN_USER}."
