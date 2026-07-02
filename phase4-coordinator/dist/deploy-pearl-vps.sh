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
#   SSH_KEY          default: ~/.ssh/pearl_operator_ed25519
#   VPS_HOST         default: 159.223.165.194
#   VPS_USER         default: root
#   DOMAIN           default: coordinator.streamvc.live  (PRIMARY money-path hostname)
#   STATS_DOMAIN     default: stats.streamvc.live        (SPEC-017 first-class hostname)
#   EMAIL            default: augstar@gmail.com          (for Let's Encrypt)
#   STATS_REQUIRED   default: 0   set to 1 to fail-closed on STATS_DOMAIN cert
#                                 issuance failure (default WARN-only because
#                                 stats cert outages must not break the
#                                 primary deploy — issue #244 root cause).
#   FORCE_RESTART    default: 0   bypass connected-provider guard at step 1c/6c
#   STRICT_PROVENANCE default: 0  fail if /healthz lacks `version` field
#   SKIP_C2_CHECK    default: 0   skip C2 cross-check (development only)
#   ALLOW_CONFIG_DRIFT default: 0 push local coordinator.yaml over live one
#
# Note: DOMAIN and STATS_DOMAIN are validated up-front (step 0) against
# DNS-name regex AND against the baked-in vhost-template hostnames. The
# templates `dist/nginx-{coordinator,stats}.streamvc.live.conf` hardcode
# `server_name` and `/etc/letsencrypt/live/...` paths, so an env-only
# override would issue a cert for one hostname while installing a vhost
# for another. Refused fail-closed.

set -euo pipefail

SSH_KEY="${SSH_KEY:-$HOME/.ssh/pearl_operator_ed25519}"
VPS_HOST="${VPS_HOST:-159.223.165.194}"
VPS_USER="${VPS_USER:-root}"
DOMAIN="${DOMAIN:-coordinator.streamvc.live}"
EMAIL="${EMAIL:-augstar@gmail.com}"

# Issue #244 R1 SEC HIGH-1 / CODE MED-2 / ARCH HIGH-2 — validate operator-
# overridable values up front so they cannot inject shell metacharacters
# or argument boundaries into the SSH command strings below, AND so an
# overridden $DOMAIN that doesn't match the baked-in vhost template's
# server_name is rejected fail-closed rather than installing a TLS vhost
# for the wrong hostname.
_validate_dns_name() {
  local v="$1" label="$2"
  if ! printf '%s' "$v" | grep -Eq '^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$'; then
    echo "aborting deploy: $label is not a valid DNS name: '$v'" >&2
    exit 1
  fi
}
_validate_dns_name "$DOMAIN"        DOMAIN
_validate_dns_name "${STATS_DOMAIN:-stats.streamvc.live}" STATS_DOMAIN

# Email validator — RFC-conformant pre-validation is overkill; we just
# need to reject metacharacters that would split a shell arg.
if ! printf '%s' "$EMAIL" | grep -Eq '^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'; then
  echo "aborting deploy: EMAIL is not a valid address: '$EMAIL'" >&2
  exit 1
fi

# R1 ARCH HIGH-2 — the baked-in vhost templates hardcode
# server_name=coordinator.streamvc.live and the matching certbot live
# paths. Refuse if $DOMAIN was overridden to something else; otherwise
# we'd issue a cert for the override domain while installing a vhost
# with a non-matching server_name.
if [ "$DOMAIN" != "coordinator.streamvc.live" ]; then
  echo "aborting deploy: DOMAIN override ($DOMAIN) does not match the baked-in vhost template" >&2
  echo "  dist/nginx-coordinator.streamvc.live.conf has server_name=coordinator.streamvc.live hardcoded." >&2
  echo "  Edit the conf file in lockstep, or remove the DOMAIN env override." >&2
  exit 1
fi
if [ "${STATS_DOMAIN:-stats.streamvc.live}" != "stats.streamvc.live" ]; then
  echo "aborting deploy: STATS_DOMAIN override (${STATS_DOMAIN}) does not match the baked-in vhost template" >&2
  exit 1
fi

DIST_DIR="$(cd "$(dirname "$0")" && pwd)"
BINARY="$DIST_DIR/coordinator-linux-amd64"
CLI_BINARY="$DIST_DIR/coordinator-cli-linux-amd64"
CONFIG="$DIST_DIR/coordinator.yaml"
SERVICE="$DIST_DIR/macprovider-coordinator.service"
NGINX_SITE="$DIST_DIR/nginx-coordinator.streamvc.live.conf"
# SPEC-017 v0.1.8 Step 4.B — additional nginx artifacts the
# coordinator vhost depends on:
#   - stats-shared.conf is the http-context snippet declaring the
#     `$public_rl_key` map, the per-endpoint `stats_*` zones, the
#     `stats_public` cache, and the `stats_redacted` log format.
#     Both the coordinator vhost and the stats vhost reference
#     these names; without the snippet installed first, `nginx -t`
#     fails (Step 4.B CODE r1 CRITICAL).
#   - nginx-stats.streamvc.live.conf is the standalone
#     `stats.streamvc.live` vhost.
# Both files MUST exist before this deploy proceeds; they are
# installed below alongside the coordinator vhost.
NGINX_STATS_SHARED="$DIST_DIR/nginx-snippets/stats-shared.conf"
NGINX_STATS_SECHEADERS="$DIST_DIR/nginx-snippets/stats-security-headers.conf"
NGINX_STATS_SITE="$DIST_DIR/nginx-stats.streamvc.live.conf"
CATALOG_SOURCE="${CATALOG_SOURCE:-$DIST_DIR/../../.omc/tier2/tier2-catalog.json}"

