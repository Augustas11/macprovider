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
HARDWARE_TRUST_BOOTSTRAP="$DIST_DIR/hardware-trust-roles-bootstrap.sql"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

for f in "$DEPLOY_SH" "$SERVICE" "$TIMER" "$ENV_EXAMPLE" "$INVENTORY_EXAMPLE" "$ROLE_SQL" "$AUTH_POLICY_BOOTSTRAP" "$HARDWARE_TRUST_BOOTSTRAP"; do
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
grep -qF 'ONBOARDING_HARDWARE_TRUST_REQUEST_DSN="$(require_env_value "$env_file" ONBOARDING_HARDWARE_TRUST_REQUEST_DSN)"' "$DEPLOY_SH" ||
  fail "deploy script must require hardware-trust request DSN env var"
grep -qF 'ONBOARDING_HARDWARE_TRUST_APPROVE_DSN="$(require_env_value "$env_file" ONBOARDING_HARDWARE_TRUST_APPROVE_DSN)"' "$DEPLOY_SH" ||
  fail "deploy script must require hardware-trust approve DSN env var"
grep -qF 'psql_preflight_service hardware_trust_request_preflight "$ONBOARDING_HARDWARE_TRUST_REQUEST_DSN"' "$DEPLOY_SH" ||
  fail "deploy script must preflight hardware-trust request DSN through root-only service file"
grep -qF 'psql_preflight_service hardware_trust_approve_preflight "$ONBOARDING_HARDWARE_TRUST_APPROVE_DSN"' "$DEPLOY_SH" ||
  fail "deploy script must preflight hardware-trust approve DSN through root-only service file"
grep -qF "current_user = 'hardware_trust_requester'" "$DEPLOY_SH" ||
  fail "deploy script must validate the hardware-trust requester role identity"
grep -qF "current_user = 'hardware_trust_approver'" "$DEPLOY_SH" ||
  fail "deploy script must validate the hardware-trust approver role identity"
grep -qF "has_function_privilege(current_user, 'revoke_hardware_trust_approval(uuid,text,text,text,text)'::regprocedure, 'EXECUTE')" "$DEPLOY_SH" ||
  fail "deploy script must confirm the hardware-trust approver can revoke"
grep -qF 'session_user = current_user' "$DEPLOY_SH" ||
  fail "deploy script must reject SET ROLE based auth-policy DSNs"
grep -qF 'pg_auth_members' "$DEPLOY_SH" ||
  fail "deploy script must reject auth-policy roles with role memberships"
grep -qF 'psql_preflight_service hardware_verifier_preflight "$STATS_HARDWARE_VERIFIER_DSN"' "$DEPLOY_SH" ||
  fail "deploy script must preflight verifier DSN through root-only service file"
# FIX 7: the verifier preflight must assert the exact promotion role identity and
# its write grants (not just SELECT visibility), or a mis-provisioned verifier DSN
# that can never promote would pass and operators would commit unfulfillable
# approvals.
grep -qF "current_user = 'stats_hardware_verifier'" "$DEPLOY_SH" ||
  fail "deploy script must assert the verifier DSN maps to stats_hardware_verifier"
# FIX 3 (round-6): the verifier's write grants are COLUMN-scoped, so the preflight
# must validate them with has_column_privilege (has_table_privilege does not see
# column-only grants and wrongly rejected the correctly-provisioned role).
grep -qF "has_column_privilege(current_user, 'hardware_verification_jobs', 'status', 'UPDATE')" "$DEPLOY_SH" ||
  fail "deploy script must confirm the verifier can UPDATE hardware_verification_jobs.status (column-level)"
grep -qF "has_column_privilege(current_user, 'provider_hardware_profiles', 'verified', 'INSERT')" "$DEPLOY_SH" ||
  fail "deploy script must confirm the verifier can INSERT provider_hardware_profiles.verified (column-level)"
grep -qF "has_column_privilege(current_user, 'provider_hardware_profiles', 'verified', 'UPDATE')" "$DEPLOY_SH" ||
  fail "deploy script must confirm the verifier can UPDATE provider_hardware_profiles.verified (column-level)"
# FIX 5 (round-8): the verifier preflight must assert the FULL column write surface
# promoteJob/waitTrustJob/rejectJob write, not just status+verified. Enumerate every
# granted column (cross-checked against migration 008) so a DSN missing e.g.
# processed_at or last_reported_at cannot pass deploy then fail on first finalize.
for hvj_col in processed_at decision_reason; do
  grep -qF "has_column_privilege(current_user, 'hardware_verification_jobs', '$hvj_col', 'UPDATE')" "$DEPLOY_SH" ||
    fail "deploy script must confirm the verifier can UPDATE hardware_verification_jobs.$hvj_col (column-level)"
done
for php_ins_col in provider_id chip chip_normalized unified_memory_gb macos_version app_version source last_reported_at; do
  grep -qF "has_column_privilege(current_user, 'provider_hardware_profiles', '$php_ins_col', 'INSERT')" "$DEPLOY_SH" ||
    fail "deploy script must confirm the verifier can INSERT provider_hardware_profiles.$php_ins_col (column-level)"
done
for php_upd_col in chip chip_normalized unified_memory_gb macos_version app_version source last_reported_at; do
  grep -qF "has_column_privilege(current_user, 'provider_hardware_profiles', '$php_upd_col', 'UPDATE')" "$DEPLOY_SH" ||
    fail "deploy script must confirm the verifier can UPDATE provider_hardware_profiles.$php_upd_col (column-level)"
done
# FIX 7 (round-8): the onboarding preflight must exercise the LatestVerified
# admission join INCLUDING the hardware_verification_trust EXISTS, so a missing
# provider_onboarding SELECT grant on hardware_verification_trust fails the deploy
# rather than breaking every gated hello at runtime.
grep -qF 'FROM hardware_verification_trust t' "$DEPLOY_SH" ||
  fail "deploy script onboarding preflight must exercise the hardware_verification_trust admission join"
