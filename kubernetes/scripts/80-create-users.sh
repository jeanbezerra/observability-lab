#!/usr/bin/env bash

# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_root

render_and_apply() {
  local source_file="$1"
  local rendered
  rendered="$(mktemp)"
  sed "s|__NAMESPACE__|${DASHBOARD_NAMESPACE}|g" "${source_file}" >"${rendered}"
  kube apply -f "${rendered}"
  rm -f -- "${rendered}"
}

log "Criando identidade de leitura do Dashboard."
render_and_apply "${PROJECT_DIR}/manifests/dashboard/rbac-viewer.yaml"

if is_true "${CREATE_ADMIN_SERVICE_ACCOUNT}"; then
  warn "Criando dashboard-admin com privilégios cluster-admin; emita tokens apenas quando necessário."
  render_and_apply "${PROJECT_DIR}/manifests/dashboard/rbac-admin.yaml"
else
  log "CREATE_ADMIN_SERVICE_ACCOUNT=false; identidade administrativa não será criada."
fi

install -d -o root -g root -m 0755 /etc/k8s-bootstrap
{
  printf 'DASHBOARD_NAMESPACE=%q\n' "${DASHBOARD_NAMESPACE}"
  printf 'DEFAULT_TOKEN_DURATION=%q\n' "${DEFAULT_TOKEN_DURATION}"
  printf 'KUBECONFIG_ADMIN=%q\n' "${KUBECONFIG_ADMIN}"
} >/etc/k8s-bootstrap/dashboard.env
chmod 0644 /etc/k8s-bootstrap/dashboard.env

install -o root -g "${ADMIN_GROUP}" -m 0750 \
  "${PROJECT_DIR}/scripts/dashboard-token.sh" /usr/local/sbin/k8s-dashboard-token

log "Usuários Kubernetes criados. Gere um token com: sudo k8s-dashboard-token viewer ${DEFAULT_TOKEN_DURATION}"
