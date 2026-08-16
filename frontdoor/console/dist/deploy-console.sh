#!/usr/bin/env bash
# deploy-console.sh — deploy the Mac Provider front-door static site to
# console.malibu.tech on the Pearl VPS.
#
# Run from the operator's Mac. Idempotent: re-running against an
# already-deployed console is a safe no-op (DNS create skipped if the
# record exists, cert issuance skipped if the cert exists, static file
# re-copied). Mirrors phase4-coordinator/dist/deploy-pearl-vps.sh.
#
# What it does:
#   0. freshness check — compare local repo / Pearl-deployed / origin/main
#      sha256 for index.html; refuse to silently overwrite Pearl drift
#   1. confirm SSH
#   2. ensure DNS A record console.malibu.tech -> VPS (Cloudflare API,
#      DNS-only) — created if missing, skipped if present
#   3. wait for the name to resolve to the VPS (required before certbot)
#   4. install a port-80 stub vhost (ACME challenge), reload nginx
#   5. obtain the Let's Encrypt cert via webroot (skipped if present)
#   6. install the full TLS vhost, reload nginx
#   7. copy index.html to /var/www/console
#   8. verify the public endpoint + cert
#
# Architecture (decision Bδ): browser -> static HTML on nginx -> direct
# fetch() to https://api.malibu.tech (strict-allowlist CORS). No Vercel,
# no proxy hop.
#
# Usage:
#   bash deploy-console.sh
#
# Environment:
#   SSH_KEY    default: ~/.ssh/pearl_operator_ed25519
#   VPS_HOST   default: 159.223.165.194
#   VPS_USER   default: root
#   DOMAIN     default: console.malibu.tech
#   EMAIL      default: augstar@gmail.com (Let's Encrypt)
#   CF_TOKEN_FILE default: ~/.config/macprovider/cloudflare-api-token
#                  (Cloudflare API token scoped to Zone:DNS:Edit on malibu.tech;
#                   only needed if the DNS record does not already exist)
#   FORCE_OVERWRITE=1  bypass the step-0 freshness gate when local diverges
#                      from origin/main (intentional hot-fix deploy)
#   SKIP_FRESHNESS=1   skip step 0 entirely (offline / first-deploy / no git)

set -euo pipefail

SSH_KEY="${SSH_KEY:-$HOME/.ssh/pearl_operator_ed25519}"
VPS_HOST="${VPS_HOST:-159.223.165.194}"
VPS_USER="${VPS_USER:-root}"
DOMAIN="${DOMAIN:-console.malibu.tech}"
EMAIL="${EMAIL:-augstar@gmail.com}"
CF_TOKEN_FILE="${CF_TOKEN_FILE:-$HOME/.config/macprovider/cloudflare-api-token}"
CF_ZONE_NAME="malibu.tech"

DIST_DIR="$(cd "$(dirname "$0")" && pwd)"
INDEX="$DIST_DIR/../index.html"
FAVICON="$DIST_DIR/../favicon.svg"
NGINX_SITE="$DIST_DIR/nginx-console.malibu.tech.conf"

for f in "$INDEX" "$FAVICON" "$NGINX_SITE"; do
  [ -f "$f" ] || { echo "missing required file: $f" >&2; exit 1; }
done

SSH="ssh -i $SSH_KEY -o ConnectTimeout=10 -p 22 $VPS_USER@$VPS_HOST"
SCP="scp -i $SSH_KEY -P 22"

log() { printf "\n[console-deploy] %s\n" "$*"; }