# FIX 3 (round-6): the verifier preflight must NOT assert NOINHERIT — nothing
# provisions stats_hardware_verifier as NOINHERIT (roles default INHERIT), so the
# assertion would fail every onboarding-enabled deploy.
grep -qF "current_user = 'stats_hardware_verifier'" "$DEPLOY_SH" &&
  ! awk '/hardware_verifier_preflight/,/does not map to the stats_hardware_verifier/' "$DEPLOY_SH" | grep -qF 'NOT rolinherit' ||
  fail "verifier preflight must not assert NOT rolinherit (NOINHERIT) on stats_hardware_verifier"
# FIX 7: when hardware-trust approval is enabled, a failed INITIAL verifier run
# must be FATAL (abort the deploy), not a warning.
grep -qF 'aborting deploy: stats-hardware-verifier.service failed its initial run and hardware-trust approval is enabled' "$DEPLOY_SH" ||
  fail "deploy script must fail the deploy when the initial verifier run fails under hardware-trust approval"
grep -qF 'ONBOARDING_HARDWARE_TRUST_REQUEST_DSN=' "$DEPLOY_SH" ||
  fail "deploy script must detect hardware-trust approval enablement before gating the verifier run"
# FIX 8: hardware-trust approval (request/approve DSNs required above) must be
# coupled to the verifier that promotes approved jobs. An absent verifier env
# must fail the deploy closed, not silently ship a coordinator that commits
# approvals no timer can fulfil.
grep -qF 'if [ ! -f "$verifier_env" ]; then' "$DEPLOY_SH" ||
  fail "deploy script must require the verifier env when hardware-trust approval is enabled"
grep -qF 'aborting deploy: hardware-trust approval DSNs are configured but $verifier_env is absent.' "$DEPLOY_SH" ||
  fail "deploy script must fail closed when hardware-trust DSNs are set but the verifier env is absent"
grep -qF 'service_file="$(umask 077 && mktemp)"' "$DEPLOY_SH" ||
  fail "deploy script must create root-only temporary libpq service file"
grep -qF 'PGSERVICEFILE="$service_file" PGSERVICE="$service_name" psql -v ON_ERROR_STOP=1 -qAt "$@"' "$DEPLOY_SH" ||
  fail "deploy script must invoke psql via service name without DSN argv"
grep -qF 'read_env_value()' "$DEPLOY_SH" ||
  fail "deploy script must parse DSN env files as data"
if grep -qF '. "$env_file"' "$DEPLOY_SH" ||
   grep -qF '. "$verifier_env"' "$DEPLOY_SH" ||
   grep -qF 'eval "value=' "$DEPLOY_SH"; then
  fail "deploy script must not source or eval env files containing DSN secrets"
fi
remote_preflight_tmp="$(mktemp)"
parser_tmp="$(mktemp)"
env_parse_tmp="$(mktemp)"
trap 'rm -f "$remote_preflight_tmp" "$parser_tmp" "$env_parse_tmp"' EXIT
awk '
  $0 == "REMOTE_ONBOARDING_PREFLIGHT" { in_block=0; end=1; next }
  in_block { print; next }
  index($0, "<<'\''REMOTE_ONBOARDING_PREFLIGHT'\''") { in_block=1; start=1; next }
  END { if (!start || !end || in_block) exit 1 }
' "$DEPLOY_SH" > "$remote_preflight_tmp" ||
  fail "deploy script must keep an extractable onboarding preflight remote heredoc"
if ! bash -n "$remote_preflight_tmp"; then
  fail "onboarding preflight remote heredoc must be valid bash"
fi
awk '
  $0 == "    read_env_value() {" { in_block=1 }
  in_block { print }
  in_block && $0 == "PY" { saw_py_end=1; next }
  in_block && saw_py_end && $0 == "    }" { exit }
  END { if (!saw_py_end) exit 1 }
' "$remote_preflight_tmp" > "$parser_tmp" ||
  fail "deploy script must keep an extractable env parser"
printf '%s\n' \
  'ONBOARDING_POSTGRES_DSN=postgres://first.example/db' \
  'ONBOARDING_POSTGRES_DSN=postgres://second.example/db' \
  > "$env_parse_tmp"
parsed_duplicate="$(
  . "$parser_tmp"
  read_env_value "$env_parse_tmp" ONBOARDING_POSTGRES_DSN
)"
if [ "$parsed_duplicate" != "postgres://second.example/db" ]; then
  fail "deploy env parser must use the last duplicate assignment"
fi
printf '%s\n' 'export ONBOARDING_POSTGRES_DSN=postgres://export.example/db' > "$env_parse_tmp"
if (
  . "$parser_tmp"
  read_env_value "$env_parse_tmp" ONBOARDING_POSTGRES_DSN >/dev/null 2>&1
); then
  fail "deploy env parser must reject shell export syntax that systemd EnvironmentFile does not use"
fi
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

grep -qF 'HARDWARE_TRUST_REQUESTER_PASSWORD' "$HARDWARE_TRUST_BOOTSTRAP" ||
  fail "hardware-trust bootstrap must require requester password env"
grep -qF 'HARDWARE_TRUST_APPROVER_PASSWORD' "$HARDWARE_TRUST_BOOTSTRAP" ||
  fail "hardware-trust bootstrap must require approver password env"
grep -qF "NULLIF(:'requester_password', '') IS NOT NULL" "$HARDWARE_TRUST_BOOTSTRAP" ||
  fail "hardware-trust bootstrap must reject empty requester password"
grep -qF "NULLIF(:'approver_password', '') IS NOT NULL" "$HARDWARE_TRUST_BOOTSTRAP" ||
  fail "hardware-trust bootstrap must reject empty approver password"
