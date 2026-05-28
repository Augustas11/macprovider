#!/usr/bin/env bash
# deploy-pearl-vps.sh — Stage 2 of the Phase 4 coordinator VPS deploy.
#
# Run this from the operator's Mac. It SSHes into Pearl VPS, installs the
# coordinator behind nginx + Let's Encrypt, and verifies the public
# endpoint. Idempotent — re-running won't break a working deploy.
#
# Prerequisites done in Stage 1:
#   - coordinator-linux-amd64 cross-compiled into dist/
#   - coordinator.yaml + service unit + nginx site config drafted in dist/
#   - DNS A record coordinator.streamvc.live -> 159.223.165.194 (DNS-only)
#
# Usage:
#   bash deploy-pearl-vps.sh
#
# Environment:
#   SSH_KEY      default: ~/.ssh/pearl_operator_ed25519
#   VPS_HOST     default: 159.223.165.194
#   VPS_USER     default: root
#   DOMAIN       default: coordinator.streamvc.live
#   EMAIL        default: augstar@gmail.com (for Let's Encrypt)

set -euo pipefail

SSH_KEY="${SSH_KEY:-$HOME/.ssh/pearl_operator_ed25519}"
VPS_HOST="${VPS_HOST:-159.223.165.194}"
VPS_USER="${VPS_USER:-root}"
DOMAIN="${DOMAIN:-coordinator.streamvc.live}"
EMAIL="${EMAIL:-augstar@gmail.com}"

DIST_DIR="$(cd "$(dirname "$0")" && pwd)"
BINARY="$DIST_DIR/coordinator-linux-amd64"
CONFIG="$DIST_DIR/coordinator.yaml"
SERVICE="$DIST_DIR/macprovider-coordinator.service"
NGINX_SITE="$DIST_DIR/nginx-coordinator.streamvc.live.conf"

for f in "$BINARY" "$CONFIG" "$SERVICE" "$NGINX_SITE"; do
  [ -f "$f" ] || { echo "missing required file: $f" >&2; exit 1; }
done

SSH="ssh -i $SSH_KEY -o ConnectTimeout=10 -p 22 $VPS_USER@$VPS_HOST"
SCP="scp -i $SSH_KEY -P 22"

log() { printf "\n[deploy] %s\n" "$*"; }

log "step 1/9: confirm SSH + DNS"
$SSH 'hostname && uptime' >/dev/null
dig +short "$DOMAIN" | grep -q "$VPS_HOST" || { echo "DNS for $DOMAIN does not resolve to $VPS_HOST yet" >&2; exit 1; }

log "step 2/9: install certbot + nginx-snippets (apt)"
$SSH 'DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -qq -y certbot python3-certbot-nginx >/dev/null' || {
  echo "certbot install failed" >&2; exit 1;
}

log "step 3/9: create macprovider system user + dirs"
$SSH 'set -e
  id macprovider >/dev/null 2>&1 || useradd --system --home /opt/macprovider --shell /usr/sbin/nologin macprovider
  install -d -o macprovider -g macprovider -m 0755 /opt/macprovider
  install -d -o macprovider -g macprovider -m 0750 /var/lib/macprovider
  install -d -o macprovider -g macprovider -m 0750 /var/log/macprovider
'

log "step 4/9: upload binary + config + nginx site"
$SCP "$BINARY" "$VPS_USER@$VPS_HOST:/tmp/coordinator-linux-amd64"
$SCP "$CONFIG" "$VPS_USER@$VPS_HOST:/tmp/coordinator.yaml"
$SCP "$SERVICE" "$VPS_USER@$VPS_HOST:/tmp/macprovider-coordinator.service"
$SCP "$NGINX_SITE" "$VPS_USER@$VPS_HOST:/tmp/nginx-coordinator-full.conf"

$SSH "set -e
  install -o macprovider -g macprovider -m 0755 /tmp/coordinator-linux-amd64 /opt/macprovider/coordinator
  install -o macprovider -g macprovider -m 0600 /tmp/coordinator.yaml /opt/macprovider/coordinator.yaml
  install -o root -g root -m 0644 /tmp/macprovider-coordinator.service /etc/systemd/system/macprovider-coordinator.service
  rm -f /tmp/coordinator-linux-amd64 /tmp/coordinator.yaml /tmp/macprovider-coordinator.service
"

# nginx + Let's Encrypt strategy:
#   step 5  -> install a port-80-only STUB nginx site (ACME challenge + redirect).
#              No port 443 block, no ssl_certificate references, nginx -t passes.
#   step 6  -> certbot certonly --webroot (skipped if cert already present).
#   step 6b -> install the full TLS site, uncomment the ssl_certificate lines
#              that point at /etc/letsencrypt/live/<DOMAIN>/, reload.
#
# This sequence is idempotent and never mutates the user-authored nginx site
# config in place — earlier versions used in-place sed surgery on the full
# config and corrupted brace balance on first run.

