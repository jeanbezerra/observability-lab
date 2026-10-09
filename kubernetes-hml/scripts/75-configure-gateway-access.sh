#!/usr/bin/env bash

# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_root
require_command python3
require_command curl

readonly external_service_name="hml-gateway-external"
temporary_dir="$(mktemp -d /tmp/k8s-hml-gateway-access.XXXXXX)"
cleanup() {
  if [[ "${temporary_dir}" == /tmp/k8s-hml-gateway-access.* && -d "${temporary_dir}" ]]; then
    rm -rf -- "${temporary_dir}"
  fi
}
trap cleanup EXIT

load_gateway_source() {
  local selector records=()
  selector="gateway.envoyproxy.io/owning-gateway-namespace=${GATEWAY_NAMESPACE},gateway.envoyproxy.io/owning-gateway-name=${GATEWAY_NAME}"
  mapfile -t records < <(kube get service -A -l "${selector}" \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"\n"}{end}' 2>/dev/null)
  [[ "${#records[@]}" -eq 1 ]] || {
    check_pending "esperado exatamente um Service Envoy gerenciado; encontrados: ${#records[@]}."
    return 1
  }
  IFS='|' read -r service_namespace source_service_name <<<"${records[0]}"
  kube -n "${service_namespace}" get service "${source_service_name}" -o json >"${temporary_dir}/source.json" || return 1
  python3 - "${temporary_dir}/source.json" "${temporary_dir}/desired.json" \
    "${external_service_name}" "${GATEWAY_LISTENER_PORT}" "${GATEWAY_NODE_PORT}" <<'PY'
import json
import sys

source_file, desired_file, name, listener, node_port = sys.argv[1:]
with open(source_file, encoding="utf-8") as stream:
    source = json.load(stream)
spec = source["spec"]
ports = [port for port in spec.get("ports", [])
         if port["port"] == int(listener) and port.get("protocol", "TCP") == "TCP"]
if spec.get("type") != "ClusterIP" or not spec.get("selector") or len(ports) != 1:
    sys.exit("Service Envoy precisa ser ClusterIP, ter selector e uma porta HTTP correspondente.")
source_port = ports[0]
port = {"name": source_port.get("name", "http"), "protocol": "TCP",
        "port": source_port["port"],
        "targetPort": source_port.get("targetPort", source_port["port"]),
        "nodePort": int(node_port)}
if "appProtocol" in source_port:
    port["appProtocol"] = source_port["appProtocol"]
desired = {
    "apiVersion": "v1", "kind": "Service",
    "metadata": {"name": name, "namespace": source["metadata"]["namespace"],
                 "labels": {"app.kubernetes.io/managed-by": "kubernetes-hml",
                            "app.kubernetes.io/name": "hml-gateway-external"}},
    "spec": {"type": "NodePort", "externalTrafficPolicy": "Cluster",
             "selector": spec["selector"], "ports": [port]}}
with open(desired_file, "w", encoding="utf-8") as stream:
    json.dump(desired, stream)
PY
}

read_external_service() {
  kube -n "${service_namespace}" get service "${external_service_name}" \
    --ignore-not-found -o json >"${temporary_dir}/existing.json"
}

external_service_state_ok() {
  [[ -s "${temporary_dir}/existing.json" ]] || {
    check_pending "Service externo ${service_namespace}/${external_service_name} ausente."
    return 1
  }
  python3 - "${temporary_dir}/desired.json" "${temporary_dir}/existing.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    desired = json.load(stream)
with open(sys.argv[2], encoding="utf-8") as stream:
    existing = json.load(stream)
if existing["metadata"].get("labels", {}).get("app.kubernetes.io/managed-by") != "kubernetes-hml":
    sys.exit("Service externo não é gerenciado por kubernetes-hml.")
spec = existing["spec"]
if not spec.get("clusterIP") or spec["clusterIP"] == "None":
    sys.exit("Service externo não possui ClusterIP alocado.")
for key in ("type", "externalTrafficPolicy", "selector"):
    if spec.get(key) != desired["spec"][key]:
        sys.exit(f"Service externo diverge no campo {key}.")
ports = spec.get("ports", [])
if len(ports) != 1:
    sys.exit("Service externo precisa ter exatamente uma porta.")
expected_port = desired["spec"]["ports"][0]
if ports[0] != expected_port:
    sys.exit("Service externo diverge em port, targetPort, nodePort ou protocolo HTTP.")
PY
}

