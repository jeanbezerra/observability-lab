#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

[[ "${EUID}" -eq 0 ]] || {
  printf 'ERRO: execute como root.\n' >&2
  exit 1
}
[[ -r /etc/keycloak/backup.env ]] || {
  printf 'ERRO: /etc/keycloak/backup.env não pode ser lido.\n' >&2
  exit 1
}
# shellcheck source=/dev/null
source /etc/keycloak/backup.env

backup_dir="${KEYCLOAK_BACKUP_DIR:-/var/backups/keycloak}"
database_name="${KEYCLOAK_DB_NAME:-keycloak}"
retention_days="${BACKUP_RETENTION_DAYS:-14}"
timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
final_file="${backup_dir}/keycloak-${timestamp}.dump"

install -d -o root -g root -m 0700 "${backup_dir}"
temporary_file="$(mktemp "${backup_dir}/.keycloak-${timestamp}.XXXXXX.dump")"
cleanup() {
  rm -f -- "${temporary_file:-}"
}
trap cleanup EXIT

runuser -u postgres -- pg_dump --format=custom --compress=6 \
  --no-owner --no-acl "${database_name}" >"${temporary_file}"
pg_restore --list "${temporary_file}" >/dev/null
chmod 0600 "${temporary_file}"
mv -- "${temporary_file}" "${final_file}"
temporary_file=""
sha256sum "${final_file}" >"${final_file}.sha256"
chmod 0600 "${final_file}.sha256"

find "${backup_dir}" -maxdepth 1 -type f \
  \( -name 'keycloak-*.dump' -o -name 'keycloak-*.dump.sha256' \) \
  -mtime "+${retention_days}" -print -delete

printf 'Backup lógico criado e validado: %s\n' "${final_file}"
