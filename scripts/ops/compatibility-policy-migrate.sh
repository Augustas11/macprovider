#!/usr/bin/env bash
# Safely replace Pearl's legacy exact compatibility allowlist with a
# version-floor policy.  This is deliberately a one-purpose train, not a
# general config editor.
set -euo pipefail

OPS_NAME=compatibility-policy-migrate
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

HELPER="$OPS_DIR/lib/compatibility-policy.py"
FLOOR=""

usage() {
  cat <<'EOF'
Usage:
  scripts/ops/compatibility-policy-migrate.sh status --floor MAJOR.MINOR.PATCH
  scripts/ops/compatibility-policy-migrate.sh next --floor MAJOR.MINOR.PATCH
  scripts/ops/compatibility-policy-migrate.sh next --floor MAJOR.MINOR.PATCH --run

The requested floor must be no newer than every connected provider reported by
the authenticated Pearl /admin/providers inventory. `next --run` takes the
local live-ops lock and both Pearl deployment locks, preserves unrelated overlay
fields, validates the merged config, atomically swaps only the overlay, then
requires both the applied-config digest and /healthz policy to prove SIGHUP
applied the floor. It restores the old overlay if validation or postflight fails.
EOF
}

require_floor() {
  is_semver "$FLOOR" || refuse "--floor must be strict MAJOR.MINOR.PATCH"
  python3 - "$FLOOR" <<'PYVERSION' || refuse "--floor must be canonical numeric MAJOR.MINOR.PATCH"
import re, sys
value = sys.argv[1]
valid = re.fullmatch(r"(?:0|[1-9][0-9]{0,18})\.(?:0|[1-9][0-9]{0,18})\.(?:0|[1-9][0-9]{0,18})", value)
raise SystemExit(0 if valid and all(int(x) <= 2**63 - 1 for x in value.split(".")) else 1)
PYVERSION
}

remote_policy() {
  # The helper never emits YAML or environment values. Streaming avoids storing
  # local tool bytes or credentials on Pearl.
  cat "$HELPER" | pearl_ssh "python3 - inspect"
}

remote_inventory_page() {
  local suffix="$1"
  # The helper reads the running process's environment from /proc in memory;
  # neither a shell parser, argv nor a file receives OPERATOR_KEY.
  cat "$HELPER" | pearl_ssh "python3 - inventory --suffix '$suffix'"
}

inventory_proves_floor() {
  local page=0 suffix="" out="$OPS_TMP_DIR/providers"
  mkdir -p "$out"
  while :; do
    page=$((page + 1))
    [ "$page" -le 100 ] || { printf 'too many provider inventory pages\n' >&2; return 1; }
    remote_inventory_page "$suffix" > "$out/$page.json" || return 1
    local next
    next="$(python3 - "$out/$page.json" <<'PY'
import json, re, sys, urllib.parse
d=json.load(open(sys.argv[1]))
after=d.get("next_after", ""); seen=d.get("next_after_seen", "")
if not after and not seen: print("")
elif isinstance(after, str) and isinstance(seen, str) and re.fullmatch(r"[A-Za-z0-9._-]{1,256}", after) and re.fullmatch(r"[0-9TZ:.-]+", seen): print("&" + urllib.parse.urlencode({"after": after, "after_seen": seen}))
else: raise SystemExit("invalid pagination token")
PY
)" || return 1
    [ -n "$next" ] || break
    suffix="$next"
  done
  python3 - "$FLOOR" "$out" <<'PY'
import glob, json, re, sys
floor, directory = sys.argv[1:]
version = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
set_id = re.compile(r"^[A-Za-z0-9_.-]{1,64}/[A-Za-z0-9_.-]{1,100}:v([0-9]+\.[0-9]+\.[0-9]+)@[0-9a-f]{40}$")
def semver(value): return tuple(map(int, value.split(".")))
pages = [json.load(open(p)) for p in sorted(glob.glob(directory + "/*.json"), key=lambda p:int(p.rsplit("/", 1)[1].split(".")[0]))]
connected_total = None; connected = []; ids = set()
for doc in pages:
    summary = doc.get("summary") or {}
    count = summary.get("connected")
    if type(count) is not int or count < 0: raise SystemExit("inventory lacks a valid connected count")
    if connected_total is None: connected_total = count
    elif connected_total != count: raise SystemExit("connected count changed while reading paginated inventory")
    rows = doc.get("providers")
    if not isinstance(rows, list): raise SystemExit("inventory providers is not an array")
    for row in rows:
        if not isinstance(row, dict) or row.get("presence") != "connected": continue
        pid, binary, compat = row.get("provider_id"), row.get("binary_version"), row.get("compatibility_set_id")
        if not isinstance(pid, str) or not pid or pid in ids: raise SystemExit("connected provider identity is missing or duplicated")
        ids.add(pid)
        if not isinstance(binary, str) or not version.fullmatch(binary): raise SystemExit("connected provider has malformed binary_version")
        m = set_id.fullmatch(compat or "")
        if not m or m.group(1) != binary: raise SystemExit("connected provider has unknown or mismatched compatibility identity")
        connected.append(binary)
