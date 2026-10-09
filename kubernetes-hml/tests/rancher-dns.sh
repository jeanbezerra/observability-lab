#!/usr/bin/env bash

# Regressão offline: nenhum DNS, cluster, kubeconfig, sudo ou instalação real.
set -Eeuo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
command -v python3 >/dev/null || { printf 'python3 é obrigatório.\n' >&2; exit 1; }

python3 - "${project_dir}" <<'PY'
from pathlib import Path
import copy
import json
import importlib.util
import os
import shutil
import subprocess
import sys
import struct
import tempfile

sys.dont_write_bytecode = True
project = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("rancher_dns", project / "scripts/lib/rancher-dns.py")
dns = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dns)
original_corefile = """# DNS customizado: manter comentário, ordem e blocos existentes.
.:53 {
    errors
    health
    ready
    kubernetes cluster.local in-addr.arpa ip6.arpa {
        pods insecure
        fallthrough in-addr.arpa ip6.arpa
    }
    forward . /etc/resolv.conf
    cache 30
    reload
}

custom.example:53 {
    forward . 192.0.2.54
}
"""
original = {"apiVersion": "v1", "kind": "ConfigMap",
            "metadata": {"name": "coredns", "namespace": "kube-system",
                         "resourceVersion": "12", "annotations": {"custom-owner": "preserve"}},
            "data": {"Corefile": original_corefile, "custom-key": "preserve"}}
