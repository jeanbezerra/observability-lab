#!/usr/bin/env bash

# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_root

unit_file="/etc/systemd/system/${GATEWAY_FORWARD_SERVICE}"
helper_file="/usr/local/sbin/k8s-gateway-local-forward"
admin_home="$(getent passwd "${ADMIN_USER}" | cut -d: -f6)"
admin_group="$(id -gn "${ADMIN_USER}")"
user_kubeconfig="${admin_home}/.kube/config"

render_helper() {
  cat <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

selector='gateway.envoyproxy.io/owning-gateway-namespace=${GATEWAY_NAMESPACE},gateway.envoyproxy.io/owning-gateway-name=${GATEWAY_NAME}'
mapfile -t services < <(/usr/bin/kubectl --kubeconfig='${user_kubeconfig}' get service -A -l "\${selector}" \\
  -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"\\n"}{end}')

if [[ "\${#services[@]}" -ne 1 ]]; then
  printf 'ERRO: esperado exatamente um Service para ${GATEWAY_NAMESPACE}/${GATEWAY_NAME}; encontrado: %s.\\n' "\${#services[@]}" >&2
  exit 1
fi

IFS='|' read -r service_namespace service_name <<<"\${services[0]}"
exec /usr/bin/kubectl --kubeconfig='${user_kubeconfig}' --namespace="\${service_namespace}" \\
  port-forward --address=127.0.0.1 "service/\${service_name}" '${GATEWAY_LOCAL_PORT}:${GATEWAY_LISTENER_PORT}'
EOF
}

render_unit() {
  cat <<EOF
[Unit]
Description=Envoy Gateway HTTP restricted to localhost for Windows/WSL
Wants=network-online.target
After=network-online.target kubelet.service ${WSL_NODE_IP_SERVICE}

[Service]
Type=simple
User=${ADMIN_USER}
Group=${admin_group}
ExecStart=${helper_file}
Restart=always
RestartSec=5s
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

[Install]
WantedBy=multi-user.target
EOF
}

gateway_access_state_ok() {
  local listeners
  if [[ ! -x "${helper_file}" ]] || ! cmp -s <(render_helper) "${helper_file}"; then
    check_pending "helper do encaminhamento local do Gateway está ausente ou desatualizado."
    return 1
  fi
  if [[ ! -r "${unit_file}" ]] || ! cmp -s <(render_unit) "${unit_file}"; then
    check_pending "serviço local do Gateway está ausente ou desatualizado."
    return 1
  fi

  if systemctl is-enabled --quiet "${GATEWAY_FORWARD_SERVICE}"; then
    systemctl is-active --quiet "${GATEWAY_FORWARD_SERVICE}" || {
      check_pending "${GATEWAY_FORWARD_SERVICE} está habilitado, mas não está ativo."
      return 1
    }
  fi

  listeners="$(ss -H -ltn "sport = :${GATEWAY_LOCAL_PORT}" 2>/dev/null | awk '{print $4}')"
  if systemctl is-active --quiet "${GATEWAY_FORWARD_SERVICE}"; then
    grep -Fxq "127.0.0.1:${GATEWAY_LOCAL_PORT}" <<<"${listeners}" || {
      check_pending "a porta ${GATEWAY_LOCAL_PORT} não está ouvindo em 127.0.0.1."
      return 1
    }
    if grep -Fvxq "127.0.0.1:${GATEWAY_LOCAL_PORT}" <<<"${listeners}"; then
      check_pending "a porta do Gateway também está exposta em uma interface não local."
      return 1
    fi
  elif [[ -n "${listeners}" ]]; then
    check_pending "a porta ${GATEWAY_LOCAL_PORT} está ocupada por outro processo."
    return 1
  fi
}

if check_requested "${1:-}"; then
  if gateway_access_state_ok; then
    exit 0
  fi
  exit 1
fi

[[ -r "${user_kubeconfig}" ]] || die "kubeconfig de ${ADMIN_USER} não encontrado: ${user_kubeconfig}."
bash "${SCRIPTS_DIR}/55-install-gateway.sh" --check \
  || die "Gateway ainda não está pronto; reconcilie 55-install-gateway.sh antes do acesso local."

unit_preexisted=false
unit_was_active=false
[[ -r "${unit_file}" ]] && unit_preexisted=true
systemctl is-active --quiet "${GATEWAY_FORWARD_SERVICE}" && unit_was_active=true

temporary_helper="$(mktemp)"
temporary_unit="$(mktemp)"
trap 'rm -f -- "${temporary_helper}" "${temporary_unit}"' EXIT
render_helper >"${temporary_helper}"
render_unit >"${temporary_unit}"
install -o root -g root -m 0755 "${temporary_helper}" "${helper_file}"
install -o root -g root -m 0644 "${temporary_unit}" "${unit_file}"
systemctl daemon-reload

if is_true "${unit_preexisted}" && is_true "${unit_was_active}"; then
  systemctl restart "${GATEWAY_FORWARD_SERVICE}"
elif ! is_true "${unit_preexisted}"; then
  # Segurança por padrão: instalar o mecanismo não publica a porta. A abertura
  # é uma ação explícita do usuário pelo CMD 25-open-gateway-port.cmd.
  systemctl disable --now "${GATEWAY_FORWARD_SERVICE}" >/dev/null 2>&1 || true
fi

gateway_access_state_ok || die "o mecanismo de acesso local ao Gateway ficou em estado inconsistente."
log "Acesso do Gateway instalado e fechado por padrão; use o CMD 25 para abrir 127.0.0.1:${GATEWAY_LOCAL_PORT}."
