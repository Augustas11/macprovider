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
CLI_BINARY="$DIST_DIR/coordinator-cli-linux-amd64"
CONFIG="$DIST_DIR/coordinator.yaml"
SERVICE="$DIST_DIR/macprovider-coordinator.service"
NGINX_SITE="$DIST_DIR/nginx-coordinator.streamvc.live.conf"

# coordinator-cli is required ALONGSIDE the daemon (SPEC-003 v0.8.3
# FR-C9.4 strict-reject path still requires `coordinator-cli
# revoke-token` for the used-token-persist-failure case; routine
# prune-tokens / list-tokens also belong on Pearl). If absent, the
# operator forgot to run build-linux.sh after the M2 update that
# extended it. Fail closed — do NOT silently deploy with a stale CLI.
for f in "$BINARY" "$CLI_BINARY" "$CONFIG" "$SERVICE" "$NGINX_SITE"; do
  [ -f "$f" ] || { echo "missing required file: $f" >&2; exit 1; }
done

SSH="ssh -i $SSH_KEY -o ConnectTimeout=10 -p 22 $VPS_USER@$VPS_HOST"
SCP="scp -i $SSH_KEY -P 22"

log() { printf "\n[deploy] %s\n" "$*"; }

log "step 0/9: pre-deploy config-drift + C2 cross-check"
# Fail closed before touching the VPS if the config to be deployed has a
# placeholder operator_key, an unsafe threshold, etc. (see check-deploy-config.sh).
# Catches the sanitized-config hazard that would otherwise break prod auth.
#
# M1-6 / DEVE-4: pass BOTH configs so the C2 timer cross-check runs.
# Previously only $CONFIG was passed, so check-deploy-config.sh silently
# skipped C2 on every standard coordinator deploy — the past-incident
# guard was effectively disabled.
# M1-6 follow-up (codex audits 2026-06-11): the previous .example fallback
# was a false fail-closed gate — production deploy could pass C2 using
# SAMPLE timeout values while the real VPS gateway.yaml had drifted.
# Sample config is documentation, not an operational input. Require a real
# gateway.yaml or an explicit SKIP_C2_CHECK=1 override.
GATEWAY_CONFIG_DEFAULT="$DIST_DIR/../../phase5-gateway/dist/gateway.yaml"
GATEWAY_CONFIG="${GATEWAY_CONFIG:-$GATEWAY_CONFIG_DEFAULT}"
if [ "${SKIP_C2_CHECK:-0}" = "1" ]; then
  echo "  SKIP_C2_CHECK=1 set — running coordinator-only check (C2 gate intentionally skipped)" >&2
  SKIP_C2_CHECK=1 bash "$DIST_DIR/check-deploy-config.sh" "$CONFIG" || {
    echo "aborting deploy: config-drift check failed" >&2; exit 5;
  }
else
  if [ ! -f "$GATEWAY_CONFIG" ]; then
    echo "aborting deploy: real gateway.yaml not found for C2 cross-check ($GATEWAY_CONFIG)." >&2
    echo "  Provide GATEWAY_CONFIG=<path-to-real-gateway.yaml> or set SKIP_C2_CHECK=1" >&2
    echo "  to deploy without the cross-check. gateway.yaml.example is sample" >&2
    echo "  documentation and intentionally NOT accepted here." >&2
    exit 5
  fi
  bash "$DIST_DIR/check-deploy-config.sh" "$CONFIG" "$GATEWAY_CONFIG" || {
    echo "aborting deploy: config-drift check failed" >&2; exit 5;
  }
fi

log "step 1/9: confirm SSH + DNS"
$SSH 'hostname && uptime' >/dev/null
dig +short "$DOMAIN" | grep -q "$VPS_HOST" || { echo "DNS for $DOMAIN does not resolve to $VPS_HOST yet" >&2; exit 1; }

# Previous-deploy bypass tombstone — if the last deploy used
# FORCE_RESTART=1 (or got manually bypassed past the connected-provider
# guard), step 1c or step 6c writes /var/lib/macprovider/last-deploy-bypass.json
# below. Surface it here so the operator can audit before scping a new
# binary. Does NOT exit — informational only. Remove the file once
# audited by the operator.
PREV_BYPASS=$($SSH 'cat /var/lib/macprovider/last-deploy-bypass.json 2>/dev/null || true')
if [ -n "$PREV_BYPASS" ]; then
  log "  NOTE: previous deploy left a bypass tombstone:"
  printf '%s\n' "$PREV_BYPASS" | sed 's/^/    /'
  log "  If audited, clear with: ssh <pearl> rm /var/lib/macprovider/last-deploy-bypass.json"
