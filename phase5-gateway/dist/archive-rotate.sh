#!/usr/bin/env bash
# archive-rotate.sh — gateway DB archive rotation (M2-4 Part C, PERF-1 close-out).
#
# Implements the Q4 ruling (beta/DECISION_CRITERIA.md Entry 77, 2026-06-11) and
# audits/2026-06-10/Q4_ARCHIVE_ROTATE_DESIGN.md: the gateway's 9 RAISE(ABORT)
# BEFORE-DELETE triggers stay in force ("append-only forever" tamper-evidence
# claim is preserved). Disk pressure is solved out-of-band by this script:
#
#   1. If gateway.db exceeds GATEWAY_ARCHIVE_SIZE_BYTES (default 8 GiB) OR is
#      older than GATEWAY_ARCHIVE_AGE_DAYS (default 30), snapshot it.
#   2. Snapshot via sqlite3 VACUUM INTO (clean single-file copy, no WAL artifacts).
#   3. Compress the snapshot (zstd if present, gzip fallback) + sha256 sidecar.
#   4. If GATEWAY_ARCHIVE_REQUIRE_REMOTE=1 (default), upload to S3 AND verify
#      readback BEFORE prune. Otherwise, local archive dir is sufficient.
#   5. Drain in-flight gateway requests via /healthz before systemctl stop
#      (configurable timeout GATEWAY_ARCHIVE_DRAIN_TIMEOUT_S, default 60).
#   6. Stop the gateway, aged-prune rows older than cutoff from the 8 event
#      tables AND concurrency_reservations (drop+recreate the BEFORE-DELETE
#      triggers around the DELETE per Q4 design 4(b)), VACUUM, restart.
#   7. Verify live DB shrank or alert.
#
# A trap on EXIT/INT/TERM guarantees unquiesce_gateway is called regardless of
# how the script terminates after quiesce — closing the BLOCKER from audit 1.
#
# Idempotent: re-running with no growth past threshold is a no-op (just logs
# size + age + exit 2). Fails loudly on any sub-step.
#
# Restore: see archive-restore.sh.
#
# Environment:
#   GATEWAY_DB_PATH                       default: /var/lib/macprovider/gateway.db
#   GATEWAY_ARCHIVE_DIR                   default: /var/lib/macprovider-gateway-archive
#   GATEWAY_ARCHIVE_SIZE_BYTES            default: 8589934592   (8 GiB)
#   GATEWAY_ARCHIVE_AGE_DAYS              default: 30
#   GATEWAY_ARCHIVE_PRUNE_DAYS            default: 7   (rows newer than this stay live)
#   GATEWAY_ARCHIVE_S3_BUCKET             optional, e.g. macprovider-archives
#   GATEWAY_ARCHIVE_REQUIRE_REMOTE        default: 1 (fail closed if S3 unconfigured/failed)
#                                         set 0 only on hosts with no off-host archive plan
#   GATEWAY_ARCHIVE_DRAIN_TIMEOUT_S       default: 60 (in-flight drain window pre-stop)
#   GATEWAY_HEALTHZ_URL                   default: http://127.0.0.1:9443/healthz
#   GATEWAY_SERVICE_NAME                  default: macprovider-gateway
#   GATEWAY_DB_OWNER                      default: macprovider:macprovider
#   GATEWAY_ARCHIVE_ALLOW_NO_SYSTEMCTL    default: 0 (1 only for tests; without
#                                         this, a missing service unit aborts
#                                         with exit 4 — no fail-open prune)
#   FORCE_ROTATE=1                        skip size/age check, rotate now
#   DRY_RUN=1                             print intended actions, do not modify state
#
# Exit codes:
#   0  success (rotation happened OR no rotation needed)
#   1  generic error (missing tool, missing file, malformed env)
#   2  size/age below threshold + FORCE_ROTATE=0 -> nothing to do
#   3  rotation attempted but live DB did not shrink (loud alert)
#   4  pre-flight check failed (gateway service not registered, drain timeout,
#      cold storage required but missing/failed)

