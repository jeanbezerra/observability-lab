#!/usr/bin/env bash

# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_root
require_command openssl
require_command sed
require_command sha256sum
require_command crictl

node_ip="$(detect_node_ip)"
node_name="$(effective_node_name)"
cert_dir="/etc/kubernetes/pki/headlamp"
install -d -o root -g root -m 0700 "${cert_dir}"
extension_file=""
rendered_manifest=""

cleanup() {
  [[ -z "${extension_file}" ]] || rm -f -- "${extension_file}"
  [[ -z "${rendered_manifest}" ]] || rm -f -- "${rendered_manifest}"
  rm -f -- "${cert_dir}/server.csr"
}
trap cleanup EXIT

dashboard_diagnostics() {
  warn "O rollout do Headlamp falhou. Coletando diagnóstico do namespace ${DASHBOARD_NAMESPACE}."
  kube -n "${DASHBOARD_NAMESPACE}" get deployment,replicaset,pod,service -o wide || true
  printf '\n--- DESCRIBE DEPLOYMENT ---\n' >&2
  kube -n "${DASHBOARD_NAMESPACE}" describe deployment/headlamp || true
  printf '\n--- DESCRIBE PODS ---\n' >&2
  kube -n "${DASHBOARD_NAMESPACE}" describe pods -l app.kubernetes.io/name=headlamp || true
  printf '\n--- LOGS ---\n' >&2
  kube -n "${DASHBOARD_NAMESPACE}" logs \
    -l app.kubernetes.io/name=headlamp --all-containers=true --prefix --tail=100 || true
  printf '\n--- EVENTOS RECENTES ---\n' >&2
  kube -n "${DASHBOARD_NAMESPACE}" get events --sort-by=.metadata.creationTimestamp \
    | tail -n 50 || true
}

if [[ ! -s "${cert_dir}/ca.crt" || ! -s "${cert_dir}/ca.key" ]]; then
  log "Criando autoridade certificadora local para o Dashboard."
  openssl genrsa -out "${cert_dir}/ca.key" 4096
  openssl req -x509 -new -sha256 \
    -key "${cert_dir}/ca.key" \
    -out "${cert_dir}/ca.crt" \
    -days 3650 \
    -subj "/CN=k8s-dashboard-local-ca"
fi

san_entries=("DNS:${node_name}" "IP:${node_ip}")
[[ -z "${DASHBOARD_DNS_NAME}" ]] || san_entries+=("DNS:${DASHBOARD_DNS_NAME}")
[[ -z "${DASHBOARD_PUBLIC_IP}" ]] || san_entries+=("IP:${DASHBOARD_PUBLIC_IP}")
san_csv="$(IFS=,; printf '%s' "${san_entries[*]}")"
common_name="${DASHBOARD_DNS_NAME:-${node_name}}"

regenerate_certificate=false
if [[ ! -s "${cert_dir}/tls.crt" || ! -s "${cert_dir}/tls.key" || ! -s "${cert_dir}/server.sans" ]]; then
  regenerate_certificate=true
elif [[ "$(<"${cert_dir}/server.sans")" != "${san_csv}" ]]; then
  regenerate_certificate=true
elif ! openssl x509 -checkend 2592000 -noout -in "${cert_dir}/tls.crt" >/dev/null 2>&1; then
  regenerate_certificate=true
elif ! openssl verify -CAfile "${cert_dir}/ca.crt" "${cert_dir}/tls.crt" >/dev/null 2>&1; then
  regenerate_certificate=true
fi

if is_true "${regenerate_certificate}"; then
  log "Emitindo certificado HTTPS do Dashboard para ${san_csv}."
  extension_file="$(mktemp)"
  cat >"${extension_file}" <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=${san_csv}
EOF
  openssl genrsa -out "${cert_dir}/tls.key" 4096
  openssl req -new -sha256 \
    -key "${cert_dir}/tls.key" \
    -out "${cert_dir}/server.csr" \
    -subj "/CN=${common_name}"
  openssl x509 -req -sha256 \
    -in "${cert_dir}/server.csr" \
    -CA "${cert_dir}/ca.crt" \
    -CAkey "${cert_dir}/ca.key" \
    -CAcreateserial \
    -out "${cert_dir}/tls.crt" \
    -days "${DASHBOARD_CERT_DAYS}" \
    -extfile "${extension_file}"
  printf '%s' "${san_csv}" >"${cert_dir}/server.sans"
fi

chmod 0600 "${cert_dir}/ca.key" "${cert_dir}/tls.key"
chmod 0644 "${cert_dir}/ca.crt" "${cert_dir}/tls.crt" "${cert_dir}/server.sans"

log "Garantindo que a imagem ${HEADLAMP_IMAGE} esteja disponível no containerd."
if ! retry 3 5 crictl --runtime-endpoint=unix:///run/containerd/containerd.sock \
  pull "${HEADLAMP_IMAGE}"; then
  die "não foi possível baixar ${HEADLAMP_IMAGE} do GHCR; verifique DNS, proxy e acesso a ghcr.io."
fi

kube create namespace "${DASHBOARD_NAMESPACE}" --dry-run=client -o yaml | kube apply -f -
kube -n "${DASHBOARD_NAMESPACE}" create secret tls headlamp-tls \
  --cert="${cert_dir}/tls.crt" \
  --key="${cert_dir}/tls.key" \
  --dry-run=client -o yaml | kube apply -f -

rendered_manifest="$(mktemp)"
tls_checksum="$(sha256sum "${cert_dir}/tls.crt" "${cert_dir}/tls.key" | sha256sum | awk '{print $1}')"
sed \
  -e "s|__NAMESPACE__|${DASHBOARD_NAMESPACE}|g" \
  -e "s|__NODE_PORT__|${DASHBOARD_NODE_PORT}|g" \
  -e "s|__HEADLAMP_IMAGE__|${HEADLAMP_IMAGE}|g" \
  -e "s|__TLS_CHECKSUM__|${tls_checksum}|g" \
  "${PROJECT_DIR}/manifests/dashboard/headlamp.yaml" >"${rendered_manifest}"

log "Instalando Dashboard Headlamp como Deployment e NodePort HTTPS."
kube apply -f "${rendered_manifest}"
if ! kube -n "${DASHBOARD_NAMESPACE}" rollout status deployment/headlamp \
  --timeout="${DASHBOARD_ROLLOUT_TIMEOUT}"; then
  dashboard_diagnostics
  die "Headlamp não ficou pronto em ${DASHBOARD_ROLLOUT_TIMEOUT}; veja o diagnóstico acima."
fi

primary_group="$(id -gn "${ADMIN_USER}")"
admin_home="$(getent passwd "${ADMIN_USER}" | cut -d: -f6)"
install -o "${ADMIN_USER}" -g "${primary_group}" -m 0644 \
  "${cert_dir}/ca.crt" "${admin_home}/.kube/headlamp-ca.crt"

log "Dashboard instalado em https://${node_ip}:${DASHBOARD_NODE_PORT}."
