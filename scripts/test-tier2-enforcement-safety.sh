#!/usr/bin/env bash
# Hermetic safety checks for scripts/enforce-tier2-hash.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_ROOT="${TMPDIR:-/tmp}/tier2-enforce-test.$$"
TEST_ROOT="$TMP_ROOT/tree"
mkdir -p "$TEST_ROOT/scripts" "$TEST_ROOT/ops/pearl-updater"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
  printf '[tier2-enforce-test] ERROR: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local needle="$2"
  if ! grep -Fq -- "$needle" "$file"; then
    printf '%s\n' "--- $file ---" >&2
    cat "$file" >&2 || true
    fail "expected '$needle' in $file"
  fi
}

assert_not_contains() {
  local file="$1"
  local needle="$2"
  if grep -Fq -- "$needle" "$file"; then
    printf '%s\n' "--- $file ---" >&2
    cat "$file" >&2 || true
    fail "did not expect '$needle' in $file"
  fi
}

cp "$REPO_ROOT/scripts/enforce-tier2-hash.sh" "$TEST_ROOT/scripts/enforce-tier2-hash.sh"
cp "$REPO_ROOT/ops/pearl-updater/macprovider-pearl-update" \
  "$TEST_ROOT/ops/pearl-updater/macprovider-pearl-update"
cp "$REPO_ROOT/ops/pearl-updater/macprovider-tier2-enforcement-watchdog" \
  "$TEST_ROOT/ops/pearl-updater/macprovider-tier2-enforcement-watchdog"
cp "$REPO_ROOT/ops/pearl-updater/macprovider-pearl-update-gate" \
  "$TEST_ROOT/ops/pearl-updater/macprovider-pearl-update-gate"
cp "$REPO_ROOT/ops/pearl-updater/macprovider-tier2-enforcement-reconcile.service" \
  "$TEST_ROOT/ops/pearl-updater/macprovider-tier2-enforcement-reconcile.service"
cp "$REPO_ROOT/ops/pearl-updater/macprovider-pearl-updater-transaction-gate.conf" \
  "$TEST_ROOT/ops/pearl-updater/macprovider-pearl-updater-transaction-gate.conf"
chmod 755 \
  "$TEST_ROOT/scripts/enforce-tier2-hash.sh" \
  "$TEST_ROOT/ops/pearl-updater/macprovider-pearl-update" \
  "$TEST_ROOT/ops/pearl-updater/macprovider-tier2-enforcement-watchdog" \
  "$TEST_ROOT/ops/pearl-updater/macprovider-pearl-update-gate"

for deploy_script in \
  "$REPO_ROOT/phase4-coordinator/dist/deploy-malibu-emission-pearl.sh" \
  "$REPO_ROOT/phase4-coordinator/dist/deploy-opoi-v0-pearl.sh"; do
  if DRY_RUN=0 bash "$deploy_script" >"$TMP_ROOT/retired.out" 2>"$TMP_ROOT/retired.err"; then
    fail "expected retired coordinator-only Pearl deploy to refuse live execution"
  fi
  assert_contains "$TMP_ROOT/retired.err" \
    "this coordinator-only Pearl deploy authority is retired"
  assert_contains "$TMP_ROOT/retired.err" "Use the signed backend-pair updater"
done

cat >"$TEST_ROOT/scripts/verify-tier2-live.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$1" >>"$FAKE_LOG"
[ "${BAD_VERIFY:-0}" != "1" ] || { printf '{"mode":"wrong"}\n'; exit 0; }
case "$1" in
  --enforce-ready)
    [ "${FAIL_READY:-0}" != "1" ] || exit 9
    printf '{"mode":"enforce-ready","require_verified":false,"snapshot_manifest_provider_count":2}\n'
    ;;
  --enforced)
    [ "${FAIL_ENFORCED:-0}" != "1" ] || exit 10
    printf '{"mode":"enforced","require_verified":true,"snapshot_manifest_provider_count":2}\n'
    ;;
  *)
    exit 2
    ;;
esac
SH
chmod 755 "$TEST_ROOT/scripts/verify-tier2-live.sh"