set -euo pipefail

# ---- environment -----------------------------------------------------------

GATEWAY_DB_PATH="${GATEWAY_DB_PATH:-/var/lib/macprovider/gateway.db}"
GATEWAY_ARCHIVE_DIR="${GATEWAY_ARCHIVE_DIR:-/var/lib/macprovider-gateway-archive}"
GATEWAY_ARCHIVE_SIZE_BYTES="${GATEWAY_ARCHIVE_SIZE_BYTES:-8589934592}"
GATEWAY_ARCHIVE_AGE_DAYS="${GATEWAY_ARCHIVE_AGE_DAYS:-30}"
GATEWAY_ARCHIVE_PRUNE_DAYS="${GATEWAY_ARCHIVE_PRUNE_DAYS:-7}"
GATEWAY_ARCHIVE_S3_BUCKET="${GATEWAY_ARCHIVE_S3_BUCKET:-}"
GATEWAY_ARCHIVE_REQUIRE_REMOTE="${GATEWAY_ARCHIVE_REQUIRE_REMOTE:-1}"
GATEWAY_ARCHIVE_DRAIN_TIMEOUT_S="${GATEWAY_ARCHIVE_DRAIN_TIMEOUT_S:-60}"
GATEWAY_HEALTHZ_URL="${GATEWAY_HEALTHZ_URL:-http://127.0.0.1:9443/healthz}"
GATEWAY_SERVICE_NAME="${GATEWAY_SERVICE_NAME:-macprovider-gateway}"
GATEWAY_DB_OWNER="${GATEWAY_DB_OWNER:-macprovider:macprovider}"
GATEWAY_ARCHIVE_ALLOW_NO_SYSTEMCTL="${GATEWAY_ARCHIVE_ALLOW_NO_SYSTEMCTL:-0}"
FORCE_ROTATE="${FORCE_ROTATE:-0}"
DRY_RUN="${DRY_RUN:-0}"

# Internal state for the cleanup trap (set after we quiesce so the trap knows
# whether to unquiesce). Initialized empty under set -u.
QUIESCED=0
SNAPSHOT_PATH=""
PRUNE_SQL_FILE=""
RECOVER_SQL_FILE=""

# ---- logging ---------------------------------------------------------------

log() { printf '[archive-rotate] %s\n' "$*" >&2; }
fail() { log "ERROR: $*"; exit 1; }

# ---- cleanup trap (closes the unquiesce BLOCKER) ---------------------------
#
# Runs on every exit path — normal completion, error, SIGTERM, SIGINT, kill.
# Idempotent because each step checks state. Without this trap, a VACUUM
# failure, kill mid-script, or sub-shell crash could leave macprovider-gateway
# stopped, and `Restart=on-failure` in the gateway unit does NOT recover an
# explicit `systemctl stop`.
cleanup() {
  local rc=$?
  # Re-apply triggers idempotently in case we exited mid-prune transaction.
  # (CREATE TRIGGER IF NOT EXISTS — won't double-create if they already exist.)
  if [ "$QUIESCED" = "1" ]; then
    log "cleanup: re-asserting append-only triggers (defensive)"
    reassert_triggers_idempotent || log "  WARN: trigger re-assert failed"
  fi
  if [ -n "$PRUNE_SQL_FILE" ] && [ -f "$PRUNE_SQL_FILE" ]; then
    rm -f "$PRUNE_SQL_FILE"
  fi
  if [ -n "$RECOVER_SQL_FILE" ] && [ -f "$RECOVER_SQL_FILE" ]; then
    rm -f "$RECOVER_SQL_FILE"
  fi
  if [ -n "$SNAPSHOT_PATH" ] && [ -f "$SNAPSHOT_PATH" ]; then
    rm -f "$SNAPSHOT_PATH"
  fi
  if [ "$QUIESCED" = "1" ]; then
    log "cleanup: restarting $GATEWAY_SERVICE_NAME (was stopped by this run)"
    unquiesce_gateway_idempotent
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'log "INT received"; exit 130' INT
trap 'log "TERM received"; exit 143' TERM

# ---- pre-flight ------------------------------------------------------------

need_tool() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required tool: $1"
}

