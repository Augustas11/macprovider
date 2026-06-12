#!/usr/bin/env bash
# archive-restore.sh — restore a gateway DB archive produced by archive-rotate.sh.
#
# Forensic-restore path (Q4 design "Restore procedure", section 4(b)). Decompresses
# a checksummed archive into a target path so the operator can run SELECT-only
# queries against it via `sqlite3`. This script does NOT replace the live
# gateway.db — that would destroy the rows added since the snapshot was taken.
# To rehydrate the live DB on top of a snapshot, run this with --to-live and
# read the loud warning it prints.
#
# Usage:
#   archive-restore.sh <archive-path> [<target-path>]
#   archive-restore.sh --to-live <archive-path>     # destructive; replaces live DB
#
# Defaults:
#   <target-path>: $(mktemp -t gateway-restored.XXXXXX).db   (NOT predictable)
#
# Environment:
#   GATEWAY_DB_PATH        default: /var/lib/macprovider/gateway.db (used by --to-live)
#   GATEWAY_SERVICE_NAME   default: macprovider-gateway
#   GATEWAY_DB_OWNER       default: macprovider:macprovider
#   SKIP_CHECKSUM=1        skip checksum verification (NOT recommended)
#   ASSUME_YES=1           skip --to-live confirmation prompt
#
# Exit codes:
#   0  success
#   1  generic error
#   5  archive checksum mismatch OR sidecar filename mismatch
#   6  schema-version mismatch (archive predates current migrate.go)

set -euo pipefail

GATEWAY_DB_PATH="${GATEWAY_DB_PATH:-/var/lib/macprovider/gateway.db}"
GATEWAY_SERVICE_NAME="${GATEWAY_SERVICE_NAME:-macprovider-gateway}"
GATEWAY_DB_OWNER="${GATEWAY_DB_OWNER:-macprovider:macprovider}"
SKIP_CHECKSUM="${SKIP_CHECKSUM:-0}"
ASSUME_YES="${ASSUME_YES:-0}"

# Variables consumed by the cleanup trap — initialize so `set -u` doesn't
# explode in early failure paths.
TMP_DB=""
BACKUP_LIVE=""

log() { printf '[archive-restore] %s\n' "$*" >&2; }
fail() { log "ERROR: $*"; exit 1; }

cleanup() {
  local rc=$?
  if [ -n "$TMP_DB" ] && [ -f "$TMP_DB" ]; then
    rm -f "$TMP_DB"
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'log "INT received"; exit 130' INT
trap 'log "TERM received"; exit 143' TERM

# ---- parse args ------------------------------------------------------------

TO_LIVE=0
if [ "${1:-}" = "--to-live" ]; then
  TO_LIVE=1
  shift
fi

ARCHIVE_PATH="${1:-}"
if [ -z "$ARCHIVE_PATH" ]; then
  cat >&2 <<EOF
usage: $0 <archive-path> [<target-path>]
       $0 --to-live <archive-path>
EOF
  exit 1
fi
[ -f "$ARCHIVE_PATH" ] || fail "archive not found: $ARCHIVE_PATH"

if [ "$TO_LIVE" = "1" ]; then
  TARGET_PATH="$GATEWAY_DB_PATH"
else
  # mktemp gives an unpredictable path under TMPDIR (defends against
  # symlink-race attacks on /tmp).
  TARGET_PATH="${2:-$(mktemp -t gateway-restored.XXXXXX).db}"
fi

# ---- tool detection --------------------------------------------------------

need_tool() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required tool: $1"
}
need_tool sqlite3

if command -v sha256sum >/dev/null 2>&1; then
  CHECKSUM_CMD="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
  CHECKSUM_CMD="shasum -a 256"
else
  fail "neither sha256sum nor shasum found"
fi

# ---- checksum + filename-binding verification ------------------------------

if [ "$SKIP_CHECKSUM" != "1" ]; then
  CHECKSUM_FILE="${ARCHIVE_PATH}.sha256"
  if [ ! -f "$CHECKSUM_FILE" ]; then
    fail "checksum file missing: $CHECKSUM_FILE (use SKIP_CHECKSUM=1 to override — NOT recommended for cold-storage drops)"
  fi
  ARCHIVE_BASE=$(basename "$ARCHIVE_PATH")
  # Bind the sidecar to the archive's basename. `sha256sum -c` will happily
  # verify any filename listed in the sidecar; without this check, an attacker
  # who can write the cold-storage dir could rename a forged archive over a
  # legitimate one and the listed filename in the sidecar wouldn't necessarily
  # match. We require the sidecar's last field to equal ARCHIVE_BASE.
  SIDECAR_BASE=$(awk '{print $NF}' "$CHECKSUM_FILE" | head -1)
  if [ "$SIDECAR_BASE" != "$ARCHIVE_BASE" ]; then
    log "ERROR: checksum sidecar lists '$SIDECAR_BASE' but archive basename is '$ARCHIVE_BASE'"
    exit 5
  fi
  log "verifying checksum against $CHECKSUM_FILE (filename-bound to $ARCHIVE_BASE)"
  ARCHIVE_DIR=$(dirname "$ARCHIVE_PATH")
  ( cd "$ARCHIVE_DIR" && $CHECKSUM_CMD -c "$(basename "$CHECKSUM_FILE")" ) || {
    log "ERROR: checksum mismatch — archive is corrupted or tampered with"
    exit 5
  }
