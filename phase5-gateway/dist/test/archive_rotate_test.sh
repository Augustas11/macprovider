#!/usr/bin/env bash
# archive_rotate_test.sh — integration tests for archive-rotate.sh and
# archive-restore.sh. Plain-bash assertions (no bats dependency).
#
# Scenarios:
#   T1 — below-threshold no-op (exit 2)
#   T2 — FORCE_ROTATE produces archive + shrinks live DB; old rows gone, recent rows kept
#   T3 — archive is restorable to a forensic target, integrity ok, schema version matches
#   T4 — idempotent re-run: two FORCE_ROTATE passes back-to-back don't corrupt
#   T5 — schema-mismatch detection: archive bumped to higher schema -> exit 6
#   T6 — append-only trigger is restored after prune (DELETE fails post-rotate)
#
# Run from repo root or any cwd: SCRIPT_DIR is derived from $0.
#
# Skips with a noisy message if sqlite3 is unavailable.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIST_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROTATE_SH="$DIST_DIR/archive-rotate.sh"
RESTORE_SH="$DIST_DIR/archive-restore.sh"

[ -x "$ROTATE_SH" ] || { echo "missing $ROTATE_SH" >&2; exit 1; }
[ -x "$RESTORE_SH" ] || { echo "missing $RESTORE_SH" >&2; exit 1; }
command -v sqlite3 >/dev/null 2>&1 || { echo "SKIP: sqlite3 not installed" >&2; exit 0; }

PASS=0
FAIL=0
FAIL_NAMES=()

# ---- helpers ---------------------------------------------------------------

# Make an isolated tmp work area per test so failures don't leak state.
mk_workdir() {
  mktemp -d -t archive-rotate-test.XXXXXX
}

# Seed a minimal gateway-shaped DB with the 8 event tables + triggers + a
# couple of rows in each. Rows are split between "old" (created_at way in the
# past) and "recent" (created_at = now).
seed_db() {
  local db="$1"
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local old="2000-01-01T00:00:00Z"
  sqlite3 "$db" <<EOF
CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL);
INSERT INTO schema_migrations VALUES(1, '$now');

CREATE TABLE usage_events (request_id TEXT PRIMARY KEY, account_id TEXT, demo_identity TEXT DEFAULT '', window_date TEXT, prompt_tokens INTEGER, completion_tokens INTEGER, total_tokens INTEGER, token_source TEXT, outcome TEXT, created_at TEXT);
CREATE TABLE feedback_events (event_id TEXT PRIMARY KEY, request_id TEXT, account_id TEXT, scope TEXT, rating INTEGER, comment TEXT, created_at TEXT);
CREATE TABLE audit_events (event_id TEXT PRIMARY KEY, request_id TEXT, account_id TEXT DEFAULT '', actor TEXT, event_type TEXT, payload_json TEXT, created_at TEXT);
CREATE TABLE api_key_events (event_id INTEGER PRIMARY KEY AUTOINCREMENT, key_id TEXT, account_id TEXT, request_id TEXT, event_type TEXT, actor TEXT, created_at TEXT);
CREATE TABLE demo_usage_events (request_id TEXT PRIMARY KEY, client_ip TEXT, demo_token_hash TEXT, window_date TEXT, total_tokens INTEGER, created_at TEXT);
CREATE TABLE capacity_signal_events (event_id TEXT PRIMARY KEY, signal TEXT, value REAL, threshold REAL, firing INTEGER, created_at TEXT);
CREATE TABLE signup_events (event_id TEXT PRIMARY KEY, account_id TEXT, client_ip TEXT, provider TEXT, created_at TEXT);
CREATE TABLE demo_session_events (event_id TEXT PRIMARY KEY, client_ip TEXT, created_at TEXT);
CREATE TABLE concurrency_reservations (account_id TEXT, request_id TEXT, status TEXT, expires_at TEXT, created_at TEXT, released_at TEXT DEFAULT '', PRIMARY KEY (account_id, request_id));

