#!/usr/bin/env bash

# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_root
export DEBIAN_FRONTEND=noninteractive

required_packages=(
  apt-transport-https ca-certificates conntrack curl ebtables ethtool gpg iproute2
  iptables jq kmod openssl socat
)
is_true "${ENABLE_UFW}" && required_packages+=(ufw)
required_command_packages=(
  curl:curl gpg:gpg ip:iproute2 iptables:iptables jq:jq lsmod:kmod modprobe:kmod
  openssl:openssl
)
is_true "${ENABLE_UFW}" && required_command_packages+=(ufw:ufw)

host_state_ok() {
  local package_name
  for package_name in "${required_packages[@]}"; do
    if ! package_is_installed "${package_name}"; then
      check_pending "pacote ausente: ${package_name}."
      return 1
    fi
  done
  for command_package in "${required_command_packages[@]}"; do
    command_name="${command_package%%:*}"
    command -v "${command_name}" >/dev/null 2>&1 || {
      check_pending "comando ausente apesar da preparação do host: ${command_name}."
      return 1
    }
  done
  getent group "${ADMIN_GROUP}" >/dev/null || {
    check_pending "grupo ${ADMIN_GROUP} não existe."
    return 1
  }
  id "${ADMIN_USER}" >/dev/null 2>&1 || {
    check_pending "usuário ${ADMIN_USER} não existe."
    return 1
  }
  id -nG "${ADMIN_USER}" | tr ' ' '\n' | grep -Fxq "${ADMIN_GROUP}" || {
    check_pending "usuário ${ADMIN_USER} não pertence ao grupo ${ADMIN_GROUP}."
    return 1
  }
  if swapon --show --noheadings 2>/dev/null | grep -q .; then
    check_pending "swap ainda está ativo."
    return 1
  fi
  if awk '!/^[[:space:]]*#/ && $3 == "swap" {found=1} END {exit !found}' /etc/fstab; then
    check_pending "há swap ativo na configuração persistente /etc/fstab."
    return 1
  fi
  grep -Fxq overlay /etc/modules-load.d/k8s.conf 2>/dev/null || {
    check_pending "módulo overlay não está configurado."
    return 1
  }
  grep -Fxq br_netfilter /etc/modules-load.d/k8s.conf 2>/dev/null || {
    check_pending "módulo br_netfilter não está configurado."
    return 1
  }
  lsmod | awk '{print $1}' | grep -Fxq overlay || {
    check_pending "módulo overlay não está carregado."
    return 1
  }
  lsmod | awk '{print $1}' | grep -Fxq br_netfilter || {
    check_pending "módulo br_netfilter não está carregado."
    return 1
  }
  [[ "$(sysctl -n net.bridge.bridge-nf-call-iptables 2>/dev/null)" == "1" ]] || {
    check_pending "net.bridge.bridge-nf-call-iptables não está ativo."
    return 1
  }
  [[ "$(sysctl -n net.bridge.bridge-nf-call-ip6tables 2>/dev/null)" == "1" ]] || {
    check_pending "net.bridge.bridge-nf-call-ip6tables não está ativo."
    return 1
  }
  [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" == "1" ]] || {
    check_pending "net.ipv4.ip_forward não está ativo."
    return 1
  }
  grep -Eq '^[[:space:]]*net\.bridge\.bridge-nf-call-iptables[[:space:]]*=[[:space:]]*1[[:space:]]*$' \
    /etc/sysctl.d/99-kubernetes.conf 2>/dev/null || {
      check_pending "parâmetro bridge-nf-call-iptables não está persistido."
      return 1
    }
  grep -Eq '^[[:space:]]*net\.bridge\.bridge-nf-call-ip6tables[[:space:]]*=[[:space:]]*1[[:space:]]*$' \
    /etc/sysctl.d/99-kubernetes.conf 2>/dev/null || {
      check_pending "parâmetro bridge-nf-call-ip6tables não está persistido."
      return 1
    }
  grep -Eq '^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=[[:space:]]*1[[:space:]]*$' \
    /etc/sysctl.d/99-kubernetes.conf 2>/dev/null || {
      check_pending "parâmetro ip_forward não está persistido."
      return 1
    }
}

if check_requested "${1:-}"; then
  if host_state_ok; then
    exit 0
  fi
  exit 1
fi

missing_packages=()
reinstall_packages=()
for package_name in "${required_packages[@]}"; do
  package_is_installed "${package_name}" || missing_packages+=("${package_name}")
done
for command_package in "${required_command_packages[@]}"; do
  command_name="${command_package%%:*}"
  package_name="${command_package##*:}"
  if ! command -v "${command_name}" >/dev/null 2>&1 && package_is_installed "${package_name}"; then
    if [[ " ${reinstall_packages[*]} " != *" ${package_name} "* ]]; then
      reinstall_packages+=("${package_name}")
    fi
  fi
done
if (( ${#missing_packages[@]} > 0 || ${#reinstall_packages[@]} > 0 )); then
  apt-get update
  if (( ${#missing_packages[@]} > 0 )); then
    log "Instalando pacotes ausentes do host: ${missing_packages[*]}."
    apt-get install -y --no-install-recommends "${missing_packages[@]}"
  fi
  if (( ${#reinstall_packages[@]} > 0 )); then
    log "Reinstalando pacotes com comandos ausentes: ${reinstall_packages[*]}."
    apt-get install -y --reinstall --no-install-recommends "${reinstall_packages[@]}"
  fi
else
  log "Pacotes básicos do host já estão instalados."
fi

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
install -o root -g root -m 0644 /dev/null /etc/modules-load.d/k8s.conf
cat >/etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

install -o root -g root -m 0644 /dev/null /etc/sysctl.d/99-kubernetes.conf
cat >/etc/sysctl.d/99-kubernetes.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system >/dev/null

[[ "$(sysctl -n net.ipv4.ip_forward)" == "1" ]] || die "não foi possível ativar net.ipv4.ip_forward."
host_state_ok || die "a preparação do host terminou, mas o estado esperado não foi atingido."
log "Host preparado."
