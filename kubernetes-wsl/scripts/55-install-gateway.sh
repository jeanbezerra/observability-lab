#!/usr/bin/env bash

# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_root

readonly HELM_SAFE_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/sbin"
readonly ENVOY_CONTROLLER_NAME="gateway.envoyproxy.io/gatewayclass-controller"

helm_local() {
  # Não deixe helpers de credenciais do Rancher/Docker Desktop presentes no
  # PATH do Windows interferirem com pulls OCI anônimos dentro do WSL.
  env PATH="${HELM_SAFE_PATH}" /usr/local/bin/helm "$@"
}

gateway_condition() {
  local resource_kind="$1" resource_namespace="$2" resource_name="$3" condition_type="$4"
  if [[ -n "${resource_namespace}" ]]; then
    kube -n "${resource_namespace}" get "${resource_kind}" "${resource_name}" \
      -o "jsonpath={.status.conditions[?(@.type=='${condition_type}')].status}" 2>/dev/null
  else
    kube get "${resource_kind}" "${resource_name}" \
      -o "jsonpath={.status.conditions[?(@.type=='${condition_type}')].status}" 2>/dev/null
  fi
}

managed_service_record() {
  local selector records=()
  selector="gateway.envoyproxy.io/owning-gateway-namespace=${GATEWAY_NAMESPACE},gateway.envoyproxy.io/owning-gateway-name=${GATEWAY_NAME}"
  mapfile -t records < <(kube get service -A -l "${selector}" \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"|"}{.spec.type}{"|"}{.spec.ports[*].nodePort}{"\n"}{end}' 2>/dev/null)
  [[ "${#records[@]}" -eq 1 ]] || return 1
  printf '%s\n' "${records[0]}"
}

managed_deployment_record() {
  local selector records=()
  selector="gateway.envoyproxy.io/owning-gateway-namespace=${GATEWAY_NAMESPACE},gateway.envoyproxy.io/owning-gateway-name=${GATEWAY_NAME}"
  mapfile -t records < <(kube get deployment -A -l "${selector}" \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"|"}{.spec.replicas}{"|"}{.status.readyReplicas}{"\n"}{end}' 2>/dev/null)
  [[ "${#records[@]}" -eq 1 ]] || return 1
  printf '%s\n' "${records[0]}"
}