log "step 5/9: install port-80 stub nginx site (for ACME challenge)"
$SSH "set -e
  install -d -o www-data -g www-data -m 0755 /var/www/html
  cat > /etc/nginx/sites-available/$DOMAIN <<'NGINX_STUB'
# Stub site — replaced by the full TLS config after Let's Encrypt cert
# is obtained. Only handles HTTP-01 challenge + redirect to https.
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }
    location / {
        return 301 https://\$host\$request_uri;
    }
}
NGINX_STUB
  ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/$DOMAIN
  nginx -t
  systemctl reload nginx
"

log "step 6/9: obtain Let's Encrypt cert via certbot webroot (idempotent)"
$SSH "set -e
  if [ -f /etc/letsencrypt/live/$DOMAIN/fullchain.pem ]; then
    echo '  cert already present at /etc/letsencrypt/live/$DOMAIN/ — skipping issuance'
  else
    certbot certonly --webroot -w /var/www/html -d $DOMAIN \\
      --non-interactive --agree-tos --email $EMAIL
  fi
"

log "step 6b/9: install full TLS nginx site"
$SSH "set -e
  install -o root -g root -m 0644 /tmp/nginx-coordinator-full.conf /etc/nginx/sites-available/$DOMAIN
  rm -f /tmp/nginx-coordinator-full.conf
  # The full site config ships with ssl_certificate lines commented; the
  # cert exists now so uncomment them. (Idempotent: re-running this on an
  # already-uncommented file is a no-op.)
  sed -i 's|# ssl_certificate /etc/letsencrypt|ssl_certificate /etc/letsencrypt|g' /etc/nginx/sites-available/$DOMAIN
  sed -i 's|# ssl_certificate_key /etc/letsencrypt|ssl_certificate_key /etc/letsencrypt|g' /etc/nginx/sites-available/$DOMAIN
  # Clean up the .full backup file from the broken v1 deploy if present.
  rm -f /etc/nginx/sites-available/$DOMAIN.full
  nginx -t
  systemctl reload nginx
"

log "step 6c/9: pre-restart safeguard (check for connected providers)"
# Coordinator restart triggers SPEC-001 § 6.5 drain on all connected
# providers. v1.1.3+ phase3-binary handles this gracefully (drops WS,
# keeps serving direct traffic, reconnects after grace period). Older
# phase3-binary (v1.1.2 and earlier) exits the process on drain — which
# kills tunnel-direct buyer traffic. Until you can guarantee every
# connected provider is on v1.1.3+, refuse to auto-restart with
# connected providers unless the operator passes --force-restart.
CONNECTED_COUNT=$(curl -fsS --max-time 5 "https://$DOMAIN/healthz" 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('pool_size', 0))" 2>/dev/null \
  || echo 0)
if [ "${CONNECTED_COUNT:-0}" -gt 0 ] && [ "${FORCE_RESTART:-0}" != "1" ]; then
  log "  REFUSING TO RESTART — $CONNECTED_COUNT provider(s) currently connected."
  log "  Restart triggers drain; phase3-binary <= v1.1.2 exits the process"
  log "  on drain and breaks tunnel-direct buyer traffic."
  log "  To proceed anyway:  FORCE_RESTART=1 bash $0"
  exit 4
fi
log "  ok: $CONNECTED_COUNT connected providers (or FORCE_RESTART=1 set)"

log "step 7/9: enable + start coordinator service"
$SSH 'set -e
  systemctl daemon-reload
  systemctl enable macprovider-coordinator
  systemctl restart macprovider-coordinator
  sleep 3
  systemctl is-active macprovider-coordinator
  ss -tlnp | grep -E ":8443|:8444"
'

log "step 8/9: verify public endpoints"
sleep 2
echo "  GET https://$DOMAIN/healthz"
curl -fsS --max-time 10 "https://$DOMAIN/healthz" | python3 -m json.tool || { echo "healthz failed"; exit 1; }
echo "  GET https://$DOMAIN/v1/models"
curl -fsS --max-time 10 "https://$DOMAIN/v1/models" | python3 -m json.tool || { echo "models failed"; exit 1; }

log "step 9/9: tail the coordinator journal for sanity"
$SSH 'journalctl -u macprovider-coordinator --no-pager -n 20'

log "DONE. coordinator is live at https://$DOMAIN"
echo
echo "Next steps:"
echo "  - Stage 3: restart M4 phase3-binary with --coordinator wss://$DOMAIN/ws/provider"
echo "  - Verify: providers should appear in /poolz (auth: bearer operator_key from coordinator.yaml)"
echo "  - End-to-end: run harness against https://$DOMAIN"
