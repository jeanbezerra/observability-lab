#!/usr/bin/env bash

# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_root

if ! is_true "${ENABLE_UFW}"; then
  warn "ENABLE_UFW=false: nenhuma regra de firewall foi alterada."
  exit 0
fi

require_command ufw
log "Configurando UFW sem bloquear a sessão SSH atual."

ssh_ports=("${SSH_PORT}")
if command -v sshd >/dev/null 2>&1; then
  while read -r detected_ssh_port; do
    [[ -z "${detected_ssh_port}" ]] || ssh_ports+=("${detected_ssh_port}")
  done < <(sshd -T 2>/dev/null | awk '$1 == "port" {print $2}')
fi
for ssh_port in "${ssh_ports[@]}"; do
  ufw allow "${ssh_port}/tcp" comment 'SSH administracao' >/dev/null
done

ufw allow from "${DASHBOARD_ALLOWED_CIDR}" to any port "${DASHBOARD_NODE_PORT}" proto tcp \
  comment 'Kubernetes Dashboard HTTPS' >/dev/null

# Permite tráfego originado/encaminhado pelas interfaces do CNI.
ufw allow in on cni0 comment 'Kubernetes CNI input' >/dev/null
ufw allow in on flannel.1 comment 'Kubernetes Flannel input' >/dev/null
ufw route allow in on cni0 comment 'Kubernetes CNI routed input' >/dev/null
ufw route allow out on cni0 comment 'Kubernetes CNI routed output' >/dev/null
ufw route allow in on flannel.1 comment 'Kubernetes Flannel routed input' >/dev/null
ufw route allow out on flannel.1 comment 'Kubernetes Flannel routed output' >/dev/null

ufw --force enable >/dev/null
ufw reload >/dev/null
log "UFW ativo; Dashboard permitido a partir de ${DASHBOARD_ALLOWED_CIDR}."
