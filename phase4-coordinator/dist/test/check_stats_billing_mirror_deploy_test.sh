#!/usr/bin/env bash
# check_stats_billing_mirror_deploy_test.sh — offline validation for the
# stats billing mirror sidecar deploy wiring.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEPLOY_SH="$DIST_DIR/deploy-pearl-vps.sh"
SERVICE="$DIST_DIR/stats-billing-mirror.service"
TIMER="$DIST_DIR/stats-billing-mirror.timer"
ENV_EXAMPLE="$DIST_DIR/stats-billing-mirror.env.example"
BOOTSTRAP_SQL="$DIST_DIR/stats-billing-mirror-bootstrap.sql"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

for f in "$DEPLOY_SH" "$SERVICE" "$TIMER" "$ENV_EXAMPLE" "$BOOTSTRAP_SQL"; do
  [ -f "$f" ] || fail "missing required file: $f"
done

grep -qF 'STATS_BILLING_MIRROR_BINARY="$DIST_DIR/stats-billing-mirror-linux-amd64"' "$DEPLOY_SH" ||
  fail "deploy script missing billing mirror binary variable"
grep -qF 'STATS_BILLING_MIRROR_SERVICE="$PINNED_DIST_DIR/stats-billing-mirror.service"' "$DEPLOY_SH" ||
  fail "deploy script missing billing mirror service variable"
grep -qF 'STATS_BILLING_MIRROR_TIMER="$PINNED_DIST_DIR/stats-billing-mirror.timer"' "$DEPLOY_SH" ||
  fail "deploy script missing billing mirror timer variable"
grep -qF '$SCP "$STATS_BILLING_MIRROR_BINARY" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-billing-mirror-linux-amd64"' "$DEPLOY_SH" ||
  fail "deploy script missing billing mirror binary upload"
grep -qF 'for f in "$BINARY" "$CLI_BINARY" "$STATS_INVENTORY_BINARY" "$STATS_BILLING_MIRROR_BINARY"' "$DEPLOY_SH" ||
  fail "deploy preflight must require billing mirror binary"
grep -qF '"$STATS_BILLING_MIRROR_SERVICE" "$STATS_BILLING_MIRROR_TIMER"' "$DEPLOY_SH" ||
  fail "deploy preflight must require billing mirror unit files"
grep -qF '$SCP "$STATS_BILLING_MIRROR_SERVICE" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-billing-mirror.service"' "$DEPLOY_SH" ||
  fail "deploy script missing billing mirror service upload"
grep -qF '$SCP "$STATS_BILLING_MIRROR_TIMER"   "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/stats-billing-mirror.timer"' "$DEPLOY_SH" ||
  fail "deploy script missing billing mirror timer upload"
grep -qF 'install -o root -g macprovider-stats -m 0750 $DEPLOY_TMP/stats-billing-mirror-linux-amd64 /opt/macprovider-stats/stats-billing-mirror' "$DEPLOY_SH" ||
  fail "deploy script missing billing mirror binary install"
grep -qF 'setfacl -m u:macprovider-stats:r-- /var/lib/macprovider/request-log.sqlite' "$DEPLOY_SH" ||
  fail "deploy script must grant narrow SQLite file ACL"
grep -qF "echo '  warning: setfacl/getfacl not available; stats billing mirror will remain disabled until rollback-safe ACL management is available'" "$DEPLOY_SH" ||
  fail "deploy script must keep setfacl warning single-quoted inside SSH install block"
grep -qF 'su -s /bin/sh -c "test -r /var/lib/macprovider/request-log.sqlite" macprovider-stats' "$DEPLOY_SH" ||
  fail "deploy script must only enable mirror when stats user can read sqlite source"
grep -qF 'install -o root -g root       -m 0644 $DEPLOY_TMP/stats-billing-mirror.service /etc/systemd/system/stats-billing-mirror.service' "$DEPLOY_SH" ||
  fail "deploy script missing billing mirror service install"
grep -qF 'install -o root -g root       -m 0644 $DEPLOY_TMP/stats-billing-mirror.timer /etc/systemd/system/stats-billing-mirror.timer' "$DEPLOY_SH" ||
  fail "deploy script missing billing mirror timer install"
grep -qF '[ -f /etc/macprovider-stats/stats-billing-mirror.env ] && [ -f /var/lib/macprovider/request-log.sqlite ]' "$DEPLOY_SH" ||
  fail "deploy script must only enable timer when env and SQLite source exist"
