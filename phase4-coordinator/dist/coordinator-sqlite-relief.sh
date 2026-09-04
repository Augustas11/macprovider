#!/usr/bin/env bash
# Safe, manual SQLite hot-DB relief for coordinator operators.
# Runs a passive WAL checkpoint and touches hot-table schema metadata without
# changing durability pragmas or emitting credential-bearing config values.

set -euo pipefail

usage() {
  echo "usage: coordinator-sqlite-relief.sh [coordinator.db]" >&2
  echo "       or set MACPROVIDER_COORDINATOR_DB" >&2
}

DB_PATH="${1:-${MACPROVIDER_COORDINATOR_DB:-}}"
if [ -z "$DB_PATH" ]; then
  usage
  exit 2
fi
if [ "${2:-}" != "" ]; then
  usage
  exit 2
fi
if [ ! -f "$DB_PATH" ]; then
  echo "coordinator SQLite DB not found" >&2
  exit 1
fi

SQLITE3="${SQLITE3:-sqlite3}"
if ! command -v "$SQLITE3" >/dev/null 2>&1; then
  echo "sqlite3 not found" >&2
  exit 1
fi

"$SQLITE3" "$DB_PATH" <<'SQL'
PRAGMA busy_timeout=5000;
PRAGMA wal_checkpoint(PASSIVE);
SELECT name
  FROM sqlite_schema
 WHERE type = 'table'
   AND name IN (
     'request_log',
     'audit_log',
     'ledger_request_credits',
     'ledger_provider_earnings',
     'ledger_payout_ready'
   )
 ORDER BY name;
SQL
