#!/usr/bin/env bash

# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_root

auth_dir="/etc/kubernetes/pki/oidc"
auth_config="${auth_dir}/authentication-config.yaml"
installed_ca="${auth_dir}/keycloak-ca.crt"
apiserver_manifest="/etc/kubernetes/manifests/kube-apiserver.yaml"
auth_flag="--authentication-config=${auth_config}"
state_file="${BOOTSTRAP_STATE_DIR}/oidc.fingerprint"

render_authentication_config() {
  cat <<EOF
apiVersion: apiserver.config.k8s.io/v1
kind: AuthenticationConfiguration
jwt:
  - issuer:
      url: ${OIDC_ISSUER_URL}
      audiences:
        - ${OIDC_CLIENT_ID}
EOF
  if [[ -s "${installed_ca}" ]]; then
    printf '      certificateAuthority: |\n'
    sed 's/^/        /' "${installed_ca}"
  fi
  cat <<EOF
    claimMappings:
      username:
        claim: preferred_username
        prefix: "${OIDC_USERNAME_PREFIX}"
      groups:
        claim: groups
        prefix: "${OIDC_GROUPS_PREFIX}"
      uid:
        claim: sub
    userValidationRules:
      - expression: "!user.username.startsWith('system:')"
        message: "username não pode usar o prefixo reservado system:"
      - expression: "user.groups.all(group, !group.startsWith('system:'))"
        message: "grupos não podem usar o prefixo reservado system:"
EOF
}

oidc_fingerprint() {
  {
    render_authentication_config
    printf 'client_secret_sha256=%s\n' \
      "$(printf '%s' "${HEADLAMP_OIDC_CLIENT_SECRET}" | sha256sum | awk '{print $1}')"
  } | sha256sum | awk '{print $1}'
}

api_ready() {
  kube --request-timeout=5s get --raw=/readyz >/dev/null 2>&1
}

issuer_reachable() {
  local curl_args discovery
  curl_args=(--fail --silent --show-error --connect-timeout 5 --max-time 20)
  [[ -z "${OIDC_CA_FILE}" ]] || curl_args+=(--cacert "${OIDC_CA_FILE}")
  discovery="$(curl "${curl_args[@]}" \
    "${OIDC_ISSUER_URL}/.well-known/openid-configuration" 2>/dev/null)" || return 1
  jq -e --arg issuer "${OIDC_ISSUER_URL}" \
    '.issuer == $issuer and (.jwks_uri | startswith($issuer))' <<<"${discovery}" >/dev/null
}

oidc_state_ok() {
  if ! is_true "${ENABLE_OIDC}"; then
    if [[ -e "${state_file}" ]] || grep -Fq -- "${auth_flag}" "${apiserver_manifest}" 2>/dev/null; then
      warn "ENABLE_OIDC=false, mas uma configuração OIDC gerenciada já existe; ela foi preservada para não interromper usuários."
    fi
    return 0
  fi
  [[ -r "${apiserver_manifest}" ]] || {
    check_pending "manifesto estático do kube-apiserver não existe."
    return 1
  }
  if grep -Eq -- '^[[:space:]]*-[[:space:]]+--oidc-' "${apiserver_manifest}"; then
    check_pending "o kube-apiserver ainda possui flags --oidc-* incompatíveis com AuthenticationConfiguration."
    return 1
  fi
  grep -Fqx -- "    - ${auth_flag}" "${apiserver_manifest}" || {
    check_pending "kube-apiserver não referencia ${auth_config}."
    return 1
  }
  [[ "$(grep -Ec -- '^[[:space:]]*-[[:space:]]+--authentication-config=' "${apiserver_manifest}")" == "1" ]] || {
    check_pending "kube-apiserver possui zero ou múltiplos --authentication-config."
    return 1
  }
  [[ -r "${auth_config}" ]] && cmp -s <(render_authentication_config) "${auth_config}" || {
    check_pending "AuthenticationConfiguration está ausente ou divergente."
    return 1
  }
  if [[ -n "${OIDC_CA_FILE}" ]]; then
    [[ -r "${installed_ca}" ]] && cmp -s "${OIDC_CA_FILE}" "${installed_ca}" || {
      check_pending "CA privada do Keycloak está ausente ou desatualizada no control plane."
      return 1
    }
  elif [[ -e "${installed_ca}" ]]; then
    check_pending "há uma CA OIDC gerenciada, mas OIDC_CA_FILE está vazio."
    return 1
  fi
  issuer_reachable || {
    check_pending "issuer OIDC/discovery não está acessível a partir do control plane."
    return 1
  }
  api_ready || {
    check_pending "API Server não está pronto após a configuração OIDC."
    return 1
  }
  [[ -r "${state_file}" && "$(<"${state_file}")" == "$(oidc_fingerprint)" ]] || {
    check_pending "fingerprint OIDC está ausente ou desatualizado."
    return 1
  }
}

if check_requested "${1:-}"; then
  oidc_state_ok
  exit $?
fi

