#!/usr/bin/env bash

# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_root

node_ip="$(detect_node_ip)"
node_name="$(effective_node_name)"
cert_dir="/etc/kubernetes/pki/headlamp"
san_entries=("DNS:${node_name}" "IP:${node_ip}")
[[ -z "${DASHBOARD_DNS_NAME}" ]] || san_entries+=("DNS:${DASHBOARD_DNS_NAME}")
[[ -z "${DASHBOARD_PUBLIC_IP}" ]] || san_entries+=("IP:${DASHBOARD_PUBLIC_IP}")
san_csv="$(IFS=,; printf '%s' "${san_entries[*]}")"
common_name="${DASHBOARD_DNS_NAME:-${node_name}}"
previous_dashboard_namespace=""
if [[ -r /etc/k8s-bootstrap/dashboard.env ]]; then
  previous_dashboard_namespace="$(sed -n 's/^DASHBOARD_NAMESPACE=//p' /etc/k8s-bootstrap/dashboard.env | head -n 1)"
fi
extension_file=""
rendered_manifest=""
base_manifest=""
oidc_env_fragment=""
oidc_volume_mount_fragment=""
oidc_volume_fragment=""
oidc_secret_file=""

cleanup() {
  [[ -z "${extension_file}" ]] || rm -f -- "${extension_file}"
  [[ -z "${rendered_manifest}" ]] || rm -f -- "${rendered_manifest}"
  [[ -z "${base_manifest}" ]] || rm -f -- "${base_manifest}"
  [[ -z "${oidc_env_fragment}" ]] || rm -f -- "${oidc_env_fragment}"
  [[ -z "${oidc_volume_mount_fragment}" ]] || rm -f -- "${oidc_volume_mount_fragment}"
  [[ -z "${oidc_volume_fragment}" ]] || rm -f -- "${oidc_volume_fragment}"
  [[ -z "${oidc_secret_file}" ]] || rm -f -- "${oidc_secret_file}"
}
trap cleanup EXIT

tls_checksum() {
  sha256sum "${cert_dir}/tls.crt" "${cert_dir}/tls.key" | sha256sum | awk '{print $1}'
}

oidc_checksum() {
  if ! is_true "${ENABLE_OIDC}"; then
    printf 'disabled' | sha256sum | awk '{print $1}'
    return
  fi
  {
    printf '%s\n' "${OIDC_CLIENT_ID}" "${OIDC_ISSUER_URL}" "${HEADLAMP_OIDC_SCOPES}"
    printf '%s' "${HEADLAMP_OIDC_CLIENT_SECRET}" | sha256sum
    [[ -z "${OIDC_CA_FILE}" ]] || sha256sum "${OIDC_CA_FILE}"
  } | sha256sum | awk '{print $1}'
}

