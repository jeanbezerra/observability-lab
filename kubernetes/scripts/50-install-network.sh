#!/usr/bin/env bash

# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_root
require_command curl
require_command sha256sum

manifest="$(mktemp)"
trap 'rm -f -- "${manifest}"' EXIT
manifest_url="https://github.com/flannel-io/flannel/releases/download/${FLANNEL_VERSION}/kube-flannel.yml"

log "Baixando Flannel ${FLANNEL_VERSION} com verificação SHA-256."
retry 3 3 curl -fL --retry 2 --connect-timeout 15 "${manifest_url}" -o "${manifest}"
printf '%s  %s\n' "${FLANNEL_SHA256}" "${manifest}" | sha256sum --check --status \
  || die "checksum do manifesto Flannel não confere."

if [[ "${POD_NETWORK_CIDR}" != "10.244.0.0/16" ]]; then
  sed -i "s#10\.244\.0\.0/16#${POD_NETWORK_CIDR}#g" "${manifest}"
fi

kube apply -f "${manifest}"
kube rollout status daemonset/kube-flannel-ds -n kube-flannel --timeout=5m
kube rollout status deployment/coredns -n kube-system --timeout=5m

log "Rede de Pods instalada."
