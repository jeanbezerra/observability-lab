#!/usr/bin/env bash

# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_root
require_command hostname
require_command hostnamectl
require_command timedatectl

wsl_conf="/etc/wsl.conf"
hosts_file="/etc/hosts"
profile_file="/etc/profile.d/k8s-wsl-no-proxy.sh"
containerd_dropin="/etc/systemd/system/containerd.service.d/20-k8s-wsl-no-proxy.conf"
kubelet_dropin="/etc/systemd/system/kubelet.service.d/20-k8s-wsl-no-proxy.conf"

render_profile() {
  cat <<'EOF'
# Gerenciado por kubernetes-wsl. Preserve os destinos locais fora do proxy.
EOF
  printf 'export NO_PROXY=%q\n' "${K8S_NO_PROXY}"
  printf 'export no_proxy=%q\n' "${K8S_NO_PROXY}"
}

render_systemd_dropin() {
  local escaped_no_proxy
  escaped_no_proxy="$(systemd_escape_environment_value "${K8S_NO_PROXY}")"
  cat <<EOF
[Service]
Environment="NO_PROXY=${escaped_no_proxy}"
Environment="no_proxy=${escaped_no_proxy}"
EOF
}

render_wsl_conf() {
  if [[ ! -r "${wsl_conf}" ]]; then
    printf '[network]\nhostname=%s\n' "${NODE_NAME}"
    return
  fi

  awk -v desired_hostname="${NODE_NAME}" '
    BEGIN {
      in_network = 0
      saw_network = 0
      wrote_hostname = 0
    }
    /^\[[^]]+\][[:space:]]*$/ {
      if (in_network && !wrote_hostname) print "hostname=" desired_hostname
      in_network = (tolower($0) ~ /^\[network\][[:space:]]*$/)
      if (in_network) {
        saw_network = 1
        wrote_hostname = 0
      }
      print
      next
    }
    in_network && tolower($0) ~ /^[[:space:]]*hostname[[:space:]]*=/ {
      if (!wrote_hostname) print "hostname=" desired_hostname
      wrote_hostname = 1
      next
    }
    { print }
    END {
      if (in_network && !wrote_hostname) print "hostname=" desired_hostname
      if (!saw_network) {
        print ""
        print "[network]"
        print "hostname=" desired_hostname
      }
    }
  ' "${wsl_conf}"
}

render_hosts() {
  awk -v desired_hostname="${NODE_NAME}" '
    BEGIN { wrote_hostname = 0 }
    $1 == "127.0.1.1" {
      if (!wrote_hostname) {
        printf "127.0.1.1\t%s", desired_hostname
        for (field = 2; field <= NF; field++) {
          if ($field != desired_hostname) printf "\t%s", $field
        }
        print ""
      }
      wrote_hostname = 1
      next
    }
    { print }
    END {
      if (!wrote_hostname) print "127.0.1.1\t" desired_hostname
    }
  ' "${hosts_file}"
}

wsl_hostname_is_correct() {
  [[ -r "${wsl_conf}" ]] || return 1
  awk -v desired_hostname="${NODE_NAME}" '
    BEGIN { in_network = 0; found = 0; invalid = 0 }
    /^\[[^]]+\][[:space:]]*$/ {
      in_network = (tolower($0) ~ /^\[network\][[:space:]]*$/)
      next
    }
    in_network && tolower($0) ~ /^[[:space:]]*hostname[[:space:]]*=/ {
      value = $0
      sub(/^[^=]*=[[:space:]]*/, "", value)
      sub(/[[:space:]]*$/, "", value)
      found = 1
      if (value != desired_hostname) invalid = 1
    }
    END { exit !(found && !invalid) }
  ' "${wsl_conf}"
}

