#!/usr/bin/env bash

# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_root
require_command curl

log "Verificando serviços systemd."
systemctl is-enabled --quiet containerd || die "containerd não está habilitado no boot."
systemctl is-active --quiet containerd || die "containerd não está ativo."
systemctl is-enabled --quiet kubelet || die "kubelet não está habilitado no boot."
systemctl is-active --quiet kubelet || die "kubelet não está ativo."

log "Aguardando nó, rede e Dashboard."
kube wait --for=condition=Ready nodes --all --timeout=5m
kube rollout status daemonset/kube-flannel-ds -n kube-flannel --timeout=3m
kube rollout status deployment/coredns -n kube-system --timeout=3m
kube rollout status deployment/headlamp -n "${DASHBOARD_NAMESPACE}" --timeout=3m

actual_node_port="$(kube -n "${DASHBOARD_NAMESPACE}" get service headlamp -o jsonpath='{.spec.ports[0].nodePort}')"
[[ "${actual_node_port}" == "${DASHBOARD_NODE_PORT}" ]] \
  || die "NodePort esperado ${DASHBOARD_NODE_PORT}, encontrado ${actual_node_port}."

viewer_identity="system:serviceaccount:${DASHBOARD_NAMESPACE}:dashboard-viewer"
kube auth can-i list pods --all-namespaces \
  --as="${viewer_identity}" --quiet \
  || die "dashboard-viewer não consegue listar Pods."
if kube auth can-i get secrets --all-namespaces \
  --as="${viewer_identity}" --quiet; then
  die "dashboard-viewer recebeu acesso indevido a Secrets."
fi

if is_true "${CREATE_ADMIN_SERVICE_ACCOUNT}"; then
  admin_identity="system:serviceaccount:${DASHBOARD_NAMESPACE}:dashboard-admin"
  kube auth can-i '*' '*' --all-namespaces \
    --as="${admin_identity}" --quiet \
    || die "dashboard-admin não recebeu as permissões administrativas esperadas."
fi

node_ip="$(detect_node_ip)"
retry 12 5 curl -fsS --cacert /etc/kubernetes/pki/headlamp/ca.crt \
  --connect-timeout 5 "https://${node_ip}:${DASHBOARD_NODE_PORT}/" -o /dev/null \
  || die "Dashboard não respondeu via HTTPS/NodePort."

access_host="${DASHBOARD_DNS_NAME:-${DASHBOARD_PUBLIC_IP:-${node_ip}}}"
if is_true "${CREATE_ADMIN_SERVICE_ACCOUNT}"; then
  admin_token_hint="sudo k8s-dashboard-token admin 1h"
else
  admin_token_hint="desativado por CREATE_ADMIN_SERVICE_ACCOUNT=false"
fi
cat <<EOF

Cluster validado com sucesso.
  Dashboard: https://${access_host}:${DASHBOARD_NODE_PORT}
  Token leitura: sudo k8s-dashboard-token viewer ${DEFAULT_TOKEN_DURATION}
  Token admin:   ${admin_token_hint}
  CA local:      /etc/kubernetes/pki/headlamp/ca.crt

Para acesso pela Internet, também encaminhe TCP/${DASHBOARD_NODE_PORT} no roteador
ou libere essa porta no firewall/security group do provedor.
EOF