grep -qF 'warning: stats-billing-mirror.service failed; leaving coordinator deploy running' "$DEPLOY_SH" ||
  fail "deploy script must not fail coordinator deploy on mirror run failure"

grep -qxF 'User=macprovider-stats' "$SERVICE" ||
  fail "billing mirror must run as dedicated stats user"
grep -qxF 'Group=macprovider-stats' "$SERVICE" ||
  fail "billing mirror must run with dedicated stats group"
grep -qxF 'ConditionPathExists=/etc/macprovider-stats/stats-billing-mirror.env' "$SERVICE" ||
  fail "billing mirror service must be opt-in on env file"
grep -qxF 'ConditionPathExists=/var/lib/macprovider/request-log.sqlite' "$SERVICE" ||
  fail "billing mirror service must require the SQLite source"
grep -qxF 'EnvironmentFile=/etc/macprovider-stats/stats-billing-mirror.env' "$SERVICE" ||
  fail "billing mirror service must read isolated env file"
grep -qxF 'ExecStart=/opt/macprovider-stats/stats-billing-mirror --sqlite /var/lib/macprovider/request-log.sqlite --ensure-schema=false' "$SERVICE" ||
  fail "billing mirror service must execute from deploy path"
grep -qxF 'ReadOnlyPaths=/var/lib/macprovider/request-log.sqlite' "$SERVICE" ||
  fail "billing mirror service must read only the SQLite source"
grep -qxF 'InaccessiblePaths=/etc/macprovider' "$SERVICE" ||
  fail "billing mirror service must not access coordinator secrets"
grep -qxF 'OnUnitActiveSec=60s' "$TIMER" ||
  fail "billing mirror timer must run frequently enough for public stats"
grep -qF 'stats_billing_mirror_writer' "$ENV_EXAMPLE" ||
  fail "env example must document dedicated writer role"
grep -qF 'STATS_BILLING_MIRROR_DSN=' "$ENV_EXAMPLE" ||
  fail "env example must define the expected DSN variable"
grep -qF 'runs with --ensure-schema=false' "$ENV_EXAMPLE" ||
  fail "env example must document bootstrap-before-service contract"
grep -qF 'CREATE TABLE IF NOT EXISTS ledger_request_credits' "$BOOTSTRAP_SQL" ||
  fail "bootstrap SQL must create ledger_request_credits"
if grep -qF "PASSWORD 'REPLACE_ME'" "$BOOTSTRAP_SQL"; then
  fail "bootstrap SQL must not create a known default password"
fi
grep -qF 'RAISE EXCEPTION' "$BOOTSTRAP_SQL" ||
  fail "bootstrap SQL must fail if writer role is missing"
grep -qF 'CREATE TABLE IF NOT EXISTS provider_tokens' "$BOOTSTRAP_SQL" ||
  fail "bootstrap SQL must create provider_tokens"
grep -qF 'GRANT SELECT ON ledger_request_credits TO stats_rollup' "$BOOTSTRAP_SQL" ||
  fail "bootstrap SQL must grant rollup read access"
grep -qF 'REVOKE ALL ON ledger_request_credits FROM stats_billing_mirror_writer' "$BOOTSTRAP_SQL" ||
  fail "bootstrap SQL must revoke direct writer table DML"
grep -qF 'REVOKE ALL ON FUNCTION stats_billing_mirror_upsert_request_credit' "$BOOTSTRAP_SQL" ||
  fail "bootstrap SQL must revoke public function execute"
grep -qF 'GRANT EXECUTE ON FUNCTION stats_billing_mirror_upsert_request_credit' "$BOOTSTRAP_SQL" ||
  fail "bootstrap SQL must grant constrained upsert function"
grep -qF 'CHECK (usage_source IN' "$BOOTSTRAP_SQL" ||
  fail "bootstrap SQL must carry source billing enum constraints"

if LC_ALL=C grep -q $'\r' "$SERVICE" "$TIMER" "$ENV_EXAMPLE" "$BOOTSTRAP_SQL"; then
  fail "billing mirror deploy artifacts contain CRLF line endings"
fi
if awk '/[^[:space:]]/ && /[[:blank:]]$/ { print FILENAME ":" FNR ":" $0; bad=1 } END { exit bad }' "$SERVICE" "$TIMER" "$ENV_EXAMPLE" "$BOOTSTRAP_SQL" >&2; then
  :
else
  fail "billing mirror deploy artifacts contain trailing whitespace"
fi

echo "ok: stats billing mirror deploy wiring"
