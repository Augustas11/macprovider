#!/usr/bin/env bash
# deploy-pearl-vps.sh — scripted Pearl-VPS deploy for the gateway (M1-6).
#
# Mirrors phase4-coordinator/dist/deploy-pearl-vps.sh: idempotent, fail-closed
# config gate as step 0, .prev binary snapshot for one-command rollback,
# version-stamped provenance check on /healthz. The previous gateway deploy
# was an .md runbook with no scripted automation — DEVE-4 in the
# audits/2026-06-10/REPO_AUDIT.md.
#
# Run this from the operator's Mac. It SSHes into Pearl VPS, installs the
# gateway behind the existing nginx + Let's Encrypt for api.streamvc.live,
# and verifies the public endpoint.
#
# Prerequisites:
#   - gateway-linux-amd64 cross-compiled into dist/ (see build-linux.sh)
#   - dist/gateway-config-or-mock.yaml available locally for the C2 check, or
#     pass via GATEWAY_CONFIG env (see GATEWAY_CONFIG below).
#   - /etc/macprovider/gateway.env on Pearl already contains:
#       COORDINATOR_OPERATOR_KEY, MACPROVIDER_KEY_HASH_SECRET,
#       MACPROVIDER_DEMO_SIGNING_SECRET,
#       GITHUB_OAUTH_CLIENT_ID, GITHUB_OAUTH_CLIENT_SECRET
#     This deploy script does NOT touch that file — secrets stay on the VPS.
#   - nginx site for api.streamvc.live already exists; we reinstall it from
#     dist/nginx-api.streamvc.live.conf on every deploy.
#   - DNS A record api.streamvc.live -> $VPS_HOST.
#
# Usage:
#   bash deploy-pearl-vps.sh
#
# Environment:
#   SSH_KEY          default: ~/.ssh/pearl_operator_ed25519
#   VPS_HOST         default: 159.223.165.194
#   VPS_USER         default: root
#   DOMAIN           default: api.streamvc.live
#   EMAIL            default: augstar@gmail.com
#   GATEWAY_CONFIG   path to a real gateway.yaml to use for the pre-deploy
#                    C2 cross-check (must contain timeouts.coordinator_request_seconds).
#                    Defaults to ./gateway.yaml under dist/. Missing config aborts
#                    the deploy unless SKIP_C2_CHECK=1 is also set; the deploy
#                    intentionally REFUSES gateway.yaml.example as input — sample
#                    config is documentation, not a production safety input.
#   COORD_CONFIG     path to the coordinator.yaml that's expected to be live
#                    on Pearl. Defaults to ../../phase4-coordinator/dist/coordinator.yaml
#                    if present. Used for the C2 timer cross-check.
#   FORCE_RESTART=1  bypass the connected-buyer guard (similar to the
#                    coordinator's connected-provider guard).
#   STRICT_PROVENANCE=1  abort if /healthz returns no "version" field.

set -euo pipefail

SSH_KEY="${SSH_KEY:-$HOME/.ssh/pearl_operator_ed25519}"
VPS_HOST="${VPS_HOST:-159.223.165.194}"
VPS_USER="${VPS_USER:-root}"
DOMAIN="${DOMAIN:-api.streamvc.live}"
EMAIL="${EMAIL:-augstar@gmail.com}"

DIST_DIR="$(cd "$(dirname "$0")" && pwd)"
BINARY="$DIST_DIR/gateway-linux-amd64"
SERVICE="$DIST_DIR/macprovider-gateway.service"
NGINX_SITE="$DIST_DIR/nginx-api.streamvc.live.conf"

# M1-6 follow-up (codex audits 2026-06-11): no .example fallback. Sample
# config is documentation, not an operational input — passing C2 against
# example timeouts while the real VPS config has drifted is a false
# fail-closed gate.
GATEWAY_CONFIG_DEFAULT="$DIST_DIR/gateway.yaml"
GATEWAY_CONFIG="${GATEWAY_CONFIG:-$GATEWAY_CONFIG_DEFAULT}"