fi

log "step 1b/9: drift check vs live /opt/macprovider/coordinator.yaml"
# Catches the silent-config-change hazard. The 2026-06-11 deploy caused
# a brief outage because the local config dropped auth.require_provider_tokens
# entirely; the prior binary defaulted false, the new binary defaulted true,
# and providers were rejected. A field-level diff vs live is the tripwire
# that would have surfaced that drift before the restart.
#
# Secrets are masked in the SSH pipe so unmasked Pearl content never lands
# on local disk. Operator opts into pushing local-over-live with
# ALLOW_CONFIG_DRIFT=1.
normalize_yaml() {
  # Mask any field whose name ends in _key / _secret / _token, then strip
  # pure-comment lines and blanks so the drift check focuses on semantic
  # differences (values + structure) rather than comment-placement noise.
  sed -E 's/^([[:space:]]*[a-zA-Z0-9_]*(_key|_secret|_token)):[[:space:]]*.*$/\1: <MASKED>/' \
    | sed -E 's/[[:space:]]+#.*$//' \
    | grep -vE '^[[:space:]]*(#|$)'
}
LIVE_NORM=$($SSH 'cat /opt/macprovider/coordinator.yaml' 2>/dev/null | normalize_yaml) || {
  echo "could not pull live coordinator.yaml from Pearl for drift check" >&2; exit 6;
}
LOCAL_NORM=$(normalize_yaml < "$CONFIG")
if ! DRIFT_DIFF=$(diff <(printf '%s\n' "$LOCAL_NORM") <(printf '%s\n' "$LIVE_NORM")); then
  echo "" >&2
  echo "  CONFIG DRIFT detected (secrets masked; '<' = local, '>' = live):" >&2
  printf '%s\n' "$DRIFT_DIFF" | sed 's/^/    /' >&2
  echo "" >&2
  if [ "${ALLOW_CONFIG_DRIFT:-0}" != "1" ]; then
    echo "  Aborting. The local config will overwrite the live one on deploy." >&2
    echo "  Review the diff above. To proceed (pushing local over live):" >&2
    echo "    ALLOW_CONFIG_DRIFT=1 $0" >&2
    exit 8
  fi
  echo "  ALLOW_CONFIG_DRIFT=1 set — proceeding despite drift." >&2
else
  echo "  ok: local config matches live (modulo secrets)"
fi

log "step 1c/9: early connected-provider check"
# Mirror of step 6c, run BEFORE binary swap so a refusal does not leave
# the operator with new code on disk and old code running. The full
# script does the connected-provider check twice on purpose:
#   - step 1c here: protects the longest part of the window (between
#     step 4 binary install and step 7 restart, which spans certbot +
#     nginx work and can take minutes); refusing here saves the scp.
#   - step 6c just before restart: protects against providers that
#     connected DURING the deploy itself (between step 1c and step 7).
# Both honor FORCE_RESTART=1, which writes a sticky tombstone at
# /var/lib/macprovider/last-deploy-bypass.json so the NEXT deploy
# notices the operator override (see step 1's PREV_BYPASS surface).
CONNECTED_COUNT_EARLY=$(curl -fsS --max-time 5 --max-filesize 65536 "https://$DOMAIN/healthz" 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('pool_size', 0))" 2>/dev/null \
  || echo 0)
if [ "${CONNECTED_COUNT_EARLY:-0}" -gt 0 ] && [ "${FORCE_RESTART:-0}" != "1" ]; then
  log "  REFUSING TO DEPLOY — $CONNECTED_COUNT_EARLY provider(s) currently connected."
  log "  Restart at step 7 would trigger SPEC-001 § 6.5 drain on these providers."
  log "  Refusing EARLY (pre-scp) so you don't leave a new binary on disk."
  log "  To proceed anyway:  FORCE_RESTART=1 bash $0"
  exit 4
