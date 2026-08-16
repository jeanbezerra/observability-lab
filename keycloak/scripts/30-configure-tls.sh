#!/usr/bin/env bash

# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_root

tls_sans() {
  printf 'DNS:%s,DNS:localhost,IP:127.0.0.1' "${KEYCLOAK_HOSTNAME}"
  [[ -z "${KEYCLOAK_SERVER_IP}" ]] || printf ',IP:%s' "${KEYCLOAK_SERVER_IP}"
}

certificate_key_match() {
  local cert_pub key_pub
  cert_pub="$(openssl x509 -in "${KEYCLOAK_TLS_DIR}/tls.crt" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
  key_pub="$(openssl pkey -in "${KEYCLOAK_TLS_DIR}/tls.key" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
  [[ -n "${cert_pub}" && "${cert_pub}" == "${key_pub}" ]]
}

ca_certificate_key_match() {
  local cert_pub key_pub
  cert_pub="$(openssl x509 -in "${KEYCLOAK_TLS_DIR}/ca.crt" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
  key_pub="$(openssl pkey -in "${KEYCLOAK_TLS_DIR}/ca.key" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
  [[ -n "${cert_pub}" && "${cert_pub}" == "${key_pub}" ]]
}

tls_state_ok() {
  [[ -s "${KEYCLOAK_TLS_DIR}/tls.crt" && -s "${KEYCLOAK_TLS_DIR}/tls.key" \
    && -s "${KEYCLOAK_TLS_DIR}/ca.crt" && -s "${KEYCLOAK_TLS_DIR}/server.sans" ]] || {
    check_pending "material TLS está incompleto."
    return 1
  }
  [[ "$(stat -c '%U:%G:%a' "${KEYCLOAK_TLS_DIR}/tls.key")" == "root:${KEYCLOAK_GROUP}:640" ]] || {
    check_pending "permissões da chave TLS estão incorretas."
    return 1
  }
  openssl x509 -checkend 2592000 -noout -in "${KEYCLOAK_TLS_DIR}/tls.crt" >/dev/null 2>&1 || {
    check_pending "certificado TLS está vencido ou expira em menos de 30 dias."
    return 1
  }
  openssl verify -CAfile "${KEYCLOAK_TLS_DIR}/ca.crt" "${KEYCLOAK_TLS_DIR}/tls.crt" >/dev/null 2>&1 || {
    check_pending "certificado TLS não é validado pela CA configurada."
    return 1
  }
  openssl x509 -in "${KEYCLOAK_TLS_DIR}/tls.crt" -noout -checkhost "${KEYCLOAK_HOSTNAME}" >/dev/null 2>&1 || {
    check_pending "certificado TLS não cobre ${KEYCLOAK_HOSTNAME}."
    return 1
  }
  certificate_key_match || {
    check_pending "certificado e chave TLS não formam um par."
    return 1
  }
  if [[ "${TLS_MODE}" == "provided" ]]; then
    cmp -s "${TLS_CERT_FILE}" "${KEYCLOAK_TLS_DIR}/tls.crt" \
      && cmp -s "${TLS_KEY_FILE}" "${KEYCLOAK_TLS_DIR}/tls.key" \
      && cmp -s "${TLS_CA_FILE}" "${KEYCLOAK_TLS_DIR}/ca.crt" || {
        check_pending "material TLS fornecido foi alterado e precisa ser reinstalado."
        return 1
      }
  fi
  if [[ "${TLS_MODE}" == "self-signed" ]]; then
    [[ -s "${KEYCLOAK_TLS_DIR}/ca.key" ]] && ca_certificate_key_match || {
      check_pending "a chave da CA privada está ausente ou não corresponde ao certificado."
      return 1
    }
    [[ "$(<"${KEYCLOAK_TLS_DIR}/server.sans")" == "$(tls_sans)" ]] || {
      check_pending "SANs desejados do certificado privado mudaram."
      return 1
    }
  fi
}

if check_requested "${1:-}"; then
  tls_state_ok
  exit $?
fi

require_command openssl
install -d -o root -g "${KEYCLOAK_GROUP}" -m 0750 "${KEYCLOAK_TLS_DIR}"

if [[ "${TLS_MODE}" == "provided" ]]; then
  log "Instalando certificado TLS fornecido pelo administrador."
  install -o root -g "${KEYCLOAK_GROUP}" -m 0640 "${TLS_KEY_FILE}" "${KEYCLOAK_TLS_DIR}/tls.key"
  install -o root -g "${KEYCLOAK_GROUP}" -m 0644 "${TLS_CERT_FILE}" "${KEYCLOAK_TLS_DIR}/tls.crt"
  install -o root -g "${KEYCLOAK_GROUP}" -m 0644 "${TLS_CA_FILE}" "${KEYCLOAK_TLS_DIR}/ca.crt"
  printf 'provided:%s\n' "${KEYCLOAK_HOSTNAME}" >"${KEYCLOAK_TLS_DIR}/server.sans"