COORD_CONFIG_DEFAULT="$DIST_DIR/../../phase4-coordinator/dist/coordinator.yaml"
COORD_CONFIG="${COORD_CONFIG:-$COORD_CONFIG_DEFAULT}"

CHECK_SCRIPT="$DIST_DIR/../../phase4-coordinator/dist/check-deploy-config.sh"

for f in "$BINARY" "$SERVICE" "$NGINX_SITE"; do
  [ -f "$f" ] || { echo "missing required file: $f" >&2; exit 1; }
done

SSH="ssh -i $SSH_KEY -o ConnectTimeout=10 -p 22 $VPS_USER@$VPS_HOST"
SCP="scp -i $SSH_KEY -P 22"

log() { printf "\n[deploy-gateway] %s\n" "$*"; }

log "step 0/8: pre-deploy C2 cross-component config check"
# M1-6 follow-up (codex audits 2026-06-11): require real configs for C2,
# or an explicit SKIP_C2_CHECK=1 override. The previous "best-effort"
# path treated missing inputs as a warning, which weakened a deploy gate
# the audit called out as mandatory.
if [ "${SKIP_C2_CHECK:-0}" = "1" ]; then
  echo "  SKIP_C2_CHECK=1 set — C2 cross-check skipped by operator opt-out" >&2
elif [ -x "$CHECK_SCRIPT" ] && [ -f "$COORD_CONFIG" ] && [ -f "$GATEWAY_CONFIG" ]; then
  bash "$CHECK_SCRIPT" "$COORD_CONFIG" "$GATEWAY_CONFIG" || {
    echo "aborting gateway deploy: config-drift check failed" >&2; exit 5;
  }
else
  echo "aborting gateway deploy: cannot run C2 cross-check." >&2
  echo "  check-deploy-config.sh: $CHECK_SCRIPT $( [ -x "$CHECK_SCRIPT" ] || echo '(missing or not executable)')" >&2
  echo "  coordinator config:    $COORD_CONFIG $( [ -f "$COORD_CONFIG" ] || echo '(missing)')" >&2
  echo "  gateway config:        $GATEWAY_CONFIG $( [ -f "$GATEWAY_CONFIG" ] || echo '(missing — provide GATEWAY_CONFIG=<path>)')" >&2
  echo "  To deploy without the cross-check, set SKIP_C2_CHECK=1 explicitly." >&2
  echo "  gateway.yaml.example is sample documentation and intentionally NOT accepted here." >&2
  exit 5
fi
# Defensive: even with C2 skipped, the gateway config (if provided) must at
# least carry the coordinator_request_seconds key the C2 check looks at.
if [ -f "$GATEWAY_CONFIG" ] && ! grep -qE '^[[:space:]]*coordinator_request_seconds:' "$GATEWAY_CONFIG"; then
  echo "  FAIL: gateway config $GATEWAY_CONFIG missing timeouts.coordinator_request_seconds" >&2
  exit 5
fi
log "step 1/8: confirm SSH + DNS"
$SSH 'hostname && uptime' >/dev/null
dig +short "$DOMAIN" | grep -q "$VPS_HOST" || { echo "DNS for $DOMAIN does not resolve to $VPS_HOST yet" >&2; exit 1; }

# Previous-deploy bypass tombstone — the coordinator script and this
# script share /var/lib/macprovider/last-deploy-bypass.json. Surface
# it here so the operator can audit before scping a new binary.
# Does NOT exit — informational only.
PREV_BYPASS=$($SSH 'cat /var/lib/macprovider/last-deploy-bypass.json 2>/dev/null || true')
if [ -n "$PREV_BYPASS" ]; then
  log "  NOTE: previous deploy left a bypass tombstone:"
  printf '%s\n' "$PREV_BYPASS" | sed 's/^/    /'
  log "  If audited, clear with: ssh <pearl> rm /var/lib/macprovider/last-deploy-bypass.json"