cat >"$TMP_ROOT/ssh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cmd="${*: -1}"
printf 'ARGS:%s\n' "$*" >>"$FAKE_SSH_LOG"
printf '%s\n' "$cmd" >>"$FAKE_SSH_LOG"
transaction=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
previous=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
enforced=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
release=/opt/macprovider/autotune/releases/test-release
case "$cmd" in
  *"systemctl is-enabled --quiet macprovider-tier2-enforcement-reconcile.service"*)
    [ "${FAIL_INSTALL_CONTROLS:-0}" != "1" ] || exit 17
    printf 'installed_controls=ok\n'
    ;;
  *"remote_posture=ok"*)
    [ "${FAIL_POSTURE:-0}" != "1" ] || exit 8
    printf 'remote_posture=ok\n'
    ;;
  *"macprovider-tier2-enforcement-watchdog --arm"*)
    [ "${FAIL_ARM:-0}" != "1" ] || exit 13
    printf '{"action":"armed","transaction_id":"%s","previous_config_sha256":"%s","enforced_config_sha256":"%s","release_pointer":"%s"}\n' \
      "$transaction" "$previous" "$enforced" "$release"
    ;;
  *"macprovider-tier2-enforcement-watchdog --commit"*)
    [ "${FAIL_COMMIT:-0}" != "1" ] || exit 15
    printf '{"action":"committed","transaction_id":"%s","previous_config_sha256":"%s","enforced_config_sha256":"%s","release_pointer":"%s"}\n' \
      "$transaction" "$previous" "$enforced" "$release"
    ;;
  *"macprovider-tier2-enforcement-watchdog --rollback"*)
    [ "${ROLLBACK_STALE:-0}" != "1" ] || exit 14
    printf '{"action":"rolled_back","transaction_id":"%s","previous_config_sha256":"%s","enforced_config_sha256":"%s","release_pointer":"%s"}\n' \
      "$transaction" "$previous" "$enforced" "$release"
    ;;
  *"macprovider-tier2-enforcement-watchdog --reconcile"*)
    [ "${FAIL_RECONCILE:-0}" != "1" ] || exit 16
    action=reconciled
    [ "${COMMIT_TERMINAL:-0}" != "1" ] || action=committed
    printf '{"action":"%s","transaction_id":"%s","previous_config_sha256":"%s","enforced_config_sha256":"%s","release_pointer":"%s"}\n' \
      "$action" \
      "$transaction" "$previous" "$enforced" "$release"
    ;;
  *"--prove-hash-enforced"*)
    [ "${FAIL_POST_PROOF:-0}" != "1" ] || exit 11
    [ "${BAD_PROOF:-0}" != "1" ] || { printf '{"action":"wrong"}\n'; exit 0; }
    printf '{"action":"prove_hash_enforced","candidate":"v1.8.60","tier2_catalog_path":"/opt/macprovider/autotune/current/tier2-catalog.json","hash_enforced_buyer_serving_cycles":3}\n'
    ;;
  *"--prove-current"*)
    [ "${BAD_PROOF:-0}" != "1" ] || { printf '{"action":"wrong"}\n'; exit 0; }
    printf '{"action":"prove_current","candidate":"v1.8.60","tier2_catalog_path":"/opt/macprovider/autotune/current/tier2-catalog.json","single_authority_buyer_serving_cycles":3}\n'
    ;;
  *"date --iso-8601=seconds"*)
    printf '2026-07-23T20:00:00+00:00\n'
    ;;
  *"tier2 config reloaded"*)
    printf 'May 31 tier2 config reloaded provider_hash_statuses_updated=2\n'
    ;;
  *"journalctl"*)
    [ "${FAIL_JOURNAL_READ:-0}" != "1" ] || exit 12
    if [ "${STOP_EVENT:-0}" = "1" ]; then
      printf '{"event":"hash_required_provider_excluded","reason":"catalog_unavailable"}\n'
    else
      printf 'May 31 unrelated coordinator event\n'
    fi
    ;;
  *)
    printf 'ok\n'
    ;;
esac
SH
chmod 755 "$TMP_ROOT/ssh"

run_apply() {
  FAKE_LOG="$TMP_ROOT/verify.log" \
    FAKE_SSH_LOG="$TMP_ROOT/ssh.log" \
    SSH_BIN="$TMP_ROOT/ssh" \
    SSH_KEY="$TMP_ROOT/key" \
    SSH_KNOWN_HOSTS="$TMP_ROOT/known_hosts" \
    DEMO_TOKEN=demo \
    OPERATOR_KEY=operator \
    PROOF_TAG="${PROOF_TAG:-v1.8.60}" \
    "$TEST_ROOT/scripts/enforce-tier2-hash.sh" --apply
}

touch "$TMP_ROOT/key" "$TMP_ROOT/known_hosts"
chmod 600 "$TMP_ROOT/key" "$TMP_ROOT/known_hosts"
cp "$TEST_ROOT/ops/pearl-updater/macprovider-pearl-update" "$TMP_ROOT/substitute-updater"
chmod 755 "$TMP_ROOT/substitute-updater"