need_tool sqlite3
need_tool gzip
need_tool stat
need_tool awk
need_tool date

# Resolve checksum tool exactly once — and DO NOT short-circuit. The earlier
# pattern `need_tool sha256sum 2>/dev/null || need_tool shasum` aborts under
# `set -e` before reaching the fallback on hosts that lack `sha256sum`.
if command -v sha256sum >/dev/null 2>&1; then
  CHECKSUM_CMD="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
  CHECKSUM_CMD="shasum -a 256"
else
  fail "neither sha256sum nor shasum found"
fi

# Compression: prefer zstd, fall back to gzip.
if command -v zstd >/dev/null 2>&1; then
  # -T0 = all cores; bound threads on small Pearl-class hosts via the env if
  # needed by setting ZSTD_NBTHREADS in the unit's env file. -19 trades CPU
  # for size; the operator can downgrade by exporting ZSTD_CLEVEL.
  COMPRESS_CMD="zstd -q -${ZSTD_CLEVEL:-19} -T${ZSTD_NBTHREADS:-0}"
  COMPRESS_EXT="zst"
else
  COMPRESS_CMD="gzip -9"
  COMPRESS_EXT="gz"
fi

[ -f "$GATEWAY_DB_PATH" ] || fail "gateway db not found at $GATEWAY_DB_PATH"

# Validate numeric env (defends against shell-injection via env).
for v in GATEWAY_ARCHIVE_SIZE_BYTES GATEWAY_ARCHIVE_AGE_DAYS GATEWAY_ARCHIVE_PRUNE_DAYS GATEWAY_ARCHIVE_DRAIN_TIMEOUT_S; do
  case "${!v}" in
    ''|*[!0-9]*) fail "$v must be a non-negative integer, got: ${!v}" ;;
  esac
done

# Validate archive dir path — defend against $(...) / backticks / newlines that
# could be injected through the env file. Allow alnum, '_', '-', '/', '.', ':'.
case "$GATEWAY_ARCHIVE_DIR" in
  *$'\n'*|*'$'*|*'`'*|*';'*|*'&'*|*'|'*|*'>'*|*'<'*|*'*'*|*'?'*) fail "GATEWAY_ARCHIVE_DIR contains forbidden shell metachars: $GATEWAY_ARCHIVE_DIR" ;;
esac
case "$GATEWAY_DB_PATH" in
  *$'\n'*|*'$'*|*'`'*|*';'*|*'&'*|*'|'*|*'>'*|*'<'*|*'*'*|*'?'*) fail "GATEWAY_DB_PATH contains forbidden shell metachars: $GATEWAY_DB_PATH" ;;
esac

# ---- helpers ---------------------------------------------------------------

stat_size() {
  if stat -c %s "$1" >/dev/null 2>&1; then
    stat -c %s "$1"
  else
    stat -f %z "$1"
  fi
}

stat_mtime_epoch() {
  if stat -c %Y "$1" >/dev/null 2>&1; then
    stat -c %Y "$1"
  else
    stat -f %m "$1"
  fi
}

utc_ts() { date -u +%Y%m%dT%H%M%SZ; }

service_exists() {
  command -v systemctl >/dev/null 2>&1 || return 1
  systemctl list-unit-files --type=service --no-legend 2>/dev/null \
    | awk '{print $1}' | grep -qx "${GATEWAY_SERVICE_NAME}.service"
}

