#!/usr/bin/env bash
# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
require_root
validate_config
if check_requested "${1:-}"; then
  status="$(ufw status)"
  if [[ "${status}" != *'Status: active'* ]]; then
    [[ "${ENABLE_UFW}" == false ]] || die 'Ativação UFW pendente.'
    exit 0
  fi
  for port in "${SSH_PORT}" 80 443; do
    grep -Eq "^${port}/tcp[[:space:]].*ALLOW" <<<"${status}" || die "Regra UFW TCP/${port} pendente."
  done
  exit 0
fi
if ufw status | grep -q '^Status: active' || [[ "${ENABLE_UFW}" == true ]]; then
  ufw allow "${SSH_PORT}/tcp" comment 'SSH administration'
  ufw allow 80/tcp comment 'Rancher HTTP redirect'
  ufw allow 443/tcp comment 'Rancher HTTPS agents and UI'
  if [[ "${ENABLE_UFW}" == true ]]; then ufw --force enable; fi
fi
log 'Backend não exposto; acesso externo usa TCP/80 e TCP/443.'
