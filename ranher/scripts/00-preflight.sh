#!/usr/bin/env bash
# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
require_root
validate_config
# shellcheck source=/dev/null
source /etc/os-release
[[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" == 26.04 ]] || die 'Esta instalação exige Ubuntu 26.04 LTS em uma VM dedicada.'
host_is_wsl && die 'Instale o servidor Rancher em uma VM dedicada, fora do WSL e do cluster administrado.'
if [[ -e /etc/kubernetes/admin.conf ]] || systemctl is-active --quiet kubelet; then
  die 'Esta máquina já pertence a um cluster kubeadm; use uma VM dedicada para o servidor Rancher.'
fi
(( $(nproc) >= 4 )) || die 'Rancher exige pelo menos 4 vCPUs nesta variante.'
(( $(awk '/MemTotal:/ {print $2}' /proc/meminfo) >= 7800000 )) || die 'Rancher exige pelo menos 8 GiB de RAM nesta variante.'
(( $(df -Pk / | awk 'NR == 2 {print $4}') >= 20971520 )) || die 'Rancher exige pelo menos 20 GiB livres após expansão da raiz.'
log 'VM, relógio, disco e DNS aprovados.'
