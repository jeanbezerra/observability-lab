#!/usr/bin/env bash

set -Eeuo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  printf 'ERRO: execute dentro do Ubuntu WSL: sudo bash %s\n' "$0" >&2
  exit 1
fi

if ! grep -Eqi 'microsoft-standard-WSL2|WSL2' /proc/sys/kernel/osrelease /proc/version 2>/dev/null; then
  printf 'ERRO: este preparador deve ser executado dentro de uma distribuição WSL 2.\n' >&2
  exit 1
fi

source /etc/os-release
if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "26.04" ]]; then
  printf 'ERRO: esperado Ubuntu 26.04 no WSL 2; detectado: %s.\n' "${PRETTY_NAME:-desconhecido}" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
missing_packages=()
for package_name in systemd systemd-sysv; do
  dpkg-query -W -f='${Status}' "${package_name}" 2>/dev/null | grep -Fq 'ok installed' \
    || missing_packages+=("${package_name}")
done
if (( ${#missing_packages[@]} > 0 )); then
  apt-get update
  apt-get install -y --no-install-recommends "${missing_packages[@]}"
fi

wsl_conf=/etc/wsl.conf
temporary_conf="$(mktemp)"
trap 'rm -f -- "${temporary_conf}"' EXIT

if [[ -r "${wsl_conf}" ]]; then
  awk '
    BEGIN { in_boot=0; saw_boot=0; wrote_systemd=0 }
    /^\[boot\][[:space:]]*$/ {
      if (in_boot && !wrote_systemd) print "systemd=true"
      in_boot=1
      saw_boot=1
      wrote_systemd=0
      print
      next
    }
    /^\[[^]]+\][[:space:]]*$/ {
      if (in_boot && !wrote_systemd) print "systemd=true"
      in_boot=0
      print
      next
    }
    in_boot && /^[[:space:]]*systemd[[:space:]]*=/ {
      if (!wrote_systemd) print "systemd=true"
      wrote_systemd=1
      next
    }
    { print }
    END {
      if (in_boot && !wrote_systemd) print "systemd=true"
      if (!saw_boot) {
        print ""
        print "[boot]"
        print "systemd=true"
      }
    }
  ' "${wsl_conf}" >"${temporary_conf}"
else
  printf '[boot]\nsystemd=true\n' >"${temporary_conf}"
fi

if [[ ! -f "${wsl_conf}" ]] || ! cmp -s "${temporary_conf}" "${wsl_conf}"; then
  if [[ -f "${wsl_conf}" && ! -e "${wsl_conf}.pre-kubernetes-wsl" ]]; then
    cp --preserve=mode,timestamps "${wsl_conf}" "${wsl_conf}.pre-kubernetes-wsl"
  fi
  install -o root -g root -m 0644 "${temporary_conf}" "${wsl_conf}"
  printf 'systemd foi habilitado em /etc/wsl.conf.\n'
fi

if [[ "$(ps -p 1 -o comm= 2>/dev/null | tr -d '[:space:]')" == "systemd" ]]; then
  printf 'WSL 2 já está usando systemd; você pode executar install-all.sh.\n'
else
  cat <<'EOF'

Preparação concluída. Feche esta janela e, no Prompt de Comando (CMD) do Windows,
execute o comando abaixo. Ele não precisa de PowerShell:

  wsl.exe --terminate Ubuntu-26.04

Abra novamente o Ubuntu 26.04 e confirme com:

  systemctl is-system-running

Depois execute o instalador.
EOF
fi