# coordinator-cli is required ALONGSIDE the daemon (SPEC-003 v0.8.3
# FR-C9.4 strict-reject path still requires `coordinator-cli
# revoke-token` for the used-token-persist-failure case; routine
# prune-tokens / list-tokens also belong on Pearl). If absent, the
# operator forgot to run build-linux.sh after the M2 update that
# extended it. Fail closed — do NOT silently deploy with a stale CLI.
for f in "$BINARY" "$CLI_BINARY" "$CONFIG" "$SERVICE" "$NGINX_SITE" \
         "$NGINX_STATS_SHARED" "$NGINX_STATS_SECHEADERS" "$NGINX_STATS_SITE"; do
  [ -f "$f" ] || { echo "missing required file: $f" >&2; exit 1; }
done

# Issue #244 R1+R2 — replace the defensive sed (silently re-rewriting
# commented cert directives) with a pre-upload assertion that the dist
# vhosts ship with ACTIVE ssl_certificate + ssl_certificate_key
# directives AND server_name matching the deploy hostname. The dist
# confs are the single source of truth; the deploy script no longer
# "fixes up" the templates. If the assertion fails, the operator must
# edit the dist conf in place.
#
# R2 ARCH MEDIUM-2: also assert server_name + /etc/letsencrypt/live/<d>/
# paths in each template match the expected hostname, so an env-only
# DOMAIN override paired with a stale template can't issue a cert for
# one hostname and install a vhost for another.
_assert_vhost_template() {
  local f="$1" expected_host="$2"
  local host_esc="${expected_host//./\\.}"
  # R3 ARCH MED: anchor the active cert directives to the EXPECTED
  # hostname's letsencrypt path — not just any letsencrypt path. A
  # wrong active cert + commented expected cert would otherwise pass.
  if ! grep -Eq "^[[:space:]]*ssl_certificate[[:space:]]+/etc/letsencrypt/live/${host_esc}/fullchain\\.pem;" "$f"; then
    echo "aborting deploy: $f is missing an active 'ssl_certificate /etc/letsencrypt/live/$expected_host/fullchain.pem;' directive" >&2
    echo "  Edit the file to uncomment the cert path for this hostname; the deploy script no longer rewrites it." >&2
    exit 1
  fi
  if ! grep -Eq "^[[:space:]]*ssl_certificate_key[[:space:]]+/etc/letsencrypt/live/${host_esc}/privkey\\.pem;" "$f"; then
    echo "aborting deploy: $f is missing an active 'ssl_certificate_key /etc/letsencrypt/live/$expected_host/privkey.pem;' directive" >&2
    exit 1
  fi
  if ! grep -Eq "^[[:space:]]*server_name[[:space:]]+${host_esc}[[:space:]]*;" "$f"; then
    echo "aborting deploy: $f does not contain server_name $expected_host;" >&2
    exit 1
  fi
}
_assert_vhost_template "$NGINX_SITE"       "$DOMAIN"
_assert_vhost_template "$NGINX_STATS_SITE" "${STATS_DOMAIN:-stats.streamvc.live}"

SSH="ssh -i $SSH_KEY -o ConnectTimeout=10 -p 22 $VPS_USER@$VPS_HOST"
SCP="scp -i $SSH_KEY -P 22"

log() { printf "\n[deploy] %s\n" "$*"; }

yaml_tier2_value() {
  yaml_block_value tier2 "$1"
}