dashboard_state_ok() {
  local actual_checksum actual_fs_group actual_group actual_image actual_node_port actual_strategy actual_user
  local actual_oidc_checksum actual_oidc_client actual_oidc_issuer actual_oidc_scopes actual_oidc_secret_ref
  local admin_home desired_replicas ready_replicas secret_certificate local_certificate secret_oidc local_oidc
  command -v openssl >/dev/null 2>&1 || {
    check_pending "openssl não está instalado."
    return 1
  }
  command -v sha256sum >/dev/null 2>&1 || {
    check_pending "sha256sum não está disponível."
    return 1
  }
  [[ -s "${cert_dir}/ca.crt" && -s "${cert_dir}/ca.key" \
    && -s "${cert_dir}/tls.crt" && -s "${cert_dir}/tls.key" \
    && -s "${cert_dir}/server.sans" ]] || {
      check_pending "certificados TLS do Dashboard estão incompletos."
      return 1
    }
  [[ "$(stat -c '%U:%G:%a' "${cert_dir}/ca.key" 2>/dev/null)" == "root:root:600" \
    && "$(stat -c '%U:%G:%a' "${cert_dir}/tls.key" 2>/dev/null)" == "root:root:600" ]] || {
      check_pending "permissões das chaves TLS do Dashboard estão incorretas."
      return 1
    }
  [[ "$(<"${cert_dir}/server.sans")" == "${san_csv}" ]] || {
    check_pending "SANs do certificado do Dashboard mudaram."
    return 1
  }
  openssl x509 -checkend 2592000 -noout -in "${cert_dir}/tls.crt" >/dev/null 2>&1 || {
    check_pending "certificado HTTPS está vencido ou próximo do vencimento."
    return 1
  }
  openssl verify -CAfile "${cert_dir}/ca.crt" "${cert_dir}/tls.crt" >/dev/null 2>&1 || {
    check_pending "certificado HTTPS não confere com a CA local."
    return 1
  }
  kube -n "${DASHBOARD_NAMESPACE}" get secret headlamp-tls >/dev/null 2>&1 || {
    check_pending "Secret TLS do Headlamp não existe."
    return 1
  }
  secret_certificate="$(kube -n "${DASHBOARD_NAMESPACE}" get secret headlamp-tls \
    -o jsonpath='{.data.tls\.crt}' 2>/dev/null)"
  local_certificate="$(base64 -w 0 "${cert_dir}/tls.crt")"
  [[ "${secret_certificate}" == "${local_certificate}" ]] || {
    check_pending "Secret TLS do Headlamp está desatualizado."
    return 1
  }
  kube -n "${DASHBOARD_NAMESPACE}" get deployment headlamp >/dev/null 2>&1 || {
    check_pending "Deployment do Headlamp não existe."
    return 1
  }
  actual_image="$(kube -n "${DASHBOARD_NAMESPACE}" get deployment headlamp \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="headlamp")].image}' 2>/dev/null)"
  [[ "${actual_image}" == "${HEADLAMP_IMAGE}" ]] || {
    check_pending "imagem do Headlamp difere de ${HEADLAMP_IMAGE}."
    return 1
  }
  actual_strategy="$(kube -n "${DASHBOARD_NAMESPACE}" get deployment headlamp \
    -o jsonpath='{.spec.strategy.type}' 2>/dev/null)"
  [[ "${actual_strategy}" == "Recreate" ]] || {
    check_pending "Deployment Headlamp ainda não usa estratégia Recreate."
    return 1
  }
  actual_checksum="$(kube -n "${DASHBOARD_NAMESPACE}" get deployment headlamp \
    -o jsonpath='{.spec.template.metadata.annotations.bootstrap\.k8s\.io/tls-checksum}' 2>/dev/null)"
  [[ "${actual_checksum}" == "$(tls_checksum)" ]] || {
    check_pending "Pod do Headlamp ainda não referencia o certificado TLS atual."
    return 1
  }
  actual_oidc_checksum="$(kube -n "${DASHBOARD_NAMESPACE}" get deployment headlamp \
    -o jsonpath='{.spec.template.metadata.annotations.bootstrap\.k8s\.io/oidc-checksum}' 2>/dev/null)"
  [[ "${actual_oidc_checksum}" == "$(oidc_checksum)" ]] || {
    check_pending "Pod do Headlamp ainda não referencia a configuração OIDC atual."
    return 1
  }
  actual_oidc_client="$(kube -n "${DASHBOARD_NAMESPACE}" get deployment headlamp \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="headlamp")].env[?(@.name=="HEADLAMP_CONFIG_OIDC_CLIENT_ID")].value}' 2>/dev/null)"
  if is_true "${ENABLE_OIDC}"; then
    actual_oidc_issuer="$(kube -n "${DASHBOARD_NAMESPACE}" get deployment headlamp \
      -o jsonpath='{.spec.template.spec.containers[?(@.name=="headlamp")].env[?(@.name=="HEADLAMP_CONFIG_OIDC_IDP_ISSUER_URL")].value}' 2>/dev/null)"
    actual_oidc_scopes="$(kube -n "${DASHBOARD_NAMESPACE}" get deployment headlamp \
      -o jsonpath='{.spec.template.spec.containers[?(@.name=="headlamp")].env[?(@.name=="HEADLAMP_CONFIG_OIDC_SCOPES")].value}' 2>/dev/null)"
    actual_oidc_secret_ref="$(kube -n "${DASHBOARD_NAMESPACE}" get deployment headlamp \
      -o jsonpath='{.spec.template.spec.containers[?(@.name=="headlamp")].env[?(@.name=="HEADLAMP_CONFIG_OIDC_CLIENT_SECRET")].valueFrom.secretKeyRef.name}' 2>/dev/null)"
    [[ "${actual_oidc_client}" == "${OIDC_CLIENT_ID}" \
      && "${actual_oidc_issuer}" == "${OIDC_ISSUER_URL}" \
      && "${actual_oidc_scopes}" == "${HEADLAMP_OIDC_SCOPES}" \
      && "${actual_oidc_secret_ref}" == "headlamp-oidc" ]] || {
        check_pending "variáveis OIDC do Headlamp estão ausentes ou divergentes."
        return 1
      }
    secret_oidc="$(kube -n "${DASHBOARD_NAMESPACE}" get secret headlamp-oidc \
      -o jsonpath='{.data.client-secret}' 2>/dev/null)"
    local_oidc="$(printf '%s' "${HEADLAMP_OIDC_CLIENT_SECRET}" | base64 -w 0)"
    [[ "${secret_oidc}" == "${local_oidc}" ]] || {
      check_pending "Secret OIDC do Headlamp está ausente ou desatualizado."
      return 1
    }
    if [[ -n "${OIDC_CA_FILE}" ]]; then
      kube -n "${DASHBOARD_NAMESPACE}" get configmap headlamp-oidc-ca >/dev/null 2>&1 || {
        check_pending "ConfigMap da CA privada do Keycloak está ausente."
        return 1
      }
      [[ "$(kube -n "${DASHBOARD_NAMESPACE}" get configmap headlamp-oidc-ca \
        -o jsonpath='{.data.keycloak-ca\.crt}' 2>/dev/null)" == "$(<"${OIDC_CA_FILE}")" ]] || {
          check_pending "CA privada montada no Headlamp está desatualizada."
          return 1
        }
    fi
  elif [[ -n "${actual_oidc_client}" ]]; then
    check_pending "Headlamp ainda possui configuração OIDC apesar de ENABLE_OIDC=false."
    return 1
  fi
  read -r desired_replicas ready_replicas < <(kube -n "${DASHBOARD_NAMESPACE}" get deployment headlamp \
    -o jsonpath='{.spec.replicas} {.status.readyReplicas}' 2>/dev/null)
  [[ "${desired_replicas}" == "1" && "${ready_replicas}" == "1" ]] || {
    check_pending "Headlamp ainda não possui uma réplica pronta."
    return 1
  }
  actual_node_port="$(kube -n "${DASHBOARD_NAMESPACE}" get service headlamp \
    -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}' 2>/dev/null)"
  [[ "${actual_node_port}" == "${DASHBOARD_NODE_PORT}" ]] || {
    check_pending "NodePort do Headlamp difere de ${DASHBOARD_NODE_PORT}."
    return 1
  }
  admin_home="$(getent passwd "${ADMIN_USER}" | cut -d: -f6)"
  [[ -n "${admin_home}" && -r "${admin_home}/.kube/headlamp-ca.crt" ]] \
    && cmp -s "${cert_dir}/ca.crt" "${admin_home}/.kube/headlamp-ca.crt" || {
      check_pending "cópia pública da CA para ${ADMIN_USER} está ausente ou desatualizada."
      return 1
    }
  actual_user="$(kube -n "${DASHBOARD_NAMESPACE}" get deployment headlamp \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="headlamp")].securityContext.runAsUser}' 2>/dev/null)"
  actual_group="$(kube -n "${DASHBOARD_NAMESPACE}" get deployment headlamp \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="headlamp")].securityContext.runAsGroup}' 2>/dev/null)"
  actual_fs_group="$(kube -n "${DASHBOARD_NAMESPACE}" get deployment headlamp \
    -o jsonpath='{.spec.template.spec.securityContext.fsGroup}' 2>/dev/null)"
  [[ "${actual_user}" == "100" && "${actual_group}" == "101" && "${actual_fs_group}" == "101" ]] || {
    check_pending "UID/GID do Headlamp precisa ser 100:101 para validar runAsNonRoot."
    return 1
  }
  [[ "$(stat -c '%U:%a' "${admin_home}/.kube/headlamp-ca.crt" 2>/dev/null)" == "${ADMIN_USER}:644" ]] || {
    check_pending "dono ou modo da CA pública de ${ADMIN_USER} está incorreto."
    return 1
  }
}

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