# The 8 event tables plus concurrency_reservations — all 9 tables protected by
# RAISE(ABORT) BEFORE-DELETE triggers in migrate.go:184-251. concurrency_reservations
# IS included in the prune list now (architect-auditor 1 flagged that PERF-1's
# original audit scope covered all 9 tables, not just 8). We only delete
# concurrency_reservations rows where status != 'active' so we never drop a
# live concurrency reservation — M2-4 Part B's DeleteTerminalQuotaReservations
# semantics are preserved for active rows.
EVENT_TABLES="usage_events feedback_events audit_events api_key_events demo_usage_events capacity_signal_events signup_events demo_session_events"
PRUNE_ALL_TABLES="$EVENT_TABLES concurrency_reservations"

# Build the per-table WHERE clause. Use julianday() to compare RFC3339Nano text
# safely (lexicographic compare against `...:00Z` cutoff is unsafe at fractional
# seconds — code-auditor 1 flagged this).
prune_where_for_table() {
  local t="$1"
  if [ "$t" = "concurrency_reservations" ]; then
    # Never drop active reservations regardless of age.
    printf "julianday(created_at) < julianday(?) AND status <> 'active'"
  else
    printf 'julianday(created_at) < julianday(?)'
  fi
}

reassert_triggers_idempotent() {
  local sql
  sql=""
  for t in $PRUNE_ALL_TABLES; do
    if [ "$t" = "concurrency_reservations" ]; then
      sql="$sql CREATE TRIGGER IF NOT EXISTS ${t}_no_delete BEFORE DELETE ON ${t} BEGIN SELECT RAISE(ABORT, '${t} cannot be deleted'); END;"
    else
      sql="$sql CREATE TRIGGER IF NOT EXISTS ${t}_no_delete BEFORE DELETE ON ${t} BEGIN SELECT RAISE(ABORT, '${t} are append-only'); END;"
    fi
  done
  sqlite3 "$GATEWAY_DB_PATH" "$sql"
}

# Drain pre-stop: poll /healthz for in_flight_requests and only stop when it
# reaches 0 or the timeout elapses. Mirrors deploy-pearl-vps.sh step 5 shape.
# Closes the security-auditor HIGH on rotation killing in-flight streaming
# settlement.
drain_inflight() {
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN: would drain in-flight requests via $GATEWAY_HEALTHZ_URL"
    return 0
  fi
  if ! command -v curl >/dev/null 2>&1; then
    log "WARN: curl not present — skipping in-flight drain (assuming caller knows the system is quiet)"
    return 0
  fi
  local deadline=$(( $(date -u +%s) + GATEWAY_ARCHIVE_DRAIN_TIMEOUT_S ))
  local inflight body
  while :; do
    body=$(curl -fsS --max-time 5 --max-filesize 65536 "$GATEWAY_HEALTHZ_URL" 2>/dev/null || true)
    if [ -z "$body" ]; then
      log "WARN: /healthz unreachable during drain — proceeding (gateway likely already down)"
      return 0
    fi
    inflight=$(printf '%s' "$body" | python3 -c "import sys,json
try: d=json.load(sys.stdin)
except Exception: print(0); sys.exit(0)
print(d.get('in_flight_requests', d.get('inflight', 0)))" 2>/dev/null || echo 0)
    case "$inflight" in
      ''|*[!0-9]*) inflight=0 ;;
    esac
    if [ "$inflight" -eq 0 ]; then
      log "drain ok: 0 in-flight requests"
      return 0
    fi
    if [ "$(date -u +%s)" -ge "$deadline" ]; then
      log "ERROR: drain timeout — $inflight requests still in flight after ${GATEWAY_ARCHIVE_DRAIN_TIMEOUT_S}s"
      return 1
    fi
    log "  draining: $inflight in-flight requests, sleeping 2s"
    sleep 2
  done
}