CREATE TRIGGER usage_events_no_delete BEFORE DELETE ON usage_events BEGIN SELECT RAISE(ABORT, 'usage_events are append-only'); END;
CREATE TRIGGER feedback_events_no_delete BEFORE DELETE ON feedback_events BEGIN SELECT RAISE(ABORT, 'feedback_events are append-only'); END;
CREATE TRIGGER audit_events_no_delete BEFORE DELETE ON audit_events BEGIN SELECT RAISE(ABORT, 'audit_events are append-only'); END;
CREATE TRIGGER api_key_events_no_delete BEFORE DELETE ON api_key_events BEGIN SELECT RAISE(ABORT, 'api_key_events are append-only'); END;
CREATE TRIGGER demo_usage_events_no_delete BEFORE DELETE ON demo_usage_events BEGIN SELECT RAISE(ABORT, 'demo_usage_events are append-only'); END;
CREATE TRIGGER capacity_signal_events_no_delete BEFORE DELETE ON capacity_signal_events BEGIN SELECT RAISE(ABORT, 'capacity_signal_events are append-only'); END;
CREATE TRIGGER signup_events_no_delete BEFORE DELETE ON signup_events BEGIN SELECT RAISE(ABORT, 'signup_events are append-only'); END;
CREATE TRIGGER demo_session_events_no_delete BEFORE DELETE ON demo_session_events BEGIN SELECT RAISE(ABORT, 'demo_session_events are append-only'); END;
CREATE TRIGGER concurrency_reservations_no_delete BEFORE DELETE ON concurrency_reservations BEGIN SELECT RAISE(ABORT, 'concurrency_reservations cannot be deleted'); END;

-- Old rows (will be pruned).
INSERT INTO usage_events VALUES('old-u-1', 'acct-1', '', '2000-01-01', 10, 20, 30, 'provider_reported', 'ok', '$old');
INSERT INTO feedback_events VALUES('old-f-1', 'old-u-1', 'acct-1', 'response', 4, '', '$old');
INSERT INTO audit_events VALUES('old-a-1', 'old-u-1', 'acct-1', 'gateway', 'admit', '{}', '$old');
INSERT INTO api_key_events(key_id, account_id, request_id, event_type, actor, created_at) VALUES('k1','acct-1','old-u-1','create','admin','$old');
INSERT INTO demo_usage_events VALUES('old-d-1', '1.1.1.1', 'dhash', '2000-01-01', 50, '$old');
INSERT INTO capacity_signal_events VALUES('old-c-1', 'queue_depth', 1.0, 5.0, 0, '$old');
INSERT INTO signup_events VALUES('old-s-1', 'acct-1', '1.1.1.1', 'github', '$old');
INSERT INTO demo_session_events VALUES('old-ds-1', '1.1.1.1', '$old');
INSERT INTO concurrency_reservations VALUES('acct-1', 'old-cr-1', 'released', '$old', '$old', '$old');

-- Recent rows (must survive prune).
INSERT INTO usage_events VALUES('new-u-1', 'acct-1', '', '2026-06-12', 10, 20, 30, 'provider_reported', 'ok', '$now');
INSERT INTO feedback_events VALUES('new-f-1', 'new-u-1', 'acct-1', 'response', 4, '', '$now');
INSERT INTO audit_events VALUES('new-a-1', 'new-u-1', 'acct-1', 'gateway', 'admit', '{}', '$now');
INSERT INTO api_key_events(key_id, account_id, request_id, event_type, actor, created_at) VALUES('k1','acct-1','new-u-1','create','admin','$now');
INSERT INTO demo_usage_events VALUES('new-d-1', '1.1.1.1', 'dhash', '2026-06-12', 50, '$now');
INSERT INTO capacity_signal_events VALUES('new-c-1', 'queue_depth', 1.0, 5.0, 0, '$now');
INSERT INTO signup_events VALUES('new-s-1', 'acct-1', '1.1.1.1', 'github', '$now');
INSERT INTO demo_session_events VALUES('new-ds-1', '1.1.1.1', '$now');
INSERT INTO concurrency_reservations VALUES('acct-1', 'new-cr-1', 'active', '$now', '$now', '');
EOF
}

