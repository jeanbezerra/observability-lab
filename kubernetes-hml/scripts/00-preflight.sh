#!/usr/bin/env bash

# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_root
require_command ip
log "Validando a VM Ubuntu 26.04 HML, systemd e a configuração de rede."

if is_wsl2 || grep -Eiq 'microsoft|wsl' /proc/sys/kernel/osrelease /proc/version; then
  die "esta variante exige uma VM Ubuntu e não pode ser instalada no WSL. Use kubernetes-wsl nesse ambiente."
fi
systemd_is_pid1 \
  || die "systemd não é o PID 1. Inicialize a VM Ubuntu normalmente antes de instalar."
system_state="$(systemctl is-system-running 2>/dev/null || true)"
[[ "${system_state}" == "running" || "${system_state}" == "degraded" ]] \
  || die "systemd ainda não está operacional na VM (estado: ${system_state:-desconhecido})."

[[ -r /etc/os-release ]] || die "/etc/os-release não encontrado."
# shellcheck source=/dev/null
source /etc/os-release
if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "26.04" ]]; then
  if is_true "${ALLOW_UNSUPPORTED_OS}"; then
    warn "sistema não homologado (${PRETTY_NAME:-desconhecido}); prosseguindo por configuração explícita."
  else
    die "este instalador exige Ubuntu 26.04 LTS na VM; detectado: ${PRETTY_NAME:-desconhecido}."
  fi
fi

case "$(uname -m)" in
  x86_64|aarch64) ;;
  *) die "arquitetura não suportada: $(uname -m). Use amd64 ou arm64." ;;
esac

[[ -r /sys/fs/cgroup/cgroup.controllers ]] \
  || die "cgroup v2 não está disponível. Inicialize a VM com o kernel padrão do Ubuntu 26.04 LTS."

cpu_count="$(nproc)"
memory_kib="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
disk_kib="$(df -Pk / | awk 'NR == 2 {print $4}')"
resource_error=false
(( cpu_count >= 2 )) || { warn "Kubernetes precisa de pelo menos 2 CPUs; detectado: ${cpu_count}."; resource_error=true; }
(( memory_kib >= 3900000 )) || { warn "o ambiente HML exige pelo menos 4 GB de RAM na VM."; resource_error=true; }
(( disk_kib >= 20971520 )) || { warn "o ambiente HML exige pelo menos 20 GiB livres no filesystem Linux."; resource_error=true; }
if is_true "${resource_error}" && ! is_true "${ALLOW_LOW_RESOURCES}"; then
  die "recursos insuficientes. Amplie a VM ou defina ALLOW_LOW_RESOURCES=true conscientemente."
fi
if (( cpu_count < 4 || memory_kib < 7800000 )); then
  warn "para HML, recomendamos 4 vCPUs e 8 GB de RAM ou mais."
fi