grep -qF "ALTER ROLE hardware_trust_requester LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS PASSWORD :'requester_password';" "$HARDWARE_TRUST_BOOTSTRAP" ||
  fail "hardware-trust bootstrap must enable requester login with explicit least-privilege attributes"
grep -qF "ALTER ROLE hardware_trust_approver LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS PASSWORD :'approver_password';" "$HARDWARE_TRUST_BOOTSTRAP" ||
  fail "hardware-trust bootstrap must enable approver login with explicit least-privilege attributes"
if grep -qF 'ALTER ROLE hardware_trust_definer LOGIN' "$HARDWARE_TRUST_BOOTSTRAP"; then
  fail "hardware-trust bootstrap must keep the definer role NOLOGIN"
fi
grep -qF 'FROM pg_auth_members m' "$HARDWARE_TRUST_BOOTSTRAP" ||
  fail "hardware-trust bootstrap must remove split-role memberships dynamically"
grep -qF 'REVOKE ALL ON hardware_trust_pending FROM hardware_trust_requester, hardware_trust_approver;' "$HARDWARE_TRUST_BOOTSTRAP" ||
  fail "hardware-trust bootstrap must remove direct split-role table privileges"
grep -qF '\set ON_ERROR_STOP on' "$HARDWARE_TRUST_BOOTSTRAP" ||
  fail "hardware-trust bootstrap must fail fast on SQL errors"
grep -qF 'BEGIN;' "$HARDWARE_TRUST_BOOTSTRAP" ||
  fail "hardware-trust bootstrap must run role changes in a transaction"
grep -qF 'COMMIT;' "$HARDWARE_TRUST_BOOTSTRAP" ||
  fail "hardware-trust bootstrap must commit only after all role repairs succeed"
ht_alter_line="$(grep -nF "ALTER ROLE hardware_trust_requester LOGIN NOSUPERUSER" "$HARDWARE_TRUST_BOOTSTRAP" | cut -d: -f1 | head -n1)"
ht_cleanup_line="$(grep -nF 'FROM pg_auth_members m' "$HARDWARE_TRUST_BOOTSTRAP" | cut -d: -f1 | head -n1)"
if [ -z "$ht_alter_line" ] || [ -z "$ht_cleanup_line" ] || [ "$ht_cleanup_line" -le "$ht_alter_line" ]; then
  fail "hardware-trust bootstrap must clean memberships after ALTER ROLE password/attribute repair"
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

# Issue #582 MIGRATION-019 ORDERING: the pre-019 stats-inventory-sync binary
# reconciles with a 2-column ON CONFLICT that migration 019's 3-column PRIMARY
# KEY breaks. Migration 019 is NOT applied at coordinator boot (see main.go) — it
# is applied by the coordinator's out-of-band `stats-migrate` subcommand. So the
# deploy cannot merely CHECK 019 is present; to make the standard path
# self-enforcing it must run the FULL ordered workflow itself:
#   quiesce (stop+disable old sidecar)
#     -> apply migration 019 via `coordinator stats-migrate` (inside the quiesced window)
#       -> onboarding hardware-trust preflight (which requires 019 present)
#         -> install the new 3-column sidecar binary (step 4)
#           -> re-enable the sidecar timer (step 9)
# The load-bearing invariant is that the sidecar stays disabled from BEFORE any
# 019 apply until AFTER the new 3-column binary is installed, and that the deploy
# — not an out-of-band operator step — applies 019 so the ordering is provable.
grep -qF 'stats-inventory-sync unit did not quiesce before migration' "$DEPLOY_SH" ||
  fail "deploy script must quiesce stats-inventory-sync before the migration"
grep -qF 'systemctl disable "$unit"' "$DEPLOY_SH" ||
  fail "deploy script must disable (not merely stop) the inventory sidecar during the pre-migration quiesce"
# The deploy must APPLY 019 itself (self-enforcing standard path), not just verify
# it. It resolves the admin DSN from coordinator.env as DATA (require_env_value,
# never sourced — enforced above) and drives the coordinator's stats-migrate.
grep -qF 'COORDINATOR_PARTNER_KEYS_ADMIN_DSN="$(require_env_value "$env_file" COORDINATOR_PARTNER_KEYS_ADMIN_DSN)"' "$DEPLOY_SH" ||
  fail "deploy script must read the stats admin DSN as data (require_env_value) to self-apply migration 019"
grep -qF '"$coordinator_bin" stats-migrate' "$DEPLOY_SH" ||
  fail "deploy script must apply stats migrations itself via coordinator stats-migrate inside the quiesced window"
# HARD GATE: 019 must be applied after stats-migrate, else the on-disk coordinator
# predates issue #582 and the deploy must abort rather than install + re-enable a
# 3-column sidecar against a coordinator that cannot own the operator_api rows.
grep -qF 'migration 019 (hardware_verification_trust 3-column PRIMARY KEY) is not applied after stats-migrate;' "$DEPLOY_SH" ||
  fail "deploy script must hard-gate on migration 019 being applied after stats-migrate"

