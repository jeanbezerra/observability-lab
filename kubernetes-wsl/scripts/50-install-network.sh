#!/usr/bin/env bash

# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_root

flannel_subnet_file_ok() {
  [[ -s /run/flannel/subnet.env ]] || return 1
  grep -Fqx "FLANNEL_NETWORK=${POD_NETWORK_CIDR}" /run/flannel/subnet.env \
    && grep -Eq '^FLANNEL_SUBNET=[0-9]+(\.[0-9]+){3}/[0-9]+$' /run/flannel/subnet.env \
    && grep -Eq '^FLANNEL_MTU=[0-9]+$' /run/flannel/subnet.env \
    && grep -Eq '^FLANNEL_IPMASQ=(true|false)$' /run/flannel/subnet.env
}

network_state_ok() {
  local desired ready updated images network_config coredns_desired coredns_ready
  kube --request-timeout=5s -n kube-flannel get daemonset kube-flannel-ds >/dev/null 2>&1 || {
    check_pending "DaemonSet do Flannel não existe."
    return 1
  }
  images="$(kube -n kube-flannel get daemonset kube-flannel-ds \
    -o jsonpath='{.spec.template.spec.initContainers[*].image} {.spec.template.spec.containers[*].image}' 2>/dev/null)"
  grep -Fq ":${FLANNEL_VERSION}" <<<"${images}" || {
    check_pending "Flannel instalado não está na versão ${FLANNEL_VERSION}."
    return 1
  }
  network_config="$(kube -n kube-flannel get configmap kube-flannel-cfg \
    -o jsonpath='{.data.net-conf\.json}' 2>/dev/null)"
  grep -Fq "\"Network\": \"${POD_NETWORK_CIDR}\"" <<<"${network_config}" || {
    check_pending "CIDR configurado no Flannel difere de ${POD_NETWORK_CIDR}."
    return 1
  }
  read -r desired ready updated < <(kube -n kube-flannel get daemonset kube-flannel-ds \
    -o jsonpath='{.status.desiredNumberScheduled} {.status.numberReady} {.status.updatedNumberScheduled}' 2>/dev/null)
  [[ -n "${desired}" && "${desired}" != "0" && "${desired}" == "${ready}" && "${desired}" == "${updated}" ]] || {
    check_pending "Pods do Flannel ainda não estão todos prontos."
    return 1
  }
  read -r coredns_desired coredns_ready < <(kube -n kube-system get deployment coredns \
    -o jsonpath='{.status.replicas} {.status.readyReplicas}' 2>/dev/null)
  [[ -n "${coredns_desired}" && "${coredns_desired}" != "0" && "${coredns_desired}" == "${coredns_ready}" ]] || {
    check_pending "CoreDNS ainda não está pronto."
    return 1
  }
  flannel_subnet_file_ok || {
    check_pending "/run/flannel/subnet.env está ausente ou incompatível com ${POD_NETWORK_CIDR}."
    return 1
  }
}

if check_requested "${1:-}"; then
  if network_state_ok; then
    exit 0
  fi
  exit 1
fi

require_command curl
require_command sha256sum

manifest="$(mktemp)"
trap 'rm -f -- "${manifest}"' EXIT
manifest_url="https://github.com/flannel-io/flannel/releases/download/${FLANNEL_VERSION}/kube-flannel.yml"
restart_flannel=false
flannel_subnet_file_ok || restart_flannel=true

log "Baixando Flannel ${FLANNEL_VERSION} com verificação SHA-256."
retry 3 3 curl -fL --retry 2 --connect-timeout 15 "${manifest_url}" -o "${manifest}"
printf '%s  %s\n' "${FLANNEL_SHA256}" "${manifest}" | sha256sum --check --status \
  || die "checksum do manifesto Flannel não confere."

if [[ "${POD_NETWORK_CIDR}" != "10.244.0.0/16" ]]; then
  sed -i "s#10\.244\.0\.0/16#${POD_NETWORK_CIDR}#g" "${manifest}"
fi

kube apply -f "${manifest}"
if is_true "${restart_flannel}"; then
  warn "estado local do Flannel está incompleto; reiniciando o DaemonSet para recriar /run/flannel/subnet.env."
  kube rollout restart daemonset/kube-flannel-ds -n kube-flannel
fi
kube rollout status daemonset/kube-flannel-ds -n kube-flannel --timeout=5m
if ! retry 30 2 flannel_subnet_file_ok; then
  kube -n kube-flannel get daemonset,pod -o wide >&2 || true
  kube -n kube-flannel logs daemonset/kube-flannel-ds \
    --all-containers=true --prefix --tail=100 >&2 || true
  die "Flannel ficou pronto na API, mas não criou /run/flannel/subnet.env no nó."
fi
kube rollout status deployment/coredns -n kube-system --timeout=5m

network_state_ok || die "a rede foi aplicada, mas Flannel/CoreDNS ainda não atingiram o estado esperado."
log "Rede de Pods instalada."
