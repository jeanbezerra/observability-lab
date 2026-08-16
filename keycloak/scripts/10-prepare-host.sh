#!/usr/bin/env bash

# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_root
export DEBIAN_FRONTEND=noninteractive

required_packages=(
  ca-certificates curl iproute2 jq openssl tar "${JAVA_PACKAGE}"
  "postgresql-${POSTGRESQL_MAJOR}" "postgresql-client-${POSTGRESQL_MAJOR}"
)
is_true "${ENABLE_UFW}" && required_packages+=(ufw)

host_state_ok() {
  local package_name java_major psql_major
  for package_name in "${required_packages[@]}"; do
    package_is_installed "${package_name}" || {
      check_pending "pacote ausente: ${package_name}."
      return 1
    }
  done
  for command_name in curl java jq openssl psql sha256sum ss tar; do
    command -v "${command_name}" >/dev/null 2>&1 || {
      check_pending "comando ausente: ${command_name}."
      return 1
    }
  done
  java_major="$(java -version 2>&1 | sed -n '1s/.*version "\([0-9]*\).*/\1/p')"
  [[ "${java_major}" == "25" ]] || {
    check_pending "Java ativo não é OpenJDK 25."
    return 1
  }
  psql_major="$(psql --version | awk '{print $3}' | cut -d. -f1)"
  [[ "${psql_major}" == "${POSTGRESQL_MAJOR}" ]] || {
    check_pending "cliente psql ativo não é PostgreSQL ${POSTGRESQL_MAJOR}."
    return 1
  }
  id "${KEYCLOAK_USER}" >/dev/null 2>&1 || {
    check_pending "usuário de sistema ${KEYCLOAK_USER} não existe."
    return 1
  }
  [[ "$(getent passwd "${KEYCLOAK_USER}" | cut -d: -f7)" == "/usr/sbin/nologin" ]] || {
    check_pending "usuário ${KEYCLOAK_USER} ainda possui shell interativo."
    return 1
  }
  for directory in "${KEYCLOAK_CONFIG_DIR}" "${KEYCLOAK_TLS_DIR}" "${KEYCLOAK_DATA_DIR}" "${KEYCLOAK_STATE_DIR}"; do
    [[ -d "${directory}" ]] || {
      check_pending "diretório ausente: ${directory}."
      return 1
    }
  done
  [[ "$(stat -c '%U:%G:%a' "${KEYCLOAK_CONFIG_DIR}")" == "root:${KEYCLOAK_GROUP}:750" ]] || {
    check_pending "permissões de ${KEYCLOAK_CONFIG_DIR} estão incorretas."
    return 1
  }
  [[ "$(stat -c '%U:%G:%a' "${KEYCLOAK_DATA_DIR}")" == "${KEYCLOAK_USER}:${KEYCLOAK_GROUP}:750" ]] || {
    check_pending "permissões de ${KEYCLOAK_DATA_DIR} estão incorretas."
    return 1
  }
}

if check_requested "${1:-}"; then
  host_state_ok
  exit $?
fi

missing_packages=()
for package_name in "${required_packages[@]}"; do
  package_is_installed "${package_name}" || missing_packages+=("${package_name}")
done
if (( ${#missing_packages[@]} > 0 )); then
  apt-get update
  apt-get install -y --no-install-recommends "${missing_packages[@]}"
else
  log "Pacotes do host já estão instalados."
fi

if ! getent group "${KEYCLOAK_GROUP}" >/dev/null; then
  groupadd --system "${KEYCLOAK_GROUP}"
fi
if id "${KEYCLOAK_USER}" >/dev/null 2>&1; then
  usermod --home "${KEYCLOAK_DATA_DIR}" --shell /usr/sbin/nologin "${KEYCLOAK_USER}"
else
  useradd --system --gid "${KEYCLOAK_GROUP}" --home-dir "${KEYCLOAK_DATA_DIR}" \
    --no-create-home --shell /usr/sbin/nologin "${KEYCLOAK_USER}"
fi

install -d -o root -g "${KEYCLOAK_GROUP}" -m 0750 "${KEYCLOAK_CONFIG_DIR}" "${KEYCLOAK_TLS_DIR}"
install -d -o "${KEYCLOAK_USER}" -g "${KEYCLOAK_GROUP}" -m 0750 "${KEYCLOAK_DATA_DIR}"
install -d -o root -g root -m 0700 "${KEYCLOAK_STATE_DIR}"

if command -v timedatectl >/dev/null 2>&1 \
  && [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)" != "yes" ]]; then
  warn "o relógio ainda não está sincronizado por NTP; OIDC depende de horário correto."
fi

host_state_ok || die "a preparação do host terminou, mas o estado esperado não foi atingido."
log "Host preparado com OpenJDK 25 e PostgreSQL ${POSTGRESQL_MAJOR}."
