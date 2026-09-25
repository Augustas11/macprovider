#!/usr/bin/env bash
# #1690 VM e2e F-8: step 2c's in-flight guard must be able to pass without
# FORCE_RESTART. The gateway /healthz has no in-flight metric, so the guard
# falls back to counting in-flight reservations in the live gateway DB.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_SH="$SCRIPT_DIR/../deploy-pearl-vps.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

bash -n "$DEPLOY_SH"

command -v sqlite3 >/dev/null 2>&1 || fail "sqlite3 is required for this test"

sql_line="$(grep -E '^INFLIGHT_SQL=' "$DEPLOY_SH" || true)"
[ -n "$sql_line" ] || fail "step 2c has no gateway-DB in-flight fallback (INFLIGHT_SQL)"
eval "$sql_line"

guard_line="$(grep -n 'if \[ "${INFLIGHT}" = "unknown" \] && \[ "${FORCE_RESTART:-0}" != "1" \]' "$DEPLOY_SH" | head -n1 | cut -d: -f1)"
fallback_line="$(grep -n 'sqlite3 -readonly' "$DEPLOY_SH" | head -n1 | cut -d: -f1)"
[ -n "$guard_line" ] && [ -n "$fallback_line" ] && [ "$fallback_line" -lt "$guard_line" ] ||
  fail "the gateway-DB fallback must run before the unknown-metric refusal (fallback=$fallback_line guard=$guard_line)"
grep -q 'INFLIGHT_SQL\\"" 2>/dev/null) || INFLIGHT="unknown"' "$DEPLOY_SH" ||
  fail "a failed gateway-DB query must stay unknown (fail closed)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
db="$work/gateway.db"
future="$(date -u -v+10M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+10 minutes' +%Y-%m-%dT%H:%M:%SZ)"
past="2000-01-01T00:00:00Z"
sqlite3 "$db" "
CREATE TABLE quota_reservations (
  account_id TEXT NOT NULL, request_id TEXT NOT NULL, status TEXT NOT NULL,
  settlement_hold INTEGER NOT NULL DEFAULT 0, expires_at TEXT NOT NULL,
  PRIMARY KEY (account_id, request_id));
INSERT INTO quota_reservations VALUES ('a', 'in-flight-1', 'active', 0, '$future');
INSERT INTO quota_reservations VALUES ('a', 'in-flight-2', 'active', 0, '$future');
INSERT INTO quota_reservations VALUES ('a', 'held', 'active', 1, '$future');
INSERT INTO quota_reservations VALUES ('a', 'expired', 'active', 0, '$past');
INSERT INTO quota_reservations VALUES ('a', 'settled', 'settled', 0, '$future');
INSERT INTO quota_reservations VALUES ('a', 'refunded', 'refunded', 0, '$future');"

got="$(sqlite3 -readonly "$db" "$INFLIGHT_SQL")"
[ "$got" = "2" ] || fail "in-flight count=$got, want 2 (active, unheld, unexpired only)"

sqlite3 "$db" "UPDATE quota_reservations SET status = 'settled' WHERE request_id LIKE 'in-flight-%';"
got="$(sqlite3 -readonly "$db" "$INFLIGHT_SQL")"
[ "$got" = "0" ] || fail "quiet gateway in-flight count=$got, want 0 (step 2c passes without FORCE_RESTART)"

echo "PASS: gateway deploy step 2c counts in-flight requests from the live gateway DB"
