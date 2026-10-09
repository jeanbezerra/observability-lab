#!/usr/bin/env bash

# HTTPS local com certificados efêmeros. Não usa Rancher externo, VM ou root.
set -Eeuo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
command -v python3 >/dev/null
command -v openssl >/dev/null
command -v curl >/dev/null

python3 - "${project_dir}/scripts/lib/rancher-endpoint.sh" "${BASH}" <<'PY'
import hashlib
import http.server
import json
import os
from pathlib import Path
import ssl
import stat
import subprocess
import sys
import tempfile
import threading

endpoint_file, bash = sys.argv[1:]
passed = []

def openssl(*arguments):
    return subprocess.run(["openssl", *map(str, arguments)], capture_output=True, check=True).stdout

with tempfile.TemporaryDirectory(prefix="rancher-generic-ca-") as directory:
    base = Path(directory)
    bundle, key = base / "root.pem", base / "root.key"
    openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
            "-subj", "/CN=Generic-Test-Root", "-keyout", key, "-out", bundle,
            "-addext", "basicConstraints=critical,CA:TRUE",
            "-addext", "keyUsage=critical,keyCertSign,cRLSign")
    fingerprint = hashlib.sha256(openssl("x509", "-in", bundle, "-outform", "DER")).hexdigest()
    leaf, leaf_key, csr = base / "leaf.pem", base / "leaf.key", base / "leaf.csr"
    openssl("req", "-new", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=localhost",
            "-keyout", leaf_key, "-out", csr)
    extensions = base / "extensions"
    extensions.write_text("basicConstraints=critical,CA:FALSE\nsubjectAltName=DNS:localhost\n")
    openssl("x509", "-req", "-in", csr, "-CA", bundle, "-CAkey", key,
            "-CAcreateserial", "-out", leaf, "-days", "1", "-extfile", extensions)

    settings = {"ca": bundle.read_text(), "raw_available": True, "ping": "pong"}
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == "/ping":
                body, status = settings["ping"], 200
            elif self.path == "/cacerts":
                body, status = (settings["ca"], 200) if settings["raw_available"] else ("missing", 404)
            elif self.path == "/v3/settings/cacerts":
                body, status = json.dumps({"value": settings["ca"], "description": "Autoridade genérica"}, ensure_ascii=False), 200
            else:
                body, status = "missing", 404
            self.send_response(status)
            self.send_header("Content-Length", str(len(body.encode())))
            self.end_headers()
            self.wfile.write(body.encode())
        def log_message(self, *args):
            pass
    class Server(http.server.ThreadingHTTPServer):
        def handle_error(self, *args):
            # Clientes interrompem o handshake nos cenários de TLS rejeitado.
            pass
    server = Server(("127.0.0.1", 0), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(leaf, leaf_key)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    url = f"https://localhost:{server.server_port}"
    runner = base / "run.sh"
    runner.write_text(r'''set -Eeuo pipefail
umask 077
require_command() { command -v "$1" >/dev/null; }
valid_https_url() { [[ "$1" =~ ^https://[a-zA-Z0-9.:-]+$ ]]; }
log() { printf 'INFO: %s\n' "$*"; }
die() { printf 'ERRO: %s\n' "$*" >&2; exit 1; }
source "$ENDPOINT_FILE"
if [[ "$MODE" == configure ]]; then prepare_rancher_ca; fi
validate_rancher_endpoint
''', encoding="utf-8")

    def run(name, *, state=None, pin="", mode="configure", ca="", expected=0, message="", extra=None):
        state = state or base / name
        env = dict(os.environ, ENDPOINT_FILE=endpoint_file, MODE=mode,
                   BOOTSTRAP_STATE_DIR=str(state), RANCHER_URL=url,
                   RANCHER_CA_FILE=ca, RANCHER_CA_AUTO_DISCOVER="true",
                   RANCHER_CA_FINGERPRINT=pin, NO_PROXY="localhost,127.0.0.1",
                   no_proxy="localhost,127.0.0.1")
        # Não permita que um trust store da máquina altere a prova de primeira confiança.
        for variable in ("CURL_CA_BUNDLE", "SSL_CERT_FILE", "SSL_CERT_DIR"):
            env.pop(variable, None)
        env.update(extra or {})
        result = subprocess.run([bash, str(runner)], env=env, stdin=subprocess.DEVNULL,
                                capture_output=True, text=True, timeout=30)
        output = result.stdout + result.stderr
        assert result.returncode == expected, (name, result.returncode, output)
        assert message in output, (name, output)
        assert "PRIVATE KEY" not in output
        passed.append(name)
        return state

    rejected = run("unknown_ca_requires_authorization", expected=1, message="CA ainda não autorizada")
    assert not (rejected / "rancher-ca").exists()
    rejected = run("wrong_pin_rejected", pin="0" * 64, expected=1, message="difere de RANCHER_CA_FINGERPRINT")
    assert not (rejected / "rancher-ca").exists()
    accepted = run("pinned_ca_authorized", pin=fingerprint, message="validado com TLS")
    cached = next((accepted / "rancher-ca").glob("*.pem"))
    assert stat.S_IMODE(cached.stat().st_mode) == 0o600
    assert stat.S_IMODE(cached.parent.stat().st_mode) == 0o700
    run("readonly_reuses_authorized_origin", state=accepted, mode="readonly", message="validado com TLS")
    original_cache = cached.read_bytes()
    run("readonly_enforces_changed_pin", state=accepted, mode="readonly", pin="0" * 64,
        expected=1, message="cache CA difere")
    run("disabled_discovery_still_enforces_pin", state=accepted, pin="0" * 64,
        expected=1, message="cache CA difere", extra={"RANCHER_CA_AUTO_DISCOVER": "false"})
    run("changed_pin_does_not_replace_valid_cache", state=accepted, pin="0" * 64,
        expected=1, message="difere de RANCHER_CA_FINGERPRINT")
    assert cached.read_bytes() == original_cache
    run("malformed_pin_rejected", pin="bad pin", expected=1, message="64 caracteres")
    cached.chmod(0o644)
    run("unsafe_cache_rejected", state=accepted, mode="readonly", expected=1, message="permissões 0600")
    cached.chmod(0o600)
    settings["ca"] = "MALFORMED PUBLIC DATA"
    run("cache_does_not_redownload", state=accepted, message="validado com TLS")
    run("invalid_bundle_rejected", pin=fingerprint, expected=1, message="bundle CA válido")
    settings["ca"] = leaf.read_text()
    run("leaf_cannot_be_trust_anchor", expected=1, message="bundle CA válido")
    settings.update(ca=bundle.read_text(), raw_available=False)
    run("json_cacerts_fallback", pin=fingerprint, message="validado com TLS")
    run("explicit_ca_remains_authoritative", ca=str(bundle), message="validado com TLS")
    settings["ping"] = "unexpected html"
    run("candidate_requires_pong", pin=fingerprint, expected=1, message="não validou a cadeia")
    settings["ping"] = "pong"
    # Certificado assinado pela CA certa, mas URL com hostname incorreto.
    mismatched_url = f"https://127.0.0.1:{server.server_port}"
    run("hostname_mismatch_not_repaired", pin=fingerprint, expected=1,
        message="nome do certificado", extra={"RANCHER_URL": mismatched_url})
    assert not (base / "hostname_mismatch_not_repaired" / "rancher-ca").exists()
    run("changed_origin_does_not_inherit_trust", state=accepted, mode="readonly", expected=1,
        message="nome do certificado", extra={"RANCHER_URL": mismatched_url})
    # Nova raiz/certificado na mesma URL não substituem confiança sem novo pin.
    rotated_bundle, rotated_key = base / "rotated.pem", base / "rotated.key"
    openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
            "-subj", "/CN=Another-Generic-Root", "-keyout", rotated_key, "-out", rotated_bundle,
            "-addext", "basicConstraints=critical,CA:TRUE")
    rotated_leaf = base / "rotated-leaf.pem"
    openssl("x509", "-req", "-in", csr, "-CA", rotated_bundle, "-CAkey", rotated_key,
            "-CAcreateserial", "-out", rotated_leaf, "-days", "1", "-extfile", extensions)
    context.load_cert_chain(rotated_leaf, leaf_key)
    settings.update(ca=rotated_bundle.read_text(), raw_available=True)
    run("rotation_requires_new_authorization", state=accepted, expected=1, message="CA ainda não autorizada")
    assert cached.read_bytes() == original_cache
    run("rotation_rejects_old_pin", state=accepted, pin=fingerprint, expected=1,
        message="difere de RANCHER_CA_FINGERPRINT")
    assert cached.read_bytes() == original_cache
    rotated_fingerprint = hashlib.sha256(openssl("x509", "-in", rotated_bundle, "-outform", "DER")).hexdigest()
    run("rotation_accepts_confirmed_new_pin", state=accepted, pin=rotated_fingerprint,
        message="validado com TLS")
    assert cached.read_bytes() != original_cache
    run("readonly_after_rotation", state=accepted, mode="readonly", pin=rotated_fingerprint,
        message="validado com TLS")
    server.shutdown()
    server.server_close()
    print(f"PASS: {len(passed)} cenários de confiança CA genérica (HTTPS local, certificados efêmeros, sem root).")
PY
