#!/usr/bin/env bash
# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
require_root
validate_config
target=/etc/nginx/sites-available/rancher
temporary="$(mktemp)"
trap 'rm -f -- "${temporary}"' EXIT
cat >"${temporary}" <<EOF
map \$http_upgrade \$rancher_connection_upgrade { default upgrade; '' close; }
server {
    listen 80;
    listen [::]:80;
    server_name ${RANCHER_FQDN};
    return 301 https://${RANCHER_FQDN}\$request_uri;
}
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${RANCHER_FQDN};
    ssl_certificate "${TLS_CERT_FILE}";
    ssl_certificate_key "${TLS_KEY_FILE}";
    ssl_protocols TLSv1.2 TLSv1.3;
    client_max_body_size 0;
    location / {
        proxy_pass http://127.0.0.1:${RANCHER_BACKEND_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Port 443;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$rancher_connection_upgrade;
        proxy_read_timeout 900s;
        proxy_send_timeout 900s;
        proxy_buffering off;
    }
}
EOF
if check_requested "${1:-}"; then
  cmp -s "${temporary}" "${target}" || die 'Configuração Nginx pendente.'
  [[ "$(readlink -f /etc/nginx/sites-enabled/rancher)" == "${target}" ]] || die 'Site Rancher não está habilitado.'
  nginx -t
  if ! systemctl is-active --quiet nginx || ! systemctl is-enabled --quiet nginx; then die 'Serviço Nginx pendente.'; fi
  exit 0
fi
backup=""
if [[ -e "${target}" ]]; then
  install -d -m 0700 /var/lib/rancher-bootstrap/backups
  backup="/var/lib/rancher-bootstrap/backups/nginx-$(date '+%Y%m%d-%H%M%S%z')-$$.conf"
  cp -p -- "${target}" "${backup}"
fi
install -m 0644 "${temporary}" "${target}"
ln -sfn "${target}" /etc/nginx/sites-enabled/rancher
if ! nginx -t; then
  if [[ -n "${backup}" ]]; then cp -p -- "${backup}" "${target}"; else rm -f -- "${target}" /etc/nginx/sites-enabled/rancher; fi
  die 'Nginx inválido; configuração anterior restaurada.'
fi
systemctl enable --now nginx
systemctl reload nginx