# R5 ARCH MED: generic top-level-block value reader so callers can
# query e.g. `stats.enabled` in addition to `tier2.catalog_path`. Same
# scoping rule: read keys until the next top-level block.
yaml_block_value() {
  local block="$1" key="$2"
  awk -v block="$block" -v key="$key" '
    BEGIN { in_block=0 }
    {
      line=$0
      sub(/[[:space:]]+#.*$/, "", line)
    }
    line ~ "^[[:space:]]*" block ":[[:space:]]*$" { in_block=1; next }
    in_block && line ~ /^[^[:space:]#][^:]*:/ { exit }
    in_block {
      if (line ~ "^[[:space:]]*" key ":[[:space:]]*") {
        sub("^[[:space:]]*" key ":[[:space:]]*", "", line)
        gsub(/^"|"$/, "", line)
        gsub(/^'\''|'\''$/, "", line)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
        print line
        exit
      }
    }
  ' "$CONFIG"
}

# R5 ARCH M1 — early coherence check: if the operator set
# STATS_REQUIRED=1 but coordinator.yaml has stats.enabled=false (or
# unset), the deploy would restart the binary then exit 9 in step 8.
# Catch it BEFORE any SSH mutation.
if [ "${STATS_REQUIRED:-0}" = "1" ]; then
  _stats_enabled_pre="$(yaml_block_value stats enabled)"
  if [ "$_stats_enabled_pre" != "true" ]; then
    echo "aborting deploy: STATS_REQUIRED=1 but stats.enabled is not true in $CONFIG ('$_stats_enabled_pre')." >&2
    echo "  Either set stats.enabled: true in coordinator.yaml, or drop STATS_REQUIRED=1." >&2
    exit 5
  fi
fi

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

# SPEC-015 v0.3 §M.4 — fail closed before any remote mutation if the
# local nginx conf lacks the catalog routes. The static check is
# under-engineered for the operator-runbook live smoke surface
# (check_nginx_receipt_header_live_test.sh is the live counterpart);
# this is the pre-upload acceptance gate that catches a stale local
# nginx-coordinator.streamvc.live.conf before the deploy ships it.
bash "$DIST_DIR/test/check_nginx_catalog_routes_test.sh" || {
  echo "aborting deploy: nginx /catalog/ routes missing or misconfigured" >&2; exit 5;
}

# Issue #244 R6 (CODE+SEC+ARCH convergent MED) — register the EXIT
# cleanup trap UNCONDITIONALLY, before any temp resource is created.
# Earlier the trap was inside the `if [ -n "$CATALOG_REMOTE_PATH" ]`
# branch, so a deploy with catalog disabled that failed mid-flight
# could leave the remote $DEPLOY_TMP and local TMP_CATALOG_PUBKEY
# behind. Both variables are guarded with `:-` so the trap is a
# no-op when they are unset.
trap '
  rm -f "${TMP_CATALOG_PUBKEY:-}"
  rm -f "${CATALOG_SMOKE_TMP:-}"
  if [ -n "${DEPLOY_TMP:-}" ]; then
    $SSH "rm -rf $DEPLOY_TMP" 2>/dev/null || true
  fi
' EXIT

CATALOG_REMOTE_PATH="$(yaml_tier2_value catalog_path)"
CATALOG_PUBLIC_KEY="$(yaml_tier2_value catalog_public_key)"
# Issue #244 R2 SEC HIGH-2 + R3 SEC HIGH-1 + R4 CODE HIGH-1 + R4 SEC
# HIGH-1: the catalog destination is HARDCODED, not operator-controlled.
# Earlier rounds tried regex-validation then prefix-allowlist; both still
# permitted attacks: trailing slash → `dirname` yields `/opt` →
# `install -d` re-chowns `/opt`; macprovider-writable parent →
# attacker plants a symlink at the destination → root `install` follows
# it. Single fixed path under a root-owned dir (see step 3 below)
# closes both classes. coordinator.yaml MUST set catalog_path to this
# exact value or deploy refuses.
CATALOG_REMOTE_PATH_CANONICAL="/opt/macprovider/tier2-catalog.json"
if [ -n "$CATALOG_REMOTE_PATH" ]; then
  if [ "$CATALOG_REMOTE_PATH" != "$CATALOG_REMOTE_PATH_CANONICAL" ]; then
    echo "aborting deploy: tier2.catalog_path must be exactly '$CATALOG_REMOTE_PATH_CANONICAL'" >&2
    echo "  Got: '$CATALOG_REMOTE_PATH'." >&2
    echo "  This is hardcoded as a single defense-in-depth path: the parent" >&2
    echo "  dir /opt/macprovider/ is root-owned 0750 so a same-uid attacker" >&2
    echo "  cannot plant a symlink at the destination, AND no dynamic" >&2
    echo "  dirname-derived directory can be re-chowned by the deploy." >&2
    exit 5
  fi
  if [ -z "$CATALOG_PUBLIC_KEY" ]; then
    echo "aborting deploy: tier2.catalog_path is set but tier2.catalog_public_key is empty" >&2
    exit 5
  fi
  if [ ! -f "$CATALOG_SOURCE" ]; then
    echo "aborting deploy: configured tier2.catalog_path requires local catalog artifact, missing: $CATALOG_SOURCE" >&2
    echo "  Override with CATALOG_SOURCE=<signed-catalog-json>" >&2
    exit 5
  fi
  if ! command -v go >/dev/null 2>&1; then
    echo "aborting deploy: go is required to verify the signed catalog before upload" >&2
    exit 5
  fi
  TMP_CATALOG_PUBKEY="$(mktemp)"
  # Cleanup of TMP_CATALOG_PUBKEY happens in the unconditional EXIT
  # trap registered above (#244 R6).
  printf '%s\n' "$CATALOG_PUBLIC_KEY" > "$TMP_CATALOG_PUBKEY"
  go run "$DIST_DIR/../../scripts/sign-catalog.go" verify -public-key "$TMP_CATALOG_PUBKEY" "$CATALOG_SOURCE" >/dev/null || {
    echo "aborting deploy: signed catalog does not verify against tier2.catalog_public_key" >&2
    exit 5
  }
  echo "  ok: signed catalog verifies and will install to $CATALOG_REMOTE_PATH"
else
  echo "  tier2.catalog_path unset — public /catalog/current will return 404 by design"
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
  # R6 SEC/CODE/ARCH convergent MED — write the tombstone via remote
  # mktemp under umask 077 instead of predictable /tmp/last-deploy-
  # bypass.json. Same threat model as R5's main /tmp staging fix:
  # a same-host attacker could otherwise pre-place a FIFO/symlink at
  # the predictable name and forge/clobber the audit tombstone or
  # cause a deploy DoS.
  $SSH "set -e
        install -d -o macprovider -g macprovider -m 0750 /var/lib/macprovider 2>/dev/null || true
        _bypass_tmp=\$(umask 077 && mktemp)
        cat > \"\$_bypass_tmp\" <<EOF
{\"ts\":\"$TS_NOW\",\"service\":\"coordinator\",\"reason\":\"FORCE_RESTART=1\",\"step\":\"1c\",\"metric\":\"connected_providers\",\"value\":$CONNECTED_COUNT_EARLY,\"operator_host\":\"$OP_HOST\"}
EOF
        install -o macprovider -g macprovider -m 0640 \"\$_bypass_tmp\" /var/lib/macprovider/last-deploy-bypass.json
        rm -f \"\$_bypass_tmp\"
        logger -t macprovider-deploy \"FORCE_RESTART=1 used at step 1c; connected=$CONNECTED_COUNT_EARLY\""
  log "  AUDIT TRAIL: FORCE_RESTART=1 override written to /var/lib/macprovider/last-deploy-bypass.json"
fi
log "  ok: $CONNECTED_COUNT_EARLY connected providers (or FORCE_RESTART=1 set)"

log "step 2/9: install certbot + openssl + nginx-snippets (apt)"
# openssl is required by step 4b's cert-validity probe (#244 R2 fix).
$SSH 'DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -qq -y certbot python3-certbot-nginx openssl >/dev/null' || {
  echo "certbot/openssl install failed" >&2; exit 1;
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
  # Issue #244 R4 SEC HIGH-1 — /opt/macprovider is root-owned 0750 so
  # the macprovider user (or anything running as it) cannot plant a
  # symlink at the catalog destination that a later root-owned
  # `install` would follow. macprovider group keeps r-x to enter the
  # dir and read files within it. Files inside (coordinator binary,
  # config, catalog) are still installed mode-set to macprovider so
  # the daemon can read them.
  install -d -o root -g macprovider -m 0750 /opt/macprovider
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
# Use install(1) instead of cp -p so ownership (#244 R4+R5: root:macprovider
# 0750) is set explicitly per-invocation rather than inherited from the
# source — protects against drift if the .prev was ever rebuilt from a
# snapshot under different rules.
# See audits/2026-06-10/ROLLBACK_PROCEDURE.md for the swap-back steps.
$SSH 'if [ -x /opt/macprovider/coordinator ]; then
        # R5 SEC MED: ownership matches the deploy artifacts — root:macprovider 0750.
        install -o root -g macprovider -m 0750 /opt/macprovider/coordinator /opt/macprovider/coordinator.prev
        echo "  snapshot saved at /opt/macprovider/coordinator.prev"
      else
        echo "  no live binary at /opt/macprovider/coordinator — first deploy"
      fi'

# Issue #244 R5 SEC CRITICAL — stage uploaded artifacts into a fresh
# per-deploy root-owned 0700 directory instead of predictable /tmp/X
# names. Otherwise any local user (including a compromised macprovider
# UID) can race the SCP/install window and substitute their own
# systemd unit, binary, or nginx config — which root then installs.
# `mktemp -d` returns a fresh dir with mode 0700 owned by the SSH
# user (root). The wider /tmp permissions (1777) don't matter because
# the fresh subdir denies traversal.
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

$SCP "$BINARY"      "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/coordinator-linux-amd64"
$SCP "$CLI_BINARY"  "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/coordinator-cli-linux-amd64"
$SCP "$CONFIG"      "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/coordinator.yaml"
$SCP "$SERVICE"     "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/macprovider-coordinator.service"
$SCP "$NGINX_SITE"  "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/nginx-coordinator-full.conf"
# SPEC-017 v0.1.8 Step 4.B artifacts (snippet must land at
# /etc/nginx/conf.d/ so the http-context declarations are visible
# to BOTH the coordinator vhost (for /v1/stats/* allow-through)
# and the stats vhost. Installation step below is wired BEFORE
# the coordinator vhost full-TLS install so `nginx -t` does not
# trip on missing zone names.).
$SCP "$NGINX_STATS_SHARED"     "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/nginx-stats-shared.conf"
$SCP "$NGINX_STATS_SECHEADERS" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/nginx-stats-security-headers.conf"
$SCP "$NGINX_STATS_SITE"       "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/nginx-stats.streamvc.live.conf"
if [ -n "$CATALOG_REMOTE_PATH" ]; then
  $SCP "$CATALOG_SOURCE" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/tier2-catalog.json"
fi

# M1-6 / DEVE-5 Part D: dated backup of the remote coordinator.yaml on Pearl
# BEFORE we overwrite it. Step 1b already aborted on drift unless the
# operator opted in, but the audit also calls for a persistent
# remote-side backup so a bad deploy can be inspected/reverted without
# trusting the operator's local copy. Backups live next to the live config
# at /opt/macprovider/coordinator.yaml.bak-<UTC>.
BACKUP_TS=$(date -u +%Y%m%dT%H%M%SZ)
$SSH "if [ -f /opt/macprovider/coordinator.yaml ]; then
        install -o root -g macprovider -m 0640 /opt/macprovider/coordinator.yaml /opt/macprovider/coordinator.yaml.bak-$BACKUP_TS
        echo '  remote-config backup saved at /opt/macprovider/coordinator.yaml.bak-$BACKUP_TS'
      else
        echo '  no live coordinator.yaml — first deploy, skipping backup'
      fi"

$SSH "set -e
  # R5 SEC MED — deploy artifacts owned root:macprovider with group-read
  # rather than macprovider:macprovider. This prevents a compromised
  # macprovider UID from persistently rewriting its own executable /
  # config / cli. The daemon runs as macprovider; group=macprovider +
  # mode 0750 (binary/cli) and 0640 (config) give it the needed
  # read/execute access.
  install -o root -g macprovider -m 0750 $DEPLOY_TMP/coordinator-linux-amd64 /opt/macprovider/coordinator
  # coordinator-cli is the operator-facing token-management tool. It's
  # invoked manually via 'sudo -u macprovider' so it does NOT get a
  # .prev snapshot — re-deploy is the rollback.
  install -o root -g macprovider -m 0750 $DEPLOY_TMP/coordinator-cli-linux-amd64 /opt/macprovider/coordinator-cli
  install -o root -g macprovider -m 0640 $DEPLOY_TMP/coordinator.yaml /opt/macprovider/coordinator.yaml
  install -o root -g root       -m 0644 $DEPLOY_TMP/macprovider-coordinator.service /etc/systemd/system/macprovider-coordinator.service
"
if [ -n "$CATALOG_REMOTE_PATH" ]; then
  # R4: no more `install -d` on a dynamic dirname. /opt/macprovider is
  # created in step 3 as root-owned 0750; root writes the catalog file
  # into it. The destination is the hardcoded canonical path validated
  # at startup; no operator-controlled value reaches the SSH command.
  $SSH "set -e
    install -o root -g macprovider -m 0640 $DEPLOY_TMP/tier2-catalog.json $CATALOG_REMOTE_PATH_CANONICAL
  "
fi

# nginx + Let's Encrypt strategy (issue #244 R1+R2+R3+R4 — TLS-safety hardening):
#
# Domain classification (step 4b) produces FOUR states:
#   HAVE    fullchain.pem + privkey.pem present, openssl -checkend
#           86400 valid → no stub, no certbot, full vhost reinstalled
#           idempotently in step 6b.
#   RENEW   files present, cert valid RIGHT NOW (openssl -checkend 0
#           valid) but <24h to expiry → certbot needed, but the
#           existing full TLS vhost is left in place. A certbot
#           failure leaves the soon-expiring cert serving until next
#           deploy (instead of being replaced with an HTTP-only stub).
#   EXPIRED files present but cert is already invalid (openssl
#           -checkend 0 fails) → treat like MISSING. Existing vhost
#           would serve a broken cert; install stub + run certbot
#           instead.
#   MISSING fullchain.pem or privkey.pem absent → install stub + run
#           certbot. (Always-stub: dropped the R2 vhost-flag gate
#           after R3 audit showed a stale enabled vhost could lack
#           /.well-known/acme-challenge/ and block first issuance.)
#
#   step 5   -> install the port-80 ACME-stub ONLY for DOMAINS_NEED_STUB
#               (= EXPIRED ∪ MISSING). HAVE + RENEW production vhosts
#               are untouched. This is the load-bearing change vs. the
#               original bug: a downstream certbot failure cannot leave
#               another domain's working TLS vhost broken because we
#               never clobbered it in the first place.
#   step 6   -> per-domain certbot certonly --webroot, FAIL-SOFT. A
#               failure on ANY single domain (e.g. NXDOMAIN) is logged
#               and recorded but does not abort the deploy. State-aware
#               messaging tells the operator the per-domain fallback.
#   step 6b  -> install the full TLS vhost ONLY for DOMAINS_FULL_TLS
#               (= HAVE ∪ ISSUED_OK). EXPIRED/MISSING domains that
#               certbot failed for keep the ACME stub. RENEW domains
#               that certbot failed for keep their existing full TLS
#               vhost with the soon-to-expire cert. nginx -t + reload
#               runs ONCE at the end so any single bad file aborts the
#               batch atomically.
#
# Primary-domain failure (DOMAIN ∈ ISSUED_FAIL) triggers exit-9
# immediately after step 6b — before the connected-provider re-check,
# binary restart, and verify steps — with state-aware abort messaging.
# Non-primary failure defaults to WARN-only (issue #244 intent) unless
# STATS_REQUIRED=1 is set.
#
# This sequence is idempotent and never mutates a working production
# vhost when there is nothing to change. Earlier versions wrote the
# stub over the full vhost AND used in-place sed surgery on the full
# config (corrupted brace balance). Both removed in #244 R1; the dist/
# nginx confs now ship with active ssl_certificate directives and the
# pre-upload assertion at the top of this script refuses to deploy
# unless they remain active and bound to the expected hostname.

# SPEC-017 v0.1.8 Step 4.B — stats.streamvc.live is a first-class
# public hostname per SPEC §7.1; deploy applies the SAME ACME
# stub + certbot + full-vhost pipeline used for the coordinator
# hostname (round-4 ARCH r2 H1 / CODE r2 C1 fix).
STATS_DOMAIN="${STATS_DOMAIN:-stats.streamvc.live}"

# Classify domains by cert state on the remote host (#244 R1+R2+R3).
# One SSH round-trip; one line per domain: "<STATE> <DOMAIN>".
#
# Four states (R3 ARCH MED + CODE MED + SEC HIGH convergent refinement):
#   HAVE     fullchain.pem + privkey.pem present AND cert is valid for
#            >24h. No certbot, no stub. Full TLS vhost reinstalled
#            idempotently in step 6b.
#   RENEW    files present, cert valid RIGHT NOW (>0 seconds) but
#            <24h to expiry. certbot needed; existing full TLS vhost
#            is kept in place during certbot — if certbot fails, the
#            soon-expiring cert keeps serving until next deploy
#            (instead of being replaced with an HTTP-only stub).
#   EXPIRED  files present but cert is already expired or malformed
#            (openssl -checkend 0 reports invalid). Existing vhost
#            would serve a broken cert, so treat as MISSING: install
#            stub + run certbot, do NOT preserve the broken vhost.
#   MISSING  fullchain.pem or privkey.pem absent. First-ever issuance.
#            Always install stub before certbot (R3 ARCH+CODE MED:
#            vhost=1 was an over-coarse proxy for "ACME-ready" — a
#            stale enabled vhost can lack /.well-known/acme-challenge/
#            and block issuance. Always-stub for first-issuance is
#            cheap and idempotent; the stub gets overwritten in 6b
#            on certbot success).
#
# R2 ARCH/SEC/CODE convergent MED: missing openssl is FATAL (no silent
# file-presence fallback). step 2 above explicitly apt-installs openssl.
#
# R2 CODE HIGH-1: no `declare -A` (bash 3.2 compatibility for the
# operator Mac — default /usr/bin/env bash is 3.2.57). Track "seen"
# via parallel array + linear scan; only 2 domains, no perf concern.
log "step 4b/9: classify domains by cert state"
DOMAINS_ALL=("$DOMAIN" "$STATS_DOMAIN")
DOMAINS_HAVE_CERT=()
DOMAINS_NEED_CERT=()
DOMAINS_NEED_STUB=()
# Track per-domain "what state was this in BEFORE certbot" so failure
# messaging at end-of-step-6b can give the operator the truth (R3 LOW).
DOMAINS_STATE_KEYS=()
DOMAINS_STATE_VALS=()
# Pass domains via positional args; single-quoted remote heredoc for safety.
CERT_STATUS=$($SSH "bash -s -- '$DOMAIN' '$STATS_DOMAIN'" <<'REMOTE_PROBE'
set -e
if ! command -v openssl >/dev/null 2>&1; then
  echo "ABORT openssl-missing-on-remote" >&2
  exit 1
fi
for d in "$@"; do
  full="/etc/letsencrypt/live/$d/fullchain.pem"
  priv="/etc/letsencrypt/live/$d/privkey.pem"
  if [ -f "$full" ] && [ -f "$priv" ]; then
    # R3 ARCH MED: split RENEW (still valid right now) from EXPIRED
    # (already expired or malformed). EXPIRED behaves like MISSING.
    if ! openssl x509 -checkend 0 -noout -in "$full" >/dev/null 2>&1; then
      echo "EXPIRED $d"
    elif openssl x509 -checkend 86400 -noout -in "$full" >/dev/null 2>&1; then
      echo "HAVE $d"
    else
      echo "RENEW $d"
    fi
  else
    echo "MISSING $d"
  fi
done
REMOTE_PROBE
) || { echo "cert-status probe failed (see ABORT line above)" >&2; exit 1; }

# Strict parsing (R2 CODE LOW): use `read -r` to enforce exactly two
# fields per line — "<STATE> <DOMAIN>". Anything else fatal. R3 dropped
# the vhost flag (R3 ARCH+CODE convergent MED): MISSING/EXPIRED always
# install the stub for safety; the flag was over-coarse.
_seen=()  # parallel array, linear scan (bash 3.2 — no `declare -A`)
while IFS= read -r line; do
  [ -z "$line" ] && continue
  read -r status domain extra <<<"$line"
  if [ -n "$extra" ]; then
    echo "aborting deploy: malformed cert-status line (extra field): '$line'" >&2
    exit 1
  fi
  case "$status" in
    HAVE|RENEW|EXPIRED|MISSING) ;;
    *) echo "aborting deploy: unknown cert-status state: '$status' in '$line'" >&2; exit 1 ;;
  esac
  # Reject unexpected domains.
  expected=0
  for d in "${DOMAINS_ALL[@]}"; do
    [ "$d" = "$domain" ] && expected=1 && break
  done
  if [ "$expected" -ne 1 ]; then
    echo "aborting deploy: unexpected domain in cert-status: '$domain'" >&2
    exit 1
  fi
  # bash 3.2 + set -u: guard empty-array expansion with ${arr[@]+...}.
  for s in ${_seen[@]+"${_seen[@]}"}; do
    if [ "$s" = "$domain" ]; then
      echo "aborting deploy: duplicate cert-status line for: '$domain'" >&2
      exit 1
    fi
  done
  _seen+=("$domain")
  DOMAINS_STATE_KEYS+=("$domain")
  DOMAINS_STATE_VALS+=("$status")
  case "$status" in
    HAVE)
      DOMAINS_HAVE_CERT+=("$domain")
      ;;
    RENEW)
      # Currently-valid cert; need certbot to refresh, but do NOT
      # install the stub — existing vhost stays in place so a certbot
      # failure leaves the soon-expiring cert serving instead of
      # replacing it with an HTTP-only stub.
      DOMAINS_NEED_CERT+=("$domain")
      ;;
    EXPIRED|MISSING)
      # No usable cert today: stub install is safe (no working TLS
      # vhost to clobber) and needed (so certbot webroot has a
      # /.well-known/acme-challenge/ listener). Always install the
      # stub, regardless of whether some other vhost happens to be
      # enabled at this hostname.
      DOMAINS_NEED_CERT+=("$domain")
      DOMAINS_NEED_STUB+=("$domain")
      ;;
  esac
