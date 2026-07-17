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

# shellcheck source=scripts/lib/common.sh
source "${ROOT_DIR}/scripts/lib/common.sh"

if command -v flock >/dev/null 2>&1; then
  exec 9>/run/lock/k8s-bootstrap.lock
  flock -n 9 || die "já existe outra execução do instalador em andamento."
fi

"${ROOT_DIR}/scripts/00-preflight.sh"
mark_step_complete "00-preflight"

steps=(
  10-prepare-host.sh
  20-install-containerd.sh
  30-install-kubernetes.sh
  40-bootstrap-cluster.sh
  50-install-network.sh
  60-install-dashboard.sh
  70-configure-firewall.sh
  80-create-users.sh
)

for step in "${steps[@]}"; do
  step_path="${ROOT_DIR}/scripts/${step}"
  step_name="${step%.sh}"
  printf '\n\033[1;36m==> Verificando %s\033[0m\n' "${step}"
  if "${step_path}" --check; then
    log "${step}: estado já está correto; nenhuma alteração necessária."
  else
    printf '\033[1;36m==> Reconciliando %s\033[0m\n' "${step}"
    "${step_path}"
    if ! "${step_path}" --check; then
      die "${step} terminou, mas a verificação pós-execução ainda falha."
    fi
  fi
  mark_step_complete "${step_name}"
done

printf '\n\033[1;36m==> Executando verificação final\033[0m\n'
"${ROOT_DIR}/scripts/90-verify.sh"
mark_step_complete "90-verify"

printf '\n\033[1;32mInstalação concluída. Consulte %s/README.md para acessar o Dashboard.\033[0m\n' "${ROOT_DIR}"
