#!/usr/bin/env bash
# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
require_root
validate_config
if ! check_requested "${1:-}"; then install -d -m 0750 "${RANCHER_DATA_DIR}/data"; fi
image="rancher/rancher:${RANCHER_VERSION}"
if docker container inspect "${RANCHER_CONTAINER_NAME}" >/dev/null 2>&1; then
  # Inspect actual image, data, privilege and port binding before adopting a rerun.
  docker inspect "${RANCHER_CONTAINER_NAME}" | python3 -c '
import json,sys
c=json.load(sys.stdin)[0]; name,image,data,port,ca=sys.argv[1:]
assert c["Config"]["Image"] == image, "Imagem existente difere; upgrade exige backup e procedimento dedicado."
assert c["HostConfig"]["Privileged"], "Container existente não é privileged."
assert c["HostConfig"]["RestartPolicy"]["Name"] == "unless-stopped", "Restart policy diferente."
mounts={m["Destination"]:m for m in c["Mounts"]}
assert mounts.get("/var/lib/rancher",{}).get("Source") == data and mounts["/var/lib/rancher"].get("RW"), "Dados persistentes divergem."
assert set(c["HostConfig"]["PortBindings"]) == {"80/tcp"}, "Outra porta do container foi publicada."
bindings=c["HostConfig"]["PortBindings"].get("80/tcp",[])
assert bindings == [{"HostIp":"127.0.0.1","HostPort":port}], "Backend existente deve publicar apenas em loopback."
if ca: assert mounts.get("/etc/rancher/ssl/cacerts.pem",{}).get("Source") == ca and not mounts["/etc/rancher/ssl/cacerts.pem"].get("RW"), "CA existente diverge."
else: assert "--no-cacerts" in c["Config"]["Cmd"], "Container existente mantém CA privada."
' "${RANCHER_CONTAINER_NAME}" "${image}" "${RANCHER_DATA_DIR}/data" "${RANCHER_BACKEND_PORT}" "${TLS_CA_FILE}" \
    || die 'Container existente incompatível; dados e container preservados.'
  if check_requested "${1:-}"; then
    [[ "$(docker inspect -f '{{.State.Running}}' "${RANCHER_CONTAINER_NAME}")" == true ]] || die 'Container existente parado.'
    exit 0
  fi
  docker start "${RANCHER_CONTAINER_NAME}" >/dev/null
  log 'Container Rancher existente preservado.'
  exit 0
fi
check_requested "${1:-}" && die 'Container Rancher ainda não foi criado.'
docker pull "${image}"
arguments=(run -d --name "${RANCHER_CONTAINER_NAME}" --hostname "${RANCHER_CONTAINER_NAME}" --restart unless-stopped --privileged
  -e TZ=America/Sao_Paulo -v /etc/localtime:/etc/localtime:ro
  -p "127.0.0.1:${RANCHER_BACKEND_PORT}:80" -v "${RANCHER_DATA_DIR}/data:/var/lib/rancher")
if [[ -n "${TLS_CA_FILE}" ]]; then
  arguments+=(-v "${TLS_CA_FILE}:/etc/rancher/ssl/cacerts.pem:ro" -e CATTLE_AGENT_TLS_MODE=strict)
else
  arguments+=(-e CATTLE_AGENT_TLS_MODE=system-store)
fi
arguments+=("${image}")
if [[ -z "${TLS_CA_FILE}" ]]; then arguments+=(--no-cacerts); fi
docker "${arguments[@]}" >/dev/null
log 'Rancher iniciado com armazenamento persistente e backend restrito ao loopback.'
