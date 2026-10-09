#!/usr/bin/env bash
# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
require_root
validate_config
original_tls_paths="${TLS_CERT_FILE}|${TLS_KEY_FILE}|${TLS_CA_FILE}"
if ! check_requested "${1:-}"; then install -d -o root -g www-data -m 0750 "${PKI_DIR}"; fi
if [[ "${TLS_MODE}" == private-ca ]]; then
  TLS_CA_FILE="${PKI_DIR}/root-ca.crt"
  TLS_CERT_FILE="${PKI_DIR}/server.crt"
  TLS_KEY_FILE="${PKI_DIR}/server.key"
  if [[ ! -e "${TLS_CA_FILE}" && ! -e "${PKI_DIR}/root-ca.key" && ! -e "${TLS_CERT_FILE}" && ! -e "${TLS_KEY_FILE}" ]]; then
    check_requested "${1:-}" && die 'PKI privada ainda não foi criada.'
    openssl genrsa -out "${PKI_DIR}/root-ca.key" 4096
    openssl req -x509 -new -key "${PKI_DIR}/root-ca.key" -sha256 -days 3650 \
      -subj '/CN=Rancher Local CA' \
      -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign' -out "${TLS_CA_FILE}"
    openssl genrsa -out "${TLS_KEY_FILE}" 3072
    openssl req -new -key "${TLS_KEY_FILE}" -passin pass: -subj "/CN=${RANCHER_FQDN:0:64}" -out "${PKI_DIR}/server.csr"
    printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:%s,IP:%s\n' \
      "${RANCHER_FQDN}" "${SERVER_IP}" >"${PKI_DIR}/server-ext.cnf"
    openssl x509 -req -in "${PKI_DIR}/server.csr" -CA "${TLS_CA_FILE}" -CAkey "${PKI_DIR}/root-ca.key" \
      -CAcreateserial -out "${TLS_CERT_FILE}" -days "${TLS_CERT_DAYS}" -sha256 -extfile "${PKI_DIR}/server-ext.cnf"
    rm -f -- "${PKI_DIR}/server.csr" "${PKI_DIR}/server-ext.cnf"
  fi
  [[ -s "${PKI_DIR}/root-ca.key" && -s "${TLS_CA_FILE}" && -s "${TLS_CERT_FILE}" && -s "${TLS_KEY_FILE}" ]] \
    || die 'PKI incompleta: corrija o conjunto existente; nenhuma chave será sobrescrita.'
  if ! check_requested "${1:-}"; then chmod 0600 "${PKI_DIR}/root-ca.key"; fi
  openssl x509 -in "${TLS_CA_FILE}" -noout -checkend "$((TLS_CERT_DAYS * 86400))" \
    || die 'CA privada vence antes da próxima validade TLS; planeje rotação da CA antes de instalar.'
  if ! openssl x509 -in "${TLS_CERT_FILE}" -noout -checkend 604800 >/dev/null \
    || ! openssl x509 -in "${TLS_CERT_FILE}" -noout -checkhost "${RANCHER_FQDN}" >/dev/null; then
    check_requested "${1:-}" && die 'Certificado privado precisa de renovação para o hostname/validade configurados.'
    install -d -m 0700 /var/lib/rancher-bootstrap/backups
    cp -p -- "${TLS_CERT_FILE}" "/var/lib/rancher-bootstrap/backups/server-$(date '+%Y%m%d-%H%M%S%z')-$$.crt"
    temporary="$(mktemp -d "${PKI_DIR}/.renew.XXXXXX")"
    trap 'rm -f -- "${temporary}/server.csr" "${temporary}/server-ext.cnf" "${temporary}/server.crt"; rmdir -- "${temporary}"' EXIT
    openssl req -new -key "${TLS_KEY_FILE}" -passin pass: -subj "/CN=${RANCHER_FQDN:0:64}" -out "${temporary}/server.csr"
    printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:%s,IP:%s\n' \
      "${RANCHER_FQDN}" "${SERVER_IP}" >"${temporary}/server-ext.cnf"
    openssl x509 -req -in "${temporary}/server.csr" -CA "${TLS_CA_FILE}" -CAkey "${PKI_DIR}/root-ca.key" \
      -CAcreateserial -out "${temporary}/server.crt" -days "${TLS_CERT_DAYS}" -sha256 -extfile "${temporary}/server-ext.cnf"
    install -m 0644 "${temporary}/server.crt" "${TLS_CERT_FILE}"
    log 'Certificado do servidor renovado; CA e chave existentes preservadas.'
  fi
else
  [[ -r "${TLS_CERT_FILE}" && -r "${TLS_KEY_FILE}" ]] || die 'TLS provided exige certificado/chain e chave PEM legíveis.'
fi
openssl x509 -in "${TLS_CERT_FILE}" -noout -checkend 86400 || die 'Certificado expirado ou vence em menos de 24 horas.'
openssl x509 -in "${TLS_CERT_FILE}" -noout -checkhost "${RANCHER_FQDN}" || die 'Certificado não cobre o hostname Rancher.'
certificate_key="$(openssl x509 -in "${TLS_CERT_FILE}" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum)"
private_key="$(openssl pkey -in "${TLS_KEY_FILE}" -passin pass: -pubout -outform DER | sha256sum)"
[[ "${certificate_key}" == "${private_key}" ]] || die 'Certificado e chave não correspondem.'
verify_arguments=(-purpose sslserver -verify_hostname "${RANCHER_FQDN}" -untrusted "${TLS_CERT_FILE}")
if [[ -n "${TLS_CA_FILE}" ]]; then verify_arguments+=(-CAfile "${TLS_CA_FILE}"); fi
openssl verify "${verify_arguments[@]}" "${TLS_CERT_FILE}" || die 'Cadeia TLS inválida.'
if check_requested "${1:-}"; then
  [[ "${original_tls_paths}" == "${TLS_CERT_FILE}|${TLS_KEY_FILE}|${TLS_CA_FILE}" ]] || die 'Caminhos TLS ainda não foram persistidos na configuração.'
  key_mode="$(stat -c '%a' "${TLS_KEY_FILE}")"
  [[ "${key_mode}" == 600 || "${key_mode}" == 640 ]] || die 'Permissões da chave TLS precisam de correção.'
  if [[ "${TLS_MODE}" == private-ca ]]; then
    [[ "$(stat -c '%a' "${PKI_DIR}/root-ca.key")" == 600 ]] || die 'Chave CA privada exige permissão 600.'
  fi
  exit 0
fi
# The path is persisted, never the private key content.
if [[ "${original_tls_paths}" != "${TLS_CERT_FILE}|${TLS_KEY_FILE}|${TLS_CA_FILE}" ]]; then
  printf '\nTLS_CERT_FILE=%q\nTLS_KEY_FILE=%q\nTLS_CA_FILE=%q\n' "${TLS_CERT_FILE}" "${TLS_KEY_FILE}" "${TLS_CA_FILE}" >>"${RANCHER_CONFIG_FILE:-${PROJECT_DIR}/rancher.env}"
fi
chown root:www-data "${TLS_KEY_FILE}"
chmod 0640 "${TLS_KEY_FILE}"
chmod 0644 "${TLS_CERT_FILE}"
if [[ -n "${TLS_CA_FILE}" ]]; then chmod 0644 "${TLS_CA_FILE}"; fi
log 'TLS, hostname, validade e correspondência de chave aprovados.'
