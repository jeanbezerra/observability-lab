#!/usr/bin/env bash

# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_root
export DEBIAN_FRONTEND=noninteractive

required_packages=(
  apt-transport-https ca-certificates conntrack curl ebtables ethtool gpg iproute2
  iptables kmod openssl procps python3 socat tar
)
required_command_packages=(
  curl:curl gpg:gpg ip:iproute2 iptables:iptables modprobe:kmod
  openssl:openssl python3:python3 sysctl:procps tar:tar
)
node_ip_unit="/etc/systemd/system/${NODE_NETWORK_SERVICE}"
network_helper="/usr/local/sbin/k8s-hml-node-network"
kubelet_dropin="/etc/systemd/system/kubelet.service.d/05-k8s-hml-node-ip.conf"
sysctl_file="/etc/sysctl.d/99-kubernetes-hml.conf"

render_node_ip_unit() {
  cat <<EOF
[Unit]
Description=Kubernetes HML VM node network preparation
Wants=network-online.target
After=network-online.target systemd-modules-load.service
Before=containerd.service kubelet.service

[Service]
Type=oneshot
ExecStartPre=/usr/sbin/modprobe overlay
ExecStartPre=/usr/sbin/modprobe br_netfilter
ExecStart=/usr/local/sbin/k8s-hml-node-network ${NODE_IP}
ExecStart=/usr/sbin/sysctl -q -w net.bridge.bridge-nf-call-iptables=1
ExecStart=/usr/sbin/sysctl -q -w net.bridge.bridge-nf-call-ip6tables=1
ExecStart=/usr/sbin/sysctl -q -w net.ipv4.ip_forward=1
RemainAfterExit=yes
TimeoutStartSec=90

[Install]
WantedBy=multi-user.target
EOF
}

render_network_helper() {
  cat <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
# Gerenciado por kubernetes-hml. Valida a rede existente sem alterar DHCP/netplan.
PATH=/usr/sbin:/usr/bin:/sbin:/bin
readonly expected_ip="${1:?informe o IPv4 configurado para o nó}"
for ((attempt = 1; attempt <= 30; attempt++)); do
  while IFS= read -r interface; do
    interface="${interface%%@*}"
    if [[ "${interface}" != "lo" && -e "/sys/class/net/${interface}/device" ]]; then
      printf 'NODE_IP=%s disponível na interface %s.\n' "${expected_ip}" "${interface}"
      exit 0
    fi
  done < <(ip -o -4 address show scope global | awk -v wanted="${expected_ip}" \
    '$3 == "inet" {split($4, a, "/"); if (a[1] == wanted) print $2}')
  sleep 2
done
printf 'NODE_IP=%s ausente em interfaces físicas da VM. Verifique DHCP/reserva de endereço.\n' "${expected_ip}" >&2
exit 1
EOF
}

render_kubelet_dropin() {
  cat <<EOF
[Unit]
Requires=${NODE_NETWORK_SERVICE}
After=${NODE_NETWORK_SERVICE}
EOF
}

render_sysctl() {
  cat <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
}

kernel_features_ok() {
  grep -Eq '(^|[[:space:]])overlay$' /proc/filesystems || {
    check_pending "filesystem overlay não está disponível no kernel da VM."
    return 1
  }
  [[ -e /proc/sys/net/bridge/bridge-nf-call-iptables ]] || {
    check_pending "br_netfilter não está disponível no kernel da VM."
    return 1
  }
}