INV_QUIESCE_LINE=$(grep -nF 'stats-inventory-sync unit did not quiesce before migration' "$DEPLOY_SH" | head -1 | cut -d: -f1)
INV_MIGRATE_APPLY_LINE=$(grep -nF '"$coordinator_bin" stats-migrate' "$DEPLOY_SH" | head -1 | cut -d: -f1)
INV_MIGRATE_GATE_LINE=$(grep -nF 'migration 019 (hardware_verification_trust 3-column PRIMARY KEY) is not applied after stats-migrate;' "$DEPLOY_SH" | head -1 | cut -d: -f1)
INV_PREFLIGHT_LINE=$(grep -nF 'psql_preflight_service hardware_trust_request_preflight' "$DEPLOY_SH" | head -1 | cut -d: -f1)
INV_NEW_BINARY_LINE=$(grep -nF 'install -o root -g macprovider-stats -m 0750 $DEPLOY_TMP/stats-inventory-sync-linux-amd64 /opt/macprovider-stats/stats-inventory-sync' "$DEPLOY_SH" | head -1 | cut -d: -f1)
INV_REENABLE_LINE=$(grep -nF 'systemctl enable --now stats-inventory-sync.timer' "$DEPLOY_SH" | head -1 | cut -d: -f1)
for anchor in "$INV_QUIESCE_LINE" "$INV_MIGRATE_APPLY_LINE" "$INV_MIGRATE_GATE_LINE" "$INV_PREFLIGHT_LINE" "$INV_NEW_BINARY_LINE" "$INV_REENABLE_LINE"; do
  [ -n "$anchor" ] ||
    fail "could not locate one of the ordered MIGRATION-019 workflow anchors (quiesce/apply/gate/preflight/new-binary/re-enable)"
done
# 1. quiesce precedes the 019 apply (old binary is stopped+disabled before the migration touches the schema)
[ "$INV_QUIESCE_LINE" -lt "$INV_MIGRATE_APPLY_LINE" ] ||
  fail "stats-inventory-sync quiesce (line $INV_QUIESCE_LINE) must precede the 019 stats-migrate apply (line $INV_MIGRATE_APPLY_LINE)"
# 2. the 019 apply + hard gate precede the onboarding preflight that requires 019 present
[ "$INV_MIGRATE_GATE_LINE" -lt "$INV_PREFLIGHT_LINE" ] ||
  fail "the 019 apply hard gate (line $INV_MIGRATE_GATE_LINE) must precede the hardware-trust migration preflight (line $INV_PREFLIGHT_LINE)"
# 3. the 019 apply precedes the new 3-column sidecar binary install (schema migrated before the new binary lands)
[ "$INV_MIGRATE_APPLY_LINE" -lt "$INV_NEW_BINARY_LINE" ] ||
  fail "the 019 stats-migrate apply (line $INV_MIGRATE_APPLY_LINE) must precede the new sidecar binary install (line $INV_NEW_BINARY_LINE)"
# 4. re-enable follows the new 3-column sidecar binary install (never re-enable an old binary against the migrated schema)
[ "$INV_NEW_BINARY_LINE" -lt "$INV_REENABLE_LINE" ] ||
  fail "the new sidecar binary install (line $INV_NEW_BINARY_LINE) must precede the sidecar timer re-enable (line $INV_REENABLE_LINE)"

# Issue #582 MIGRATION-019 UNIVERSAL SCHEMA GATE (all deploy paths): round-14's
# 019 auto-apply is gated on ONBOARDING_ENABLED_LOCAL=true, but the new 3-column
# stats-inventory-sync binary is installed on EVERY deploy. A NON-onboarding
# deploy against a pre-019 schema would install + re-enable the 3-column sidecar
# whose trusted_hardware reconciliation then fails (warning-only) — silently
# breaking trust-inventory sync. A universal, read-only, fail-closed gate must run
# OUTSIDE the onboarding-gated block, AFTER the onboarding auto-apply and BEFORE
# the sidecar binary install + timer re-enable, and ABORT (exit 12) when 019's
# shape (source column + 3-column PK) is absent.
grep -qF 'stats-inventory-sync migration-019 schema gate (all deploy paths)' "$DEPLOY_SH" ||
  fail "deploy script must carry a universal (all-paths) migration-019 stats-inventory-sync schema gate"
# The gate must couple to migration 019's exact shape: the source column and the
# 3-column PRIMARY KEY, probed read-only.
grep -qF "column_name = 'source'" "$DEPLOY_SH" ||
  fail "migration-019 gate must probe hardware_verification_trust.source via information_schema.columns"
grep -qF "= ARRAY['provider_id', 'hardware_identity_hash', 'source']" "$DEPLOY_SH" ||
  fail "migration-019 gate must probe the 3-column (provider_id, hardware_identity_hash, source) PRIMARY KEY"
grep -qF "c.contype = 'p'" "$DEPLOY_SH" ||
  fail "migration-019 gate must inspect the PRIMARY KEY via pg_constraint"
# The gate must use the sidecar's own trust DSN, read as data (not sourced) and
# passed to psql via a root-only service file (no DSN in argv/ps).
grep -qF 'read_env_value "$inventory_env" STATS_TRUST_INVENTORY_DSN' "$DEPLOY_SH" ||
  fail "migration-019 gate must read the sidecar STATS_TRUST_INVENTORY_DSN as data"
grep -qF 'PGSERVICEFILE="$service_file" PGSERVICE=stats_trust_019_gate psql -v ON_ERROR_STOP=1' "$DEPLOY_SH" ||
  fail "migration-019 gate must probe via a root-only PGSERVICEFILE without exposing the DSN in argv"
if grep -qF 'psql "$trust_dsn"' "$DEPLOY_SH" ||
   grep -qF 'PGDATABASE="$trust_dsn" psql' "$DEPLOY_SH"; then
  fail "migration-019 gate must not expose the trust DSN via psql argv or PGDATABASE"
fi
# The gate must abort (exit 12) fail-closed when 019 is absent.
grep -qF 'the new stats-inventory-sync binary requires migration 019' "$DEPLOY_SH" ||
  fail "migration-019 gate must abort with a clear message when the 019 schema is absent"
grep -qF 'Refusing to install/re-enable the 3-column stats-inventory-sync sidecar against a pre-019 schema.' "$DEPLOY_SH" ||
  fail "migration-019 gate must refuse to install/re-enable the 3-column sidecar against a pre-019 schema"