gateway_state_ok() {
  local actual actual_image actual_ports bundle_channel bundle_version
  local controller_desired controller_ready deployment_record deployment_namespace deployment_name
  local deployment_desired deployment_ready service_record service_namespace service_name service_type service_nodeports

  [[ -x /usr/local/bin/helm ]] || {
    check_pending "Helm não está instalado."
    return 1
  }
  [[ "$(/usr/local/bin/helm version --template '{{.Version}}' 2>/dev/null || true)" == "${HELM_VERSION}" ]] || {
    check_pending "versão do Helm difere de ${HELM_VERSION}."
    return 1
  }

  for crd_name in \
    gatewayclasses.gateway.networking.k8s.io \
    gateways.gateway.networking.k8s.io \
    httproutes.gateway.networking.k8s.io \
    grpcroutes.gateway.networking.k8s.io \
    referencegrants.gateway.networking.k8s.io \
    backendtlspolicies.gateway.networking.k8s.io \
    envoyproxies.gateway.envoyproxy.io \
    backendtrafficpolicies.gateway.envoyproxy.io; do
    kube get crd "${crd_name}" >/dev/null 2>&1 || {
      check_pending "CRD ausente: ${crd_name}."
      return 1
    }
  done

  bundle_version="$(kube get crd gateways.gateway.networking.k8s.io \
    -o go-template='{{ index .metadata.annotations "gateway.networking.k8s.io/bundle-version" }}' 2>/dev/null)"
  bundle_channel="$(kube get crd gateways.gateway.networking.k8s.io \
    -o go-template='{{ index .metadata.annotations "gateway.networking.k8s.io/channel" }}' 2>/dev/null)"
  [[ "${bundle_version}" == "${GATEWAY_API_VERSION}" && "${bundle_channel}" == "standard" ]] || {
    check_pending "Gateway API esperado: ${GATEWAY_API_VERSION}/standard; encontrado: ${bundle_version:-ausente}/${bundle_channel:-ausente}."
    return 1
  }

  kube -n "${ENVOY_GATEWAY_NAMESPACE}" get deployment envoy-gateway >/dev/null 2>&1 || {
    check_pending "Deployment do Envoy Gateway não existe."
    return 1
  }
  actual="$(kube -n "${ENVOY_GATEWAY_NAMESPACE}" get deployment envoy-gateway \
    -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}:{.metadata.annotations.meta\.helm\.sh/release-namespace}' 2>/dev/null)"
  [[ "${actual}" == "${ENVOY_GATEWAY_RELEASE}:${ENVOY_GATEWAY_NAMESPACE}" ]] || {
    check_pending "Deployment envoy-gateway não pertence à release Helm configurada."
    return 1
  }
  actual_image="$(kube -n "${ENVOY_GATEWAY_NAMESPACE}" get deployment envoy-gateway \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="envoy-gateway")].image}' 2>/dev/null)"
  [[ "${actual_image}" == "docker.io/envoyproxy/gateway:${ENVOY_GATEWAY_VERSION}" ]] || {
    check_pending "imagem do Envoy Gateway difere de ${ENVOY_GATEWAY_VERSION}: ${actual_image:-ausente}."
    return 1
  }
  actual="$(kube -n "${ENVOY_GATEWAY_NAMESPACE}" get deployment envoy-gateway \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="envoy-gateway")].resources.requests.cpu}:{.spec.template.spec.containers[?(@.name=="envoy-gateway")].resources.requests.memory}:{.spec.template.spec.containers[?(@.name=="envoy-gateway")].resources.limits.cpu}:{.spec.template.spec.containers[?(@.name=="envoy-gateway")].resources.limits.memory}' 2>/dev/null)"
  [[ "${actual}" == "50m:128Mi:500m:512Mi" ]] || {
    check_pending "recursos do control plane Envoy Gateway diferem do perfil enxuto."
    return 1
  }
  actual="$(kube -n "${ENVOY_GATEWAY_NAMESPACE}" get service envoy-gateway \
    -o jsonpath='{.spec.type}:{.spec.ports[*].nodePort}' 2>/dev/null)"
  [[ "${actual// /}" == "ClusterIP:" ]] || {
    check_pending "Service do control plane Envoy Gateway não está limitado a ClusterIP."
    return 1
  }
  read -r controller_desired controller_ready < <(kube -n "${ENVOY_GATEWAY_NAMESPACE}" \
    get deployment envoy-gateway -o jsonpath='{.spec.replicas} {.status.readyReplicas}' 2>/dev/null)
  [[ "${controller_desired}" == "1" && "${controller_ready}" == "1" ]] || {
    check_pending "control plane do Envoy Gateway ainda não está pronto."
    return 1
  }

  actual="$(kube get gatewayclass "${GATEWAY_CLASS_NAME}" -o jsonpath='{.spec.controllerName}' 2>/dev/null)"
  [[ "${actual}" == "${ENVOY_CONTROLLER_NAME}" ]] || return 1
  actual="$(kube get gatewayclass "${GATEWAY_CLASS_NAME}" \
    -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null)"
  [[ "${actual}" == "kubernetes-wsl" ]] || return 1
  actual="$(kube get gatewayclass "${GATEWAY_CLASS_NAME}" \
    -o jsonpath='{.spec.parametersRef.group}/{.spec.parametersRef.kind}/{.spec.parametersRef.namespace}/{.spec.parametersRef.name}' 2>/dev/null)"
  [[ "${actual}" == "gateway.envoyproxy.io/EnvoyProxy/${ENVOY_GATEWAY_NAMESPACE}/${ENVOY_PROXY_NAME}" ]] || return 1
  [[ "$(gateway_condition gatewayclass '' "${GATEWAY_CLASS_NAME}" Accepted)" == "True" ]] || {
    check_pending "GatewayClass ${GATEWAY_CLASS_NAME} ainda não foi aceita."
    return 1
  }

  actual="$(kube -n "${ENVOY_GATEWAY_NAMESPACE}" get envoyproxy "${ENVOY_PROXY_NAME}" \
    -o jsonpath='{.spec.provider.kubernetes.envoyService.type}' 2>/dev/null)"
  [[ "${actual}" == "ClusterIP" ]] || {
    check_pending "EnvoyProxy não está limitado a Service ClusterIP."
    return 1
  }
  actual="$(kube -n "${ENVOY_GATEWAY_NAMESPACE}" get envoyproxy "${ENVOY_PROXY_NAME}" \
    -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null)"
  [[ "${actual}" == "kubernetes-wsl" ]] || return 1
  actual="$(kube -n "${ENVOY_GATEWAY_NAMESPACE}" get envoyproxy "${ENVOY_PROXY_NAME}" \
    -o jsonpath='{.spec.provider.kubernetes.envoyDeployment.container.resources.requests.cpu}:{.spec.provider.kubernetes.envoyDeployment.container.resources.requests.memory}:{.spec.provider.kubernetes.envoyDeployment.container.resources.limits.cpu}:{.spec.provider.kubernetes.envoyDeployment.container.resources.limits.memory}' 2>/dev/null)"
  [[ "${actual}" == "50m:128Mi:500m:512Mi" ]] || {
    check_pending "recursos do dataplane Envoy diferem do perfil enxuto."
    return 1
  }

  actual="$(kube -n "${GATEWAY_NAMESPACE}" get gateway "${GATEWAY_NAME}" \
    -o jsonpath='{.spec.gatewayClassName}' 2>/dev/null)"
  [[ "${actual}" == "${GATEWAY_CLASS_NAME}" ]] || return 1
  actual="$(kube -n "${GATEWAY_NAMESPACE}" get gateway "${GATEWAY_NAME}" \
    -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null)"
  [[ "${actual}" == "kubernetes-wsl" ]] || return 1
  actual="$(kube -n "${GATEWAY_NAMESPACE}" get gateway "${GATEWAY_NAME}" \
    -o jsonpath='{.spec.listeners[?(@.name=="http")].protocol}:{.spec.listeners[?(@.name=="http")].port}:{.spec.listeners[?(@.name=="http")].allowedRoutes.namespaces.from}' 2>/dev/null)"
  [[ "${actual}" == "HTTP:${GATEWAY_LISTENER_PORT}:All" ]] || return 1
  [[ "$(gateway_condition gateway "${GATEWAY_NAMESPACE}" "${GATEWAY_NAME}" Programmed)" == "True" ]] || {
    check_pending "Gateway ${GATEWAY_NAMESPACE}/${GATEWAY_NAME} ainda não foi programado."
    return 1
  }

  service_record="$(managed_service_record)" || {
    check_pending "não foi encontrado exatamente um Service gerenciado para o Gateway."
    return 1
  }
  IFS='|' read -r service_namespace service_name service_type service_nodeports <<<"${service_record}"
  [[ "${service_type}" == "ClusterIP" && -z "${service_nodeports// /}" ]] || {
    check_pending "Service ${service_namespace}/${service_name} expõe LoadBalancer ou NodePort."
    return 1
  }
  actual_ports="$(kube -n "${service_namespace}" get service "${service_name}" \
    -o jsonpath='{.spec.ports[*].port}' 2>/dev/null)"
  tr ' ' '\n' <<<"${actual_ports}" | grep -Fxq "${GATEWAY_LISTENER_PORT}" || {
    check_pending "Service do Gateway não publica internamente a porta ${GATEWAY_LISTENER_PORT}."
    return 1
  }

  deployment_record="$(managed_deployment_record)" || {
    check_pending "não foi encontrado exatamente um Deployment Envoy gerenciado para o Gateway."
    return 1
  }
  IFS='|' read -r deployment_namespace deployment_name deployment_desired deployment_ready <<<"${deployment_record}"
  [[ "${deployment_desired}" == "1" && "${deployment_ready}" == "1" ]] || {
    check_pending "dataplane ${deployment_namespace}/${deployment_name} ainda não está pronto."
    return 1
  }
}

