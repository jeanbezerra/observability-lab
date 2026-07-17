#!/usr/bin/env bash

# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_root
export DEBIAN_FRONTEND=noninteractive

log "Instalando containerd e runc."
apt-get install -y --no-install-recommends containerd runc

install -d -o root -g root -m 0755 /etc/containerd
temporary_config="$(mktemp)"
trap 'rm -f -- "${temporary_config}"' EXIT
containerd config default >"${temporary_config}"

# Funciona nos layouts de configuração do containerd 1.x e 2.x.
sed -i -E 's/(SystemdCgroup[[:space:]]*=[[:space:]]*)false/\1true/g' "${temporary_config}"
grep -Eq 'SystemdCgroup[[:space:]]*=[[:space:]]*true' "${temporary_config}" \
  || die "a configuração gerada pelo containerd não contém SystemdCgroup=true."

install -o root -g root -m 0644 "${temporary_config}" /etc/containerd/config.toml
systemctl daemon-reload
systemctl enable --now containerd
systemctl restart containerd
systemctl is-active --quiet containerd || die "containerd não iniciou."

log "containerd configurado com cgroup systemd: $(containerd --version)."

