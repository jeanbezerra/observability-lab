#!/usr/bin/env bash

# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_root
export DEBIAN_FRONTEND=noninteractive

required_packages=(
  apt-transport-https ca-certificates conntrack curl ebtables ethtool gpg iproute2
  iptables kmod openssl procps socat tar
)
required_command_packages=(
  curl:curl gpg:gpg ip:iproute2 iptables:iptables modprobe:kmod
  openssl:openssl sysctl:procps tar:tar
)
node_ip_unit="/etc/systemd/system/${WSL_NODE_IP_SERVICE}"
kubelet_dropin="/etc/systemd/system/kubelet.service.d/05-k8s-wsl-node-ip.conf"
sysctl_file="/etc/sysctl.d/99-kubernetes-wsl.conf"

render_node_ip_unit() {
  cat <<EOF
[Unit]
Description=Stable loopback address for the local Kubernetes node on WSL 2
After=network.target
Before=containerd.service kubelet.service

[Service]
Type=oneshot
ExecStartPre=-/usr/sbin/modprobe overlay
ExecStartPre=-/usr/sbin/modprobe br_netfilter
ExecStart=/usr/sbin/ip address replace ${NODE_IP}/32 dev lo
ExecStart=/usr/sbin/sysctl -q -w net.bridge.bridge-nf-call-iptables=1
ExecStart=/usr/sbin/sysctl -q -w net.bridge.bridge-nf-call-ip6tables=1
ExecStart=/usr/sbin/sysctl -q -w net.ipv4.ip_forward=1
ExecStop=-/usr/sbin/ip address del ${NODE_IP}/32 dev lo
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
}

render_kubelet_dropin() {
  cat <<EOF
[Unit]
Requires=${WSL_NODE_IP_SERVICE}
After=${WSL_NODE_IP_SERVICE}
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
    check_pending "filesystem overlay não está disponível no kernel WSL."
    return 1
  }
  [[ -e /proc/sys/net/bridge/bridge-nf-call-iptables ]] || {
    check_pending "br_netfilter não está disponível no kernel WSL."
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
    check_pending "usuário WSL ${ADMIN_USER} não existe."
    return 1
  }
  if [[ ! -r "${node_ip_unit}" ]] || ! cmp -s <(render_node_ip_unit) "${node_ip_unit}"; then
    check_pending "serviço do endereço estável do WSL está ausente ou desatualizado."
    return 1
  fi
  if [[ ! -r "${kubelet_dropin}" ]] || ! cmp -s <(render_kubelet_dropin) "${kubelet_dropin}"; then
    check_pending "dependência do kubelet no endereço estável está ausente."
    return 1
  fi
  if [[ ! -r "${sysctl_file}" ]] || ! cmp -s <(render_sysctl) "${sysctl_file}"; then
    check_pending "parâmetros de rede Kubernetes estão ausentes ou desatualizados."
    return 1
  fi
  systemctl is-enabled --quiet "${WSL_NODE_IP_SERVICE}" || {
    check_pending "${WSL_NODE_IP_SERVICE} não está habilitado."
    return 1
  }
  systemctl is-active --quiet "${WSL_NODE_IP_SERVICE}" || {
    check_pending "${WSL_NODE_IP_SERVICE} não está ativo."
    return 1
  }
  ip -4 address show dev lo | grep -Fq "${NODE_IP}/32" || {
    check_pending "endereço estável ${NODE_IP}/32 não está na interface loopback."
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

log "Preparando recursos de kernel e um endereço de nó estável para reinícios do WSL."
modprobe overlay 2>/dev/null || true
modprobe br_netfilter 2>/dev/null || true
kernel_features_ok \
  || die "o kernel WSL atual não oferece overlay/br_netfilter; execute 'wsl.exe --update' no CMD e tente novamente."

install -d -o root -g root -m 0755 /etc/systemd/system/kubelet.service.d
temporary_unit="$(mktemp)"
temporary_dropin="$(mktemp)"
temporary_sysctl="$(mktemp)"
trap 'rm -f -- "${temporary_unit}" "${temporary_dropin}" "${temporary_sysctl}"' EXIT
render_node_ip_unit >"${temporary_unit}"
render_kubelet_dropin >"${temporary_dropin}"
render_sysctl >"${temporary_sysctl}"
if [[ -r "${node_ip_unit}" ]] && ! cmp -s "${temporary_unit}" "${node_ip_unit}" \
  && systemctl is-active --quiet "${WSL_NODE_IP_SERVICE}"; then
  systemctl stop "${WSL_NODE_IP_SERVICE}"
fi
install -o root -g root -m 0644 "${temporary_unit}" "${node_ip_unit}"
install -o root -g root -m 0644 "${temporary_dropin}" "${kubelet_dropin}"
install -o root -g root -m 0644 "${temporary_sysctl}" "${sysctl_file}"

systemctl daemon-reload
systemctl enable "${WSL_NODE_IP_SERVICE}"
systemctl start "${WSL_NODE_IP_SERVICE}"
ip address replace "${NODE_IP}/32" dev lo
sysctl -q -w net.bridge.bridge-nf-call-iptables=1
sysctl -q -w net.bridge.bridge-nf-call-ip6tables=1
sysctl -q -w net.ipv4.ip_forward=1

if swapon --show --noheadings 2>/dev/null | grep -q .; then
  log "Swap gerenciado pelo WSL foi preservado; o kubelet será configurado com failSwapOn=false e NoSwap para Pods."
fi

host_state_ok || die "a preparação do host WSL terminou, mas o estado esperado não foi atingido."
log "Host WSL preparado sem alterar UFW, Windows Firewall ou /etc/fstab."
