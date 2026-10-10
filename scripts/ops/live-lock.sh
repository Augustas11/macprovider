#!/usr/bin/env bash
# Live-ops lock: one actor mutates live production at a time
# (pearl-coordinator-rollout.md rule 3, AGENTS.md hard rule 7).
#
# Usage:
#   scripts/ops/live-lock.sh acquire <owner-label> [--purpose TEXT] [--ttl-hours N] [--steal] [--bind-pid]
#   scripts/ops/live-lock.sh release <owner-label> [--force]
#   scripts/ops/live-lock.sh status
#
# The lock is a JSON file (default ~/.config/macprovider/live-ops.lock,
# override with MACPROVIDER_LIVE_LOCK):
#   {"owner", "session", "pid", "host", "acquired_at", "refreshed_at", "purpose",
#    "ttl_hours"}
#
# acquire succeeds when the lock is free or already held by the same owner
# (refreshes it). A lock held by another owner is refused, with the holder
# printed. It may be taken over only with --steal, and only once the holder's
# own TTL has passed since its last refresh (the TTL stored in the record;
# default 6h, MACPROVIDER_LIVE_LOCK_TTL_HOURS, minimum 1). An unreadable or
# unparsable lock file is refused.
#
# --bind-pid (used by the ops entrypoints' next --run) records that the lock
# belongs to the calling process. Such a lock whose pid no longer exists on
# this host is stale at once: acquire by any owner takes it over, logging the
# takeover, without --steal and without waiting for the TTL. Locks taken by
# hand (no --bind-pid) keep TTL/--steal semantics only, because their pid is
# a short-lived shell. release removes the lock only for its
# owner unless --force (which prints the holder it removed).
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
steal=0
bindpid=0
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
    --bind-pid) bindpid=1 ;;
    --steal) steal=1 ;;
    *) echo "live-lock: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
case "$TTL_HOURS" in ""|*[!0-9]*|0*) echo "live-lock: TTL hours must be a positive integer without leading zeros" >&2; exit 2 ;; esac
case "$owner" in *[!A-Za-z0-9._@:/+-]*) echo "live-lock: owner label may use only [A-Za-z0-9._@:/+-]" >&2; exit 2 ;; esac

mkdir -p "$(dirname "$LOCK_PATH")"
chmod 700 "$(dirname "$LOCK_PATH")" 2>/dev/null || true

session="${MACPROVIDER_OPS_SESSION:-${CLAUDE_SESSION_ID:-${CODEX_SESSION_ID:-unknown}}}"

exec python3 - "$cmd" "$LOCK_PATH" "$TTL_HOURS" "$owner" "$purpose" "$force" "$session" "$PPID" "$steal" "$bindpid" <<'PY'
import datetime, fcntl, json, os, socket, sys

cmd, path, ttl_hours, owner, purpose, force, session, pid, steal, bindpid = sys.argv[1:11]
now = datetime.datetime.now(datetime.timezone.utc)
fmt = "%Y-%m-%dT%H:%M:%SZ"

def parse(ts):
    return datetime.datetime.strptime(ts, fmt).replace(tzinfo=datetime.timezone.utc)

def holder_line(rec):
    return "held by owner=%s session=%s pid=%s host=%s since %s (refreshed %s, ttl %sh) purpose=%s" % (
        rec.get("owner"), rec.get("session"), rec.get("pid"), rec.get("host"),
        rec.get("acquired_at"), rec.get("refreshed_at"), rec.get("ttl_hours", "?"), rec.get("purpose") or "-")

# Serialize read-modify-write through a sidecar mutex.
mutex = open(path + ".mutex", "a")
fcntl.flock(mutex, fcntl.LOCK_EX)

rec = None
unreadable = False
if os.path.exists(path):
    try:
        rec = json.load(open(path))
        if not isinstance(rec, dict) or not rec.get("owner"):
            raise ValueError("no owner")
        parse(rec.get("refreshed_at") or rec["acquired_at"])
        int(rec.get("ttl_hours", ttl_hours))
    except Exception:
        unreadable = True

def stale(r):
    """True once the holder's own TTL has passed since its last refresh."""
    holder_ttl = datetime.timedelta(hours=int(r.get("ttl_hours", ttl_hours)))
    return now - parse(r.get("refreshed_at") or r["acquired_at"]) > holder_ttl

def pid_dead(r):
    """True when a pid-bound lock's holder process is gone from this host."""
    if not r.get("pid_bound") or r.get("host") != socket.gethostname().split(".")[0]:
        return False
    try:
        os.kill(int(r["pid"]), 0)
    except ProcessLookupError:
        return True
    except Exception:
        return False
    return False

def write(r):
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(r, f, indent=2, sort_keys=True)
        f.write("\n")
    os.replace(tmp, path)

if unreadable:
    if cmd == "status":
        print(json.dumps({"held": True, "unreadable": True, "path": path}))
        sys.stderr.write("live-ops lock file is unreadable; inspect %s by hand\n" % path)
        sys.exit(0)
    if cmd == "release" and force == "1":
        os.remove(path)
        sys.stderr.write("live-lock: force-removed an unreadable lock file\n")
        sys.exit(0)
    sys.stderr.write("live-lock: REFUSED: lock file %s is unreadable or unparsable; inspect it by hand\n" % path)
    sys.exit(3)

if cmd == "status":
    if rec is None:
        print(json.dumps({"held": False, "path": path}))
        sys.stderr.write("live-ops lock is free\n")
    else:
        is_stale = stale(rec)
        print(json.dumps({"held": True, "stale": is_stale, "path": path, "lock": rec}, sort_keys=True))
        sys.stderr.write("live-ops lock %s%s\n" % (holder_line(rec), " [STALE: older than its TTL]" if is_stale else ""))
    sys.exit(0)

if cmd == "acquire":
    stamp = now.strftime(fmt)
    if rec is not None and rec.get("owner") != owner:
        if pid_dead(rec):
            sys.stderr.write("live-lock: TAKING OVER lock whose holder pid is gone: %s\n" % holder_line(rec))
            rec = None
        elif not stale(rec):
            sys.stderr.write("live-lock: REFUSED: %s\n" % holder_line(rec))
            sys.exit(3)
        elif steal != "1":
            sys.stderr.write("live-lock: REFUSED: stale (past the holder's %sh TTL) but still %s; "
                             "take it over only with --steal after confirming the holder is gone\n"
                             % (rec.get("ttl_hours", ttl_hours), holder_line(rec)))
            sys.exit(3)
        else:
            sys.stderr.write("live-lock: STEALING stale lock %s\n" % holder_line(rec))
            rec = None
    if rec is None:
        rec = {"owner": owner, "acquired_at": stamp}
    rec.update({
        "session": session,
        "pid": int(pid),
        "pid_bound": bindpid == "1",
        "host": socket.gethostname().split(".")[0],
        "refreshed_at": stamp,
        "purpose": purpose or rec.get("purpose", ""),
        "ttl_hours": int(ttl_hours),
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
