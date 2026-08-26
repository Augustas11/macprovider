#!/usr/bin/env bash
# coordinator-archive-restore.sh — forensic restore for coordinator DB archives.
#
# Restores archives produced by coordinator-archive-rotate.sh to a separate
# target. Replacing the live coordinator DB is intentionally refused in this
# Phase 3 scaffold; promote restored files manually only after operator review.

set -euo pipefail

COORDINATOR_DB_PATH="${COORDINATOR_DB_PATH:-/var/lib/macprovider/coordinator.db}"
COORDINATOR_AUDIT_DB_PATH="${COORDINATOR_AUDIT_DB_PATH:-}"
SKIP_CHECKSUM="${SKIP_CHECKSUM:-0}"
ALLOW_UNPAIRED_AUDIT_RESTORE="${ALLOW_UNPAIRED_AUDIT_RESTORE:-0}"

log() { printf '[coordinator-archive-restore] %s\n' "$*" >&2; }
fail() { log "ERROR: $*"; exit 1; }
refuse() { log "REFUSING: $*"; exit 4; }

need_tool() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required tool: $1"
}

TO_LIVE=0
if [ "${1:-}" = "--to-live" ]; then
  TO_LIVE=1
  shift
fi

ARCHIVE_PATH="${1:-}"
if [ -z "$ARCHIVE_PATH" ]; then
  echo "usage: coordinator-archive-restore.sh [--to-live] <archive-path> [target-path]" >&2
  exit 2
fi
[ -f "$ARCHIVE_PATH" ] || fail "archive not found"

if [ "$TO_LIVE" = "1" ]; then
  refuse "live restore is not implemented in Phase 3; restore to a separate target and promote manually after verification"
fi
TARGET_PATH="${2:-$(mktemp -t coordinator-restored.XXXXXX).db}"

archive_base=$(basename "$ARCHIVE_PATH")
case "$archive_base" in
  coordinator-audit-*) refuse "audit archive cannot be restored as the primary archive; pass the matching coordinator-*.db.gz archive instead" ;;
esac

default_audit_db_path_for() {
  local primary_path="$1"
  local primary_dir
  primary_dir=$(dirname "$primary_path")
  if [ "$primary_dir" = "." ] || [ -z "$primary_dir" ]; then
    printf 'coordinator-audit.db\n'
  else
    printf '%s/coordinator-audit.db\n' "$primary_dir"
  fi
}

if [ -z "$COORDINATOR_AUDIT_DB_PATH" ]; then
  COORDINATOR_AUDIT_DB_PATH=$(default_audit_db_path_for "$TARGET_PATH")
fi

need_tool sqlite3
need_tool gzip
if command -v sha256sum >/dev/null 2>&1; then
  CHECKSUM_CMD="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
  CHECKSUM_CMD="shasum -a 256"
else
  fail "neither sha256sum nor shasum found"
fi

check_archive_checksum() {
  local archive_path="$1"
  [ "$SKIP_CHECKSUM" = "1" ] && return 0

  CHECKSUM_FILE="${archive_path}.sha256"
  [ -f "$CHECKSUM_FILE" ] || fail "checksum sidecar missing"
  archive_base=$(basename "$archive_path")
  sidecar_base=$(awk '{print $NF}' "$CHECKSUM_FILE" | head -1)
  if [ "$sidecar_base" != "$archive_base" ]; then
    log "ERROR: checksum sidecar filename does not match archive"
    exit 5
  fi
  archive_dir=$(dirname "$archive_path")
  ( cd "$archive_dir" && $CHECKSUM_CMD -c "$(basename "$CHECKSUM_FILE")" >/dev/null ) || {
    log "ERROR: checksum mismatch"
    exit 5
  }
}

paired_audit_archive_for() {
  local archive_path="$1"
  local archive_dir archive_base suffix candidate
  archive_dir=$(dirname "$archive_path")
  archive_base=$(basename "$archive_path")
  case "$archive_base" in
    coordinator-audit-*) return 0 ;;
    coordinator-*.db.gz)
      suffix=${archive_base#coordinator-}
      candidate="$archive_dir/coordinator-audit-$suffix"
      [ -f "$candidate" ] && printf '%s\n' "$candidate"
      return 0
      ;;
  esac
}

TMP_DIR=$(mktemp -d -t coordinator-restore.XXXXXX)
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

restore_archive_to_temp() {
  local archive_path="$1"
  local tmp_db="$2"

  check_archive_checksum "$archive_path"

  case "$archive_path" in
    *.gz) gzip -dc "$archive_path" >"$tmp_db" || fail "gzip decompress failed" ;;
    *.db) cp "$archive_path" "$tmp_db" || fail "copy failed" ;;
    *) fail "unknown archive extension; expected .gz or .db" ;;
  esac

  integrity=$(sqlite3 "$tmp_db" "PRAGMA integrity_check;" || echo "fail")
  [ "$integrity" = "ok" ] || fail "restored DB integrity_check failed"
  fk=$(sqlite3 "$tmp_db" "PRAGMA foreign_key_check;" || echo "fail")
  [ -z "$fk" ] || fail "restored DB foreign_key_check failed"
}

AUDIT_ARCHIVE_PATH=$(paired_audit_archive_for "$ARCHIVE_PATH")
if [ -z "$AUDIT_ARCHIVE_PATH" ] && [ "$ALLOW_UNPAIRED_AUDIT_RESTORE" != "1" ]; then
  refuse "paired coordinator-audit archive missing; set ALLOW_UNPAIRED_AUDIT_RESTORE=1 only for legacy primary-only forensic restores"
fi
PRIMARY_TMP="$TMP_DIR/coordinator.db"
AUDIT_TMP="$TMP_DIR/coordinator-audit.db"
restore_archive_to_temp "$ARCHIVE_PATH" "$PRIMARY_TMP"
if [ -n "$AUDIT_ARCHIVE_PATH" ]; then
  restore_archive_to_temp "$AUDIT_ARCHIVE_PATH" "$AUDIT_TMP"
fi

install -m 0600 "$PRIMARY_TMP" "$TARGET_PATH" || fail "install failed"
if [ -n "$AUDIT_ARCHIVE_PATH" ]; then
  install -m 0600 "$AUDIT_TMP" "$COORDINATOR_AUDIT_DB_PATH" || fail "audit install failed"
fi

log "DONE restored coordinator archive"
