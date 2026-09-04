#!/usr/bin/env bash
# coordinator-archive-rotate.sh — coordinator.db archive-rotate scaffold (#1226).
#
# Manual ops capacity ceiling for the 1-writer money DB: dry-run-first sizing
# and snapshot scaffolding only (VACUUM INTO + gzip + sha256). Same fail-closed
# shape as gateway archive-rotate, without live row DELETE. It reports
# coordinator hot table counts and candidate terminal settlement bundles, but
# refuses live prune by default.
# Do not weaken settlement/audit compliance here:
#   - settlement chains are never age-only deleted;
#   - audit_log is never considered below the existing 90-day floor;
#   - live prune requires a later, reviewed delete plan.
#
# Environment:
#   COORDINATOR_DB_PATH                  default: /var/lib/macprovider/coordinator.db
#   COORDINATOR_AUDIT_DB_PATH            default: sibling coordinator-audit.db
#   COORDINATOR_ARCHIVE_DIR             default: /var/lib/macprovider-coordinator-archive
#   COORDINATOR_ARCHIVE_TERMINAL_DAYS   default: 180
#   COORDINATOR_ARCHIVE_AUDIT_DAYS      default: 90; values below 90 are refused
#   COORDINATOR_ARCHIVE_SNAPSHOT_ONLY   default: 0; set 1 to take a verified archive
#   COORDINATOR_ARCHIVE_ASSUME_QUIESCED default: 0; required for snapshot/live paths
#   FORCE_ROTATE                        default: 0; required for snapshot/live paths
#   LIVE_PRUNE                          default: 0; live prune still refuses in Phase 3
#   DRY_RUN                             default: 1; report only, no state changes
#
# Exit codes:
#   0  dry-run report or snapshot success
#   1  generic error
#   2  usage / malformed environment
#   4  live/snapshot safety gate refused

set -euo pipefail

COORDINATOR_DB_PATH="${COORDINATOR_DB_PATH:-/var/lib/macprovider/coordinator.db}"
COORDINATOR_AUDIT_DB_PATH="${COORDINATOR_AUDIT_DB_PATH:-}"
COORDINATOR_ARCHIVE_DIR="${COORDINATOR_ARCHIVE_DIR:-/var/lib/macprovider-coordinator-archive}"
COORDINATOR_ARCHIVE_TERMINAL_DAYS="${COORDINATOR_ARCHIVE_TERMINAL_DAYS:-180}"
COORDINATOR_ARCHIVE_AUDIT_DAYS="${COORDINATOR_ARCHIVE_AUDIT_DAYS:-90}"
COORDINATOR_ARCHIVE_SNAPSHOT_ONLY="${COORDINATOR_ARCHIVE_SNAPSHOT_ONLY:-0}"
COORDINATOR_ARCHIVE_ASSUME_QUIESCED="${COORDINATOR_ARCHIVE_ASSUME_QUIESCED:-0}"
FORCE_ROTATE="${FORCE_ROTATE:-0}"
LIVE_PRUNE="${LIVE_PRUNE:-0}"
DRY_RUN="${DRY_RUN:-1}"

log() { printf '[coordinator-archive-rotate] %s\n' "$*" >&2; }
fail() { log "ERROR: $*"; exit 1; }
refuse() { log "REFUSING: $*"; exit 4; }

need_tool() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required tool: $1"
}

need_tool sqlite3
need_tool stat
need_tool date
need_tool awk
need_tool gzip

if command -v sha256sum >/dev/null 2>&1; then
  CHECKSUM_CMD="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
  CHECKSUM_CMD="shasum -a 256"
else
  fail "neither sha256sum nor shasum found"
fi
SQLITE_ERROR_FILE=$(mktemp -t coordinator-archive-sqlite-error.XXXXXX)
rm -f "$SQLITE_ERROR_FILE"
cleanup_sqlite_error_file() { rm -f "$SQLITE_ERROR_FILE"; }
trap cleanup_sqlite_error_file EXIT

for v in COORDINATOR_ARCHIVE_TERMINAL_DAYS COORDINATOR_ARCHIVE_AUDIT_DAYS; do
  case "${!v}" in
    ''|*[!0-9]*) log "ERROR: $v must be a non-negative integer"; exit 2 ;;
  esac
done

case "$COORDINATOR_DB_PATH" in
  *$'\n'*|*'$'*|*'`'*|*';'*|*'&'*|*'|'*|*'>'*|*'<'*|*'*'*|*'?'*) log "ERROR: unsafe coordinator DB path"; exit 2 ;;