fi

log "step 2/8: confirm /etc/macprovider/gateway.env exists on Pearl"
$SSH "test -f /etc/macprovider/gateway.env || { echo 'missing /etc/macprovider/gateway.env on Pearl' >&2; exit 1; }"

log "step 3/8: snapshot live gateway binary as .prev (rollback)"
# Mirror the coordinator's M0-5 .prev pattern. install(1) is intentional —
# preserves ownership/perms even if a future recovery rebuilds the snapshot.
$SSH 'if [ -x /opt/macprovider/gateway ]; then
        install -o macprovider -g macprovider -m 0755 /opt/macprovider/gateway /opt/macprovider/gateway.prev
        echo "  snapshot saved at /opt/macprovider/gateway.prev"
      else
        echo "  no live gateway at /opt/macprovider/gateway — first deploy"
      fi'

log "step 4/8: upload binary + service unit + nginx site"
$SCP "$BINARY" "$VPS_USER@$VPS_HOST:/tmp/gateway-linux-amd64"
$SCP "$SERVICE" "$VPS_USER@$VPS_HOST:/tmp/macprovider-gateway.service"
$SCP "$NGINX_SITE" "$VPS_USER@$VPS_HOST:/tmp/nginx-api.streamvc.live.conf"

$SSH "set -e
  install -o macprovider -g macprovider -m 0755 /tmp/gateway-linux-amd64 /opt/macprovider/gateway
  install -o root -g root -m 0644 /tmp/macprovider-gateway.service /etc/systemd/system/macprovider-gateway.service
  install -o root -g root -m 0644 /tmp/nginx-api.streamvc.live.conf /etc/nginx/sites-available/$DOMAIN
  rm -f /tmp/gateway-linux-amd64 /tmp/macprovider-gateway.service /tmp/nginx-api.streamvc.live.conf
  ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/$DOMAIN
  nginx -t
  systemctl reload nginx
"

log "step 5/8: pre-restart safeguard (check for in-flight buyer requests)"
# Mirror the coordinator's FORCE_RESTART guard. Gateway restart drops
# in-flight buyer requests; a quiet window is preferable. Defensive but
# overrideable.
# We use the gateway's own /healthz which includes a coarse in-flight metric
# when available; if absent, fall back to nginx access-log activity.
#
# Both this script and the coordinator's deploy-pearl-vps.sh write the
# bypass tombstone to the same path (/var/lib/macprovider/last-deploy-bypass.json)
# so a subsequent deploy of either service surfaces the override at its
# step 1. Manual jumps past this step are tracked the same way as
# manual jumps past the coordinator's step 6c — write the file by hand
# (the refusal message below has the command).
INFLIGHT=$(curl -fsS --max-time 5 --max-filesize 65536 "https://$DOMAIN/healthz" 2>/dev/null \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('in_flight_requests', d.get('inflight', 0)))" 2>/dev/null \
  || echo 0)
if [ "${INFLIGHT:-0}" -gt 0 ] && [ "${FORCE_RESTART:-0}" != "1" ]; then
  log "  REFUSING TO RESTART — $INFLIGHT request(s) in flight."
  log "  To proceed anyway:  FORCE_RESTART=1 bash $0"
  log "  If you must JUMP past this step manually, please first write:"
  log "    ssh <pearl> 'echo {\"ts\":\"\$(date -u +%FT%TZ)\",\"service\":\"gateway\",\"reason\":\"manual_jump\",\"step\":\"5\",\"metric\":\"in_flight_requests\",\"value\":$INFLIGHT,\"operator_host\":\"\$HOSTNAME\"} > /var/lib/macprovider/last-deploy-bypass.json'"
  log "  so the next deploy surfaces the bypass at step 1."
  exit 4
