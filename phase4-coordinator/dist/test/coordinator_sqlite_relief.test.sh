#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RELIEF="$SCRIPT_DIR/../coordinator-sqlite-relief.sh"
TMP="$(umask 077 && mktemp -d -t coordinator-sqlite-relief-test.XXXXXXXX)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[ -f "$RELIEF" ] || fail "missing relief script"

DB="$TMP/coordinator.db"
SQL_CAPTURE="$TMP/sql.txt"
touch "$DB"
mkdir -p "$TMP/bin"
cat >"$TMP/bin/sqlite3" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = "$MACPROVIDER_TEST_DB" ] || exit 11
cat > "$MACPROVIDER_TEST_SQL_CAPTURE"
SH
chmod +x "$TMP/bin/sqlite3"

PATH="$TMP/bin:$PATH" \
  MACPROVIDER_TEST_DB="$DB" \
  MACPROVIDER_TEST_SQL_CAPTURE="$SQL_CAPTURE" \
  "$RELIEF" "$DB"

grep -q "PRAGMA busy_timeout=5000;" "$SQL_CAPTURE" || fail "busy timeout pragma missing"
grep -q "PRAGMA wal_checkpoint(PASSIVE);" "$SQL_CAPTURE" || fail "passive checkpoint missing"
grep -q "request_log" "$SQL_CAPTURE" || fail "hot table schema prewarm missing"
if grep -qi "synchronous *( *NORMAL" "$SQL_CAPTURE"; then
  fail "script weakened SQLite synchronous durability"
fi

if "$RELIEF" "$TMP/missing.db" >"$TMP/out.txt" 2>"$TMP/err.txt"; then
  fail "missing DB unexpectedly succeeded"
fi
grep -q "not found" "$TMP/err.txt" || fail "missing DB error not clear"
if grep -q "$TMP/missing.db" "$TMP/err.txt"; then
  fail "missing DB error printed operator path"
fi

echo "coordinator sqlite relief script tests passed"
