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

# #290 (mirrors #244 R2 CODE MED): validate DOMAIN + EMAIL up front so a
# typo doesn't fail mid-deploy leaving the VPS in a partial state.
# DOMAIN must be a plausible hostname; EMAIL must have exactly one @ with
# non-empty local and domain parts. Not RFC-strict; guards against
# accidental empty/whitespace/multiline overrides.
case "$DOMAIN" in
  *' '*|*$'\n'*|'')
    echo "aborting deploy: DOMAIN='$DOMAIN' is empty or contains whitespace" >&2
    exit 1
    ;;
esac
case "$DOMAIN" in
  *[!A-Za-z0-9.-]*)
    echo "aborting deploy: DOMAIN='$DOMAIN' contains invalid characters (only A-Za-z0-9.- allowed)" >&2
    exit 1
    ;;
esac
case "$EMAIL" in
  *' '*|*$'\n'*|'')
    echo "aborting deploy: EMAIL='$EMAIL' is empty or contains whitespace" >&2
    exit 1
    ;;
  *@*@*)
    echo "aborting deploy: EMAIL='$EMAIL' has more than one '@'" >&2
    exit 1
    ;;
  *@?*)
    _email_local="${EMAIL%@*}"
    [ -n "$_email_local" ] || {
      echo "aborting deploy: EMAIL='$EMAIL' has empty local part" >&2
      exit 1
    }
    ;;
  *)
    echo "aborting deploy: EMAIL='$EMAIL' missing '@' with non-empty domain" >&2
    exit 1
    ;;
esac

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

# #290 (mirrors #244 R6 CODE+SEC+ARCH convergent MED) — register the
# EXIT cleanup trap UNCONDITIONALLY, before any temp resource is
# created. Same threat model as the coordinator: if the deploy fails
# mid-flight, the remote staging dir must not persist. $DEPLOY_TMP is
# guarded with `:-` so the trap is a no-op when it is unset.
trap '
  if [ -n "${DEPLOY_TMP:-}" ]; then
    $SSH "rm -rf $DEPLOY_TMP" 2>/dev/null || true
  fi
' EXIT

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
# #290 (mirrors #244 R5 SEC CRITICAL / R5 SEC MED): ownership tightened
# to root:macprovider 0750. Previously macprovider:macprovider 0755,
# which meant a compromised macprovider UID could rewrite the rollback
# binary — a persistent attack path against the /opt/macprovider surface.
# Parent dir /opt/macprovider is already root:macprovider 0750 (set by
# the coordinator's step 3); files inside can be group-read by the
# macprovider daemon but not written by anything running as macprovider.
$SSH 'if [ -x /opt/macprovider/gateway ]; then
        install -o root -g macprovider -m 0750 /opt/macprovider/gateway /opt/macprovider/gateway.prev
        echo "  snapshot saved at /opt/macprovider/gateway.prev (root:macprovider 0750)"
      else
        echo "  no live gateway at /opt/macprovider/gateway — first deploy"
      fi'

log "step 4/8: upload binary + service unit + nginx site"
# #290 (mirrors #244 R5 SEC CRITICAL) — stage uploaded artifacts into a
# fresh per-deploy root-owned 0700 directory instead of predictable
# /tmp/<name> paths. Otherwise any local user (including a compromised
# macprovider UID) can race the SCP/install window and substitute their
# own systemd unit, binary, or nginx config — which root then installs.
# `mktemp -d` returns a fresh dir with mode 0700 owned by the SSH user
# (root). The wider /tmp permissions (1777) don't matter because the
# fresh subdir denies traversal.
DEPLOY_TMP=$($SSH 'umask 077 && mktemp -d -t macprovider-deploy.XXXXXXXX') || {
  echo "failed to create remote staging directory" >&2; exit 1;
}
case "$DEPLOY_TMP" in
  /tmp/macprovider-deploy.*) ;;
  *)
    echo "aborting deploy: mktemp produced unexpected path: '$DEPLOY_TMP'" >&2
    exit 1
    ;;
esac
log "  staging dir: $DEPLOY_TMP (root:root 0700)"

$SCP "$BINARY"     "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/gateway-linux-amd64"
$SCP "$SERVICE"    "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/macprovider-gateway.service"
$SCP "$NGINX_SITE" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/nginx-api.streamvc.live.conf"

