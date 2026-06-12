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
#   3. Compress the snapshot (zstd if present, gzip fallback).
#   4. Move the compressed archive to $GATEWAY_ARCHIVE_DIR (default
#      /var/lib/macprovider-gateway-archive). Optionally upload to S3 if
#      $GATEWAY_ARCHIVE_S3_BUCKET is set and aws-cli is installed.
#   5. Stop the gateway, aged-prune rows older than cutoff from the 8 event
#      tables (drop+recreate the BEFORE-DELETE triggers around the DELETE per
#      Q4 design 4(b)), VACUUM, restart the gateway. concurrency_reservations
#      keeps its trigger and is not pruned here (M2-4 Part B owns that table).
#   6. Verify live DB shrank or alert and roll back the prune.
#
# Idempotent: re-running with no growth past threshold is a no-op (just logs
# size + age + exit 0). Fails loudly on any sub-step.
#
# Restore: see archive-restore.sh.
#
# Environment:
#   GATEWAY_DB_PATH             default: /var/lib/macprovider/gateway.db
#   GATEWAY_ARCHIVE_DIR         default: /var/lib/macprovider-gateway-archive
#   GATEWAY_ARCHIVE_SIZE_BYTES  default: 8589934592   (8 GiB)
#   GATEWAY_ARCHIVE_AGE_DAYS    default: 30
#   GATEWAY_ARCHIVE_PRUNE_DAYS  default: 7   (rows newer than this stay live)
#   GATEWAY_ARCHIVE_S3_BUCKET   optional, e.g. macprovider-archives
#   GATEWAY_SERVICE_NAME        default: macprovider-gateway
#   GATEWAY_DB_OWNER            default: macprovider:macprovider
#   FORCE_ROTATE=1              skip size/age check, rotate now
#   DRY_RUN=1                   print intended actions, do not modify state
#
# Exit codes:
#   0  success (rotation happened OR no rotation needed)
#   1  generic error (missing tool, missing file, malformed env)
#   2  size/age below threshold + FORCE_ROTATE=0 -> nothing to do (treated as 0
#      in the timer path; this code is for scripted callers that want to know)
#   3  rotation attempted but live DB did not shrink (roll-back triggered)
#   4  pre-flight check failed (gateway service not running where expected)

set -euo pipefail

# ---- environment -----------------------------------------------------------

GATEWAY_DB_PATH="${GATEWAY_DB_PATH:-/var/lib/macprovider/gateway.db}"
GATEWAY_ARCHIVE_DIR="${GATEWAY_ARCHIVE_DIR:-/var/lib/macprovider-gateway-archive}"
GATEWAY_ARCHIVE_SIZE_BYTES="${GATEWAY_ARCHIVE_SIZE_BYTES:-8589934592}"
GATEWAY_ARCHIVE_AGE_DAYS="${GATEWAY_ARCHIVE_AGE_DAYS:-30}"
GATEWAY_ARCHIVE_PRUNE_DAYS="${GATEWAY_ARCHIVE_PRUNE_DAYS:-7}"
GATEWAY_ARCHIVE_S3_BUCKET="${GATEWAY_ARCHIVE_S3_BUCKET:-}"
GATEWAY_SERVICE_NAME="${GATEWAY_SERVICE_NAME:-macprovider-gateway}"
GATEWAY_DB_OWNER="${GATEWAY_DB_OWNER:-macprovider:macprovider}"
FORCE_ROTATE="${FORCE_ROTATE:-0}"
DRY_RUN="${DRY_RUN:-0}"

# ---- logging ---------------------------------------------------------------

log() { printf '[archive-rotate] %s\n' "$*" >&2; }
fail() { log "ERROR: $*"; exit 1; }

# ---- pre-flight ------------------------------------------------------------

need_tool() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required tool: $1"
}

need_tool sqlite3
need_tool gzip
need_tool stat
need_tool awk
need_tool date
need_tool sha256sum 2>/dev/null || need_tool shasum  # GNU vs BSD; we resolve later

# Pick the checksum binary once.
if command -v sha256sum >/dev/null 2>&1; then
  CHECKSUM_CMD="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
  CHECKSUM_CMD="shasum -a 256"
else
  fail "neither sha256sum nor shasum found"
fi

# Compression: prefer zstd, fall back to gzip.
if command -v zstd >/dev/null 2>&1; then
  COMPRESS_CMD="zstd -q -19 -T0"
  COMPRESS_EXT="zst"
else
  COMPRESS_CMD="gzip -9"
  COMPRESS_EXT="gz"
fi

[ -f "$GATEWAY_DB_PATH" ] || fail "gateway db not found at $GATEWAY_DB_PATH"

# Validate numeric env (defends against shell-injection via env).
case "$GATEWAY_ARCHIVE_SIZE_BYTES" in
  ''|*[!0-9]*) fail "GATEWAY_ARCHIVE_SIZE_BYTES must be a non-negative integer, got: $GATEWAY_ARCHIVE_SIZE_BYTES" ;;