# ─── step 0/8: freshness gate ──────────────────────────────────────────
# Catches the "code-shipped-not-routed" pattern (decision-log Entry 86 +
# Entry 138 silent drift): Pearl ran 5 commits behind origin/main on
# index.html for 23 days because no one re-ran this script. This gate
# makes the staleness loud at the start of every deploy.
if [ "${SKIP_FRESHNESS:-0}" != "1" ]; then
  log "step 0/8: freshness gate (local vs Pearl vs origin/main)"

  LOCAL_SHA="$(sha256sum "$INDEX" | awk '{print $1}')"
  PEARL_SHA="$(curl -fsS --max-time 10 --resolve "$DOMAIN:443:$VPS_HOST" \
               "https://$DOMAIN/" 2>/dev/null | sha256sum | awk '{print $1}')"

  REPO_ROOT="$(cd "$DIST_DIR/../../.." && pwd)"
  ORIGIN_SHA=""
  ORIGIN_AGE_LINE=""
  if (cd "$REPO_ROOT" && git rev-parse --git-dir >/dev/null 2>&1); then
    (cd "$REPO_ROOT" && git fetch -q origin main 2>/dev/null || true)
    ORIGIN_SHA="$(cd "$REPO_ROOT" && git show origin/main:frontdoor/console/index.html 2>/dev/null | sha256sum | awk '{print $1}')"
    # Find the most-recent commit on origin/main touching this file and
    # the commit whose blob matches Pearl's served bytes (if any).
    if [ -n "$PEARL_SHA" ]; then
      ORIGIN_AGE_LINE="$(cd "$REPO_ROOT" && \
        for sha in $(git log origin/main --pretty=format:'%h' -- frontdoor/console/index.html 2>/dev/null); do
          blob=$(git show "$sha":frontdoor/console/index.html 2>/dev/null | sha256sum | awk '{print $1}')
          if [ "$blob" = "$PEARL_SHA" ]; then
            git log -1 --pretty=format:'  Pearl bytes match commit %h (%ar) — %s' "$sha"
            break
          fi
        done)"
    fi
  fi

  printf "  local sha256:        %s\n" "${LOCAL_SHA:-(unknown)}"
  printf "  Pearl-served sha256: %s\n" "${PEARL_SHA:-(unreachable)}"
  printf "  origin/main sha256:  %s\n" "${ORIGIN_SHA:-(no git or no fetch)}"
  [ -n "$ORIGIN_AGE_LINE" ] && echo "$ORIGIN_AGE_LINE"

  # Decide what state we're in.
  if [ -n "$PEARL_SHA" ] && [ "$LOCAL_SHA" = "$PEARL_SHA" ]; then
    log "step 0/8 result: Pearl is already serving these bytes — nothing to deploy"
    log "DONE (no-op). Use SKIP_FRESHNESS=1 to force a redeploy anyway."
    exit 0
  fi

  if [ -n "$ORIGIN_SHA" ] && [ "$LOCAL_SHA" != "$ORIGIN_SHA" ]; then
    if [ "${FORCE_OVERWRITE:-0}" != "1" ]; then
      echo "  WARNING: local index.html differs from origin/main." >&2
      echo "  This deploy will ship un-pushed bytes to production." >&2
      echo "  Re-run with FORCE_OVERWRITE=1 to confirm intent." >&2
      exit 1
    fi
    log "step 0/8 result: FORCE_OVERWRITE=1 set — proceeding with local-diverged bytes"
  else
    log "step 0/8 result: deploying current origin/main"
  fi
fi

log "step 1/8: confirm SSH"
$SSH 'hostname >/dev/null && echo ok' >/dev/null

log "step 2/8: ensure DNS A record $DOMAIN -> $VPS_HOST (Cloudflare, DNS-only)"
if dig +short "$DOMAIN" A @1.1.1.1 2>/dev/null | grep -q "$VPS_HOST" \
   || dig +short "$DOMAIN" A @8.8.8.8 2>/dev/null | grep -q "$VPS_HOST"; then
  echo "  DNS already resolves to $VPS_HOST — skipping create"
elif [ -f "$CF_TOKEN_FILE" ]; then
  CF_TOKEN="$(tr -d ' \n\r' < "$CF_TOKEN_FILE")"
  SUB="${DOMAIN%.$CF_ZONE_NAME}"
  ZONE_ID="$(curl -sS -H "Authorization: Bearer $CF_TOKEN" \
    "https://api.cloudflare.com/client/v4/zones?name=$CF_ZONE_NAME" \
    | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['result'][0]['id'] if d.get('result') else '')")"
  [ -n "$ZONE_ID" ] || { echo "could not resolve Cloudflare zone id for $CF_ZONE_NAME" >&2; exit 1; }
  EXISTING="$(curl -sS -H "Authorization: Bearer $CF_TOKEN" \
    "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?name=$DOMAIN" \
    | python3 -c "import sys,json;print(len(json.load(sys.stdin).get('result',[])))")"
  if [ "$EXISTING" = "0" ]; then
    echo "  creating A record $SUB -> $VPS_HOST (proxied=false, ttl=300)"
    curl -sS -X POST -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" \
      "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
      --data "{\"type\":\"A\",\"name\":\"$SUB\",\"content\":\"$VPS_HOST\",\"ttl\":300,\"proxied\":false}" \
      | python3 -c "import sys,json;d=json.load(sys.stdin);sys.exit(0) if d.get('success') else (print('CF error:',d.get('errors'),file=sys.stderr) or sys.exit(1))"
  else
    echo "  record exists in Cloudflare but not yet resolving — waiting on propagation"
  fi
