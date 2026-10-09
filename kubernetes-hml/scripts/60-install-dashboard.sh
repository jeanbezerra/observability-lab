#!/usr/bin/env bash

# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_root

node_ip="$(detect_node_ip)"
node_name="$(effective_node_name)"
cert_dir="/etc/kubernetes/pki/headlamp"
san_csv="DNS:localhost,DNS:${node_name},IP:127.0.0.1,IP:${node_ip}"
if [[ "${HEADLAMP_HOST}" != "${node_ip}" && "${HEADLAMP_HOST}" != "${node_name}" && "${HEADLAMP_HOST}" != "localhost" ]]; then
  if valid_ipv4 "${HEADLAMP_HOST}"; then
    san_csv+=",IP:${HEADLAMP_HOST}"
  else
    san_csv+=",DNS:${HEADLAMP_HOST}"
  fi
fi
extension_file=""
rendered_manifest=""

cleanup() {
  [[ -z "${extension_file}" ]] || rm -f -- "${extension_file}"
  [[ -z "${rendered_manifest}" ]] || rm -f -- "${rendered_manifest}"
}
trap cleanup EXIT

tls_checksum() {
  sha256sum "${cert_dir}/tls.crt" "${cert_dir}/tls.key" | sha256sum | awk '{print $1}'
}

certificate_key_matches() {
  local certificate="$1" private_key="$2" certificate_public_key private_public_key
  certificate_public_key="$(openssl x509 -in "${certificate}" -pubkey -noout 2>/dev/null)" || return 1
  private_public_key="$(openssl pkey -in "${private_key}" -pubout 2>/dev/null)" || return 1
  [[ "${certificate_public_key}" == "${private_public_key}" ]]
}

