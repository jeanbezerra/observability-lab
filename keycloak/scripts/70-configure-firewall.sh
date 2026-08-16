#!/usr/bin/env bash

# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_root

firewall_state_file="${KEYCLOAK_STATE_DIR}/ufw.fingerprint"
managed_comments=('Keycloak SSH' 'Keycloak HTTPS')

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
    printf 'keycloak_cidrs=%s\n' "${KEYCLOAK_ALLOWED_CIDRS}"
    printf 'keycloak_port=%s\n' "${KEYCLOAK_HTTPS_PORT}"
    printf 'ssh_cidrs=%s\n' "${SSH_ALLOWED_CIDRS}"
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

expected_rules_exist() {
  local status_output cidr port
  status_output="$(ufw status 2>/dev/null)"
  IFS=',' read -r -a keycloak_cidrs <<<"${KEYCLOAK_ALLOWED_CIDRS}"
  for cidr in "${keycloak_cidrs[@]}"; do
    grep -E "^${KEYCLOAK_HTTPS_PORT}/tcp[[:space:]]+ALLOW IN[[:space:]]+${cidr//./\.}([[:space:]]|$).*# Keycloak HTTPS" \
      <<<"${status_output}" >/dev/null || return 1
  done
  IFS=',' read -r -a ssh_cidrs <<<"${SSH_ALLOWED_CIDRS}"
  while read -r port; do
    for cidr in "${ssh_cidrs[@]}"; do
      grep -E "^${port}/tcp[[:space:]]+ALLOW IN[[:space:]]+${cidr//./\.}([[:space:]]|$).*# Keycloak SSH" \
        <<<"${status_output}" >/dev/null || return 1
    done
  done < <(detected_ssh_ports)
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
  [[ -r "${firewall_state_file}" \
    && "$(<"${firewall_state_file}")" == "$(firewall_fingerprint)" ]] || {
      check_pending "regras UFW precisam ser reconciliadas."
      return 1
    }
  expected_rules_exist || {
    check_pending "uma ou mais regras UFW esperadas estão ausentes."
    return 1
  }
  if ufw status | grep -Eq '^(5432|9000)/tcp[[:space:]]+ALLOW'; then
    check_pending "UFW possui uma regra que expõe PostgreSQL ou a interface de gerenciamento."
    return 1
  fi
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
  firewall_state_ok
  exit $?
fi

if ! is_true "${ENABLE_UFW}"; then
  if command -v ufw >/dev/null 2>&1; then
    remove_managed_rules
  fi
  rm -f -- "${firewall_state_file}"
  log "ENABLE_UFW=false; somente regras anteriormente gerenciadas foram removidas."
  exit 0
fi

require_command ufw
remove_managed_rules

IFS=',' read -r -a ssh_cidrs <<<"${SSH_ALLOWED_CIDRS}"
while read -r port; do
  for cidr in "${ssh_cidrs[@]}"; do
    ufw allow from "${cidr}" to any port "${port}" proto tcp \
      comment 'Keycloak SSH' >/dev/null
  done
done < <(detected_ssh_ports)

IFS=',' read -r -a keycloak_cidrs <<<"${KEYCLOAK_ALLOWED_CIDRS}"
for cidr in "${keycloak_cidrs[@]}"; do
  ufw allow from "${cidr}" to any port "${KEYCLOAK_HTTPS_PORT}" proto tcp \
    comment 'Keycloak HTTPS' >/dev/null
done

ufw --force enable >/dev/null
ufw reload >/dev/null
ensure_state_dir
printf '%s\n' "$(firewall_fingerprint)" >"${firewall_state_file}"
chmod 0600 "${firewall_state_file}"

firewall_state_ok || die "UFW foi aplicado, mas a verificação de estado falhou."
log "UFW ativo; somente SSH e HTTPS/${KEYCLOAK_HTTPS_PORT} foram liberados nos CIDRs configurados."

