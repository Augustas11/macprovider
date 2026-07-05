#!/usr/bin/env bash
# check_stats_inventory_deploy_test.sh — offline validation for the
# stats hardware inventory sidecar deploy wiring.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEPLOY_SH="$DIST_DIR/deploy-pearl-vps.sh"
SERVICE="$DIST_DIR/stats-inventory-sync.service"
TIMER="$DIST_DIR/stats-inventory-sync.timer"
ENV_EXAMPLE="$DIST_DIR/stats-inventory-sync.env.example"
INVENTORY_EXAMPLE="$DIST_DIR/stats-hardware-inventory.yaml.example"
ROLE_SQL="$DIST_DIR/stats-inventory-writer.sql"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

for f in "$DEPLOY_SH" "$SERVICE" "$TIMER" "$ENV_EXAMPLE" "$INVENTORY_EXAMPLE" "$ROLE_SQL"; do
  [ -f "$f" ] || fail "missing required file: $f"
done

grep -qF 'STATS_INVENTORY_BINARY="$DIST_DIR/stats-inventory-sync-linux-amd64"' "$DEPLOY_SH" ||
  fail "deploy script missing sidecar binary variable"
grep -qF 'STATS_INVENTORY_SERVICE="$DIST_DIR/stats-inventory-sync.service"' "$DEPLOY_SH" ||
  fail "deploy script missing sidecar service variable"
grep -qF 'STATS_INVENTORY_TIMER="$DIST_DIR/stats-inventory-sync.timer"' "$DEPLOY_SH" ||
  fail "deploy script missing sidecar timer variable"
grep -qF 'getent group macprovider-stats' "$DEPLOY_SH" ||
  fail "deploy script must create isolated stats group"
grep -qF 'useradd --system --gid macprovider-stats' "$DEPLOY_SH" ||
  fail "deploy script must create isolated stats user"
grep -qF 'install -d -o root -g macprovider-stats -m 0750 /etc/macprovider-stats' "$DEPLOY_SH" ||
  fail "deploy script must create isolated stats config directory"
grep -qF 'install -d -o root -g macprovider-stats -m 0750 /opt/macprovider-stats' "$DEPLOY_SH" ||
  fail "deploy script must create isolated executable directory"
grep -qF '$SCP "$STATS_INVENTORY_BINARY"  "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-inventory-sync-linux-amd64"' "$DEPLOY_SH" ||
  fail "deploy script missing sidecar binary upload"
grep -qF '$SCP "$STATS_INVENTORY_SERVICE" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-inventory-sync.service"' "$DEPLOY_SH" ||
  fail "deploy script missing sidecar service upload"
grep -qF '$SCP "$STATS_INVENTORY_TIMER"   "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-inventory-sync.timer"' "$DEPLOY_SH" ||
  fail "deploy script missing sidecar timer upload"
grep -qF 'install -o root -g macprovider-stats -m 0750 $DEPLOY_TMP/stats-inventory-sync-linux-amd64 /opt/macprovider-stats/stats-inventory-sync' "$DEPLOY_SH" ||
  fail "deploy script missing sidecar binary install"
grep -qF 'install -o root -g root       -m 0644 $DEPLOY_TMP/stats-inventory-sync.service /etc/systemd/system/stats-inventory-sync.service' "$DEPLOY_SH" ||
  fail "deploy script missing sidecar service install"
grep -qF 'install -o root -g root       -m 0644 $DEPLOY_TMP/stats-inventory-sync.timer /etc/systemd/system/stats-inventory-sync.timer' "$DEPLOY_SH" ||
  fail "deploy script missing sidecar timer install"
grep -qF '[ -f /etc/macprovider-stats/stats-hardware-inventory.yaml ] && [ -f /etc/macprovider-stats/stats-inventory-sync.env ]' "$DEPLOY_SH" ||
  fail "deploy script must only enable timer when config and env exist"
grep -qF 'warning: stats-inventory-sync.service failed; leaving coordinator deploy running' "$DEPLOY_SH" ||
  fail "deploy script must not fail coordinator deploy on sidecar run failure"

grep -qxF 'User=macprovider-stats' "$SERVICE" ||
  fail "sidecar service must run as macprovider-stats"
grep -qxF 'Group=macprovider-stats' "$SERVICE" ||
  fail "sidecar service must run with macprovider-stats group"