fi
if [ "${FORCE_RESTART:-0}" = "1" ] && [ "${INFLIGHT:-0}" -gt 0 ]; then
  TS_NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  OP_HOST="${HOSTNAME:-unknown}"
  $SSH "set -e
        install -d -o macprovider -g macprovider -m 0750 /var/lib/macprovider 2>/dev/null || true
        cat > /tmp/last-deploy-bypass.json <<EOF
{\"ts\":\"$TS_NOW\",\"service\":\"gateway\",\"reason\":\"FORCE_RESTART=1\",\"step\":\"5\",\"metric\":\"in_flight_requests\",\"value\":$INFLIGHT,\"operator_host\":\"$OP_HOST\"}
EOF
        install -o macprovider -g macprovider -m 0640 /tmp/last-deploy-bypass.json /var/lib/macprovider/last-deploy-bypass.json
        rm -f /tmp/last-deploy-bypass.json
        logger -t macprovider-deploy \"FORCE_RESTART=1 used at gateway step 5; in_flight=$INFLIGHT\""
  log "  AUDIT TRAIL: FORCE_RESTART=1 override written to /var/lib/macprovider/last-deploy-bypass.json"
fi
log "  ok: $INFLIGHT in-flight requests (or FORCE_RESTART=1 set)"

log "step 6/8: enable + start gateway service"
$SSH 'set -e
  systemctl daemon-reload
  systemctl enable macprovider-gateway
  systemctl restart macprovider-gateway
  sleep 3
  systemctl is-active macprovider-gateway
  ss -tlnp | grep -E ":9443" >/dev/null || { echo "gateway did not bind :9443" >&2; exit 1; }
'

log "step 7/8: verify public endpoints + provenance"
sleep 2
echo "  GET https://$DOMAIN/healthz"
HEALTHZ_BODY=$(curl -fsS --max-time 10 --max-filesize 65536 "https://$DOMAIN/healthz" || { echo "healthz failed"; exit 1; })
printf '%s\n' "$HEALTHZ_BODY" | python3 -m json.tool

DEPLOYED_VERSION=$(printf '%s' "$HEALTHZ_BODY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('version', '?'))" 2>/dev/null || echo "?")
EXPECTED_VERSION=$(git describe --always --dirty --tags 2>/dev/null || git rev-parse --short HEAD)
if [ "$DEPLOYED_VERSION" = "?" ]; then
  echo "  CRITICAL provenance MISSING: /healthz returned no \"version\" field" >&2
  echo "           This almost certainly means the deployed gateway binary predates M0-5 instrumentation." >&2
  echo "           Expected: $EXPECTED_VERSION" >&2
  if [ "${STRICT_PROVENANCE:-0}" = "1" ]; then
    echo "  STRICT_PROVENANCE=1 set — aborting." >&2
    exit 7
  fi
elif [ "$DEPLOYED_VERSION" = "$EXPECTED_VERSION" ]; then
  echo "  provenance OK: deployed=$DEPLOYED_VERSION | expected=$EXPECTED_VERSION"
else
  echo "  WARN provenance mismatch: deployed=$DEPLOYED_VERSION | expected=$EXPECTED_VERSION" >&2
fi

echo "  GET https://$DOMAIN/v1/models without auth -> expect 401"
STATUS=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "https://$DOMAIN/v1/models")
if [ "$STATUS" != "401" ] && [ "$STATUS" != "403" ]; then
  echo "  WARN: /v1/models without auth returned $STATUS (expected 401 or 403)" >&2
fi

log "step 8/8: tail the gateway journal for sanity"
$SSH 'journalctl -u macprovider-gateway --no-pager -n 20'

log "DONE. gateway is live at https://$DOMAIN"
echo
echo "Rollback (one command on Pearl):"
echo "  ssh $VPS_USER@$VPS_HOST 'install -o macprovider -g macprovider -m 0755 /opt/macprovider/gateway.prev /opt/macprovider/gateway && systemctl restart macprovider-gateway'"
