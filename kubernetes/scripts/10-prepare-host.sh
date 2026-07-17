#!/usr/bin/env bash

# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_root
export DEBIAN_FRONTEND=noninteractive

log "Atualizando o índice APT e instalando utilitários do host."
apt-get update
apt-get install -y --no-install-recommends \
  apt-transport-https ca-certificates conntrack curl ebtables ethtool gpg iproute2 \
  iptables jq openssl socat ufw

log "Criando usuário/grupo operacional."
if ! getent group "${ADMIN_GROUP}" >/dev/null; then
  groupadd --system "${ADMIN_GROUP}"
fi

if id "${ADMIN_USER}" >/dev/null 2>&1; then
  usermod --append --groups "${ADMIN_GROUP}" "${ADMIN_USER}"
else
  useradd --create-home --shell /bin/bash --groups "${ADMIN_GROUP}" "${ADMIN_USER}"
fi

log "Desativando swap de forma persistente."
swapoff -a
sed -ri '/^[[:space:]]*#/! s@^([^#].*[[:space:]]swap[[:space:]].*)$@# disabled-by-k8s-bootstrap: \1@' /etc/fstab

log "Carregando módulos e parâmetros de rede exigidos pelo Kubernetes/Flannel."
cat >/etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

cat >/etc/sysctl.d/99-kubernetes.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system >/dev/null

[[ "$(sysctl -n net.ipv4.ip_forward)" == "1" ]] || die "não foi possível ativar net.ipv4.ip_forward."
log "Host preparado."

