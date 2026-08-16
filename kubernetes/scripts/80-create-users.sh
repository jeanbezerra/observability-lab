#!/usr/bin/env bash

# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_root

previous_dashboard_namespace=""
if [[ -r /etc/k8s-bootstrap/dashboard.env ]]; then
  previous_dashboard_namespace="$(sed -n 's/^DASHBOARD_NAMESPACE=//p' /etc/k8s-bootstrap/dashboard.env | head -n 1)"
fi

render_and_apply() {
  local source_file="$1"
  local rendered
  rendered="$(mktemp)"
  sed "s|__NAMESPACE__|${DASHBOARD_NAMESPACE}|g" "${source_file}" >"${rendered}"
  kube apply -f "${rendered}"
  rm -f -- "${rendered}"
}

render_oidc_manifest() {
  local source_file="$1"
  sed \
    -e "s|__OIDC_GROUPS_PREFIX__|${OIDC_GROUPS_PREFIX}|g" \
    -e "s|__OIDC_VIEWER_GROUP__|${OIDC_VIEWER_GROUP}|g" \
    -e "s|__OIDC_ADMIN_GROUP__|${OIDC_ADMIN_GROUP}|g" \
    "${source_file}"
}

render_oidc_and_apply() {
  local source_file="$1" rendered
  rendered="$(mktemp)"
  render_oidc_manifest "${source_file}" >"${rendered}"
  kube apply -f "${rendered}"
  rm -f -- "${rendered}"
}

render_dashboard_env() {
  printf 'DASHBOARD_NAMESPACE=%q\n' "${DASHBOARD_NAMESPACE}"
  printf 'DEFAULT_TOKEN_DURATION=%q\n' "${DEFAULT_TOKEN_DURATION}"
  printf 'KUBECONFIG_ADMIN=%q\n' "${KUBECONFIG_ADMIN}"
}

