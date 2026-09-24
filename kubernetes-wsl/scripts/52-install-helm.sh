#!/usr/bin/env bash

# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_root

helm_state_ok() {
  local installed_version
  [[ -x /usr/local/bin/helm ]] || {
    check_pending "Helm não está instalado em /usr/local/bin/helm."
    return 1
  }
  installed_version="$(/usr/local/bin/helm version --template '{{.Version}}' 2>/dev/null || true)"
  [[ "${installed_version}" == "${HELM_VERSION}" ]] || {
    check_pending "Helm instalado (${installed_version:-desconhecido}) difere de ${HELM_VERSION}."
    return 1
  }
}

if check_requested "${1:-}"; then
  if helm_state_ok; then
    exit 0
  fi
  exit 1
fi

require_command curl
require_command sha256sum
require_command tar

case "$(uname -m)" in
  x86_64)
    helm_arch="amd64"
    helm_checksum="${HELM_SHA256_AMD64}"
    ;;
  aarch64)
    helm_arch="arm64"
    helm_checksum="${HELM_SHA256_ARM64}"
    ;;
  *) die "arquitetura sem binário Helm homologado: $(uname -m)." ;;
esac

temporary_dir="$(mktemp -d /tmp/k8s-wsl-helm.XXXXXX)"
cleanup_temporary_dir() {
  if [[ "${temporary_dir}" == /tmp/k8s-wsl-helm.* && -d "${temporary_dir}" ]]; then
    rm -rf -- "${temporary_dir}"
  fi
}
trap cleanup_temporary_dir EXIT
archive="${temporary_dir}/helm.tar.gz"
version_without_prefix="${HELM_VERSION#v}"
download_url="https://get.helm.sh/helm-v${version_without_prefix}-linux-${helm_arch}.tar.gz"

log "Baixando Helm ${HELM_VERSION} para linux/${helm_arch} com verificação SHA-256."
retry 3 3 curl -fL --retry 2 --connect-timeout 15 "${download_url}" -o "${archive}"
printf '%s  %s\n' "${helm_checksum}" "${archive}" | sha256sum --check --status \
  || die "checksum do pacote Helm ${HELM_VERSION} não confere."

tar -xzf "${archive}" -C "${temporary_dir}"
[[ -x "${temporary_dir}/linux-${helm_arch}/helm" ]] \
  || die "pacote Helm não contém o binário esperado para linux/${helm_arch}."
install -o root -g root -m 0755 "${temporary_dir}/linux-${helm_arch}/helm" /usr/local/bin/helm

helm_state_ok || die "Helm foi instalado, mas a validação de versão falhou."
log "Helm ${HELM_VERSION} instalado de forma reproduzível em /usr/local/bin/helm."