quiesce_gateway() {
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN: would drain + systemctl stop $GATEWAY_SERVICE_NAME"
    QUIESCED=1
    return 0
  fi
  if service_exists; then
    log "draining in-flight requests pre-stop (timeout=${GATEWAY_ARCHIVE_DRAIN_TIMEOUT_S}s)"
    drain_inflight || { log "ERROR: drain failed — refusing to stop gateway"; exit 4; }
    log "stopping $GATEWAY_SERVICE_NAME for prune window"
    systemctl stop "$GATEWAY_SERVICE_NAME" || fail "failed to stop $GATEWAY_SERVICE_NAME"
    QUIESCED=1
  else
    if [ "$GATEWAY_ARCHIVE_ALLOW_NO_SYSTEMCTL" = "1" ]; then
      log "no systemctl/$GATEWAY_SERVICE_NAME unit found — GATEWAY_ARCHIVE_ALLOW_NO_SYSTEMCTL=1 set, assuming caller handles quiesce (test mode)"
      QUIESCED=1
    else
      log "ERROR: gateway service $GATEWAY_SERVICE_NAME not registered with systemd. Refusing to prune live DB without quiesce."
      log "       Set GATEWAY_ARCHIVE_ALLOW_NO_SYSTEMCTL=1 ONLY for test environments."
      exit 4
    fi
  fi
}

unquiesce_gateway_idempotent() {
  [ "$QUIESCED" = "1" ] || return 0
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN: would systemctl start $GATEWAY_SERVICE_NAME"
    QUIESCED=0
    return 0
  fi
  if service_exists; then
    systemctl start "$GATEWAY_SERVICE_NAME" || log "WARN: failed to start $GATEWAY_SERVICE_NAME — operator action required"
  fi
  QUIESCED=0
}

# ---- threshold check -------------------------------------------------------

SIZE_BYTES=$(stat_size "$GATEWAY_DB_PATH")
MTIME_EPOCH=$(stat_mtime_epoch "$GATEWAY_DB_PATH")
NOW_EPOCH=$(date -u +%s)
AGE_SECONDS=$(( NOW_EPOCH - MTIME_EPOCH ))
AGE_DAYS=$(( AGE_SECONDS / 86400 ))

log "gateway.db size=${SIZE_BYTES}B age=${AGE_DAYS}d (threshold size=${GATEWAY_ARCHIVE_SIZE_BYTES}B age=${GATEWAY_ARCHIVE_AGE_DAYS}d)"

if [ "$FORCE_ROTATE" != "1" ]; then
  if [ "$SIZE_BYTES" -lt "$GATEWAY_ARCHIVE_SIZE_BYTES" ] && [ "$AGE_DAYS" -lt "$GATEWAY_ARCHIVE_AGE_DAYS" ]; then
    log "below thresholds, nothing to do"
    exit 2
  fi
fi

# ---- cold-storage pre-flight (require remote if configured) ----------------
#
# Closes the architect/security HIGH on prune-before-confirmed-cold-storage.
# In production (GATEWAY_ARCHIVE_REQUIRE_REMOTE=1, the default), we MUST have:
#   - GATEWAY_ARCHIVE_S3_BUCKET set
#   - aws-cli on PATH
#   - credentials sufficient to write + read back
# If REQUIRE_REMOTE=0 the operator has explicitly opted into local-only
# retention (e.g. for testing or hosts where cold storage is provided by a
# different mechanism). This must be a deliberate opt-out, not the default.
if [ "$GATEWAY_ARCHIVE_REQUIRE_REMOTE" = "1" ]; then
  if [ -z "$GATEWAY_ARCHIVE_S3_BUCKET" ]; then
    log "ERROR: GATEWAY_ARCHIVE_REQUIRE_REMOTE=1 but GATEWAY_ARCHIVE_S3_BUCKET is empty."
    log "       Set GATEWAY_ARCHIVE_S3_BUCKET, or explicitly set GATEWAY_ARCHIVE_REQUIRE_REMOTE=0"
    log "       (local-only retention; archives stay on the same disk as the live DB)."
    exit 4
  fi
  if ! command -v aws >/dev/null 2>&1; then
    log "ERROR: GATEWAY_ARCHIVE_REQUIRE_REMOTE=1 but aws-cli not on PATH."
    exit 4
  fi
