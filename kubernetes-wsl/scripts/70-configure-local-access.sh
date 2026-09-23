#!/usr/bin/env bash

# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_root

unit_file="/etc/systemd/system/${HEADLAMP_FORWARD_SERVICE}"
admin_home="$(getent passwd "${ADMIN_USER}" | cut -d: -f6)"
admin_group="$(id -gn "${ADMIN_USER}")"
user_kubeconfig="${admin_home}/.kube/config"

render_unit() {
  cat <<EOF
[Unit]
Description=Headlamp HTTPS restricted to localhost for Windows/WSL
Wants=network-online.target
After=network-online.target kubelet.service ${WSL_NODE_IP_SERVICE}

[Service]
Type=simple
User=${ADMIN_USER}
Group=${admin_group}
ExecStart=/usr/bin/kubectl --kubeconfig=${user_kubeconfig} --namespace=${DASHBOARD_NAMESPACE} port-forward --address=127.0.0.1 service/headlamp ${DASHBOARD_LOCAL_PORT}:443
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

local_access_state_ok() {
  local local_listeners
  if [[ ! -r "${unit_file}" ]] || ! cmp -s <(render_unit) "${unit_file}"; then
    check_pending "serviço local do Headlamp está ausente ou desatualizado."
    return 1
  fi
  systemctl is-enabled --quiet "${HEADLAMP_FORWARD_SERVICE}" || {
    check_pending "${HEADLAMP_FORWARD_SERVICE} não está habilitado."
    return 1
  }
  systemctl is-active --quiet "${HEADLAMP_FORWARD_SERVICE}" || {
    check_pending "${HEADLAMP_FORWARD_SERVICE} não está ativo."
    return 1
  }
  local_listeners="$(ss -H -ltn "sport = :${DASHBOARD_LOCAL_PORT}" 2>/dev/null | awk '{print $4}')"
  grep -Fxq "127.0.0.1:${DASHBOARD_LOCAL_PORT}" <<<"${local_listeners}" || {
      check_pending "a porta ${DASHBOARD_LOCAL_PORT} não está ouvindo em 127.0.0.1."
      return 1
    }
  if grep -Fvxq "127.0.0.1:${DASHBOARD_LOCAL_PORT}" <<<"${local_listeners}"; then
    check_pending "a porta do Headlamp também está exposta em uma interface não local."
    return 1
  fi
}

if check_requested "${1:-}"; then
  if local_access_state_ok; then
    exit 0
  fi
  exit 1
fi

[[ -r "${user_kubeconfig}" ]] || die "kubeconfig de ${ADMIN_USER} não encontrado: ${user_kubeconfig}."

if ! systemctl is-active --quiet "${HEADLAMP_FORWARD_SERVICE}" \
  && ss -H -ltn "sport = :${DASHBOARD_LOCAL_PORT}" 2>/dev/null | grep -q .; then
  die "a porta local ${DASHBOARD_LOCAL_PORT} já está em uso por outro processo. Ajuste DASHBOARD_LOCAL_PORT."
fi

temporary_unit="$(mktemp)"
trap 'rm -f -- "${temporary_unit}"' EXIT
render_unit >"${temporary_unit}"
unit_changed=false
if [[ ! -r "${unit_file}" ]] || ! cmp -s "${temporary_unit}" "${unit_file}"; then
  install -o root -g root -m 0644 "${temporary_unit}" "${unit_file}"
  unit_changed=true
fi
systemctl daemon-reload
systemctl enable "${HEADLAMP_FORWARD_SERVICE}"
if is_true "${unit_changed}"; then
  systemctl restart "${HEADLAMP_FORWARD_SERVICE}"
else
  systemctl start "${HEADLAMP_FORWARD_SERVICE}"
fi

retry 15 2 local_access_state_ok \
  || { journalctl -u "${HEADLAMP_FORWARD_SERVICE}" -n 100 --no-pager >&2 || true; die "o acesso local do Headlamp não iniciou."; }
log "Headlamp publicado somente em https://127.0.0.1:${DASHBOARD_LOCAL_PORT}."
