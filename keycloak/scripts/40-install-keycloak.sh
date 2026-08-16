#!/usr/bin/env bash

# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_root

render_keycloak_conf() {
  cat <<EOF
# Gerenciado por ${PROJECT_DIR}/scripts/40-install-keycloak.sh
db=postgres
db-url=${KEYCLOAK_DB_URL}
db-username=${KEYCLOAK_DB_USER}
db-pool-initial-size=${KEYCLOAK_DB_POOL_INITIAL_SIZE}
db-pool-min-size=${KEYCLOAK_DB_POOL_MIN_SIZE}
db-pool-max-size=${KEYCLOAK_DB_POOL_MAX_SIZE}

hostname=${KEYCLOAK_EXTERNAL_URL}
http-enabled=false
https-port=${KEYCLOAK_HTTPS_PORT}
https-certificate-file=${KEYCLOAK_TLS_DIR}/tls.crt
https-certificate-key-file=${KEYCLOAK_TLS_DIR}/tls.key
https-certificates-reload-period=1h

health-enabled=true
metrics-enabled=true
http-management-host=127.0.0.1
http-management-port=9000
http-management-scheme=http
http-management-health-enabled=true

cache=ispn
cache-stack=jdbc-ping
server-async-bootstrap=false

log=console
log-console-output=json
EOF
}

render_runtime_env() {
  printf 'JAVA_OPTS_KC_HEAP=%s\n' "$(systemd_quote "${KEYCLOAK_JAVA_HEAP}")"
}

render_secret_env() {
  printf 'KCRAW_DB_PASSWORD=%s\n' "$(systemd_quote "${KEYCLOAK_DB_PASSWORD}")"
}

build_fingerprint() {
  printf '%s\n' \
    "version=${KEYCLOAK_VERSION}" \
    "db=postgres" \
    "health-enabled=true" \
    "metrics-enabled=true" \
    | sha256sum | awk '{print $1}'
}

keycloak_state_ok() {
  [[ -L "${KEYCLOAK_HOME}" && "$(readlink -f "${KEYCLOAK_HOME}")" == "${KEYCLOAK_VERSION_HOME}" ]] || {
    check_pending "${KEYCLOAK_HOME} não aponta para ${KEYCLOAK_VERSION_HOME}."
    return 1
  }
  [[ -x "${KEYCLOAK_HOME}/bin/kc.sh" && -x "${KEYCLOAK_HOME}/bin/kcadm.sh" ]] || {
    check_pending "binários Keycloak estão ausentes."
    return 1
  }
  [[ -r "${KEYCLOAK_VERSION_HOME}/.distribution-sha256" \
    && "$(<"${KEYCLOAK_VERSION_HOME}/.distribution-sha256")" == "${KEYCLOAK_SHA256,,}" ]] || {
    check_pending "marcador de integridade da distribuição está ausente ou incorreto."
    return 1
  }
  [[ -r "${KEYCLOAK_VERSION_HOME}/.build-fingerprint" \
    && "$(<"${KEYCLOAK_VERSION_HOME}/.build-fingerprint")" == "$(build_fingerprint)" ]] || {
    check_pending "build otimizado do Keycloak está ausente ou desatualizado."
    return 1
  }
  cmp -s <(render_keycloak_conf) "${KEYCLOAK_CONFIG_DIR}/keycloak.conf" || {
    check_pending "keycloak.conf difere da configuração desejada."
    return 1
  }
  cmp -s <(render_runtime_env) "${KEYCLOAK_CONFIG_DIR}/keycloak.env" || {
    check_pending "keycloak.env difere da configuração desejada."
    return 1
  }
  cmp -s <(render_secret_env) "${KEYCLOAK_CONFIG_DIR}/keycloak-secrets.env" || {
    check_pending "senha do banco instalada precisa ser reconciliada."
    return 1
  }
  [[ "$(stat -c '%U:%G:%a' "${KEYCLOAK_CONFIG_DIR}/keycloak-secrets.env")" == "root:${KEYCLOAK_GROUP}:640" ]] || {
    check_pending "permissões do arquivo de segredos do runtime estão incorretas."
    return 1
  }
  [[ -L "${KEYCLOAK_VERSION_HOME}/conf/keycloak.conf" \
    && "$(readlink -f "${KEYCLOAK_VERSION_HOME}/conf/keycloak.conf")" == "${KEYCLOAK_CONFIG_DIR}/keycloak.conf" ]] || {
    check_pending "distribuição não referencia o keycloak.conf em /etc."
    return 1
  }
  [[ -L "${KEYCLOAK_VERSION_HOME}/data" \
    && "$(readlink -f "${KEYCLOAK_VERSION_HOME}/data")" == "${KEYCLOAK_DATA_DIR}" ]] || {
    check_pending "diretório data do Keycloak não está persistido em /var/lib."
    return 1
  }
}