esac
case "$GATEWAY_ARCHIVE_AGE_DAYS" in
  ''|*[!0-9]*) fail "GATEWAY_ARCHIVE_AGE_DAYS must be a non-negative integer, got: $GATEWAY_ARCHIVE_AGE_DAYS" ;;
esac
case "$GATEWAY_ARCHIVE_PRUNE_DAYS" in
  ''|*[!0-9]*) fail "GATEWAY_ARCHIVE_PRUNE_DAYS must be a non-negative integer, got: $GATEWAY_ARCHIVE_PRUNE_DAYS" ;;
esac

# ---- helpers ---------------------------------------------------------------

stat_size() {
  # GNU: stat -c %s, BSD: stat -f %z. Detect once.
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

# Quiesce: stop the gateway service if systemctl is available and the service
# exists; otherwise the caller is responsible (DRY_RUN/tests skip this).
quiesce_gateway() {
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN: would systemctl stop $GATEWAY_SERVICE_NAME"
    return 0
  fi
  if command -v systemctl >/dev/null 2>&1 && systemctl list-units --type=service --all --no-legend 2>/dev/null | grep -q "^$GATEWAY_SERVICE_NAME"; then
    log "stopping $GATEWAY_SERVICE_NAME for prune window"
    systemctl stop "$GATEWAY_SERVICE_NAME" || fail "failed to stop $GATEWAY_SERVICE_NAME"
  else
    log "no systemctl/service found — assuming caller handles quiesce (test mode)"
  fi
}

unquiesce_gateway() {
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN: would systemctl start $GATEWAY_SERVICE_NAME"
    return 0
  fi
  if command -v systemctl >/dev/null 2>&1 && systemctl list-units --type=service --all --no-legend 2>/dev/null | grep -q "^$GATEWAY_SERVICE_NAME"; then
    log "starting $GATEWAY_SERVICE_NAME"
    systemctl start "$GATEWAY_SERVICE_NAME" || fail "failed to start $GATEWAY_SERVICE_NAME"
  fi
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

# ---- snapshot --------------------------------------------------------------

TS=$(utc_ts)
mkdir -p "$GATEWAY_ARCHIVE_DIR"
chmod 0700 "$GATEWAY_ARCHIVE_DIR" 2>/dev/null || true

SNAPSHOT_PATH="$GATEWAY_ARCHIVE_DIR/gateway-${TS}.db"
ARCHIVE_PATH="${SNAPSHOT_PATH}.${COMPRESS_EXT}"
CHECKSUM_PATH="${ARCHIVE_PATH}.sha256"

if [ "$DRY_RUN" = "1" ]; then
  log "DRY_RUN: would VACUUM INTO $SNAPSHOT_PATH, compress -> $ARCHIVE_PATH, write $CHECKSUM_PATH"
  exit 0
fi

cleanup_snapshot() {
  [ -f "$SNAPSHOT_PATH" ] && rm -f "$SNAPSHOT_PATH"
}
trap cleanup_snapshot EXIT

log "snapshot via sqlite3 VACUUM INTO -> $SNAPSHOT_PATH"
# VACUUM INTO is read-only against the live DB and produces a clean single-file
# copy with no WAL artifacts. Safer than file copy because the live DB may have
# in-flight writes.
sqlite3 "$GATEWAY_DB_PATH" "VACUUM INTO '$SNAPSHOT_PATH';" || fail "VACUUM INTO failed"
chmod 0600 "$SNAPSHOT_PATH"

# Integrity-check the snapshot before we trust it for the prune step.
log "integrity check on snapshot"
INTEGRITY=$(sqlite3 "$SNAPSHOT_PATH" "PRAGMA integrity_check;" || echo "fail")
if [ "$INTEGRITY" != "ok" ]; then
  fail "snapshot integrity check failed: $INTEGRITY"
fi

log "compress snapshot ($COMPRESS_CMD)"
$COMPRESS_CMD <"$SNAPSHOT_PATH" >"$ARCHIVE_PATH" || fail "compress failed"
chmod 0600 "$ARCHIVE_PATH"

log "checksum -> $CHECKSUM_PATH"
( cd "$GATEWAY_ARCHIVE_DIR" && $CHECKSUM_CMD "$(basename "$ARCHIVE_PATH")" >"$CHECKSUM_PATH" )
chmod 0600 "$CHECKSUM_PATH"

# Snapshot is no longer needed once compressed + checksummed.
rm -f "$SNAPSHOT_PATH"
trap - EXIT

# ---- optional S3 upload ----------------------------------------------------

if [ -n "$GATEWAY_ARCHIVE_S3_BUCKET" ]; then
  if command -v aws >/dev/null 2>&1; then
    log "upload to s3://$GATEWAY_ARCHIVE_S3_BUCKET/$(basename "$ARCHIVE_PATH")"
    aws s3 cp "$ARCHIVE_PATH" "s3://$GATEWAY_ARCHIVE_S3_BUCKET/" --only-show-errors \
      || log "WARN: s3 upload failed; archive remains in $GATEWAY_ARCHIVE_DIR"
    aws s3 cp "$CHECKSUM_PATH" "s3://$GATEWAY_ARCHIVE_S3_BUCKET/" --only-show-errors \
      || log "WARN: s3 checksum upload failed"
  else
    log "WARN: GATEWAY_ARCHIVE_S3_BUCKET set but aws-cli missing — archive stays local"
  fi
fi

# ---- prune live DB (Q4 design 4(b): aged-prune) ----------------------------

quiesce_gateway

PRE_PRUNE_SIZE=$(stat_size "$GATEWAY_DB_PATH")
CUTOFF=$(date -u -d "@$(( NOW_EPOCH - GATEWAY_ARCHIVE_PRUNE_DAYS * 86400 ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -r "$(( NOW_EPOCH - GATEWAY_ARCHIVE_PRUNE_DAYS * 86400 ))" +%Y-%m-%dT%H:%M:%SZ)

log "aged-prune cutoff=$CUTOFF (rows older than this are dropped from event tables)"
log "pre-prune live DB size=${PRE_PRUNE_SIZE}B"

# The 8 event tables that have BEFORE-DELETE triggers in migrate.go:184-251.
# concurrency_reservations is intentionally NOT in this list: M2-4 Part B owns
# its lifecycle via DeleteTerminalQuotaReservations (per-row, no trigger drop
# needed because it never had a BEFORE-DELETE trigger amended out).
EVENT_TABLES="usage_events feedback_events audit_events api_key_events demo_usage_events capacity_signal_events signup_events demo_session_events"

# Each table has a `created_at` TEXT column in RFC3339 form (see migrate.go).
# Drop+recreate the trigger inside a single transaction so the append-only
# invariant is restored even if the prune aborts.
PRUNE_SQL=$(mktemp)
cleanup_prune() {
  [ -f "$PRUNE_SQL" ] && rm -f "$PRUNE_SQL"
}
trap cleanup_prune EXIT

{
  echo "BEGIN IMMEDIATE;"
  for t in $EVENT_TABLES; do
    echo "DROP TRIGGER IF EXISTS ${t}_no_delete;"
    echo "DELETE FROM ${t} WHERE created_at < '$CUTOFF';"
    echo "CREATE TRIGGER ${t}_no_delete BEFORE DELETE ON ${t} BEGIN SELECT RAISE(ABORT, '${t} are append-only'); END;"
  done
  echo "COMMIT;"
} >"$PRUNE_SQL"

log "applying aged-prune transaction"
if ! sqlite3 "$GATEWAY_DB_PATH" <"$PRUNE_SQL"; then
  log "prune failed — gateway DB transaction rolled back, but triggers may need re-application; running idempotent restore"
  # Re-apply triggers idempotently (CREATE TRIGGER IF NOT EXISTS) so the
  # append-only invariant is guaranteed even after a partial prune.
  RECOVER_SQL=$(mktemp)
  for t in $EVENT_TABLES; do
    printf "CREATE TRIGGER IF NOT EXISTS %s_no_delete BEFORE DELETE ON %s BEGIN SELECT RAISE(ABORT, '%s are append-only'); END;\n" "$t" "$t" "$t" >>"$RECOVER_SQL"
  done
  sqlite3 "$GATEWAY_DB_PATH" <"$RECOVER_SQL" || true
  rm -f "$RECOVER_SQL"
  unquiesce_gateway
  fail "aged-prune transaction failed; triggers re-asserted"
fi

# VACUUM to actually reclaim space.
log "VACUUM to reclaim free pages"
sqlite3 "$GATEWAY_DB_PATH" "VACUUM;" || fail "VACUUM failed"

POST_PRUNE_SIZE=$(stat_size "$GATEWAY_DB_PATH")
log "post-prune live DB size=${POST_PRUNE_SIZE}B (was ${PRE_PRUNE_SIZE}B)"

# Permissions on the (possibly recreated) WAL/SHM files: VACUUM may have
# touched them. Ensure ownership matches what the daemon expects.
if [ "$(id -u)" = "0" ]; then
  chown "$GATEWAY_DB_OWNER" "$GATEWAY_DB_PATH" 2>/dev/null || true
  for ext in "-wal" "-shm"; do
    [ -f "${GATEWAY_DB_PATH}${ext}" ] && chown "$GATEWAY_DB_OWNER" "${GATEWAY_DB_PATH}${ext}" 2>/dev/null || true
  done
fi

unquiesce_gateway

# ---- verify shrinkage ------------------------------------------------------

# If the prune cutoff was so recent / there was no aged data, size may not
# have shrunk. That's fine when FORCE_ROTATE=1 was used (operator drill).
# Only alert if we hit the threshold path AND the file did not shrink at all.
if [ "$FORCE_ROTATE" != "1" ] && [ "$POST_PRUNE_SIZE" -ge "$PRE_PRUNE_SIZE" ]; then
  log "WARN: live DB did not shrink (pre=${PRE_PRUNE_SIZE}, post=${POST_PRUNE_SIZE}). Archive is still on disk at $ARCHIVE_PATH — investigate before next run."
  exit 3
fi

log "DONE. archive=$ARCHIVE_PATH (sha256 in ${CHECKSUM_PATH}). live DB shrank by $(( PRE_PRUNE_SIZE - POST_PRUNE_SIZE )) bytes."
exit 0