headlamp_workload_absent() {
  kube get namespace "${DASHBOARD_NAMESPACE}" >/dev/null 2>&1 || return 1
  ! kube -n "${DASHBOARD_NAMESPACE}" get deployment headlamp >/dev/null 2>&1 \
    && [[ -z "$(kube -n "${DASHBOARD_NAMESPACE}" get replicaset,pod \
      -l app.kubernetes.io/name=headlamp -o name 2>/dev/null)" ]]
}

remove_headlamp_workload() {
  local pod_name
  warn "Recriando somente o workload Headlamp gerenciado; Service, TLS, RBAC e outros workloads serão preservados."
  kube -n "${DASHBOARD_NAMESPACE}" delete deployment headlamp \
    --ignore-not-found=true --cascade=background --wait=false
  kube -n "${DASHBOARD_NAMESPACE}" delete replicaset \
    -l app.kubernetes.io/name=headlamp \
    --ignore-not-found=true --cascade=background --wait=false

  log "Aguardando até 30 segundos pelo encerramento gracioso dos Pods Headlamp."
  if retry 15 2 headlamp_workload_absent; then
    return 0
  fi

  warn "Pods Headlamp não encerraram no prazo; aplicando remoção forçada somente aos remanescentes."
  while read -r pod_name; do
    [[ -z "${pod_name}" ]] && continue
    kube -n "${DASHBOARD_NAMESPACE}" delete pod "${pod_name}" \
      --grace-period=0 --force --wait=false
  done < <(kube -n "${DASHBOARD_NAMESPACE}" get pod \
    -l app.kubernetes.io/name=headlamp -o name 2>/dev/null | sed 's#^pod/##')
  retry 15 2 headlamp_workload_absent \
    || die "recursos antigos do Headlamp permaneceram após as tentativas graciosa e forçada."
}

