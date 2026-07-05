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
AUTH_POLICY_BOOTSTRAP="$DIST_DIR/provider-auth-policy-roles-bootstrap.sql"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

for f in "$DEPLOY_SH" "$SERVICE" "$TIMER" "$ENV_EXAMPLE" "$INVENTORY_EXAMPLE" "$ROLE_SQL" "$AUTH_POLICY_BOOTSTRAP"; do
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
grep -qF 'psql_preflight_service onboarding_preflight "$ONBOARDING_POSTGRES_DSN"' "$DEPLOY_SH" ||
  fail "deploy script must preflight onboarding DSN through root-only service file"
grep -qF 'psql_preflight_service auth_policy_request_preflight "$ONBOARDING_AUTH_POLICY_REQUEST_DSN"' "$DEPLOY_SH" ||
  fail "deploy script must preflight auth-policy request DSN through root-only service file"
grep -qF 'psql_preflight_service auth_policy_approve_preflight "$ONBOARDING_AUTH_POLICY_APPROVE_DSN"' "$DEPLOY_SH" ||
  fail "deploy script must preflight auth-policy approve DSN through root-only service file"
grep -qF 'psql_preflight_service auth_policy_cutover_preflight "$ONBOARDING_AUTH_POLICY_CUTOVER_DSN"' "$DEPLOY_SH" ||
  fail "deploy script must preflight auth-policy cutover DSN through root-only service file"
grep -qF 'session_user = current_user' "$DEPLOY_SH" ||
  fail "deploy script must reject SET ROLE based auth-policy DSNs"
grep -qF 'pg_auth_members' "$DEPLOY_SH" ||
  fail "deploy script must reject auth-policy roles with role memberships"
grep -qF 'psql_preflight_service hardware_verifier_preflight "$STATS_HARDWARE_VERIFIER_DSN"' "$DEPLOY_SH" ||
  fail "deploy script must preflight verifier DSN through root-only service file"
grep -qF 'service_file="$(umask 077 && mktemp)"' "$DEPLOY_SH" ||
  fail "deploy script must create root-only temporary libpq service file"
grep -qF 'PGSERVICEFILE="$service_file" PGSERVICE="$service_name" psql -v ON_ERROR_STOP=1 -qAt "$@"' "$DEPLOY_SH" ||
  fail "deploy script must invoke psql via service name without DSN argv"
if grep -qF 'PGDATABASE="$ONBOARDING_POSTGRES_DSN" psql' "$DEPLOY_SH" ||
   grep -qF 'PGDATABASE="$STATS_HARDWARE_VERIFIER_DSN" psql' "$DEPLOY_SH" ||
   grep -qF 'psql "$ONBOARDING_POSTGRES_DSN"' "$DEPLOY_SH" ||
   grep -qF 'psql "$STATS_HARDWARE_VERIFIER_DSN"' "$DEPLOY_SH"; then
  fail "deploy script must not expose URI DSNs via PGDATABASE or psql argv"
fi

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
grep -qF 'PROVIDER_AUTH_POLICY_REQUESTER_PASSWORD' "$AUTH_POLICY_BOOTSTRAP" ||
  fail "auth-policy bootstrap must require requester password env"
grep -qF 'PROVIDER_AUTH_POLICY_APPROVER_PASSWORD' "$AUTH_POLICY_BOOTSTRAP" ||
  fail "auth-policy bootstrap must require approver password env"
grep -qF 'PROVIDER_AUTH_POLICY_CUTOVER_PASSWORD' "$AUTH_POLICY_BOOTSTRAP" ||
  fail "auth-policy bootstrap must require cutover password env"
grep -qF "NULLIF(:'requester_password', '') IS NOT NULL" "$AUTH_POLICY_BOOTSTRAP" ||
  fail "auth-policy bootstrap must reject empty requester password"
grep -qF "NULLIF(:'approver_password', '') IS NOT NULL" "$AUTH_POLICY_BOOTSTRAP" ||
  fail "auth-policy bootstrap must reject empty approver password"
grep -qF "NULLIF(:'cutover_password', '') IS NOT NULL" "$AUTH_POLICY_BOOTSTRAP" ||
  fail "auth-policy bootstrap must reject empty cutover password"
grep -qF "ALTER ROLE provider_auth_policy_requester LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS PASSWORD :'requester_password';" "$AUTH_POLICY_BOOTSTRAP" ||
  fail "auth-policy bootstrap must enable requester login with explicit least-privilege attributes"
grep -qF "ALTER ROLE provider_auth_policy_approver LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS PASSWORD :'approver_password';" "$AUTH_POLICY_BOOTSTRAP" ||
  fail "auth-policy bootstrap must enable approver login with explicit least-privilege attributes"
grep -qF "ALTER ROLE provider_auth_policy_cutover LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS PASSWORD :'cutover_password';" "$AUTH_POLICY_BOOTSTRAP" ||
  fail "auth-policy bootstrap must enable cutover login with explicit least-privilege attributes"
grep -qF 'FROM pg_auth_members m' "$AUTH_POLICY_BOOTSTRAP" ||
  fail "auth-policy bootstrap must remove split-role memberships dynamically"
grep -qF 'REVOKE ALL ON provider_auth_policy_pending FROM provider_auth_policy_requester, provider_auth_policy_approver, provider_auth_policy_cutover;' "$AUTH_POLICY_BOOTSTRAP" ||
  fail "auth-policy bootstrap must remove direct split-role table privileges"
grep -qF '\set ON_ERROR_STOP on' "$AUTH_POLICY_BOOTSTRAP" ||
  fail "auth-policy bootstrap must fail fast on SQL errors"
grep -qF 'BEGIN;' "$AUTH_POLICY_BOOTSTRAP" ||
  fail "auth-policy bootstrap must run role changes in a transaction"
grep -qF 'COMMIT;' "$AUTH_POLICY_BOOTSTRAP" ||
  fail "auth-policy bootstrap must commit only after all role repairs succeed"
alter_line="$(grep -nF "ALTER ROLE provider_auth_policy_requester LOGIN NOSUPERUSER" "$AUTH_POLICY_BOOTSTRAP" | cut -d: -f1 | head -n1)"
cleanup_line="$(grep -nF 'FROM pg_auth_members m' "$AUTH_POLICY_BOOTSTRAP" | cut -d: -f1 | head -n1)"
if [ -z "$alter_line" ] || [ -z "$cleanup_line" ] || [ "$cleanup_line" -le "$alter_line" ]; then
  fail "auth-policy bootstrap must clean memberships after ALTER ROLE password/attribute repair"
fi
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

if LC_ALL=C grep -q $'\r' "$SERVICE" "$TIMER" "$ENV_EXAMPLE" "$INVENTORY_EXAMPLE" "$AUTH_POLICY_BOOTSTRAP"; then
  fail "sidecar deploy artifacts contain CRLF line endings"
fi
if awk '/[^[:space:]]/ && /[[:blank:]]$/ { print FILENAME ":" FNR ":" $0; bad=1 } END { exit bad }' "$SERVICE" "$TIMER" "$ENV_EXAMPLE" "$INVENTORY_EXAMPLE" "$AUTH_POLICY_BOOTSTRAP" >&2; then
  :
else
  fail "sidecar deploy artifacts contain trailing whitespace"
fi

echo "ok: stats inventory sidecar deploy wiring"