done <<< "$CERT_STATUS"
# Coverage check — every expected domain accounted for.
for d in "${DOMAINS_ALL[@]}"; do
  found=0
  for s in ${_seen[@]+"${_seen[@]}"}; do
    [ "$s" = "$d" ] && found=1 && break
  done
  if [ "$found" -eq 0 ]; then
    echo "aborting deploy: cert-status missing for domain: '$d'" >&2
    exit 1
  fi
done
log "  cert status: have=[${DOMAINS_HAVE_CERT[*]:-none}] need_cert=[${DOMAINS_NEED_CERT[*]:-none}] need_stub=[${DOMAINS_NEED_STUB[*]:-none}]"

log "step 5/9: install port-80 ACME-stub for EXPIRED + MISSING domains"
# R3 CODE+ARCH MED: install the stub for EXPIRED + MISSING (no usable
# cert today). RENEW domains keep their existing vhost so a certbot
# failure leaves the soon-expiring cert serving instead of an HTTP-
# only stub. HAVE domains are untouched.
if [ ${#DOMAINS_NEED_STUB[@]} -eq 0 ]; then
  log "  no first-time-issuance domains — skipping stub install (preserves existing vhosts)"
else
  $SSH "set -e
    install -d -o www-data -g www-data -m 0755 /var/www/html
    for d in ${DOMAINS_NEED_STUB[*]}; do
      cat > /etc/nginx/sites-available/\$d <<NGINX_STUB
# Stub site — replaced by the full TLS config after Let's Encrypt cert
# is obtained. Only handles HTTP-01 challenge + redirect to https.
# (Issue #244 R3: installed for EXPIRED + MISSING; RENEW keeps its
# existing TLS vhost so a certbot failure leaves the soon-expiring
# cert serving instead of an HTTP-only stub.)
server {
    listen 80;
    listen [::]:80;
    server_name \$d;
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }
    location / {
        return 301 https://\\\$host\\\$request_uri;
    }
}
NGINX_STUB
      ln -sf /etc/nginx/sites-available/\$d /etc/nginx/sites-enabled/\$d
    done
    nginx -t
    systemctl reload nginx
  "
fi

log "step 6/9: obtain Let's Encrypt certs (per-domain, fail-soft)"
# Per-domain loop on the LOCAL side so the operator-visible WARN line
# is interleaved with each attempt; remote certbot invocations are
# allowed to fail without aborting the script (#244 fix (c)).
DOMAINS_ISSUED_OK=()
DOMAINS_ISSUED_FAIL=()
if [ ${#DOMAINS_NEED_CERT[@]} -eq 0 ]; then
  log "  no domains need issuance — skipping certbot"
else
  for d in ${DOMAINS_NEED_CERT[@]+"${DOMAINS_NEED_CERT[@]}"}; do
    log "  certbot certonly --webroot -d $d"
    if $SSH "certbot certonly --webroot -w /var/www/html -d $d --non-interactive --agree-tos --email $EMAIL"; then
      DOMAINS_ISSUED_OK+=("$d")
      log "    ok: cert issued for $d"
    else
      DOMAINS_ISSUED_FAIL+=("$d")
      # R3 CODE+ARCH LOW: state-aware messaging so the operator knows
      # which fallback applies to this specific failed domain.
      prior_state=""
      i=0
      for k in ${DOMAINS_STATE_KEYS[@]+"${DOMAINS_STATE_KEYS[@]}"}; do
        if [ "$k" = "$d" ]; then prior_state="${DOMAINS_STATE_VALS[$i]}"; break; fi
        i=$((i+1))
      done
      case "$prior_state" in
        RENEW)            log "    WARN: certbot failed for $d (was RENEW) — existing full TLS vhost left in place; soon-expiring cert keeps serving until next deploy" ;;
        EXPIRED|MISSING)  log "    WARN: certbot failed for $d (was $prior_state) — ACME stub left in place; HTTPS unavailable for $d until next deploy" ;;
        *)                log "    WARN: certbot failed for $d (state=$prior_state) — continuing deploy" ;;
      esac
    fi
  done