headlamp_workload_needs_recreation() {
  local actual_group actual_image actual_label actual_strategy actual_user desired ready terminating_pods
  kube -n "${DASHBOARD_NAMESPACE}" get deployment headlamp >/dev/null 2>&1 || return 1
  actual_label="$(kube -n "${DASHBOARD_NAMESPACE}" get deployment headlamp \
    -o jsonpath='{.metadata.labels.app\.kubernetes\.io/name}' 2>/dev/null)"
  [[ "${actual_label}" == "headlamp" ]] \
    || die "Deployment headlamp existente não possui o rótulo gerenciado; ele não será removido automaticamente."
  actual_strategy="$(kube -n "${DASHBOARD_NAMESPACE}" get deployment headlamp \
    -o jsonpath='{.spec.strategy.type}' 2>/dev/null)"
  actual_image="$(kube -n "${DASHBOARD_NAMESPACE}" get deployment headlamp \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="headlamp")].image}' 2>/dev/null)"
  actual_user="$(kube -n "${DASHBOARD_NAMESPACE}" get deployment headlamp \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="headlamp")].securityContext.runAsUser}' 2>/dev/null)"
  actual_group="$(kube -n "${DASHBOARD_NAMESPACE}" get deployment headlamp \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="headlamp")].securityContext.runAsGroup}' 2>/dev/null)"
  read -r desired ready < <(kube -n "${DASHBOARD_NAMESPACE}" get deployment headlamp \
    -o jsonpath='{.spec.replicas} {.status.readyReplicas}' 2>/dev/null)
  terminating_pods="$(kube -n "${DASHBOARD_NAMESPACE}" get pod \
    -l app.kubernetes.io/name=headlamp \
    -o jsonpath='{range .items[*]}{.metadata.deletionTimestamp}{"\n"}{end}' 2>/dev/null \
    | grep -v '^$' || true)"
  [[ "${actual_strategy}" != "Recreate" \
    || "${actual_image}" != "${HEADLAMP_IMAGE}" \
    || "${actual_user}" != "100" \
    || "${actual_group}" != "101" \
    || "${desired}" != "1" \
    || "${ready:-0}" != "1" \
    || -n "${terminating_pods}" ]]
}