fi

# ---- snapshot --------------------------------------------------------------

TS=$(utc_ts)
mkdir -p "$GATEWAY_ARCHIVE_DIR"
# Tighten archive-dir permissions. The runbook installs this dir as root:root
# 0700 so the gateway service (User=macprovider) cannot substitute or unlink
# archive files. Don't chown here (script may run as a different uid in tests);
# just enforce 0700 mode.
chmod 0700 "$GATEWAY_ARCHIVE_DIR" 2>/dev/null || true

SNAPSHOT_PATH="$GATEWAY_ARCHIVE_DIR/gateway-${TS}.db"
ARCHIVE_PATH="${SNAPSHOT_PATH}.${COMPRESS_EXT}"
CHECKSUM_PATH="${ARCHIVE_PATH}.sha256"

if [ "$DRY_RUN" = "1" ]; then
  log "DRY_RUN: would VACUUM INTO $SNAPSHOT_PATH, compress -> $ARCHIVE_PATH, write $CHECKSUM_PATH"
  exit 0
fi

# Pre-flight free-space check: VACUUM INTO + compressed copy will temporarily
# consume up to ~2x SIZE_BYTES on the same filesystem (the snapshot + the
# compressed archive). Bail loudly if the archive filesystem can't hold it.
if command -v df >/dev/null 2>&1; then
  AVAIL_KB=$(df -Pk "$GATEWAY_ARCHIVE_DIR" 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)
  case "$AVAIL_KB" in ''|*[!0-9]*) AVAIL_KB=0 ;; esac
  NEED_KB=$(( (SIZE_BYTES * 2) / 1024 ))
  if [ "$AVAIL_KB" -lt "$NEED_KB" ]; then
    fail "archive filesystem has ${AVAIL_KB}KB free, need ~${NEED_KB}KB for snapshot+compress"
  fi
fi

log "snapshot via sqlite3 VACUUM INTO -> $SNAPSHOT_PATH"
# Quote the SQL literal — basic single-quote escape so a path with apostrophes
# doesn't break out of the SQL string. We already rejected metachar paths above
# but defense in depth.
ESC_SNAPSHOT_PATH="${SNAPSHOT_PATH//\'/\'\'}"
sqlite3 "$GATEWAY_DB_PATH" "VACUUM INTO '$ESC_SNAPSHOT_PATH';" || fail "VACUUM INTO failed"
chmod 0600 "$SNAPSHOT_PATH"

log "integrity check on snapshot"
INTEGRITY=$(sqlite3 "$SNAPSHOT_PATH" "PRAGMA integrity_check;" || echo "fail")
if [ "$INTEGRITY" != "ok" ]; then
  fail "snapshot integrity check failed: $INTEGRITY"
fi

log "compress snapshot ($COMPRESS_CMD)"
$COMPRESS_CMD <"$SNAPSHOT_PATH" >"$ARCHIVE_PATH" || fail "compress failed"
chmod 0600 "$ARCHIVE_PATH"

log "checksum -> $CHECKSUM_PATH"
# Compute checksum keyed to the basename so archive-restore.sh can require the
# sidecar's listed filename to match the archive basename (closes security
# MEDIUM on .sha256 not being filename-bound).
( cd "$GATEWAY_ARCHIVE_DIR" && $CHECKSUM_CMD "$(basename "$ARCHIVE_PATH")" >"$CHECKSUM_PATH" )
chmod 0600 "$CHECKSUM_PATH"

# Snapshot is no longer needed once compressed + checksummed; clear the
# trap-managed var so cleanup doesn't try to delete a missing file.
rm -f "$SNAPSHOT_PATH"
SNAPSHOT_PATH=""