if connected_total is None or len(connected) != connected_total:
    raise SystemExit("paginated inventory is incomplete for the connected fleet")
if not connected: raise SystemExit("refusing empty connected-fleet migration proof")
if semver(floor) > min(map(semver, connected)):
    raise SystemExit("requested floor is above a connected provider version")
print(json.dumps({"connected": len(connected), "lowest_connected_version": min(connected, key=semver)}, sort_keys=True))
PY
}

gather() {
  require_floor
  OPS_SCOPE="compatibility-policy-$FLOOR"
  fact requested_minimum_version "$FLOOR"
  local policy inventory
  policy="$(remote_policy 2>"$OPS_TMP_DIR/policy.err")" || policy=""
  if [ -z "$policy" ]; then
    fact active_policy "unreadable"
    step active_policy blocked "applied policy evidence unavailable"
    set_next active_policy blocked "Read the applied Pearl compatibility policy" "" "$(tail -n 1 "$OPS_TMP_DIR/policy.err")"
    return
  fi
  fact active_policy "$(python3 - "$policy" <<'PY'
import json,sys
d=json.loads(sys.argv[1]); print(d.get("mode", ""))
PY
)"
  if [ "$(python3 - "$policy" <<'PY'
import json,sys
d=json.loads(sys.argv[1]); print("yes" if d.get("mode") == "version_floor" else "no")
PY
)" = yes ]; then
    step active_policy done "already version_floor"
    set_next done done "Compatibility policy is already migrated" ""
    return
  fi
  step active_policy done "legacy allowlist proved by applied config"
  inventory="$(inventory_proves_floor 2>"$OPS_TMP_DIR/inventory.err")" || inventory=""
  if [ -z "$inventory" ]; then
    fact connected_fleet "unreadable_or_incomplete"
    step connected_fleet blocked "cannot prove every connected provider accepts $FLOOR"
    set_next connected_fleet blocked "Read the complete authenticated connected-provider inventory" "" "$(tail -n 1 "$OPS_TMP_DIR/inventory.err")"
    return
  fi
  fact connected_fleet "$inventory"
  step connected_fleet done "$inventory"
  step migrate pending "validated legacy source and connected-fleet floor"
  set_next migrate mutate "Migrate Pearl legacy allowlist to version floor $FLOOR" "$0 _apply $FLOOR"
  next_meta migrate "docs/runbooks/pearl-coordinator-rollout.md" "none expected: SIGHUP reload; existing sessions remain connected unless explicitly revoked"
}

apply() {
  local floor="$1"
  is_semver "$floor" || die "internal invalid floor"
  [ "${MACPROVIDER_OPS_ENTRYPOINT:-}" = 1 ] ||
    refuse "_apply is internal; use '$0 next --floor $floor --run'"
  require_clean_origin_main
  [ -n "${MACPROVIDER_OPS_OWNER:-}" ] || refuse "MACPROVIDER_OPS_OWNER is unset"
  local lock_status
  lock_status="$("$OPS_DIR/live-lock.sh" status 2>/dev/null)" || refuse "live-ops lock status is unreadable"
  python3 - "$lock_status" "$MACPROVIDER_OPS_OWNER" <<'PYLOCK' || refuse "the live-ops lock is not held by MACPROVIDER_OPS_OWNER=$MACPROVIDER_OPS_OWNER"
import json, sys
d = json.loads(sys.argv[1])
raise SystemExit(0 if d.get("held") is True and d.get("stale") is False and d.get("lock", {}).get("owner") == sys.argv[2] else 1)
PYLOCK
  cat "$HELPER" | pearl_ssh "flock -n /run/lock/macprovider-pearl-updater.lock flock -n /opt/macprovider/.coordinator-deploy.lock python3 - migrate --floor '$floor'"
}

main() {
  local command="${1:-status}"; shift || true
  if [ "$command" = _apply ]; then
    apply "${1:-}"
    return
  fi
  local run=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --floor) FLOOR="${2:-}"; shift ;;
      --run) run=1 ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  case "$command" in
    status) gather; export_next; emit_status ;;
    next)
      gather
      if [ "$run" = 1 ]; then run_next; else print_next; fi
      ;;
    -h|--help|help) usage ;;
    *) usage >&2; exit 2 ;;
  esac
}
main "$@"