: >"$TMP_ROOT/verify.log"
: >"$TMP_ROOT/ssh.log"
run_apply >/tmp/tier2-enforce-success.out
assert_contains "$TMP_ROOT/verify.log" "--enforce-ready"
assert_contains "$TMP_ROOT/verify.log" "--enforced"
assert_contains "$TMP_ROOT/ssh.log" "--prove-current"
assert_contains "$TMP_ROOT/ssh.log" "--prove-hash-enforced"
assert_contains "$TMP_ROOT/ssh.log" "macprovider-tier2-enforcement-watchdog --arm"
assert_contains "$TMP_ROOT/ssh.log" "macprovider-tier2-enforcement-watchdog --commit"
assert_contains "$TMP_ROOT/ssh.log" "macprovider-tier2-enforcement-reconcile.service"
assert_contains "$TMP_ROOT/ssh.log" "macprovider-pearl-update-gate"
assert_contains "$TMP_ROOT/ssh.log" "50-pearl-updater-transaction-gate.conf"
assert_contains "$TMP_ROOT/ssh.log" "systemctl is-enabled --quiet"
assert_contains "$TMP_ROOT/ssh.log" "NeedDaemonReload"
assert_not_contains "$TMP_ROOT/ssh.log" "macprovider-tier2-enforcement-watchdog --rollback"
assert_contains "$TMP_ROOT/ssh.log" "-o BatchMode=yes"
assert_contains "$TMP_ROOT/ssh.log" "-o StrictHostKeyChecking=yes"
assert_contains "$TMP_ROOT/ssh.log" "-o GlobalKnownHostsFile=/dev/null"
assert_contains "$TMP_ROOT/ssh.log" "-F /dev/null"

: >"$TMP_ROOT/verify.log"
: >"$TMP_ROOT/ssh.log"
if FAIL_READY=1 run_apply >/tmp/tier2-enforce-ready-fail.out 2>/tmp/tier2-enforce-ready-fail.err; then
  fail "expected strict readiness failure"
fi
assert_not_contains "$TMP_ROOT/ssh.log" "macprovider-tier2-enforcement-watchdog --arm"

: >"$TMP_ROOT/verify.log"
: >"$TMP_ROOT/ssh.log"
if FAIL_INSTALL_CONTROLS=1 run_apply \
  >/tmp/tier2-enforce-controls-fail.out 2>/tmp/tier2-enforce-controls-fail.err; then
  fail "expected missing or stale installed recovery controls to fail before proof"
fi
assert_not_contains "$TMP_ROOT/ssh.log" "remote_posture=ok"
assert_not_contains "$TMP_ROOT/ssh.log" "macprovider-tier2-enforcement-watchdog --arm"

: >"$TMP_ROOT/verify.log"
: >"$TMP_ROOT/ssh.log"
if BAD_VERIFY=1 run_apply >/tmp/tier2-enforce-bad-verify.out 2>/tmp/tier2-enforce-bad-verify.err; then
  fail "expected unbound verifier output to fail"
fi
assert_not_contains "$TMP_ROOT/ssh.log" "macprovider-tier2-enforcement-watchdog --arm"

: >"$TMP_ROOT/verify.log"
: >"$TMP_ROOT/ssh.log"
if BAD_PROOF=1 run_apply >/tmp/tier2-enforce-bad-proof.out 2>/tmp/tier2-enforce-bad-proof.err; then
  fail "expected unbound remote proof output to fail"
fi
assert_not_contains "$TMP_ROOT/ssh.log" "macprovider-tier2-enforcement-watchdog --arm"

: >"$TMP_ROOT/verify.log"
: >"$TMP_ROOT/ssh.log"
if FAIL_ARM=1 run_apply >/tmp/tier2-enforce-arm-fail.out 2>/tmp/tier2-enforce-arm-fail.err; then
  fail "expected a failed arm to exit after immediate recovery"
fi
assert_contains "$TMP_ROOT/ssh.log" "macprovider-tier2-enforcement-watchdog --reconcile"
assert_contains /tmp/tier2-enforce-arm-fail.err "immediate recovery re-proved enforcement=false"
assert_contains "$TMP_ROOT/verify.log" "--enforce-ready"

for failure in FAIL_ENFORCED FAIL_POST_PROOF STOP_EVENT FAIL_JOURNAL_READ FAIL_POSTURE; do
  : >"$TMP_ROOT/verify.log"
  : >"$TMP_ROOT/ssh.log"
  export "$failure=1"
  if run_apply >/tmp/tier2-enforce-failure.out 2>/tmp/tier2-enforce-failure.err; then
    unset "$failure"
    fail "expected $failure to fail"
  fi
  unset "$failure"
  if [ "$failure" != "FAIL_POSTURE" ]; then
    assert_contains "$TMP_ROOT/ssh.log" "macprovider-tier2-enforcement-watchdog --rollback"
  fi