esac
if [ -z "$COORDINATOR_AUDIT_DB_PATH" ]; then
  coordinator_db_dir=$(dirname "$COORDINATOR_DB_PATH")
  if [ "$coordinator_db_dir" = "." ] || [ -z "$coordinator_db_dir" ]; then
    COORDINATOR_AUDIT_DB_PATH="coordinator-audit.db"
  else
    COORDINATOR_AUDIT_DB_PATH="$coordinator_db_dir/coordinator-audit.db"
  fi
fi
case "$COORDINATOR_AUDIT_DB_PATH" in
  *$'\n'*|*'$'*|*'`'*|*';'*|*'&'*|*'|'*|*'>'*|*'<'*|*'*'*|*'?'*) log "ERROR: unsafe coordinator audit DB path"; exit 2 ;;
esac
case "$COORDINATOR_ARCHIVE_DIR" in
  *$'\n'*|*'$'*|*'`'*|*';'*|*'&'*|*'|'*|*'>'*|*'<'*|*'*'*|*'?'*) log "ERROR: unsafe archive directory path"; exit 2 ;;
esac

[ -f "$COORDINATOR_DB_PATH" ] || fail "coordinator SQLite DB not found"

if [ "$COORDINATOR_ARCHIVE_AUDIT_DAYS" -lt 90 ]; then
  refuse "COORDINATOR_ARCHIVE_AUDIT_DAYS cannot be below the 90-day audit_log floor"
fi
if [ "$LIVE_PRUNE" = "1" ]; then
  refuse "live prune is not implemented in Phase 3; use DRY_RUN=1 or COORDINATOR_ARCHIVE_SNAPSHOT_ONLY=1"
fi

stat_size() {
  if stat -c %s "$1" >/dev/null 2>&1; then
    stat -c %s "$1"
  else
    stat -f %z "$1"
  fi
}

utc_ts() { date -u +%Y%m%dT%H%M%SZ; }
now_epoch() { date -u +%s; }

sqlite_scalar() {
  local sql="$1"
  local out
  if ! out=$(sqlite3 -batch -noheader "$COORDINATOR_DB_PATH" "$sql" 2>&1); then
    log "ERROR: sqlite query failed for coordinator DB: $out"
    : >"$SQLITE_ERROR_FILE"
    printf '0\n'
    return 0
  fi
  printf '%s\n' "$out"
}

sqlite_scalar_db() {
  local db_path="$1"
  local sql="$2"
  local out
  if ! out=$(sqlite3 -batch -noheader "$db_path" "$sql" 2>&1); then
    log "ERROR: sqlite query failed for $db_path: $out"
    : >"$SQLITE_ERROR_FILE"
    printf '0\n'
    return 0
  fi
  printf '%s\n' "$out"
}

abort_on_sqlite_error() {
  [ ! -f "$SQLITE_ERROR_FILE" ] || fail "one or more SQLite reads failed; refusing to continue with partial archive sizing"
}

table_exists() {
  local table="$1"
  local n
  n=$(sqlite_scalar "SELECT COUNT(*) FROM sqlite_schema WHERE type='table' AND name='$table';")
  [ "$n" = "1" ]
}

table_exists_db() {
  local db_path="$1"
  local table="$2"
  local n
  n=$(sqlite_scalar_db "$db_path" "SELECT COUNT(*) FROM sqlite_schema WHERE type='table' AND name='$table';")
  [ "$n" = "1" ]
}

table_count() {
  local table="$1"
  if table_exists "$table"; then
    sqlite_scalar "SELECT COUNT(*) FROM $table;"
  else
    printf '0\n'
  fi
}

dbstat_bytes() {
  local table="$1"
  if ! table_exists "$table"; then
    printf '0\n'
    return 0
  fi
  sqlite_scalar "SELECT COALESCE(SUM(pgsize), 0) FROM dbstat WHERE name='$table';"
}

report_table() {
  local table="$1"
  local rows bytes
  rows=$(table_count "$table")
  abort_on_sqlite_error
  bytes=$(dbstat_bytes "$table")
  abort_on_sqlite_error
  log "table=$table rows=$rows approx_bytes=$bytes"
}

