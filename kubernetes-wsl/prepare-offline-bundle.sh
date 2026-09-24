#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${ROOT_DIR}/scripts/lib/common.sh"

usage() {
  cat <<EOF
Uso: sudo bash $0 [--force]

Baixa os artefatos de instalação para offline-cache/ e gera um .tar.gz em
dist/. O bundle inclui pacotes .deb, chave Kubernetes, Helm, Flannel e charts
do Envoy Gateway. Imagens de contêiner não são incluídas.

--force  substitui somente o cache da arquitetura atual, se ele já existir
EOF
}

force=false
case "${1:-}" in
  '') ;;
  --force) force=true ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { usage >&2; exit 2; }

require_root
require_command apt-get
require_command curl
require_command sha256sum
require_command tar

architecture="$(artifact_arch)" || die "arquitetura não suportada: $(uname -m)."
cache_parent="$(realpath -m -- "${ARTIFACT_CACHE_DIR}")"
cache_root="${cache_parent}/${architecture}"
[[ "${cache_root}" == "${cache_parent}/"* && "${cache_root}" != "${cache_parent}" ]] \
  || die "destino de cache inseguro: ${cache_root}."

if [[ -e "${cache_root}" ]]; then
  is_true "${force}" \
    || die "${cache_root} já existe. Preserve-o ou execute novamente com --force para substituí-lo."
fi

work_dir="$(mktemp -d /tmp/k8s-wsl-artifacts.XXXXXX)"
chmod 0755 "${work_dir}"
cleanup() {
  if [[ "${work_dir}" == /tmp/k8s-wsl-artifacts.* && -d "${work_dir}" ]]; then
    rm -rf -- "${work_dir}"
  fi
}
trap cleanup EXIT

staging_root="${work_dir}/${architecture}"
artifact_dir="${staging_root}/artifacts"
chart_dir="${staging_root}/charts"
apt_root="${work_dir}/apt-state"
install -d -m 0755 "${artifact_dir}" "${chart_dir}" \
  "${staging_root}/apt/host" "${staging_root}/apt/containerd" \
  "${staging_root}/apt/kubernetes" "${apt_root}/sources.list.d" \
  "${apt_root}/lists/partial"

version_without_prefix="${HELM_VERSION#v}"
helm_archive="${artifact_dir}/helm-${HELM_VERSION}-linux-${architecture}.tar.gz"
flannel_manifest="${artifact_dir}/kube-flannel-${FLANNEL_VERSION}.yml"
kubernetes_key="${artifact_dir}/kubernetes-${KUBERNETES_MINOR}-Release.key"
gateway_chart="${chart_dir}/gateway-helm-${ENVOY_GATEWAY_VERSION}.tgz"
crds_chart="${chart_dir}/gateway-crds-helm-${ENVOY_GATEWAY_VERSION}.tgz"

case "${architecture}" in
  amd64) helm_checksum="${HELM_SHA256_AMD64}" ;;
  arm64) helm_checksum="${HELM_SHA256_ARM64}" ;;
esac

log "Baixando chave do Kubernetes, Helm e manifesto do Flannel."
retry "${ARTIFACT_RETRY_ATTEMPTS}" "${ARTIFACT_RETRY_DELAY_SECONDS}" \
  curl -fL --retry 4 --retry-delay 5 \
  --connect-timeout "${ARTIFACT_CONNECT_TIMEOUT_SECONDS}" \
  "https://pkgs.k8s.io/core:/stable:/${KUBERNETES_MINOR}/deb/Release.key" \
  -o "${kubernetes_key}"
retry "${ARTIFACT_RETRY_ATTEMPTS}" "${ARTIFACT_RETRY_DELAY_SECONDS}" \
  curl -fL --retry 4 --retry-delay 5 \
  --connect-timeout "${ARTIFACT_CONNECT_TIMEOUT_SECONDS}" \
  "https://get.helm.sh/helm-v${version_without_prefix}-linux-${architecture}.tar.gz" \
  -o "${helm_archive}"
retry "${ARTIFACT_RETRY_ATTEMPTS}" "${ARTIFACT_RETRY_DELAY_SECONDS}" \
  curl -fL --retry 4 --retry-delay 5 \
  --connect-timeout "${ARTIFACT_CONNECT_TIMEOUT_SECONDS}" \
  "https://github.com/flannel-io/flannel/releases/download/${FLANNEL_VERSION}/kube-flannel.yml" \
  -o "${flannel_manifest}"
printf '%s  %s\n' "${helm_checksum}" "${helm_archive}" | sha256sum --check --status \
  || die "checksum do Helm baixado não confere."
printf '%s  %s\n' "${FLANNEL_SHA256}" "${flannel_manifest}" | sha256sum --check --status \
  || die "checksum do Flannel baixado não confere."

helm_extract="${work_dir}/helm"
install -d -m 0755 "${helm_extract}"
tar -xzf "${helm_archive}" -C "${helm_extract}"
helm_binary="${helm_extract}/linux-${architecture}/helm"
[[ -x "${helm_binary}" ]] || die "arquivo do Helm não contém o binário esperado."
registry_config="${work_dir}/registry.json"
printf '{}\n' >"${registry_config}"

log "Baixando charts OCI do Envoy Gateway ${ENVOY_GATEWAY_VERSION}."
env PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/sbin" \
  "${helm_binary}" pull oci://docker.io/envoyproxy/gateway-crds-helm \
  --version "${ENVOY_GATEWAY_VERSION}" --destination "${chart_dir}" \
  --registry-config "${registry_config}"
env PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/sbin" \
  "${helm_binary}" pull oci://docker.io/envoyproxy/gateway-helm \
  --version "${ENVOY_GATEWAY_VERSION}" --destination "${chart_dir}" \
  --registry-config "${registry_config}"
printf '%s  %s\n' "${ENVOY_GATEWAY_CRDS_CHART_SHA256}" "${crds_chart}" \
  | sha256sum --check --status || die "checksum do chart de CRDs não confere."
printf '%s  %s\n' "${ENVOY_GATEWAY_CHART_SHA256}" "${gateway_chart}" \
  | sha256sum --check --status || die "checksum do chart principal não confere."

# Copia as fontes APT existentes para um estado temporário, removendo qualquer
# definição Kubernetes anterior. A fonte do minor escolhido é adicionada abaixo.
: >"${apt_root}/sources.list"
if [[ -r /etc/apt/sources.list ]]; then
  cp -- /etc/apt/sources.list "${apt_root}/sources.list"
fi
for source_file in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
  [[ -r "${source_file}" ]] || continue
  grep -Fq 'pkgs.k8s.io' "${source_file}" && continue
  cp -- "${source_file}" "${apt_root}/sources.list.d/$(basename -- "${source_file}")"
done
cp -- "${kubernetes_key}" "${apt_root}/kubernetes.asc"
cat >"${apt_root}/sources.list.d/kubernetes.list" <<EOF
deb [signed-by=${apt_root}/kubernetes.asc] https://pkgs.k8s.io/core:/stable:/${KUBERNETES_MINOR}/deb/ /
EOF

apt_options=(
  -o Debug::NoLocking=true
  -o "Dir::Etc::sourcelist=${apt_root}/sources.list"
  -o "Dir::Etc::sourceparts=${apt_root}/sources.list.d"
  -o "Dir::State::lists=${apt_root}/lists"
  -o Dir::State::status=/dev/null
)

log "Atualizando metadados APT temporários."
apt-get "${apt_options[@]}" update

download_deb_group() {
  local group="$1"
  shift
  local destination="${staging_root}/apt/${group}"
  install -d -m 0755 "${destination}/partial"
  log "Baixando grupo .deb ${group}."
  apt-get "${apt_options[@]}" \
    -o "Dir::Cache::archives=${destination}" \
    --download-only --no-install-recommends -y install "$@"
  rm -rf -- "${destination}/partial"
  rm -f -- "${destination}/lock"
  compgen -G "${destination}/*.deb" >/dev/null \
    || die "nenhum .deb foi baixado para o grupo ${group}."
  (cd -- "${destination}" && sha256sum -- *.deb >SHA256SUMS)
}

download_deb_group host \
  apt-transport-https ca-certificates conntrack curl ebtables ethtool gpg \
  iproute2 iptables kmod openssl procps socat tar
download_deb_group containerd containerd runc
download_deb_group kubernetes kubelet kubeadm kubectl kubernetes-cni cri-tools

(cd -- "${artifact_dir}" && sha256sum -- * >SHA256SUMS)
(cd -- "${chart_dir}" && sha256sum -- *.tgz >SHA256SUMS)

cat >"${staging_root}/bundle.env" <<EOF
CACHE_FORMAT=${OFFLINE_CACHE_FORMAT_VERSION}
UBUNTU_VERSION=26.04
ARCHITECTURE=${architecture}
KUBERNETES_MINOR=${KUBERNETES_MINOR}
FLANNEL_VERSION=${FLANNEL_VERSION}
HELM_VERSION=${HELM_VERSION}
GATEWAY_API_VERSION=${GATEWAY_API_VERSION}
ENVOY_GATEWAY_VERSION=${ENVOY_GATEWAY_VERSION}
CREATED_AT=$(date --iso-8601=seconds)
IMAGES_INCLUDED=false
EOF

artifact_cache_complete_staging=true
for directory in apt/host apt/containerd apt/kubernetes artifacts charts; do
  verify_cache_directory "${staging_root}/${directory}" || artifact_cache_complete_staging=false
done
is_true "${artifact_cache_complete_staging}" || die "a validação interna do bundle falhou."

install -d -m 0755 "${cache_parent}" "${ROOT_DIR}/dist"
if [[ -e "${cache_root}" ]]; then
  rm -rf -- "${cache_root}"
fi
mv -- "${staging_root}" "${cache_root}"

archive_name="kubernetes-wsl-artifacts-ubuntu-26.04-${KUBERNETES_MINOR}-${architecture}.tar.gz"
archive_path="${ROOT_DIR}/dist/${archive_name}"
tar -C "${cache_parent}" -czf "${archive_path}" "${architecture}"
(cd -- "${ROOT_DIR}/dist" && sha256sum -- "${archive_name}" >"${archive_name}.sha256")

project_owner="$(stat -c '%u:%g' "${ROOT_DIR}")"
chown -R "${project_owner}" "${cache_root}" "${archive_path}" "${archive_path}.sha256" 2>/dev/null || true

log "Bundle criado sem imagens de contêiner."
printf 'Cache:   %s\nArquivo: %s\nSHA-256: %s.sha256\n' \
  "${cache_root}" "${archive_path}" "${archive_path}"