if check_requested "${1:-}"; then
  if gateway_state_ok; then
    exit 0
  fi
  exit 1
fi

require_command curl
require_command kubectl
require_command sha256sum
[[ -x /usr/local/bin/helm ]] || die "Helm não está instalado; execute primeiro 52-install-helm.sh."

temporary_dir="$(mktemp -d /tmp/k8s-wsl-gateway.XXXXXX)"
cleanup_temporary_dir() {
  if [[ "${temporary_dir}" == /tmp/k8s-wsl-gateway.* && -d "${temporary_dir}" ]]; then
    rm -rf -- "${temporary_dir}"
  fi
}
trap cleanup_temporary_dir EXIT
registry_config="${temporary_dir}/registry.json"
gateway_chart="${temporary_dir}/gateway-helm-${ENVOY_GATEWAY_VERSION}.tgz"
crds_chart="${temporary_dir}/gateway-crds-helm-${ENVOY_GATEWAY_VERSION}.tgz"
rendered_crds="${temporary_dir}/gateway-crds.yaml"
rendered_base="${temporary_dir}/gateway-base.yaml"
printf '{}\n' >"${registry_config}"

helm_oci() {
  helm_local "$@" --registry-config "${registry_config}"
}

log "Baixando charts oficiais do Envoy Gateway ${ENVOY_GATEWAY_VERSION}."
retry 3 3 helm_oci pull oci://docker.io/envoyproxy/gateway-crds-helm \
  --version "${ENVOY_GATEWAY_VERSION}" --destination "${temporary_dir}"
