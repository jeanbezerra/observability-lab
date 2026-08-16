#!/usr/bin/env bash

# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_root

KCADM_CONFIG="${KEYCLOAK_DATA_DIR}/.keycloak/kcadm.config"
REALM_STATE_FILE="${KEYCLOAK_STATE_DIR}/realm-configured.state"

kcadm() {
  runuser -u "${KEYCLOAK_USER}" -- "${KEYCLOAK_HOME}/bin/kcadm.sh" "$@" \
    --config "${KCADM_CONFIG}"
}

kcadm_login() {
  local username="$1" password="$2"
  install -d -o "${KEYCLOAK_USER}" -g "${KEYCLOAK_GROUP}" -m 0700 \
    "$(dirname -- "${KCADM_CONFIG}")"
  # O kcadm aceita a senha pelo stdin; assim ela não aparece na linha de
  # comando de um processo observável com ps.
  printf '%s\n' "${password}" \
    | kcadm config credentials --server "${KEYCLOAK_EXTERNAL_URL}" --realm master \
      --user "${username}" >/dev/null 2>&1
}

kcadm_admin_login() {
  local username="$1" password="$2"
  kcadm_login "${username}" "${password}" \
    && kcadm get realms --fields realm >/dev/null 2>&1
}

exact_user_id() {
  local realm="$1" username="$2"
  kcadm get users -r "${realm}" -q exact=true -q username="${username}" \
    --fields id,username 2>/dev/null \
    | jq -r --arg username "${username}" '.[] | select(.username == $username) | .id' \
    | head -n 1
}

exact_group_id() {
  local group_name="$1"
  kcadm get groups -r "${OIDC_REALM}" -q exact=true -q search="${group_name}" \
    2>/dev/null | jq -r --arg name "${group_name}" '.[] | select(.name == $name) | .id' \
    | head -n 1
}

client_uuid() {
  kcadm get clients -r "${OIDC_REALM}" -q clientId="${OIDC_CLIENT_ID}" \
    --fields id,clientId 2>/dev/null \
    | jq -r --arg client_id "${OIDC_CLIENT_ID}" '.[] | select(.clientId == $client_id) | .id' \
    | head -n 1
}

render_client_json() {
  jq -n \
    --arg client_id "${OIDC_CLIENT_ID}" \
    --arg client_secret "${OIDC_CLIENT_SECRET}" \
    --arg callback "${HEADLAMP_OIDC_CALLBACK_URL}" \
    --arg kubectl_callback "${KUBECTL_OIDC_REDIRECT_URI}" \
    --arg headlamp_origin "${HEADLAMP_EXTERNAL_URL%/}" \
    '{
      clientId: $client_id,
      name: "Kubernetes e Headlamp",
      description: "Cliente OIDC confidencial gerenciado pela automação do laboratório",
      enabled: true,
      protocol: "openid-connect",
      publicClient: false,
      clientAuthenticatorType: "client-secret",
      secret: $client_secret,
      standardFlowEnabled: true,
      implicitFlowEnabled: false,
      directAccessGrantsEnabled: false,
      serviceAccountsEnabled: false,
      frontchannelLogout: true,
      redirectUris: [$callback, $kubectl_callback],
      webOrigins: [$headlamp_origin],
      attributes: {
        "post.logout.redirect.uris": ($headlamp_origin + "/*"),
        "backchannel.logout.session.required": "true",
        "backchannel.logout.revoke.offline.tokens": "false",
        "oauth2.device.authorization.grant.enabled": "false"
      }
    }'
}

render_groups_mapper_json() {
  jq -n '{
    name: "groups",
    protocol: "openid-connect",
    protocolMapper: "oidc-group-membership-mapper",
    consentRequired: false,
    config: {
      "claim.name": "groups",
      "full.path": "false",
      "id.token.claim": "true",
      "access.token.claim": "true",
      "userinfo.token.claim": "true",
      "introspection.token.claim": "true"
    }
  }'
}