gateway_http_ok() {
  local response_code
  response_code="$(curl --noproxy '*' --silent --show-error \
    --connect-timeout 5 --max-time 10 --output /dev/null --write-out '%{http_code}' \
    "http://${NODE_IP}:${GATEWAY_NODE_PORT}/")" || return 1
  # Sem HTTPRoute instalada, a resposta normal do dataplane é HTTP 404.
  case "${response_code}" in
    2??|3??|4??) return 0 ;;
    *) check_pending "Envoy respondeu HTTP ${response_code}; esperado serviço HTTP disponível."; return 1 ;;
  esac
}

gateway_access_state_ok() {
  load_gateway_source || return 1
  read_external_service || return 1
  external_service_state_ok || return 1
  gateway_http_ok
}

if check_requested "${1:-}"; then
  if gateway_access_state_ok; then
    exit 0
  fi
  exit 1
fi

bash "${SCRIPTS_DIR}/55-install-gateway.sh" --check \
  || die "Gateway ainda não está pronto; reconcilie a etapa 55 antes de publicar o NodePort."
load_gateway_source || die "não foi possível determinar o Service Envoy do Gateway HML."
read_external_service || die "não foi possível consultar o Service externo do Gateway."

if [[ ! -s "${temporary_dir}/existing.json" ]]; then
  kube create -f "${temporary_dir}/desired.json"
else
  # JSON merge patch remove selectors extras e substitui a lista de portas, mantendo clusterIP,
  # clusterIPs e demais campos alocados pelo API server. resourceVersion impede
  # que uma alteração concorrente seja sobrescrita silenciosamente.
  python3 - "${temporary_dir}/desired.json" "${temporary_dir}/existing.json" \
    "${temporary_dir}/patch.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    desired = json.load(stream)
with open(sys.argv[2], encoding="utf-8") as stream:
    existing = json.load(stream)
metadata = existing["metadata"]
if metadata.get("labels", {}).get("app.kubernetes.io/managed-by") != "kubernetes-hml":
    sys.exit("Service externo já existe e não é gerenciado por kubernetes-hml; alteração recusada.")
if existing["spec"].get("clusterIP") == "None":
    sys.exit("Service externo é headless; alteração recusada para preservar seu ClusterIP imutável.")
patch_spec = desired["spec"]
patch_spec["selector"] = {
    **{key: None for key in existing["spec"].get("selector", {})
       if key not in desired["spec"]["selector"]},
    **desired["spec"]["selector"]}
for stale_field in ("externalName", "healthCheckNodePort", "allocateLoadBalancerNodePorts",
                    "loadBalancerIP", "loadBalancerSourceRanges", "loadBalancerClass"):
    if stale_field in existing["spec"]:
        patch_spec[stale_field] = None
patch = {"metadata": {"resourceVersion": metadata["resourceVersion"],
                      "labels": desired["metadata"]["labels"]}, "spec": patch_spec}
with open(sys.argv[3], "w", encoding="utf-8") as stream:
    json.dump(patch, stream)
PY
  if ! external_service_state_ok; then
    kube -n "${service_namespace}" patch service "${external_service_name}" \
      --type=merge --patch-file "${temporary_dir}/patch.json"
  fi
fi

retry 6 3 gateway_access_state_ok \
  || die "Gateway não respondeu em http://${NODE_IP}:${GATEWAY_NODE_PORT}; confira a rede da VM e TCP/${GATEWAY_NODE_PORT}."
log "Gateway HML publicado em http://${NODE_IP}:${GATEWAY_NODE_PORT}, preservando o Service Envoy ${service_namespace}/${source_service_name}."