run_rotate() {
  # Run the rotate script in test-mode env. Two opt-outs are required vs prod:
  #   - GATEWAY_ARCHIVE_ALLOW_NO_SYSTEMCTL=1: there is no real systemd unit in
  #     the test env, so allow the script to skip its fail-closed quiesce gate.
  #   - GATEWAY_ARCHIVE_REQUIRE_REMOTE=0: no S3 in the test env.
  local db="$1"
  local archive_dir="$2"
  shift; shift
  GATEWAY_DB_PATH="$db" \
    GATEWAY_ARCHIVE_DIR="$archive_dir" \
    GATEWAY_SERVICE_NAME="nonexistent-archive-rotate-test-service" \
    GATEWAY_ARCHIVE_PRUNE_DAYS=7 \
    GATEWAY_ARCHIVE_ALLOW_NO_SYSTEMCTL=1 \
    GATEWAY_ARCHIVE_REQUIRE_REMOTE=0 \
    "$@" \
    bash "$ROTATE_SH"
}

assert_eq() {
  local got="$1" want="$2" msg="$3"
  if [ "$got" != "$want" ]; then
    echo "  FAIL: $msg (got='$got' want='$want')"
    return 1
  fi
  echo "  ok:   $msg"
  return 0
}

assert_neq() {
  local got="$1" want="$2" msg="$3"
  if [ "$got" = "$want" ]; then
    echo "  FAIL: $msg (got='$got' equals forbidden value)"
    return 1
  fi
  echo "  ok:   $msg"
  return 0
}

record_result() {
  local test_name="$1" ok="$2"
  if [ "$ok" = "1" ]; then
    PASS=$(( PASS + 1 ))
    echo "PASS: $test_name"
  else
    FAIL=$(( FAIL + 1 ))
    FAIL_NAMES+=("$test_name")
    echo "FAIL: $test_name"
  fi
  echo
}

# ---- T1: below-threshold no-op ---------------------------------------------

test_below_threshold_noop() {
  echo "==> T1: below-threshold no-op"
  local w; w=$(mk_workdir)
  local db="$w/gateway.db"
  seed_db "$db"

  set +e
  GATEWAY_ARCHIVE_SIZE_BYTES=1000000000000 \
    GATEWAY_ARCHIVE_AGE_DAYS=10000 \
    run_rotate "$db" "$w/archive" 2>"$w/stderr"
  local rc=$?
  set -e

  local ok=1
  assert_eq "$rc" "2" "exit code 2 (below threshold)" || ok=0
  # Archive directory should not contain any *.zst/*.gz files.
  if find "$w/archive" -type f \( -name '*.zst' -o -name '*.gz' \) 2>/dev/null | grep -q .; then
    echo "  FAIL: archive directory should be empty"
    ok=0
  else
    echo "  ok:   archive directory empty"
  fi

  rm -rf "$w"
  record_result "T1_below_threshold_noop" "$ok"
}

# ---- T2: FORCE_ROTATE shrinks live DB, keeps recent rows -------------------

