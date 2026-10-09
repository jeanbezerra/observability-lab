#!/usr/bin/env bash

# Requer common.sh. O endpoint não usa tokens e nunca segue redirecionamentos,
# imprime respostas HTTP ou mostra stderr arbitrário do curl.
# shellcheck source=rancher-ca.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/rancher-ca.sh"

validate_rancher_endpoint() {
  # Evita imprimir respostas/erros brutos quando o chamador herdou xtrace.
  set +x
  use_cached_rancher_ca
  local rancher_url="${RANCHER_URL:-}" ca_file="${RANCHER_CA_FILE:-}"
  local endpoint_temporary_dir http_status curl_status=0 curl_error failure="" detail=""
  local ping_response
  # --disable precisa ser o primeiro argumento: um .curlrc local não pode
  # habilitar insecure, redirects ou adicionar cabeçalhos/credenciais ao teste.
  local -a curl_options=(--disable --silent --show-error --proto '=https'
    --connect-timeout 15 --max-time 30 --max-filesize 4096)

  rancher_url="${rancher_url%/}"
  valid_https_url "${rancher_url}" \
    || die "RANCHER_URL deve ser HTTPS com hostname/IP e porta opcional, sem credenciais, caminho ou query."
  require_command curl
  if [[ -n "${ca_file}" ]]; then
    [[ -f "${ca_file}" && -r "${ca_file}" ]] \
      || die "RANCHER_CA_FILE deve apontar para a cadeia CA pública local em PEM."
    curl_options+=(--cacert "${ca_file}")
  fi

  endpoint_temporary_dir="$(mktemp -d)" \
    || die "Não foi possível criar o diretório temporário do teste Rancher."
  # O stderr é analisado somente para mensagens conhecidas. A resposta fica em
  # arquivo privado e não entra em logs, inclusive se o proxy devolver HTML.
  if http_status="$(curl "${curl_options[@]}" \
    --output "${endpoint_temporary_dir}/body" --write-out '%{http_code}' \
    "${rancher_url}/ping" 2>"${endpoint_temporary_dir}/stderr")"; then
    curl_status=0
  else
    curl_status=$?
  fi
  curl_error="$(cat -- "${endpoint_temporary_dir}/stderr")"

  if (( curl_status != 0 )); then
    case "${curl_status}" in
      5) failure="DNS do proxy indisponível; verifique HTTPS_PROXY e a resolução do proxy" ;;
      6) failure="DNS do Rancher indisponível; verifique a resolução do hostname na VM" ;;
      7) failure="conexão TCP recusada ou indisponível; verifique a rota, a porta HTTPS e o firewall" ;;
      28) failure="timeout de conexão/resposta; verifique a rota, o firewall e o proxy" ;;
      35) failure="falha no handshake TLS; verifique TLS, SNI e a configuração do proxy/servidor" ;;
      60)
        case "${curl_error,,}" in
          *'certificate has expired'*|*'cert_e_expired'*) detail="certificado expirado" ;;
          *'certificate is not yet valid'*) detail="certificado ainda não válido; confira o relógio da VM" ;;
          *'no alternative certificate subject name matches'*|*'certificate subject name'*|*'cert_e_cn_no_match'*)
            detail="nome do certificado não corresponde ao hostname" ;;
          *'sec_e_untrusted_root'*|*'cert_e_untrustedroot'*|*'self-signed certificate'*|*'unable to get local issuer certificate'*|*'unable to verify the first certificate'*)
            detail="CA/cadeia do certificado não confiável" ;;
          *) detail="certificado ou cadeia CA não validado" ;;
        esac
        failure="${detail}; configure RANCHER_CA_FILE com a CA pública da administração do Rancher, ou use test-rancher.sh --configure-ca para descobrir e autorizar o fingerprint; confira cadeia, hostname e validade"
        ;;
      63) failure="resposta excedeu o limite de 4096 bytes esperado para /ping; verifique o proxy e o destino" ;;
      77) failure="arquivo CA inválido ou ilegível pelo curl; confira RANCHER_CA_FILE e o formato PEM" ;;
      *) failure="requisição HTTPS não concluída; verifique conectividade, TLS e proxy" ;;
    esac
    rm -f -- "${endpoint_temporary_dir}/body" "${endpoint_temporary_dir}/stderr"
    rmdir -- "${endpoint_temporary_dir}"
    die "Rancher /ping: curl=${curl_status}; ${failure}. TLS permanece obrigatório."
  fi

  if [[ ! "${http_status}" =~ ^[0-9]{3}$ ]]; then
    failure="curl não retornou um status HTTP válido"
  elif [[ "${http_status}" =~ ^3[0-9]{2}$ ]]; then
    failure="HTTP ${http_status}: redirecionamento recusado; configure a URL HTTPS final e revise o proxy"
  elif [[ "${http_status}" != "200" ]]; then
    failure="HTTP ${http_status}: /ping deve responder 200; revise o proxy, autenticação externa e disponibilidade do Rancher"
  else
    ping_response="$(cat -- "${endpoint_temporary_dir}/body")"
    [[ "${ping_response}" == "pong" ]] \
      || failure="HTTP 200 com corpo inesperado; /ping deve responder pong; revise o proxy e o destino"
  fi
  rm -f -- "${endpoint_temporary_dir}/body" "${endpoint_temporary_dir}/stderr"
  rmdir -- "${endpoint_temporary_dir}"
  [[ -z "${failure}" ]] || die "Rancher /ping: curl=0; ${failure}. Corpo da resposta omitido."
  log "Endpoint /ping do Rancher externo validado com TLS: HTTP 200, pong."
}
