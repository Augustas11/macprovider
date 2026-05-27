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

log "step 4/9: upload binary + config"
$SCP "$BINARY" "$VPS_USER@$VPS_HOST:/tmp/coordinator-linux-amd64"
$SCP "$CONFIG" "$VPS_USER@$VPS_HOST:/tmp/coordinator.yaml"
$SCP "$SERVICE" "$VPS_USER@$VPS_HOST:/tmp/macprovider-coordinator.service"
$SCP "$NGINX_SITE" "$VPS_USER@$VPS_HOST:/tmp/nginx-coordinator.conf"

$SSH "set -e
  install -o macprovider -g macprovider -m 0755 /tmp/coordinator-linux-amd64 /opt/macprovider/coordinator
  install -o macprovider -g macprovider -m 0600 /tmp/coordinator.yaml /opt/macprovider/coordinator.yaml
  install -o root -g root -m 0644 /tmp/macprovider-coordinator.service /etc/systemd/system/macprovider-coordinator.service
  rm -f /tmp/coordinator-linux-amd64 /tmp/coordinator.yaml /tmp/macprovider-coordinator.service
"

log "step 5/9: install nginx site for $DOMAIN"
$SSH "set -e
  install -o root -g root -m 0644 /tmp/nginx-coordinator.conf /etc/nginx/sites-available/$DOMAIN
  rm -f /tmp/nginx-coordinator.conf
  # Comment out the ssl_certificate lines for the first nginx -t — certbot adds them.
  ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/$DOMAIN
  # Drop a no-tls placeholder so nginx -t passes before certbot runs.
  sed -i 's|listen 443 ssl http2;|listen 443 ssl http2;\n    # certbot will fill ssl_certificate below|' /etc/nginx/sites-available/$DOMAIN || true
"

# certbot --nginx mode is the cleanest: it edits the site config in place
# to add ssl_certificate directives. We pass --redirect to ensure 80->443.
log "step 6/9: obtain Let's Encrypt cert via certbot --nginx"
$SSH "set -e
  # certbot needs a working port-80 server block for $DOMAIN. The site
  # config we just installed provides it. But the 443 block references
  # cert files that don't exist yet; comment them out so nginx -t passes.
  if ! nginx -t 2>&1 | grep -q 'syntax is ok'; then
    # Temporarily strip the entire 443 block so nginx -t passes.
    cp /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-available/$DOMAIN.full
    sed -i '/^server {\$/,/^}\$/{ /listen 443/,/^}\$/d }' /etc/nginx/sites-available/$DOMAIN || true
  fi
  nginx -t
  systemctl reload nginx
  certbot --nginx -d $DOMAIN --non-interactive --agree-tos --email $EMAIL --redirect
  # Restore full config (certbot will have re-added the 443 block with cert paths)
  nginx -t
  systemctl reload nginx
"

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
