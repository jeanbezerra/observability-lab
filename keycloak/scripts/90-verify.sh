#!/usr/bin/env bash

# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_root
require_command curl
require_command jq

log "Verificando serviços e banco."
systemctl is-active --quiet postgresql || die "PostgreSQL não está ativo."
systemctl is-active --quiet keycloak || die "Keycloak não está ativo."
systemctl is-enabled --quiet keycloak || die "Keycloak não está habilitado no boot."
systemctl is-active --quiet keycloak-backup.timer || die "timer de backup não está ativo."

server_version="$(runuser -u postgres -- psql -X -Atqc \
  "SELECT current_setting('server_version_num')" postgres)"
[[ "${server_version}" =~ ^18[0-9]{4}$ ]] \
  || die "servidor PostgreSQL não pertence à major 18."
runuser -u postgres -- pg_dump --schema-only "${KEYCLOAK_DB_NAME}" >/dev/null \
  || die "smoke test de pg_dump falhou."

log "Verificando TLS, health e discovery OIDC."
openssl verify -CAfile "${KEYCLOAK_TLS_DIR}/ca.crt" "${KEYCLOAK_TLS_DIR}/tls.crt" >/dev/null \
  || die "cadeia TLS do Keycloak é inválida."
openssl x509 -in "${KEYCLOAK_TLS_DIR}/tls.crt" -noout -checkhost "${KEYCLOAK_HOSTNAME}" >/dev/null \
  || die "certificado não cobre ${KEYCLOAK_HOSTNAME}."
curl -fsS --connect-timeout 3 --max-time 10 http://127.0.0.1:9000/health/ready \
  | jq -e '.status == "UP"' >/dev/null || die "health/ready não está UP."
discovery="$(curl_keycloak "${OIDC_ISSUER_URL}/.well-known/openid-configuration")"
jq -e --arg issuer "${OIDC_ISSUER_URL}" \
  '.issuer == $issuer and (.authorization_endpoint | startswith($issuer)) and (.jwks_uri | startswith($issuer))' \
  <<<"${discovery}" >/dev/null || die "documento discovery não corresponde ao issuer esperado."
jwks_uri="$(jq -r '.jwks_uri' <<<"${discovery}")"
curl_keycloak "${jwks_uri}" | jq -e '.keys | length > 0' >/dev/null \
  || die "JWKS não contém chaves de assinatura."

log "Verificando objetos do realm com a etapa reconciliadora."
"${PROJECT_DIR}/scripts/60-configure-realm.sh" --check \
  || die "realm, cliente ou grupos OIDC estão divergentes."
"${PROJECT_DIR}/scripts/70-configure-firewall.sh" --check \
  || die "firewall diverge da configuração desejada."
"${PROJECT_DIR}/scripts/80-configure-backup.sh" --check \
  || die "backup diverge da configuração desejada."

if ! find "${KEYCLOAK_BACKUP_DIR}" -maxdepth 1 -type f -name 'keycloak-*.dump' -print -quit \
  | grep -q .; then
  log "Criando o primeiro backup lógico validado."
  /usr/local/sbin/keycloak-backup >/dev/null
fi
latest_backup="$(find "${KEYCLOAK_BACKUP_DIR}" -maxdepth 1 -type f -name 'keycloak-*.dump' \
  -printf '%T@ %p\n' | sort -nr | head -n 1 | cut -d' ' -f2-)"
[[ -n "${latest_backup}" ]] || die "nenhum backup lógico foi encontrado."
pg_restore --list "${latest_backup}" >/dev/null || die "o backup lógico mais recente é ilegível."
sha256sum -c "${latest_backup}.sha256" >/dev/null \
  || die "checksum do backup mais recente não confere."

cat <<EOF

Keycloak validado com sucesso.
  URL:            ${KEYCLOAK_EXTERNAL_URL}
  Console admin:  ${KEYCLOAK_EXTERNAL_URL}/admin/
  Issuer K8s:     ${OIDC_ISSUER_URL}
  Discovery:      ${OIDC_ISSUER_URL}/.well-known/openid-configuration
  CA para cluster:${KEYCLOAK_TLS_DIR}/ca.crt
  Grupos RBAC:    ${OIDC_VIEWER_GROUP} / ${OIDC_ADMIN_GROUP}
  Backup recente: ${latest_backup}

PostgreSQL 5432 e management 9000 permanecem locais; o UFW publica apenas
HTTPS/${KEYCLOAK_HTTPS_PORT} e SSH para os CIDRs configurados.
EOF