else
  desired_sans="$(tls_sans)"
  regenerate=false
  if [[ ! -e "${KEYCLOAK_TLS_DIR}/ca.crt" && ! -e "${KEYCLOAK_TLS_DIR}/ca.key" ]]; then
    log "Criando CA privada local do Keycloak."
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out "${KEYCLOAK_TLS_DIR}/ca.key"
    openssl req -x509 -new -sha256 -key "${KEYCLOAK_TLS_DIR}/ca.key" \
      -out "${KEYCLOAK_TLS_DIR}/ca.crt" -days 3650 -subj "/CN=keycloak-local-ca" \
      -addext 'basicConstraints=critical,CA:TRUE,pathlen:0' \
      -addext 'keyUsage=critical,keyCertSign,cRLSign'
    regenerate=true
  elif [[ ! -s "${KEYCLOAK_TLS_DIR}/ca.crt" || ! -s "${KEYCLOAK_TLS_DIR}/ca.key" ]]; then
    die "a CA privada está incompleta. Restaure ca.crt/ca.key do backup ou planeje uma rotação explícita; o instalador não substituirá silenciosamente a confiança dos clusters."
  elif ! ca_certificate_key_match; then
    die "ca.crt e ca.key não formam um par. Restaure a CA correta antes de continuar."
  fi
  [[ -s "${KEYCLOAK_TLS_DIR}/tls.crt" && -s "${KEYCLOAK_TLS_DIR}/tls.key" \
    && -s "${KEYCLOAK_TLS_DIR}/server.sans" ]] || regenerate=true
  [[ -s "${KEYCLOAK_TLS_DIR}/server.sans" \
    && "$(<"${KEYCLOAK_TLS_DIR}/server.sans")" == "${desired_sans}" ]] || regenerate=true
  openssl x509 -checkend 2592000 -noout -in "${KEYCLOAK_TLS_DIR}/tls.crt" >/dev/null 2>&1 || regenerate=true
  openssl verify -CAfile "${KEYCLOAK_TLS_DIR}/ca.crt" "${KEYCLOAK_TLS_DIR}/tls.crt" >/dev/null 2>&1 || regenerate=true
  certificate_key_match || regenerate=true

  if is_true "${regenerate}"; then
    log "Emitindo certificado HTTPS privado para ${desired_sans}."
    extension_file="$(mktemp)"
    trap 'rm -f -- "${extension_file}"' EXIT
    cat >"${extension_file}" <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=${desired_sans}
EOF
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "${KEYCLOAK_TLS_DIR}/tls.key"
    openssl req -new -sha256 -key "${KEYCLOAK_TLS_DIR}/tls.key" \
      -out "${KEYCLOAK_TLS_DIR}/server.csr" -subj "/CN=${KEYCLOAK_HOSTNAME}"
    openssl x509 -req -sha256 -in "${KEYCLOAK_TLS_DIR}/server.csr" \
      -CA "${KEYCLOAK_TLS_DIR}/ca.crt" -CAkey "${KEYCLOAK_TLS_DIR}/ca.key" -CAcreateserial \
      -out "${KEYCLOAK_TLS_DIR}/tls.crt" -days "${TLS_CERT_DAYS}" -extfile "${extension_file}"
    printf '%s' "${desired_sans}" >"${KEYCLOAK_TLS_DIR}/server.sans"
    rm -f -- "${KEYCLOAK_TLS_DIR}/server.csr"
  fi
  chmod 0600 "${KEYCLOAK_TLS_DIR}/ca.key"
fi

chown root:"${KEYCLOAK_GROUP}" "${KEYCLOAK_TLS_DIR}/tls.key" \
  "${KEYCLOAK_TLS_DIR}/tls.crt" "${KEYCLOAK_TLS_DIR}/ca.crt" "${KEYCLOAK_TLS_DIR}/server.sans"
chmod 0640 "${KEYCLOAK_TLS_DIR}/tls.key"
chmod 0644 "${KEYCLOAK_TLS_DIR}/tls.crt" "${KEYCLOAK_TLS_DIR}/ca.crt" "${KEYCLOAK_TLS_DIR}/server.sans"

# O kcadm usa a truststore do Java. Instalar a CA também cobre certificados
# privados fornecidos pelo administrador e mantém a automação administrativa TLS.
install -o root -g root -m 0644 "${KEYCLOAK_TLS_DIR}/ca.crt" \
  /usr/local/share/ca-certificates/keycloak-local-ca.crt
update-ca-certificates >/dev/null

tls_state_ok || die "TLS foi configurado, mas a verificação falhou."
log "TLS pronto para ${KEYCLOAK_HOSTNAME}; CA exportável em ${KEYCLOAK_TLS_DIR}/ca.crt."
