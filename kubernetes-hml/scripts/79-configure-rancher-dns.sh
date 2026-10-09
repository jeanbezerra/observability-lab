#!/usr/bin/env bash

set +x
# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_root
[[ $# -le 1 && ( $# -eq 0 || "${1}" == "--check" ) ]] \
  || die "Uso: sudo bash scripts/79-configure-rancher-dns.sh [--check]"

RANCHER_DNS_SERVERS="${RANCHER_DNS_SERVERS:-}"
RANCHER_DNS_MODE="${RANCHER_DNS_MODE:-auto}"
case "${RANCHER_DNS_MODE}" in
  auto) ;;
  off) exit 0 ;;
  *) die "RANCHER_DNS_MODE deve ser auto ou off." ;;
esac
[[ -n "${RANCHER_URL:-}" ]] || exit 0
valid_https_url "${RANCHER_URL:-}" || die "Configure RANCHER_URL HTTPS antes do DNS Rancher."
require_command python3

helper_file="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/rancher-dns.py"
ip_url="$(python3 "${helper_file}" ip-url "${RANCHER_URL}")" \
  || die "RANCHER_URL não é válida para a reconciliação DNS."
[[ "${ip_url}" != true ]] \
  || { log "Rancher usa endereço IP literal; nenhum encaminhamento DNS é necessário."; exit 0; }
selection_mode=manual
if [[ -z "${RANCHER_DNS_SERVERS//[[:space:]]/}" ]]; then
  selection_mode=auto
  if check_requested "${1:-}"; then
    # --check não resolve nomes e não consulta DNS externos. Avalia somente o
    # último estado aplicado; a reconciliação normal refaz a descoberta sempre.
    RANCHER_DNS_SERVERS="$(python3 "${helper_file}" recorded \
      "${BOOTSTRAP_STATE_DIR}/rancher-dns.json" "${RANCHER_URL}" 2>/dev/null)" \
      || { check_pending "Seleção DNS automática ainda não foi reconciliada para o Rancher atual."; exit 1; }
  else
    RANCHER_DNS_SERVERS="$(python3 "${helper_file}" discover "${RANCHER_URL}" "${POD_NETWORK_CIDR}")" \
      || die "Descoberta DNS falhou; CoreDNS foi preservado. Revise o DNS da VM ou configure RANCHER_DNS_SERVERS."
    log "Upstreams DNS do ambiente selecionados conforme a resolução Rancher no host: ${RANCHER_DNS_SERVERS}."
  fi
fi
temporary_dir="$(mktemp -d)"
trap 'rm -f -- "${temporary_dir}/live.json" "${temporary_dir}/plan.json" "${temporary_dir}/patch.json" "${temporary_dir}/state.json"; rmdir -- "${temporary_dir}"' EXIT

kube -n kube-system get configmap coredns -o json >"${temporary_dir}/live.json" \
  || die "Não foi possível consultar ConfigMap kube-system/coredns."
python3 "${helper_file}" plan "${temporary_dir}/live.json" "${temporary_dir}/plan.json" \
  "${RANCHER_URL}" "${RANCHER_DNS_SERVERS}" "${selection_mode}" \
  || die "A configuração DNS Rancher não foi aplicada; revise servidores IPv4/IPv6 e o bloco gerenciado."
read -r patch_needed corefile_changed < <(python3 "${helper_file}" extract \
  "${temporary_dir}/plan.json" "${temporary_dir}/patch.json" "${temporary_dir}/state.json")

if check_requested "${1:-}"; then
  [[ "${patch_needed}" == "false" ]] \
    || { check_pending "ConfigMap CoreDNS ainda diverge de RANCHER_DNS_SERVERS para o hostname Rancher."; exit 1; }
  kube -n kube-system rollout status deployment/coredns --timeout=15s >/dev/null 2>&1 \
    || { check_pending "ConfigMap está conforme, mas CoreDNS ainda não está pronto."; exit 1; }
  log "Encaminhamento DNS do hostname Rancher conferido no ConfigMap CoreDNS."
  exit 0
fi

if [[ "${corefile_changed}" == "true" ]]; then
  # Guarda o ConfigMap completo antes do patch; não reverte alterações remotas
  # automaticamente, pois outros administradores podem editar o CoreDNS.
  backup_dir="${BOOTSTRAP_STATE_DIR}/rancher-dns-backups"
  install -d -m 0700 -- "${BOOTSTRAP_STATE_DIR}" "${backup_dir}"
  backup_file="$(mktemp "${backup_dir}/coredns-$(date '+%Y%m%dT%H%M%S%z').XXXXXX.json")"
  install -m 0600 -- "${temporary_dir}/live.json" "${backup_file}"
  log "Backup privado do CoreDNS anterior ao patch: ${backup_file}."
fi
if [[ "${patch_needed}" == "true" ]]; then
  kube -n kube-system patch configmap coredns --type=merge --patch-file "${temporary_dir}/patch.json" \
    || die "CoreDNS mudou durante a reconciliação ou o patch falhou; execute novamente após revisar a API."
fi
if [[ "${corefile_changed}" == "true" ]]; then
  kube -n kube-system rollout restart deployment/coredns
fi
# Também valida reruns: um patch pode ter sido aplicado antes de um timeout.
kube -n kube-system rollout status deployment/coredns --timeout="${CLUSTER_OPERATION_TIMEOUT}" \
  || die "CoreDNS ainda não ficou pronto; estado de sucesso não foi gravado. Preserve o backup e revise o Deployment."

install -d -m 0700 -- "${BOOTSTRAP_STATE_DIR}"
install -m 0600 -- "${temporary_dir}/state.json" "${BOOTSTRAP_STATE_DIR}/rancher-dns.json"
log "DNS Rancher reconciliado no CoreDNS (seleção ${selection_mode}, policy sequential); demais zonas preservadas."
