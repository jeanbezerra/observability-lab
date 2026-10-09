#!/usr/bin/env bash

# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_root
require_command curl

external_access_state_ok() {
  local actual
  actual="$(kube -n "${DASHBOARD_NAMESPACE}" get service headlamp \
    -o jsonpath='{.spec.type}:{.spec.ports[*].port}:{.spec.ports[*].targetPort}:{.spec.ports[*].nodePort}:{.spec.ports[*].protocol}:{.spec.selector.app\.kubernetes\.io/name}' 2>/dev/null)" || return 1
  [[ "${actual}" == "NodePort:443:https:${DASHBOARD_NODE_PORT}:TCP:headlamp" ]] || {
    check_pending "Service do Headlamp não corresponde ao NodePort HTTPS esperado."
    return 1
  }
  [[ -r /etc/kubernetes/pki/headlamp/ca.crt ]] || {
    check_pending "CA do Headlamp ausente."
    return 1
  }

  # Usa o IP informado durante a instalação sem depender de DNS já propagado.
  # O nome da URL continua sendo validado contra os SANs do certificado TLS.
  curl --noproxy '*' --fail --silent --show-error \
    --cacert /etc/kubernetes/pki/headlamp/ca.crt \
    --resolve "${HEADLAMP_HOST}:${DASHBOARD_NODE_PORT}:${NODE_IP}" \
    --connect-timeout 5 --max-time 10 \
    "https://${HEADLAMP_HOST}:${DASHBOARD_NODE_PORT}/" -o /dev/null
}

if check_requested "${1:-}"; then
  if external_access_state_ok; then
    exit 0
  fi
  exit 1
fi

bash "${SCRIPTS_DIR}/60-install-dashboard.sh" --check \
  || die "Headlamp ainda não está pronto; reconcilie a etapa 60 antes de verificar o acesso externo."

retry 6 3 external_access_state_ok \
  || die "Headlamp não respondeu em https://${HEADLAMP_HOST}:${DASHBOARD_NODE_PORT}; confira a rede da VM e as regras para TCP/${DASHBOARD_NODE_PORT}."

log "Headlamp responde com TLS válido em https://${HEADLAMP_HOST}:${DASHBOARD_NODE_PORT}/?lng=${DASHBOARD_DEFAULT_LANGUAGE}."
