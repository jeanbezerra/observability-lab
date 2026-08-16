#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${EUID}" -ne 0 ]]; then
  printf 'ERRO: execute como root: sudo bash %s [keycloak.env] [secrets.env]\n' "$0" >&2
  exit 1
fi

if [[ $# -gt 2 ]]; then
  printf 'Uso: sudo bash %s [keycloak.env] [secrets.env]\n' "$0" >&2
  exit 2
fi

if [[ $# -ge 1 ]]; then
  KEYCLOAK_CONFIG_FILE="$(realpath -- "$1")"
  export KEYCLOAK_CONFIG_FILE
fi
if [[ $# -eq 2 ]]; then
  KEYCLOAK_SECRETS_FILE="$(realpath -- "$2")"
  export KEYCLOAK_SECRETS_FILE
fi

find "${ROOT_DIR}/scripts" -type f -name '*.sh' -exec chmod 0750 {} +
chmod 0750 "${ROOT_DIR}/install-all.sh"
find "${ROOT_DIR}/systemd" -type f -exec chmod 0640 {} +

# shellcheck source=scripts/lib/common.sh
source "${ROOT_DIR}/scripts/lib/common.sh"

if command -v flock >/dev/null 2>&1; then
  exec 9>/run/lock/keycloak-bootstrap.lock
  flock -n 9 || die "já existe outra execução do instalador Keycloak em andamento."
fi

"${ROOT_DIR}/scripts/00-preflight.sh"
mark_step_complete "00-preflight"

steps=(
  10-prepare-host.sh
  20-install-postgresql.sh
  30-configure-tls.sh
  40-install-keycloak.sh
  50-configure-service.sh
  60-configure-realm.sh
  70-configure-firewall.sh
  80-configure-backup.sh
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

printf '\n\033[1;32mKeycloak instalado e validado. Consulte %s/README.md.\033[0m\n' "${ROOT_DIR}"