# Anchor the gate abort and confirm ordering: it runs on the NON-onboarding path
# (after the onboarding-gated block closes) and before the sidecar binary install
# and timer re-enable.
GATE_019_LINE=$(grep -nF 'stats-inventory-sync migration-019 schema gate (all deploy paths)' "$DEPLOY_SH" | grep -F 'log ' | head -1 | cut -d: -f1)
GATE_019_ABORT_LINE=$(grep -nF 'the new stats-inventory-sync binary requires migration 019' "$DEPLOY_SH" | head -1 | cut -d: -f1)
ONBOARDING_HEREDOC_END_LINE=$(grep -nxF 'REMOTE_ONBOARDING_PREFLIGHT' "$DEPLOY_SH" | tail -1 | cut -d: -f1)
ONBOARDING_ELSE_SKIP_LINE=$(grep -nF 'onboarding.app_track_register_enabled is not true — skipping hardware evidence migration preflight' "$DEPLOY_SH" | head -1 | cut -d: -f1)
for anchor in "$GATE_019_LINE" "$GATE_019_ABORT_LINE" "$ONBOARDING_HEREDOC_END_LINE" "$ONBOARDING_ELSE_SKIP_LINE"; do
  [ -n "$anchor" ] ||
    fail "could not locate one of the migration-019 universal gate anchors (gate/abort/onboarding-heredoc-end/onboarding-else)"
done
# The gate must sit AFTER the onboarding preflight heredoc AND the onboarding
# `else` skip branch — i.e. outside the ONBOARDING_ENABLED_LOCAL=true block, so it
# runs on the non-onboarding path too.
[ "$GATE_019_LINE" -gt "$ONBOARDING_HEREDOC_END_LINE" ] ||
  fail "migration-019 gate (line $GATE_019_LINE) must run AFTER the onboarding preflight heredoc (line $ONBOARDING_HEREDOC_END_LINE), i.e. outside the onboarding-gated block"
[ "$GATE_019_LINE" -gt "$ONBOARDING_ELSE_SKIP_LINE" ] ||
  fail "migration-019 gate (line $GATE_019_LINE) must run AFTER the onboarding else-skip branch (line $ONBOARDING_ELSE_SKIP_LINE), i.e. on the non-onboarding path"
# The gate must precede the unconditional sidecar binary install and timer re-enable.
[ "$GATE_019_ABORT_LINE" -lt "$INV_NEW_BINARY_LINE" ] ||
  fail "migration-019 gate abort (line $GATE_019_ABORT_LINE) must precede the sidecar binary install (line $INV_NEW_BINARY_LINE)"
[ "$GATE_019_ABORT_LINE" -lt "$INV_REENABLE_LINE" ] ||
  fail "migration-019 gate abort (line $GATE_019_ABORT_LINE) must precede the sidecar timer re-enable (line $INV_REENABLE_LINE)"
# The universal gate's remote heredoc must be valid bash.
gate_heredoc_tmp="$(mktemp)"
trap 'rm -f "$remote_preflight_tmp" "$parser_tmp" "$env_parse_tmp" "$gate_heredoc_tmp"' EXIT
awk '
  $0 == "REMOTE_STATS_019_GATE" { in_block=0; end=1; next }
  in_block { print; next }
  index($0, "<<'\''REMOTE_STATS_019_GATE'\''") { in_block=1; start=1; next }
  END { if (!start || !end || in_block) exit 1 }
' "$DEPLOY_SH" > "$gate_heredoc_tmp" ||
  fail "deploy script must keep an extractable migration-019 gate remote heredoc"
if ! bash -n "$gate_heredoc_tmp"; then
  fail "migration-019 gate remote heredoc must be valid bash"
fi

# FIX (round-15 fail-open): the universal migration-019 gate reads the sidecar's
# STATS_TRUST_INVENTORY_DSN via read_env_value to decide applicability. A parse
# error (read_env_value exit 2 — e.g. a malformed unrelated env line that systemd
# itself tolerates) must NOT be conflated with a clean-absent DSN. Conflating them
# fails OPEN: the gate no-ops, then step 9 re-enables the 3-column sidecar against a
# possibly-pre-019 schema. The gate must fail CLOSED (abort, exit 12) on a parse
# error and only no-op when the DSN is cleanly absent.
gate_parser_tmp="$(mktemp)"
gate_env_tmp="$(mktemp)"
trap 'rm -f "$remote_preflight_tmp" "$parser_tmp" "$env_parse_tmp" "$gate_heredoc_tmp" "$gate_parser_tmp" "$gate_env_tmp"' EXIT
# Behavioral: the gate's own read_env_value must signal a malformed env file as
# exit 2 (parse error), distinct from a clean-absent DSN's exit 1, so the gate's
# classification can tell them apart.
awk '
  $0 == "    read_env_value() {" { in_block=1 }
  in_block { print }
  $0 == "    }" && in_block { in_block=0 }
' "$gate_heredoc_tmp" > "$gate_parser_tmp" ||
  fail "migration-019 gate must keep an extractable env parser"
# A malformed line systemd would ignore, immediately followed by a valid DSN it hides.
printf '%s\n' 'this line has no equals sign' 'STATS_TRUST_INVENTORY_DSN=postgres://trust.example/db' > "$gate_env_tmp"
gate_parse_rc=0
(
  . "$gate_parser_tmp"
  read_env_value "$gate_env_tmp" STATS_TRUST_INVENTORY_DSN >/dev/null 2>&1
) || gate_parse_rc=$?
if [ "$gate_parse_rc" -ne 2 ]; then
  fail "migration-019 gate parser must signal a malformed env file as exit 2 (got $gate_parse_rc), not clean-absent"
fi
# Clean-absent must remain exit 1 (distinct) so the gate can still safely no-op.
printf '%s\n' '# no trust DSN configured' > "$gate_env_tmp"
gate_absent_rc=0
(
  . "$gate_parser_tmp"
  read_env_value "$gate_env_tmp" STATS_TRUST_INVENTORY_DSN >/dev/null 2>&1
) || gate_absent_rc=$?
if [ "$gate_absent_rc" -ne 1 ]; then
  fail "migration-019 gate parser must signal a clean-absent DSN as exit 1 (got $gate_absent_rc)"