test_force_rotate_prunes_old() {
  echo "==> T2: FORCE_ROTATE archives + prunes old rows; recent rows survive"
  local w; w=$(mk_workdir)
  local db="$w/gateway.db"
  seed_db "$db"

  set +e
  FORCE_ROTATE=1 run_rotate "$db" "$w/archive" 2>"$w/stderr"
  local rc=$?
  set -e

  local ok=1
  assert_eq "$rc" "0" "rotate exit 0" || { ok=0; cat "$w/stderr"; }

  # Archive must exist + checksum sidecar must exist.
  local archive_count
  archive_count=$(find "$w/archive" -type f \( -name 'gateway-*.zst' -o -name 'gateway-*.gz' \) | wc -l | tr -d ' ')
  assert_eq "$archive_count" "1" "exactly one archive file produced" || ok=0
  local checksum_count
  checksum_count=$(find "$w/archive" -type f -name '*.sha256' | wc -l | tr -d ' ')
  assert_eq "$checksum_count" "1" "exactly one .sha256 file produced" || ok=0

  # Live DB: old rows dropped, recent rows kept.
  local old_count new_count
  old_count=$(sqlite3 "$db" "SELECT COUNT(*) FROM usage_events WHERE request_id='old-u-1';")
  new_count=$(sqlite3 "$db" "SELECT COUNT(*) FROM usage_events WHERE request_id='new-u-1';")
  assert_eq "$old_count" "0" "old usage_events row pruned from live" || ok=0
  assert_eq "$new_count" "1" "recent usage_events row preserved in live" || ok=0

  # Spot-check one more event table for prune correctness.
  old_count=$(sqlite3 "$db" "SELECT COUNT(*) FROM audit_events WHERE event_id='old-a-1';")
  new_count=$(sqlite3 "$db" "SELECT COUNT(*) FROM audit_events WHERE event_id='new-a-1';")
  assert_eq "$old_count" "0" "old audit_events row pruned from live" || ok=0
  assert_eq "$new_count" "1" "recent audit_events row preserved in live" || ok=0

  # concurrency_reservations: old NON-active rows ARE pruned per audit
  # iteration 1 architect feedback (PERF-1 covers all 9 tables). Active rows
  # are NEVER pruned regardless of age. Seeded: old-cr-1 status=released,
  # new-cr-1 status=active.
  local cr_old cr_new
  cr_old=$(sqlite3 "$db" "SELECT COUNT(*) FROM concurrency_reservations WHERE request_id='old-cr-1';")
  cr_new=$(sqlite3 "$db" "SELECT COUNT(*) FROM concurrency_reservations WHERE request_id='new-cr-1';")
  assert_eq "$cr_old" "0" "concurrency_reservations: old non-active row pruned" || ok=0
  assert_eq "$cr_new" "1" "concurrency_reservations: recent active row preserved" || ok=0

  rm -rf "$w"
  record_result "T2_force_rotate_prunes_old" "$ok"
}

# ---- T3: restore archive to forensic target --------------------------------

test_restore_forensic() {
  echo "==> T3: restore archive to forensic target, integrity ok"
  local w; w=$(mk_workdir)
  local db="$w/gateway.db"
  seed_db "$db"

  FORCE_ROTATE=1 run_rotate "$db" "$w/archive" 2>"$w/rotate.stderr" || { cat "$w/rotate.stderr"; rm -rf "$w"; record_result "T3_restore_forensic" "0"; return; }

  local archive_path
  archive_path=$(find "$w/archive" -type f \( -name 'gateway-*.zst' -o -name 'gateway-*.gz' \) | head -1)
  local ok=1

  local restored="$w/restored.db"
  set +e
  bash "$RESTORE_SH" "$archive_path" "$restored" 2>"$w/restore.stderr"
  local rc=$?
  set -e
  assert_eq "$rc" "0" "restore exit 0" || { ok=0; cat "$w/restore.stderr"; }
  [ -f "$restored" ] && echo "  ok:   restored target exists" || { ok=0; echo "  FAIL: restored target missing"; }

  # Restored DB should contain BOTH the old and the new rows (the snapshot
  # was taken BEFORE the live prune ran).
  local archived_old archived_new
  archived_old=$(sqlite3 "$restored" "SELECT COUNT(*) FROM usage_events WHERE request_id='old-u-1';")
  archived_new=$(sqlite3 "$restored" "SELECT COUNT(*) FROM usage_events WHERE request_id='new-u-1';")
  assert_eq "$archived_old" "1" "archive preserves old usage_events row" || ok=0
  assert_eq "$archived_new" "1" "archive preserves recent usage_events row" || ok=0

  # Integrity check.
  local integ
  integ=$(sqlite3 "$restored" "PRAGMA integrity_check;")
  assert_eq "$integ" "ok" "restored DB integrity ok" || ok=0

  rm -rf "$w"
  record_result "T3_restore_forensic" "$ok"
}

# ---- T4: idempotent re-run -------------------------------------------------

