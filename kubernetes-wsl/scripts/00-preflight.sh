#!/usr/bin/env bash

# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_root
log "Validando Ubuntu 26.04, WSL 2, systemd e a configuração local."

is_wsl2 || die "este instalador é exclusivo para WSL 2; nenhuma VM Linux WSL 2 foi detectada."
systemd_is_pid1 \
  || die "systemd não é o PID 1. Execute 'sudo bash prepare-wsl.sh', depois 'wsl.exe --terminate Ubuntu-26.04' no CMD e abra o Ubuntu novamente."
system_state="$(systemctl is-system-running 2>/dev/null || true)"
[[ "${system_state}" == "running" || "${system_state}" == "degraded" ]] \
  || die "systemd ainda não está operacional dentro do WSL 2 (estado: ${system_state:-desconhecido})."

[[ -r /etc/os-release ]] || die "/etc/os-release não encontrado."
# shellcheck source=/dev/null
source /etc/os-release
if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "26.04" ]]; then
  if is_true "${ALLOW_UNSUPPORTED_OS}"; then
    warn "sistema não homologado (${PRETTY_NAME:-desconhecido}); prosseguindo por configuração explícita."
  else
    die "este instalador exige Ubuntu 26.04 no WSL 2; detectado: ${PRETTY_NAME:-desconhecido}."
  fi
fi

case "$(uname -m)" in
  x86_64|aarch64) ;;
  *) die "arquitetura não suportada: $(uname -m). Use amd64 ou arm64." ;;
esac

[[ -r /sys/fs/cgroup/cgroup.controllers ]] \
  || die "cgroup v2 não está disponível; atualize o WSL pelo CMD com 'wsl.exe --update'."

cpu_count="$(nproc)"
memory_kib="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
disk_kib="$(df -Pk / | awk 'NR == 2 {print $4}')"
resource_error=false
(( cpu_count >= 2 )) || { warn "Kubernetes precisa de pelo menos 2 CPUs; detectado: ${cpu_count}."; resource_error=true; }
(( memory_kib >= 1900000 )) || { warn "Kubernetes precisa de pelo menos 2 GB de RAM dentro do WSL."; resource_error=true; }
(( disk_kib >= 10485760 )) || { warn "Kubernetes precisa de pelo menos 10 GB livres no filesystem Linux."; resource_error=true; }
if is_true "${resource_error}" && ! is_true "${ALLOW_LOW_RESOURCES}"; then
  die "recursos insuficientes. Ajuste %UserProfile%\\.wslconfig ou defina ALLOW_LOW_RESOURCES=true conscientemente."
fi