realm_state_ok() {
  local realm_json client_id client_json client_secret mapper_json group_id
  kcadm_admin_login "${KEYCLOAK_ADMIN_USER}" "${KEYCLOAK_ADMIN_PASSWORD}" || {
    check_pending "não foi possível autenticar a conta administrativa permanente."
    return 1
  }
  realm_json="$(kcadm get "realms/${OIDC_REALM}" 2>/dev/null)" || {
    check_pending "realm ${OIDC_REALM} não existe."
    return 1
  }
  jq -e \
    --arg display_name "${OIDC_REALM_DISPLAY_NAME}" \
    '.enabled == true
      and .displayName == $display_name
      and .sslRequired == "external"
      and .registrationAllowed == false
      and .bruteForceProtected == true
      and .accessTokenLifespan == 300' <<<"${realm_json}" >/dev/null || {
        check_pending "parâmetros de segurança do realm diferem do desejado."
        return 1
      }
  for group_name in "${OIDC_VIEWER_GROUP}" "${OIDC_ADMIN_GROUP}"; do
    group_id="$(exact_group_id "${group_name}")"
    [[ -n "${group_id}" ]] || {
      check_pending "grupo ${group_name} não existe no realm."
      return 1
    }
  done
  client_id="$(client_uuid)"
  [[ -n "${client_id}" ]] || {
    check_pending "cliente OIDC ${OIDC_CLIENT_ID} não existe."
    return 1
  }
  client_json="$(kcadm get "clients/${client_id}" -r "${OIDC_REALM}" 2>/dev/null)"
  jq -e \
    --arg callback "${HEADLAMP_OIDC_CALLBACK_URL}" \
    --arg kubectl_callback "${KUBECTL_OIDC_REDIRECT_URI}" \
    --arg origin "${HEADLAMP_EXTERNAL_URL%/}" \
    '.enabled == true
      and .publicClient == false
      and .standardFlowEnabled == true
      and .implicitFlowEnabled == false
      and .directAccessGrantsEnabled == false
      and (.redirectUris | index($callback) != null)
      and (.redirectUris | index($kubectl_callback) != null)
      and (.webOrigins | index($origin) != null)' <<<"${client_json}" >/dev/null || {
        check_pending "cliente OIDC difere do fluxo confidencial/redirects esperados."
        return 1
      }
  client_secret="$(kcadm get "clients/${client_id}/client-secret" -r "${OIDC_REALM}" 2>/dev/null \
    | jq -r '.value // empty')"
  [[ "${client_secret}" == "${OIDC_CLIENT_SECRET}" ]] || {
    check_pending "secret do cliente OIDC precisa ser reconciliado."
    return 1
  }
  mapper_json="$(kcadm get "clients/${client_id}/protocol-mappers/models" \
    -r "${OIDC_REALM}" 2>/dev/null \
    | jq -c '.[] | select(.name == "groups" and .protocolMapper == "oidc-group-membership-mapper")' \
    | head -n 1)"
  [[ -n "${mapper_json}" ]] \
    && jq -e '.config["claim.name"] == "groups"
      and .config["full.path"] == "false"
      and .config["id.token.claim"] == "true"
      and .config["access.token.claim"] == "true"' <<<"${mapper_json}" >/dev/null || {
        check_pending "mapper OIDC de grupos está ausente ou incorreto."
        return 1
      }
  [[ -r "${REALM_STATE_FILE}" \
    && "$(<"${REALM_STATE_FILE}")" == "$(desired_state_fingerprint)" ]] || {
      check_pending "marcador da reconciliação do realm está desatualizado."
      return 1
    }
}

if check_requested "${1:-}"; then
  realm_state_ok
  exit $?
fi

require_command jq
systemctl is-active --quiet keycloak || die "Keycloak precisa estar ativo antes de configurar o realm."

authenticated_as=""
if kcadm_admin_login "${KEYCLOAK_ADMIN_USER}" "${KEYCLOAK_ADMIN_PASSWORD}"; then
  authenticated_as="permanent"
elif kcadm_login "${KEYCLOAK_BOOTSTRAP_USER}" "${KEYCLOAK_BOOTSTRAP_PASSWORD}"; then
  authenticated_as="bootstrap"
elif [[ -e "${REALM_STATE_FILE}" ]]; then
  die "a conta administrativa permanente não autenticou. O instalador não criará uma conta de recuperação em uma instância já configurada; valide a senha ou siga o procedimento oficial de recuperação."
else
  warn "Nenhuma conta de automação autenticou; criando uma conta bootstrap temporária com o serviço parado."
  systemctl stop keycloak
  if ! runuser -u "${KEYCLOAK_USER}" -- env \
    "PASS_VAR=${KEYCLOAK_BOOTSTRAP_PASSWORD}" \
    "KCRAW_DB_PASSWORD=${KEYCLOAK_DB_PASSWORD}" \
    "${KEYCLOAK_HOME}/bin/kc.sh" bootstrap-admin user \
      --username "${KEYCLOAK_BOOTSTRAP_USER}" --password:env PASS_VAR \
      --no-prompt --optimized; then
    systemctl start keycloak
    die "não foi possível criar a conta bootstrap temporária."
  fi
  systemctl start keycloak
  retry 60 5 curl -fsS --connect-timeout 3 --max-time 10 \
    http://127.0.0.1:9000/health/ready -o /dev/null \
    || die "Keycloak não voltou após o bootstrap administrativo."
  kcadm_login "${KEYCLOAK_BOOTSTRAP_USER}" "${KEYCLOAK_BOOTSTRAP_PASSWORD}" \
    || die "a conta bootstrap foi criada, mas não autenticou."
  authenticated_as="bootstrap"