dashboard_state_ok() {
  local actual_args actual_checksum actual_image actual_service admin_home
  local binding_namespace binding_role desired_replicas local_certificate ready_replicas secret_certificate secret_key local_key
  [[ -s "${cert_dir}/ca.crt" && -s "${cert_dir}/ca.key" \
    && -s "${cert_dir}/tls.crt" && -s "${cert_dir}/tls.key" \
    && -s "${cert_dir}/server.sans" ]] || {
      check_pending "certificados TLS locais do Headlamp estão incompletos."
      return 1
    }
  [[ "$(<"${cert_dir}/server.sans")" == "${san_csv}" ]] || {
    check_pending "SANs do certificado do Headlamp mudaram."
    return 1
  }
  openssl x509 -checkend 2592000 -noout -in "${cert_dir}/tls.crt" >/dev/null 2>&1 || {
    check_pending "certificado HTTPS está vencido ou próximo do vencimento."
    return 1
  }
  openssl verify -CAfile "${cert_dir}/ca.crt" "${cert_dir}/tls.crt" >/dev/null 2>&1 || return 1
  openssl x509 -checkend 2592000 -noout -in "${cert_dir}/ca.crt" >/dev/null 2>&1 || return 1
  certificate_key_matches "${cert_dir}/ca.crt" "${cert_dir}/ca.key" || return 1
  certificate_key_matches "${cert_dir}/tls.crt" "${cert_dir}/tls.key" || return 1
  openssl x509 -in "${cert_dir}/tls.crt" -noout -checkip "${node_ip}" >/dev/null 2>&1 || return 1
  openssl x509 -in "${cert_dir}/tls.crt" -noout -checkhost "${node_name}" >/dev/null 2>&1 || return 1
  if valid_ipv4 "${HEADLAMP_HOST}"; then
    openssl x509 -in "${cert_dir}/tls.crt" -noout -checkip "${HEADLAMP_HOST}" >/dev/null 2>&1 || return 1
  else
    openssl x509 -in "${cert_dir}/tls.crt" -noout -checkhost "${HEADLAMP_HOST}" >/dev/null 2>&1 || return 1
  fi
  [[ "$(stat -c '%U:%G:%a' "${cert_dir}/ca.key" 2>/dev/null)" == "root:root:600" \
    && "$(stat -c '%U:%G:%a' "${cert_dir}/tls.key" 2>/dev/null)" == "root:root:600" ]] || return 1

  kube -n "${DASHBOARD_NAMESPACE}" get secret headlamp-tls >/dev/null 2>&1 || {
    check_pending "Secret TLS do Headlamp não existe."
    return 1
  }
  secret_certificate="$(kube -n "${DASHBOARD_NAMESPACE}" get secret headlamp-tls \
    -o jsonpath='{.data.tls\.crt}' 2>/dev/null)"
  local_certificate="$(base64 -w 0 "${cert_dir}/tls.crt")"
  [[ "${secret_certificate}" == "${local_certificate}" ]] || return 1
  secret_key="$(kube -n "${DASHBOARD_NAMESPACE}" get secret headlamp-tls \
    -o jsonpath='{.data.tls\.key}' 2>/dev/null)"
  local_key="$(base64 -w 0 "${cert_dir}/tls.key")"
  [[ "${secret_key}" == "${local_key}" ]] || return 1

  kube -n "${DASHBOARD_NAMESPACE}" get deployment headlamp >/dev/null 2>&1 || {
    check_pending "Deployment do Headlamp não existe."
    return 1
  }
  actual_image="$(kube -n "${DASHBOARD_NAMESPACE}" get deployment headlamp \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="headlamp")].image}' 2>/dev/null)"
  [[ "${actual_image}" == "${HEADLAMP_IMAGE}" ]] || return 1
  actual_args="$(kube -n "${DASHBOARD_NAMESPACE}" get deployment headlamp \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="headlamp")].args}' 2>/dev/null)"
  if ! grep -Fq -- '-in-cluster' <<<"${actual_args}" \
    || ! grep -Fq -- '-unsafe-use-service-account-token' <<<"${actual_args}"; then
    check_pending "Headlamp não está no modo HML sem login."
    return 1
  fi
  actual_checksum="$(kube -n "${DASHBOARD_NAMESPACE}" get deployment headlamp \
    -o jsonpath='{.spec.template.metadata.annotations.bootstrap\.k8s\.io/tls-checksum}' 2>/dev/null)"
  [[ "${actual_checksum}" == "$(tls_checksum)" ]] || return 1
  read -r desired_replicas ready_replicas < <(kube -n "${DASHBOARD_NAMESPACE}" get deployment headlamp \
    -o jsonpath='{.spec.replicas} {.status.readyReplicas}' 2>/dev/null)
  [[ "${desired_replicas}" == "1" && "${ready_replicas}" == "1" ]] || return 1

  actual_service="$(kube -n "${DASHBOARD_NAMESPACE}" get service headlamp \
    -o jsonpath='{.spec.type}:{.spec.ports[*].port}:{.spec.ports[*].targetPort}:{.spec.ports[*].nodePort}:{.spec.ports[*].protocol}:{.spec.selector.app\.kubernetes\.io/name}:{.spec.externalTrafficPolicy}:{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null)"
  [[ "${actual_service}" == "NodePort:443:https:${DASHBOARD_NODE_PORT}:TCP:headlamp:Cluster:kubernetes-hml" ]] || {
    check_pending "Service do Headlamp difere do NodePort HTTPS ${DASHBOARD_NODE_PORT} esperado."
    return 1
  }

  binding_role="$(kube get clusterrolebinding headlamp-hml-admin \
    -o jsonpath='{.roleRef.name}' 2>/dev/null)"
  binding_namespace="$(kube get clusterrolebinding headlamp-hml-admin \
    -o jsonpath='{.subjects[?(@.name=="headlamp")].namespace}' 2>/dev/null)"
  [[ "${binding_role}" == "cluster-admin" && "${binding_namespace}" == "${DASHBOARD_NAMESPACE}" ]] || {
    check_pending "RBAC HML do Headlamp está ausente ou incorreto."
    return 1
  }
  kube auth can-i '*' '*' --all-namespaces \
    --as="system:serviceaccount:${DASHBOARD_NAMESPACE}:headlamp" --quiet || return 1

  admin_home="$(getent passwd "${ADMIN_USER}" | cut -d: -f6)"
  if [[ -z "${admin_home}" || ! -r "${admin_home}/.kube/headlamp-ca.crt" ]] \
    || ! cmp -s "${cert_dir}/ca.crt" "${admin_home}/.kube/headlamp-ca.crt"; then
    return 1
  fi
  [[ "$(stat -c '%U:%a' "${admin_home}/.kube/headlamp-ca.crt" 2>/dev/null)" == "${ADMIN_USER}:644" ]]
}