if ! is_true "${ENABLE_OIDC}"; then
  if [[ -e "${state_file}" ]] || grep -Fq -- "${auth_flag}" "${apiserver_manifest}" 2>/dev/null; then
    warn "OIDC gerenciado já existe e foi preservado. A remoção exige um procedimento explícito para não bloquear todos os usuários federados."
  else
    log "ENABLE_OIDC=false; integração do API Server não solicitada."
  fi
  exit 0
fi

require_command curl
require_command jq
require_command sha256sum
[[ -r "${apiserver_manifest}" ]] \
  || die "manifesto estático do kube-apiserver não encontrado: ${apiserver_manifest}."
if grep -Eq -- '^[[:space:]]*-[[:space:]]+--oidc-' "${apiserver_manifest}"; then
  die "foram encontradas flags --oidc-* no kube-apiserver. Migre/remova essas flags antes de usar --authentication-config; as duas formas juntas impedem a API de iniciar."
fi
existing_auth_flags="$(grep -E -- '^[[:space:]]*-[[:space:]]+--authentication-config=' \
  "${apiserver_manifest}" || true)"
if [[ -n "${existing_auth_flags}" && "${existing_auth_flags}" != "    - ${auth_flag}" ]]; then
  die "o kube-apiserver já usa outro --authentication-config; ele não será substituído automaticamente: ${existing_auth_flags}."
fi

issuer_reachable \
  || die "não foi possível validar ${OIDC_ISSUER_URL}/.well-known/openid-configuration a partir do control plane. Verifique DNS, rota, firewall e CA."

backup_dir="${BOOTSTRAP_STATE_DIR}/backups"
backup_stamp="$(date '+%Y%m%d%H%M%S')"
backup_config=""
backup_ca=""
install -d -o root -g root -m 0700 "${backup_dir}"
if [[ -r "${auth_config}" ]]; then
  backup_config="${backup_dir}/authentication-config.pre-oidc.${backup_stamp}.yaml"
  install -o root -g root -m 0600 "${auth_config}" "${backup_config}"
fi
if [[ -r "${installed_ca}" ]]; then
  backup_ca="${backup_dir}/keycloak-ca.pre-oidc.${backup_stamp}.crt"
  install -o root -g root -m 0600 "${installed_ca}" "${backup_ca}"
fi

install -d -o root -g root -m 0755 "${auth_dir}"
if [[ -n "${OIDC_CA_FILE}" ]]; then
  install -o root -g root -m 0644 "${OIDC_CA_FILE}" "${installed_ca}"
else
  rm -f -- "${installed_ca}"
fi

temporary_config="$(mktemp "${auth_dir}/.authentication-config.XXXXXX")"
render_authentication_config >"${temporary_config}"
chown root:root "${temporary_config}"
chmod 0644 "${temporary_config}"
mv -f -- "${temporary_config}" "${auth_config}"

manifest_changed=false
backup_manifest=""
if [[ -z "${existing_auth_flags}" ]]; then
  backup_manifest="${backup_dir}/kube-apiserver.pre-oidc.${backup_stamp}.yaml"
  install -o root -g root -m 0600 "${apiserver_manifest}" "${backup_manifest}"
  temporary_manifest="$(mktemp "$(dirname -- "${apiserver_manifest}")/.kube-apiserver.XXXXXX")"
  if ! awk -v flag="${auth_flag}" '
      { print }
      /^[[:space:]]*- kube-apiserver[[:space:]]*$/ {
        print "    - " flag
        added=1
      }
      END { if (!added) exit 42 }
    ' "${apiserver_manifest}" >"${temporary_manifest}"; then
    rm -f -- "${temporary_manifest}"
    die "não foi possível localizar o comando kube-apiserver no manifesto estático."
  fi
  chown root:root "${temporary_manifest}"
  chmod 0600 "${temporary_manifest}"
  mv -f -- "${temporary_manifest}" "${apiserver_manifest}"
  manifest_changed=true
  log "Manifesto do kube-apiserver atualizado; aguardando a reinicialização do Pod estático."
fi

if ! retry 60 5 api_ready; then
  warn "API Server não ficou pronto; restaurando a configuração OIDC anterior."
  if [[ -n "${backup_config}" && -r "${backup_config}" ]]; then
    install -o root -g root -m 0644 "${backup_config}" "${auth_config}"
  else
    rm -f -- "${auth_config}"
  fi
  if [[ -n "${backup_ca}" && -r "${backup_ca}" ]]; then
    install -o root -g root -m 0644 "${backup_ca}" "${installed_ca}"
  else
    rm -f -- "${installed_ca}"
  fi
  if is_true "${manifest_changed}" && [[ -r "${backup_manifest}" ]]; then
    install -o root -g root -m 0600 "${backup_manifest}" "${apiserver_manifest}"
  fi
  retry 60 5 api_ready \
    || die "o rollback OIDC foi aplicado, mas a API ainda não voltou; inspecione kubelet e os containers do kube-apiserver."
  die "a configuração OIDC foi revertida porque o kube-apiserver não ficou pronto."
fi

ensure_state_dir
printf '%s\n' "$(oidc_fingerprint)" >"${state_file}"
chmod 0600 "${state_file}"

oidc_state_ok || die "OIDC foi aplicado ao API Server, mas a verificação final falhou."
log "API Server autenticando tokens emitidos por ${OIDC_ISSUER_URL}."