grep -qxF 'ConditionPathExists=/etc/macprovider-stats/stats-hardware-inventory.yaml' "$SERVICE" ||
  fail "sidecar service must be opt-in on isolated inventory config"
grep -qxF 'EnvironmentFile=-/etc/macprovider-stats/stats-inventory-sync.env' "$SERVICE" ||
  fail "sidecar service must read isolated env file"
grep -qxF 'ExecStart=/opt/macprovider-stats/stats-inventory-sync --config /etc/macprovider-stats/stats-hardware-inventory.yaml' "$SERVICE" ||
  fail "sidecar service must execute from isolated traversable directory"
grep -qxF 'ReadOnlyPaths=/etc/macprovider-stats' "$SERVICE" ||
  fail "sidecar service must only read isolated stats config path"
grep -qxF 'OnUnitActiveSec=5min' "$TIMER" ||
  fail "sidecar timer must remain low-frequency"
grep -qF 'root:root 0600' "$ENV_EXAMPLE" ||
  fail "env example must document root-only DSN credentials"
grep -qF 'SELECT, INSERT, UPDATE, DELETE on chip_hardware_profiles' "$ENV_EXAMPLE" ||
  fail "env example must document chip DELETE privilege for reconciliation"
grep -qF 'SELECT, INSERT, UPDATE on provider_hardware_profiles' "$ENV_EXAMPLE" ||
  fail "env example must document provider inventory privileges"
grep -qF 'SELECT on hardware_verification_jobs' "$ENV_EXAMPLE" ||
  fail "env example must document demotion proof job read privilege"
grep -qF 'SELECT on hardware_verification_trust' "$ENV_EXAMPLE" ||
  fail "env example must document demotion proof trust read privilege"
grep -qF 'STATS_TRUST_INVENTORY_DSN=postgres://stats_trust_inventory_writer:' "$ENV_EXAMPLE" ||
  fail "env example must document separate trust inventory dsn"
grep -qF 'SELECT, INSERT, UPDATE, DELETE on hardware_verification_trust' "$ENV_EXAMPLE" ||
  fail "env example must document trusted hardware inventory privileges"
grep -qF 'GRANT SELECT ON hardware_verification_jobs TO stats_inventory_writer;' "$ROLE_SQL" ||
  fail "role sql must grant ordinary inventory writer read-only job evidence access"
grep -qF 'GRANT SELECT ON hardware_verification_trust TO stats_inventory_writer;' "$ROLE_SQL" ||
  fail "role sql must grant ordinary inventory writer read-only trust evidence access"
grep -qF 'GRANT SELECT, INSERT, UPDATE, DELETE ON hardware_verification_trust TO stats_trust_inventory_writer;' "$ROLE_SQL" ||
  fail "role sql must keep trust writes on separate trust writer role"
grep -qF "WHERE rolname = 'stats_inventory_writer'" "$ROLE_SQL" ||
  fail "role sql must be idempotent for existing inventory writer role"
grep -qF "WHERE rolname = 'stats_trust_inventory_writer'" "$ROLE_SQL" ||
  fail "role sql must be idempotent for existing trust writer role"
grep -qF 'operator fixture chip:' "$INVENTORY_EXAMPLE" ||
  fail "inventory example must use a fictional fixture chip key"
grep -qF '# trusted_hardware:' "$INVENTORY_EXAMPLE" ||
  fail "inventory example must document commented trusted hardware identity rows"
if grep -qE '^trusted_hardware:' "$INVENTORY_EXAMPLE"; then
  fail "inventory example must not ship an active authoritative trusted_hardware section"
fi
if grep -qF 'apple m' "$INVENTORY_EXAMPLE"; then
  fail "inventory example must not ship copyable Apple capacity guesses"
fi

if LC_ALL=C grep -q $'\r' "$SERVICE" "$TIMER" "$ENV_EXAMPLE" "$INVENTORY_EXAMPLE"; then
  fail "sidecar deploy artifacts contain CRLF line endings"
fi
if awk '/[^[:space:]]/ && /[[:blank:]]$/ { print FILENAME ":" FNR ":" $0; bad=1 } END { exit bad }' "$SERVICE" "$TIMER" "$ENV_EXAMPLE" "$INVENTORY_EXAMPLE" >&2; then
  :
else
  fail "sidecar deploy artifacts contain trailing whitespace"
fi

echo "ok: stats inventory sidecar deploy wiring"