fi
# Static: the gate must capture read_env_value's exit code and fail CLOSED (abort,
# exit 12) on any rc that is neither success (0) nor clean-absent (1), only
# no-opping on the clean-absent case — never folding a parse error into the no-op.
grep -qF 'trust_dsn="$(read_env_value "$inventory_env" STATS_TRUST_INVENTORY_DSN)" || trust_dsn_rc=$?' "$DEPLOY_SH" ||
  fail "migration-019 gate must capture read_env_value's exit code (not fold a parse error into the no-op)"
grep -qF '[ "$trust_dsn_rc" -ne 0 ] && [ "$trust_dsn_rc" -ne 1 ]' "$DEPLOY_SH" ||
  fail "migration-019 gate must fail closed on an rc that is neither 0 (present) nor 1 (clean-absent)"
grep -qF 'could not be parsed to determine STATS_TRUST_INVENTORY_DSN' "$DEPLOY_SH" ||
  fail "migration-019 gate must abort with a clear parse-error message when the trust env file cannot be parsed"

# FIX (round-17 present-but-DSN-absent): the universal migration-019 gate no-longer
# keys its applicability on the DSN's presence. The REAL trigger for trust
# reconciliation — and thus for this gate — is whether the inventory YAML DECLARES a
# trusted_hardware section (mirroring the sidecar's UnmarshalYAML "omitted vs explicit
# {}" contract). If trusted_hardware is DECLARED but STATS_TRUST_INVENTORY_DSN is
# clean-absent, step 9 re-enables the sidecar and its reconciliation fails permanently
# (warning-only) — a silently-broken deploy. The gate must abort (exit 12) in that
# case, and still no-op only when trusted_hardware is provably OMITTED.
#
# Static: presence is determined with a REAL YAML parser (PyYAML), not a
# grep/sed-for-structure hand-parse, and it fails closed.
grep -qF 'trusted_hardware_present()' "$DEPLOY_SH" ||
  fail "migration-019 gate must key applicability on trusted_hardware presence (trusted_hardware_present helper)"
awk '/trusted_hardware_present\(\) \{/,/^    \}$/' "$DEPLOY_SH" | grep -qF 'import yaml' ||
  fail "migration-019 gate must detect trusted_hardware presence with a real YAML parser (import yaml)"
awk '/trusted_hardware_present\(\) \{/,/^    \}$/' "$DEPLOY_SH" | grep -qF '"trusted_hardware" in doc' ||
  fail "migration-019 gate must test top-level trusted_hardware key membership (present incl. {} => reconciliation declared)"
grep -qF 'declares a trusted_hardware section but STATS_TRUST_INVENTORY_DSN is not set' "$DEPLOY_SH" ||
  fail "migration-019 gate must abort when trusted_hardware is declared but the trust DSN is absent"
# Static: the presence check must run BEFORE the trust DSN read, so an omitted
# trusted_hardware short-circuits to a no-op and a declared one reaches the DSN check.
TH_PRESENCE_LINE=$(grep -nF 'trusted_hardware_present "$inventory_yaml"' "$DEPLOY_SH" | head -1 | cut -d: -f1)
TRUST_DSN_READ_LINE=$(grep -nF 'trust_dsn="$(read_env_value "$inventory_env" STATS_TRUST_INVENTORY_DSN)"' "$DEPLOY_SH" | head -1 | cut -d: -f1)
[ -n "$TH_PRESENCE_LINE" ] && [ -n "$TRUST_DSN_READ_LINE" ] ||
  fail "could not locate the trusted_hardware presence check and/or the trust DSN read in the migration-019 gate"
[ "$TH_PRESENCE_LINE" -lt "$TRUST_DSN_READ_LINE" ] ||
  fail "migration-019 gate must determine trusted_hardware presence (line $TH_PRESENCE_LINE) BEFORE reading the trust DSN (line $TRUST_DSN_READ_LINE)"

# Behavioral: run the extracted gate heredoc end-to-end against fixtures, with the two
# hardcoded /etc paths retargeted to temp files and a stub psql on PATH (the abort/no-op
# cases never invoke psql; the happy path needs it to exit 0). This exercises the real
# gate control flow, not just its text.
gate_run_dir="$(mktemp -d)"
gate_stub_bin="$gate_run_dir/bin"
trap 'rm -rf "$remote_preflight_tmp" "$parser_tmp" "$env_parse_tmp" "$gate_heredoc_tmp" "$gate_parser_tmp" "$gate_env_tmp" "$gate_run_dir"' EXIT
mkdir -p "$gate_stub_bin"
# Stub psql: for the fixtures that reach it (declared + DSN present), 019 is "present".
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$gate_stub_bin/psql"
chmod +x "$gate_stub_bin/psql"

run_gate_fixture() {
  # $1 inventory yaml body, $2 env body -> prints "<rc>" and captured output on stdout
  gf_yaml="$gate_run_dir/inventory.yaml"
  gf_env="$gate_run_dir/inventory.env"
  gf_script="$gate_run_dir/gate.sh"
  printf '%s' "$1" > "$gf_yaml"
  printf '%s' "$2" > "$gf_env"
  sed \
    -e "s|^    inventory_yaml=/etc/macprovider-stats/stats-hardware-inventory.yaml\$|    inventory_yaml=$gf_yaml|" \
    -e "s|^    inventory_env=/etc/macprovider-stats/stats-inventory-sync.env\$|    inventory_env=$gf_env|" \
    "$gate_heredoc_tmp" > "$gf_script"
  grep -qF "inventory_yaml=$gf_yaml" "$gf_script" ||
    fail "gate fixture harness failed to retarget inventory_yaml path"
  grep -qF "inventory_env=$gf_env" "$gf_script" ||
    fail "gate fixture harness failed to retarget inventory_env path"
  gf_rc=0
  gf_out="$(PATH="$gate_stub_bin:$PATH" bash "$gf_script" 2>&1)" || gf_rc=$?
  printf '%s' "$gf_out"
  return "$gf_rc"
}