fi
if [ "${FORCE_RESTART:-0}" = "1" ] && [ "${CONNECTED_COUNT_EARLY:-0}" -gt 0 ]; then
  TS_NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  OP_HOST="${HOSTNAME:-unknown}"
  $SSH "set -e
        install -d -o macprovider -g macprovider -m 0750 /var/lib/macprovider 2>/dev/null || true
        cat > /tmp/last-deploy-bypass.json <<EOF
{\"ts\":\"$TS_NOW\",\"service\":\"coordinator\",\"reason\":\"FORCE_RESTART=1\",\"step\":\"1c\",\"metric\":\"connected_providers\",\"value\":$CONNECTED_COUNT_EARLY,\"operator_host\":\"$OP_HOST\"}
EOF
        install -o macprovider -g macprovider -m 0640 /tmp/last-deploy-bypass.json /var/lib/macprovider/last-deploy-bypass.json
        rm -f /tmp/last-deploy-bypass.json
        logger -t macprovider-deploy \"FORCE_RESTART=1 used at step 1c; connected=$CONNECTED_COUNT_EARLY\""
  log "  AUDIT TRAIL: FORCE_RESTART=1 override written to /var/lib/macprovider/last-deploy-bypass.json"
fi
log "  ok: $CONNECTED_COUNT_EARLY connected providers (or FORCE_RESTART=1 set)"

log "step 2/9: install certbot + nginx-snippets (apt)"
$SSH 'DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -qq -y certbot python3-certbot-nginx >/dev/null' || {
  echo "certbot install failed" >&2; exit 1;
}

log "step 3/9: create macprovider system user + dirs"
# codex PR #73 fixup:
#   - /var/lib/macprovider-monitor — writable carve-out for the de-rooted
#     monitor under ProtectSystem=strict (HIGH-2 sandbox). Systemd would
#     also create this via StateDirectory= at unit start, but creating it
#     up-front guarantees correct ownership before the first activation.
#   - /etc/macprovider — operator-rooted directory holding coordinator.env.
#     The env file is read by the coordinator unit (root) and by the de-rooted
#     monitor (macprovider). Mode 0750 lets macprovider read it via group;
#     coordinator.env itself ships mode 0640 root:macprovider (LOW-fix).
$SSH 'set -e
  id macprovider >/dev/null 2>&1 || useradd --system --home /opt/macprovider --shell /usr/sbin/nologin macprovider
  install -d -o macprovider -g macprovider -m 0755 /opt/macprovider
  install -d -o macprovider -g macprovider -m 0750 /var/lib/macprovider
  install -d -o macprovider -g macprovider -m 0750 /var/log/macprovider
  install -d -o macprovider -g macprovider -m 0750 /var/lib/macprovider-monitor
  install -d -o root -g macprovider -m 0750 /etc/macprovider
  if [ -f /etc/macprovider/coordinator.env ]; then
    chown root:macprovider /etc/macprovider/coordinator.env
    chmod 0640 /etc/macprovider/coordinator.env
    echo "  enforced coordinator.env perms: root:macprovider 0640"
  else
    echo "  /etc/macprovider/coordinator.env not yet present; operator must drop it with mode 0640 (root:macprovider)"
  fi
'

log "step 4/9: upload binary + config + nginx site (with rollback snapshot)"
# Backup the live binary BEFORE the install so a rollback is one mv away.
# Use install(1) instead of cp -p so ownership (macprovider:macprovider)
# is explicit per-invocation rather than inherited from the source —
# protects against a future "rebuild snapshot from scratch" recovery that
# would otherwise drift the .prev to root:root and then propagate that
# back into /opt/macprovider/coordinator on rollback.
# See audits/2026-06-10/ROLLBACK_PROCEDURE.md for the swap-back steps.
$SSH 'if [ -x /opt/macprovider/coordinator ]; then
        install -o macprovider -g macprovider -m 0755 /opt/macprovider/coordinator /opt/macprovider/coordinator.prev
        echo "  snapshot saved at /opt/macprovider/coordinator.prev"
      else
        echo "  no live binary at /opt/macprovider/coordinator — first deploy"
      fi'

$SCP "$BINARY" "$VPS_USER@$VPS_HOST:/tmp/coordinator-linux-amd64"
$SCP "$CLI_BINARY" "$VPS_USER@$VPS_HOST:/tmp/coordinator-cli-linux-amd64"
$SCP "$CONFIG" "$VPS_USER@$VPS_HOST:/tmp/coordinator.yaml"
$SCP "$SERVICE" "$VPS_USER@$VPS_HOST:/tmp/macprovider-coordinator.service"
$SCP "$NGINX_SITE" "$VPS_USER@$VPS_HOST:/tmp/nginx-coordinator-full.conf"

# M1-6 / DEVE-5 Part D: dated backup of the remote coordinator.yaml on Pearl
# BEFORE we overwrite it. Step 1b already aborted on drift unless the
# operator opted in, but the audit also calls for a persistent
# remote-side backup so a bad deploy can be inspected/reverted without
# trusting the operator's local copy. Backups live next to the live config
# at /opt/macprovider/coordinator.yaml.bak-<UTC>.
BACKUP_TS=$(date -u +%Y%m%dT%H%M%SZ)
$SSH "if [ -f /opt/macprovider/coordinator.yaml ]; then
        install -o macprovider -g macprovider -m 0600 /opt/macprovider/coordinator.yaml /opt/macprovider/coordinator.yaml.bak-$BACKUP_TS
        echo '  remote-config backup saved at /opt/macprovider/coordinator.yaml.bak-$BACKUP_TS'
      else
        echo '  no live coordinator.yaml — first deploy, skipping backup'
      fi"

$SSH "set -e
  install -o macprovider -g macprovider -m 0755 /tmp/coordinator-linux-amd64 /opt/macprovider/coordinator
  # coordinator-cli is the operator-facing token-management tool. It's
  # invoked manually (not under systemd) so it does NOT get a .prev
  # snapshot — re-deploy is the rollback. Owned macprovider:macprovider
  # so the operator runs it via 'sudo -u macprovider' for the same DB
  # file-ownership posture as the daemon (the auth Store opens
  # coordinator.db with the daemon's uid).
  install -o macprovider -g macprovider -m 0755 /tmp/coordinator-cli-linux-amd64 /opt/macprovider/coordinator-cli
  install -o macprovider -g macprovider -m 0600 /tmp/coordinator.yaml /opt/macprovider/coordinator.yaml
  install -o root -g root -m 0644 /tmp/macprovider-coordinator.service /etc/systemd/system/macprovider-coordinator.service
  rm -f /tmp/coordinator-linux-amd64 /tmp/coordinator-cli-linux-amd64 /tmp/coordinator.yaml /tmp/macprovider-coordinator.service
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

log "step 6c/9: pre-restart safeguard (late connected-provider check)"
# Coordinator restart triggers SPEC-001 § 6.5 drain on all connected
# providers. v1.1.3+ phase3-binary handles this gracefully (drops WS,
# keeps serving direct traffic, reconnects after grace period). Older
# phase3-binary (v1.1.2 and earlier) exits the process on drain — which
# kills tunnel-direct buyer traffic. Until you can guarantee every
# connected provider is on v1.1.3+, refuse to auto-restart with
# connected providers unless the operator passes FORCE_RESTART=1.
#
# This is the LATE check — step 1c was the early one. Both exist on
# purpose: a provider that wasn't connected at step 1c can have
# connected during certbot/nginx work (step 2-6b is the longest part
# of the script). The 2026-06-12 deploy had air5 connect mid-script
# under exactly this shape; the operator manually jumped past this
# step. The tombstone wired below + the early check + the PREV_BYPASS
# surface at step 1 are the audit-trail trio that makes future
# bypasses visible to the NEXT deploy. Manual jumps past this step
# leave no trail beyond the absence of a completion marker — write
# the bypass file by hand if jumping past, see message below.
CONNECTED_COUNT=$(curl -fsS --max-time 5 --max-filesize 65536 "https://$DOMAIN/healthz" 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('pool_size', 0))" 2>/dev/null \
  || echo 0)
if [ "${CONNECTED_COUNT:-0}" -gt 0 ] && [ "${FORCE_RESTART:-0}" != "1" ]; then
  log "  REFUSING TO RESTART — $CONNECTED_COUNT provider(s) currently connected."
  log "  Restart triggers drain; phase3-binary <= v1.1.2 exits the process"
  log "  on drain and breaks tunnel-direct buyer traffic."
  log "  To proceed anyway:  FORCE_RESTART=1 bash $0"
  log "  If you must JUMP past this step manually, please first write:"
  log "    ssh <pearl> 'echo {\"ts\":\"\$(date -u +%FT%TZ)\",\"service\":\"coordinator\",\"reason\":\"manual_jump\",\"step\":\"6c\",\"metric\":\"connected_providers\",\"value\":$CONNECTED_COUNT,\"operator_host\":\"\$HOSTNAME\"} > /var/lib/macprovider/last-deploy-bypass.json'"
  log "  so the next deploy surfaces the bypass at step 1."
  exit 4
fi
if [ "${FORCE_RESTART:-0}" = "1" ] && [ "${CONNECTED_COUNT:-0}" -gt 0 ]; then
  TS_NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  OP_HOST="${HOSTNAME:-unknown}"
  $SSH "set -e
        install -d -o macprovider -g macprovider -m 0750 /var/lib/macprovider 2>/dev/null || true
        cat > /tmp/last-deploy-bypass.json <<EOF
{\"ts\":\"$TS_NOW\",\"service\":\"coordinator\",\"reason\":\"FORCE_RESTART=1\",\"step\":\"6c\",\"metric\":\"connected_providers\",\"value\":$CONNECTED_COUNT,\"operator_host\":\"$OP_HOST\"}
EOF
        install -o macprovider -g macprovider -m 0640 /tmp/last-deploy-bypass.json /var/lib/macprovider/last-deploy-bypass.json
        rm -f /tmp/last-deploy-bypass.json
        logger -t macprovider-deploy \"FORCE_RESTART=1 used at step 6c; connected=$CONNECTED_COUNT\""
  log "  AUDIT TRAIL: FORCE_RESTART=1 override written to /var/lib/macprovider/last-deploy-bypass.json"
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
# --max-filesize bounds bytes (--max-time only bounds wall-clock); /healthz
# is a few hundred bytes in practice, so 64 KiB is a generous cap that
# protects the operator Mac from a malicious or misbehaving upstream
# streaming gigabytes inside the 10s window.
HEALTHZ_BODY=$(curl -fsS --max-time 10 --max-filesize 65536 "https://$DOMAIN/healthz" || { echo "healthz failed"; exit 1; })
printf '%s\n' "$HEALTHZ_BODY" | python3 -m json.tool

# Provenance check: compare the deployed version (from /healthz) against
# what the local working tree would have built. Three outcomes:
#   - "?"        the binary predates PR #18 and has no `version` field on
#                /healthz at all → CRITICAL line (and abort if
#                STRICT_PROVENANCE=1) because the entire M0-5 instrumentation
#                got bypassed. By design still non-fatal by default so the
#                operator can decide.
#   - matched    OK line.
#   - mismatched WARN line (the deployed binary was built from a different
#                commit than the local tree — usually means an unstaged or
#                unfetched change locally; investigate before trusting).
# See audits/2026-06-10/ROLLBACK_PROCEDURE.md for the rollback path.
DEPLOYED_VERSION=$(printf '%s' "$HEALTHZ_BODY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('version', '?'))" 2>/dev/null || echo "?")
EXPECTED_VERSION=$(git describe --always --dirty --tags 2>/dev/null || git rev-parse --short HEAD)
if [ "$DEPLOYED_VERSION" = "?" ]; then
  echo "  CRITICAL provenance MISSING: /healthz returned no \"version\" field" >&2
  echo "           This almost certainly means the deployed binary predates the" >&2
  echo "           M0-5 instrumentation (PR #18) and the rollback gate is bypassed." >&2
  echo "           Expected was: $EXPECTED_VERSION" >&2
  echo "           See audits/2026-06-10/ROLLBACK_PROCEDURE.md to replace the live binary." >&2
  if [ "${STRICT_PROVENANCE:-0}" = "1" ]; then
    echo "  STRICT_PROVENANCE=1 set — aborting." >&2
    exit 7
  fi
elif [ "$DEPLOYED_VERSION" = "$EXPECTED_VERSION" ]; then
  echo "  provenance OK: deployed=$DEPLOYED_VERSION | expected=$EXPECTED_VERSION"
else
  echo "  WARN provenance mismatch: deployed=$DEPLOYED_VERSION | expected=$EXPECTED_VERSION" >&2
  echo "       (build artifact does not match the local working tree — investigate before relying on this deploy)" >&2
fi

echo "  GET https://$DOMAIN/v1/models -> expect 404 (buyer API is gateway-only)"
STATUS=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "https://$DOMAIN/v1/models")
if [ "$STATUS" != "404" ]; then
  echo "coordinator /v1/models exposure check failed: status=$STATUS" >&2
  exit 1
fi

log "step 9/9: tail the coordinator journal for sanity"
$SSH 'journalctl -u macprovider-coordinator --no-pager -n 20'

log "DONE. coordinator is live at https://$DOMAIN"
echo
echo "Next steps:"
echo "  - Stage 3: restart M4 phase3-binary with --coordinator wss://$DOMAIN/ws/provider"
echo "  - Verify: providers should appear in /poolz (auth: bearer operator_key from coordinator.yaml)"
echo "  - End-to-end: run harness against https://$DOMAIN"
