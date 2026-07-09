#!/usr/bin/env bash
# One-time (re-runnable) provisioning for download.malibu.tech on Pearl VPS.
#
# DNS lives at name.com (malibu.tech NS). Add before certbot can succeed:
#   download.malibu.tech  A  159.223.165.194  TTL 300
#
# Installs nginx vhost + Let's Encrypt cert + /var/www/malibu-download docroot.
# Publish release assets with scripts/publish-malibu-latest-dmg.sh.
#
# Usage:
#   bash scripts/setup-malibu-download-pearl.sh
#
# Environment:
#   SSH_KEY    default ~/.ssh/pearl_operator_ed25519
#   VPS_HOST   default 159.223.165.194
#   VPS_USER   default root
#   DOMAIN     default download.malibu.tech
#   EMAIL      default augstar@gmail.com
#   SKIP_DNS_WAIT=1   install nginx/docroot without waiting for public DNS
#   PUBLISH_TAG=v1.8.19  run publish-malibu-latest-dmg.sh after setup

set -euo pipefail

SSH_KEY="${SSH_KEY:-$HOME/.ssh/pearl_operator_ed25519}"
VPS_HOST="${VPS_HOST:-159.223.165.194}"
VPS_USER="${VPS_USER:-root}"
DOMAIN="${DOMAIN:-download.malibu.tech}"
EMAIL="${EMAIL:-augstar@gmail.com}"
PUBLISH_TAG="${PUBLISH_TAG:-}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NGINX_SITE="$SCRIPT_DIR/dist/nginx-download.malibu.tech.conf"

[[ -f "$NGINX_SITE" ]] || { echo "missing $NGINX_SITE" >&2; exit 1; }
[[ -f "$SSH_KEY" ]] || { echo "missing SSH key: $SSH_KEY" >&2; exit 1; }

MALIBU_DOWNLOAD_SSH_CONNECT_TIMEOUT=10
# shellcheck source=malibu-download-ssh.sh
source "$SCRIPT_DIR/malibu-download-ssh.sh"

log() { printf '[setup-malibu-download-pearl] %s\n' "$*"; }

dns_ready() {
  local ip
  for resolver in '' '@ns1jlp.name.com' '@8.8.8.8' '@1.1.1.1'; do
    if [[ -z "$resolver" ]]; then
      ip="$(dig +short "$DOMAIN" A 2>/dev/null | head -1)"
    else
      ip="$(dig +short "$DOMAIN" A "${resolver#@}" 2>/dev/null | head -1)"
    fi
    [[ "$ip" == "$VPS_HOST" ]] && return 0
  done
  return 1
}

print_namecom_dns() {
  cat <<EOF

name.com DNS — use the **malibu.tech** zone (NOT streamvc.live):
  Host: download
  Type: A
  Answer: ${VPS_HOST}
  TTL: 300

Malibu Sparkle checks https://download.malibu.tech/appcast.xml (not download.streamvc.live).

Verify: dig +short ${DOMAIN} @8.8.8.8
EOF
}

log "step 1/7: confirm SSH"
malibu_download_ssh 'hostname >/dev/null && echo ok' >/dev/null

log "step 2/7: DNS check"
if dns_ready; then
  log "  ${DOMAIN} resolves to ${VPS_HOST}"
else
  print_namecom_dns
  if [[ "${SKIP_DNS_WAIT:-0}" != "1" ]]; then
    log "waiting for public DNS (up to ~5 min; set SKIP_DNS_WAIT=1 to install nginx only)"
    for i in $(seq 1 30); do
      if dns_ready; then
        log "  DNS ready"
        break
      fi
      [[ "$i" = 30 ]] && {
        log "DNS still missing — continuing with nginx/docroot only (no cert yet)"
        SKIP_CERT=1
        break
      }
      sleep 10
    done
  else
    log "  SKIP_DNS_WAIT=1 — skipping DNS wait"
    SKIP_CERT=1
  fi
fi

log "step 3/7: ensure certbot + docroot on Pearl"
malibu_download_ssh "set -e
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -qq -y certbot python3-certbot-nginx nginx >/dev/null || true
  install -d -o www-data -g www-data -m 0755 /var/www/html
  install -d -o www-data -g www-data -m 0755 /var/www/malibu-download
"

log "step 4/7: upload nginx site + install port-80 stub"
malibu_download_scp "$NGINX_SITE" "$VPS_USER@$VPS_HOST:/tmp/nginx-malibu-download.conf" >/dev/null
malibu_download_ssh "set -e
  if [ ! -f /etc/letsencrypt/live/$DOMAIN/fullchain.pem ]; then
    cat > /etc/nginx/sites-available/$DOMAIN <<'NGINX_STUB'
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    root /var/www/malibu-download;
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location = /appcast.xml {
        default_type application/xml;
        try_files \$uri =404;
    }
    location ~* \\.dmg\$ {
        default_type application/octet-stream;
        try_files \$uri =404;
    }
    location ~* \\.sha256\$ {
        default_type text/plain;
        try_files \$uri =404;
    }
    location / { return 404; }
}
NGINX_STUB
    ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/$DOMAIN
    nginx -t && systemctl reload nginx
  fi
"

if [[ "${SKIP_CERT:-0}" != "1" ]] && dns_ready; then
  log "step 5/7: obtain Let's Encrypt cert (webroot)"
  malibu_download_ssh "set -e
    if [ -f /etc/letsencrypt/live/$DOMAIN/fullchain.pem ]; then
      echo '  cert already present'
    else
      certbot certonly --webroot -w /var/www/html -d $DOMAIN --non-interactive --agree-tos --email $EMAIL
    fi
  "

  log "step 6/7: install full TLS vhost"
  malibu_download_ssh "set -e
    install -o root -g root -m 0644 /tmp/nginx-malibu-download.conf /etc/nginx/sites-available/$DOMAIN
    rm -f /tmp/nginx-malibu-download.conf
    ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/$DOMAIN
    nginx -t && systemctl reload nginx
  "
else
  log "step 5-6/7: skipped TLS (add name.com A record, then re-run without SKIP_DNS_WAIT)"
  malibu_download_ssh "rm -f /tmp/nginx-malibu-download.conf" || true
fi

log "step 7/7: verify Pearl endpoint"
if curl -fsS --max-time 15 --resolve "$DOMAIN:443:$VPS_HOST" "https://$DOMAIN/appcast.xml" >/dev/null 2>&1; then
  log "  https://${DOMAIN}/appcast.xml reachable via Pearl TLS"
elif curl -fsS --max-time 15 --resolve "$DOMAIN:80:$VPS_HOST" "http://$DOMAIN/" >/dev/null 2>&1; then
  log "  HTTP stub on Pearl OK — TLS pending name.com A record + certbot re-run"
else
  log "  Pearl docroot ready; run publish-malibu-latest-dmg.sh after DNS"
fi

if [[ -n "$PUBLISH_TAG" ]]; then
  bash "$SCRIPT_DIR/publish-malibu-latest-dmg.sh" "$PUBLISH_TAG"
fi

log "DONE. After DNS + cert: bash scripts/publish-malibu-latest-dmg.sh vX.Y.Z && bash scripts/verify-malibu-download.sh"
