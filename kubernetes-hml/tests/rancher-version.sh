#!/usr/bin/env bash
# Descoberta/cache de versão: somente mocks e arquivos temporários, sem rede.
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
if [[ "$("${python_command}" -c 'import sys; print(sys.platform)')" == win32 ]]; then
  runner_bash="$(cygpath -m "${runner_bash}")"
  runner_python="$(cygpath -m "${runner_python}")"
fi

"${python_command}" - "${project_dir}" "${runner_bash}" "${runner_python}" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

project, bash, python = sys.argv[1:]
library = (Path(project) / "scripts/lib/rancher-version.sh").read_text(encoding="utf-8")
sentinel = "VERSION_PRIVATE_BODY_MUST_NOT_APPEAR"
common = r'''set -Eeuo pipefail
require_command() { command -v "$1" >/dev/null; }
valid_https_url() { [[ "$1" =~ ^https://[a-zA-Z0-9.-]+$ ]]; }
die() { printf 'ERRO: %s\n' "$*" >&2; exit 1; }
log() { printf 'INFO: %s\n' "$*"; }
python3() { "$MOCK_PYTHON" "$@"; }
curl() {
  [[ "$1" == --disable ]] || return 91
  printf 'curl\n' >> "$MOCK_TRACE"
  local output_file="" tls=false bounded=false protocol=false target=""
  while (( $# > 0 )); do
    case "$1" in
      --insecure|-k|--location|-L) return 92 ;;
      --output) output_file="$2"; shift ;;
      --cacert) [[ "$2" == "$RANCHER_CA_FILE" ]] || return 93; tls=true; shift ;;
      --max-filesize) [[ "$2" == 4096 ]] || return 94; bounded=true; shift ;;
      --proto) [[ "$2" == '=https' ]] || return 95; protocol=true; shift ;;
      https://*) target="$1" ;;
    esac
    shift
  done
  [[ "$bounded" == true && "$protocol" == true && -n "$output_file" ]] || return 96
  [[ "$target" == "$RANCHER_URL/rancherversion" ]] || return 97
  [[ -z "$RANCHER_CA_FILE" || "$tls" == true ]] || return 98
  printf '%s' "$MOCK_BODY" > "$output_file"
  printf '%s' "$MOCK_HTTP"
  printf '%s' "$MOCK_ERROR" >&2
  return "$MOCK_CODE"
}
'''
runner = '''#!/usr/bin/env bash
source "$(dirname -- "$0")/common.sh"
source "$(dirname -- "$0")/rancher-version.sh"
load_rancher_version
if [[ "$MOCK_MODE" == normal ]]; then discover_rancher_version; fi
if [[ "$MOCK_REQUIRED" == true ]]; then require_resolved_rancher_version; fi
printf 'RESOLVED=%s\\n' "$RANCHER_VERSION"
'''
with tempfile.TemporaryDirectory(prefix="rancher-version-") as temporary:
    base = Path(temporary)
    for filename, contents in [("common.sh", common), ("rancher-version.sh", library), ("run.sh", runner)]:
        (base / filename).write_text(contents, encoding="utf-8", newline="\n")
    passed = []

    def case(name, setting="auto", mode="normal", body="v2.15.2", http="200", code=0,
             expected=0, resolved="v2.15.2", cache=None, cache_mode=0o600,
             required=False, ca=False, url="https://rancher.environment.example",
             message=None, xtrace=False):
        folder = base / name
        folder.mkdir()
        state = folder / "state"
        cache_file = state / "rancher-version.json"
        if cache is not None:
            state.mkdir(mode=0o700)
            cache_file.write_text(json.dumps(cache), encoding="utf-8")
            cache_file.chmod(cache_mode)
        before = cache_file.read_bytes() if cache_file.exists() else None
        ca_file = folder / "public-ca.pem"
        if ca:
            ca_file.write_text("PUBLIC_CA_MOCK\n", encoding="ascii")
        trace = folder / "trace"
        env = dict(os.environ, RANCHER_URL=url, RANCHER_VERSION=setting,
                   RANCHER_CA_FILE=ca_file.as_posix() if ca else "",
                   BOOTSTRAP_STATE_DIR=state.as_posix(), MOCK_TRACE=trace.as_posix(),
                   MOCK_PYTHON=python, MOCK_BODY=body, MOCK_HTTP=http,
                   MOCK_CODE=str(code), MOCK_ERROR=sentinel, MOCK_MODE=mode,
                   MOCK_REQUIRED="true" if required else "false", PYTHONIOENCODING="utf-8")
        result = subprocess.run([bash] + (["-x"] if xtrace else []) + [(base / "run.sh").as_posix()],
                                env=env, capture_output=True, text=True, encoding="utf-8", timeout=15)
        output = result.stdout + result.stderr
        assert result.returncode == expected, (name, result.returncode, output)
        assert sentinel not in output, (name, output)
        if message:
            assert message in output, (name, output)
        calls = trace.read_text().splitlines() if trace.exists() else []
        assert len(calls) == (1 if mode == "normal" and setting != "bad" else 0), (name, calls)
        if mode == "check" or expected:
            after = cache_file.read_bytes() if cache_file.exists() else None
            assert before == after, (name, "cache alterado por check/falha")
            if cache is None:
                assert not state.exists(), (name, "check/falha criou estado")
        else:
            data = json.loads(cache_file.read_text(encoding="utf-8"))
            assert data == {"format": 1, "url": url, "version": resolved}, (name, data)
            if os.name != "nt":
                assert cache_file.stat().st_mode & 0o777 == 0o600, (name, "cache não protegido")
        if expected == 0:
            assert f"RESOLVED={resolved}" in output, (name, output)
        passed.append(name)
        return cache_file

    known = {"format": 1, "url": "https://rancher.environment.example", "version": "v2.15.2"}
    case("plain")
    case("plain_without_v", body="2.15.2")
    case("plain_whitespace", body=" v2.15.2\n")
    case("json_official", body=json.dumps({"Version": "v2.15.2", "GitCommit": "public", "RancherPrime": "false"}))
    case("json_lowercase", body='{"version":"v2.15.2"}')
    case("json_string", body='"v2.15.2"')
    case("explicit_matches", setting="2.15.2")
    case("explicit_ca", ca=True)
    case("detected_upgrade", body="v2.15.3", cache=known, resolved="v2.15.3")
    case("check_known", mode="check", cache=known, required=True)
    case("check_unknown_pending", mode="check", resolved="auto")
    case("check_explicit", mode="check", setting="v2.15.2", required=True)
    case("check_foreign_url_cache", mode="check", cache=known, url="https://another.environment.example", resolved="auto")
    if os.name != "nt":
        case("check_unprotected_cache", mode="check", cache=known, cache_mode=0o644, resolved="auto")
    case("check_unsupported_cache", mode="check", cache=dict(known, version="v2.14.6"), resolved="auto")
    case("check_wrong_format", mode="check", cache=dict(known, format=2), resolved="auto")
    case("check_no_cache_required", mode="check", required=True, expected=1, resolved="auto", message="ainda não foi resolvida")
    case("check_foreign_required", mode="check", cache=known, required=True,
         url="https://another.environment.example", expected=1, message="ainda não foi resolvida")
    case("explicit_mismatch", setting="v2.15.3", expected=1, message="diverge da versão real")
    case("bad_setting", setting="bad", expected=1, message="deve ser auto")
    case("redirect", http="302", body=sentinel, expected=1, message="redirecionamentos")
    case("unauthorized", http="401", body=sentinel, expected=1)
    case("ca_failure", code=60, body=sentinel, expected=1, message="curl=60")
    case("timeout", code=28, body=sentinel, expected=1, message="curl=28")
    case("size_failure", code=63, body=sentinel, expected=1)
    for name, body in [
        ("invalid_html", f"<html>{sentinel}</html>"),
        ("invalid_json", '{"Version":"v2.15.2"'),
        ("json_wrong_key", '{"gitVersion":"v2.15.2"}'),
        ("json_wrong_type", '{"Version":["v2.15.2"]}'),
        ("json_disagree", '{"Version":"v2.15.2","version":"v2.15.3"}'),
        ("prerelease", "v2.15.2-rc1"),
        ("unbounded_body", "v2.15.2" + " " * 4096),
        ("overflow_component", "v2.9999999999999999999.2"),
        ("unsupported_release", "v2.14.6"),
    ]:
        case(name, body=body, expected=1)
    case("xtrace_no_body_leak", xtrace=True)
    print(f"PASS: {len(passed)} cenários de descoberta HTTPS, cache protegido por URL, versão explícita, parsing e check sem rede.")
PY
