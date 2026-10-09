#!/usr/bin/env bash
# Diagnóstico sem kubeconfig/registro. --configure-ca autoriza gravar o cache CA.
set +x
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
usage() {
  cat <<EOF
Uso:
  bash $0 [--configure-ca] URL_HTTPS [ARQUIVO_CA]
  K8S_CONFIG_FILE=/caminho/cluster.env bash $0

Testa /ping com TLS obrigatório; usa CA explícita ou já autorizada no estado local.
--configure-ca descobre e propõe a CA privada para aceite interativo ou pin
RANCHER_CA_FINGERPRINT. Precisa de escrita em BOOTSTRAP_STATE_DIR, normalmente
via sudo. Não altera a confiança global do sistema nem registra clusters.
EOF
}
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi
configure_ca=false
if [[ "${1:-}" == --configure-ca ]]; then
  configure_ca=true
  shift
fi
[[ $# -le 2 ]] || { usage >&2; exit 2; }
requested_url="${1:-}"
requested_ca="${2:-}"
# shellcheck source=scripts/lib/common.sh
source "${ROOT_DIR}/scripts/lib/common.sh"
# shellcheck source=scripts/lib/rancher-endpoint.sh
source "${ROOT_DIR}/scripts/lib/rancher-endpoint.sh"

if [[ -n "${requested_url}" ]]; then
  RANCHER_URL="${requested_url}"
fi
if [[ $# -eq 2 ]]; then
  RANCHER_CA_FILE="${requested_ca}"
fi
RANCHER_URL="${RANCHER_URL%/}"
valid_https_url "${RANCHER_URL}" || die "informe a URL HTTPS do Rancher, sem credenciais, caminho ou query."
if [[ "${configure_ca}" == true ]]; then
  prepare_rancher_ca
fi
validate_rancher_endpoint
