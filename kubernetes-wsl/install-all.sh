#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${EUID}" -ne 0 ]]; then
  printf 'ERRO: execute dentro do Ubuntu WSL: sudo bash %s [cluster.env]\n' "$0" >&2
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

# Os scripts são chamados via bash para também funcionar quando o repositório
# está em DrvFS (/mnt/c), onde bits POSIX de execução podem não ser preservados.
# shellcheck source=scripts/lib/common.sh
source "${ROOT_DIR}/scripts/lib/common.sh"

if command -v flock >/dev/null 2>&1; then
  exec 9>/run/lock/k8s-wsl-bootstrap.lock
  flock -n 9 || die "já existe outra execução do instalador em andamento."
fi

bash "${ROOT_DIR}/scripts/00-preflight.sh"
mark_step_complete "00-preflight"

steps=(
  10-prepare-host.sh
  20-install-containerd.sh
  30-install-kubernetes.sh
  40-bootstrap-cluster.sh
  50-install-network.sh
  52-install-helm.sh
  55-install-gateway.sh
  60-install-dashboard.sh
  70-configure-local-access.sh
  75-configure-gateway-access.sh
)

for step in "${steps[@]}"; do
  step_path="${ROOT_DIR}/scripts/${step}"
  step_name="${step%.sh}"
  printf '\n\033[1;36m==> Verificando %s\033[0m\n' "${step}"
  if bash "${step_path}" --check; then
    log "${step}: estado já está correto; nenhuma alteração necessária."
  else
    printf '\033[1;36m==> Reconciliando %s\033[0m\n' "${step}"
    bash "${step_path}"
    bash "${step_path}" --check \
      || die "${step} terminou, mas a verificação pós-execução ainda falha."
  fi
  mark_step_complete "${step_name}"
done

printf '\n\033[1;36m==> Executando verificação final\033[0m\n'
bash "${ROOT_DIR}/scripts/90-verify.sh"
mark_step_complete "90-verify"

printf '\n\033[1;32mInstalação concluída. Abra https://localhost:%s/?lng=%s no Windows.\033[0m\n' \
  "${DASHBOARD_LOCAL_PORT}" "${DASHBOARD_DEFAULT_LANGUAGE}"
printf '\033[1;32mGateway API pronto e fechado no Windows. Use windows\\25-open-gateway-port.cmd; destino local: http://localhost:%s.\033[0m\n' \
  "${GATEWAY_LOCAL_PORT}"
