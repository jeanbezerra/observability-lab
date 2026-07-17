#!/usr/bin/env bash

# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_root

log "Validando o host e a configuração."

[[ -r /etc/os-release ]] || die "/etc/os-release não encontrado."
# shellcheck source=/dev/null
source /etc/os-release

if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "26.04" ]]; then
  if is_true "${ALLOW_UNSUPPORTED_OS}"; then
    warn "sistema não homologado (${PRETTY_NAME:-desconhecido}); prosseguindo por configuração explícita."
  else
    die "este instalador exige Ubuntu Server 26.04 LTS; detectado: ${PRETTY_NAME:-desconhecido}."
  fi
fi

case "$(uname -m)" in
  x86_64|aarch64) ;;
  *) die "arquitetura não suportada: $(uname -m). Use amd64 ou arm64." ;;
esac

cpu_count="$(nproc)"
memory_kib="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
disk_kib="$(df -Pk / | awk 'NR == 2 {print $4}')"

(( cpu_count >= 2 )) || die "são necessários pelo menos 2 CPUs; detectado: ${cpu_count}."
(( memory_kib >= 1900000 )) || die "são necessários pelo menos 2 GB de RAM."
(( disk_kib >= 10485760 )) || die "são necessários pelo menos 10 GB livres no filesystem raiz."

[[ "${KUBERNETES_MINOR}" =~ ^v1\.[0-9]+$ ]] || die "KUBERNETES_MINOR inválido: ${KUBERNETES_MINOR}."
valid_ipv4_cidr "${POD_NETWORK_CIDR}" || die "POD_NETWORK_CIDR inválido."
valid_ipv4_cidr "${SERVICE_CIDR}" || die "SERVICE_CIDR inválido."
valid_ipv4_cidr "${DASHBOARD_ALLOWED_CIDR}" || die "DASHBOARD_ALLOWED_CIDR inválido."
[[ "${DASHBOARD_NODE_PORT}" =~ ^[0-9]+$ ]] || die "DASHBOARD_NODE_PORT precisa ser numérico."
(( DASHBOARD_NODE_PORT >= 30000 && DASHBOARD_NODE_PORT <= 32767 )) || die "DASHBOARD_NODE_PORT deve estar entre 30000 e 32767."
[[ "${SSH_PORT}" =~ ^[0-9]+$ ]] && (( SSH_PORT >= 1 && SSH_PORT <= 65535 )) || die "SSH_PORT inválida."
[[ "${DASHBOARD_CERT_DAYS}" =~ ^[0-9]+$ ]] && (( DASHBOARD_CERT_DAYS >= 1 )) || die "DASHBOARD_CERT_DAYS inválido."
[[ "${ADMIN_USER}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "ADMIN_USER inválido: ${ADMIN_USER}."
[[ "${ADMIN_GROUP}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "ADMIN_GROUP inválido: ${ADMIN_GROUP}."
[[ "${DASHBOARD_NAMESPACE}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die "DASHBOARD_NAMESPACE inválido."
[[ "${HEADLAMP_IMAGE}" =~ ^[a-zA-Z0-9._/:@-]+$ ]] || die "HEADLAMP_IMAGE contém caracteres inválidos."
[[ "${DEFAULT_TOKEN_DURATION}" =~ ^[0-9]+(s|m|h)$ ]] || die "DEFAULT_TOKEN_DURATION deve usar s, m ou h (ex.: 8h)."
[[ "${DASHBOARD_ROLLOUT_TIMEOUT}" =~ ^[0-9]+(s|m|h)$ ]] || die "DASHBOARD_ROLLOUT_TIMEOUT deve usar s, m ou h (ex.: 10m)."

for boolean_name in SINGLE_NODE CREATE_ADMIN_SERVICE_ACCOUNT ENABLE_UFW ALLOW_UNSUPPORTED_OS AUTO_REPAIR_PARTIAL_CLUSTER; do
  boolean_value="${!boolean_name}"
  case "${boolean_value,,}" in
    1|0|true|false|yes|no|sim|nao|on|off) ;;
    *) die "${boolean_name} precisa ser true ou false; recebido: ${boolean_value}." ;;
  esac
done

if [[ -n "${NODE_IP}" ]]; then
  valid_ipv4 "${NODE_IP}" || die "NODE_IP inválido."
fi
if [[ -n "${DASHBOARD_PUBLIC_IP}" ]]; then
  valid_ipv4 "${DASHBOARD_PUBLIC_IP}" || die "DASHBOARD_PUBLIC_IP inválido."
fi
if [[ -n "${DASHBOARD_DNS_NAME}" ]]; then
  [[ "${DASHBOARD_DNS_NAME}" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] || die "DASHBOARD_DNS_NAME inválido."
fi

detected_ip="$(detect_node_ip)"
node_name="$(effective_node_name)"
[[ "${node_name}" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]] || die "NODE_NAME/hostname inválido para Kubernetes: ${node_name}."

if [[ ! -f "${KUBECONFIG_ADMIN}" ]] && command -v ss >/dev/null 2>&1 && ss -H -ltn 'sport = :6443' | grep -q .; then
  warn "a porta 6443 está em uso sem ${KUBECONFIG_ADMIN}; a etapa de bootstrap avaliará e reparará apenas resíduos de uma inicialização interrompida."
fi

for host in pkgs.k8s.io registry.k8s.io github.com ghcr.io; do
  getent ahosts "${host}" >/dev/null 2>&1 \
    || warn "não foi possível resolver ${host} agora; a execução continuará se o componente correspondente já estiver instalado."
done

log "Host aprovado: ${cpu_count} CPUs, $((memory_kib / 1024)) MiB RAM, nó ${node_name} (${detected_ip})."