test_idempotent_rerun() {
  echo "==> T4: two FORCE_ROTATE passes back-to-back don't corrupt"
  local w; w=$(mk_workdir)
  local db="$w/gateway.db"
  seed_db "$db"

  FORCE_ROTATE=1 run_rotate "$db" "$w/archive" 2>"$w/r1.stderr" || { cat "$w/r1.stderr"; rm -rf "$w"; record_result "T4_idempotent_rerun" "0"; return; }
  # Sleep 1 second so the second pass gets a distinct UTC second in its
  # archive filename (the script uses YYYYMMDDTHHMMSSZ); without this the
  # second VACUUM INTO would refuse to overwrite the existing snapshot.
  sleep 1
  FORCE_ROTATE=1 run_rotate "$db" "$w/archive" 2>"$w/r2.stderr" || { cat "$w/r2.stderr"; rm -rf "$w"; record_result "T4_idempotent_rerun" "0"; return; }

  local ok=1
  # Two archives present.
  local archive_count
  archive_count=$(find "$w/archive" -type f \( -name 'gateway-*.zst' -o -name 'gateway-*.gz' \) | wc -l | tr -d ' ')
  assert_eq "$archive_count" "2" "two archive files after two passes" || ok=0
  # Live DB still has the recent rows.
  local nu
  nu=$(sqlite3 "$db" "SELECT COUNT(*) FROM usage_events WHERE request_id='new-u-1';")
  assert_eq "$nu" "1" "recent usage_events row still present" || ok=0
  # Integrity.
  local integ
  integ=$(sqlite3 "$db" "PRAGMA integrity_check;")
  assert_eq "$integ" "ok" "live DB integrity ok after two passes" || ok=0

  rm -rf "$w"
  record_result "T4_idempotent_rerun" "$ok"
}

# ---- T5: schema-mismatch on restore ----------------------------------------

test_schema_mismatch_refused() {
  echo "==> T5: archive with future schema version refused on restore"
  local w; w=$(mk_workdir)
  local db="$w/gateway.db"
  seed_db "$db"
  # Forge an archive-equivalent DB with schema_migrations bumped beyond
  # expected version (which is 1 in the restore script).
  sqlite3 "$db" "INSERT INTO schema_migrations VALUES (9999, '2099-01-01T00:00:00Z');"

  FORCE_ROTATE=1 run_rotate "$db" "$w/archive" 2>"$w/r.stderr" || { cat "$w/r.stderr"; rm -rf "$w"; record_result "T5_schema_mismatch_refused" "0"; return; }
  local archive_path
  archive_path=$(find "$w/archive" -type f \( -name 'gateway-*.zst' -o -name 'gateway-*.gz' \) | head -1)

  local ok=1
  set +e
  bash "$RESTORE_SH" "$archive_path" "$w/restored.db" 2>"$w/restore.stderr"
  local rc=$?
  set -e
  assert_eq "$rc" "6" "restore refuses with exit 6 (future schema)" || { ok=0; cat "$w/restore.stderr"; }

  rm -rf "$w"
  record_result "T5_schema_mismatch_refused" "$ok"
}

# ---- T6: append-only invariant survives prune ------------------------------

test_append_only_invariant_restored() {
  echo "==> T6: append-only trigger present after prune"
  local w; w=$(mk_workdir)
  local db="$w/gateway.db"
  seed_db "$db"
  FORCE_ROTATE=1 run_rotate "$db" "$w/archive" 2>"$w/r.stderr" || { cat "$w/r.stderr"; rm -rf "$w"; record_result "T6_append_only_invariant_restored" "0"; return; }

  local ok=1
  # Attempt to delete a recent row; trigger should ABORT.
  local err
  err=$(sqlite3 "$db" "DELETE FROM usage_events WHERE request_id='new-u-1';" 2>&1 || true)
  if echo "$err" | grep -q "append-only"; then
    echo "  ok:   usage_events_no_delete trigger refuses post-rotate DELETE"
  else
    echo "  FAIL: trigger did not fire (sqlite output: $err)"
    ok=0
  fi
  # Verify trigger row count: 8 event tables + concurrency_reservations = 9.
  local trigger_count
  trigger_count=$(sqlite3 "$db" "SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND name LIKE '%_no_delete';")
  assert_eq "$trigger_count" "9" "all 9 no-delete triggers present (8 events + concurrency_reservations)" || ok=0
  # And explicitly check concurrency_reservations rejects DELETE on its
  # remaining active row.
  err=$(sqlite3 "$db" "DELETE FROM concurrency_reservations WHERE request_id='new-cr-1';" 2>&1 || true)
  if echo "$err" | grep -q "cannot be deleted"; then
    echo "  ok:   concurrency_reservations_no_delete trigger refuses post-rotate DELETE"
  else
    echo "  FAIL: concurrency trigger did not fire (sqlite output: $err)"
    ok=0
  fi

  rm -rf "$w"
  record_result "T6_append_only_invariant_restored" "$ok"
}

