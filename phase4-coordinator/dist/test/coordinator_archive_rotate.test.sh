#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIST_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROTATE="$DIST_DIR/coordinator-archive-rotate.sh"
RESTORE="$DIST_DIR/coordinator-archive-restore.sh"
TMP="$(umask 077 && mktemp -d -t coordinator-archive-rotate-test.XXXXXXXX)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[ -f "$ROTATE" ] || fail "missing rotate script"
[ -f "$RESTORE" ] || fail "missing restore script"
command -v sqlite3 >/dev/null 2>&1 || { echo "SKIP: sqlite3 not installed" >&2; exit 0; }

DB="$TMP/coordinator.db"
AUDIT_DB="$TMP/coordinator-audit.db"
ARCHIVE_DIR="$TMP/archive"

seed_db() {
  local db="$1"
  sqlite3 "$db" <<'SQL'
PRAGMA foreign_keys=ON;
CREATE TABLE request_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts_utc TEXT NOT NULL,
    request_id TEXT NOT NULL
);
CREATE TABLE audit_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts_utc TEXT NOT NULL,
    event_type TEXT NOT NULL,
    provider_id TEXT NOT NULL,
    payload_json TEXT NOT NULL
);
CREATE TABLE ledger_request_credits (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    request_id TEXT NOT NULL,
    attempt_n INTEGER NOT NULL,
    provider_id TEXT NOT NULL,
    ts_utc TEXT NOT NULL,
    settled INTEGER NOT NULL,
    settlement_id INTEGER NULL,
    created_at_utc TEXT NOT NULL
);
CREATE TABLE settlement_receipt_verdicts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    account_scope_hash TEXT NOT NULL,
    request_id TEXT NOT NULL,
    attempt_n INTEGER NOT NULL,
    provider_id TEXT NOT NULL,
    receipt_present INTEGER NOT NULL,
    receipt_version TEXT NOT NULL,
    receipt_result TEXT NOT NULL,
    settlement_outcome TEXT NOT NULL,
    reason TEXT NOT NULL,
    idempotency_status TEXT NOT NULL,
    closed INTEGER NOT NULL,
    terminal_state TEXT NOT NULL,
    terminal_state_ts_unix_ms INTEGER NOT NULL,
    pending_deadline_unix_ms INTEGER NOT NULL,
    received_at_unix_ms INTEGER NOT NULL,
    created_at_utc TEXT NOT NULL
);
CREATE TABLE settlement_attempt_outputs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    account_scope TEXT NOT NULL,
    request_id TEXT NOT NULL,
    attempt_n INTEGER NOT NULL,
    provider_id TEXT NOT NULL,
    terminal_state TEXT NOT NULL,
    terminal_state_ts_unix_ms INTEGER NOT NULL,
    created_at_utc TEXT NOT NULL
);
CREATE TABLE settlement_route_snapshots (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    account_scope TEXT NOT NULL,
    request_id TEXT NOT NULL,
    attempt_n INTEGER NOT NULL,
    provider_id TEXT NOT NULL,
    created_at_utc TEXT NOT NULL
);
CREATE TABLE settlement_compute_integrity_captures (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    account_scope TEXT NOT NULL,
    request_id TEXT NOT NULL,
    attempt_n INTEGER NOT NULL,
    provider_id TEXT NOT NULL,
    created_at_utc TEXT NOT NULL
);
CREATE TABLE settlement_receipt_audit_outbox (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    settlement_receipt_verdict_id INTEGER NOT NULL REFERENCES settlement_receipt_verdicts(id),
    event_type TEXT NOT NULL,
    created_at_utc TEXT NOT NULL
);

INSERT INTO request_log(ts_utc, request_id) VALUES('2025-01-01T00:00:00Z', 'req-old');
INSERT INTO audit_log(ts_utc, event_type, provider_id, payload_json) VALUES('2025-01-01T00:00:00Z', 'settlement_receipt_verdict', 'provider-1', '{}');
INSERT INTO ledger_request_credits(request_id, attempt_n, provider_id, ts_utc, settled, settlement_id, created_at_utc)
VALUES('req-old', 0, 'provider-1', '2025-01-01T00:00:00Z', 1, 7, '2025-01-01T00:00:00Z');
INSERT INTO settlement_receipt_verdicts(
    account_scope_hash, request_id, attempt_n, provider_id, receipt_present, receipt_version,
    receipt_result, settlement_outcome, reason, idempotency_status, closed, terminal_state,
    terminal_state_ts_unix_ms, pending_deadline_unix_ms, received_at_unix_ms, created_at_utc
) VALUES
('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'req-old', 0, 'provider-1', 1, 'v0.4',
 'valid', 'verified', 'verified_settlement', 'first_terminal', 1, 'normal_done',
 1735689600000, 1735689600000, 1735689600000, '2025-01-01T00:00:00Z'),
('bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', 'req-pending', 0, 'provider-1', 0, 'v0.4',
 'missing', 'pending', 'pending', 'pending', 0, 'normal_done',
 1735689600000, 1735689600000, 1735689600000, '2025-01-01T00:00:00Z');
