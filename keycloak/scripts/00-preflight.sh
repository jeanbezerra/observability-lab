#!/usr/bin/env bash

# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_root
require_command systemd-analyze

[[ -r /etc/os-release ]] || die "/etc/os-release não existe."
# shellcheck source=/dev/null
source /etc/os-release
if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "26.04" ]]; then
  if is_true "${ALLOW_UNSUPPORTED_OS}"; then
    warn "sistema não validado: ${PRETTY_NAME:-desconhecido}; continuando por ALLOW_UNSUPPORTED_OS=true."
  else
    die "este instalador exige Ubuntu Server 26.04 LTS; encontrado ${PRETTY_NAME:-desconhecido}."
  fi
fi

case "$(dpkg --print-architecture)" in
  amd64|arm64) ;;
  *) die "arquitetura não suportada: $(dpkg --print-architecture)." ;;
esac

cpu_count="$(nproc)"
memory_kib="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
free_kib="$(df -Pk /opt 2>/dev/null | awk 'NR == 2 {print $4}')"
[[ -n "${free_kib}" ]] || free_kib="$(df -Pk / | awk 'NR == 2 {print $4}')"
(( cpu_count >= 2 )) || die "Keycloak e PostgreSQL exigem ao menos 2 CPUs; encontrado ${cpu_count}."
(( memory_kib >= 3 * 1024 * 1024 )) \
  || die "Keycloak e PostgreSQL exigem ao menos 3 GiB de RAM; encontrado $((memory_kib / 1024)) MiB."
(( free_kib >= 10 * 1024 * 1024 )) \
  || die "são necessários ao menos 10 GiB livres em /opt (ou /); encontrado $((free_kib / 1024 / 1024)) GiB."

[[ "${KEYCLOAK_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || die "KEYCLOAK_VERSION inválido: ${KEYCLOAK_VERSION}."
[[ "${KEYCLOAK_SHA256}" =~ ^[a-fA-F0-9]{64}$ ]] \
  || die "KEYCLOAK_SHA256 precisa conter 64 caracteres hexadecimais."
[[ "${POSTGRESQL_MAJOR}" == "18" ]] \
  || die "esta automação foi validada para PostgreSQL 18; encontrado ${POSTGRESQL_MAJOR}."
[[ "${KEYCLOAK_HOSTNAME}" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ \
  && "${KEYCLOAK_HOSTNAME}" == *.* ]] \
  || die "KEYCLOAK_HOSTNAME deve ser um FQDN válido."
[[ "${KEYCLOAK_HTTPS_PORT}" =~ ^[0-9]+$ ]] \
  && (( KEYCLOAK_HTTPS_PORT >= 1 && KEYCLOAK_HTTPS_PORT <= 65535 )) \
  || die "KEYCLOAK_HTTPS_PORT inválida: ${KEYCLOAK_HTTPS_PORT}."
[[ -z "${KEYCLOAK_SERVER_IP}" ]] || valid_ipv4 "${KEYCLOAK_SERVER_IP}" \
  || die "KEYCLOAK_SERVER_IP inválido: ${KEYCLOAK_SERVER_IP}."
if [[ "${KEYCLOAK_HTTPS_PORT}" == "443" ]]; then
  expected_external_url="https://${KEYCLOAK_HOSTNAME}"
else
  expected_external_url="https://${KEYCLOAK_HOSTNAME}:${KEYCLOAK_HTTPS_PORT}"
fi
[[ "${KEYCLOAK_EXTERNAL_URL}" == "${expected_external_url}" ]] \
  || die "KEYCLOAK_EXTERNAL_URL deve ser exatamente ${expected_external_url}."

getent ahosts "${KEYCLOAK_HOSTNAME}" >/dev/null 2>&1 \
  || die "${KEYCLOAK_HOSTNAME} não resolve neste servidor. Configure DNS ou /etc/hosts antes de instalar."

for identifier in KEYCLOAK_DB_NAME KEYCLOAK_DB_USER; do
  value="${!identifier}"
  [[ "${value}" =~ ^[a-z_][a-z0-9_]{0,62}$ ]] \
    || die "${identifier} deve ser um identificador PostgreSQL lower_snake_case."
done
for identifier in OIDC_REALM OIDC_CLIENT_ID OIDC_VIEWER_GROUP OIDC_ADMIN_GROUP; do
  value="${!identifier}"
  [[ "${value}" =~ ^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$ ]] \
    || die "${identifier} contém caracteres não permitidos: ${value}."
done
[[ "${KEYCLOAK_ADMIN_USER}" != "${KEYCLOAK_BOOTSTRAP_USER}" ]] \
  || die "KEYCLOAK_ADMIN_USER e KEYCLOAK_BOOTSTRAP_USER precisam ser diferentes."
[[ "${HEADLAMP_EXTERNAL_URL}" =~ ^https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]+)?/?$ ]] \
  || die "HEADLAMP_EXTERNAL_URL deve ser uma origem HTTPS, sem caminho."
