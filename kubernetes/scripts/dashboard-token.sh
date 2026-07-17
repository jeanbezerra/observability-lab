#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

if [[ -r /etc/k8s-bootstrap/dashboard.env ]]; then
  # shellcheck source=/dev/null
  source /etc/k8s-bootstrap/dashboard.env
fi

DASHBOARD_NAMESPACE="${DASHBOARD_NAMESPACE:-kubernetes-dashboard}"
DEFAULT_TOKEN_DURATION="${DEFAULT_TOKEN_DURATION:-8h}"

profile="${1:-viewer}"
duration="${2:-${DEFAULT_TOKEN_DURATION}}"

if [[ ! "${duration}" =~ ^[0-9]+(s|m|h)$ ]]; then
  printf 'Uso: %s [viewer|admin] [duracao: 30m, 8h, ...]\n' "$0" >&2
  exit 2
fi

case "${profile}" in
  viewer) service_account=dashboard-viewer ;;
  admin) service_account=dashboard-admin ;;
  *)
    printf 'Perfil inválido: %s. Use viewer ou admin.\n' "${profile}" >&2
    exit 2
    ;;
esac

if [[ "${EUID}" -eq 0 ]]; then
  kubeconfig="${KUBECONFIG_ADMIN:-/etc/kubernetes/admin.conf}"
else
  kubeconfig="${KUBECONFIG:-${HOME:-}/.kube/config}"
fi

[[ -r "${kubeconfig}" ]] || { printf 'Kubeconfig não pode ser lido: %s\n' "${kubeconfig}" >&2; exit 1; }
kubectl --kubeconfig "${kubeconfig}" -n "${DASHBOARD_NAMESPACE}" get serviceaccount "${service_account}" >/dev/null
kubectl --kubeconfig "${kubeconfig}" -n "${DASHBOARD_NAMESPACE}" \
  create token "${service_account}" --duration="${duration}"
