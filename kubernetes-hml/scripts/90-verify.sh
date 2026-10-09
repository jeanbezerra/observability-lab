#!/usr/bin/env bash

# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_root
require_command curl

log "Verificando serviços systemd e a rede real da VM HML."
systemd_is_pid1 || die "systemd não é o PID 1."
for service_name in "${NODE_NETWORK_SERVICE}" containerd kubelet; do
  systemctl is-enabled --quiet "${service_name}" || die "${service_name} não está habilitado."
  systemctl is-active --quiet "${service_name}" || die "${service_name} não está ativo."
done
ip -o -4 address show scope global | awk '{split($4, address, "/"); print address[1]}' \
  | grep -Fxq "${NODE_IP}" || die "IP ${NODE_IP} não está atribuído a uma interface da VM."
grep -Eq '^failSwapOn:[[:space:]]*false[[:space:]]*$' /var/lib/kubelet/config.yaml \
  || die "kubelet não tolera o swap configurado no Ubuntu."
grep -Eq '^[[:space:]]*swapBehavior:[[:space:]]*NoSwap[[:space:]]*$' /var/lib/kubelet/config.yaml \
  || die "Pods não estão protegidos pela política NoSwap."

log "Aguardando nó, kube-proxy, Flannel, DNS e Headlamp."
kube wait --for=condition=Ready nodes --all --timeout="${CLUSTER_OPERATION_TIMEOUT}"
actual_node_ip="$(kube get node "${NODE_NAME}" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')"
[[ "${actual_node_ip}" == "${NODE_IP}" ]] \
  || die "InternalIP do nó ${NODE_NAME} diverge do IP informado: ${actual_node_ip}."
kube rollout status daemonset/kube-proxy -n kube-system \
  --timeout="${CLUSTER_OPERATION_TIMEOUT}"
kube rollout status daemonset/kube-flannel-ds -n kube-flannel \
  --timeout="${CLUSTER_OPERATION_TIMEOUT}"
kube rollout status deployment/coredns -n kube-system \
  --timeout="${CLUSTER_OPERATION_TIMEOUT}"
kube rollout status deployment/headlamp -n "${DASHBOARD_NAMESPACE}" \
  --timeout="${CLUSTER_OPERATION_TIMEOUT}"

log "Verificando versões, TLS, RBAC sem login e Services externos HML."
bash "${SCRIPTS_DIR}/52-install-helm.sh" --check \
  || die "Helm ${HELM_VERSION} não passou na verificação."
bash "${SCRIPTS_DIR}/55-install-gateway.sh" --check \
  || die "Gateway API/Envoy Gateway não passou na verificação."
bash "${SCRIPTS_DIR}/60-install-dashboard.sh" --check \
  || die "Headlamp, certificado, Service ou RBAC não passaram na verificação."
bash "${SCRIPTS_DIR}/70-configure-external-access.sh" --check \
  || die "Headlamp não respondeu via HTTPS no IP da VM com certificado válido."
bash "${SCRIPTS_DIR}/75-configure-gateway-access.sh" --check \
  || die "Service NodePort do Gateway diverge do Envoy ou não responde via HTTP."

# NodePorts são processados por kube-proxy; não precisam de sockets visíveis em ss.
cat <<EOF

Cluster HML Ubuntu 26.04 LTS validado com sucesso.
  Nó/IP:    ${NODE_NAME} / ${NODE_IP}
  Headlamp: https://${HEADLAMP_HOST}:${DASHBOARD_NODE_PORT}/?lng=${DASHBOARD_DEFAULT_LANGUAGE}
  Login:    automático, ServiceAccount headlamp com cluster-admin
  CA:       $(getent passwd "${ADMIN_USER}" | cut -d: -f6)/.kube/headlamp-ca.crt

Gateway API/Envoy Gateway:
  Versões:  Gateway API ${GATEWAY_API_VERSION} Standard; Envoy Gateway ${ENVOY_GATEWAY_VERSION}
  Classe:   ${GATEWAY_CLASS_NAME}
  Gateway:  ${GATEWAY_NAMESPACE}/${GATEWAY_NAME}
  Acesso:   http://${NODE_IP}:${GATEWAY_NODE_PORT} (HTTP 404 é normal sem rotas)
  Service:  hml-gateway-external NodePort; Service do controller preservado como ClusterIP

O acesso de outra máquina depende da conectividade com a VM e da liberação das
portas TCP/${DASHBOARD_NODE_PORT} e TCP/${GATEWAY_NODE_PORT} na rede externa.
EOF
