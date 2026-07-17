#!/usr/bin/env bash

# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_root

firewall_state_file="${BOOTSTRAP_STATE_DIR}/ufw.fingerprint"
managed_comments=(
  'SSH administracao'
  'Kubernetes Dashboard HTTPS'
  'Kubernetes CNI input'
  'Kubernetes Flannel input'
  'Kubernetes CNI routed input'
  'Kubernetes CNI routed output'
  'Kubernetes Flannel routed input'
  'Kubernetes Flannel routed output'
)

detected_ssh_ports() {
  {
    printf '%s\n' "${SSH_PORT}"
    if command -v sshd >/dev/null 2>&1; then
      sshd -T 2>/dev/null | awk '$1 == "port" {print $2}' || true
    fi
  } | awk 'NF' | sort -nu
}

firewall_fingerprint() {
  {
    printf 'enabled=%s\n' "${ENABLE_UFW}"
    printf 'dashboard_cidr=%s\n' "${DASHBOARD_ALLOWED_CIDR}"
    printf 'dashboard_port=%s\n' "${DASHBOARD_NODE_PORT}"
    detected_ssh_ports | sed 's/^/ssh_port=/'
  } | sha256sum | awk '{print $1}'
}

managed_rules_exist() {
  local comment
  command -v ufw >/dev/null 2>&1 || return 1
  for comment in "${managed_comments[@]}"; do
    ufw status numbered 2>/dev/null | grep -Fq "# ${comment}" && return 0
  done
  return 1
}

all_managed_comments_exist() {
  local comment status_output
  status_output="$(ufw status numbered 2>/dev/null)"
  for comment in "${managed_comments[@]}"; do
    grep -Fq "# ${comment}" <<<"${status_output}" || return 1
  done
}

firewall_state_ok() {
  if ! is_true "${ENABLE_UFW}"; then
    if managed_rules_exist || [[ -e "${firewall_state_file}" ]]; then
      check_pending "ENABLE_UFW=false, mas ainda existem regras gerenciadas pelo instalador."
      return 1
    fi
    return 0
  fi
  command -v ufw >/dev/null 2>&1 || {
    check_pending "ufw não está instalado."
    return 1
  }
  ufw status 2>/dev/null | grep -Fq 'Status: active' || {
    check_pending "UFW não está ativo."
    return 1
  }
  [[ -r "${firewall_state_file}" ]] \
    && [[ "$(<"${firewall_state_file}")" == "$(firewall_fingerprint)" ]] || {
      check_pending "regras UFW precisam ser reconciliadas com a configuração atual."
      return 1
    }
  all_managed_comments_exist || {
    check_pending "uma ou mais regras UFW gerenciadas estão ausentes."
    return 1
  }
}

remove_managed_rules() {
  local comment number
  local numbers=()
  while read -r number; do
    [[ -z "${number}" ]] || numbers+=("${number}")
  done < <(
    for comment in "${managed_comments[@]}"; do
      ufw status numbered 2>/dev/null \
        | sed -n -E "/# ${comment// /[[:space:]]}/ s/^\[[[:space:]]*([0-9]+)\].*/\1/p"
    done | sort -rnu
  )
  for number in "${numbers[@]}"; do
    ufw --force delete "${number}" >/dev/null
  done
}

if check_requested "${1:-}"; then
  if firewall_state_ok; then
    exit 0
  fi
  exit 1
fi

if ! is_true "${ENABLE_UFW}"; then
  if command -v ufw >/dev/null 2>&1; then
    log "Removendo somente regras UFW anteriormente gerenciadas por este instalador."
    remove_managed_rules
  fi
  rm -f -- "${firewall_state_file}"
  log "ENABLE_UFW=false; demais regras e o estado global do UFW foram preservados."
  exit 0
fi

if ! command -v ufw >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  log "UFW não encontrado; instalando o firewall do host."
  apt-get update
  if package_is_installed ufw; then
    apt-get install -y --reinstall --no-install-recommends ufw
  else
    apt-get install -y --no-install-recommends ufw
  fi
fi
require_command ufw
log "Reconciliando UFW sem bloquear a sessão SSH atual."
remove_managed_rules

while read -r ssh_port; do
  ufw allow "${ssh_port}/tcp" comment 'SSH administracao' >/dev/null
done < <(detected_ssh_ports)

ufw allow from "${DASHBOARD_ALLOWED_CIDR}" to any port "${DASHBOARD_NODE_PORT}" proto tcp \
  comment 'Kubernetes Dashboard HTTPS' >/dev/null
ufw allow in on cni0 comment 'Kubernetes CNI input' >/dev/null
ufw allow in on flannel.1 comment 'Kubernetes Flannel input' >/dev/null
ufw route allow in on cni0 comment 'Kubernetes CNI routed input' >/dev/null
ufw route allow out on cni0 comment 'Kubernetes CNI routed output' >/dev/null
ufw route allow in on flannel.1 comment 'Kubernetes Flannel routed input' >/dev/null
ufw route allow out on flannel.1 comment 'Kubernetes Flannel routed output' >/dev/null

ufw --force enable >/dev/null
ufw reload >/dev/null
ensure_state_dir
printf '%s\n' "$(firewall_fingerprint)" >"${firewall_state_file}"
chmod 0600 "${firewall_state_file}"
firewall_state_ok || die "as regras UFW foram aplicadas, mas a verificação do estado falhou."
log "UFW ativo; Dashboard permitido a partir de ${DASHBOARD_ALLOWED_CIDR}."