if check_requested "${1:-}"; then
  keycloak_state_ok
  exit $?
fi

require_command curl
require_command sha256sum
require_command tar

install -d -o root -g root -m 0755 /var/cache/keycloak
archive="/var/cache/keycloak/keycloak-${KEYCLOAK_VERSION}.tar.gz"
archive_valid=false
if [[ -s "${archive}" ]]; then
  actual_sha="$(sha256sum "${archive}" | awk '{print $1}')"
  [[ "${actual_sha}" == "${KEYCLOAK_SHA256,,}" ]] && archive_valid=true
fi
if ! is_true "${archive_valid}"; then
  log "Baixando Keycloak ${KEYCLOAK_VERSION} da release oficial."
  temporary_archive="${archive}.part"
  rm -f -- "${temporary_archive}"
  retry 3 5 curl -fL --connect-timeout 10 --max-time 600 \
    --output "${temporary_archive}" "${KEYCLOAK_DOWNLOAD_URL}"
  actual_sha="$(sha256sum "${temporary_archive}" | awk '{print $1}')"
  [[ "${actual_sha}" == "${KEYCLOAK_SHA256,,}" ]] \
    || die "SHA-256 do Keycloak inválido: esperado ${KEYCLOAK_SHA256,,}, obtido ${actual_sha}."
  mv -f -- "${temporary_archive}" "${archive}"
fi

if [[ -e "${KEYCLOAK_VERSION_HOME}" ]]; then
  [[ -r "${KEYCLOAK_VERSION_HOME}/.distribution-sha256" \
    && "$(<"${KEYCLOAK_VERSION_HOME}/.distribution-sha256")" == "${KEYCLOAK_SHA256,,}" ]] \
    || die "${KEYCLOAK_VERSION_HOME} já existe sem o marcador esperado; ele não será sobrescrito."
else
  extraction_dir="$(mktemp -d /opt/.keycloak-extract.XXXXXX)"
  cleanup_extraction() {
    if [[ -n "${extraction_dir:-}" && "${extraction_dir}" == /opt/.keycloak-extract.* ]]; then
      rm -rf -- "${extraction_dir}"
    fi
  }
  trap cleanup_extraction EXIT
  tar -xzf "${archive}" -C "${extraction_dir}"
  extracted_home="${extraction_dir}/keycloak-${KEYCLOAK_VERSION}"
  [[ -x "${extracted_home}/bin/kc.sh" ]] \
    || die "o arquivo baixado não contém a distribuição Keycloak esperada."
  mv -- "${extracted_home}" "${KEYCLOAK_VERSION_HOME}"
  printf '%s\n' "${KEYCLOAK_SHA256,,}" >"${KEYCLOAK_VERSION_HOME}/.distribution-sha256"
  extraction_dir=""
fi

install -d -o root -g "${KEYCLOAK_GROUP}" -m 0750 "${KEYCLOAK_CONFIG_DIR}"
render_keycloak_conf >"${KEYCLOAK_CONFIG_DIR}/keycloak.conf"
render_runtime_env >"${KEYCLOAK_CONFIG_DIR}/keycloak.env"
render_secret_env >"${KEYCLOAK_CONFIG_DIR}/keycloak-secrets.env"
chown root:"${KEYCLOAK_GROUP}" "${KEYCLOAK_CONFIG_DIR}/keycloak.conf" \
  "${KEYCLOAK_CONFIG_DIR}/keycloak.env" "${KEYCLOAK_CONFIG_DIR}/keycloak-secrets.env"
