#!/usr/bin/env bash
# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
require_root
validate_config
if check_requested "${1:-}"; then
  for package in ca-certificates curl openssl nginx ufw; do
    dpkg-query -W -f='${Status}' "${package}" 2>/dev/null | grep -q 'ok installed' || die "Pacote pendente: ${package}."
  done
  if ! command -v docker >/dev/null || ! docker info >/dev/null; then die 'Docker pendente.'; fi
  if ! systemctl is-enabled --quiet docker || ! systemctl is-active --quiet docker; then die 'Serviço Docker pendente.'; fi
  exit 0
fi
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl openssl nginx ufw
if ! command -v docker >/dev/null; then
  # Do not replace runtimes used by another installation on this host.
  if dpkg-query -W -f='${Status}' containerd 2>/dev/null | grep -q 'ok installed'; then
    die 'containerd já instalado fora do Docker; use uma VM dedicada sem runtime conflitante.'
  fi
  install -d -m 0755 /etc/apt/keyrings
  curl --fail --silent --show-error --proto '=https' --tlsv1.2 https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod 0644 /etc/apt/keyrings/docker.asc
  # shellcheck source=/dev/null
  source /etc/os-release
  cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-${VERSION_CODENAME}}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  apt-get update
  apt-get install -y --no-install-recommends docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
systemctl enable --now docker
docker info >/dev/null || die 'Docker não ficou operacional.'
