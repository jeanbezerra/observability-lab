#!/usr/bin/env bash

# Requer common.sh. O cache pertence à URL configurada, nunca ao ambiente de
# quem publicou os scripts. A descoberta não equivale a confiar no certificado.
rancher_ca_cache_file() {
  local origin_hash
  origin_hash="$(printf '%s' "${RANCHER_URL%/}" | sha256sum | awk '{print $1}')"
  printf '%s/rancher-ca/%s.pem\n' "${BOOTSTRAP_STATE_DIR}" "${origin_hash}"
}

use_cached_rancher_ca() {
  [[ -z "${RANCHER_CA_FILE:-}" ]] || return 0
  local cached_ca
  cached_ca="$(rancher_ca_cache_file)"
  if [[ -f "${cached_ca}" && -r "${cached_ca}" ]]; then
    python3 - "${cached_ca}" <<'PY' \
      || die "O cache CA precisa pertencer ao usuário atual, ser um arquivo regular sem links e manter permissões 0600 em diretório 0700."
import os
from pathlib import Path
import stat
import sys
try:
    path = Path(sys.argv[1])
    info, parent = path.lstat(), path.parent.lstat()
    if not stat.S_ISREG(info.st_mode) or not stat.S_ISDIR(parent.st_mode):
        raise ValueError()
    if info.st_uid != os.geteuid() or parent.st_uid != os.geteuid():
        raise ValueError()
    if info.st_mode & 0o077 or parent.st_mode & 0o077 or info.st_size > 131072:
        raise ValueError()
except (OSError, ValueError):
    sys.exit(1)
PY
    if [[ "${1:-}" != --prepare && -n "${RANCHER_CA_FINGERPRINT:-}" ]]; then
      local cached_fingerprint expected_fingerprint
      cached_fingerprint="$(_rancher_ca_fingerprint "${cached_ca}")" \
        || die "O bundle CA no cache local não é válido; configure novamente a confiança TLS."
      expected_fingerprint="${RANCHER_CA_FINGERPRINT//:/}"
      [[ "${cached_fingerprint}" == "${expected_fingerprint^^}" ]] \
        || die "O cache CA difere de RANCHER_CA_FINGERPRINT; execute test-rancher.sh --configure-ca para conferir a rotação antes de confiar."
    fi
    RANCHER_CA_FILE="${cached_ca}"
  fi
}

_rancher_ca_fingerprint() {
  python3 - "$1" <<'PY'
import hashlib
from pathlib import Path
import re
import ssl
import sys
try:
    raw = Path(sys.argv[1]).read_text(encoding="ascii")
    blocks = re.findall(r"-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----", raw)
    if not blocks or re.sub(r"-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----", "", raw).strip():
        raise ValueError()
    print(hashlib.sha256(b"".join(ssl.PEM_cert_to_DER_cert(block) for block in blocks)).hexdigest().upper())
except (OSError, ValueError):
    sys.exit(1)
PY
}

_rancher_unknown_ca_error() {
  case "${1,,}" in
    *'sec_e_untrusted_root'*|*'cert_e_untrustedroot'*|*'self-signed certificate'*|*'unable to get local issuer certificate'*|*'unable to verify the first certificate'*) return 0 ;;
    *) return 1 ;;
  esac
}

# Canonicaliza somente certificados CA válidos. O pin é SHA-256 dos DER
# concatenados na ordem do bundle (para uma CA, é o fingerprint X.509 usual).
_inspect_rancher_ca_bundle() {
  python3 - "$1" "$2" "$3" <<'PY'
import hashlib
import json
import re
import ssl
import subprocess
import sys
import time
from pathlib import Path

source, destination, metadata = map(Path, sys.argv[1:])
try:
    raw = source.read_text(encoding="utf-8")
    if raw.lstrip().startswith("{"):
        raw = json.loads(raw)["value"]
    if not isinstance(raw, str) or len(raw) > 131072:
        raise ValueError()
    blocks = re.findall(r"-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----", raw)
    remainder = re.sub(r"-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----", "", raw)
    if not 1 <= len(blocks) <= 16 or remainder.strip():
        raise ValueError()
    digest, normalized, subjects, seen = hashlib.sha256(), [], [], set()
    for index, block in enumerate(blocks):
        cert_path = destination.with_name(f"certificate-{index}.pem")
        cert_path.write_text(block + "\n", encoding="ascii")
        def x509(*args):
            return subprocess.run(["openssl", "x509", "-in", str(cert_path), *args],
                                  capture_output=True, check=True).stdout
        constraints = x509("-noout", "-ext", "basicConstraints").decode("ascii")
        if not re.search(r"\bCA:TRUE\b", constraints):
            raise ValueError()
        dates = dict(line.split("=", 1) for line in x509("-noout", "-startdate", "-enddate").decode("ascii").splitlines())
        if not ssl.cert_time_to_seconds(dates["notBefore"]) <= time.time() < ssl.cert_time_to_seconds(dates["notAfter"]):
            raise ValueError()
        der = x509("-outform", "DER")
        if der in seen:
            raise ValueError()
        seen.add(der)
        digest.update(der)
        normalized.append(x509("-outform", "PEM").decode("ascii"))
        subject = x509("-noout", "-subject", "-nameopt", "RFC2253").decode("utf-8", errors="replace").strip()
        subjects.append(subject.encode("unicode_escape").decode("ascii")[:512])
        cert_path.unlink()
    destination.write_text("".join(normalized), encoding="ascii")
    metadata.write_text(json.dumps({"fingerprint": digest.hexdigest().upper(), "subjects": subjects}), encoding="ascii")
except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
    sys.exit(1)
PY
}

