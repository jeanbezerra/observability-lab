#!/usr/bin/env bash

# Regressão offline da etapa 75: não usa cluster, rede, sudo ou instalação.
set -Eeuo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
command -v python3 >/dev/null || { printf 'python3 é obrigatório.\n' >&2; exit 1; }

python3 - "${project_dir}" <<'PY'
from pathlib import Path
import copy
import json
import os
import shutil
import subprocess
import sys
import tempfile

project = Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix="hml-script75-test-") as directory:
    task = Path(directory)
    scripts = task / "scripts"
    (scripts / "lib").mkdir(parents=True)
    binary = task / "bin"
    binary.mkdir()
    shutil.copyfile(project / "scripts/75-configure-gateway-access.sh",
                    scripts / "75-configure-gateway-access.sh")
    (scripts / "55-install-gateway.sh").write_text("#!/usr/bin/env bash\nexit 0\n")
    (scripts / "lib/common.sh").write_text('''#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
GATEWAY_NAMESPACE=gateway-system
GATEWAY_NAME=hml-gateway
GATEWAY_LISTENER_PORT=8080
GATEWAY_NODE_PORT=30080
NODE_IP=192.0.2.30
require_root() { :; }
require_command() { command -v "$1" >/dev/null; }
check_requested() { [[ "${1:-}" == --check ]]; }
check_pending() { printf '%s\\n' "$*" >&2; }
log() { printf '%s\\n' "$*"; }
die() { printf '%s\\n' "$*" >&2; exit 1; }
retry() { shift 2; "$@"; }
kube() { python3 "${HARNESS}/mock_kube.py" "$@"; }
''')
    (binary / "curl").write_text('#!/usr/bin/env bash\ncat "${HARNESS}/http-status"\n')
    (binary / "curl").chmod(0o755)
    (task / "http-status").write_text("404")
    source = {
        "metadata": {"namespace": "envoy-gateway-system", "name": "envoy-generated-abcdef"},
        "spec": {"type": "ClusterIP", "clusterIP": "10.96.9.8",
                 "selector": {"app": "envoy", "gateway": "hml"},
                 "ports": [{"name": "http-8080", "port": 8080, "targetPort": 10080,
                            "protocol": "TCP", "appProtocol": "http"}]}}
    existing = {
        "apiVersion": "v1", "kind": "Service",
        "metadata": {"namespace": "envoy-gateway-system", "name": "hml-gateway-external",
                     "resourceVersion": "4",
                     "labels": {"app.kubernetes.io/managed-by": "kubernetes-hml"}},
        "spec": {"type": "NodePort", "externalTrafficPolicy": "Local",
                 "clusterIP": "10.96.1.42", "clusterIPs": ["10.96.1.42"],
                 "ipFamilies": ["IPv4"], "ipFamilyPolicy": "SingleStack",
                 "selector": {"app": "wrong", "extra": "wrong"},
                 "ports": [{"name": "wrong", "port": 9090, "targetPort": 9090,
                            "nodePort": 30081, "protocol": "TCP"}]}}
    state_path = task / "state.json"
    state_path.write_text(json.dumps({"source": source, "external": existing,
                                     "patches": 0, "creates": 0, "source_count": 1}))
    (task / "mock_kube.py").write_text(r'''from pathlib import Path
import copy
import json
import os
import sys

path = Path(os.environ["HARNESS"]) / "state.json"
state = json.loads(path.read_text())
args = sys.argv[1:]

def merge(target, patch):
    if not isinstance(patch, dict):
        return copy.deepcopy(patch)
    target = copy.deepcopy(target) if isinstance(target, dict) else {}
    for key, value in patch.items():
        if value is None:
            target.pop(key, None)
        else:
            target[key] = merge(target.get(key), value)
    return target

if args[:3] == ["get", "service", "-A"]:
    for _ in range(state["source_count"]):
        print("envoy-gateway-system|envoy-generated-abcdef")
elif args[:3] == ["-n", "envoy-gateway-system", "get"]:
    name = args[4]
    result = state["source"] if name == "envoy-generated-abcdef" else state["external"]
    if result is not None:
        print(json.dumps(result))
elif args[:4] == ["-n", "envoy-gateway-system", "patch", "service"]:
    assert args[4] == "hml-gateway-external", "Service do controller não pode ser alterado"
    patch = json.loads(Path(args[args.index("--patch-file") + 1]).read_text())
    for field in ("clusterIP", "clusterIPs", "ipFamilies", "ipFamilyPolicy"):
        assert field not in patch["spec"], f"Campo alocado não pode ser alterado: {field}"
    assert patch["metadata"]["resourceVersion"] == state["external"]["metadata"]["resourceVersion"]
    state["external"] = merge(state["external"], patch)
    state["patches"] += 1
    path.write_text(json.dumps(state))
    print("service/hml-gateway-external patched")
elif args[:2] == ["create", "-f"]:
    assert state["external"] is None
    desired = json.loads(Path(args[2]).read_text())
    assert not any("owning-gateway" in label for label in desired["metadata"]["labels"])
    assert "clusterIP" not in desired["spec"]
    desired["metadata"]["resourceVersion"] = "1"
    desired["spec"]["clusterIP"] = "10.96.1.42"
    desired["spec"]["clusterIPs"] = ["10.96.1.42"]
    state["external"] = desired
    state["creates"] += 1
    path.write_text(json.dumps(state))
else:
    raise RuntimeError(f"Comando Kubernetes inesperado: {args}")
''')
    environment = {**os.environ, "HARNESS": str(task),
                   "PATH": str(binary) + ":" + os.environ["PATH"]}

    def run(*arguments, success=True):
        result = subprocess.run(
            ["bash", str(scripts / "75-configure-gateway-access.sh"), *arguments],
            env=environment, text=True, capture_output=True)
        assert (result.returncode == 0) == success, (result.stdout, result.stderr)
        return json.loads(state_path.read_text())

    def save(state):
        state_path.write_text(json.dumps(state))

    state = run()
    assert state["source"] == source
    for field in ("clusterIP", "clusterIPs", "ipFamilies", "ipFamilyPolicy"):
        assert state["external"]["spec"][field] == existing["spec"][field]
    assert state["external"]["spec"]["selector"] == source["spec"]["selector"]
    port = state["external"]["spec"]["ports"][0]
    assert port["targetPort"] == 10080 and port["nodePort"] == 30080
    assert port["port"] == 8080 and port["appProtocol"] == "http"
    assert state["patches"] == 1
    state = run()
    assert state["patches"] == 1, "Rerun de Service conforme precisa ser idempotente"
    run("--check")

    for field, divergent in (("targetPort", 9999), ("nodePort", 30081),
                             ("port", 9090), ("protocol", "UDP")):
        state["external"]["spec"]["ports"][0][field] = divergent
        save(state)
        run("--check", success=False)
        state = run()
        assert state["external"]["spec"]["clusterIP"] == "10.96.1.42"
        assert state["source"] == source

    compliant = copy.deepcopy(state)
    state["external"]["metadata"]["labels"]["app.kubernetes.io/managed-by"] = "other"
    save(state)
    refused = run(success=False)
    assert refused == state, "Service de outro gerenciador deve permanecer intacto"
    state = copy.deepcopy(compliant)
    state["external"]["spec"]["clusterIP"] = "None"
    save(state)
    refused = run(success=False)
    assert refused == state, "Service headless deve permanecer intacto"

    state = copy.deepcopy(compliant)
    for source_count in (0, 2):
        state["source_count"] = source_count
        save(state)
        run(success=False)
    state["source_count"] = 1
    state["external"] = None
    save(state)
    state = run()
    assert state["creates"] == 1 and state["source"] == source
    run("--check")
    (task / "http-status").write_text("503")
    run("--check", success=False)

print("PASS: etapa 75 offline: criação, drift, selectors, portas, campos imutáveis, "
      "ownership, idempotência, Service único e HTTP 404/503.")
PY
