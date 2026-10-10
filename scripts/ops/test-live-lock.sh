#!/usr/bin/env bash
# Behaviour of scripts/ops/live-lock.sh against a temporary lock file.
# Usage: bash scripts/ops/test-live-lock.sh
set -euo pipefail

LOCK_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/live-lock.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export MACPROVIDER_LIVE_LOCK="$tmp/live-ops.lock"
unset MACPROVIDER_LIVE_LOCK_TTL_HOURS
pass=0
fail=0

# expect RC DESCRIPTION -- COMMAND...
expect() {
  local want="$1" desc="$2" rc=0
  shift 3
  "$@" >/dev/null 2>"$tmp/err" || rc=$?
  if [ "$rc" -eq "$want" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL %s: want rc=%s got rc=%s\n' "$desc" "$want" "$rc"
    sed 's/^/    /' "$tmp/err"
  fi
}

write_lock() {
  python3 - "$MACPROVIDER_LIVE_LOCK" "$@" <<'PY'
import json, sys
path, owner, refreshed, ttl = sys.argv[1:5]
rec = {"owner": owner, "acquired_at": refreshed, "refreshed_at": refreshed}
if ttl != "-":
    rec["ttl_hours"] = int(ttl)
json.dump(rec, open(path, "w"))
PY
}

expect 0 "acquire free lock" -- bash "$LOCK_SH" acquire alice --purpose test
expect 0 "same owner refreshes" -- bash "$LOCK_SH" acquire alice
expect 3 "other owner refused" -- bash "$LOCK_SH" acquire bob
expect 3 "steal refused while fresh" -- bash "$LOCK_SH" acquire bob --steal
expect 3 "release by non-owner refused" -- bash "$LOCK_SH" release bob
expect 0 "release by owner" -- bash "$LOCK_SH" release alice
expect 2 "ttl 0 rejected" -- bash "$LOCK_SH" acquire alice --ttl-hours 0
expect 2 "ttl 00 rejected" -- bash "$LOCK_SH" acquire alice --ttl-hours 00

# Staleness is judged by the holder's stored TTL, not the caller's.
write_lock carol "$(date -u -v-3H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '-3 hours' +%Y-%m-%dT%H:%M:%SZ)" 24
expect 3 "holder ttl 24h not stale at 3h even with caller ttl 1h" -- bash "$LOCK_SH" acquire dave --ttl-hours 1 --steal
write_lock carol "$(date -u -v-3H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '-3 hours' +%Y-%m-%dT%H:%M:%SZ)" 2
expect 3 "stale lock not taken without --steal" -- bash "$LOCK_SH" acquire dave
if grep -q "holder" "$tmp/err" && grep -q "owner=carol" "$tmp/err"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL refusal does not print the holder"; fi
expect 0 "stale lock taken with --steal" -- bash "$LOCK_SH" acquire dave --steal
if grep -q "STEALING" "$tmp/err" && grep -q "owner=carol" "$tmp/err"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL steal does not print the holder"; fi
if python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["owner"]=="dave" and d["ttl_hours"]==6 else 1)' "$MACPROVIDER_LIVE_LOCK"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL record lacks owner/ttl_hours"; fi

printf '{not json' > "$MACPROVIDER_LIVE_LOCK"
expect 3 "unparsable lock refused on acquire" -- bash "$LOCK_SH" acquire erin --steal
expect 3 "unparsable lock refused on release" -- bash "$LOCK_SH" release erin
expect 0 "status reports unparsable lock" -- bash "$LOCK_SH" status
printf '{"owner": "x"}' > "$MACPROVIDER_LIVE_LOCK"
expect 3 "lock without timestamps refused" -- bash "$LOCK_SH" acquire erin --steal
expect 0 "force release removes an unreadable lock" -- bash "$LOCK_SH" release erin --force
expect 0 "free again" -- bash "$LOCK_SH" acquire erin

# --bind-pid: a lock whose holder pid is gone is taken over at once.
rm -f "$MACPROVIDER_LIVE_LOCK"
bash "$LOCK_SH" acquire ghost --purpose t --bind-pid 2>/dev/null
python3 - "$MACPROVIDER_LIVE_LOCK" <<'PY'
import json, subprocess, sys
p = sys.argv[1]
d = json.load(open(p))
sub = subprocess.Popen(["true"]); sub.wait()   # a pid that is certainly gone
d["pid"] = sub.pid
json.dump(d, open(p, "w"))
PY
expect 0 "dead pid-bound lock taken over by another owner without --steal" -- bash "$LOCK_SH" acquire frank
if grep -q "TAKING OVER" "$tmp/err" && grep -q "owner=ghost" "$tmp/err"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL takeover not logged with the holder"; fi
bash "$LOCK_SH" release frank 2>/dev/null
bash "$LOCK_SH" acquire ghost --bind-pid 2>/dev/null
expect 3 "live pid-bound lock (holder pid alive) still refused" -- bash "$LOCK_SH" acquire frank
python3 - "$MACPROVIDER_LIVE_LOCK" <<'PY'
import json, subprocess, sys
p = sys.argv[1]
d = json.load(open(p))
sub = subprocess.Popen(["true"]); sub.wait()
d["pid"] = sub.pid
d["pid_bound"] = False
json.dump(d, open(p, "w"))
PY
expect 3 "dead pid on a hand-taken lock is not a takeover" -- bash "$LOCK_SH" acquire frank
bash "$LOCK_SH" release ghost 2>/dev/null

printf 'live lock: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
