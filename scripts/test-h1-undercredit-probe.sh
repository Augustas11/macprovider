#!/usr/bin/env bash
# Input-validation regression checks for h1-undercredit-probe.sh. START/END are
# interpolated into single-quoted sqlite literals, so malformed or impossible
# timestamps must be rejected (exit 2) before any query runs.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
probe="$root/scripts/h1-undercredit-probe.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/h1-probe-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
db="$work/empty.db"
: > "$db"

fail() {
  printf '[test-h1-undercredit-probe] ERROR: %s\n' "$*" >&2
  exit 1
}

valid_end="2026-07-11T00:00:00Z"
for bad in \
  "2026-07-04" \
  "2026-07-04T00:00:00+00:00" \
  "2026-07-04T24:00:00Z" \
  "2026-07-04T00:60:00Z" \
  "2026-02-30T00:00:00Z" \
  "2026-04-31T00:00:00Z" \
  "2025-02-29T00:00:00Z" \
  "2026-99-99T99:99:99Z" \
  "2026-07-04T00:00:00Z' OR 1=1 --" \
  $'2026-07-04T00:00:00Z\n'; do
  status=0
  bash "$probe" "$db" "$bad" "$valid_end" >/dev/null 2>"$work/err" || status=$?
  [[ "$status" == 2 ]] || fail "accepted invalid START (exit $status): $(printf '%q' "$bad")"
  status=0
  bash "$probe" "$db" "2026-07-04T00:00:00Z" "$bad" >/dev/null 2>"$work/err" || status=$?
  [[ "$status" == 2 ]] || fail "accepted invalid END (exit $status): $(printf '%q' "$bad")"
done

for window in "2026-07-11T00:00:00Z 2026-07-04T00:00:00Z" "2026-07-04T00:00:00Z 2026-07-04T00:00:00Z"; do
  read -r win_start win_end <<<"$window"
  status=0
  bash "$probe" "$db" "$win_start" "$win_end" >/dev/null 2>"$work/err" || status=$?
  [[ "$status" == 2 ]] || fail "accepted empty or reversed window (exit $status): $window"
done

# Valid instants, including a real leap day, must pass validation. The empty
# snapshot has no ledger table, so the query itself fails later with a
# non-validation error.
for good in "2026-07-04T00:00:00Z" "2024-02-29T23:59:59Z"; do
  status=0
  bash "$probe" "$db" "$good" "$valid_end" >/dev/null 2>"$work/err" || status=$?
  [[ "$status" != 2 ]] || fail "rejected valid START: $good"
  if grep -q 'h1-undercredit-probe:' "$work/err"; then
    fail "validation message emitted for valid START: $good"
  fi
done

printf '[test-h1-undercredit-probe] ok: malformed, impossible, and injection-shaped timestamps rejected\n'
