#!/usr/bin/env bash

# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_root
export DEBIAN_FRONTEND=noninteractive

log "Configurando o repositório oficial Kubernetes ${KUBERNETES_MINOR}."
install -d -o root -g root -m 0755 /etc/apt/keyrings
key_file="$(mktemp)"
trap 'rm -f -- "${key_file}"' EXIT

retry 3 3 curl -fsSL "https://pkgs.k8s.io/core:/stable:/${KUBERNETES_MINOR}/deb/Release.key" -o "${key_file}"
gpg --dearmor --yes --output /etc/apt/keyrings/kubernetes-apt-keyring.gpg "${key_file}"
chmod 0644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg

cat >/etc/apt/sources.list.d/kubernetes.list <<EOF
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBERNETES_MINOR}/deb/ /
EOF
chmod 0644 /etc/apt/sources.list.d/kubernetes.list

apt-get update
apt-get install -y kubelet kubeadm kubectl kubernetes-cni
apt-mark hold kubelet kubeadm kubectl kubernetes-cni >/dev/null
systemctl enable kubelet

log "Kubernetes instalado: $(kubeadm version -o short)."