# ---- T7: fail-closed quiesce when systemd unit missing ---------------------

test_fail_closed_quiesce() {
  echo "==> T7: fail-closed when systemd unit missing (no ALLOW_NO_SYSTEMCTL)"
  local w; w=$(mk_workdir)
  local db="$w/gateway.db"
  seed_db "$db"

  # Run WITHOUT GATEWAY_ARCHIVE_ALLOW_NO_SYSTEMCTL=1 — the script should
  # refuse to prune because the named service is not registered.
  set +e
  GATEWAY_DB_PATH="$db" \
    GATEWAY_ARCHIVE_DIR="$w/archive" \
    GATEWAY_SERVICE_NAME="definitely-not-a-real-service-xyz" \
    GATEWAY_ARCHIVE_PRUNE_DAYS=7 \
    GATEWAY_ARCHIVE_REQUIRE_REMOTE=0 \
    FORCE_ROTATE=1 \
    bash "$ROTATE_SH" 2>"$w/r.stderr"
  local rc=$?
  set -e

  local ok=1
  assert_eq "$rc" "4" "rotate refuses with exit 4 (fail-closed quiesce)" || { ok=0; cat "$w/r.stderr"; }

  rm -rf "$w"
  record_result "T7_fail_closed_quiesce" "$ok"
}

# ---- T8: require-remote without S3 -> exit 4 -------------------------------

test_require_remote_without_s3() {
  echo "==> T8: GATEWAY_ARCHIVE_REQUIRE_REMOTE=1 without GATEWAY_ARCHIVE_S3_BUCKET -> exit 4"
  local w; w=$(mk_workdir)
  local db="$w/gateway.db"
  seed_db "$db"

  set +e
  GATEWAY_DB_PATH="$db" \
    GATEWAY_ARCHIVE_DIR="$w/archive" \
    GATEWAY_SERVICE_NAME="nonexistent-archive-rotate-test-service" \
    GATEWAY_ARCHIVE_PRUNE_DAYS=7 \
    GATEWAY_ARCHIVE_ALLOW_NO_SYSTEMCTL=1 \
    GATEWAY_ARCHIVE_REQUIRE_REMOTE=1 \
    FORCE_ROTATE=1 \
    bash "$ROTATE_SH" 2>"$w/r.stderr"
  local rc=$?
  set -e

  local ok=1
  assert_eq "$rc" "4" "rotate refuses with exit 4 (require-remote pre-flight)" || { ok=0; cat "$w/r.stderr"; }
  # Live DB must NOT be touched on pre-flight failure.
  local n
  n=$(sqlite3 "$db" "SELECT COUNT(*) FROM usage_events WHERE request_id='old-u-1';")
  assert_eq "$n" "1" "live DB old row preserved (no prune on pre-flight fail)" || ok=0

  rm -rf "$w"
  record_result "T8_require_remote_without_s3" "$ok"
}

# ---- run -------------------------------------------------------------------

echo "== archive-rotate.sh integration tests =="
echo "rotate:  $ROTATE_SH"
echo "restore: $RESTORE_SH"
echo

test_below_threshold_noop
test_force_rotate_prunes_old
test_restore_forensic
test_idempotent_rerun
test_schema_mismatch_refused
test_append_only_invariant_restored
test_fail_closed_quiesce
test_require_remote_without_s3

echo
echo "== summary =="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "failed tests:"
  for n in "${FAIL_NAMES[@]}"; do echo "  - $n"; done
  exit 1
fi
exit 0