retry 3 3 helm_oci pull oci://docker.io/envoyproxy/gateway-helm \
  --version "${ENVOY_GATEWAY_VERSION}" --destination "${temporary_dir}"
printf '%s  %s\n' "${ENVOY_GATEWAY_CRDS_CHART_SHA256}" "${crds_chart}" \
  | sha256sum --check --status || die "checksum do chart de CRDs do Envoy Gateway não confere."
printf '%s  %s\n' "${ENVOY_GATEWAY_CHART_SHA256}" "${gateway_chart}" \
  | sha256sum --check --status || die "checksum do chart principal do Envoy Gateway não confere."

log "Instalando Gateway API ${GATEWAY_API_VERSION} no canal Standard e CRDs do Envoy Gateway."
helm_local template eg-crds "${crds_chart}" \
  --set crds.gatewayAPI.enabled=true \
  --set crds.gatewayAPI.channel=standard \
  --set crds.envoyGateway.enabled=true >"${rendered_crds}"
kube apply --server-side --field-manager=kubernetes-wsl-gateway-crds -f "${rendered_crds}"

for crd_name in \
  gatewayclasses.gateway.networking.k8s.io \
  gateways.gateway.networking.k8s.io \
  httproutes.gateway.networking.k8s.io \
  grpcroutes.gateway.networking.k8s.io \
  referencegrants.gateway.networking.k8s.io \
  backendtlspolicies.gateway.networking.k8s.io \
  envoyproxies.gateway.envoyproxy.io \
  backendtrafficpolicies.gateway.envoyproxy.io; do
  kube wait --for=condition=Established "crd/${crd_name}" --timeout=2m
done

for resource_ref in \
  "gatewayclass||${GATEWAY_CLASS_NAME}" \
  "envoyproxy|${ENVOY_GATEWAY_NAMESPACE}|${ENVOY_PROXY_NAME}" \
  "gateway|${GATEWAY_NAMESPACE}|${GATEWAY_NAME}"; do
  IFS='|' read -r resource_kind resource_namespace resource_name <<<"${resource_ref}"
  if [[ -n "${resource_namespace}" ]]; then
    if ! kube -n "${resource_namespace}" get "${resource_kind}" "${resource_name}" >/dev/null 2>&1; then
      continue
    fi
    existing_label="$(kube -n "${resource_namespace}" get "${resource_kind}" "${resource_name}" \
      -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null)"
  else
    if ! kube get "${resource_kind}" "${resource_name}" >/dev/null 2>&1; then
      continue
    fi
    existing_label="$(kube get "${resource_kind}" "${resource_name}" \
      -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null)"
  fi
  if [[ "${existing_label}" != "kubernetes-wsl" ]]; then
    die "${resource_kind}/${resource_name} já existe e não é gerenciado por kubernetes-wsl."
  fi
