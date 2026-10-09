#!/usr/bin/env bash
# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
require_root
validate_config
host_preflight --check
if ! systemctl is-active --quiet docker || ! systemctl is-active --quiet nginx; then die 'Docker/Nginx não estão ativos.'; fi
nginx -t
arguments=(--disable --fail --silent --show-error --proto '=https' --tlsv1.2 --connect-timeout 5 --max-time 15)
if [[ -n "${TLS_CA_FILE}" ]]; then arguments+=(--cacert "${TLS_CA_FILE}"); fi
deadline=$((SECONDS + RANCHER_START_TIMEOUT_SECONDS))
while :; do
  if response="$(curl "${arguments[@]}" "https://${RANCHER_FQDN}/ping" 2>/dev/null)" && [[ "${response}" == pong ]]; then break; fi
  (( SECONDS < deadline )) || die 'Rancher não retornou HTTP 200/pong com TLS e hostname válidos dentro do timeout.'
  sleep 5
done
actual="$(curl "${arguments[@]}" "https://${RANCHER_FQDN}/rancherversion" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Version"])')"
[[ "${actual}" == "${RANCHER_VERSION}" ]] || die "Versão real ${actual} difere da versão configurada."
if [[ -n "${TLS_CA_FILE}" ]]; then
  curl "${arguments[@]}" "https://${RANCHER_FQDN}/v3/settings/cacerts" \
    | python3 -c 'import json,ssl,sys,pathlib,re; data=json.load(sys.stdin); decode=lambda s:[ssl.PEM_cert_to_DER_cert(p) for p in re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----",s,re.S)]; expected=decode(pathlib.Path(sys.argv[1]).read_text()); assert expected and decode(data["value"]) == expected, "CA publicada no Rancher difere da CA configurada"' "${TLS_CA_FILE}"
fi
expected_mode=strict
[[ -n "${TLS_CA_FILE}" ]] || expected_mode=system-store
# This setting may require authentication over HTTP. Read it using the local
# management kubeconfig; do not ask for or log a Rancher admin credential.
actual_mode="$(docker exec "${RANCHER_CONTAINER_NAME}" kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml \
  get settings.management.cattle.io agent-tls-mode -o json \
  | python3 -c 'import json,sys; data=json.load(sys.stdin); print(data.get("value") or data.get("default", ""))')"
[[ "${actual_mode}" == "${expected_mode}" ]] || die "agent-tls-mode=${actual_mode}; esperado ${expected_mode} para a CA configurada."
log "HTTP 200/pong, TLS, hostname e versão ${actual} validados."
log 'Conclua o primeiro acesso pela interface Rancher. O instalador não imprime bootstrap password nem tokens.'
