#!/usr/bin/env bash

# Regressões da importação Generic. Não usa rede, kubeconfig, credenciais ou root.
set -Eeuo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v python3 >/dev/null 2>&1 && python3 -c 'import sys' >/dev/null 2>&1; then
  python_command="$(command -v python3)"
elif command -v python >/dev/null 2>&1 && python -c 'import sys' >/dev/null 2>&1; then
  python_command="$(command -v python)"
else
  printf 'ERRO: Python 3 é necessário para executar as regressões.\n' >&2
  exit 1
fi
runner_bash="${BASH}"
runner_python="${python_command}"
if [[ "$("${python_command}" -c 'import sys; print(sys.platform)')" == "win32" ]]; then
  runner_bash="$(cygpath -m "${runner_bash}")"
  runner_python="$(cygpath -m "${runner_python}")"
fi

"${python_command}" - "${project_dir}/scripts/80-register-rancher.sh" \
  "${runner_bash}" "${runner_python}" "${project_dir}/scripts/lib/rancher-endpoint.sh" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

source_file, bash_executable, python_executable, endpoint_file = sys.argv[1:]
source = Path(source_file).read_text(encoding="utf-8")
endpoint_source = Path(endpoint_file).read_text(encoding="utf-8")
ca_source = Path(endpoint_file).with_name("rancher-ca.sh").read_text(encoding="utf-8")
version_source = Path(endpoint_file).with_name("rancher-version.sh").read_text(encoding="utf-8")
dns_source = Path(source_file).with_name("79-configure-rancher-dns.sh").read_text(encoding="utf-8")
sentinel = "FAKE_TOKEN_MUST_NEVER_APPEAR"
common = r'''set -Eeuo pipefail
umask 027
KUBERNETES_MINOR=v1.36
CLUSTER_OPERATION_TIMEOUT=1s
BOOTSTRAP_STATE_DIR="$MOCK_STATE"
RANCHER_CA_AUTO_DISCOVER="${RANCHER_CA_AUTO_DISCOVER:-false}"
require_root() { :; }
require_command() { command -v "$1" >/dev/null; }
valid_https_url() { [[ "$1" =~ ^https://[a-zA-Z0-9.-]+$ ]]; }
check_requested() { [[ "${1:-}" == --check ]]; }
check_pending() { printf 'PENDENTE: %s\n' "$*"; }
log() { printf 'INFO: %s\n' "$*"; }
die() { printf 'ERRO: %s\n' "$*" >&2; exit 1; }
python3() { "$MOCK_PYTHON" "$@"; }
curl() {
  printf 'curl\n' >> "$MOCK_TRACE"
  [[ "$1" == --disable ]] || return 95
  local output_file="" ca_seen=false version_request=false
  while (( $# > 0 )); do
    case "$1" in
      --insecure|-k|--location|-L) printf 'TLS bypass/redirect forbidden\n' >&2; return 99 ;;
      --output) output_file="$2"; shift ;;
      --cacert)
        [[ "$2" == "$RANCHER_CA_FILE" ]] || return 98
        ca_seen=true; printf 'cacert\n' >> "$MOCK_TRACE"; shift
        ;;
      */rancherversion) version_request=true ;;
    esac
    shift
  done
  [[ -n "$output_file" ]] || return 97
  [[ -z "$RANCHER_CA_FILE" || "$ca_seen" == true ]] || return 96
  if [[ "$version_request" == true ]]; then
    printf '%s' "$MOCK_SERVER_VERSION" > "$output_file"
    printf '200'
    return 0
  fi
  printf '%s' "$MOCK_BODY" > "$output_file"
  printf '%s' "$MOCK_HTTP_STATUS"
  if [[ "$MOCK_CURL_STATUS" != 0 ]]; then
    printf '%s\n' "$MOCK_CURL_ERROR" >&2
    return "$MOCK_CURL_STATUS"
  fi
}
install() {
  if [[ "$1" == -d ]]; then mkdir -p -- "${@: -1}"; else cp -- "${@: -2:1}" "${@: -1}"; fi
}
kube() {
  if [[ "${1:-}" == create ]]; then
    printf 'dryrun\n' >> "$MOCK_TRACE"
    if [[ "${MOCK_DRYRUN_FAILURE:-0}" != 0 ]]; then
      printf '%s\n' "$MOCK_CURL_ERROR" >&2
      return "$MOCK_DRYRUN_FAILURE"
    fi
    cat "$MOCK_DESIRED"
  elif [[ "${1:-}" == apply ]]; then printf 'apply\n' >> "$MOCK_TRACE"; cp "$MOCK_DESIRED" "$MOCK_LIVE"
  elif [[ "${3:-}" == get ]]; then printf 'get\n' >> "$MOCK_TRACE"; [[ ! -s "$MOCK_LIVE" ]] || cat "$MOCK_LIVE"
  elif [[ "${3:-}" == rollout ]]; then printf 'rollout\n' >> "$MOCK_TRACE"; return "${MOCK_ROLLOUT_FAILURE:-0}"
  else return 99; fi
}
'''