wait_for_headlamp() {
  local elapsed=0 interval=10 timeout_seconds pod_summary ready_replicas
  timeout_seconds="$(duration_to_seconds "${DASHBOARD_ROLLOUT_TIMEOUT}")" \
    || die "DASHBOARD_ROLLOUT_TIMEOUT inválido: ${DASHBOARD_ROLLOUT_TIMEOUT}."
  while (( elapsed < timeout_seconds )); do
    if kube -n "${DASHBOARD_NAMESPACE}" rollout status deployment/headlamp \
      --timeout=5s >/dev/null 2>&1; then
      return 0
    fi
    ready_replicas="$(kube -n "${DASHBOARD_NAMESPACE}" get deployment headlamp \
      -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
    pod_summary="$(kube -n "${DASHBOARD_NAMESPACE}" get pod \
      -l app.kubernetes.io/name=headlamp \
      -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,WAITING:.status.containerStatuses[0].state.waiting.reason,NODE:.spec.nodeName' \
      --no-headers 2>/dev/null | tr '\n' ';' || true)"
    log "Aguardando Headlamp: ${ready_replicas:-0}/1 pronta; ${pod_summary:-nenhum Pod criado}"
    sleep "${interval}"
    elapsed=$((elapsed + interval + 5))
  done
  return 1
}

pull_dashboard_image() {
  if command -v crictl >/dev/null 2>&1; then
    retry 3 5 crictl --runtime-endpoint=unix:///run/containerd/containerd.sock \
      pull "${HEADLAMP_IMAGE}"
  elif command -v ctr >/dev/null 2>&1; then
    warn "crictl não foi encontrado; usando ctr como fallback para pré-baixar a imagem."
    retry 3 5 ctr --namespace k8s.io images pull "${HEADLAMP_IMAGE}"
  else
    return 1
  fi
}

if check_requested "${1:-}"; then
  if dashboard_state_ok; then
    exit 0
  fi
  exit 1
fi

require_command openssl
require_command sed
require_command sha256sum
install -d -o root -g root -m 0700 "${cert_dir}"

if [[ ! -s "${cert_dir}/ca.crt" || ! -s "${cert_dir}/ca.key" ]]; then
  log "Criando autoridade certificadora local para o Dashboard."
  openssl genrsa -out "${cert_dir}/ca.key" 4096
  openssl req -x509 -new -sha256 \
    -key "${cert_dir}/ca.key" \
    -out "${cert_dir}/ca.crt" \
    -days 3650 \
    -subj "/CN=k8s-dashboard-local-ca"
fi

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
  rm -f -- "${cert_dir}/server.csr"
fi