report_audit_sibling() {
  if [ ! -f "$COORDINATOR_AUDIT_DB_PATH" ]; then
    log "sibling_audit_db=absent"
    return 0
  fi
  local size rows
  size=$(stat_size "$COORDINATOR_AUDIT_DB_PATH")
  if table_exists_db "$COORDINATOR_AUDIT_DB_PATH" "audit_log"; then
    rows=$(sqlite_scalar_db "$COORDINATOR_AUDIT_DB_PATH" "SELECT COUNT(*) FROM audit_log;")
    abort_on_sqlite_error
  else
    abort_on_sqlite_error
    rows=0
  fi
  log "sibling_audit_db=present size=${size}B audit_log_rows=$rows"
}

terminal_cutoff_ms() {
  local cutoff_epoch
  cutoff_epoch=$(( $(now_epoch) - COORDINATOR_ARCHIVE_TERMINAL_DAYS * 86400 ))
  printf '%s000\n' "$cutoff_epoch"
}

audit_cutoff_text() {
  local cutoff_epoch
  cutoff_epoch=$(( $(now_epoch) - COORDINATOR_ARCHIVE_AUDIT_DAYS * 86400 ))
  date -u -r "$cutoff_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$cutoff_epoch" +%Y-%m-%dT%H:%M:%SZ
}

settlement_terminal_where() {
  local cutoff_ms="$1"
  cat <<SQL
closed = 1
AND settlement_outcome IN ('verified','quarantined','zero_settled')
AND idempotency_status IN ('first_terminal','terminal_after_pending','terminal_noop')
AND received_at_unix_ms < $cutoff_ms
SQL
}

candidate_terminal_bundle_count() {
  if ! table_exists "settlement_receipt_verdicts"; then
    printf '0\n'
    return 0
  fi
  local cutoff_ms where
  cutoff_ms=$(terminal_cutoff_ms)
  where=$(settlement_terminal_where "$cutoff_ms")
  sqlite_scalar "SELECT COUNT(*) FROM (SELECT account_scope_hash, request_id, attempt_n, provider_id FROM settlement_receipt_verdicts WHERE $where GROUP BY account_scope_hash, request_id, attempt_n, provider_id);"
}

candidate_terminal_row_count() {
  if ! table_exists "settlement_receipt_verdicts"; then
    printf '0\n'
    return 0
  fi
  local cutoff_ms where
  cutoff_ms=$(terminal_cutoff_ms)
  where=$(settlement_terminal_where "$cutoff_ms")
  sqlite_scalar "SELECT COUNT(*) FROM settlement_receipt_verdicts WHERE $where;"
}

audit_floor_row_count() {
  if ! table_exists "audit_log"; then
    printf '0\n'
    return 0
  fi
  local cutoff
  cutoff=$(audit_cutoff_text)
  sqlite_scalar "SELECT COUNT(*) FROM audit_log WHERE julianday(ts_utc) < julianday('$cutoff');"
}

predicted_reclaim_bytes() {
  local candidates total bytes
  candidates=$(candidate_terminal_row_count)
  total=$(table_count "settlement_receipt_verdicts")
  bytes=$(dbstat_bytes "settlement_receipt_verdicts")
  if [ "$total" -le 0 ] || [ "$bytes" -le 0 ]; then
    printf '0\n'
    return 0
  fi
  awk -v e="$candidates" -v t="$total" -v b="$bytes" 'BEGIN { printf "%.0f\n", (e / t) * b }'
}

run_dry_report() {
  local size bundles rows reclaim audit_rows
  size=$(stat_size "$COORDINATOR_DB_PATH")
  log "DRY_RUN=1 coordinator.db size=${size}B"
  log "candidate terminal settlement bundle reporting requires closed terminal receipt verdicts older than ${COORDINATOR_ARCHIVE_TERMINAL_DAYS}d"
  log "audit_log reporting floor=${COORDINATOR_ARCHIVE_AUDIT_DAYS}d (minimum 90d)"

  for table in \
    request_log audit_log \
    ledger_request_credits ledger_provider_earnings ledger_operator_credits ledger_payout_ready \
    ledger_provider_identity_snapshots ledger_config_audit_events ledger_quarantine_resolutions \
    settlement_route_snapshots settlement_compute_integrity_captures settlement_attempt_outputs \
    settlement_receipt_verdicts settlement_receipt_audit_outbox; do
    report_table "$table"
  done
  report_audit_sibling

  bundles=$(candidate_terminal_bundle_count)
  abort_on_sqlite_error
  rows=$(candidate_terminal_row_count)
  abort_on_sqlite_error
  reclaim=$(predicted_reclaim_bytes)
  abort_on_sqlite_error
  audit_rows=$(audit_floor_row_count)
  abort_on_sqlite_error
  log "candidate_terminal_settlement_bundles=$bundles candidate_receipt_verdict_rows=$rows predicted_reclaim_bytes_approx=$reclaim"
  log "audit_log_rows_older_than_floor=$audit_rows (reported only; this script does not delete audit_log)"
  log "DRY_RUN complete: no DB changes, no snapshots, no deletes, no VACUUM"
}

