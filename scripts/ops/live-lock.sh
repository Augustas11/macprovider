#!/usr/bin/env bash
# Live-ops lock: one actor mutates live production at a time
# (pearl-coordinator-rollout.md rule 3, AGENTS.md hard rule 7).
#
# Usage:
#   scripts/ops/live-lock.sh acquire <owner-label> [--purpose TEXT] [--ttl-hours N]
#   scripts/ops/live-lock.sh release <owner-label> [--force]
#   scripts/ops/live-lock.sh status
#
# The lock is a JSON file (default ~/.config/macprovider/live-ops.lock,
# override with MACPROVIDER_LIVE_LOCK):
#   {"owner", "session", "pid", "host", "acquired_at", "refreshed_at", "purpose"}
#
# acquire succeeds when the lock is free, already held by the same owner
# (refreshes it), or held by another owner whose last refresh is older than the
# TTL (default 6h, MACPROVIDER_LIVE_LOCK_TTL_HOURS). Otherwise it refuses and
# prints the holder. release removes the lock only for its owner unless
# --force (which prints the holder it removed).
#
# The session id comes from MACPROVIDER_OPS_SESSION, CLAUDE_SESSION_ID or
# CODEX_SESSION_ID. The lock is local to this machine: it serializes agents
# that share an operator Mac, not agents on other machines.
#
# Exit codes: 0 ok, 2 usage, 3 refused (held by another owner / not owner).
set -euo pipefail

LOCK_PATH="${MACPROVIDER_LIVE_LOCK:-$HOME/.config/macprovider/live-ops.lock}"
TTL_HOURS="${MACPROVIDER_LIVE_LOCK_TTL_HOURS:-6}"

usage() { sed -n '2,/^set -euo pipefail$/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'; }

cmd="${1:-}"
[ -n "$cmd" ] || { usage >&2; exit 2; }
shift
owner=""
purpose=""
force=0
case "$cmd" in
  acquire|release)
    owner="${1:-}"
    [ -n "$owner" ] || { echo "live-lock: $cmd needs <owner-label>" >&2; exit 2; }
    shift
    ;;
  status) ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
while [ $# -gt 0 ]; do
  case "$1" in
    --purpose) purpose="${2:-}"; shift ;;
    --ttl-hours) TTL_HOURS="${2:-}"; shift ;;
    --force) force=1 ;;
    *) echo "live-lock: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
case "$TTL_HOURS" in ""|*[!0-9]*) echo "live-lock: TTL hours must be a positive integer" >&2; exit 2 ;; esac
case "$owner" in *[!A-Za-z0-9._@:/+-]*) echo "live-lock: owner label may use only [A-Za-z0-9._@:/+-]" >&2; exit 2 ;; esac

mkdir -p "$(dirname "$LOCK_PATH")"
chmod 700 "$(dirname "$LOCK_PATH")" 2>/dev/null || true

session="${MACPROVIDER_OPS_SESSION:-${CLAUDE_SESSION_ID:-${CODEX_SESSION_ID:-unknown}}}"

exec python3 - "$cmd" "$LOCK_PATH" "$TTL_HOURS" "$owner" "$purpose" "$force" "$session" "$PPID" <<'PY'
import datetime, fcntl, json, os, socket, sys

cmd, path, ttl_hours, owner, purpose, force, session, pid = sys.argv[1:9]
ttl = datetime.timedelta(hours=int(ttl_hours))
now = datetime.datetime.now(datetime.timezone.utc)
fmt = "%Y-%m-%dT%H:%M:%SZ"

def parse(ts):
    return datetime.datetime.strptime(ts, fmt).replace(tzinfo=datetime.timezone.utc)

def holder_line(rec):
    return "held by owner=%s session=%s pid=%s host=%s since %s (refreshed %s) purpose=%s" % (
        rec.get("owner"), rec.get("session"), rec.get("pid"), rec.get("host"),
        rec.get("acquired_at"), rec.get("refreshed_at"), rec.get("purpose") or "-")

# Serialize read-modify-write through a sidecar mutex.
mutex = open(path + ".mutex", "a")
fcntl.flock(mutex, fcntl.LOCK_EX)

rec = None
if os.path.exists(path):
    try:
        rec = json.load(open(path))
    except Exception:
        rec = {"owner": "<unreadable>", "refreshed_at": None}

def age(r):
    try:
        return now - parse(r.get("refreshed_at") or r.get("acquired_at"))
    except Exception:
        return None

def write(r):
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(r, f, indent=2, sort_keys=True)
        f.write("\n")
    os.replace(tmp, path)

if cmd == "status":
    if rec is None:
        print(json.dumps({"held": False, "path": path}))
        sys.stderr.write("live-ops lock is free\n")
    else:
        a = age(rec)
        stale = a is None or a > ttl
        print(json.dumps({"held": True, "stale": stale, "path": path, "lock": rec}, sort_keys=True))
        sys.stderr.write("live-ops lock %s%s\n" % (holder_line(rec), " [STALE: older than TTL]" if stale else ""))
    sys.exit(0)

if cmd == "acquire":
    stamp = now.strftime(fmt)
    if rec is not None and rec.get("owner") != owner:
        a = age(rec)
        if a is not None and a <= ttl:
            sys.stderr.write("live-lock: REFUSED: %s\n" % holder_line(rec))
            sys.exit(3)
        sys.stderr.write("live-lock: taking over stale lock (older than %sh): %s\n" % (ttl_hours, holder_line(rec)))
        rec = None
    if rec is None:
        rec = {"owner": owner, "acquired_at": stamp}
    rec.update({
        "session": session,
        "pid": int(pid),
        "host": socket.gethostname().split(".")[0],
        "refreshed_at": stamp,
        "purpose": purpose or rec.get("purpose", ""),
    })
    write(rec)
    sys.stderr.write("live-lock: acquired by %s (%s)\n" % (owner, rec["purpose"] or "-"))
    sys.exit(0)

if cmd == "release":
    if rec is None:
        sys.stderr.write("live-lock: not held\n")
        sys.exit(0)
    if rec.get("owner") != owner and force != "1":
        sys.stderr.write("live-lock: REFUSED: not the owner; %s\n" % holder_line(rec))
        sys.exit(3)
    if rec.get("owner") != owner:
        sys.stderr.write("live-lock: force-releasing lock %s\n" % holder_line(rec))
    os.remove(path)
    sys.stderr.write("live-lock: released\n")
    sys.exit(0)
PY