def agent(url="https://rancher.hml.test", image="rancher/rancher-agent:v2.15.2"):
    return {"apiVersion": "apps/v1", "kind": "Deployment",
            "metadata": {"name": "cattle-cluster-agent", "namespace": "cattle-system"},
            "spec": {"template": {"spec": {"containers": [{"name": "cluster-register",
                     "image": image, "env": [{"name": "CATTLE_SERVER", "value": url},
                     {"name": "CATTLE_TOKEN", "value": sentinel}]}]}}}}

with tempfile.TemporaryDirectory(prefix="rancher-registration-") as temporary:
    base = Path(temporary)
    (base / "scripts/lib").mkdir(parents=True)
    script = base / "scripts/80-register-rancher.sh"
    script.write_text(source, encoding="utf-8", newline="\n")
    (base / "scripts/lib/common.sh").write_text(common, encoding="utf-8", newline="\n")
    (base / "scripts/lib/rancher-endpoint.sh").write_text(endpoint_source, encoding="utf-8", newline="\n")
    (base / "scripts/lib/rancher-ca.sh").write_text(ca_source, encoding="utf-8", newline="\n")
    (base / "scripts/lib/rancher-version.sh").write_text(version_source, encoding="utf-8", newline="\n")
    (base / "scripts/79-configure-rancher-dns.sh").write_text(dns_source, encoding="utf-8", newline="\n")
    passed = []

    def case(name, configured=False, existing=None, desired=None, check=True,
             expected=0, state=None, rollout_failure=False, curl_status=0,
             http_status="200", body="pong", curl_error=sentinel, ca=False,
             expected_message=None, xtrace=False, rancher_version="v2.15.2",
             ca_auto=False, fingerprint="", curl_calls=None, manifest_text=None,
             dryrun_failure=False, server_version="v2.15.2"):
        folder = base / name
        folder.mkdir()
        private_tmp = folder / "tmp"
        private_tmp.mkdir()
        live, want, trace = (folder / filename for filename in ("live.json", "manifest.json", "trace.txt"))
        live.write_text(json.dumps(existing) if existing else "", encoding="utf-8")
        want.write_text(json.dumps(desired or agent()), encoding="utf-8")
        manifest = folder / "import.yaml"
        manifest.write_text(manifest_text if manifest_text is not None else want.read_text(encoding="utf-8"),
                            encoding="utf-8", newline="")
        ca_path = folder / "ca.pem"
        if ca:
            ca_path.write_text("FAKE_PUBLIC_CA_FOR_OPTION_TEST\n", encoding="utf-8")
        env = dict(os.environ, MOCK_LIVE=live.as_posix(), MOCK_DESIRED=want.as_posix(),
                   MOCK_TRACE=trace.as_posix(), MOCK_STATE=(state or folder / "state").as_posix(),
                   MOCK_PYTHON=python_executable, PYTHONIOENCODING="utf-8",
                   RANCHER_URL="https://rancher.hml.test",
                   RANCHER_VERSION=rancher_version, RANCHER_CA_FILE=ca_path.as_posix() if ca else "",
                   RANCHER_CA_AUTO_DISCOVER="true" if ca_auto else "false",
                   RANCHER_CA_FINGERPRINT=fingerprint, TMPDIR=private_tmp.as_posix(),
                   RANCHER_DNS_MODE="off", RANCHER_DNS_SERVERS="",
                   RANCHER_IMPORT_MANIFEST=manifest.as_posix() if configured else "",
                   MOCK_DRYRUN_FAILURE="1" if dryrun_failure else "0",
                   MOCK_ROLLOUT_FAILURE="1" if rollout_failure else "0",
                   MOCK_CURL_STATUS=str(curl_status), MOCK_HTTP_STATUS=http_status,
                   MOCK_BODY=body, MOCK_CURL_ERROR=curl_error, MOCK_SERVER_VERSION=server_version)
        result = subprocess.run([bash_executable] + (["-x"] if xtrace else [])
                                + [script.as_posix()] + (["--check"] if check else []),
                                env=env, text=True, encoding="utf-8", capture_output=True, timeout=20)
        output = result.stdout + result.stderr
        assert result.returncode == expected, (name, result.returncode, output)
        assert sentinel not in output, (name, "Credencial apareceu na saída")
        assert not list(private_tmp.iterdir()), (name, "Temporários com dados de registro não foram limpos")
        if expected_message:
            assert expected_message in output, (name, expected_message, output)
        calls = trace.read_text().splitlines() if trace.exists() else []
        if check or (expected != 0 and not rollout_failure):
            assert "apply" not in calls, (name, calls)
        if check:
            assert "curl" not in calls, (name, calls)
        elif not name.startswith("foreign_agent_normal"):
            expected_curl_calls = curl_calls if curl_calls is not None else (2 if curl_status == 0 and http_status == "200" and body.rstrip("\n") == "pong" else 1)
            assert calls.count("curl") == expected_curl_calls, (name, calls)
            assert ("cacert" in calls) == ca, (name, calls)
        passed.append(name)
        return folder, calls, output

    case("empty_pending_check")
    case("auto_pending_check", rancher_version="auto", expected_message="PENDENTE")
    case("auto_manifest_check_requires_discovery", rancher_version="auto", configured=True,
         expected=1, expected_message="ainda não foi resolvida")
    auto_state, _, _ = case("auto_pending_normal", rancher_version="auto", check=False,
                            expected_message="Versão real do Rancher")
    assert json.loads((auto_state / "state/rancher-version.json").read_text())["version"] == "v2.15.2"
    case("prepare_failure_cleans_registration_tmp", ca_auto=True, fingerprint="malformed",
         check=False, expected=1, expected_message="64 caracteres", curl_calls=0)
    _, _, pending = case("empty_pending_normal", check=False)
    assert "PENDENTE" in pending and "Endpoint /ping" in pending
    for code, message in [(5, "DNS do proxy"), (6, "DNS do Rancher"),
                          (7, "conexão TCP"), (28, "timeout"), (35, "handshake TLS"),
                          (60, "certificado ou cadeia CA"), (63, "limite de 4096"),
                          (77, "arquivo CA inválido"), (56, "requisição HTTPS não concluída")]:
        _, _, failure = case(f"empty_pending_curl_{code}", check=False, curl_status=code,
                             expected=1, expected_message=message)
        assert f"curl={code};" in failure
    for name, error, message in [
        ("private_ca", "SEC_E_UNTRUSTED_ROOT", "CA/cadeia do certificado não confiável"),
        ("linux_private_ca", "SSL certificate problem: unable to get local issuer certificate",
         "CA/cadeia do certificado não confiável"),
        ("expired", "certificate has expired", "certificado expirado"),
        ("future", "certificate is not yet valid", "certificado ainda não válido"),
        ("hostname", "no alternative certificate subject name matches", "nome do certificado")]:
        case(name, check=False, curl_status=60, curl_error=f"{error}: {sentinel}",
             expected=1, expected_message=message)
    for status in ("301", "302", "401", "404", "503"):
        case(f"http_{status}", check=False, http_status=status,
             body=f"<html>{sentinel}</html>", expected=1, expected_message=f"HTTP {status}")
    case("http_invalid", check=False, http_status=sentinel, expected=1,
         expected_message="status HTTP válido")
    case("http_unexpected_body", check=False, body=f"<html>{sentinel}</html>", expected=1,
         expected_message="HTTP 200 com corpo inesperado")
    case("xtrace_tls_error", check=False, curl_status=60, curl_error=sentinel,
         expected=1, xtrace=True, expected_message="certificado ou cadeia CA")
    case("xtrace_unexpected_body", check=False, body=f"<html>{sentinel}</html>",
         expected=1, xtrace=True, expected_message="HTTP 200 com corpo inesperado")
    case("private_ca_success", check=False, ca=True,
         expected_message="validado com TLS: HTTP 200, pong")
    case("newline_success", check=False, body="pong\n")
    case("check_skips_failed_endpoint", existing=agent(), curl_status=60,
         http_status="000", expected_message="Agente pronto")
    case("existing_no_manifest", existing=agent())
    case("foreign_agent", existing=agent("https://wrong.test"), expected=1)
    case("foreign_agent_normal", existing=agent("https://wrong.test"), check=False, expected=1)
    _, foreign_calls, _ = case("foreign_agent_normal_auto", existing=agent("https://wrong.test"),
                              rancher_version="auto", check=False, expected=1)
    assert "curl" not in foreign_calls
    case("first_check", configured=True, expected=1)
    export_yaml = ("apiVersion: management.cattle.io/v3\nkind: Cluster\n"
                   f"metadata:\n  name: sample\nspec:\n  token: {sentinel}\n")
    for name, manifest in [
        ("cluster_export_yaml", export_yaml),
        ("cluster_export_json", json.dumps({"apiVersion": "management.cattle.io/v3", "kind": "Cluster",
                                            "spec": {"token": sentinel}})),
        ("cluster_export_quoted_bom_crlf", "\ufeff---\r\nkind: 'Cluster' # export\r\n"
         f'apiVersion: "management.cattle.io/v3"\r\nspec:\r\n  token: {sentinel}\r\n'),
        ("cluster_export_multiple_documents", "apiVersion: v1\nkind: Namespace\nmetadata:\n"
         "  name: cattle-system\n---\n" + export_yaml),
        ("cluster_export_json_list", json.dumps({"kind": "List", "items": [agent(),
         {"apiVersion": "management.cattle.io/v3", "kind": "Cluster", "spec": {"token": sentinel}}]})),
        ("cluster_export_provisioning", "apiVersion: provisioning.cattle.io/v1\nkind: Cluster\n")]:
        _, export_calls, _ = case(name, configured=True, check=False, expected=1, manifest_text=manifest,
                                  expected_message="export do objeto Cluster")
        assert "dryrun" not in export_calls, (name, export_calls)
    case("embedded_export_headers_not_resource", configured=True, check=False,
         manifest_text="apiVersion: v1\nkind: ConfigMap\ndata:\n  example: |\n"
         "    apiVersion: management.cattle.io/v3\n    kind: Cluster\n")
    _, failed_dryrun_calls, _ = case("dryrun_error_sanitized", configured=True, check=False,
                                    expected=1, dryrun_failure=True, xtrace=True,
                                    expected_message="interpretar/mapear")
    assert "dryrun" in failed_dryrun_calls
    applied, calls, _ = case("import_apply", configured=True, check=False)
    assert "apply" in calls and "curl" in calls
    assert (applied / "state/rancher-import.sha256").is_file()
    case("import_hash_check", configured=True, existing=agent(), state=applied / "state")
    controller_agent = agent()
    controller_spec = controller_agent["spec"]["template"]["spec"]
    controller_spec["containers"][0]["env"].append({"name": "CATTLE_FEATURES", "value": "mcma=true"})
    controller_spec["volumes"] = [{"name": "cattle-credentials", "secret": {"secretName": "controller-managed"}}]
    controller_spec["containers"][0]["volumeMounts"] = [{"name": "cattle-credentials", "mountPath": "/cattle-credentials"}]
    preserved, preserved_calls, _ = case("unchanged_manifest_preserves_controller", configured=True,
                                         existing=controller_agent, state=applied / "state", check=False,
                                         expected_message="serão preservados")
    assert "apply" not in preserved_calls and "dryrun" not in preserved_calls
    assert "rollout" in preserved_calls and preserved_calls.count("get") == 2
    assert json.loads((preserved / "live.json").read_text()) == controller_agent
    upgraded_agent = json.loads(json.dumps(controller_agent))
    upgraded_agent["spec"]["template"]["spec"]["containers"][0]["image"] = "rancher/rancher-agent:v2.15.3"
    upgraded, upgrade_calls, _ = case("unchanged_bootstrap_after_rancher_upgrade", configured=True,
                                      existing=upgraded_agent, state=applied / "state", check=False,
                                      rancher_version="auto", server_version="v2.15.3")
    assert "apply" not in upgrade_calls and "dryrun" not in upgrade_calls
    assert json.loads((upgraded / "live.json").read_text()) == upgraded_agent
    assert json.loads((applied / "state/rancher-version.json").read_text())["version"] == "v2.15.3"
    _, absent_calls, _ = case("missing_agent_reapplies_cached_manifest", configured=True,
                              state=applied / "state", check=False)
    assert "apply" in absent_calls and "dryrun" in absent_calls
    _, uncached_calls, _ = case("existing_agent_missing_import_cache_applies", configured=True,
                                existing=controller_agent, check=False)
    assert "apply" in uncached_calls and "dryrun" in uncached_calls
    preserved_hash = (applied / "state/rancher-import.sha256").read_text()
    _, failed_preserved_calls, _ = case("unchanged_manifest_rollout_failure", configured=True,
                                        existing=controller_agent, state=applied / "state", check=False,
                                        expected=1, rollout_failure=True)
    assert "apply" not in failed_preserved_calls
    assert (applied / "state/rancher-import.sha256").read_text() == preserved_hash
    changed = agent()
    changed["metadata"]["labels"] = {"changed": "yes"}
    case("changed_hash", configured=True, existing=agent(), desired=changed,
         state=applied / "state", expected=1)
    changed_applied, changed_calls, _ = case("changed_manifest_reapplied", configured=True,
                                            existing=controller_agent, desired=changed,
                                            state=applied / "state", check=False)
    assert "apply" in changed_calls and "dryrun" in changed_calls
    assert json.loads((changed_applied / "live.json").read_text()) == changed
    assert (applied / "state/rancher-import.sha256").read_text() != preserved_hash
    case("foreign_manifest", configured=True, desired=agent("https://wrong.test"), check=False, expected=1)
    case("server_disguised", configured=True, desired=agent(image="rancher/rancher:v2.15.2"),
         check=False, expected=1)
    case("old_agent_image", configured=True, desired=agent(image="rancher/rancher-agent:v2.14.6"),
         check=False, expected=1)
    case("cluster_agent_version_mismatch", configured=True, desired=agent(image="rancher/rancher-agent:v2.15.3"),
         check=False, expected=1, expected_message="versão real")
    node_agent = agent(image="rancher/rancher-agent:v2.15.3")
    node_agent.update(kind="DaemonSet", metadata={"name": "cattle-node-agent", "namespace": "cattle-system"})
    case("node_agent_version_mismatch", configured=True, desired={"kind": "List", "items": [agent(), node_agent]},
         check=False, expected=1, expected_message="versão real")
    case("digest_only_manifest_rejected", configured=True,
         desired=agent(image="rancher/rancher-agent@sha256:" + "a" * 64),
         check=False, expected=1, expected_message="versão real")
    case("tagged_digest_manifest_supported", configured=True,
         desired=agent(image="rancher/rancher-agent:v2.15.2@sha256:" + "a" * 64), check=False)
    failed, _, _ = case("rollout_failure", configured=True, check=False, expected=1, rollout_failure=True)
    assert not (failed / "state/rancher-import.sha256").exists()
    print(f"PASS: {len(passed)} cenários de registro Rancher (sem rede/API/root).")
PY