chmod 0640 "${KEYCLOAK_CONFIG_DIR}/keycloak.conf" \
  "${KEYCLOAK_CONFIG_DIR}/keycloak.env" "${KEYCLOAK_CONFIG_DIR}/keycloak-secrets.env"

# Faça a distribuição pertencer ao usuário de serviço antes de criar links para
# /etc e /var/lib, evitando que um chown recursivo atravesse esses links.
chown -hR "${KEYCLOAK_USER}:${KEYCLOAK_GROUP}" "${KEYCLOAK_VERSION_HOME}"

if [[ ! -L "${KEYCLOAK_VERSION_HOME}/conf/keycloak.conf" ]]; then
  if [[ -e "${KEYCLOAK_VERSION_HOME}/conf/keycloak.conf" ]]; then
    mv -- "${KEYCLOAK_VERSION_HOME}/conf/keycloak.conf" \
      "${KEYCLOAK_VERSION_HOME}/conf/keycloak.conf.distribution"
  fi
  ln -s "${KEYCLOAK_CONFIG_DIR}/keycloak.conf" "${KEYCLOAK_VERSION_HOME}/conf/keycloak.conf"
fi

if [[ ! -L "${KEYCLOAK_VERSION_HOME}/data" ]]; then
  if [[ -d "${KEYCLOAK_VERSION_HOME}/data" ]]; then
    cp -a "${KEYCLOAK_VERSION_HOME}/data/." "${KEYCLOAK_DATA_DIR}/"
    mv -- "${KEYCLOAK_VERSION_HOME}/data" "${KEYCLOAK_VERSION_HOME}/data.distribution"
  fi
  ln -s "${KEYCLOAK_DATA_DIR}" "${KEYCLOAK_VERSION_HOME}/data"
fi

chown -R "${KEYCLOAK_USER}:${KEYCLOAK_GROUP}" "${KEYCLOAK_DATA_DIR}"

if [[ ! -r "${KEYCLOAK_VERSION_HOME}/.build-fingerprint" \
  || "$(<"${KEYCLOAK_VERSION_HOME}/.build-fingerprint")" != "$(build_fingerprint)" ]]; then
  log "Gerando build Keycloak otimizado para PostgreSQL, health e métricas."
  runuser -u "${KEYCLOAK_USER}" -- "${KEYCLOAK_VERSION_HOME}/bin/kc.sh" build \
    --db=postgres --health-enabled=true --metrics-enabled=true
  printf '%s\n' "$(build_fingerprint)" >"${KEYCLOAK_VERSION_HOME}/.build-fingerprint"
  chown "${KEYCLOAK_USER}:${KEYCLOAK_GROUP}" "${KEYCLOAK_VERSION_HOME}/.build-fingerprint"
fi

if [[ -e "${KEYCLOAK_HOME}" && ! -L "${KEYCLOAK_HOME}" ]]; then
  die "${KEYCLOAK_HOME} existe e não é um link simbólico; ele não será substituído."
fi
if [[ -L "${KEYCLOAK_HOME}" && "$(readlink -f "${KEYCLOAK_HOME}")" != "${KEYCLOAK_VERSION_HOME}" ]] \
  && systemctl is-active --quiet keycloak 2>/dev/null; then
  warn "Atualização de versão: parando o serviço antes de trocar o link /opt/keycloak."
  systemctl stop keycloak
fi
ln -sfn "${KEYCLOAK_VERSION_HOME}" "${KEYCLOAK_HOME}"

keycloak_state_ok || die "a distribuição Keycloak foi instalada, mas a verificação falhou."
log "Keycloak ${KEYCLOAK_VERSION} instalado e otimizado em ${KEYCLOAK_VERSION_HOME}."