rbac_state_ok() {
  local binding_subject binding_role installed_group installed_mode
  if ! sed "s|__NAMESPACE__|${DASHBOARD_NAMESPACE}|g" \
    "${PROJECT_DIR}/manifests/dashboard/rbac-viewer.yaml" | kube diff -f - >/dev/null 2>&1; then
    check_pending "recursos RBAC de leitura diferem do manifesto desejado."
    return 1
  fi
  kube -n "${DASHBOARD_NAMESPACE}" get serviceaccount dashboard-viewer >/dev/null 2>&1 || {
    check_pending "ServiceAccount dashboard-viewer não existe."
    return 1
  }
  for binding in dashboard-viewer dashboard-cluster-observer; do
    kube get clusterrolebinding "${binding}" >/dev/null 2>&1 || {
      check_pending "ClusterRoleBinding ${binding} não existe."
      return 1
    }
    binding_subject="$(kube get clusterrolebinding "${binding}" \
      -o jsonpath='{.subjects[?(@.name=="dashboard-viewer")].namespace}' 2>/dev/null)"
    [[ "${binding_subject}" == "${DASHBOARD_NAMESPACE}" ]] || {
      check_pending "ClusterRoleBinding ${binding} aponta para outro namespace."
      return 1
    }
  done
  kube get clusterrole dashboard-cluster-observer >/dev/null 2>&1 || {
    check_pending "ClusterRole dashboard-cluster-observer não existe."
    return 1
  }
  binding_role="$(kube get clusterrolebinding dashboard-viewer -o jsonpath='{.roleRef.name}' 2>/dev/null)"
  [[ "${binding_role}" == "view" ]] || {
    check_pending "dashboard-viewer não referencia o ClusterRole view."
    return 1
  }

  if is_true "${ENABLE_OIDC}"; then
    if ! render_oidc_manifest "${PROJECT_DIR}/manifests/dashboard/rbac-oidc-viewer.yaml" \
      | kube diff -f - >/dev/null 2>&1; then
      check_pending "vínculos RBAC do grupo OIDC de leitura diferem do desejado."
      return 1
    fi
    binding_subject="$(kube get clusterrolebinding headlamp-oidc-viewer \
      -o jsonpath='{.subjects[?(@.kind=="Group")].name}' 2>/dev/null)"
    [[ "${binding_subject}" == "${OIDC_GROUPS_PREFIX}${OIDC_VIEWER_GROUP}" ]] || {
      check_pending "grupo OIDC de leitura aponta para outro subject."
      return 1
    }
    if is_true "${OIDC_ENABLE_ADMIN_GROUP}"; then
      if ! render_oidc_manifest "${PROJECT_DIR}/manifests/dashboard/rbac-oidc-admin.yaml" \
        | kube diff -f - >/dev/null 2>&1; then
        check_pending "vínculo RBAC do grupo OIDC administrativo difere do desejado."
        return 1
      fi
      binding_subject="$(kube get clusterrolebinding headlamp-oidc-admin \
        -o jsonpath='{.subjects[?(@.kind=="Group")].name}' 2>/dev/null)"
      [[ "${binding_subject}" == "${OIDC_GROUPS_PREFIX}${OIDC_ADMIN_GROUP}" ]] || {
        check_pending "grupo OIDC administrativo aponta para outro subject."
        return 1
      }
    elif kube get clusterrolebinding headlamp-oidc-admin >/dev/null 2>&1; then
      check_pending "vínculo OIDC administrativo existe apesar de OIDC_ENABLE_ADMIN_GROUP=false."
      return 1
    fi
  elif kube get clusterrolebinding headlamp-oidc-viewer >/dev/null 2>&1 \
    || kube get clusterrolebinding headlamp-oidc-cluster-observer >/dev/null 2>&1 \
    || kube get clusterrolebinding headlamp-oidc-admin >/dev/null 2>&1; then
    check_pending "vínculos OIDC ainda existem apesar de ENABLE_OIDC=false."
    return 1
  fi

  if is_true "${CREATE_ADMIN_SERVICE_ACCOUNT}"; then
    if ! sed "s|__NAMESPACE__|${DASHBOARD_NAMESPACE}|g" \
      "${PROJECT_DIR}/manifests/dashboard/rbac-admin.yaml" | kube diff -f - >/dev/null 2>&1; then
      check_pending "recursos RBAC administrativos diferem do manifesto desejado."
      return 1
    fi
    kube -n "${DASHBOARD_NAMESPACE}" get serviceaccount dashboard-admin >/dev/null 2>&1 || {
      check_pending "ServiceAccount dashboard-admin não existe."
      return 1
    }
    binding_subject="$(kube get clusterrolebinding dashboard-admin \
      -o jsonpath='{.subjects[?(@.name=="dashboard-admin")].namespace}' 2>/dev/null)"
    binding_role="$(kube get clusterrolebinding dashboard-admin -o jsonpath='{.roleRef.name}' 2>/dev/null)"
    [[ "${binding_subject}" == "${DASHBOARD_NAMESPACE}" && "${binding_role}" == "cluster-admin" ]] || {
      check_pending "vínculo dashboard-admin está ausente ou incorreto."
      return 1
    }
  else
    if kube get clusterrolebinding dashboard-admin >/dev/null 2>&1 \
      || kube -n "${DASHBOARD_NAMESPACE}" get serviceaccount dashboard-admin >/dev/null 2>&1; then
      check_pending "identidade dashboard-admin ainda existe, apesar de estar desativada."
      return 1
    fi
  fi

  [[ -f /usr/local/sbin/k8s-dashboard-token ]] \
    && cmp -s "${PROJECT_DIR}/scripts/dashboard-token.sh" /usr/local/sbin/k8s-dashboard-token || {
      check_pending "utilitário k8s-dashboard-token está ausente ou desatualizado."
      return 1
    }
  installed_group="$(stat -c '%G' /usr/local/sbin/k8s-dashboard-token 2>/dev/null)"
  installed_mode="$(stat -c '%a' /usr/local/sbin/k8s-dashboard-token 2>/dev/null)"
  [[ "${installed_group}" == "${ADMIN_GROUP}" && "${installed_mode}" == "750" ]] || {
    check_pending "permissões do k8s-dashboard-token estão incorretas."
    return 1
  }
  if ! cmp -s <(render_dashboard_env) /etc/k8s-bootstrap/dashboard.env; then
    check_pending "/etc/k8s-bootstrap/dashboard.env está ausente ou desatualizado."
    return 1
  fi
  [[ "$(stat -c '%U:%G:%a' /etc/k8s-bootstrap/dashboard.env 2>/dev/null)" == "root:root:644" ]] || {
    check_pending "permissões de /etc/k8s-bootstrap/dashboard.env estão incorretas."
    return 1
  }
}