[[ "${KUBECTL_OIDC_REDIRECT_URI}" =~ ^http://localhost:[0-9]+/?$ ]] \
  || die "KUBECTL_OIDC_REDIRECT_URI deve usar loopback localhost e uma porta explícita."

case "${TLS_MODE}" in
  self-signed) ;;
  provided)
    [[ -r "${TLS_CERT_FILE}" ]] || die "TLS_CERT_FILE não pode ser lido: ${TLS_CERT_FILE}."
    [[ -r "${TLS_KEY_FILE}" ]] || die "TLS_KEY_FILE não pode ser lido: ${TLS_KEY_FILE}."
    [[ -r "${TLS_CA_FILE}" ]] || die "TLS_CA_FILE não pode ser lido: ${TLS_CA_FILE}."
    ;;
  *) die "TLS_MODE aceita somente self-signed ou provided." ;;
esac
[[ "${TLS_CERT_DAYS}" =~ ^[0-9]+$ ]] && (( TLS_CERT_DAYS >= 30 )) \
  || die "TLS_CERT_DAYS deve ser um inteiro igual ou maior que 30."

[[ -n "${KEYCLOAK_SECRETS_FILE:-}" && -r "${KEYCLOAK_SECRETS_FILE}" ]] \
  || die "informe um secrets.env legível como segundo argumento do install-all.sh."
secret_mode="$(stat -c '%a' "${KEYCLOAK_SECRETS_FILE}")"
(( 8#${secret_mode} & 077 == 0 )) \
  || die "${KEYCLOAK_SECRETS_FILE} está acessível por grupo/outros (modo ${secret_mode}); execute chmod 600."
for secret_name in KEYCLOAK_DB_PASSWORD KEYCLOAK_ADMIN_PASSWORD KEYCLOAK_BOOTSTRAP_PASSWORD OIDC_CLIENT_SECRET; do
  secret_value="${!secret_name}"
  (( ${#secret_value} >= 16 )) || die "${secret_name} precisa ter ao menos 16 caracteres."
  [[ "${secret_value}" != *$'\n'* && "${secret_value}" != *$'\r'* ]] \
    || die "${secret_name} não pode conter quebra de linha."
  [[ "${secret_value}" != "SUBSTITUA_"* ]] || die "substitua o placeholder de ${secret_name}."
done
(( ${#OIDC_CLIENT_SECRET} >= 32 )) || die "OIDC_CLIENT_SECRET precisa ter ao menos 32 caracteres."

for cidr_list_name in KEYCLOAK_ALLOWED_CIDRS SSH_ALLOWED_CIDRS; do
  cidr_list="${!cidr_list_name}"
  IFS=',' read -r -a cidrs <<<"${cidr_list}"
  (( ${#cidrs[@]} > 0 )) || die "${cidr_list_name} não pode ficar vazio."
  for cidr in "${cidrs[@]}"; do
    valid_ipv4_cidr "${cidr}" || die "CIDR inválido em ${cidr_list_name}: ${cidr}."
  done
done

[[ "${BACKUP_RETENTION_DAYS}" =~ ^[0-9]+$ ]] && (( BACKUP_RETENTION_DAYS >= 1 )) \
  || die "BACKUP_RETENTION_DAYS deve ser um inteiro positivo."
[[ "${BACKUP_ON_CALENDAR}" != *$'\n'* && "${BACKUP_ON_CALENDAR}" != *$'\r'* \
  && "${BACKUP_ON_CALENDAR}" != *'|'* && "${BACKUP_ON_CALENDAR}" != *'&'* \
  && "${BACKUP_ON_CALENDAR}" != *'\\'* ]] \
  || die "BACKUP_ON_CALENDAR contém caracteres não permitidos."
systemd-analyze calendar -- "${BACKUP_ON_CALENDAR}" >/dev/null 2>&1 \
  || die "BACKUP_ON_CALENDAR não é uma expressão OnCalendar válida: ${BACKUP_ON_CALENDAR}."

if [[ "${KEYCLOAK_ALLOWED_CIDRS}" == *"0.0.0.0/0"* ]]; then
  warn "KEYCLOAK_ALLOWED_CIDRS contém 0.0.0.0/0; a tela de login e a console administrativa ficarão expostas a toda a Internet IPv4."
fi
if [[ "${SSH_ALLOWED_CIDRS}" == *"0.0.0.0/0"* ]]; then
  warn "SSH_ALLOWED_CIDRS contém 0.0.0.0/0. Restrinja-o à rede administrativa sempre que possível."
fi
warn "esta topologia possui uma única instância Keycloak e um único PostgreSQL; ela não oferece alta disponibilidade."
log "Preflight aprovado: ${cpu_count} CPUs, $((memory_kib / 1024)) MiB RAM, IdP ${KEYCLOAK_EXTERNAL_URL}."