fi

if [[ "${authenticated_as}" == "bootstrap" ]]; then
  log "Criando/reconciliando a conta administrativa permanente no realm master."
  permanent_id="$(exact_user_id master "${KEYCLOAK_ADMIN_USER}")"
  if [[ -z "${permanent_id}" ]]; then
    kcadm create users -r master -s username="${KEYCLOAK_ADMIN_USER}" -s enabled=true >/dev/null
    permanent_id="$(exact_user_id master "${KEYCLOAK_ADMIN_USER}")"
  else
    kcadm update "users/${permanent_id}" -r master -s enabled=true >/dev/null
  fi
  kcadm set-password -r master --username "${KEYCLOAK_ADMIN_USER}" \
    --new-password "${KEYCLOAK_ADMIN_PASSWORD}" >/dev/null
  kcadm add-roles -r master --uusername "${KEYCLOAK_ADMIN_USER}" --rolename admin >/dev/null
  kcadm_admin_login "${KEYCLOAK_ADMIN_USER}" "${KEYCLOAK_ADMIN_PASSWORD}" \
    || die "a conta permanente foi criada, mas não recebeu acesso administrativo."
  bootstrap_id="$(exact_user_id master "${KEYCLOAK_BOOTSTRAP_USER}")"
  if [[ -n "${bootstrap_id}" ]]; then
    warn "Removendo a conta bootstrap temporária após validar a conta permanente."
    kcadm delete "users/${bootstrap_id}" -r master >/dev/null
  fi
fi

log "Reconciliando realm ${OIDC_REALM} com TLS e proteção contra força bruta."
if ! kcadm get "realms/${OIDC_REALM}" >/dev/null 2>&1; then
  kcadm create realms -s realm="${OIDC_REALM}" -s enabled=true >/dev/null
fi
kcadm update "realms/${OIDC_REALM}" \
  -s enabled=true \
  -s displayName="${OIDC_REALM_DISPLAY_NAME}" \
  -s sslRequired=external \
  -s registrationAllowed=false \
  -s resetPasswordAllowed=true \
  -s rememberMe=true \
  -s loginWithEmailAllowed=true \
  -s duplicateEmailsAllowed=false \
  -s bruteForceProtected=true \
  -s permanentLockout=false \
  -s failureFactor=5 \
  -s waitIncrementSeconds=60 \
  -s maxFailureWaitSeconds=900 \
  -s maxDeltaTimeSeconds=43200 \
  -s accessTokenLifespan=300 \
  -s ssoSessionIdleTimeout=1800 \
  -s ssoSessionMaxLifespan=36000 >/dev/null

for group_name in "${OIDC_VIEWER_GROUP}" "${OIDC_ADMIN_GROUP}"; do
  if [[ -z "$(exact_group_id "${group_name}")" ]]; then
    kcadm create groups -r "${OIDC_REALM}" -s name="${group_name}" >/dev/null
  fi
done

client_file="$(mktemp)"
mapper_file="$(mktemp)"
cleanup_files() {
  rm -f -- "${client_file}" "${mapper_file}"
}
trap cleanup_files EXIT
render_client_json >"${client_file}"
render_groups_mapper_json >"${mapper_file}"

client_id="$(client_uuid)"
if [[ -z "${client_id}" ]]; then
  kcadm create clients -r "${OIDC_REALM}" -f "${client_file}" >/dev/null
  client_id="$(client_uuid)"
  [[ -n "${client_id}" ]] || die "cliente ${OIDC_CLIENT_ID} não foi criado."
else
  kcadm update "clients/${client_id}" -r "${OIDC_REALM}" -f "${client_file}" >/dev/null
fi

mapper_id="$(kcadm get "clients/${client_id}/protocol-mappers/models" \
  -r "${OIDC_REALM}" 2>/dev/null \
  | jq -r '.[] | select(.name == "groups" and .protocolMapper == "oidc-group-membership-mapper") | .id' \
  | head -n 1)"
if [[ -z "${mapper_id}" ]]; then
  kcadm create "clients/${client_id}/protocol-mappers/models" \
    -r "${OIDC_REALM}" -f "${mapper_file}" >/dev/null
else
  kcadm update "clients/${client_id}/protocol-mappers/models/${mapper_id}" \
    -r "${OIDC_REALM}" -f "${mapper_file}" >/dev/null
fi

ensure_state_dir
printf '%s\n' "$(desired_state_fingerprint)" >"${REALM_STATE_FILE}"
chmod 0600 "${REALM_STATE_FILE}"

realm_state_ok || die "realm e cliente foram reconciliados, mas a verificação falhou."
log "OIDC pronto: issuer ${OIDC_ISSUER_URL}; grupos ${OIDC_VIEWER_GROUP} e ${OIDC_ADMIN_GROUP}."
