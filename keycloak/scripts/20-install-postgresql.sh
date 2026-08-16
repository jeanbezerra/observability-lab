#!/usr/bin/env bash

# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_root

postgres_query() {
  runuser -u postgres -- psql -X -v ON_ERROR_STOP=1 -Atqc "$1" postgres
}

database_state_ok() {
  local server_version role_attributes role_password database_owner listen_addresses
  systemctl is-enabled --quiet postgresql || {
    check_pending "PostgreSQL não está habilitado no boot."
    return 1
  }
  systemctl is-active --quiet postgresql || {
    check_pending "PostgreSQL não está ativo."
    return 1
  }
  server_version="$(postgres_query "SELECT current_setting('server_version_num')")"
  [[ "${server_version}" =~ ^18[0-9]{4}$ ]] || {
    check_pending "servidor PostgreSQL ativo não pertence à major 18."
    return 1
  }
  role_attributes="$(postgres_query "SELECT rolcanlogin || ':' || rolsuper || ':' || rolcreatedb || ':' || rolcreaterole || ':' || rolreplication || ':' || rolbypassrls FROM pg_roles WHERE rolname = '${KEYCLOAK_DB_USER}'")"
  [[ "${role_attributes}" == "true:false:false:false:false:false" ]] || {
    check_pending "role ${KEYCLOAK_DB_USER} está ausente ou possui privilégios excessivos."
    return 1
  }
  role_password="$(postgres_query "SELECT rolpassword FROM pg_authid WHERE rolname = '${KEYCLOAK_DB_USER}'")"
  [[ "${role_password}" == SCRAM-SHA-256\$* ]] || {
    check_pending "senha da role ${KEYCLOAK_DB_USER} não usa SCRAM-SHA-256."
    return 1
  }
  database_owner="$(postgres_query "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = '${KEYCLOAK_DB_NAME}'")"
  [[ "${database_owner}" == "${KEYCLOAK_DB_USER}" ]] || {
    check_pending "database ${KEYCLOAK_DB_NAME} está ausente ou pertence a outra role."
    return 1
  }
  PGPASSWORD="${KEYCLOAK_DB_PASSWORD}" psql -X -v ON_ERROR_STOP=1 \
    -h 127.0.0.1 -U "${KEYCLOAK_DB_USER}" -d "${KEYCLOAK_DB_NAME}" \
    -Atqc 'SELECT current_user' | grep -Fxq "${KEYCLOAK_DB_USER}" || {
      check_pending "autenticação TCP local do usuário Keycloak falhou."
      return 1
    }
  listen_addresses="$(postgres_query "SELECT current_setting('listen_addresses')")"
  [[ "${listen_addresses}" != "*" && "${listen_addresses}" != *"0.0.0.0"* ]] || {
    check_pending "PostgreSQL está escutando em todas as interfaces."
    return 1
  }
}

if check_requested "${1:-}"; then
  database_state_ok
  exit $?
fi

systemctl enable --now postgresql
retry 20 2 systemctl is-active --quiet postgresql \
  || die "PostgreSQL não ficou ativo."

server_version="$(postgres_query "SELECT current_setting('server_version_num')")"
[[ "${server_version}" =~ ^18[0-9]{4}$ ]] \
  || die "esperado PostgreSQL 18.x, encontrado server_version_num=${server_version}."

log "Criando/reconciliando role PostgreSQL sem privilégios administrativos."
runuser -u postgres -- psql -X -v ON_ERROR_STOP=1 \
  --set=role_name="${KEYCLOAK_DB_USER}" \
  --set=role_password="${KEYCLOAK_DB_PASSWORD}" postgres <<'SQL'
SET password_encryption = 'scram-sha-256';
SELECT format(
  'CREATE ROLE %I LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS PASSWORD %L',
  :'role_name', :'role_password'
)
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'role_name')
\gexec
SELECT format(
  'ALTER ROLE %I WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS PASSWORD %L',
  :'role_name', :'role_password'
)
\gexec
SQL

if ! postgres_query "SELECT 1 FROM pg_database WHERE datname = '${KEYCLOAK_DB_NAME}'" | grep -Fxq 1; then
  log "Criando database ${KEYCLOAK_DB_NAME} com UTF-8 e owner dedicado."
  runuser -u postgres -- createdb --owner="${KEYCLOAK_DB_USER}" \
    --encoding=UTF8 --template=template0 "${KEYCLOAK_DB_NAME}"
fi

runuser -u postgres -- psql -X -v ON_ERROR_STOP=1 \
  --set=db_name="${KEYCLOAK_DB_NAME}" --set=role_name="${KEYCLOAK_DB_USER}" postgres <<'SQL'
SELECT format('ALTER DATABASE %I OWNER TO %I', :'db_name', :'role_name') \gexec
SELECT format('REVOKE ALL ON DATABASE %I FROM PUBLIC', :'db_name') \gexec
SELECT format('GRANT CONNECT, TEMPORARY ON DATABASE %I TO %I', :'db_name', :'role_name') \gexec
SQL

database_state_ok || die "PostgreSQL foi configurado, mas a verificação falhou."
log "PostgreSQL 18 pronto; database ${KEYCLOAK_DB_NAME} aceita somente a role dedicada via SCRAM."