else
  log "WARN: SKIP_CHECKSUM=1 — skipping checksum verification"
fi

# ---- decompress ------------------------------------------------------------

TMP_DB=$(mktemp -t gateway-restore.XXXXXX)

case "$ARCHIVE_PATH" in
  *.zst)
    need_tool zstd
    log "decompress (zstd) -> $TMP_DB"
    zstd -d -q -c "$ARCHIVE_PATH" >"$TMP_DB" || fail "zstd decompress failed"
    ;;
  *.gz)
    need_tool gzip
    log "decompress (gzip) -> $TMP_DB"
    gzip -dc "$ARCHIVE_PATH" >"$TMP_DB" || fail "gzip decompress failed"
    ;;
  *.db)
    log "uncompressed archive — copying"
    cp "$ARCHIVE_PATH" "$TMP_DB" || fail "copy failed"
    ;;
  *)
    fail "unknown archive extension: $ARCHIVE_PATH (expected .zst, .gz, or .db)"
    ;;
esac

# ---- integrity + schema-version check --------------------------------------

log "PRAGMA integrity_check on decompressed DB"
INTEGRITY=$(sqlite3 "$TMP_DB" "PRAGMA integrity_check;" || echo "fail")
if [ "$INTEGRITY" != "ok" ]; then
  fail "decompressed DB failed integrity check: $INTEGRITY"
fi

# Schema-version check.
EXPECTED_VERSION=1
ARCHIVE_VERSION=$(sqlite3 "$TMP_DB" "SELECT COALESCE(MAX(version), 0) FROM schema_migrations;" 2>/dev/null || echo 0)
log "archive schema version=$ARCHIVE_VERSION expected=$EXPECTED_VERSION"
if [ "$ARCHIVE_VERSION" -gt "$EXPECTED_VERSION" ]; then
  log "ERROR: archive schema (v$ARCHIVE_VERSION) is newer than this binary supports (v$EXPECTED_VERSION) — refusing"
  exit 6
fi
if [ "$ARCHIVE_VERSION" -lt "$EXPECTED_VERSION" ]; then
  log "WARN: archive schema (v$ARCHIVE_VERSION) is older than current (v$EXPECTED_VERSION) — gateway Migrate() will upgrade in place on next start"
fi

# ---- install ---------------------------------------------------------------

if [ "$TO_LIVE" = "1" ]; then
  if [ "$ASSUME_YES" != "1" ]; then
    cat >&2 <<EOF

  WARNING: --to-live will REPLACE the live gateway DB at:
    $GATEWAY_DB_PATH
  with the contents of:
    $ARCHIVE_PATH
  All rows written to the live DB since the snapshot was taken WILL BE LOST.

  To proceed, re-run with: ASSUME_YES=1 $0 --to-live $ARCHIVE_PATH
EOF
    exit 1
  fi

  log "stopping $GATEWAY_SERVICE_NAME for in-place restore"
  if command -v systemctl >/dev/null 2>&1 \
     && systemctl list-unit-files --type=service --no-legend 2>/dev/null \
        | awk '{print $1}' | grep -qx "${GATEWAY_SERVICE_NAME}.service"; then
    systemctl stop "$GATEWAY_SERVICE_NAME" || fail "failed to stop $GATEWAY_SERVICE_NAME"
  fi

  # Snapshot the current live DB so the operator can undo this — only if one
  # actually exists. Skip-with-log on first-time-restore avoids a `set -u` /
  # cp-of-missing-file footgun.
  if [ -f "$TARGET_PATH" ]; then
    BACKUP_LIVE="${TARGET_PATH}.pre-restore.$(date -u +%Y%m%dT%H%M%SZ)"
    log "backing up current live DB to $BACKUP_LIVE"
    cp "$TARGET_PATH" "$BACKUP_LIVE" || fail "live-DB backup failed"
  else
    log "no live DB at $TARGET_PATH — first-time restore, no backup taken"
  fi

  # Remove WAL/SHM so the daemon recovers cleanly from the snapshot.
  rm -f "${TARGET_PATH}-wal" "${TARGET_PATH}-shm" 2>/dev/null || true

  install -m 0600 "$TMP_DB" "$TARGET_PATH" || fail "install failed"
  if [ "$(id -u)" = "0" ]; then
    chown "$GATEWAY_DB_OWNER" "$TARGET_PATH" 2>/dev/null || true
  fi

  if command -v systemctl >/dev/null 2>&1 \
     && systemctl list-unit-files --type=service --no-legend 2>/dev/null \
        | awk '{print $1}' | grep -qx "${GATEWAY_SERVICE_NAME}.service"; then
    log "restarting $GATEWAY_SERVICE_NAME"
    systemctl start "$GATEWAY_SERVICE_NAME" || fail "failed to start $GATEWAY_SERVICE_NAME"
  fi
  if [ -n "$BACKUP_LIVE" ]; then
    log "DONE — live DB restored from $ARCHIVE_PATH; previous live DB at $BACKUP_LIVE"
  else
    log "DONE — live DB created from $ARCHIVE_PATH (no prior DB existed)"
  fi
else
  install -m 0600 "$TMP_DB" "$TARGET_PATH" || fail "install failed"
  log "DONE — read-only restore at $TARGET_PATH (open with: sqlite3 $TARGET_PATH)"
fi

# Cleanup of $TMP_DB happens via the EXIT trap.
exit 0