chmod 0600 "${cert_dir}/ca.key" "${cert_dir}/tls.key"
chmod 0644 "${cert_dir}/ca.crt" "${cert_dir}/tls.crt" "${cert_dir}/server.sans"

log "Garantindo que a imagem ${HEADLAMP_IMAGE} esteja disponível no containerd."
pull_dashboard_image \
  || die "não foi possível baixar ${HEADLAMP_IMAGE}; verifique DNS, proxy e acesso a ghcr.io."

if [[ -n "${previous_dashboard_namespace}" \
  && "${previous_dashboard_namespace}" != "${DASHBOARD_NAMESPACE}" \
  && "${previous_dashboard_namespace}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
  if { kube -n "${previous_dashboard_namespace}" get deployment headlamp \
      -o jsonpath='{.metadata.labels.app\.kubernetes\.io/name}' 2>/dev/null \
      || kube -n "${previous_dashboard_namespace}" get service headlamp \
      -o jsonpath='{.metadata.labels.app\.kubernetes\.io/name}' 2>/dev/null; } | grep -Fxq headlamp; then
    warn "namespace do Dashboard mudou; removendo somente os recursos Headlamp gerenciados no namespace anterior ${previous_dashboard_namespace}."
    kube -n "${previous_dashboard_namespace}" delete \
      deployment/headlamp service/headlamp serviceaccount/headlamp secret/headlamp-tls \
      --ignore-not-found=true --wait=true --timeout=2m
  fi
fi

kube create namespace "${DASHBOARD_NAMESPACE}" --dry-run=client -o yaml | kube apply -f -
kube -n "${DASHBOARD_NAMESPACE}" create secret tls headlamp-tls \
  --cert="${cert_dir}/tls.crt" \
  --key="${cert_dir}/tls.key" \
  --dry-run=client -o yaml | kube apply -f -

if is_true "${ENABLE_OIDC}"; then
  oidc_secret_file="$(mktemp)"
  chmod 0600 "${oidc_secret_file}"
  printf '%s' "${HEADLAMP_OIDC_CLIENT_SECRET}" >"${oidc_secret_file}"
  kube -n "${DASHBOARD_NAMESPACE}" create secret generic headlamp-oidc \
    --from-file=client-secret="${oidc_secret_file}" \
    --dry-run=client -o yaml | kube apply -f -
  if [[ -n "${OIDC_CA_FILE}" ]]; then
    kube -n "${DASHBOARD_NAMESPACE}" create configmap headlamp-oidc-ca \
      --from-file=keycloak-ca.crt="${OIDC_CA_FILE}" \
      --dry-run=client -o yaml | kube apply -f -
  else
    kube -n "${DASHBOARD_NAMESPACE}" delete configmap headlamp-oidc-ca \
      --ignore-not-found=true >/dev/null
  fi
else
  kube -n "${DASHBOARD_NAMESPACE}" delete secret headlamp-oidc \
    --ignore-not-found=true >/dev/null
  kube -n "${DASHBOARD_NAMESPACE}" delete configmap headlamp-oidc-ca \
    --ignore-not-found=true >/dev/null
fi

rendered_manifest="$(mktemp)"
base_manifest="$(mktemp)"
oidc_env_fragment="$(mktemp)"
oidc_volume_mount_fragment="$(mktemp)"
oidc_volume_fragment="$(mktemp)"
checksum="$(tls_checksum)"
oidc_config_checksum="$(oidc_checksum)"
sed \
  -e "s|__NAMESPACE__|${DASHBOARD_NAMESPACE}|g" \
  -e "s|__NODE_PORT__|${DASHBOARD_NODE_PORT}|g" \
  -e "s|__HEADLAMP_IMAGE__|${HEADLAMP_IMAGE}|g" \
  -e "s|__TLS_CHECKSUM__|${checksum}|g" \
  -e "s|__OIDC_CHECKSUM__|${oidc_config_checksum}|g" \
  "${PROJECT_DIR}/manifests/dashboard/headlamp.yaml" >"${base_manifest}"

if is_true "${ENABLE_OIDC}"; then
  cat >"${oidc_env_fragment}" <<EOF
          env:
            - name: HEADLAMP_CONFIG_OIDC_CLIENT_ID
              value: "${OIDC_CLIENT_ID}"
            - name: HEADLAMP_CONFIG_OIDC_CLIENT_SECRET
              valueFrom:
                secretKeyRef:
                  name: headlamp-oidc
                  key: client-secret
            - name: HEADLAMP_CONFIG_OIDC_IDP_ISSUER_URL
              value: "${OIDC_ISSUER_URL}"
            - name: HEADLAMP_CONFIG_OIDC_SCOPES
              value: "${HEADLAMP_OIDC_SCOPES}"
EOF
  if [[ -n "${OIDC_CA_FILE}" ]]; then
    cat >"${oidc_volume_mount_fragment}" <<'EOF'
            - name: oidc-ca
              mountPath: /etc/ssl/certs/keycloak-ca.crt
              subPath: keycloak-ca.crt
              readOnly: true
EOF
    cat >"${oidc_volume_fragment}" <<'EOF'
        - name: oidc-ca
          configMap:
            name: headlamp-oidc-ca
            defaultMode: 0444
EOF
  fi
fi

awk \
  -v env_file="${oidc_env_fragment}" \
  -v mount_file="${oidc_volume_mount_fragment}" \
  -v volume_file="${oidc_volume_fragment}" '
    /__OIDC_ENV__/ {
      while ((getline line < env_file) > 0) print line
      close(env_file)
      next
    }
    /__OIDC_VOLUME_MOUNT__/ {
      while ((getline line < mount_file) > 0) print line
      close(mount_file)
      next
    }
    /__OIDC_VOLUME__/ {
      while ((getline line < volume_file) > 0) print line
      close(volume_file)
      next
    }
    { print }
  ' "${base_manifest}" >"${rendered_manifest}"

if headlamp_workload_needs_recreation; then
  remove_headlamp_workload
fi

log "Reconciliando Dashboard Headlamp como Deployment e NodePort HTTPS."
if ! kube apply -f "${rendered_manifest}"; then
  if kube -n "${DASHBOARD_NAMESPACE}" get deployment headlamp \
    -o jsonpath='{.metadata.labels.app\.kubernetes\.io/name}' 2>/dev/null | grep -Fxq headlamp; then
    warn "Deployment Headlamp gerenciado possui campo imutável incompatível; recriando somente esse Deployment."
    kube -n "${DASHBOARD_NAMESPACE}" delete deployment headlamp --wait=true --timeout=2m
    kube apply -f "${rendered_manifest}"
  else
    die "não foi possível aplicar o manifesto do Headlamp e o recurso existente não foi reconhecido como gerenciado."
  fi
fi
if ! wait_for_headlamp; then
  dashboard_diagnostics
  die "Headlamp não ficou pronto em ${DASHBOARD_ROLLOUT_TIMEOUT}; veja o diagnóstico acima."
fi

primary_group="$(id -gn "${ADMIN_USER}")"
admin_home="$(getent passwd "${ADMIN_USER}" | cut -d: -f6)"
install -d -o "${ADMIN_USER}" -g "${primary_group}" -m 0700 "${admin_home}/.kube"
install -o "${ADMIN_USER}" -g "${primary_group}" -m 0644 \
  "${cert_dir}/ca.crt" "${admin_home}/.kube/headlamp-ca.crt"

dashboard_state_ok || die "o Dashboard foi aplicado, mas a verificação de estado ainda falha."
log "Dashboard instalado em https://${node_ip}:${DASHBOARD_NODE_PORT}/?lng=${DASHBOARD_DEFAULT_LANGUAGE}."