refuse_existing_archive() {
  local stem="$1"
  local ts="$2"
  local snapshot archive checksum
  snapshot="$COORDINATOR_ARCHIVE_DIR/${stem}-${ts}.db"
  archive="${snapshot}.gz"
  checksum="${archive}.sha256"
  if [ -e "$snapshot" ] || [ -e "$archive" ] || [ -e "$checksum" ]; then
    fail "$stem archive already exists; refusing overwrite of $archive"
  fi
}

snapshot_one() {
  local db_path="$1"
  local stem="$2"
  local ts="$3"
  local snapshot archive checksum esc_snapshot integrity fk
  snapshot="$COORDINATOR_ARCHIVE_DIR/${stem}-${ts}.db"
  archive="${snapshot}.gz"
  checksum="${archive}.sha256"
  esc_snapshot="${snapshot//\'/\'\'}"
  refuse_existing_archive "$stem" "$ts"

  log "pre-snapshot integrity_check db=$stem"
  integrity=$(sqlite3 "$db_path" "PRAGMA integrity_check;" || echo "fail")
  [ "$integrity" = "ok" ] || fail "$stem integrity_check failed before snapshot"
  fk=$(sqlite3 "$db_path" "PRAGMA foreign_key_check;" || echo "fail")
  [ -z "$fk" ] || fail "$stem foreign_key_check failed before snapshot"

  log "snapshot via sqlite3 VACUUM INTO db=$stem"
  sqlite3 "$db_path" "VACUUM INTO '$esc_snapshot';" || fail "$stem VACUUM INTO failed"
  chmod 0600 "$snapshot"

  log "snapshot integrity_check db=$stem"
  integrity=$(sqlite3 "$snapshot" "PRAGMA integrity_check;" || echo "fail")
  [ "$integrity" = "ok" ] || fail "$stem snapshot integrity_check failed"
  fk=$(sqlite3 "$snapshot" "PRAGMA foreign_key_check;" || echo "fail")
  [ -z "$fk" ] || fail "$stem snapshot foreign_key_check failed"

  gzip -9 <"$snapshot" >"$archive" || fail "$stem gzip archive failed"
  chmod 0600 "$archive"
  ( cd "$COORDINATOR_ARCHIVE_DIR" && $CHECKSUM_CMD "$(basename "$archive")" >"$checksum" )
  chmod 0600 "$checksum"
  rm -f "$snapshot"
  log "DONE snapshot_archive=$(basename "$archive") checksum=$(basename "$checksum")"
}

snapshot_archive() {
  [ "$FORCE_ROTATE" = "1" ] || refuse "snapshot requires FORCE_ROTATE=1"
  [ "$COORDINATOR_ARCHIVE_ASSUME_QUIESCED" = "1" ] || refuse "snapshot requires COORDINATOR_ARCHIVE_ASSUME_QUIESCED=1 after stopping coordinator writers"

  mkdir -p "$COORDINATOR_ARCHIVE_DIR"
  chmod 0700 "$COORDINATOR_ARCHIVE_DIR" 2>/dev/null || true

  local ts
  ts=$(utc_ts)
  refuse_existing_archive "coordinator" "$ts"
  if [ -f "$COORDINATOR_AUDIT_DB_PATH" ]; then
    refuse_existing_archive "coordinator-audit" "$ts"
  fi
  snapshot_one "$COORDINATOR_DB_PATH" "coordinator" "$ts"
  if [ -f "$COORDINATOR_AUDIT_DB_PATH" ]; then
    snapshot_one "$COORDINATOR_AUDIT_DB_PATH" "coordinator-audit" "$ts"
  else
    log "sibling coordinator-audit DB absent; no paired audit snapshot created"
  fi
}

if [ "$DRY_RUN" = "1" ]; then
  run_dry_report
  exit 0
fi

if [ "$COORDINATOR_ARCHIVE_SNAPSHOT_ONLY" = "1" ]; then
  snapshot_archive
  exit 0
fi

refuse "non-dry-run mode defaults closed; set DRY_RUN=1 for reporting or COORDINATOR_ARCHIVE_SNAPSHOT_ONLY=1 for verified snapshot scaffolding"
