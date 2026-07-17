#!/usr/bin/env bash

# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_root
export DEBIAN_FRONTEND=noninteractive

containerd_state_ok() {
  command -v containerd >/dev/null 2>&1 || {
    check_pending "containerd não está instalado."
    return 1
  }
  command -v runc >/dev/null 2>&1 || {
    check_pending "runc não está instalado."
    return 1
  }
  [[ -s /etc/containerd/config.toml ]] || {
    check_pending "/etc/containerd/config.toml não existe."
    return 1
  }
  [[ "$(stat -c '%U:%G:%a' /etc/containerd/config.toml 2>/dev/null)" == "root:root:644" ]] || {
    check_pending "permissões de /etc/containerd/config.toml estão incorretas."
    return 1
  }
  grep -Eq 'SystemdCgroup[[:space:]]*=[[:space:]]*true' /etc/containerd/config.toml || {
    check_pending "containerd não usa SystemdCgroup=true."
    return 1
  }
  if grep -Eq "^[[:space:]]*disabled_plugins[[:space:]]*=.*[\"']cri[\"']" /etc/containerd/config.toml; then
    check_pending "plugin CRI está desativado no containerd."
    return 1
  fi
  systemctl is-enabled --quiet containerd || {
    check_pending "containerd não está habilitado no boot."
    return 1
  }
  systemctl is-active --quiet containerd || {
    check_pending "containerd não está ativo."
    return 1
  }
  [[ -S /run/containerd/containerd.sock ]] || {
    check_pending "socket CRI do containerd não existe."
    return 1
  }
  ctr plugins ls 2>/dev/null | awk '
    tolower($NF) == "ok" && ($1 ~ /cri/ || $2 == "cri") {found=1}
    END {exit !found}
  ' || {
    check_pending "plugin CRI do containerd não está pronto."
    return 1
  }
}

if check_requested "${1:-}"; then
  if containerd_state_ok; then
    exit 0
  fi
  exit 1
fi

missing_packages=()
reinstall_packages=()
if ! command -v containerd >/dev/null 2>&1; then
  if package_is_installed containerd; then
    reinstall_packages+=(containerd)
  else
    missing_packages+=(containerd)
  fi
fi
if ! command -v runc >/dev/null 2>&1; then
  if package_is_installed runc; then
    reinstall_packages+=(runc)
  else
    missing_packages+=(runc)
  fi
fi
if (( ${#missing_packages[@]} > 0 || ${#reinstall_packages[@]} > 0 )); then
  apt-get update
  if (( ${#missing_packages[@]} > 0 )); then
    log "Instalando componentes ausentes: ${missing_packages[*]}."
    apt-get install -y --no-install-recommends "${missing_packages[@]}"
  fi
  if (( ${#reinstall_packages[@]} > 0 )); then
    log "Reinstalando componentes com binários ausentes: ${reinstall_packages[*]}."
    apt-get install -y --reinstall --no-install-recommends "${reinstall_packages[@]}"
  fi
fi

install -d -o root -g root -m 0755 /etc/containerd
temporary_config="$(mktemp)"
trap 'rm -f -- "${temporary_config}"' EXIT

config_changed=false
if [[ -s /etc/containerd/config.toml ]] \
  && ! grep -Eq "^[[:space:]]*disabled_plugins[[:space:]]*=.*[\"']cri[\"']" /etc/containerd/config.toml; then
  cp -- /etc/containerd/config.toml "${temporary_config}"
else
  containerd config default >"${temporary_config}"
fi

# Funciona nos layouts de configuração do containerd 1.x e 2.x.
sed -i -E 's/(SystemdCgroup[[:space:]]*=[[:space:]]*)false/\1true/g' "${temporary_config}"
grep -Eq 'SystemdCgroup[[:space:]]*=[[:space:]]*true' "${temporary_config}" \
  || die "a configuração gerada pelo containerd não contém SystemdCgroup=true."

if [[ ! -f /etc/containerd/config.toml ]] || ! cmp -s "${temporary_config}" /etc/containerd/config.toml; then
  ensure_state_dir
  install -d -o root -g root -m 0700 "${BOOTSTRAP_STATE_DIR}/backups"
  if [[ -f /etc/containerd/config.toml ]]; then
    cp --preserve=mode,timestamps /etc/containerd/config.toml \
      "${BOOTSTRAP_STATE_DIR}/backups/containerd-config.$(date '+%Y%m%d%H%M%S').toml"
  fi
  install -o root -g root -m 0644 "${temporary_config}" /etc/containerd/config.toml
  config_changed=true
fi
systemctl daemon-reload
systemctl enable --now containerd
if is_true "${config_changed}"; then
  systemctl restart containerd
fi
systemctl is-active --quiet containerd || die "containerd não iniciou."

containerd_state_ok || die "containerd foi configurado, mas o runtime CRI não está saudável."
log "containerd configurado com cgroup systemd: $(containerd --version)."