done

: >"$TMP_ROOT/verify.log"
: >"$TMP_ROOT/ssh.log"
if FAIL_COMMIT=1 run_apply >/tmp/tier2-enforce-commit-fail.out 2>/tmp/tier2-enforce-commit-fail.err; then
  fail "expected failed commit to trigger rollback"
fi
assert_contains "$TMP_ROOT/ssh.log" "macprovider-tier2-enforcement-watchdog --reconcile"
assert_contains /tmp/tier2-enforce-commit-fail.err "reconciled to enforcement=false"
assert_contains "$TMP_ROOT/verify.log" "--enforce-ready"

: >"$TMP_ROOT/verify.log"
: >"$TMP_ROOT/ssh.log"
FAIL_COMMIT=1 COMMIT_TERMINAL=1 run_apply \
  >/tmp/tier2-enforce-commit-terminal.out 2>/tmp/tier2-enforce-commit-terminal.err
assert_contains "$TMP_ROOT/ssh.log" "macprovider-tier2-enforcement-watchdog --reconcile"
assert_contains /tmp/tier2-enforce-commit-terminal.err "terminal cleanup was reconciled and re-proved"
assert_contains "$TMP_ROOT/verify.log" "--enforced"

: >"$TMP_ROOT/verify.log"
: >"$TMP_ROOT/ssh.log"
if FAIL_ENFORCED=1 ROLLBACK_STALE=1 run_apply >/tmp/tier2-enforce-stale-rollback.out 2>/tmp/tier2-enforce-stale-rollback.err; then
  fail "expected stale rollback refusal"
fi
assert_contains /tmp/tier2-enforce-stale-rollback.err "durable remote watchdog remains authoritative"

: >"$TMP_ROOT/verify.log"
: >"$TMP_ROOT/ssh.log"
if VERIFY_TIER2_FIXTURES="$TMP_ROOT" run_apply >/tmp/tier2-enforce-fixture-reject.out 2>/tmp/tier2-enforce-fixture-reject.err; then
  fail "expected production apply to reject verifier fixtures"
fi
assert_contains /tmp/tier2-enforce-fixture-reject.err "VERIFY_TIER2_FIXTURES is forbidden"
assert_not_contains "$TMP_ROOT/ssh.log" "remote_posture=ok"

: >"$TMP_ROOT/verify.log"
: >"$TMP_ROOT/ssh.log"
if PROOF_TAG=v1.8.61 run_apply >/tmp/tier2-enforce-tag-reject.out 2>/tmp/tier2-enforce-tag-reject.err; then
  fail "expected a non-campaign proof tag to be rejected"
fi
assert_contains /tmp/tier2-enforce-tag-reject.err "sealed Pearl coordinator tag v1.8.60"
assert_not_contains "$TMP_ROOT/ssh.log" "remote_posture=ok"

: >"$TMP_ROOT/verify.log"
: >"$TMP_ROOT/ssh.log"
if COORDINATOR_ORIGIN=https://attacker.invalid run_apply >/tmp/tier2-enforce-origin-reject.out 2>/tmp/tier2-enforce-origin-reject.err; then
  fail "expected production apply to reject an overridden origin"
fi
assert_contains /tmp/tier2-enforce-origin-reject.err "COORDINATOR_ORIGIN is pinned"

: >"$TMP_ROOT/verify.log"
: >"$TMP_ROOT/ssh.log"
if REMOTE_UPDATER=/bin/true run_apply >/tmp/tier2-enforce-updater-reject.out 2>/tmp/tier2-enforce-updater-reject.err; then
  fail "expected production apply to reject a substituted updater"
fi
assert_contains /tmp/tier2-enforce-updater-reject.err "REMOTE_UPDATER is pinned"
assert_not_contains "$TMP_ROOT/ssh.log" "remote_posture=ok"

: >"$TMP_ROOT/verify.log"
: >"$TMP_ROOT/ssh.log"
if LOCAL_UPDATER="$TMP_ROOT/substitute-updater" run_apply >/tmp/tier2-enforce-local-updater-reject.out 2>/tmp/tier2-enforce-local-updater-reject.err; then
  fail "expected production apply to reject a substituted local updater digest source"
fi
assert_contains /tmp/tier2-enforce-local-updater-reject.err "LOCAL_UPDATER is pinned"
assert_not_contains "$TMP_ROOT/ssh.log" "remote_posture=ok"

grep -qF 'trap cleanup_active_transaction EXIT HUP INT TERM' \
  "$REPO_ROOT/scripts/enforce-tier2-hash.sh" ||
  fail "controller exit must request immediate rollback while the remote watchdog remains armed"

printf '[tier2-enforce-test] ok\n'