else
  echo "  DNS does not resolve and no Cloudflare token at $CF_TOKEN_FILE." >&2
  echo "  Create A record $DOMAIN -> $VPS_HOST (DNS-only) manually, then re-run." >&2
  exit 1
fi

log "step 3/8: wait for $DOMAIN to resolve to $VPS_HOST (certbot prerequisite)"
for i in $(seq 1 30); do
  if dig +short "$DOMAIN" A @8.8.8.8 2>/dev/null | grep -q "$VPS_HOST"; then
    echo "  resolves via 8.8.8.8"; break
  fi
  [ "$i" = 30 ] && { echo "DNS did not resolve to $VPS_HOST after ~5min" >&2; exit 1; }
  sleep 10
done

log "step 4/8: upload files + install port-80 stub vhost (ACME)"
$SCP "$INDEX" "$VPS_USER@$VPS_HOST:/tmp/console-index.html" >/dev/null
$SCP "$FAVICON" "$VPS_USER@$VPS_HOST:/tmp/console-favicon.svg" >/dev/null
$SCP "$NGINX_SITE" "$VPS_USER@$VPS_HOST:/tmp/nginx-console-full.conf" >/dev/null
$SSH "set -e
  install -d -o www-data -g www-data -m 0755 /var/www/html
  if [ ! -f /etc/letsencrypt/live/$DOMAIN/fullchain.pem ]; then
    cat > /etc/nginx/sites-available/$DOMAIN <<'NGINX_STUB'
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://\$host\$request_uri; }
}
NGINX_STUB
    ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/$DOMAIN
    nginx -t && systemctl reload nginx
  else
    echo '  cert already present — skipping stub'
  fi
"

log "step 5/8: obtain Let's Encrypt cert via webroot (idempotent)"
$SSH "set -e
  if [ -f /etc/letsencrypt/live/$DOMAIN/fullchain.pem ]; then
    echo '  cert already present at /etc/letsencrypt/live/$DOMAIN/ — skipping'
  else
    certbot certonly --webroot -w /var/www/html -d $DOMAIN --non-interactive --agree-tos --email $EMAIL
  fi
"

log "step 6/8: install full TLS vhost"
$SSH "set -e
  install -o root -g root -m 0644 /tmp/nginx-console-full.conf /etc/nginx/sites-available/$DOMAIN
  rm -f /tmp/nginx-console-full.conf
  ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/$DOMAIN
  nginx -t && systemctl reload nginx
"

log "step 7/8: install static files to /var/www/console"
$SSH "set -e
  install -d -o www-data -g www-data -m 0755 /var/www/console
  install -o www-data -g www-data -m 0644 /tmp/console-index.html /var/www/console/index.html
  install -o www-data -g www-data -m 0644 /tmp/console-favicon.svg /var/www/console/favicon.svg
  rm -f /tmp/console-index.html /tmp/console-favicon.svg
"

log "step 8/8: verify public endpoint + cert"
sleep 1
curl -fsS --max-time 10 --resolve "$DOMAIN:443:$VPS_HOST" "https://$DOMAIN/" >/dev/null \
  && echo "  https://$DOMAIN serves 200" || { echo "  page check FAILED" >&2; exit 1; }
echo | openssl s_client -servername "$DOMAIN" -connect "$VPS_HOST:443" 2>/dev/null \
  | openssl x509 -noout -subject -enddate 2>/dev/null || true

log "DONE. console is live at https://$DOMAIN"
echo "  (if your local resolver still NXDOMAINs, it is negative-cache TTL = SOA min 1800s;"
echo "   verify with: dig +short $DOMAIN @8.8.8.8)"
