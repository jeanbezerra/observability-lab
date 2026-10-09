#!/usr/bin/env bash
# Regressões de configuração/rede. Somente o diretório temporário é modificado.
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/kubernetes-hml-validation.XXXXXX")"
trap 'rm -rf -- "${temporary_dir:?}"' EXIT
fixture_dir="${temporary_dir}/fixture"
mkdir -p "${fixture_dir}/scripts/lib"
cp -- "${ROOT_DIR}/configure-install.sh" "${fixture_dir}/configure-install.sh"
cp -- "${ROOT_DIR}/.env.example" "${fixture_dir}/.env.example"
cp -- "${ROOT_DIR}/scripts/00-preflight.sh" "${fixture_dir}/scripts/00-preflight.sh"
cp -- "${ROOT_DIR}/scripts/lib/common.sh" "${fixture_dir}/scripts/lib/common.sh"
cp -- "${ROOT_DIR}/scripts/lib/host-preflight.sh" "${ROOT_DIR}/scripts/lib/host-storage.py" \
  "${ROOT_DIR}/scripts/lib/windows-time.ps1" "${fixture_dir}/scripts/lib/"

# Evita depender de endereço da máquina onde a regressão está sendo executada.
# O preflight copiado continua real, mas não exige privilégios para testar a
# rejeição WSL, que ocorre antes de qualquer acesso a systemd ou ao cluster.
cat >>"${fixture_dir}/scripts/lib/common.sh" <<'EOF'
require_root() { :; }
node_ip_is_local_physical() { [[ "$1" == "192.0.2.10" ]]; }
is_wsl2() { return 0; }
EOF

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
expect_failure() {
  local description="$1" expected_message="$2"
  shift 2
  if "$@" </dev/null >"${temporary_dir}/output" 2>&1; then
    fail "${description}: comando aceitou a configuração inválida"
  fi
  grep -Fq -- "${expected_message}" "${temporary_dir}/output" \
    || { cat -- "${temporary_dir}/output" >&2; fail "${description}: erro diferente do esperado"; }
}

write_config() {
  printf 'NODE_IP=%q\nRANCHER_URL=%q\nHEADLAMP_HOST=%q\n' \
    "$1" "$2" "headlamp.hml.example" >"${temporary_dir}/cluster.env"
}

write_config 192.0.2.10 https://rancher.hml.example:8443
cp -- "${temporary_dir}/cluster.env" "${temporary_dir}/expected.env"
bash "${fixture_dir}/configure-install.sh" "${temporary_dir}/cluster.env" </dev/null \
  >"${temporary_dir}/output" 2>&1
cmp -s "${temporary_dir}/cluster.env" "${temporary_dir}/expected.env" \
  || fail "configuração não interativa alterou parâmetros já preenchidos"
[[ "$(stat -c '%a' "${temporary_dir}/cluster.env")" == "600" ]] \
  || fail "configuração não recebeu modo 0600"

expect_failure "configuração incompleta sem terminal" "execução não interativa" \
  bash "${fixture_dir}/configure-install.sh" "${temporary_dir}/new.env"
write_config 192.0.2.10 http://rancher.hml.example
expect_failure "Rancher sem HTTPS" "RANCHER_URL precisa ser" \
  bash "${fixture_dir}/configure-install.sh" "${temporary_dir}/cluster.env"
write_config 192.0.2.11 https://rancher.hml.example
expect_failure "IP ausente na VM" "precisa ser um IPv4 presente" \
  bash "${fixture_dir}/configure-install.sh" "${temporary_dir}/cluster.env"
write_config 192.0.2.10 https://rancher.hml.example
expect_failure "preflight WSL" "Use kubernetes-wsl" \
  env K8S_CONFIG_FILE="${temporary_dir}/cluster.env" \
  bash "${fixture_dir}/scripts/00-preflight.sh"

export K8S_CONFIG_FILE="${temporary_dir}/cluster.env"
# shellcheck source=../scripts/lib/common.sh
source "${ROOT_DIR}/scripts/lib/common.sh"

for invalid_ip in 192.168.1.10. 192.168.1.10.5 256.0.0.1 192.168.1.10/24; do
  if valid_ipv4 "${invalid_ip}"; then
    fail "valid_ipv4 aceitou ${invalid_ip}"
  fi
done
valid_ipv4 192.168.1.10 || fail "IPv4 válido foi recusado"
for invalid_url in http://rancher.hml.example https://user:password@rancher.hml.example \
  https://rancher.hml.example/path https://rancher.hml.example:0 \
  https://rancher.hml.example:65536 https://192.168.1.10.; do
  if valid_https_url "${invalid_url}"; then
    fail "valid_https_url aceitou ${invalid_url}"
  fi
done
valid_https_url https://rancher.hml.example:8443 || fail "URL HTTPS válida foi recusada"
ipv4_cidrs_overlap 10.96.0.0/12 10.100.0.0/16 || fail "sobreposição de redes não detectada"
ipv4_cidrs_overlap 10.100.0.0/16 10.96.0.0/12 || fail "sobreposição reversa não detectada"
if ipv4_cidrs_overlap 10.244.0.0/16 192.168.1.0/24; then
  fail "redes independentes consideradas sobrepostas"
fi
if valid_ipv4_cidr 10.244.0.0/08; then
  ipv4_cidrs_overlap 10.244.0.0/08 10.244.0.0/16 \
    || fail "CIDR validado com prefixo decimal 08 não foi calculado corretamente"
fi
[[ "$(duration_to_seconds 08m)" == "480" ]] || fail "timeout decimal com zero inicial calculado incorretamente"
if duration_to_seconds 0s >/dev/null; then
  fail "timeout de zero aceito"
fi
printf 'PASS: configuração não interativa, rejeição WSL, IPv4, CIDR, HTTPS e timeouts.\n'