done

existing_chart=""
# Na primeira instalação, o namespace do controller ainda não existe.
# O Helm 4 encerra `helm list -n <namespace-ausente>` com código 1; sob
# `set -e -o pipefail`, isso interromperia o script antes que
# `helm upgrade --install --create-namespace` pudesse criá-lo.
if kube get namespace "${ENVOY_GATEWAY_NAMESPACE}" >/dev/null 2>&1; then
  existing_chart="$(helm_local list -n "${ENVOY_GATEWAY_NAMESPACE}" \
    --all --filter "^${ENVOY_GATEWAY_RELEASE}$" --no-headers \
    | awk 'NR == 1 {print $(NF-1)}')"
fi
if [[ -n "${existing_chart}" && "${existing_chart}" != gateway-helm-* ]]; then
  die "a release Helm ${ENVOY_GATEWAY_NAMESPACE}/${ENVOY_GATEWAY_RELEASE} pertence ao chart ${existing_chart}; nada foi alterado nela."
fi

log "Instalando o control plane Envoy Gateway com recursos reduzidos."
helm_local upgrade --install "${ENVOY_GATEWAY_RELEASE}" "${gateway_chart}" \
  --namespace "${ENVOY_GATEWAY_NAMESPACE}" \
  --create-namespace \
  --set crds.enabled=false \
  --values "${PROJECT_DIR}/manifests/gateway/envoy-gateway-values.yaml" \
  --wait --timeout 10m

sed \
  -e "s|__ENVOY_GATEWAY_NAMESPACE__|${ENVOY_GATEWAY_NAMESPACE}|g" \
  -e "s|__ENVOY_PROXY_NAME__|${ENVOY_PROXY_NAME}|g" \
  -e "s|__GATEWAY_CLASS_NAME__|${GATEWAY_CLASS_NAME}|g" \
  -e "s|__GATEWAY_NAMESPACE__|${GATEWAY_NAMESPACE}|g" \
  -e "s|__GATEWAY_NAME__|${GATEWAY_NAME}|g" \
  -e "s|__GATEWAY_LISTENER_PORT__|${GATEWAY_LISTENER_PORT}|g" \
  "${PROJECT_DIR}/manifests/gateway/gateway-base.yaml" >"${rendered_base}"

log "Criando GatewayClass ${GATEWAY_CLASS_NAME} e Gateway HTTP interno ${GATEWAY_NAMESPACE}/${GATEWAY_NAME}."
kube apply --server-side --field-manager=kubernetes-wsl-gateway -f "${rendered_base}"
kube wait --for=condition=Accepted "gatewayclass/${GATEWAY_CLASS_NAME}" --timeout=10m
kube -n "${GATEWAY_NAMESPACE}" wait --for=condition=Programmed \
  "gateway/${GATEWAY_NAME}" --timeout=10m

if deployment_record="$(managed_deployment_record)"; then
  IFS='|' read -r deployment_namespace deployment_name _ _ <<<"${deployment_record}"
  kube -n "${deployment_namespace}" rollout status "deployment/${deployment_name}" --timeout=10m
fi

retry 30 3 gateway_state_ok || {
  kube get gatewayclass "${GATEWAY_CLASS_NAME}" -o yaml >&2 || true
  kube -n "${GATEWAY_NAMESPACE}" describe gateway "${GATEWAY_NAME}" >&2 || true
  kube get deployment,pod,service -A \
    -l "gateway.envoyproxy.io/owning-gateway-name=${GATEWAY_NAME}" -o wide >&2 || true
  die "Gateway API/Envoy Gateway não atingiu o estado esperado."
}

log "Gateway pronto: API Standard, Envoy ClusterIP e nenhuma porta externa aberta."