# 1) trusted_hardware OMITTED + no DSN => no-op (exit 0). Unchanged pre-existing path.
omit_rc=0
omit_out="$(run_gate_fixture $'chips:\n  fixture-chip:\n    display_chip: Fixture\nproviders: {}\n' $'# no trust dsn configured\n')" || omit_rc=$?
if [ "$omit_rc" -ne 0 ]; then
  fail "migration-019 gate must no-op (exit 0) when trusted_hardware is omitted (got $omit_rc): $omit_out"
fi
printf '%s' "$omit_out" | grep -qF 'key omitted' ||
  fail "migration-019 gate omitted-trusted_hardware no-op must announce the key is omitted: $omit_out"

# 2) trusted_hardware PRESENT (explicit {} revoke-all) + clean-absent DSN => abort (exit 12).
#    This is the round-17 MEDIUM: declared reconciliation with no DSN to perform it.
present_noargs_rc=0
present_noargs_out="$(run_gate_fixture $'chips:\n  fixture-chip:\n    display_chip: Fixture\ntrusted_hardware: {}\n' $'# no trust dsn configured\n')" || present_noargs_rc=$?
if [ "$present_noargs_rc" -ne 12 ]; then
  fail "migration-019 gate must abort exit 12 when trusted_hardware is declared but the trust DSN is absent (got $present_noargs_rc): $present_noargs_out"
fi
printf '%s' "$present_noargs_out" | grep -qF 'declares a trusted_hardware section but STATS_TRUST_INVENTORY_DSN is not set' ||
  fail "migration-019 gate present-but-DSN-absent abort must name the missing STATS_TRUST_INVENTORY_DSN: $present_noargs_out"

# 3) trusted_hardware PRESENT + DSN present + (stub) 019 shape present => proceed (exit 0).
#    Proves the declared+provisioned happy path still deploys.
present_ok_rc=0
present_ok_out="$(run_gate_fixture $'chips:\n  fixture-chip:\n    display_chip: Fixture\ntrusted_hardware: {}\n' $'STATS_TRUST_INVENTORY_DSN=postgres://trust.example/db\n')" || present_ok_rc=$?
if [ "$present_ok_rc" -ne 0 ]; then
  fail "migration-019 gate must proceed (exit 0) when trusted_hardware is declared and both the DSN and 019 schema are present (got $present_ok_rc): $present_ok_out"
fi
printf '%s' "$present_ok_out" | grep -qF 'migration 019 shape present' ||
  fail "migration-019 gate declared+provisioned happy path must confirm the 019 shape: $present_ok_out"

# Issue #582 (MEDIUM #6) — stats-inventory-sync deployment restore-on-failure.
# The sidecar is quiesced (stop+disable) before migration 019 widens the trust
# PK, so an abort BEFORE the schema/binary become incompatible must RESTORE it,
# while an abort once that parity line is crossed must LEAVE it stopped.

# 1) Static: the prior-state capture and the quiesce-attempt arming must PRECEDE
#    the quiesce for-loop, so the recorded state is the true pre-quiesce state and
#    the EXIT trap always knows a quiesce was attempted.
grep -qF 'SIDECAR_QUIESCE_ATTEMPTED=1' "$DEPLOY_SH" ||
  fail "deploy script must arm SIDECAR_QUIESCE_ATTEMPTED before quiescing the sidecar"
grep -qF '_prior_next=$_prior.next.$$' "$DEPLOY_SH" ||
  fail "deploy script must capture the sidecar prior enable/active state before quiescing"
grep -qF 'rm -f /opt/macprovider/.coordinator-deploy-sidecar-parity-required' "$DEPLOY_SH" ||
  fail "deploy script must clear any stale sidecar parity marker before quiescing"
SIDECAR_CAPTURE_LINE=$(grep -nF '_prior_next=$_prior.next.$$' "$DEPLOY_SH" | head -1 | cut -d: -f1)
SIDECAR_ARM_LINE=$(grep -nF 'SIDECAR_QUIESCE_ATTEMPTED=1' "$DEPLOY_SH" | head -1 | cut -d: -f1)
SIDECAR_QUIESCE_LOOP_LINE=$(grep -nF 'for unit in stats-inventory-sync.timer stats-inventory-sync.service; do' "$DEPLOY_SH" | head -1 | cut -d: -f1)
for anchor in "$SIDECAR_CAPTURE_LINE" "$SIDECAR_ARM_LINE" "$SIDECAR_QUIESCE_LOOP_LINE"; do
  [ -n "$anchor" ] ||
    fail "could not locate one of the sidecar restore-on-failure anchors (capture/arm/quiesce-loop)"
done
[ "$SIDECAR_ARM_LINE" -lt "$SIDECAR_QUIESCE_LOOP_LINE" ] ||
  fail "SIDECAR_QUIESCE_ATTEMPTED arming (line $SIDECAR_ARM_LINE) must precede the quiesce loop (line $SIDECAR_QUIESCE_LOOP_LINE)"
[ "$SIDECAR_CAPTURE_LINE" -lt "$SIDECAR_QUIESCE_LOOP_LINE" ] ||
  fail "sidecar prior-state capture (line $SIDECAR_CAPTURE_LINE) must precede the quiesce loop (line $SIDECAR_QUIESCE_LOOP_LINE)"