[[ "${KUBERNETES_MINOR}" =~ ^v1\.[0-9]+$ ]] || die "KUBERNETES_MINOR inválido: ${KUBERNETES_MINOR}."
kubernetes_minor_number="${KUBERNETES_MINOR#v1.}"
(( 10#${kubernetes_minor_number} >= 31 )) \
  || die "esta variante usa a API kubeadm v1beta4 e exige Kubernetes v1.31 ou superior."
if (( 10#${kubernetes_minor_number} < 34 || 10#${kubernetes_minor_number} > 36 )); then
  die "esta matriz HML com Rancher 2.15.2 e Envoy Gateway exige Kubernetes v1.34 a v1.36."
fi
[[ "${RANCHER_VERSION}" =~ ^v?([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] \
  || die "RANCHER_VERSION deve informar uma release estável como v2.15.2."
rancher_major=$((10#${BASH_REMATCH[1]}))
rancher_minor=$((10#${BASH_REMATCH[2]}))
rancher_patch=$((10#${BASH_REMATCH[3]}))
(( rancher_major > 2 || (rancher_major == 2 && rancher_minor > 15) \
  || (rancher_major == 2 && rancher_minor == 15 && rancher_patch >= 2) )) \
  || die "a referência Rancher para HML exige v2.15.2 ou superior; confira About e a matriz do servidor."
valid_ipv4_cidr "${POD_NETWORK_CIDR}" || die "POD_NETWORK_CIDR inválido."
valid_ipv4_cidr "${SERVICE_CIDR}" || die "SERVICE_CIDR inválido."
valid_ipv4 "${NODE_IP}" || die "NODE_IP inválido ou ausente. Informe um IPv4 atual da VM durante a instalação."
node_ip_is_local_physical "${NODE_IP}" \
  || die "NODE_IP=${NODE_IP} precisa existir em uma interface física da VM; loopback e endereços inventados não são aceitos."
if ipv4_cidrs_overlap "${POD_NETWORK_CIDR}" "${SERVICE_CIDR}"; then
  die "POD_NETWORK_CIDR e SERVICE_CIDR não podem se sobrepor."
fi
while read -r vm_interface vm_cidr; do
  vm_interface="${vm_interface%%@*}"
  [[ -e "/sys/class/net/${vm_interface}/device" ]] || continue
  if ipv4_cidrs_overlap "${POD_NETWORK_CIDR}" "${vm_cidr}" \
    || ipv4_cidrs_overlap "${SERVICE_CIDR}" "${vm_cidr}"; then
    die "as redes POD/SERVICE se sobrepõem à rede da VM ${vm_cidr} (${vm_interface}); escolha CIDRs diferentes."
  fi
done < <(ip -o -4 address show scope global | awk '{print $2, $4}')
case "${SYSTEM_TIMEZONE}" in
  ""|/*|*..*) die "SYSTEM_TIMEZONE contém um identificador inseguro: ${SYSTEM_TIMEZONE}." ;;
esac
[[ -e "/usr/share/zoneinfo/${SYSTEM_TIMEZONE}" ]] \
  || die "SYSTEM_TIMEZONE não existe no banco de fusos horários: ${SYSTEM_TIMEZONE}."
[[ "${K8S_NO_PROXY}" != *$'\n'* && "${K8S_NO_PROXY}" != *$'\r'* ]] \
  || die "NO_PROXY contém quebra de linha e não pode ser aplicado com segurança."
if cidr_contains_ipv4 "${POD_NETWORK_CIDR}" "${NODE_IP}"; then
  die "NODE_IP não pode pertencer a POD_NETWORK_CIDR."
fi
if cidr_contains_ipv4 "${SERVICE_CIDR}" "${NODE_IP}"; then
  die "NODE_IP não pode pertencer a SERVICE_CIDR."
fi
if [[ ! "${DASHBOARD_NODE_PORT}" =~ ^[1-9][0-9]{4}$ ]] \
  || (( 10#${DASHBOARD_NODE_PORT} < 30000 || 10#${DASHBOARD_NODE_PORT} > 32767 )); then
  die "DASHBOARD_NODE_PORT deve estar entre 30000 e 32767."
fi
if [[ ! "${GATEWAY_NODE_PORT}" =~ ^[1-9][0-9]{4}$ ]] \
  || (( 10#${GATEWAY_NODE_PORT} < 30000 || 10#${GATEWAY_NODE_PORT} > 32767 )); then
  die "GATEWAY_NODE_PORT deve estar entre 30000 e 32767."
fi
if [[ ! "${GATEWAY_LISTENER_PORT}" =~ ^[0-9]+$ ]] \
  || (( GATEWAY_LISTENER_PORT < 1 || GATEWAY_LISTENER_PORT > 65535 )); then
  die "GATEWAY_LISTENER_PORT deve estar entre 1 e 65535."
fi
[[ "${GATEWAY_NODE_PORT}" != "${DASHBOARD_NODE_PORT}" ]] \
  || die "GATEWAY_NODE_PORT e DASHBOARD_NODE_PORT precisam ser diferentes."
if [[ ! "${DASHBOARD_CERT_DAYS}" =~ ^[0-9]+$ ]] || (( DASHBOARD_CERT_DAYS < 1 )); then
  die "DASHBOARD_CERT_DAYS inválido."
fi
[[ "${ADMIN_USER}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "ADMIN_USER inválido: ${ADMIN_USER}."
id "${ADMIN_USER}" >/dev/null 2>&1 \
  || die "ADMIN_USER=${ADMIN_USER} não existe. Execute via sudo a partir do usuário administrador da VM ou ajuste cluster.env."
[[ "${NODE_NAME}" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]] \
  || die "NODE_NAME inválido para Kubernetes: ${NODE_NAME}."
[[ "${DASHBOARD_NAMESPACE}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] \
  || die "DASHBOARD_NAMESPACE inválido."
for dns_name_var in ENVOY_PROXY_NAME GATEWAY_CLASS_NAME GATEWAY_NAME; do
  dns_name_value="${!dns_name_var}"
  [[ "${dns_name_value}" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]] \
    || die "${dns_name_var} inválido para Kubernetes/Helm: ${dns_name_value}."
done
for dns_label_var in ENVOY_GATEWAY_NAMESPACE GATEWAY_NAMESPACE; do
  dns_label_value="${!dns_label_var}"
  [[ "${dns_label_value}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ && "${#dns_label_value}" -le 63 ]] \
    || die "${dns_label_var} precisa ser um label DNS Kubernetes de até 63 caracteres."
done
[[ "${ENVOY_GATEWAY_RELEASE}" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ \
  && "${#ENVOY_GATEWAY_RELEASE}" -le 53 ]] \
  || die "ENVOY_GATEWAY_RELEASE inválido para Helm (máximo 53 caracteres)."
[[ "${HELM_VERSION}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || die "HELM_VERSION inválido: ${HELM_VERSION}."
[[ "${GATEWAY_API_VERSION}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || die "GATEWAY_API_VERSION inválido: ${GATEWAY_API_VERSION}."
[[ "${ENVOY_GATEWAY_VERSION}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || die "ENVOY_GATEWAY_VERSION inválido: ${ENVOY_GATEWAY_VERSION}."
for checksum_var in HELM_SHA256_AMD64 HELM_SHA256_ARM64 ENVOY_GATEWAY_CHART_SHA256 \
  ENVOY_GATEWAY_CRDS_CHART_SHA256; do
  checksum_value="${!checksum_var}"
  [[ "${checksum_value}" =~ ^[0-9a-f]{64}$ ]] \
    || die "${checksum_var} precisa ser um SHA-256 hexadecimal de 64 caracteres."
done
[[ "${HEADLAMP_IMAGE}" =~ ^[a-zA-Z0-9._/:@-]+$ ]] || die "HEADLAMP_IMAGE contém caracteres inválidos."
valid_endpoint_host "${HEADLAMP_HOST}" || die "HEADLAMP_HOST deve ser um IPv4 ou hostname DNS válido, sem protocolo, porta ou caminho."
if [[ -n "${RANCHER_URL}" ]]; then
  valid_https_url "${RANCHER_URL}" || die "RANCHER_URL deve ser uma URL HTTPS válida do Rancher externo."
fi
case "${DASHBOARD_DEFAULT_LANGUAGE}" in
  en|es|fr|ru|pt|de|it|zh-TW|zh|ko|ja|hi|bn|ta|ar|ur|he) ;;
  *) die "DASHBOARD_DEFAULT_LANGUAGE não é suportado pelo Headlamp configurado: ${DASHBOARD_DEFAULT_LANGUAGE}." ;;
esac
[[ "${DASHBOARD_ROLLOUT_TIMEOUT}" =~ ^0*[1-9][0-9]*(s|m|h)$ ]] \
  || die "DASHBOARD_ROLLOUT_TIMEOUT deve usar s, m ou h (ex.: 10m)."
for timeout_name in CLUSTER_OPERATION_TIMEOUT KUBEADM_INIT_TIMEOUT; do
  timeout_value="${!timeout_name}"
  [[ "${timeout_value}" =~ ^0*[1-9][0-9]*(s|m|h)$ ]] \
    || die "${timeout_name} deve usar s, m ou h (ex.: 5m)."
done
for seconds_name in KUBERNETES_REQUEST_TIMEOUT_SECONDS ARTIFACT_CONNECT_TIMEOUT_SECONDS \
  ARTIFACT_RETRY_ATTEMPTS ARTIFACT_RETRY_DELAY_SECONDS \
  DIAGNOSTIC_CHECK_TIMEOUT_SECONDS DIAGNOSTIC_TAIL_LINES; do
  seconds_value="${!seconds_name}"
  [[ "${seconds_value}" =~ ^[1-9][0-9]*$ ]] \
    || die "${seconds_name} deve ser um inteiro positivo; recebido: ${seconds_value}."
done
case "${ARTIFACT_MODE}" in
  auto|online|offline|cache) ;;
  *) die "ARTIFACT_MODE deve ser auto, online, offline ou cache; recebido: ${ARTIFACT_MODE}." ;;
esac
if artifact_mode_is_offline; then
  require_command sha256sum
  artifact_cache_complete \
    || die "ARTIFACT_MODE=${ARTIFACT_MODE} exige um bundle completo e compatível em ${ARTIFACT_CACHE_DIR}."
  log "Modo offline: bundle local validado; pacotes e artefatos de instalação não usarão a Internet."
elif artifact_cache_compatible; then
  log "Cache de contingência compatível detectado em ${ARTIFACT_CACHE_DIR}."
fi

for boolean_name in SINGLE_NODE ALLOW_UNSUPPORTED_OS ALLOW_LOW_RESOURCES \
  AUTO_REPAIR_PARTIAL_CLUSTER DIAGNOSTIC_ON_ERROR; do
  boolean_value="${!boolean_name}"
  case "${boolean_value,,}" in
    1|0|true|false|yes|no|sim|nao|on|off) ;;
    *) die "${boolean_name} precisa ser true ou false; recebido: ${boolean_value}." ;;
  esac
done
is_true "${SINGLE_NODE}" \
  || die "este instalador HML oferece um único nó; SINGLE_NODE=true é obrigatório."

[[ "${BOOTSTRAP_LOG_DIR}" == /* ]] \
  || die "BOOTSTRAP_LOG_DIR precisa ser um caminho Linux absoluto."
case "${BOOTSTRAP_COLOR,,}" in
  auto|always|never) ;;
  *) die "BOOTSTRAP_COLOR precisa ser auto, always ou never; recebido: ${BOOTSTRAP_COLOR}." ;;
esac

if [[ -r /etc/kubernetes/manifests/kube-apiserver.yaml || -d /var/lib/etcd/member \
  || -r "${KUBECONFIG_ADMIN}" ]]; then
  existing_network_unit="/etc/systemd/system/${NODE_NETWORK_SERVICE}"
  if [[ ! -r "${existing_network_unit}" ]] \
    || ! grep -Fxq 'Description=Kubernetes HML VM node network preparation' "${existing_network_unit}" \
    || ! grep -Fxq "ExecStart=/usr/local/sbin/k8s-hml-node-network ${NODE_IP}" "${existing_network_unit}"; then
    die "há um cluster Kubernetes preexistente sem marcador desta variante HML; instalação recusada para preservar esse ambiente."
  fi
fi

if [[ -r "${KUBECONFIG_ADMIN}" && -r /etc/kubernetes/manifests/kube-apiserver.yaml ]]; then
  existing_kubernetes_minor="$(sed -n 's/.*image:.*kube-apiserver:\(v1\.[0-9]*\)\..*/\1/p' \
    /etc/kubernetes/manifests/kube-apiserver.yaml | head -n 1)"
  if [[ -n "${existing_kubernetes_minor}" && "${existing_kubernetes_minor}" != "${KUBERNETES_MINOR}" ]]; then
    die "KUBERNETES_MINOR=${KUBERNETES_MINOR} difere do cluster existente (${existing_kubernetes_minor}). Faça upgrades pelo fluxo kubeadm antes de reconciliar."
  fi
  existing_node_ip="$(sed -n 's/^[[:space:]]*-[[:space:]]*--advertise-address=//p' \
    /etc/kubernetes/manifests/kube-apiserver.yaml | head -n 1)"
  if [[ -n "${existing_node_ip}" && "${existing_node_ip}" != "${NODE_IP}" ]]; then
    die "NODE_IP=${NODE_IP} difere do control plane existente (${existing_node_ip}). O endereço é imutável; restaure o valor anterior em cluster.env."
  fi
fi

if [[ ! -f "${KUBECONFIG_ADMIN}" ]] && ss -H -ltn 'sport = :6443' 2>/dev/null | grep -q .; then
  if [[ -f /etc/kubernetes/manifests/kube-apiserver.yaml || -d /var/lib/etcd/member ]]; then
    warn "a porta 6443 está em uso por um bootstrap parcial; a etapa 40 fará a avaliação segura."
  else
    ss -H -ltnp 'sport = :6443' >&2 || true
    die "a porta 6443 já está ocupada por outro Kubernetes ou aplicativo. Resolva o conflito antes de instalar."
  fi
fi

network_hosts=(registry.k8s.io ghcr.io docker.io registry-1.docker.io)
if ! artifact_mode_is_offline; then
  network_hosts+=(pkgs.k8s.io github.com get.helm.sh)
fi
for host in "${network_hosts[@]}"; do
  getent ahosts "${host}" >/dev/null 2>&1 \
    || warn "não foi possível resolver ${host}; confira DNS, VPN e proxy corporativo."
done

log "VM HML aprovada: ${cpu_count} CPUs, $((memory_kib / 1024)) MiB RAM, nó ${NODE_NAME} (${NODE_IP})."
