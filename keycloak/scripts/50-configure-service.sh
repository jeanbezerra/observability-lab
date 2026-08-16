#!/usr/bin/env bash

# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_root

service_state_ok() {
  cmp -s "${PROJECT_DIR}/systemd/keycloak.service" /etc/systemd/system/keycloak.service || {
    check_pending "unit systemd do Keycloak está ausente ou desatualizada."
    return 1
  }
  systemctl is-enabled --quiet keycloak || {
    check_pending "Keycloak não está habilitado no boot."
    return 1
  }
  systemctl is-active --quiet keycloak || {
    check_pending "Keycloak não está ativo."
    return 1
  }
  curl -fsS --connect-timeout 3 --max-time 10 \
    http://127.0.0.1:9000/health/ready | jq -e '.status == "UP"' >/dev/null || {
      check_pending "health/ready local do Keycloak não está UP."
      return 1
    }
  curl_keycloak "${KEYCLOAK_EXTERNAL_URL}/realms/master/.well-known/openid-configuration" \
    | jq -e --arg issuer "${KEYCLOAK_EXTERNAL_URL}/realms/master" '.issuer == $issuer' >/dev/null || {
      check_pending "discovery OIDC do realm master não responde com o issuer esperado."
      return 1
    }
  ss -H -ltn 'sport = :9000' | awk '{print $4}' | grep -Eq '^(127\.0\.0\.1|\[::1\]):9000$' || {
    check_pending "porta de gerenciamento 9000 não está em loopback."
    return 1
  }
  if ss -H -ltn 'sport = :9000' | awk '{print $4}' | grep -Ev '^(127\.0\.0\.1|\[::1\]):9000$' | grep -q .; then
    check_pending "porta de gerenciamento 9000 também está exposta fora do loopback."
    return 1
  fi
}

if check_requested "${1:-}"; then
  service_state_ok
  exit $?
fi

require_command curl
require_command jq
require_command ss
install -o root -g root -m 0644 "${PROJECT_DIR}/systemd/keycloak.service" \
  /etc/systemd/system/keycloak.service
systemctl daemon-reload
systemctl enable keycloak
systemctl restart keycloak

if ! retry 60 5 curl -fsS --connect-timeout 3 --max-time 10 \
  http://127.0.0.1:9000/health/ready -o /dev/null; then
  systemctl --no-pager --full status keycloak >&2 || true
  journalctl -u keycloak --no-pager -n 150 >&2 || true
  die "Keycloak não ficou pronto em cinco minutos."
fi

service_state_ok || die "o serviço Keycloak iniciou, mas a verificação de estado falhou."
log "Serviço Keycloak ativo em ${KEYCLOAK_EXTERNAL_URL}; gerenciamento restrito ao loopback."