standard_state_ok() {
  [[ "$(hostnamectl --static 2>/dev/null || true)" == "${NODE_NAME}" ]] || {
    check_pending "hostname Linux difere de NODE_NAME=${NODE_NAME}."
    return 1
  }
  [[ "$(hostname 2>/dev/null || true)" == "${NODE_NAME}" ]] || {
    check_pending "hostname ativo ainda não é ${NODE_NAME}."
    return 1
  }
  wsl_hostname_is_correct || {
    check_pending "hostname persistente do WSL está ausente ou divergente."
    return 1
  }
  awk -v desired_hostname="${NODE_NAME}" '
    $1 == "127.0.1.1" {
      for (field = 2; field <= NF; field++) {
        if ($field == desired_hostname) found = 1
      }
    }
    END { exit !found }
  ' "${hosts_file}" || {
    check_pending "resolução local do hostname ${NODE_NAME} está ausente em /etc/hosts."
    return 1
  }
  [[ "$(timedatectl show --property=Timezone --value 2>/dev/null || true)" == "${SYSTEM_TIMEZONE}" ]] || {
    check_pending "timezone do sistema difere de ${SYSTEM_TIMEZONE}."
    return 1
  }
  if [[ ! -r "${profile_file}" ]] || ! cmp -s <(render_profile) "${profile_file}"; then
    check_pending "NO_PROXY do ambiente interativo está ausente ou desatualizado."
    return 1
  fi
  if [[ ! -r "${containerd_dropin}" ]] || ! cmp -s <(render_systemd_dropin) "${containerd_dropin}"; then
    check_pending "NO_PROXY do containerd está ausente ou desatualizado."
    return 1
  fi
  if [[ ! -r "${kubelet_dropin}" ]] || ! cmp -s <(render_systemd_dropin) "${kubelet_dropin}"; then
    check_pending "NO_PROXY do kubelet está ausente ou desatualizado."
    return 1
  fi
}

if check_requested "${1:-}"; then
  if standard_state_ok; then
    exit 0
  fi
  exit 1
fi

[[ -e "/usr/share/zoneinfo/${SYSTEM_TIMEZONE}" ]] \
  || die "timezone inválido ou indisponível: ${SYSTEM_TIMEZONE}."
[[ "${K8S_NO_PROXY}" != *$'\n'* && "${K8S_NO_PROXY}" != *$'\r'* ]] \
  || die "NO_PROXY contém quebra de linha e não pode ser persistido com segurança."

log "Padronizando Linux: hostname=$(hostname 2>/dev/null || printf desconhecido)->${NODE_NAME}, timezone=$(timedatectl show --property=Timezone --value 2>/dev/null || printf desconhecido)->${SYSTEM_TIMEZONE}."
log "Bypass de proxy efetivo: ${K8S_NO_PROXY}."

temporary_wsl_conf="$(mktemp)"
temporary_hosts="$(mktemp)"
temporary_profile="$(mktemp)"
temporary_dropin="$(mktemp)"
trap 'rm -f -- "${temporary_wsl_conf}" "${temporary_hosts}" "${temporary_profile}" "${temporary_dropin}"' EXIT

render_wsl_conf >"${temporary_wsl_conf}"
render_hosts >"${temporary_hosts}"
render_profile >"${temporary_profile}"
render_systemd_dropin >"${temporary_dropin}"

if [[ ! -f "${wsl_conf}" ]] || ! cmp -s "${temporary_wsl_conf}" "${wsl_conf}"; then
  if [[ -f "${wsl_conf}" && ! -e "${wsl_conf}.pre-kubernetes-wsl" ]]; then
    cp --preserve=mode,timestamps -- "${wsl_conf}" "${wsl_conf}.pre-kubernetes-wsl"
  fi
  install -o root -g root -m 0644 "${temporary_wsl_conf}" "${wsl_conf}"
fi

if [[ ! -r "${hosts_file}" ]] || ! cmp -s "${temporary_hosts}" "${hosts_file}"; then
  install -o root -g root -m 0644 "${temporary_hosts}" "${hosts_file}"
fi

hostnamectl set-hostname "${NODE_NAME}"
timedatectl set-timezone "${SYSTEM_TIMEZONE}"

install -d -o root -g root -m 0755 \
  "$(dirname -- "${profile_file}")" \
  "$(dirname -- "${containerd_dropin}")" \
  "$(dirname -- "${kubelet_dropin}")"

environment_changed=false
for destination in "${profile_file}" "${containerd_dropin}" "${kubelet_dropin}"; do
  source_file="${temporary_profile}"
  [[ "${destination}" == "${profile_file}" ]] || source_file="${temporary_dropin}"
  if [[ ! -r "${destination}" ]] || ! cmp -s "${source_file}" "${destination}"; then
    install -o root -g root -m 0644 "${source_file}" "${destination}"
    environment_changed=true
  fi
done

systemctl daemon-reload
if is_true "${environment_changed}"; then
  for service_name in containerd.service kubelet.service; do
    if systemctl is-active --quiet "${service_name}"; then
      systemctl restart "${service_name}"
    fi
  done
fi

standard_state_ok \
  || die "a padronização do sistema terminou, mas o estado esperado não foi atingido."
log "Sistema padronizado: hostname=${NODE_NAME}, timezone=${SYSTEM_TIMEZONE} e NO_PROXY local persistente."