INSERT INTO settlement_attempt_outputs(account_scope, request_id, attempt_n, provider_id, terminal_state, terminal_state_ts_unix_ms, created_at_utc)
VALUES('acct', 'req-old', 0, 'provider-1', 'normal_done', 1735689600000, '2025-01-01T00:00:00Z');
INSERT INTO settlement_route_snapshots(account_scope, request_id, attempt_n, provider_id, created_at_utc)
VALUES('acct', 'req-old', 0, 'provider-1', '2025-01-01T00:00:00Z');
INSERT INTO settlement_compute_integrity_captures(account_scope, request_id, attempt_n, provider_id, created_at_utc)
VALUES('acct', 'req-old', 0, 'provider-1', '2025-01-01T00:00:00Z');
INSERT INTO settlement_receipt_audit_outbox(settlement_receipt_verdict_id, event_type, created_at_utc)
VALUES(1, 'settlement_receipt_verdict', '2025-01-01T00:00:00Z');
SQL
}

seed_db "$DB"
sqlite3 "$AUDIT_DB" <<'SQL'
CREATE TABLE audit_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts_utc TEXT NOT NULL,
    event_type TEXT NOT NULL,
    provider_id TEXT NOT NULL,
    payload_json TEXT NOT NULL
);
INSERT INTO audit_log(ts_utc, event_type, provider_id, payload_json)
VALUES('2025-01-01T00:00:00Z', 'settlement_receipt_verdict', 'provider-1', '{"sibling":true}');
SQL

DRY_RUN=1 \
  COORDINATOR_DB_PATH="$DB" \
  COORDINATOR_AUDIT_DB_PATH="$AUDIT_DB" \
  COORDINATOR_ARCHIVE_DIR="$ARCHIVE_DIR" \
  COORDINATOR_ARCHIVE_TERMINAL_DAYS=1 \
  "$ROTATE" >"$TMP/dry.out" 2>"$TMP/dry.err"

grep -q "DRY_RUN=1 coordinator.db size=" "$TMP/dry.err" || fail "dry-run size report missing"
grep -q "table=request_log rows=1" "$TMP/dry.err" || fail "request_log count missing"
grep -q "table=audit_log rows=1" "$TMP/dry.err" || fail "audit_log count missing"
grep -q "eligible_terminal_settlement_bundles=1" "$TMP/dry.err" || fail "terminal bundle eligibility missing"
grep -q "eligible_receipt_verdict_rows=1" "$TMP/dry.err" || fail "terminal row eligibility missing"
grep -q "audit_log_rows_older_than_floor=1" "$TMP/dry.err" || fail "audit floor report missing"
grep -q "sibling_audit_db=present" "$TMP/dry.err" || fail "sibling audit DB report missing"
grep -q "no DB changes" "$TMP/dry.err" || fail "dry-run no-change statement missing"

[ "$(sqlite3 "$DB" "SELECT COUNT(*) FROM settlement_receipt_verdicts;")" = "2" ] || fail "dry-run changed settlement verdict rows"
[ "$(sqlite3 "$DB" "SELECT COUNT(*) FROM audit_log;")" = "1" ] || fail "dry-run changed audit_log rows"
if find "$ARCHIVE_DIR" -type f 2>/dev/null | grep -q .; then
  fail "dry-run created archive files"
fi

set +e
DRY_RUN=1 \
  COORDINATOR_DB_PATH="$DB" \
  COORDINATOR_ARCHIVE_AUDIT_DAYS=89 \
  "$ROTATE" >"$TMP/floor.out" 2>"$TMP/floor.err"
floor_rc=$?
set -e
[ "$floor_rc" = "4" ] || fail "audit floor should refuse with exit 4"
grep -q "90-day audit_log floor" "$TMP/floor.err" || fail "audit floor refusal text missing"

printf 'not sqlite' >"$TMP/corrupt.db"
set +e
DRY_RUN=1 \
  COORDINATOR_DB_PATH="$TMP/corrupt.db" \
  "$ROTATE" >"$TMP/corrupt.out" 2>"$TMP/corrupt.err"
corrupt_rc=$?
set -e
[ "$corrupt_rc" = "1" ] || fail "corrupt DB dry-run should fail with exit 1"
grep -q "sqlite query failed" "$TMP/corrupt.err" || fail "corrupt DB failure text missing"

set +e
DRY_RUN=0 \
  COORDINATOR_DB_PATH="$DB" \
  COORDINATOR_ARCHIVE_DIR="$ARCHIVE_DIR" \
  "$ROTATE" >"$TMP/refuse.out" 2>"$TMP/refuse.err"
refuse_rc=$?
set -e
[ "$refuse_rc" = "4" ] || fail "non-dry-run default should refuse with exit 4"
grep -q "non-dry-run mode defaults closed" "$TMP/refuse.err" || fail "default refusal text missing"