fi

# Final set of domains that should get a full TLS vhost installed.
DOMAINS_FULL_TLS=(${DOMAINS_HAVE_CERT[@]+"${DOMAINS_HAVE_CERT[@]}"} ${DOMAINS_ISSUED_OK[@]+"${DOMAINS_ISSUED_OK[@]}"})
log "step 6b/9: install nginx artifacts + full TLS vhost for [${DOMAINS_FULL_TLS[*]:-none}]"
# Shared http-context snippets always go in — no cert dependency.
$SSH "set -e
  install -o root -g root -m 0644 $DEPLOY_TMP/nginx-stats-shared.conf /etc/nginx/conf.d/stats-shared.conf
  install -o root -g root -m 0644 $DEPLOY_TMP/nginx-stats-security-headers.conf /etc/nginx/conf.d/stats-security-headers.conf
"

# Install the full TLS vhost ONLY for domains with a valid cert. Domains
# where certbot failed keep the ACME stub from step 5 (HTTP-80 only).
#
# The dist/ confs now ship with uncommented ssl_certificate lines (#244
# fix (a)), and the file-load assertion at the top of this script
# refuses to deploy if they get re-commented. No in-place sed surgery.
for d in ${DOMAINS_FULL_TLS[@]+"${DOMAINS_FULL_TLS[@]}"}; do
  case "$d" in
    "$DOMAIN")        src="$DEPLOY_TMP/nginx-coordinator-full.conf" ;;
    "$STATS_DOMAIN")  src="$DEPLOY_TMP/nginx-stats.streamvc.live.conf" ;;
    *) echo "  unknown domain in DOMAINS_FULL_TLS: $d (skipping)" >&2; continue ;;
  esac
  $SSH "set -e
    install -o root -g root -m 0644 $src /etc/nginx/sites-available/$d
    ln -sf /etc/nginx/sites-available/$d /etc/nginx/sites-enabled/$d
  "
