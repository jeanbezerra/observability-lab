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
  "${runner_bash}" "${runner_python}" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

source_file, bash_executable, python_executable = sys.argv[1:]
source = Path(source_file).read_text(encoding="utf-8")
sentinel = "FAKE_TOKEN_MUST_NEVER_APPEAR"
common = r'''set -Eeuo pipefail
umask 027
KUBERNETES_MINOR=v1.36
CLUSTER_OPERATION_TIMEOUT=1s
BOOTSTRAP_STATE_DIR="$MOCK_STATE"
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
  [[ "${MOCK_PING_FAILURE:-0}" == 0 ]] || return 60
  printf pong
}
install() {
  if [[ "$1" == -d ]]; then mkdir -p -- "${@: -1}"; else cp -- "${@: -2:1}" "${@: -1}"; fi
}
kube() {
  if [[ "${1:-}" == create ]]; then printf 'dryrun\n' >> "$MOCK_TRACE"; cat "$MOCK_DESIRED"
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
    passed = []

    def case(name, configured=False, existing=None, desired=None, check=True,
             expected=0, state=None, rollout_failure=False, ping_failure=False):
        folder = base / name
        folder.mkdir()
        live, want, trace = (folder / filename for filename in ("live.json", "manifest.json", "trace.txt"))
        live.write_text(json.dumps(existing) if existing else "", encoding="utf-8")
        want.write_text(json.dumps(desired or agent()), encoding="utf-8")
        env = dict(os.environ, MOCK_LIVE=live.as_posix(), MOCK_DESIRED=want.as_posix(),
                   MOCK_TRACE=trace.as_posix(), MOCK_STATE=(state or folder / "state").as_posix(),
                   MOCK_PYTHON=python_executable, RANCHER_URL="https://rancher.hml.test",
                   RANCHER_VERSION="v2.15.2", RANCHER_CA_FILE="",
                   RANCHER_IMPORT_MANIFEST=want.as_posix() if configured else "",
                   MOCK_ROLLOUT_FAILURE="1" if rollout_failure else "0",
                   MOCK_PING_FAILURE="1" if ping_failure else "0")
        result = subprocess.run([bash_executable, script.as_posix()] + (["--check"] if check else []),
                                env=env, text=True, capture_output=True, timeout=20)
        output = result.stdout + result.stderr
        assert result.returncode == expected, (name, result.returncode, output)
        assert sentinel not in output, (name, "Credencial apareceu na saída")
        calls = trace.read_text().splitlines() if trace.exists() else []
        if check or (expected != 0 and not rollout_failure):
            assert "apply" not in calls, (name, calls)
        if check:
            assert "curl" not in calls, (name, calls)
        elif name != "foreign_agent_normal":
            assert calls.count("curl") == 1, (name, calls)
        passed.append(name)
        return folder, calls, output

    case("empty_pending_check")
    _, _, pending = case("empty_pending_normal", check=False)
    assert "PENDENTE" in pending and "Endpoint /ping" in pending
    case("empty_pending_tls_failure", check=False, ping_failure=True, expected=1)
    case("existing_no_manifest", existing=agent())
    case("foreign_agent", existing=agent("https://wrong.test"), expected=1)
    case("foreign_agent_normal", existing=agent("https://wrong.test"), check=False, expected=1)
    case("first_check", configured=True, expected=1)
    applied, calls, _ = case("import_apply", configured=True, check=False)
    assert "apply" in calls and "curl" in calls
    assert (applied / "state/rancher-import.sha256").is_file()
    case("import_hash_check", configured=True, existing=agent(), state=applied / "state")
    changed = agent()
    changed["metadata"]["labels"] = {"changed": "yes"}
    case("changed_hash", configured=True, existing=agent(), desired=changed,
         state=applied / "state", expected=1)
    case("foreign_manifest", configured=True, desired=agent("https://wrong.test"), check=False, expected=1)
    case("server_disguised", configured=True, desired=agent(image="rancher/rancher:v2.15.2"),
         check=False, expected=1)
    case("old_agent_image", configured=True, desired=agent(image="rancher/rancher-agent:v2.14.6"),
         check=False, expected=1)
    failed, _, _ = case("rollout_failure", configured=True, check=False, expected=1, rollout_failure=True)
    assert not (failed / "state/rancher-import.sha256").exists()
    print(f"PASS: {len(passed)} cenários de registro Rancher (sem rede/API/root).")
PY