set +e
DRY_RUN=0 \
  LIVE_PRUNE=1 \
  FORCE_ROTATE=1 \
  COORDINATOR_ARCHIVE_ASSUME_QUIESCED=1 \
  COORDINATOR_DB_PATH="$DB" \
  COORDINATOR_AUDIT_DB_PATH="$AUDIT_DB" \
  COORDINATOR_ARCHIVE_DIR="$ARCHIVE_DIR" \
  "$ROTATE" >"$TMP/live.out" 2>"$TMP/live.err"
live_rc=$?
set -e
[ "$live_rc" = "4" ] || fail "live prune should refuse with exit 4"
grep -q "live prune is not implemented in Phase 3" "$TMP/live.err" || fail "live prune refusal text missing"
[ "$(sqlite3 "$DB" "SELECT COUNT(*) FROM settlement_receipt_verdicts;")" = "2" ] || fail "live refusal changed DB rows"

DRY_RUN=0 \
  COORDINATOR_ARCHIVE_SNAPSHOT_ONLY=1 \
  FORCE_ROTATE=1 \
  COORDINATOR_ARCHIVE_ASSUME_QUIESCED=1 \
  COORDINATOR_DB_PATH="$DB" \
  COORDINATOR_AUDIT_DB_PATH="$AUDIT_DB" \
  COORDINATOR_ARCHIVE_DIR="$ARCHIVE_DIR" \
  "$ROTATE" >"$TMP/snapshot.out" 2>"$TMP/snapshot.err"

archive_count=$(find "$ARCHIVE_DIR" -type f -name 'coordinator-*.db.gz' | wc -l | tr -d ' ')
[ "$archive_count" = "2" ] || fail "paired snapshot archives not created"
checksum_count=$(find "$ARCHIVE_DIR" -type f -name '*.sha256' | wc -l | tr -d ' ')
[ "$checksum_count" = "2" ] || fail "paired snapshot checksums not created"

archive_path=$(find "$ARCHIVE_DIR" -type f -name 'coordinator-*.db.gz' ! -name 'coordinator-audit-*.db.gz' | head -1)
set +e
ASSUME_YES=1 \
  SKIP_CHECKSUM=1 \
  COORDINATOR_DB_PATH="$DB" \
  COORDINATOR_AUDIT_DB_PATH="$AUDIT_DB" \
  "$RESTORE" --to-live "$archive_path" >"$TMP/restore-live-skip.out" 2>"$TMP/restore-live-skip.err"
skip_live_rc=$?
set -e
[ "$skip_live_rc" = "4" ] || fail "live restore should refuse with exit 4"
grep -q "live restore is not implemented in Phase 3" "$TMP/restore-live-skip.err" || fail "live restore refusal text missing"

set +e
ASSUME_YES=1 \
  COORDINATOR_DB_PATH="$DB" \
  COORDINATOR_AUDIT_DB_PATH="$AUDIT_DB" \
  "$RESTORE" --to-live "$archive_path" >"$TMP/restore-live-paired.out" 2>"$TMP/restore-live-paired.err"
paired_live_rc=$?
set -e
[ "$paired_live_rc" = "4" ] || fail "paired live restore should refuse with exit 4"
grep -q "live restore is not implemented in Phase 3" "$TMP/restore-live-paired.err" || fail "paired live restore refusal text missing"

audit_archive_path=$(find "$ARCHIVE_DIR" -type f -name 'coordinator-audit-*.db.gz' | head -1)
set +e
"$RESTORE" "$audit_archive_path" "$TMP/audit-as-primary.db" >"$TMP/audit-as-primary.out" 2>"$TMP/audit-as-primary.err"
audit_primary_rc=$?
set -e
[ "$audit_primary_rc" = "4" ] || fail "audit archive as primary should refuse with exit 4"
grep -q "audit archive cannot be restored as the primary archive" "$TMP/audit-as-primary.err" || fail "audit archive primary refusal text missing"

RESTORE_DIR="$TMP/restore-target"
mkdir -p "$RESTORE_DIR"
restored="$RESTORE_DIR/restored.db"
"$RESTORE" "$archive_path" "$restored" >"$TMP/restore.out" 2>"$TMP/restore.err"
[ -f "$restored" ] || fail "restore target missing"
[ -f "$RESTORE_DIR/coordinator-audit.db" ] || fail "paired audit restore target missing"
[ "$(sqlite3 "$restored" "PRAGMA integrity_check;")" = "ok" ] || fail "restored DB integrity failed"
[ "$(sqlite3 "$RESTORE_DIR/coordinator-audit.db" "PRAGMA integrity_check;")" = "ok" ] || fail "restored audit DB integrity failed"
[ "$(sqlite3 "$restored" "SELECT COUNT(*) FROM settlement_receipt_verdicts;")" = "2" ] || fail "restored DB missing settlement chain rows"
[ "$(sqlite3 "$RESTORE_DIR/coordinator-audit.db" "SELECT COUNT(*) FROM audit_log WHERE event_type='settlement_receipt_verdict';")" = "1" ] || fail "restored audit DB missing settlement audit rows"

echo "coordinator archive rotate scaffold tests passed"