dashboard_diagnostics() {
  warn "Headlamp não ficou pronto; coletando diagnóstico de ${DASHBOARD_NAMESPACE}."
  kube -n "${DASHBOARD_NAMESPACE}" get deployment,replicaset,pod,service -o wide || true
  kube -n "${DASHBOARD_NAMESPACE}" describe deployment/headlamp || true
  kube -n "${DASHBOARD_NAMESPACE}" logs deployment/headlamp --all-containers --prefix --tail=100 || true
  kube -n "${DASHBOARD_NAMESPACE}" get events --sort-by=.metadata.creationTimestamp | tail -n 50 || true
}

wait_for_headlamp() {
  local elapsed=0 interval=10 timeout_seconds started_at
  timeout_seconds="$(duration_to_seconds "${DASHBOARD_ROLLOUT_TIMEOUT}")" || return 1
  started_at="${SECONDS}"
  while (( elapsed < timeout_seconds )); do
    if kube -n "${DASHBOARD_NAMESPACE}" rollout status deployment/headlamp \
      --timeout="${KUBERNETES_REQUEST_TIMEOUT_SECONDS}s" >/dev/null 2>&1; then
      return 0
    fi
    elapsed=$((SECONDS - started_at))
    (( elapsed < timeout_seconds )) || break
    log "Aguardando o Headlamp ficar pronto (${elapsed}s/${timeout_seconds}s)."
    sleep "${interval}"
    elapsed=$((SECONDS - started_at))
  done
  return 1
}

pull_dashboard_image() {
  if command -v crictl >/dev/null 2>&1; then
    retry "${ARTIFACT_RETRY_ATTEMPTS}" "${ARTIFACT_RETRY_DELAY_SECONDS}" \
      crictl --runtime-endpoint=unix:///run/containerd/containerd.sock pull "${HEADLAMP_IMAGE}"
  else
    retry "${ARTIFACT_RETRY_ATTEMPTS}" "${ARTIFACT_RETRY_DELAY_SECONDS}" \
      ctr --namespace k8s.io images pull "${HEADLAMP_IMAGE}"
  fi
}

if check_requested "${1:-}"; then
  if dashboard_state_ok; then
    exit 0
  fi
  exit 1
fi

require_command openssl
require_command sha256sum
umask 077
install -d -o root -g root -m 0700 "${cert_dir}"

regenerate_ca=false
if [[ ! -s "${cert_dir}/ca.crt" || ! -s "${cert_dir}/ca.key" ]] \
  || ! openssl x509 -checkend 2592000 -noout -in "${cert_dir}/ca.crt" >/dev/null 2>&1 \
  || ! certificate_key_matches "${cert_dir}/ca.crt" "${cert_dir}/ca.key"; then
  log "Criando CA do Headlamp HML."
  openssl genrsa -out "${cert_dir}/ca.key" 4096
  openssl req -x509 -new -sha256 -key "${cert_dir}/ca.key" \
    -out "${cert_dir}/ca.crt" -days 3650 -subj "/CN=kubernetes-hml-headlamp-ca" \
    -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign'
  regenerate_ca=true
fi

regenerate_certificate=false
if is_true "${regenerate_ca}" \
  || [[ ! -s "${cert_dir}/tls.crt" || ! -s "${cert_dir}/tls.key" || ! -s "${cert_dir}/server.sans" ]]; then
  regenerate_certificate=true
elif [[ "$(<"${cert_dir}/server.sans")" != "${san_csv}" ]]; then
  regenerate_certificate=true
elif ! openssl x509 -checkend 2592000 -noout -in "${cert_dir}/tls.crt" >/dev/null 2>&1; then
  regenerate_certificate=true
elif ! openssl verify -CAfile "${cert_dir}/ca.crt" "${cert_dir}/tls.crt" >/dev/null 2>&1 \
  || ! certificate_key_matches "${cert_dir}/tls.crt" "${cert_dir}/tls.key"; then
  regenerate_certificate=true
fi

if is_true "${regenerate_certificate}"; then
  extension_file="$(mktemp)"
  cat >"${extension_file}" <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=${san_csv}
EOF
  openssl genrsa -out "${cert_dir}/tls.key" 4096
  openssl req -new -sha256 -key "${cert_dir}/tls.key" \
    -out "${cert_dir}/server.csr" -subj "/CN=${HEADLAMP_HOST}"
  openssl x509 -req -sha256 -in "${cert_dir}/server.csr" \
    -CA "${cert_dir}/ca.crt" -CAkey "${cert_dir}/ca.key" -CAcreateserial \
    -out "${cert_dir}/tls.crt" -days "${DASHBOARD_CERT_DAYS}" -extfile "${extension_file}"
  printf '%s' "${san_csv}" >"${cert_dir}/server.sans"
  rm -f -- "${cert_dir}/server.csr"