done

# Clean up the per-deploy staging dir + the stale .full backup file
# from the broken-v1 deploy if present. validate + reload exactly once
# so a single bad file aborts the batch atomically.
$SSH "set -e
  rm -rf $DEPLOY_TMP
  rm -f /etc/nginx/sites-available/$DOMAIN.full
  nginx -t
  systemctl reload nginx
"

if [ ${#DOMAINS_ISSUED_FAIL[@]} -gt 0 ]; then
  log "  WARN: certbot failed for [${DOMAINS_ISSUED_FAIL[*]}] (state-aware fallback per-domain logged above)"
  log "  Check DNS A records (dig +short <domain>), then re-run this script to retry issuance."
fi

# R1 CODE HIGH-1 / SEC HIGH-2 / ARCH HIGH-1 (3-of-3 convergent) — fail
# closed BEFORE step 6c/7/8 if the primary $DOMAIN failed cert issuance
# this run. Step 8's curl https://$DOMAIN/healthz would otherwise hard-
# exit 1 first, masking the cert-failure contract.
#
# R1 SEC MED-3 / ARCH MED-2 — opt-in strict mode for non-primary
# domains. Default WARN-only matches the issue intent (stats. NXDOMAIN
# must not break primary deploy); STATS_REQUIRED=1 promotes any non-
# primary failure to a fail-closed exit so operators with strict
# uptime SLOs can enforce it.
_primary_failed=0
_nonprimary_failed=0
for d in ${DOMAINS_ISSUED_FAIL[@]+"${DOMAINS_ISSUED_FAIL[@]}"}; do
  if [ "$d" = "$DOMAIN" ]; then
    _primary_failed=1
  else
    _nonprimary_failed=1
  fi
done
if [ "$_primary_failed" -eq 1 ]; then
  # R4 ARCH MED-1: state-aware abort. For RENEW the existing TLS vhost
  # is kept and the soon-expiring cert is still serving; for EXPIRED/
  # MISSING the ACME stub is in place and HTTPS is gone.
  primary_prior_state=""
  i=0
  for k in ${DOMAINS_STATE_KEYS[@]+"${DOMAINS_STATE_KEYS[@]}"}; do
    if [ "$k" = "$DOMAIN" ]; then primary_prior_state="${DOMAINS_STATE_VALS[$i]}"; break; fi
    i=$((i+1))
  done
  echo "" >&2
  echo "  ABORT-EXIT: primary domain $DOMAIN failed cert issuance during this deploy." >&2
  case "$primary_prior_state" in
    RENEW)
      echo "             Prior state was RENEW — existing TLS vhost left in place;" >&2
      echo "             soon-expiring cert keeps serving until next deploy." >&2
      echo "             Fix DNS/certbot and re-run; do not wait beyond cert expiry." >&2
      ;;
    EXPIRED|MISSING)
      echo "             Prior state was $primary_prior_state — ACME stub is in place;" >&2
      echo "             HTTPS is unavailable on $DOMAIN until DNS/certbot is fixed" >&2
      echo "             and this script is re-run." >&2
      ;;
    *)
      echo "             Prior state was $primary_prior_state — re-run after fixing DNS/certbot." >&2
      ;;
  esac
  echo "             Coordinator binary NOT restarted — old binary still serving." >&2
  exit 9