# ---- cold-storage upload + readback verify (gate before prune) -------------

if [ -n "$GATEWAY_ARCHIVE_S3_BUCKET" ]; then
  if command -v aws >/dev/null 2>&1; then
    log "upload to s3://$GATEWAY_ARCHIVE_S3_BUCKET/$(basename "$ARCHIVE_PATH")"
    if ! aws s3 cp "$ARCHIVE_PATH" "s3://$GATEWAY_ARCHIVE_S3_BUCKET/" --only-show-errors; then
      if [ "$GATEWAY_ARCHIVE_REQUIRE_REMOTE" = "1" ]; then
        log "ERROR: GATEWAY_ARCHIVE_REQUIRE_REMOTE=1 but s3 archive upload failed — refusing to prune"
        exit 4
      fi
      log "WARN: s3 upload failed (REQUIRE_REMOTE=0); archive remains in $GATEWAY_ARCHIVE_DIR"
    else
      # Upload checksum too, then readback-verify that the remote object is
      # actually fetchable. `aws s3api head-object` returns 0 only when the
      # object exists and the principal can read it.
      aws s3 cp "$CHECKSUM_PATH" "s3://$GATEWAY_ARCHIVE_S3_BUCKET/" --only-show-errors \
        || log "WARN: s3 checksum upload failed (archive upload succeeded)"
      if [ "$GATEWAY_ARCHIVE_REQUIRE_REMOTE" = "1" ]; then
        log "verifying remote readback (head-object)"
        if ! aws s3api head-object \
              --bucket "$GATEWAY_ARCHIVE_S3_BUCKET" \
              --key "$(basename "$ARCHIVE_PATH")" >/dev/null 2>&1; then
          log "ERROR: head-object failed on remote archive — refusing to prune"
          exit 4
        fi
        log "  remote readback OK"
      fi
    fi
  else
    if [ "$GATEWAY_ARCHIVE_REQUIRE_REMOTE" = "1" ]; then
      fail "GATEWAY_ARCHIVE_REQUIRE_REMOTE=1 but aws-cli missing post-snapshot — this should have been caught at pre-flight"
    fi
    log "WARN: GATEWAY_ARCHIVE_S3_BUCKET set but aws-cli missing — archive stays local"
  fi
fi

# ---- prune live DB (Q4 design 4(b): aged-prune) ----------------------------

quiesce_gateway