if check_requested "${1:-}"; then
  if rbac_state_ok; then
    exit 0
  fi
  exit 1
fi

log "Reconciliando identidade de leitura do Dashboard."
render_and_apply "${PROJECT_DIR}/manifests/dashboard/rbac-viewer.yaml"

if is_true "${ENABLE_OIDC}"; then
  log "Vinculando o grupo ${OIDC_GROUPS_PREFIX}${OIDC_VIEWER_GROUP} aos perfis de leitura."
  render_oidc_and_apply "${PROJECT_DIR}/manifests/dashboard/rbac-oidc-viewer.yaml"
  if is_true "${OIDC_ENABLE_ADMIN_GROUP}"; then
    warn "Vinculando ${OIDC_GROUPS_PREFIX}${OIDC_ADMIN_GROUP} ao ClusterRole cluster-admin. A associação de usuários a esse grupo deve ser restrita e auditada no Keycloak."
    render_oidc_and_apply "${PROJECT_DIR}/manifests/dashboard/rbac-oidc-admin.yaml"
  else
    kube delete clusterrolebinding headlamp-oidc-admin --ignore-not-found=true
  fi
else
  log "Removendo somente os vínculos de grupos OIDC gerenciados, pois ENABLE_OIDC=false."
  kube delete clusterrolebinding headlamp-oidc-viewer headlamp-oidc-cluster-observer \
    headlamp-oidc-admin --ignore-not-found=true
fi

if is_true "${CREATE_ADMIN_SERVICE_ACCOUNT}"; then
  warn "Reconciliando dashboard-admin com privilégios cluster-admin; emita tokens apenas quando necessário."
  render_and_apply "${PROJECT_DIR}/manifests/dashboard/rbac-admin.yaml"
else
  log "Removendo somente a identidade dashboard-admin gerenciada por este instalador."
  kube delete clusterrolebinding dashboard-admin --ignore-not-found=true
  kube -n "${DASHBOARD_NAMESPACE}" delete serviceaccount dashboard-admin --ignore-not-found=true
fi

if [[ -n "${previous_dashboard_namespace}" \
  && "${previous_dashboard_namespace}" != "${DASHBOARD_NAMESPACE}" \
  && "${previous_dashboard_namespace}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
  log "Removendo ServiceAccounts gerenciadas do namespace anterior ${previous_dashboard_namespace}."
  kube -n "${previous_dashboard_namespace}" delete serviceaccount \
    dashboard-viewer dashboard-admin --ignore-not-found=true
fi

install -d -o root -g root -m 0755 /etc/k8s-bootstrap
render_dashboard_env >/etc/k8s-bootstrap/dashboard.env
chmod 0644 /etc/k8s-bootstrap/dashboard.env

install -o root -g "${ADMIN_GROUP}" -m 0750 \
  "${PROJECT_DIR}/scripts/dashboard-token.sh" /usr/local/sbin/k8s-dashboard-token

rbac_state_ok || die "RBAC e utilitário de tokens foram aplicados, mas a verificação falhou."
log "Usuários Kubernetes reconciliados. Gere um token com: sudo k8s-dashboard-token viewer ${DEFAULT_TOKEN_DURATION}"