fi
chmod 0600 "${cert_dir}/ca.key" "${cert_dir}/tls.key"
chmod 0644 "${cert_dir}/ca.crt" "${cert_dir}/tls.crt" "${cert_dir}/server.sans"

log "Baixando a imagem ${HEADLAMP_IMAGE}, se necessário."
pull_dashboard_image || die "não foi possível baixar o Headlamp; confira DNS, VPN e proxy corporativo."

for resource_ref in "deployment|headlamp" "service|headlamp" "serviceaccount|headlamp" "secret|headlamp-tls" "clusterrolebinding|headlamp-hml-admin"; do
  IFS='|' read -r resource_kind resource_name <<<"${resource_ref}"
  namespace_args=(-n "${DASHBOARD_NAMESPACE}")
  [[ "${resource_kind}" != "clusterrolebinding" ]] || namespace_args=()
  if kube "${namespace_args[@]}" get "${resource_kind}" "${resource_name}" >/dev/null 2>&1; then
    managed_label="$(kube "${namespace_args[@]}" get "${resource_kind}" "${resource_name}" \
      -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}')"
    [[ "${managed_label}" == "kubernetes-hml" ]] \
      || die "${resource_kind}/${resource_name} já existe e não é gerenciado por kubernetes-hml."
  fi
done

kube create namespace "${DASHBOARD_NAMESPACE}" --dry-run=client -o yaml | kube apply -f -
kube -n "${DASHBOARD_NAMESPACE}" create secret tls headlamp-tls \
  --cert="${cert_dir}/tls.crt" --key="${cert_dir}/tls.key" \
  --dry-run=client -o yaml \
  | kubectl label --local -f - app.kubernetes.io/managed-by=kubernetes-hml -o yaml \
  | kube apply -f -

rendered_manifest="$(mktemp)"
sed \
  -e "s|__NAMESPACE__|${DASHBOARD_NAMESPACE}|g" \
  -e "s|__HEADLAMP_IMAGE__|${HEADLAMP_IMAGE}|g" \
  -e "s|__TLS_CHECKSUM__|$(tls_checksum)|g" \
  -e "s|__DASHBOARD_NODE_PORT__|${DASHBOARD_NODE_PORT}|g" \
  "${PROJECT_DIR}/manifests/dashboard/headlamp.yaml" >"${rendered_manifest}"

if kube get clusterrolebinding headlamp-hml-admin >/dev/null 2>&1; then
  existing_role="$(kube get clusterrolebinding headlamp-hml-admin \
    -o jsonpath='{.roleRef.apiGroup}/{.roleRef.kind}/{.roleRef.name}')"
  if [[ "${existing_role}" != "rbac.authorization.k8s.io/ClusterRole/cluster-admin" ]]; then
    # roleRef é imutável; somente esta binding HML previamente reconhecida é recriada.
    kube delete clusterrolebinding headlamp-hml-admin --wait=true
  fi
fi

log "Instalando Headlamp sem senha ou token manual em https://${HEADLAMP_HOST}:${DASHBOARD_NODE_PORT}."
kube apply -f "${rendered_manifest}"
if ! wait_for_headlamp; then
  dashboard_diagnostics
  die "Headlamp não ficou pronto em ${DASHBOARD_ROLLOUT_TIMEOUT}."
fi

primary_group="$(id -gn "${ADMIN_USER}")"
admin_home="$(getent passwd "${ADMIN_USER}" | cut -d: -f6)"
install -d -o "${ADMIN_USER}" -g "${primary_group}" -m 0700 "${admin_home}/.kube"
install -o "${ADMIN_USER}" -g "${primary_group}" -m 0644 \
  "${cert_dir}/ca.crt" "${admin_home}/.kube/headlamp-ca.crt"

dashboard_state_ok || die "o Headlamp foi aplicado, mas a verificação de estado falhou."
log "Headlamp instalado com TLS e NodePort ${DASHBOARD_NODE_PORT}; CA em ${admin_home}/.kube/headlamp-ca.crt."