prepare_rancher_ca() {
  set +x
  local explicit_ca="${RANCHER_CA_FILE:-}" cache_file ca_temporary_dir status=0 http_status error
  local fingerprint expected_fingerprint answer="" endpoint fetched=false accepted=false cached_pin_matches=true
  local auto_discover="${RANCHER_CA_AUTO_DISCOVER:-true}" staged_cache
  local -a verify_options=(--disable --silent --show-error --proto '=https'
    --connect-timeout 15 --max-time 30 --max-filesize 4096)
  [[ -z "${explicit_ca}" ]] || return 0
  if [[ ! "${auto_discover,,}" =~ ^(true|1|yes|on|sim)$ ]]; then
    use_cached_rancher_ca
    return 0
  fi
  use_cached_rancher_ca --prepare
  require_command curl
  require_command python3
  require_command openssl
  require_command sha256sum
  valid_https_url "${RANCHER_URL%/}" || die "RANCHER_URL deve informar a origem HTTPS do Rancher."
  ca_temporary_dir="$(mktemp -d)" || die "Não foi possível preparar a descoberta da CA."
  expected_fingerprint="${RANCHER_CA_FINGERPRINT:-}"
  expected_fingerprint="${expected_fingerprint//:/}"
  expected_fingerprint="${expected_fingerprint^^}"
  if [[ -n "${expected_fingerprint}" && ! "${expected_fingerprint}" =~ ^[A-F0-9]{64}$ ]]; then
    rm -rf -- "${ca_temporary_dir}"
    die "RANCHER_CA_FINGERPRINT deve ser SHA-256 hexadecimal de 64 caracteres, com dois-pontos opcionais."
  fi
  if [[ -n "${RANCHER_CA_FILE:-}" ]]; then
    verify_options+=(--cacert "${RANCHER_CA_FILE}")
    if [[ -n "${expected_fingerprint}" ]]; then
      cached_pin_matches=false
      if _inspect_rancher_ca_bundle "${RANCHER_CA_FILE}" "${ca_temporary_dir}/ca.pem" "${ca_temporary_dir}/metadata.json"; then
        fingerprint="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["fingerprint"])' "${ca_temporary_dir}/metadata.json")"
        [[ "${fingerprint}" != "${expected_fingerprint}" ]] || cached_pin_matches=true
      fi
    fi
  fi
  if http_status="$(curl "${verify_options[@]}" --output "${ca_temporary_dir}/ping" \
    --write-out '%{http_code}' "${RANCHER_URL%/}/ping" 2>"${ca_temporary_dir}/stderr")"; then
    status=0
  else
    status=$?
  fi
  error="$(cat -- "${ca_temporary_dir}/stderr")"
  if [[ "${cached_pin_matches}" == true ]] \
    && { (( status != 60 )) || ! _rancher_unknown_ca_error "${error}"; }; then
    # A validação principal classifica DNS, proxy, validade, hostname e HTTP.
    rm -rf -- "${ca_temporary_dir}"
    return 0
  fi
  log "Descobrindo a CA publicada pela origem Rancher configurada para conferir a confiança TLS."
  # --insecure serve exclusivamente para coletar material público ainda NÃO
  # confiável. Nenhum token/YAML é enviado; o /ping final sempre verifica TLS.
  for endpoint in /cacerts /v3/settings/cacerts; do
    if http_status="$(curl --disable --silent --show-error --insecure --proto '=https' \
      --connect-timeout 15 --max-time 30 --max-filesize 131072 \
      --output "${ca_temporary_dir}/candidate" --write-out '%{http_code}' \
      "${RANCHER_URL%/}${endpoint}" 2>"${ca_temporary_dir}/stderr")" \
      && [[ "${http_status}" == 200 ]] \
      && _inspect_rancher_ca_bundle "${ca_temporary_dir}/candidate" "${ca_temporary_dir}/ca.pem" "${ca_temporary_dir}/metadata.json"; then
      fetched=true
      break
    fi
  done
  if [[ "${fetched}" != true ]]; then
    rm -rf -- "${ca_temporary_dir}"
    die "O Rancher não publicou um bundle CA válido. Forneça RANCHER_CA_FILE pela administração do servidor; não foi alterada a confiança TLS."
  fi
  fingerprint="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["fingerprint"])' "${ca_temporary_dir}/metadata.json")"
  if [[ -n "${expected_fingerprint}" ]]; then
    if [[ ! "${expected_fingerprint}" =~ ^[A-F0-9]{64}$ || "${fingerprint}" != "${expected_fingerprint}" ]]; then
      rm -rf -- "${ca_temporary_dir}"
      die "A CA descoberta difere de RANCHER_CA_FINGERPRINT. Confirme a rotação com a administração do Rancher; a confiança anterior foi preservada."
    fi
    accepted=true
  fi
  # O candidato deve realmente validar a identidade, a cadeia e a validade do
  # servidor antes de oferecê-lo como opção de confiança ao operador.
  status=0
  if http_status="$(curl --disable --silent --show-error --proto '=https' \
    --connect-timeout 15 --max-time 30 --max-filesize 4096 --cacert "${ca_temporary_dir}/ca.pem" \
    --output "${ca_temporary_dir}/ping" --write-out '%{http_code}' \
    "${RANCHER_URL%/}/ping" 2>"${ca_temporary_dir}/stderr")"; then
    status=0
  else
    status=$?
  fi
  if (( status != 0 )) || [[ "${http_status}" != 200 || "$(cat -- "${ca_temporary_dir}/ping")" != pong ]]; then
    rm -rf -- "${ca_temporary_dir}"
    die "A CA publicada não validou a cadeia, o hostname, a validade e /ping do Rancher. Corrija o certificado/servidor; a confiança anterior foi preservada."
  fi
  if [[ "${accepted}" != true ]]; then
    log "Primeira confiança ou rotação de CA para ${RANCHER_URL%/}."
    python3 -c 'import json,sys; data=json.load(open(sys.argv[1])); print("\n".join(data["subjects"]))' "${ca_temporary_dir}/metadata.json"
    log "Fingerprint SHA-256 do bundle DER: ${fingerprint}"
    if [[ -t 0 && -r /dev/tty ]]; then
      printf 'Confira o fingerprint por uma fonte da administração do Rancher. Confiar nesta CA? [sim/NAO]: ' >/dev/tty
      read -r answer </dev/tty || answer=""
      case "${answer,,}" in sim|yes) accepted=true ;; esac
    fi
    if [[ "${accepted}" != true ]]; then
      rm -rf -- "${ca_temporary_dir}"
      die "CA ainda não autorizada. Defina RANCHER_CA_FINGERPRINT com o SHA-256 confirmado ou RANCHER_CA_FILE com a CA fornecida pela administração; a descoberta não habilita confiança automática."
    fi
  fi
  cache_file="$(rancher_ca_cache_file)"
  if [[ "${BOOTSTRAP_STATE_DIR}" != /* || -L "${BOOTSTRAP_STATE_DIR}" || -L "${BOOTSTRAP_STATE_DIR}/rancher-ca" || -L "${cache_file}" ]]; then
    rm -rf -- "${ca_temporary_dir}"
    die "O diretório de confiança precisa ser absoluto e não pode conter links simbólicos."
  fi
  install -d -m 0700 -- "${BOOTSTRAP_STATE_DIR}/rancher-ca"
  staged_cache="$(mktemp "${BOOTSTRAP_STATE_DIR}/rancher-ca/.ca.XXXXXX")"
  install -m 0600 -- "${ca_temporary_dir}/ca.pem" "${staged_cache}"
  mv -f -- "${staged_cache}" "${cache_file}"
  RANCHER_CA_FILE="${cache_file}"
  rm -rf -- "${ca_temporary_dir}"
  log "CA autorizada persistida no estado local da origem Rancher; TLS validado sem alterar a confiança global do sistema."
}
