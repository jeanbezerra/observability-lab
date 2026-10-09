#!/usr/bin/env bash

# Requer common.sh e TLS previamente validado. Nunca lê /version, que pertence
# ao Kubernetes do servidor, nem confia em uma versão de outro endpoint.
rancher_version_is_supported() {
  local major minor patch
  [[ "$1" =~ ^v?([0-9]{1,6})\.([0-9]{1,6})\.([0-9]{1,6})$ ]] || return 1
  major=$((10#${BASH_REMATCH[1]}))
  minor=$((10#${BASH_REMATCH[2]}))
  patch=$((10#${BASH_REMATCH[3]}))
  (( major > 2 || (major == 2 && minor > 15) \
    || (major == 2 && minor == 15 && patch >= 2) ))
}

load_rancher_version() {
  set +x
  RANCHER_REQUESTED_VERSION="${RANCHER_VERSION:-auto}"
  if [[ "${RANCHER_REQUESTED_VERSION}" != auto ]]; then
    rancher_version_is_supported "${RANCHER_REQUESTED_VERSION}" \
      || die "RANCHER_VERSION deve ser auto ou uma release estável v2.15.2 ou superior compatível com o Kubernetes configurado."
    RANCHER_VERSION="v${RANCHER_REQUESTED_VERSION#v}"
    return 0
  fi

  local cached_version
  # O cache é dado JSON, jamais shell executável. --check não cria diretórios,
  # não altera permissões e não faz chamadas de rede.
  if cached_version="$(python3 - "${BOOTSTRAP_STATE_DIR}/rancher-version.json" "${RANCHER_URL%/}" <<'PY'
import json
import os
from pathlib import Path
import re
import stat
import sys

try:
    path, wanted_url = Path(sys.argv[1]), sys.argv[2]
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_mode & 0o077 or info.st_uid != os.geteuid() or info.st_size > 4096:
        raise ValueError()
    data = json.loads(path.read_text(encoding="utf-8"))
    version = data["version"]
    if data.get("format") != 1 or data["url"] != wanted_url or not isinstance(version, str):
        raise ValueError()
    if not re.fullmatch(r"v[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}", version):
        raise ValueError()
    print(version)
except (OSError, ValueError, KeyError, TypeError):
    sys.exit(1)
PY
  )" && rancher_version_is_supported "${cached_version}"; then
    RANCHER_VERSION="${cached_version}"
  else
    RANCHER_VERSION=auto
  fi
}

discover_rancher_version() {
  set +x
  require_command curl
  require_command python3
  valid_https_url "${RANCHER_URL%/}" \
    || die "A descoberta da versão exige RANCHER_URL HTTPS sem credenciais, caminho ou query."
  local version_temporary_dir http_status curl_status=0 detected_version failure=""
  local -a version_curl_options=(--disable --silent --show-error --proto '=https'
    --connect-timeout 15 --max-time 30 --max-filesize 4096)
  if [[ -n "${RANCHER_CA_FILE:-}" ]]; then
    [[ -f "${RANCHER_CA_FILE}" && -r "${RANCHER_CA_FILE}" ]] \
      || die "RANCHER_CA_FILE deve apontar para a cadeia CA pública local em PEM."
    version_curl_options+=(--cacert "${RANCHER_CA_FILE}")
  fi
  version_temporary_dir="$(mktemp -d)" \
    || die "Não foi possível criar o diretório temporário de descoberta da versão."
  if http_status="$(curl "${version_curl_options[@]}" \
    --output "${version_temporary_dir}/body" --write-out '%{http_code}' \
    "${RANCHER_URL%/}/rancherversion" 2>"${version_temporary_dir}/stderr")"; then
    curl_status=0
  else
    curl_status=$?
  fi
  if (( curl_status != 0 )); then
    failure="Rancher /rancherversion: curl=${curl_status}; não foi possível validar a versão por HTTPS. Revise conectividade, CA e proxy."
  elif [[ "${http_status}" != 200 ]]; then
    failure="Rancher /rancherversion não respondeu HTTP 200; redirecionamentos são recusados. Revise a URL final e o proxy."
  elif ! detected_version="$(python3 - "${version_temporary_dir}/body" <<'PY'
import json
from pathlib import Path
import re
import sys

try:
    raw = Path(sys.argv[1]).read_bytes()
    if len(raw) > 4096:
        raise ValueError()
    value = raw.decode("utf-8").strip()
    if value.startswith(("{", '"')):
        value = json.loads(value)
        if isinstance(value, dict):
            candidates = [value[key] for key in ("Version", "version") if key in value]
            if not candidates or any(candidate != candidates[0] for candidate in candidates):
                raise ValueError()
            value = candidates[0]
    if not isinstance(value, str) or not re.fullmatch(r"v?[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}", value):
        raise ValueError()
    print("v" + value.removeprefix("v"))
except (OSError, ValueError, TypeError):
    sys.exit(1)
PY
  )"; then
    failure="Rancher /rancherversion devolveu uma versão estável inválida; corpo omitido."
  elif ! rancher_version_is_supported "${detected_version}"; then
    failure="A versão detectada do Rancher não atende à referência v2.15.2 ou superior deste instalador; confira a matriz para o Kubernetes configurado."
  elif [[ "${RANCHER_REQUESTED_VERSION:-auto}" != auto \
    && "v${RANCHER_REQUESTED_VERSION#v}" != "${detected_version}" ]]; then
    failure="RANCHER_VERSION diverge da versão real do servidor; use auto ou ajuste a versão explícita antes de importar."
  fi
  rm -f -- "${version_temporary_dir}/body" "${version_temporary_dir}/stderr"
  rmdir -- "${version_temporary_dir}"
  [[ -z "${failure}" ]] || die "${failure}"

  # Atualização atômica fora do checkout, com URL e versão no mesmo arquivo.
  python3 - "${BOOTSTRAP_STATE_DIR}" "${RANCHER_URL%/}" "${detected_version}" <<'PY' \
    || die "Não foi possível guardar o cache protegido da versão Rancher."
import json
import os
from pathlib import Path
import sys
import tempfile

directory, url, version = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
temporary_name = None
try:
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=directory,
                                     prefix=".rancher-version-", delete=False) as stream:
        temporary_name = stream.name
        os.chmod(temporary_name, 0o600)
        json.dump({"format": 1, "url": url, "version": version}, stream)
        stream.write("\n")
    os.replace(temporary_name, directory / "rancher-version.json")
except OSError:
    if temporary_name:
        try:
            os.unlink(temporary_name)
        except OSError:
            pass
    sys.exit(1)
PY
  RANCHER_VERSION="${detected_version}"
  log "Versão real do Rancher detectada por HTTPS: ${RANCHER_VERSION}."
}

require_resolved_rancher_version() {
  rancher_version_is_supported "${RANCHER_VERSION:-auto}" \
    || die "A versão real do Rancher ainda não foi resolvida. Execute a etapa normalmente para validar HTTPS e guardar a descoberta, ou informe RANCHER_VERSION explicitamente para a verificação local."
}