host_state_ok() {
  local command_name command_package package_name
  for package_name in "${required_packages[@]}"; do
    package_is_installed "${package_name}" || {
      check_pending "pacote ausente: ${package_name}."
      return 1
    }
  done
  for command_package in "${required_command_packages[@]}"; do
    command_name="${command_package%%:*}"
    command -v "${command_name}" >/dev/null 2>&1 || {
      check_pending "comando ausente: ${command_name}."
      return 1
    }
  done
  id "${ADMIN_USER}" >/dev/null 2>&1 || {
    check_pending "usuário administrador ${ADMIN_USER} não existe."
    return 1
  }
  if [[ ! -r "${node_ip_unit}" ]] || ! cmp -s <(render_node_ip_unit) "${node_ip_unit}"; then
    check_pending "serviço de preparação da rede da VM está ausente ou desatualizado."
    return 1
  fi
  if [[ ! -x "${network_helper}" ]] || ! cmp -s <(render_network_helper) "${network_helper}"; then
    check_pending "helper de validação da rede HML está ausente ou desatualizado."
    return 1
  fi
  if [[ ! -r "${kubelet_dropin}" ]] || ! cmp -s <(render_kubelet_dropin) "${kubelet_dropin}"; then
    check_pending "dependência do kubelet na preparação da rede está ausente."
    return 1
  fi
  if [[ ! -r "${sysctl_file}" ]] || ! cmp -s <(render_sysctl) "${sysctl_file}"; then
    check_pending "parâmetros de rede Kubernetes estão ausentes ou desatualizados."
    return 1
  fi
  systemctl is-enabled --quiet "${NODE_NETWORK_SERVICE}" || {
    check_pending "${NODE_NETWORK_SERVICE} não está habilitado."
    return 1
  }
  systemctl is-active --quiet "${NODE_NETWORK_SERVICE}" || {
    check_pending "${NODE_NETWORK_SERVICE} não está ativo."
    return 1
  }
  node_ip_is_local_physical "${NODE_IP}" || {
    check_pending "NODE_IP=${NODE_IP} não está presente em uma interface física da VM."
    return 1
  }
  kernel_features_ok || return 1
  [[ "$(sysctl -n net.bridge.bridge-nf-call-iptables 2>/dev/null)" == "1" ]] || return 1
  [[ "$(sysctl -n net.bridge.bridge-nf-call-ip6tables 2>/dev/null)" == "1" ]] || return 1
  [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" == "1" ]] || return 1
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
    [[ " ${reinstall_packages[*]} " == *" ${package_name} "* ]] || reinstall_packages+=("${package_name}")
  fi
done
if (( ${#missing_packages[@]} > 0 || ${#reinstall_packages[@]} > 0 )); then
  log "Instalando ou reparando os pacotes básicos do host."
  apt_install_with_cache host -y --reinstall --no-install-recommends "${required_packages[@]}"
fi

log "Preparando recursos de kernel e validando o endereço existente da VM HML."
modprobe overlay 2>/dev/null || true
modprobe br_netfilter 2>/dev/null || true
kernel_features_ok \
  || die "o kernel da VM não oferece overlay/br_netfilter; instale o kernel padrão do Ubuntu 26.04 LTS."
node_ip_is_local_physical "${NODE_IP}" \
  || die "NODE_IP=${NODE_IP} não existe em uma interface física da VM. A configuração de rede deve estar pronta antes de instalar."

install -d -o root -g root -m 0755 /etc/systemd/system/kubelet.service.d
temporary_unit="$(mktemp)"
temporary_dropin="$(mktemp)"
temporary_sysctl="$(mktemp)"
temporary_helper="$(mktemp)"
trap 'rm -f -- "${temporary_unit}" "${temporary_dropin}" "${temporary_sysctl}" "${temporary_helper}"' EXIT
render_node_ip_unit >"${temporary_unit}"
render_kubelet_dropin >"${temporary_dropin}"
render_sysctl >"${temporary_sysctl}"
render_network_helper >"${temporary_helper}"
if [[ -r "${node_ip_unit}" ]] && ! cmp -s "${temporary_unit}" "${node_ip_unit}" \
  && systemctl is-active --quiet "${NODE_NETWORK_SERVICE}"; then
  systemctl stop "${NODE_NETWORK_SERVICE}"
fi
install -o root -g root -m 0644 "${temporary_unit}" "${node_ip_unit}"
install -o root -g root -m 0644 "${temporary_dropin}" "${kubelet_dropin}"
install -o root -g root -m 0644 "${temporary_sysctl}" "${sysctl_file}"
install -d -o root -g root -m 0755 /usr/local/sbin
install -o root -g root -m 0755 "${temporary_helper}" "${network_helper}"

systemctl daemon-reload
systemctl enable "${NODE_NETWORK_SERVICE}"
systemctl restart "${NODE_NETWORK_SERVICE}"
sysctl -q -w net.bridge.bridge-nf-call-iptables=1
sysctl -q -w net.bridge.bridge-nf-call-ip6tables=1
sysctl -q -w net.ipv4.ip_forward=1

if swapon --show --noheadings 2>/dev/null | grep -q .; then
  log "Swap do Ubuntu foi preservado; o kubelet será configurado com failSwapOn=false e NoSwap para Pods."
fi

host_state_ok || die "a preparação da VM terminou, mas o estado esperado não foi atingido."
log "VM HML preparada: módulos, sysctl e validação de NODE_IP configurados."