[[ "${KUBERNETES_MINOR}" =~ ^v1\.[0-9]+$ ]] || die "KUBERNETES_MINOR inválido: ${KUBERNETES_MINOR}."
kubernetes_minor_number="${KUBERNETES_MINOR#v1.}"
(( 10#${kubernetes_minor_number} >= 31 )) \
  || die "esta variante usa a API kubeadm v1beta4 e exige Kubernetes v1.31 ou superior."
valid_ipv4_cidr "${POD_NETWORK_CIDR}" || die "POD_NETWORK_CIDR inválido."
valid_ipv4_cidr "${SERVICE_CIDR}" || die "SERVICE_CIDR inválido."
valid_ipv4 "${NODE_IP}" || die "NODE_IP inválido."
if cidr_contains_ipv4 "${POD_NETWORK_CIDR}" "${NODE_IP}"; then
  die "NODE_IP não pode pertencer a POD_NETWORK_CIDR."
fi
if cidr_contains_ipv4 "${SERVICE_CIDR}" "${NODE_IP}"; then
  die "NODE_IP não pode pertencer a SERVICE_CIDR."
fi
if [[ ! "${DASHBOARD_LOCAL_PORT}" =~ ^[0-9]+$ ]] \
  || (( DASHBOARD_LOCAL_PORT < 1024 || DASHBOARD_LOCAL_PORT > 65535 )); then
  die "DASHBOARD_LOCAL_PORT deve estar entre 1024 e 65535."
fi
if [[ ! "${DASHBOARD_CERT_DAYS}" =~ ^[0-9]+$ ]] || (( DASHBOARD_CERT_DAYS < 1 )); then
  die "DASHBOARD_CERT_DAYS inválido."
fi
[[ "${ADMIN_USER}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "ADMIN_USER inválido: ${ADMIN_USER}."
id "${ADMIN_USER}" >/dev/null 2>&1 \
  || die "ADMIN_USER=${ADMIN_USER} não existe. Execute via sudo a partir do usuário padrão do WSL ou ajuste cluster.env."
[[ "${NODE_NAME}" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]] \
  || die "NODE_NAME inválido para Kubernetes: ${NODE_NAME}."
[[ "${DASHBOARD_NAMESPACE}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] \
  || die "DASHBOARD_NAMESPACE inválido."
[[ "${HEADLAMP_IMAGE}" =~ ^[a-zA-Z0-9._/:@-]+$ ]] || die "HEADLAMP_IMAGE contém caracteres inválidos."
case "${DASHBOARD_DEFAULT_LANGUAGE}" in
  en|es|fr|ru|pt|de|it|zh-TW|zh|ko|ja|hi|bn|ta|ar|ur|he) ;;
  *) die "DASHBOARD_DEFAULT_LANGUAGE não é suportado pelo Headlamp v0.43: ${DASHBOARD_DEFAULT_LANGUAGE}." ;;
esac
[[ "${DASHBOARD_ROLLOUT_TIMEOUT}" =~ ^[0-9]+(s|m|h)$ ]] \
  || die "DASHBOARD_ROLLOUT_TIMEOUT deve usar s, m ou h (ex.: 10m)."

for boolean_name in SINGLE_NODE ALLOW_UNSUPPORTED_OS ALLOW_LOW_RESOURCES AUTO_REPAIR_PARTIAL_CLUSTER; do
  boolean_value="${!boolean_name}"
  case "${boolean_value,,}" in
    1|0|true|false|yes|no|sim|nao|on|off) ;;
    *) die "${boolean_name} precisa ser true ou false; recebido: ${boolean_value}." ;;
  esac
done

project_fs="$(findmnt -T "${PROJECT_DIR}" -n -o FSTYPE 2>/dev/null || true)"
case "${project_fs}" in
  9p|drvfs) warn "o projeto está em filesystem Windows (${project_fs}). Funciona, mas ~/kubernetes-wsl no filesystem Linux é mais rápido." ;;
esac

if [[ -r "${KUBECONFIG_ADMIN}" && -r /etc/kubernetes/manifests/kube-apiserver.yaml ]]; then
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
    die "a porta 6443 já está ocupada por outro Kubernetes ou aplicativo. Encerre Rancher Desktop/Docker Desktop ou o processo conflitante antes de instalar."
  fi
fi

if ! systemctl is-active --quiet "${HEADLAMP_FORWARD_SERVICE}" \
  && ss -H -ltn "sport = :${DASHBOARD_LOCAL_PORT}" 2>/dev/null | grep -q .; then
  ss -H -ltnp "sport = :${DASHBOARD_LOCAL_PORT}" >&2 || true
  die "DASHBOARD_LOCAL_PORT=${DASHBOARD_LOCAL_PORT} já está em uso. Escolha outra porta em cluster.env."
fi

for host in pkgs.k8s.io registry.k8s.io github.com ghcr.io; do
  getent ahosts "${host}" >/dev/null 2>&1 \
    || warn "não foi possível resolver ${host}; confira DNS, VPN e proxy corporativo."
done

log "WSL 2 aprovado: ${cpu_count} CPUs, $((memory_kib / 1024)) MiB RAM, nó ${NODE_NAME} (${NODE_IP})."
