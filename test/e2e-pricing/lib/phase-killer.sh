#!/usr/bin/env bash
# Runs ON the VM (root). Waits for the pricing journal to reach <phase>, then
# kill -9s every process holding the coordinator-deploy lock: the lane's lease
# runner and whatever lane command it is running (the publish script, the
# pricing helper). Together with the Mac-side kill of the lane this is "kill -9
# the lane" at that journal phase. One long-lived python process polls txn.json
# every ~2 ms (a per-poll interpreter start misses `prepared`/`mutating`).
# Writes <out>: "KILLED <phase-seen> <pids>" or "TIMEOUT <last phase>";
# <out>.trace lists every phase seen.
# Usage: phase-killer.sh <phase> <out> [timeout-s]
exec python3 - "$@" <<'PY'
import json, os, signal, subprocess, sys, time
want, out = sys.argv[1], sys.argv[2]
limit = float(sys.argv[3]) if len(sys.argv) > 3 else 1500
action = os.environ.get("PHASE_ACTION", "kill")
end = time.time() + limit
last = None
trace = open(out + ".trace", "a", buffering=1)
while time.time() < end:
    try:
        p = json.load(open("/opt/macprovider/.pricing-txn/txn.json"))["phase"]
    except Exception:
        p = "none"
    if p != last:
        trace.write("%.3f phase %s\n" % (time.time(), p)); last = p
    if p == want:
        if action == "sqlite-lock":
            import sqlite3
            c = sqlite3.connect("/var/lib/macprovider/request-log.sqlite", timeout=60)
            c.execute("BEGIN EXCLUSIVE")
            open(out, "w").write("LOCKED %s\n" % p)
            time.sleep(float(os.environ.get("LOCK_SECONDS", "25")))
            c.rollback()
            sys.exit(0)
        if action == "poweroff":
            open(out, "w").write("POWEROFF %s\n" % p)
            os.sync() if False else None
            open("/proc/sys/kernel/sysrq", "w").write("1")
            open("/proc/sysrq-trigger", "w").write("o")
            time.sleep(60)
        r = subprocess.run(["fuser", "/opt/macprovider/.coordinator-deploy.lock"], capture_output=True, text=True)
        pids = [int(x) for x in r.stdout.split() if x.strip().isdigit()]
        for pid in pids:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        open(out, "w").write("KILLED %s %s\n" % (p, " ".join(map(str, pids))))
        sys.exit(0)
    time.sleep(0.002)
open(out, "w").write("TIMEOUT %s\n" % last)
PY