# 2) Static: the parity marker (the schema/binary-incompatible crossing) must be
#    set BEFORE the migration apply, and the EXIT trap must invoke the restore.
grep -qF '_sidecar_restore_on_abort "$_deploy_rc"' "$DEPLOY_SH" ||
  fail "EXIT trap must invoke _sidecar_restore_on_abort with the deploy exit code"
SIDECAR_PARITY_TOUCH_LINE=$(grep -nF 'touch /opt/macprovider/.coordinator-deploy-sidecar-parity-required' "$DEPLOY_SH" | head -1 | cut -d: -f1)
SIDECAR_MIGRATE_APPLY_BARE_LINE=$(grep -nE '^[[:space:]]*"\$coordinator_bin" stats-migrate$' "$DEPLOY_SH" | head -1 | cut -d: -f1)
[ -n "$SIDECAR_PARITY_TOUCH_LINE" ] && [ -n "$SIDECAR_MIGRATE_APPLY_BARE_LINE" ] ||
  fail "could not locate the sidecar parity marker touch and/or the bare stats-migrate apply"
[ "$SIDECAR_PARITY_TOUCH_LINE" -lt "$SIDECAR_MIGRATE_APPLY_BARE_LINE" ] ||
  fail "sidecar parity marker (line $SIDECAR_PARITY_TOUCH_LINE) must be set BEFORE the migration apply (line $SIDECAR_MIGRATE_APPLY_BARE_LINE)"

# 3) Behavioral: extract _sidecar_restore_on_abort and drive it with a stub $SSH
#    to prove: a pre-migration (parity-absent) abort RESTORES the sidecar; a
#    post-migration (parity-present) abort LEAVES it stopped with the parity
#    message and never restores; an armed abort defers to the rollback's
#    leave-stopped; and a successful deploy is a no-op.
sidecar_fn_tmp="$(mktemp)"
trap 'rm -f "$remote_preflight_tmp" "$parser_tmp" "$env_parse_tmp" "$gate_heredoc_tmp" "$gate_parser_tmp" "$gate_env_tmp" "$sidecar_fn_tmp"; rm -rf "$gate_run_dir"' EXIT
awk '/^_sidecar_restore_on_abort\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$DEPLOY_SH" > "$sidecar_fn_tmp" ||
  fail "deploy script must keep an extractable _sidecar_restore_on_abort function"
grep -qF '_sidecar_restore_on_abort()' "$sidecar_fn_tmp" ||
  fail "extracted sidecar restore function is empty"
if ! bash -n "$sidecar_fn_tmp"; then
  fail "extracted _sidecar_restore_on_abort must be valid bash"
fi

run_sidecar_case() {
  # $1 rc, $2 COORDINATOR_DEPLOY_ARMED, $3 parity-present-flag
  (
    _stub_ssh() {
      case "$*" in
        *coordinator-deploy-sidecar-parity-required*)
          [ "${STUB_PARITY_PRESENT:-0}" = 1 ] && return 0 || return 1 ;;
        *coordinator-deploy-sidecar-prior-state*)
          echo "STUB_RESTORE_INVOKED"; return 0 ;;
      esac
      return 0
    }
    SSH=_stub_ssh
    SIDECAR_QUIESCE_ATTEMPTED=1
    COORDINATOR_DEPLOY_ARMED="$2"
    STUB_PARITY_PRESENT="$3"
    # shellcheck disable=SC1090
    . "$sidecar_fn_tmp"
    _sidecar_restore_on_abort "$1"
  ) 2>&1
}

restore_out="$(run_sidecar_case 1 0 0)"
printf '%s' "$restore_out" | grep -qF 'restored to its pre-quiesce state' ||
  fail "pre-migration abort must restore the sidecar: $restore_out"
printf '%s' "$restore_out" | grep -qF 'STUB_RESTORE_INVOKED' ||
  fail "pre-migration abort must actually invoke the sidecar restore SSH: $restore_out"

parity_out="$(run_sidecar_case 1 0 1)"
printf '%s' "$parity_out" | grep -qF 'deliberately left stopped (schema/binary parity required — migration 019 applied' ||
  fail "post-migration abort must leave the sidecar stopped with the parity message: $parity_out"
if printf '%s' "$parity_out" | grep -qF 'STUB_RESTORE_INVOKED'; then
  fail "post-migration abort must NOT restore the sidecar: $parity_out"
fi

armed_out="$(run_sidecar_case 1 1 0)"
printf '%s' "$armed_out" | grep -qF 'the armed rollback leaves the old 2-column sidecar stopped' ||
  fail "armed abort must defer to the rollback and leave the sidecar stopped: $armed_out"
if printf '%s' "$armed_out" | grep -qF 'STUB_RESTORE_INVOKED'; then
  fail "armed abort must NOT independently restore the sidecar: $armed_out"
fi

noop_out="$(run_sidecar_case 0 0 0)"
if [ -n "$noop_out" ]; then
  fail "a successful deploy (rc=0) must be a sidecar restore no-op: $noop_out"
fi

if LC_ALL=C grep -q $'\r' "$SERVICE" "$TIMER" "$ENV_EXAMPLE" "$INVENTORY_EXAMPLE" "$AUTH_POLICY_BOOTSTRAP" "$HARDWARE_TRUST_BOOTSTRAP"; then
  fail "sidecar deploy artifacts contain CRLF line endings"
fi
if awk '/[^[:space:]]/ && /[[:blank:]]$/ { print FILENAME ":" FNR ":" $0; bad=1 } END { exit bad }' "$SERVICE" "$TIMER" "$ENV_EXAMPLE" "$INVENTORY_EXAMPLE" "$AUTH_POLICY_BOOTSTRAP" "$HARDWARE_TRUST_BOOTSTRAP" >&2; then
  :
else
  fail "sidecar deploy artifacts contain trailing whitespace"
fi

echo "ok: stats inventory sidecar deploy wiring"
