#!/usr/bin/env bash

# O YAML de importação contém credenciais. Nunca habilite xtrace neste script.
set +x
# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_root
[[ $# -le 1 && ( $# -eq 0 || "${1}" == "--check" ) ]] \
  || die "Uso: sudo bash scripts/80-register-rancher.sh [--check]"

RANCHER_URL="${RANCHER_URL:-}"
RANCHER_URL="${RANCHER_URL%/}"
RANCHER_VERSION="${RANCHER_VERSION:-v2.15.2}"
RANCHER_IMPORT_MANIFEST="${RANCHER_IMPORT_MANIFEST:-}"
RANCHER_CA_FILE="${RANCHER_CA_FILE:-}"
RANCHER_ROLLOUT_TIMEOUT="${RANCHER_ROLLOUT_TIMEOUT:-${CLUSTER_OPERATION_TIMEOUT}}"
readonly import_hash_file="${BOOTSTRAP_STATE_DIR}/rancher-import.sha256"

valid_https_url "${RANCHER_URL}" \
  || die "RANCHER_URL deve ser HTTPS com hostname/IP e porta opcional, sem credenciais, caminho ou query."
[[ "${RANCHER_VERSION}" =~ ^v?([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] \
  || die "RANCHER_VERSION deve informar uma versão estável, por exemplo v2.15.2."
version_major=$((10#${BASH_REMATCH[1]}))
version_minor=$((10#${BASH_REMATCH[2]}))
version_patch=$((10#${BASH_REMATCH[3]}))
(( version_major > 2 || (version_major == 2 && version_minor > 15) \
  || (version_major == 2 && version_minor == 15 && version_patch >= 2) )) \
  || die "Use Rancher v2.15.2 ou superior compatível com Kubernetes ${KUBERNETES_MINOR}; confira a matriz da release."

require_command python3
require_command sha256sum
require_command kubectl
temporary_dir="$(mktemp -d)"
trap 'rm -f -- "${temporary_dir}/live.json" "${temporary_dir}/desired.json" "${temporary_dir}/hash"; rmdir -- "${temporary_dir}"' EXIT

# kubectl pode emitir um List ou vários documentos JSON concatenados. O parser
# usa apenas a biblioteca padrão e jamais imprime recursos, envs ou Secrets.
inspect_agent_json() {
  local mode="$1" file="$2"
  python3 - "${mode}" "${file}" "${RANCHER_URL}" "${RANCHER_VERSION}" <<'PY'
import json
import re
import sys

mode, filename, wanted_url, wanted_version = sys.argv[1:]

def reject(message):
    print(message, file=sys.stderr)
    sys.exit(1)

try:
    text = open(filename, encoding="utf-8").read()
    decoder = json.JSONDecoder()
    objects = []
    while text.strip():
        document, end = decoder.raw_decode(text.lstrip())
        text = text.lstrip()[end:]
        objects.extend(document.get("items", []) if document.get("kind") == "List" else [document])
except (OSError, ValueError, TypeError, AttributeError):
    reject("Não foi possível interpretar o manifesto/estado do agente; detalhes omitidos para proteger credenciais.")

allowed_kinds = {"Namespace", "ServiceAccount", "Secret", "ConfigMap", "Service",
                 "ClusterRole", "ClusterRoleBinding", "Role", "RoleBinding", "Deployment", "DaemonSet"}
if mode == "manifest":
    for resource in objects:
        kind = resource.get("kind", "")
        metadata = resource.get("metadata", {})
        if kind not in allowed_kinds:
            reject("O arquivo deve conter somente o manifesto padrão de importação Generic, sem workloads adicionais.")
        if kind == "Namespace" and metadata.get("name") != "cattle-system":
            reject("O manifesto de importação deve usar somente o namespace cattle-system.")
        if kind not in {"Namespace", "ClusterRole", "ClusterRoleBinding"} and metadata.get("namespace") != "cattle-system":
            reject("Um recurso do manifesto não pertence a cattle-system; não será aplicado.")
        if kind in {"Deployment", "DaemonSet"}:
            name = metadata.get("name")
            if (kind, name) not in {("Deployment", "cattle-cluster-agent"), ("DaemonSet", "cattle-node-agent")}:
                reject("O arquivo contém outro workload; esta etapa nunca instala o servidor Rancher.")
            pod_spec = resource.get("spec", {}).get("template", {}).get("spec", {})
            for container in pod_spec.get("containers", []) + pod_spec.get("initContainers", []):
                image_name = container.get("image", "").split("@", 1)[0].rsplit("/", 1)[-1].split(":", 1)[0]
                if image_name != "rancher-agent":
                    reject("Os workloads de importação devem executar apenas rancher-agent, nunca o servidor Rancher.")
            workload_servers = [env.get("value", "").rstrip("/") for container in pod_spec.get("containers", [])
                                for env in container.get("env", []) if env.get("name") == "CATTLE_SERVER"]
            if workload_servers != [wanted_url]:
                reject("CATTLE_SERVER de um workload do manifesto difere de RANCHER_URL; arquivo não será aplicado.")

agents = [resource for resource in objects if resource.get("kind") == "Deployment"
          and resource.get("metadata", {}).get("name") == "cattle-cluster-agent"]
if len(agents) != 1:
    reject("O manifesto/estado deve conter exatamente um Deployment cattle-cluster-agent.")
agent = agents[0]
if agent.get("metadata", {}).get("namespace") != "cattle-system":
    reject("O Deployment cattle-cluster-agent deve pertencer a cattle-system.")
containers = agent.get("spec", {}).get("template", {}).get("spec", {}).get("containers", [])
servers = [env.get("value", "").rstrip("/") for container in containers
           for env in container.get("env", []) if env.get("name") == "CATTLE_SERVER"]
if servers != [wanted_url]:
    reject("CATTLE_SERVER do agente difere de RANCHER_URL; registro existente não será redirecionado.")
agent_containers = [container for container in containers
                    if any(env.get("name") == "CATTLE_SERVER" for env in container.get("env", []))]
image = agent_containers[0].get("image", "")
image_without_digest = image.split("@", 1)[0]
if image_without_digest.rsplit("/", 1)[-1].split(":", 1)[0] != "rancher-agent":
    reject("A imagem de cattle-cluster-agent deve ser rancher-agent; servidor Rancher não será instalado.")
tag = image_without_digest.rsplit("/", 1)[-1].partition(":")[2]
if tag:
    match = re.fullmatch(r"v?(\d+)\.(\d+)\.(\d+)", tag)
    if not match or tuple(map(int, match.groups())) < (2, 15, 2):
        reject("A imagem do agente deve usar uma release estável Rancher v2.15.2 ou superior compatível com o cluster.")
    if mode == "manifest" and tag.lstrip("v") != wanted_version.lstrip("v"):
        reject("A versão da imagem no manifesto difere de RANCHER_VERSION; confirme About no servidor e ajuste a configuração.")
elif "@sha256:" not in image:
    reject("A imagem do agente deve informar versão estável ou digest explícito.")
PY
}

validate_rancher_endpoint() {
  local ping_response
  local -a curl_options=(--fail --silent --show-error --proto '=https' --connect-timeout 15 --max-time 30)
  require_command curl
  if [[ -n "${RANCHER_CA_FILE}" ]]; then
    [[ -f "${RANCHER_CA_FILE}" && -r "${RANCHER_CA_FILE}" ]] \
      || die "RANCHER_CA_FILE deve apontar para a cadeia CA pública local em PEM."
    curl_options+=(--cacert "${RANCHER_CA_FILE}")
  fi
  if ! ping_response="$(curl "${curl_options[@]}" "${RANCHER_URL}/ping" 2>/dev/null)" \
    || [[ "${ping_response}" != "pong" ]]; then
    die "Rancher não respondeu pong em /ping com TLS válido; verifique DNS, saída HTTPS e a cadeia CA."
  fi
  log "Endpoint /ping do Rancher externo validado com TLS; versão declarada ${RANCHER_VERSION}, a conferir em About."
}

print_import_instructions() {
  check_pending "PENDENTE: importação Generic ainda não configurada; cluster continua operacional."
  log "No Rancher externo: Cluster Management > Import Existing > Generic; crie o cluster HML."
  log "Confirme a versão real em About e ajuste RANCHER_VERSION; referência verificada: v2.15.2."
  log "CA pública: Global Settings > agent-tls-mode = system-store; strict também exige cacerts preenchido no Rancher."
  log "CA privada: configure strict e a cadeia em cacerts no servidor Rancher; RANCHER_CA_FILE só valida TLS no host desta VM."
  log "Salve o YAML da URL de importação fornecida pela UI em arquivo local protegido (chmod 600); não versione URL, token ou YAML."
  log "Defina RANCHER_IMPORT_MANIFEST com o caminho absoluto no cluster.env e execute novamente sudo bash install-all.sh cluster.env."
}

agent_exists=false
if ! kube -n cattle-system get deployment cattle-cluster-agent --ignore-not-found \
  -o json >"${temporary_dir}/live.json" 2>/dev/null; then
  die "Não foi possível consultar cattle-cluster-agent; valide a API antes de tentar importar."
fi
if [[ -s "${temporary_dir}/live.json" ]]; then
  agent_exists=true
  if ! inspection_error="$(inspect_agent_json live "${temporary_dir}/live.json" 2>&1)"; then
    die "${inspection_error}"
  fi
fi

if ! check_requested "${1:-}"; then
  validate_rancher_endpoint
fi

if [[ -z "${RANCHER_IMPORT_MANIFEST}" && "${agent_exists}" == "false" ]]; then
  print_import_instructions
  exit 0
fi

manifest_hash=""
if [[ -n "${RANCHER_IMPORT_MANIFEST}" ]]; then
  [[ -f "${RANCHER_IMPORT_MANIFEST}" && -r "${RANCHER_IMPORT_MANIFEST}" ]] \
    || die "RANCHER_IMPORT_MANIFEST deve apontar para um arquivo YAML local legível."
  # Não deixe kubectl imprimir erros contendo o manifesto ou dados de Secrets.
  if ! kube create --dry-run=client --validate=false -f "${RANCHER_IMPORT_MANIFEST}" \
    -o json >"${temporary_dir}/desired.json" 2>/dev/null; then
    die "YAML de importação inválido; mensagem do kubectl omitida para proteger credenciais. Revise o arquivo local."
  fi
  if ! inspection_error="$(inspect_agent_json manifest "${temporary_dir}/desired.json" 2>&1)"; then
    die "${inspection_error}"
  fi
  manifest_hash="$(sha256sum -- "${RANCHER_IMPORT_MANIFEST}" | awk '{print $1}')"
fi

if check_requested "${1:-}"; then
  [[ "${agent_exists}" == "true" ]] || { check_pending "Deployment cattle-cluster-agent ainda não existe."; exit 1; }
  if [[ -n "${manifest_hash}" ]] \
    && { [[ ! -r "${import_hash_file}" ]] || [[ "$(cat -- "${import_hash_file}")" != "${manifest_hash}" ]]; }; then
    check_pending "O manifesto local ainda não foi aplicado/validado por esta variante."
    exit 1
  fi
  kube -n cattle-system rollout status deployment/cattle-cluster-agent --timeout=15s >/dev/null 2>&1 \
    || { check_pending "Agente Rancher ainda não está pronto."; exit 1; }
  log "Agente pronto e CATTLE_SERVER validado; confirme estado Active em Cluster Management no Rancher."
  exit 0
fi

if [[ -n "${RANCHER_IMPORT_MANIFEST}" ]]; then
  if ! kube apply -f "${RANCHER_IMPORT_MANIFEST}" >/dev/null 2>&1; then
    die "Falha ao aplicar o YAML de importação local; detalhes omitidos para proteger credenciais."
  fi
  log "Manifesto Generic aplicado; aguardando o Deployment cattle-cluster-agent."
fi
kube -n cattle-system rollout status deployment/cattle-cluster-agent \
  --timeout="${RANCHER_ROLLOUT_TIMEOUT}" >/dev/null 2>&1 \
  || die "Agente ainda não ficou pronto. Revise os eventos de cattle-system; não compartilhe logs sem remover credenciais."
kube -n cattle-system get deployment cattle-cluster-agent -o json >"${temporary_dir}/live.json" 2>/dev/null \
  || die "Não foi possível verificar o Deployment após a importação."
if ! inspection_error="$(inspect_agent_json live "${temporary_dir}/live.json" 2>&1)"; then
  die "${inspection_error}"
fi
if [[ -n "${manifest_hash}" ]]; then
  install -d -m 0700 -- "${BOOTSTRAP_STATE_DIR}"
  printf '%s\n' "${manifest_hash}" >"${temporary_dir}/hash"
  install -m 0600 -- "${temporary_dir}/hash" "${import_hash_file}"
fi
log "Agente pronto e destino validado. Rollout não comprova conexão upstream: confirme HML como Active no Rancher."
