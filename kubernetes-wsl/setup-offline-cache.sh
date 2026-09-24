#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${ROOT_DIR}/scripts/lib/common.sh"

published_bundle_file="${ROOT_DIR}/offline-bundle-builder/published-bundle.env"
[[ -r "${published_bundle_file}" ]] \
  || die "metadados do bundle publicado não encontrados: ${published_bundle_file}."
# shellcheck source=offline-bundle-builder/published-bundle.env
source "${published_bundle_file}"

: "${PUBLISHED_BUNDLE_NAME:?PUBLISHED_BUNDLE_NAME ausente em published-bundle.env}"
: "${PUBLISHED_BUNDLE_ARCHITECTURE:?PUBLISHED_BUNDLE_ARCHITECTURE ausente em published-bundle.env}"
: "${PUBLISHED_BUNDLE_BASE_URL:?PUBLISHED_BUNDLE_BASE_URL ausente em published-bundle.env}"
[[ "${PUBLISHED_BUNDLE_NAME}" =~ ^[A-Za-z0-9._-]+\.tar\.gz$ ]] \
  || die "PUBLISHED_BUNDLE_NAME contém um nome inseguro."
[[ "${PUBLISHED_BUNDLE_ARCHITECTURE}" =~ ^(amd64|arm64)$ ]] \
  || die "PUBLISHED_BUNDLE_ARCHITECTURE precisa ser amd64 ou arm64."
[[ "${PUBLISHED_BUNDLE_BASE_URL}" == https://* && "${PUBLISHED_BUNDLE_BASE_URL}" != *[[:space:]]* ]] \
  || die "PUBLISHED_BUNDLE_BASE_URL precisa ser uma URL HTTPS sem espaços."

readonly BUNDLE_NAME="${PUBLISHED_BUNDLE_NAME}"
readonly BUNDLE_URL="${PUBLISHED_BUNDLE_BASE_URL%/}/${BUNDLE_NAME}"
readonly CHECKSUM_URL="${BUNDLE_URL}.sha256"

usage() {
  cat <<EOF
Uso: bash $0

Baixa e valida o bundle publicado, instala o cache em:
  ${ARTIFACT_CACHE_DIR}

Também cria, quando ausente, e configura:
  ${PROJECT_DIR}/cluster.env

Imagens de contêiner não fazem parte do bundle e continuam sendo baixadas.
EOF
}

case "${1:-}" in
  '') ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
[[ $# -eq 0 ]] || { usage >&2; exit 2; }

require_command curl
require_command sha256sum
require_command tar

architecture="$(artifact_arch)" || die "arquitetura não suportada: $(uname -m)."
[[ "${architecture}" == "${PUBLISHED_BUNDLE_ARCHITECTURE}" ]] \
  || die "o bundle publicado é ${PUBLISHED_BUNDLE_ARCHITECTURE}, mas este Ubuntu usa ${architecture}."

cache_parent="$(realpath -m -- "${ARTIFACT_CACHE_DIR}")"
cache_root="${cache_parent}/${architecture}"
[[ "${cache_root}" == "${cache_parent}/"* && "${cache_root}" != "${cache_parent}" ]] \
  || die "destino de cache inseguro: ${cache_root}."
install -d -m 0755 "${cache_parent}"

download_dir="$(mktemp -d /tmp/k8s-wsl-cache-download.XXXXXX)"
staging_dir="$(mktemp -d "${cache_parent}/.import.XXXXXX")"
cleanup() {
  if [[ "${download_dir}" == /tmp/k8s-wsl-cache-download.* && -d "${download_dir}" ]]; then
    rm -rf -- "${download_dir}"
  fi
  if [[ "${staging_dir}" == "${cache_parent}/.import."* && -d "${staging_dir}" ]]; then
    rm -rf -- "${staging_dir}"
  fi
}
trap cleanup EXIT

archive="${download_dir}/${BUNDLE_NAME}"
checksum_file="${archive}.sha256"

log "Baixando o checksum do bundle."
retry "${ARTIFACT_RETRY_ATTEMPTS}" "${ARTIFACT_RETRY_DELAY_SECONDS}" \
  curl -fL --retry 4 --retry-delay 5 \
  --connect-timeout "${ARTIFACT_CONNECT_TIMEOUT_SECONDS}" \
  "${CHECKSUM_URL}" -o "${checksum_file}"

log "Baixando o bundle de aproximadamente 191 MiB diretamente para uma área temporária."
retry "${ARTIFACT_RETRY_ATTEMPTS}" "${ARTIFACT_RETRY_DELAY_SECONDS}" \
  curl -fL --retry 4 --retry-delay 5 \
  --connect-timeout "${ARTIFACT_CONNECT_TIMEOUT_SECONDS}" \
  "${BUNDLE_URL}" -o "${archive}"

(cd -- "${download_dir}" && sha256sum --check "$(basename -- "${checksum_file}")") \
  || die "o bundle baixado não corresponde ao SHA-256 publicado."

if tar -tzf "${archive}" | grep -Ev "^${architecture}(/|$)" | grep -q .; then
  die "o bundle contém caminhos fora do diretório ${architecture}."
fi
tar -xzf "${archive}" -C "${staging_dir}"

original_cache_dir="${ARTIFACT_CACHE_DIR}"
ARTIFACT_CACHE_DIR="${staging_dir}"
artifact_cache_complete \
  || die "o conteúdo extraído está incompleto, corrompido ou incompatível."
ARTIFACT_CACHE_DIR="${original_cache_dir}"

staged_cache="${staging_dir}/${architecture}"
backup_cache="${cache_parent}/.${architecture}.previous.$$"
had_previous=false
if [[ -e "${cache_root}" ]]; then
  mv -- "${cache_root}" "${backup_cache}"
  had_previous=true
fi
if mv -- "${staged_cache}" "${cache_root}"; then
  if is_true "${had_previous}"; then
    rm -rf -- "${backup_cache}"
  fi
else
  if is_true "${had_previous}" && [[ -e "${backup_cache}" ]]; then
    mv -- "${backup_cache}" "${cache_root}"
  fi
  die "não foi possível ativar o novo cache; o cache anterior foi preservado."
fi

cluster_config="${PROJECT_DIR}/cluster.env"
if [[ ! -e "${cluster_config}" ]]; then
  install -m 0600 "${PROJECT_DIR}/.env.example" "${cluster_config}"
  log "cluster.env criado a partir de .env.example."
elif [[ ! -f "${cluster_config}" ]]; then
  die "${cluster_config} existe, mas não é um arquivo comum."
fi

if grep -q '^ARTIFACT_MODE=' "${cluster_config}"; then
  sed -i -E 's/^ARTIFACT_MODE=.*/ARTIFACT_MODE="offline"/' "${cluster_config}"
else
  printf '\nARTIFACT_MODE="offline"\n' >>"${cluster_config}"
fi
chmod 0600 "${cluster_config}" 2>/dev/null || true

project_owner="$(stat -c '%u:%g' "${PROJECT_DIR}")"
if [[ "${EUID}" -eq 0 ]]; then
  chown -R "${project_owner}" "${cache_root}" "${cluster_config}" 2>/dev/null || true
fi

artifact_cache_complete \
  || die "o cache instalado falhou na verificação final."

log "Cache instalado e cluster.env configurado para ARTIFACT_MODE=offline."
printf '\nPróximo comando:\n  sudo bash %q %q\n' \
  "${PROJECT_DIR}/install-all.sh" "${cluster_config}"
