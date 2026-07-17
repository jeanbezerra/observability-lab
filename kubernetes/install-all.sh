#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${EUID}" -ne 0 ]]; then
  printf 'ERRO: execute como root: sudo bash %s [cluster.env]\n' "$0" >&2
  exit 1
fi

if [[ $# -gt 1 ]]; then
  printf 'Uso: sudo bash %s [cluster.env]\n' "$0" >&2
  exit 2
fi

if [[ $# -eq 1 ]]; then
  K8S_CONFIG_FILE="$(realpath -- "$1")"
  export K8S_CONFIG_FILE
fi

# Corrige permissões mesmo quando os arquivos vieram de um volume Windows/ZIP.
find "${ROOT_DIR}/scripts" -type f -name '*.sh' -exec chmod 0750 {} +
chmod 0750 "${ROOT_DIR}/install-all.sh"
find "${ROOT_DIR}/manifests" -type f -exec chmod 0640 {} +

steps=(
  00-preflight.sh
  10-prepare-host.sh
  20-install-containerd.sh
  30-install-kubernetes.sh
  40-bootstrap-cluster.sh
  50-install-network.sh
  60-install-dashboard.sh
  70-configure-firewall.sh
  80-create-users.sh
  90-verify.sh
)

for step in "${steps[@]}"; do
  printf '\n\033[1;36m==> Executando %s\033[0m\n' "${step}"
  "${ROOT_DIR}/scripts/${step}"
done

printf '\n\033[1;32mInstalação concluída. Consulte %s/README.md para acessar o Dashboard.\033[0m\n' "${ROOT_DIR}"