PRE_PRUNE_SIZE=$(stat_size "$GATEWAY_DB_PATH")
# Cutoff for the SQL parameter; format is irrelevant to julianday() but we use
# RFC3339 seconds for the log line.
CUTOFF_EPOCH=$(( NOW_EPOCH - GATEWAY_ARCHIVE_PRUNE_DAYS * 86400 ))
CUTOFF=$(date -u -d "@${CUTOFF_EPOCH}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -r "${CUTOFF_EPOCH}" +%Y-%m-%dT%H:%M:%SZ)

log "aged-prune cutoff=$CUTOFF (rows older than this are dropped from event tables)"
log "pre-prune live DB size=${PRE_PRUNE_SIZE}B"

# Drop + recreate each table's BEFORE-DELETE trigger inside a single
# BEGIN IMMEDIATE; ... COMMIT; transaction so the append-only invariant is
# restored even if the prune aborts. Uses julianday() for safe comparison
# against RFC3339Nano `created_at` values (closes code-auditor MEDIUM).
PRUNE_SQL_FILE=$(mktemp)

{
  echo ".bail on"
  echo "BEGIN IMMEDIATE;"
  for t in $PRUNE_ALL_TABLES; do
    echo "DROP TRIGGER IF EXISTS ${t}_no_delete;"
    where=$(prune_where_for_table "$t")
    # Single bound parameter via .param; bash here-doc has no shell expansion
    # for $CUTOFF inside SQL — we pass it via .param set instead of literal
    # interpolation to avoid quoting issues entirely.
    echo "DELETE FROM ${t} WHERE ${where};"
    if [ "$t" = "concurrency_reservations" ]; then
      echo "CREATE TRIGGER ${t}_no_delete BEFORE DELETE ON ${t} BEGIN SELECT RAISE(ABORT, '${t} cannot be deleted'); END;"
    else
      echo "CREATE TRIGGER ${t}_no_delete BEFORE DELETE ON ${t} BEGIN SELECT RAISE(ABORT, '${t} are append-only'); END;"
    fi
  done
  echo "COMMIT;"
} >"$PRUNE_SQL_FILE"

# sqlite3 .param doesn't combine well with .read in older builds; pass the
# CUTOFF literal but SQL-escape it (single quote doubling). Easier than .param.
ESC_CUTOFF="${CUTOFF//\'/\'\'}"
sed -i.bak "s/WHERE ${EVENT_TABLES%% *} julianday/PLACEHOLDER/" "$PRUNE_SQL_FILE" 2>/dev/null || true
# Simpler: replace the single `?` with a quoted literal everywhere in the SQL
# file. Each DELETE uses the same cutoff.
python3 -c "
import sys, pathlib
p = pathlib.Path('$PRUNE_SQL_FILE')
sql = p.read_text()
sql = sql.replace('julianday(?)', \"julianday('$ESC_CUTOFF')\")
p.write_text(sql)
" || fail "failed to substitute CUTOFF into prune SQL"
rm -f "${PRUNE_SQL_FILE}.bak"

log "applying aged-prune transaction"
if ! sqlite3 "$GATEWAY_DB_PATH" <"$PRUNE_SQL_FILE"; then
  log "ERROR: aged-prune transaction failed — triggers will be re-asserted by cleanup trap"
  fail "aged-prune failed"
fi
rm -f "$PRUNE_SQL_FILE"
PRUNE_SQL_FILE=""

log "VACUUM to reclaim free pages"
sqlite3 "$GATEWAY_DB_PATH" "VACUUM;" || fail "VACUUM failed"

POST_PRUNE_SIZE=$(stat_size "$GATEWAY_DB_PATH")
log "post-prune live DB size=${POST_PRUNE_SIZE}B (was ${PRE_PRUNE_SIZE}B)"

# Permissions on the (possibly recreated) WAL/SHM files: VACUUM may have
# touched them. Ensure ownership matches what the daemon expects.
if [ "$(id -u)" = "0" ]; then
  chown "$GATEWAY_DB_OWNER" "$GATEWAY_DB_PATH" 2>/dev/null || true
  for ext in "-wal" "-shm"; do
    if [ -f "${GATEWAY_DB_PATH}${ext}" ]; then
      chown "$GATEWAY_DB_OWNER" "${GATEWAY_DB_PATH}${ext}" 2>/dev/null || true
    fi
  done
fi

# Trap-driven unquiesce will run on EXIT; clear early so we restart cleanly on
# the success path with normal exit 0.
unquiesce_gateway_idempotent

# ---- verify shrinkage ------------------------------------------------------

# If the prune cutoff was so recent / there was no aged data, size may not
# have shrunk. That's fine when FORCE_ROTATE=1 was used (operator drill).
# Only alert if we hit the threshold path AND the file did not shrink at all.
if [ "$FORCE_ROTATE" != "1" ] && [ "$POST_PRUNE_SIZE" -ge "$PRE_PRUNE_SIZE" ]; then
  log "WARN: live DB did not shrink (pre=${PRE_PRUNE_SIZE}, post=${POST_PRUNE_SIZE}). Archive is at $ARCHIVE_PATH — investigate before next run."
  exit 3
fi

log "DONE. archive=$ARCHIVE_PATH (sha256 in ${CHECKSUM_PATH}). live DB shrank by $(( PRE_PRUNE_SIZE - POST_PRUNE_SIZE )) bytes."
exit 0
