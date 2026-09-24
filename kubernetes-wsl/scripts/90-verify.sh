#!/usr/bin/env bash

# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_root
require_command curl

networking_mode="$(wsl_networking_mode)" || die "não foi possível identificar a rede do WSL."
[[ "${networking_mode}" == "mirrored" ]] \
  || die "a rede do WSL mudou para ${networking_mode}; esperado: mirrored."

log "Verificando serviços systemd do WSL e do Kubernetes."
systemd_is_pid1 || die "systemd não é o PID 1."
for service_name in "${WSL_NODE_IP_SERVICE}" containerd kubelet "${HEADLAMP_FORWARD_SERVICE}"; do
  systemctl is-enabled --quiet "${service_name}" || die "${service_name} não está habilitado."
  systemctl is-active --quiet "${service_name}" || die "${service_name} não está ativo."
done

ip -4 address show dev lo | grep -Fq "${NODE_IP}/32" \
  || die "endereço estável ${NODE_IP}/32 está ausente."
grep -Eq '^failSwapOn:[[:space:]]*false[[:space:]]*$' /var/lib/kubelet/config.yaml \
  || die "kubelet não tolera o swap gerenciado pelo WSL."
grep -Eq '^[[:space:]]*swapBehavior:[[:space:]]*NoSwap[[:space:]]*$' /var/lib/kubelet/config.yaml \
  || die "Pods não estão protegidos pela política NoSwap."

log "Aguardando nó, Flannel, DNS e Headlamp."
kube wait --for=condition=Ready nodes --all --timeout="${CLUSTER_OPERATION_TIMEOUT}"
kube rollout status daemonset/kube-flannel-ds -n kube-flannel \
  --timeout="${CLUSTER_OPERATION_TIMEOUT}"
kube rollout status deployment/coredns -n kube-system \
  --timeout="${CLUSTER_OPERATION_TIMEOUT}"
kube rollout status deployment/headlamp -n "${DASHBOARD_NAMESPACE}" \
  --timeout="${CLUSTER_OPERATION_TIMEOUT}"

log "Verificando Gateway API Standard, Envoy Gateway e o acesso local sob demanda."
bash "${SCRIPTS_DIR}/52-install-helm.sh" --check \
  || die "Helm ${HELM_VERSION} não passou na verificação."
bash "${SCRIPTS_DIR}/55-install-gateway.sh" --check \
  || die "Gateway API/Envoy Gateway não passou na verificação."
bash "${SCRIPTS_DIR}/75-configure-gateway-access.sh" --check \
  || die "o serviço local do Gateway está ausente, exposto ou inconsistente."

service_type="$(kube -n "${DASHBOARD_NAMESPACE}" get service headlamp -o jsonpath='{.spec.type}')"
[[ "${service_type}" == "ClusterIP" ]] || die "Headlamp não está protegido por Service ClusterIP."
[[ -z "$(kube -n "${DASHBOARD_NAMESPACE}" get service headlamp \
  -o jsonpath='{.spec.ports[*].nodePort}' 2>/dev/null)" ]] || die "Headlamp expôs um NodePort inesperado."

headlamp_identity="system:serviceaccount:${DASHBOARD_NAMESPACE}:headlamp"
kube auth can-i '*' '*' --all-namespaces --as="${headlamp_identity}" --quiet \
  || die "a ServiceAccount interna do Headlamp não recebeu cluster-admin."
headlamp_args="$(kube -n "${DASHBOARD_NAMESPACE}" get deployment headlamp \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="headlamp")].args}')"
grep -Fq -- '-unsafe-use-service-account-token' <<<"${headlamp_args}" \
  || die "login automático local do Headlamp não está habilitado."

listeners="$(ss -H -ltn "sport = :${DASHBOARD_LOCAL_PORT}" 2>/dev/null | awk '{print $4}')"
grep -Fxq "127.0.0.1:${DASHBOARD_LOCAL_PORT}" <<<"${listeners}" \
  || die "Headlamp não está ouvindo em 127.0.0.1:${DASHBOARD_LOCAL_PORT}."
grep -Fvxq "127.0.0.1:${DASHBOARD_LOCAL_PORT}" <<<"${listeners}" \
  && die "Headlamp está exposto fora da interface local."

retry_for "${CLUSTER_OPERATION_TIMEOUT}" 10 curl -fsS \
  --cacert /etc/kubernetes/pki/headlamp/ca.crt \
  --connect-timeout "${KUBERNETES_REQUEST_TIMEOUT_SECONDS}" \
  --max-time "${KUBERNETES_REQUEST_TIMEOUT_SECONDS}" \
  "https://127.0.0.1:${DASHBOARD_LOCAL_PORT}/" -o /dev/null \
  || die "Headlamp não respondeu pelo acesso HTTPS local."

gateway_access_state="fechado"
if systemctl is-active --quiet "${GATEWAY_FORWARD_SERVICE}"; then
  retry_for "${CLUSTER_OPERATION_TIMEOUT}" 10 curl -sS \
    --connect-timeout "${KUBERNETES_REQUEST_TIMEOUT_SECONDS}" \
    --max-time "${KUBERNETES_REQUEST_TIMEOUT_SECONDS}" \
    "http://127.0.0.1:${GATEWAY_LOCAL_PORT}/" -o /dev/null \
    || die "o túnel do Gateway está ativo, mas o Envoy não respondeu localmente."
  gateway_access_state="aberto somente em localhost"
fi

cat <<EOF

Cluster WSL 2 validado com sucesso.
  Rede WSL:  mirrored, com acessos publicados somente em 127.0.0.1
  Headlamp: https://localhost:${DASHBOARD_LOCAL_PORT}/?lng=${DASHBOARD_DEFAULT_LANGUAGE}
  Login:    automático, usando a ServiceAccount interna do laboratório
  Escopo:   somente localhost; sem UFW, OIDC, NodePort ou token manual
  CA:       $(getent passwd "${ADMIN_USER}" | cut -d: -f6)/.kube/headlamp-ca.crt

Gateway API/Envoy Gateway:
  Versões:  Gateway API ${GATEWAY_API_VERSION} Standard; Envoy Gateway ${ENVOY_GATEWAY_VERSION}
  Classe:   ${GATEWAY_CLASS_NAME}
  Gateway:  ${GATEWAY_NAMESPACE}/${GATEWAY_NAME}, Service ClusterIP
  Acesso:   ${gateway_access_state} (http://localhost:${GATEWAY_LOCAL_PORT})

Para remover o aviso do navegador, execute no CMD normal do Windows:
  windows\\30-trust-headlamp-ca.cmd Ubuntu-26.04
EOF