$SSH "set -e
  # #290 (mirrors #244 R5 SEC MED) — binary is root:macprovider 0750.
  # macprovider daemon can execute + read via group; only root can write.
  install -o root -g macprovider -m 0750 $DEPLOY_TMP/gateway-linux-amd64 /opt/macprovider/gateway
  install -o root -g root -m 0644 $DEPLOY_TMP/macprovider-gateway.service /etc/systemd/system/macprovider-gateway.service
  install -o root -g root -m 0644 $DEPLOY_TMP/nginx-api.streamvc.live.conf /etc/nginx/sites-available/$DOMAIN
  # EXIT trap will rm -rf \$DEPLOY_TMP after script exits (success or
  # failure). Explicit cleanup here is not required.
  ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/$DOMAIN
  # Mirror the coordinator script's step 6b: nginx-api.streamvc.live.conf ships
  # with the ssl_certificate / ssl_certificate_key lines commented (so a
  # first-deploy clean run before certbot doesn't fail nginx -t with a missing
  # cert). The cert exists by the time we get here on every subsequent deploy;
  # uncomment idempotently. Without this, step 4 fails nginx -t with
  # 'no ssl_certificate is defined for the listen ... ssl' (Pearl, 2026-06-11
  # deploy — mitigated by switching to a binary-only swap at the time).
  sed -i 's|# ssl_certificate /etc/letsencrypt|ssl_certificate /etc/letsencrypt|g' /etc/nginx/sites-available/$DOMAIN
  sed -i 's|# ssl_certificate_key /etc/letsencrypt|ssl_certificate_key /etc/letsencrypt|g' /etc/nginx/sites-available/$DOMAIN
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
  # #290 (mirrors #244 R6 SEC/CODE/ARCH convergent MED) — write the
  # tombstone via remote `mktemp` under `umask 077` instead of the
  # predictable /tmp/last-deploy-bypass.json path. Same threat model as
  # step 4's DEPLOY_TMP fix: a same-host attacker could otherwise
  # pre-place a FIFO/symlink at the predictable name and forge or
  # clobber the audit tombstone, or cause a deploy DoS.
  $SSH "set -e
        install -d -o macprovider -g macprovider -m 0750 /var/lib/macprovider 2>/dev/null || true
        _bypass_tmp=\$(umask 077 && mktemp)
        cat > \"\$_bypass_tmp\" <<EOF
{\"ts\":\"$TS_NOW\",\"service\":\"gateway\",\"reason\":\"FORCE_RESTART=1\",\"step\":\"5\",\"metric\":\"in_flight_requests\",\"value\":$INFLIGHT,\"operator_host\":\"$OP_HOST\"}
EOF
        install -o macprovider -g macprovider -m 0640 \"\$_bypass_tmp\" /var/lib/macprovider/last-deploy-bypass.json
        rm -f \"\$_bypass_tmp\"
        logger -t macprovider-deploy \"FORCE_RESTART=1 used at gateway step 5; in_flight=$INFLIGHT\""
  log "  AUDIT TRAIL: FORCE_RESTART=1 override written to /var/lib/macprovider/last-deploy-bypass.json"
fi
log "  ok: $INFLIGHT in-flight requests (or FORCE_RESTART=1 set)"

log "step 5b/8: pre-restart snapshot of gateway.db (rollback safety, issue #196)"
# The new binary's first start runs Migrate() which may upgrade schema
# in place (e.g. v1 -> v2 composite-PK rebuild). The old binary CANNOT
# read the upgraded schema correctly — its WHERE request_id = ? lookup
# returns wrong-account rows once cross-account collisions exist. So
# binary-only rollback via gateway.prev is INVALID after a schema
# upgrade. We snapshot the DB BEFORE the new binary starts; rollback
# becomes binary.prev + db.pre-deploy.<ts>.
#
# Snapshot uses `sqlite3 .backup` (which serializes a WAL-consistent
# copy from a still-running gateway) rather than a raw `install`/`cp`
# of just gateway.db. Raw copy misses rows still in gateway.db-wal
# that have been COMMITTED but not yet checkpointed into the main
# file — a rollback to that snapshot would silently lose money-path
# audit rows. ISS-196 R3 codex SECURITY + ARCHITECT HIGH.
$SSH 'set -e
  TS=$(date -u +%Y%m%dT%H%M%SZ)
  DB=/var/lib/macprovider/gateway.db
  if [ -f "$DB" ]; then
    SNAP="${DB}.pre-deploy.${TS}"
    # .backup opens a read txn that pins a consistent WAL view; the
    # output file is a single .db with WAL already merged in (no
    # accompanying -wal/-shm sidecars), so rollback restore is a
    # single-file copy.
    sudo -u macprovider sqlite3 "$DB" ".backup ${SNAP}"
    chmod 0600 "$SNAP"
    chown macprovider:macprovider "$SNAP"
    INTEG=$(sudo -u macprovider sqlite3 "$SNAP" "PRAGMA integrity_check;" 2>&1 | head -1)
    if [ "$INTEG" != "ok" ]; then
      echo "  ERROR: snapshot integrity_check returned: $INTEG" >&2
      rm -f "$SNAP"
      exit 5
    fi
    echo "  db snapshot saved at $SNAP (WAL-consistent, integrity=ok)"
    # Retain the 5 most recent pre-deploy snapshots; older ones are
    # auto-pruned to bound disk growth.
    ls -1t /var/lib/macprovider/gateway.db.pre-deploy.* 2>/dev/null \
      | tail -n +6 | xargs -r rm -f
  else
    echo "  no live gateway.db at $DB — first deploy, no snapshot needed"
  fi
'

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
echo "Rollback:"
echo
echo "  IMPORTANT — issue #196 added a schema upgrade (v1 -> v2) the OLD"
echo "  binary cannot safely read. After any deploy that crosses schema"
echo "  versions, restore BOTH the binary AND the pre-deploy DB snapshot:"
echo
echo "    ssh $VPS_USER@$VPS_HOST '"
echo "      systemctl stop macprovider-gateway &&"
echo "      install -o root -g macprovider -m 0750 /opt/macprovider/gateway.prev /opt/macprovider/gateway &&"
echo "      LATEST=\$(ls -1t /var/lib/macprovider/gateway.db.pre-deploy.* | head -1) &&"
echo "      install -o macprovider -g macprovider -m 0600 \"\$LATEST\" /var/lib/macprovider/gateway.db &&"
echo "      systemctl start macprovider-gateway"
echo "    '"
echo
echo "  Binary-only rollback (gateway.prev only) is SAFE only if no schema"
echo "  bump happened between the two deploys."
