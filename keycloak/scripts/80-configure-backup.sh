#!/usr/bin/env bash

# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_root

render_backup_env() {
  printf 'KEYCLOAK_DB_NAME=%q\n' "${KEYCLOAK_DB_NAME}"
  printf 'KEYCLOAK_BACKUP_DIR=%q\n' "${KEYCLOAK_BACKUP_DIR}"
  printf 'BACKUP_RETENTION_DAYS=%q\n' "${BACKUP_RETENTION_DAYS}"
}

render_timer() {
  sed "s|__ON_CALENDAR__|${BACKUP_ON_CALENDAR}|" \
    "${PROJECT_DIR}/systemd/keycloak-backup.timer"
}

backup_state_ok() {
  cmp -s "${PROJECT_DIR}/scripts/keycloak-backup.sh" /usr/local/sbin/keycloak-backup || {
    check_pending "utilitário de backup está ausente ou desatualizado."
    return 1
  }
  cmp -s <(render_backup_env) "${KEYCLOAK_CONFIG_DIR}/backup.env" || {
    check_pending "backup.env está ausente ou desatualizado."
    return 1
  }
  cmp -s "${PROJECT_DIR}/systemd/keycloak-backup.service" \
    /etc/systemd/system/keycloak-backup.service || {
      check_pending "unit de backup está ausente ou desatualizada."
      return 1
    }
  cmp -s <(render_timer) /etc/systemd/system/keycloak-backup.timer || {
    check_pending "timer de backup está ausente ou desatualizado."
    return 1
  }
  [[ "$(stat -c '%U:%G:%a' "${KEYCLOAK_BACKUP_DIR}")" == "root:root:700" ]] || {
    check_pending "diretório de backup está ausente ou com permissões incorretas."
    return 1
  }
  systemctl is-enabled --quiet keycloak-backup.timer || {
    check_pending "timer de backup não está habilitado."
    return 1
  }
  systemctl is-active --quiet keycloak-backup.timer || {
    check_pending "timer de backup não está ativo."
    return 1
  }
}

if check_requested "${1:-}"; then
  backup_state_ok
  exit $?
fi

install -d -o root -g root -m 0700 "${KEYCLOAK_BACKUP_DIR}"
install -o root -g root -m 0750 "${PROJECT_DIR}/scripts/keycloak-backup.sh" \
  /usr/local/sbin/keycloak-backup
render_backup_env >"${KEYCLOAK_CONFIG_DIR}/backup.env"
chown root:root "${KEYCLOAK_CONFIG_DIR}/backup.env"
chmod 0600 "${KEYCLOAK_CONFIG_DIR}/backup.env"
install -o root -g root -m 0644 "${PROJECT_DIR}/systemd/keycloak-backup.service" \
  /etc/systemd/system/keycloak-backup.service
render_timer >/etc/systemd/system/keycloak-backup.timer
chown root:root /etc/systemd/system/keycloak-backup.timer
chmod 0644 /etc/systemd/system/keycloak-backup.timer

systemctl daemon-reload
systemctl enable --now keycloak-backup.timer

backup_state_ok || die "backup foi configurado, mas a verificação falhou."
log "Backup lógico diário agendado (${BACKUP_ON_CALENDAR}), retenção local de ${BACKUP_RETENTION_DAYS} dias."