with tempfile.TemporaryDirectory(prefix="hml-rancher-dns-test-") as directory:
    task = Path(directory)
    scripts = task / "scripts"
    (scripts / "lib").mkdir(parents=True)
    shutil.copyfile(project / "scripts/79-configure-rancher-dns.sh",
                    scripts / "79-configure-rancher-dns.sh")
    shutil.copyfile(project / "scripts/lib/rancher-dns.py", scripts / "lib/rancher-dns.py")
    (scripts / "lib/common.sh").write_text(r'''set -Eeuo pipefail
CLUSTER_OPERATION_TIMEOUT=1s
POD_NETWORK_CIDR=10.244.0.0/16
BOOTSTRAP_STATE_DIR="${HARNESS}/bootstrap"
require_root() { :; }
require_command() { command -v "$1" >/dev/null; }
valid_https_url() { [[ "$1" == https://* ]]; }
check_requested() { [[ "${1:-}" == --check ]]; }
check_pending() { printf 'PENDENTE: %s\n' "$*" >&2; }
log() { printf '%s\n' "$*"; }
die() { printf 'ERRO: %s\n' "$*" >&2; exit 1; }
kube() { python3 "${HARNESS}/mock_kube.py" "$@"; }
python3() {
  if [[ "${2:-}" == discover ]]; then
    printf 'discover\n' >> "${HARNESS}/trace.txt"
    [[ "${MOCK_DISCOVERY_FAIL:-0}" == 0 ]] || return 1
    printf '%s\n' "${MOCK_DISCOVERED_SERVERS:-192.0.2.53}"
  else
    command python3 "$@"
  fi
}
''')
    (task / "mock_kube.py").write_text(r'''from pathlib import Path
import copy
import json
import os
import sys

root = Path(os.environ["HARNESS"])
state_path = root / "cluster.json"
trace_path = root / "trace.txt"
state = json.loads(state_path.read_text())
args = sys.argv[1:]

def trace(action):
    with trace_path.open("a") as stream:
        stream.write(action + "\n")

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

if args == ["-n", "kube-system", "get", "configmap", "coredns", "-o", "json"]:
    trace("get")
    print(json.dumps(state))
elif args[:5] == ["-n", "kube-system", "patch", "configmap", "coredns"]:
    trace("patch")
    patch = json.loads(Path(args[args.index("--patch-file") + 1]).read_text())
    assert patch["metadata"]["resourceVersion"] == state["metadata"]["resourceVersion"]
    assert set(patch).issubset({"metadata", "data"})
    assert set(patch.get("data", {})).issubset({"Corefile"})
    if os.environ.get("MOCK_PATCH_FAIL") == "1":
        sys.exit(1)
    state = merge(state, patch)
    state_path.write_text(json.dumps(state))
elif args[:5] == ["-n", "kube-system", "rollout", "restart", "deployment/coredns"]:
    trace("restart")
elif args[:5] == ["-n", "kube-system", "rollout", "status", "deployment/coredns"]:
    trace("rollout")
    if os.environ.get("MOCK_ROLLOUT_FAIL") == "1":
        sys.exit(1)
else:
    raise RuntimeError(f"Comando inesperado; teste deve permanecer sem rede: {args}")
''')
    state_path, trace_path = task / "cluster.json", task / "trace.txt"
    state_path.write_text(json.dumps(original))
    environment = {**os.environ, "HARNESS": str(task),
                   "RANCHER_URL": "https://rancher.hml.example:8443",
                   "RANCHER_DNS_SERVERS": "192.0.2.53 192.0.2.54",
                   "RANCHER_DNS_MODE": "auto", "MOCK_DISCOVERY_FAIL": "0",
                   "MOCK_PATCH_FAIL": "0", "MOCK_ROLLOUT_FAIL": "0"}
    scenarios = 0

    def run(*arguments, success=True, **overrides):
        global scenarios
        trace_path.write_text("")
        result = subprocess.run(
            ["bash", str(scripts / "79-configure-rancher-dns.sh"), *arguments],
            env={**environment, **overrides}, text=True, capture_output=True, timeout=10)
        assert (result.returncode == 0) == success, (result.stdout, result.stderr)
        scenarios += 1
        return json.loads(state_path.read_text()), trace_path.read_text().splitlines()

    for arguments in ((), ("--check",)):
        state, calls = run(*arguments, RANCHER_DNS_SERVERS="", RANCHER_URL="")
        assert state == original and calls == []
    state, calls = run("--check", RANCHER_DNS_SERVERS=" \t ", RANCHER_URL="")
    assert calls == [] and not (task / "bootstrap").exists()
    state, calls = run(RANCHER_DNS_MODE="off")
    assert state == original and calls == []
    state, calls = run("--check", RANCHER_DNS_MODE="off")
    assert state == original and calls == []
    state, calls = run(success=False, RANCHER_DNS_MODE="invalid")
    assert state == original and calls == []

    state, calls = run("--check", success=False)
    assert state == original and calls == ["get"]
    state, calls = run()
    assert calls == ["get", "patch", "restart", "rollout"]
    corefile = state["data"]["Corefile"]
    assert corefile.startswith(original_corefile)
    assert corefile.count("# BEGIN kubernetes-hml rancher-dns") == 1
    assert "rancher.hml.example:53 {" in corefile
    assert "forward . 192.0.2.53 192.0.2.54" in corefile
    assert "policy sequential" in corefile and "hosts" not in corefile
    assert state["data"]["custom-key"] == "preserve"
    assert state["metadata"]["annotations"]["custom-owner"] == "preserve"
    recorded = json.loads((task / "bootstrap/rancher-dns.json").read_text())
    assert recorded["hostname"] == "rancher.hml.example"
    assert recorded["dns_servers"] == ["192.0.2.53", "192.0.2.54"]
    assert (task / "bootstrap/rancher-dns.json").stat().st_mode & 0o777 == 0o600
    backups = list((task / "bootstrap/rancher-dns-backups").glob("*.json"))
    assert len(backups) == 1
    assert json.loads(backups[0].read_text()) == original
    assert backups[0].stat().st_mode & 0o777 == 0o600
    compliant = copy.deepcopy(state)
    state, calls = run()
    assert state == compliant and calls == ["get", "rollout"]
    state, calls = run("--check")
    assert state == compliant and calls == ["get", "rollout"]
    state, calls = run(RANCHER_DNS_SERVERS="192.0.2.53 192.0.2.53 192.0.2.54")
    assert state == compliant and calls == ["get", "rollout"]

    changed = copy.deepcopy(compliant)
    changed["data"]["Corefile"] = corefile.replace("policy sequential", "policy random")
    state_path.write_text(json.dumps(changed))
    _, calls = run("--check", success=False)
    assert calls == ["get"]
    state, calls = run()
    assert state == compliant and calls == ["get", "patch", "restart", "rollout"]
    state, calls = run(RANCHER_URL="https://rancher-new.hml.example",
                       RANCHER_DNS_SERVERS="192.0.2.55")
    assert state["data"]["Corefile"].startswith(original_corefile)
    assert "rancher-new.hml.example:53" in state["data"]["Corefile"]
    assert "rancher.hml.example:53" not in state["data"]["Corefile"]
    assert calls == ["get", "patch", "restart", "rollout"]

    annotation_missing = copy.deepcopy(compliant)
    del annotation_missing["metadata"]["annotations"]["bootstrap.k8s.io/rancher-dns-sha256"]
    state_path.write_text(json.dumps(annotation_missing))
    state, calls = run()
    assert state == compliant and calls == ["get", "patch", "rollout"]

    for servers in ("192.0.2.53; touch /tmp/injection", "dns.internal", "192.0.2.53:53",
                    "127.0.0.1", "0.0.0.0", "224.0.0.1", "999.0.0.1",
                    "fe80::1", "2001:db8::53%eth0", "::ffff:127.0.0.1"):
        state_path.write_text(json.dumps(original))
        state, calls = run(success=False, RANCHER_DNS_SERVERS=servers)
        assert state == original and calls == ["get"]
    state, calls = run(RANCHER_URL="https://192.0.2.30")
    assert state == original and calls == []

    malformed = (
        corefile.replace("# END kubernetes-hml rancher-dns", ""),
        corefile + "# BEGIN kubernetes-hml rancher-dns\n",
        corefile.replace("# BEGIN kubernetes-hml rancher-dns", " # BEGIN kubernetes-hml rancher-dns"),
        corefile.replace("policy sequential", "unknown-plugin secret-value"),
        corefile.replace("    errors\n    cache 30\n    forward . 192.0.2.53", "    forward . 192.0.2.53"),
        original_corefile + "rancher.hml.example:53 {\n    forward . 192.0.2.55\n}\n",
    )
    for invalid in malformed:
        broken = copy.deepcopy(original)
        broken["data"]["Corefile"] = invalid
        state_path.write_text(json.dumps(broken))
        state, calls = run(success=False)
        assert state == broken and calls == ["get"]

    state_path.write_text(json.dumps(original))
    state, calls = run(success=False, MOCK_PATCH_FAIL="1")
    assert state == original and calls == ["get", "patch"]
    (task / "bootstrap/rancher-dns.json").unlink()
    state_path.write_text(json.dumps(original))
    state, calls = run(success=False, MOCK_ROLLOUT_FAIL="1")
    assert state["data"]["Corefile"] == compliant["data"]["Corefile"]
    assert calls == ["get", "patch", "restart", "rollout"]
    assert not (task / "bootstrap/rancher-dns.json").exists()
    # Depois do timeout o Corefile já está conforme, mas nenhum rerun pode
    # informar sucesso enquanto o Deployment continua indisponível.
    state, calls = run(success=False, MOCK_ROLLOUT_FAIL="1")
    assert calls == ["get", "rollout"]
    assert not (task / "bootstrap/rancher-dns.json").exists()
    state, calls = run("--check", success=False, MOCK_ROLLOUT_FAIL="1")
    assert calls == ["get", "rollout"]
    assert not (task / "bootstrap/rancher-dns.json").exists()
    state, calls = run()
    assert calls == ["get", "rollout"]
    assert (task / "bootstrap/rancher-dns.json").exists()

    # Descoberta normal refaz os testes de upstream; --check usa somente o
    # estado gravado e não consulta DNS, inclusive quando URL muda.
    (task / "bootstrap/rancher-dns.json").unlink()
    state_path.write_text(json.dumps(original))
    state, calls = run("--check", success=False, RANCHER_DNS_SERVERS="")
    assert state == original and calls == []
    state, calls = run(success=False, RANCHER_DNS_SERVERS="", MOCK_DISCOVERY_FAIL="1")
    assert state == original and calls == ["discover"]
    state, calls = run(RANCHER_DNS_SERVERS="")
    assert calls == ["discover", "get", "patch", "restart", "rollout"]
    auto_state = copy.deepcopy(state)
    recorded = json.loads((task / "bootstrap/rancher-dns.json").read_text())
    assert recorded["selection_mode"] == "auto" and recorded["dns_servers"] == ["192.0.2.53"]
    state, calls = run("--check", RANCHER_DNS_SERVERS="", MOCK_DISCOVERY_FAIL="1")
    assert state == auto_state and calls == ["get", "rollout"]
    state, calls = run("--check", success=False, RANCHER_DNS_SERVERS="",
                       RANCHER_URL="https://rancher-other.example")
    assert state == auto_state and calls == []
    state, calls = run(RANCHER_DNS_SERVERS="", MOCK_DISCOVERED_SERVERS="2001:db8::53")
    assert calls == ["discover", "get", "patch", "restart", "rollout"]
    assert "forward . 2001:db8::53" in state["data"]["Corefile"]
    state, calls = run(RANCHER_DNS_SERVERS="", MOCK_DISCOVERED_SERVERS="2001:db8::53")
    assert calls == ["discover", "get", "rollout"]

    # Descoberta e parser reais testados com respostas DNS sintéticas; os
    # mocks ficam no teste, sem atalhos de rede no código de produção.
    upstreams, fallback = task / "upstreams.conf", task / "fallback.conf"
    upstreams.write_text("nameserver 127.0.0.53\nnameserver 192.0.2.53\n"
                         "nameserver 192.0.2.54\nnameserver 2001:db8::53\n"
                         "nameserver 192.0.2.53\nnameserver fe80::1\n")
    fallback.write_text("nameserver 192.0.2.55\n")
    assert dns.resolver_candidates([upstreams, fallback]) == ["192.0.2.53", "192.0.2.54", "2001:db8::53"]
    scenarios += 1

    def lookup(hostname):
        assert hostname == "rancher.dynamic.example"
        return {"192.0.2.30", "2001:db8::30"}

    def query(server, hostname, qtype, timeout):
        assert hostname == "rancher.dynamic.example" and 0 < timeout <= 2
        if server == "192.0.2.54":  # NXDOMAIN, sem endereço.
            return set()
        if server == "192.0.2.55":  # Outra visão DNS, não pode ser misturada.
            return {"198.51.100.30"} if qtype == 1 else set()
        return {"192.0.2.30"} if qtype == 1 else {"2001:db8::30"}

    selected = dns.discover_servers("https://rancher.dynamic.example", [upstreams], lookup, query)
    assert selected == ["192.0.2.53", "2001:db8::53"]
    scenarios += 1
    selected = dns.discover_servers("https://rancher.dynamic.example", [upstreams], lookup, query, {4})
    assert selected == ["192.0.2.53"]
    scenarios += 1
    upstreams.write_text("nameserver 127.0.0.53\n")
    assert dns.resolver_candidates([upstreams, fallback]) == ["192.0.2.55"]
    scenarios += 1
    try:
        dns.discover_servers("https://rancher.dynamic.example", [fallback], lookup, query)
        raise AssertionError("Outro DNS não pode sobrepor a resolução do host.")
    except ValueError:
        scenarios += 1

    # Mensagens corretas, NXDOMAIN, CNAME, respostas não relacionadas e
    # transação adulterada. Nenhuma resposta arbitrária aparece no diagnóstico.
    name = b"\x07rancher\x07dynamic\x07example\0"
    question = name + struct.pack("!2H", 1, 1)
    response = struct.pack("!6H", 321, 0x8180, 1, 1, 0, 0) + question
    response += b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, 60, 4) + bytes([192, 0, 2, 30])
    assert dns.parse_answers(response, 321, "rancher.dynamic.example", 1) == {"192.0.2.30"}
    scenarios += 1
    nxdomain = struct.pack("!6H", 321, 0x8183, 1, 0, 0, 0) + question
    assert dns.parse_answers(nxdomain, 321, "rancher.dynamic.example", 1) == set()
    scenarios += 1
    alias = b"\x04edge\x07dynamic\x07example\0"
    cname = struct.pack("!6H", 321, 0x8180, 1, 2, 0, 0) + question
    cname += b"\xc0\x0c" + struct.pack("!HHIH", 5, 1, 60, len(alias)) + alias
    cname += alias + struct.pack("!HHIH", 1, 1, 60, 4) + bytes([192, 0, 2, 30])
    assert dns.parse_answers(cname, 321, "rancher.dynamic.example", 1) == {"192.0.2.30"}
    scenarios += 1
    aaaa_question = name + struct.pack("!2H", 28, 1)
    aaaa_response = struct.pack("!6H", 321, 0x8180, 1, 1, 0, 0) + aaaa_question
    aaaa_response += b"\xc0\x0c" + struct.pack("!HHIH", 28, 1, 60, 16)
    aaaa_response += bytes.fromhex("20010db8000000000000000000000030")
    assert dns.parse_answers(aaaa_response, 321, "rancher.dynamic.example", 28) == {"2001:db8::30"}
    scenarios += 1

    # Uma resposta truncada UDP deve ser repetida por TCP. O mock fragmenta
    # os bytes TCP para verificar leitura completa, sem sockets de rede reais.
    transports = []
    socket_original, random_original = dns.socket.socket, dns.secrets.randbelow

    class FakeConnection:
        def __init__(self, family, kind):
            assert family == dns.socket.AF_INET
            self.kind = kind
            self.remaining = bytearray(struct.pack("!H", len(response)) + response)
            transports.append(kind)

        def __enter__(self):
            return self

        def __exit__(self, *arguments):
            pass

        def settimeout(self, timeout):
            assert timeout == 2

        def connect(self, destination):
            assert destination == ("192.0.2.53", 53)

        def send(self, request):
            assert struct.unpack("!H", request[:2])[0] == 321 and request[12:] == question

        def sendall(self, request):
            size = struct.unpack("!H", request[:2])[0]
            assert size == len(request) - 2 and request[14:] == question

        def recv(self, size):
            if self.kind == dns.socket.SOCK_DGRAM:
                return struct.pack("!6H", 321, 0x8380, 1, 0, 0, 0) + question
            amount = min(size, 3)
            result = bytes(self.remaining[:amount])
            del self.remaining[:amount]
            return result

    try:
        dns.socket.socket = FakeConnection
        dns.secrets.randbelow = lambda maximum: 321
        assert dns.query_addresses("192.0.2.53", "rancher.dynamic.example", 1) == {"192.0.2.30"}
        assert transports == [dns.socket.SOCK_DGRAM, dns.socket.SOCK_STREAM]
        scenarios += 1
    finally:
        dns.socket.socket, dns.secrets.randbelow = socket_original, random_original
    for malformed_response, transaction, hostname, qtype in (
        (response, 322, "rancher.dynamic.example", 1),
        (response, 321, "other.example", 1),
        (response[:-1], 321, "rancher.dynamic.example", 1),
        (response, 321, "rancher.dynamic.example", 28),
        (b"invalid", 321, "rancher.dynamic.example", 1),
    ):
        try:
            dns.parse_answers(malformed_response, transaction, hostname, qtype)
            raise AssertionError("Parser deve recusar resposta DNS inválida.")
        except ValueError:
            scenarios += 1

print(f"PASS: {scenarios} cenários DNS Rancher sem rede/API/root; custom Corefile, "
      "auto, split DNS, IPv4/IPv6, read-only, markers, parser, patch e rollout.")
PY