fi
if [ "$_nonprimary_failed" -eq 1 ] && [ "${STATS_REQUIRED:-0}" = "1" ]; then
  echo "" >&2
  echo "  ABORT-EXIT: STATS_REQUIRED=1 set and a non-primary domain failed cert" >&2
  echo "             issuance ([${DOMAINS_ISSUED_FAIL[*]}]). Refusing to restart." >&2
  exit 9
fi

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
  # R6 — write via remote mktemp (see step 1c above for full rationale).
  $SSH "set -e
        install -d -o macprovider -g macprovider -m 0750 /var/lib/macprovider 2>/dev/null || true
        _bypass_tmp=\$(umask 077 && mktemp)
        cat > \"\$_bypass_tmp\" <<EOF
{\"ts\":\"$TS_NOW\",\"service\":\"coordinator\",\"reason\":\"FORCE_RESTART=1\",\"step\":\"6c\",\"metric\":\"connected_providers\",\"value\":$CONNECTED_COUNT,\"operator_host\":\"$OP_HOST\"}
EOF
        install -o macprovider -g macprovider -m 0640 \"\$_bypass_tmp\" /var/lib/macprovider/last-deploy-bypass.json
        rm -f \"\$_bypass_tmp\"
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

if [ -n "$CATALOG_REMOTE_PATH" ]; then
  echo "  GET https://$DOMAIN/catalog/current -> expect 200"
  # Issue #292 (LOW, deferred from #244 R6/R7 CODE+SEC): don't write
  # the smoke response to a predictable operator-Mac /tmp path. A
  # local attacker on the operator's workstation could pre-place a
  # symlink at /tmp/macprovider-catalog-current.json (or race the
  # curl -o open) to redirect the write. mktemp under umask 077
  # picks an unpredictable name with 0600 perms; cleanup rides the
  # unconditional EXIT trap registered above.
  CATALOG_SMOKE_TMP=$(umask 077 && mktemp -t macprovider-catalog-current.XXXXXXXX) || {
    echo "aborting smoke: mktemp failed" >&2
    exit 1
  }
  STATUS=$(curl -sS -o "$CATALOG_SMOKE_TMP" -w '%{http_code}' --max-time 10 --max-filesize 1048576 "https://$DOMAIN/catalog/current")
  if [ "$STATUS" != "200" ]; then
    echo "coordinator /catalog/current check failed: status=$STATUS body=$(head -c 300 "$CATALOG_SMOKE_TMP")" >&2
    exit 1
  fi
  echo "  catalog OK: $(python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); print("catalog_id=%s models=%d" % (c.get("catalog_id"), len(c.get("models", []))))' "$CATALOG_SMOKE_TMP")"
fi

# R3+R4+R5 stats smoke check on STATS_DOMAIN.
#
# R5 ARCH MED-1: coordinator's `stats.enabled` defaults FALSE — when
# it's not set or set to false, /v1/stats/* routes don't exist. Hitting
# them blind would flag a perfectly valid stats-disabled deploy as
# degraded. Parse `stats.enabled` from the SAME coordinator.yaml we
# just deployed; gate the smoke check on it.
STATS_ENABLED_LOCAL="$(yaml_block_value stats enabled)"
if [ "$STATS_ENABLED_LOCAL" = "true" ]; then
  echo "  GET https://$STATS_DOMAIN/v1/stats/health -> expect 200"
  # R4 CODE/SEC convergent HIGH — DON'T use `STATS=$(curl ... || echo 000)`:
  # curl prints `000` to stdout AND exits non-zero on TLS/DNS failure, so
  # the `|| echo 000` appends another `000` producing `STATS=000000` and
  # silently passing the `[ "$STATS" = "000" ]` failure branch.
  if ! STATS_STATUS=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "https://$STATS_DOMAIN/v1/stats/health" 2>/dev/null); then
    STATS_STATUS="000"
  fi
  if [ "$STATS_STATUS" != "200" ]; then
    if [ "$STATS_STATUS" = "000" ]; then
      echo "  WARN: $STATS_DOMAIN /v1/stats/health unreachable (TLS handshake or DNS failed)" >&2
    else
      echo "  WARN: $STATS_DOMAIN /v1/stats/health returned status=$STATS_STATUS (expected 200)" >&2
    fi
    if [ "${STATS_REQUIRED:-0}" = "1" ]; then
      echo "  STATS_REQUIRED=1 set — aborting." >&2
      exit 9
    fi
  else
    echo "  ok: $STATS_DOMAIN /v1/stats/health responded 200"
  fi
else
  # Stats disabled in deployed config. If STATS_REQUIRED=1, the operator
  # explicitly asked for strict mode but disabled stats — that's
  # incoherent; refuse. Otherwise just log and skip.
  if [ "${STATS_REQUIRED:-0}" = "1" ]; then
    echo "  ABORT: STATS_REQUIRED=1 but stats.enabled is not true in $CONFIG." >&2
    echo "         Enable stats in coordinator.yaml or drop STATS_REQUIRED=1." >&2
    exit 9
  fi
  echo "  stats.enabled is not true in $CONFIG — skipping $STATS_DOMAIN smoke check"
fi

log "step 9/9: tail the coordinator journal for sanity"
$SSH 'journalctl -u macprovider-coordinator --no-pager -n 20'

log "DONE. coordinator is live at https://$DOMAIN"
echo
echo "Next steps:"
echo "  - Stage 3: restart M4 phase3-binary with --coordinator wss://$DOMAIN/ws/provider"
echo "  - Verify: providers should appear in /poolz (auth: bearer operator_key from coordinator.yaml)"
echo "  - End-to-end: run harness against https://$DOMAIN"
