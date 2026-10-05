#!/usr/bin/env bash
# Runbook section 9 step 4b manifest-history check (docs/runbooks/trusted-pool-
# production-launch.md), run exactly as written: the python block is
# extracted from the runbook, then run against copies of a lab coordinator
# database. Each case prints the runbook's VERDICT and exit code next to the
# expected one; any difference is a failure. Read-only on the lab database;
# the copies live under $LAB/tmp/check4b.
#   check4b.sh LAB    (LAB's db/coordinator.db must hold manifests that
#                      allowlist llamacpp_loopback and lmstudio_loopback or
#                      omlx_loopback, e.g. after full_run.sh)
set -uo pipefail
LAB=${1:?lab}
HERE="$(cd "$(dirname "$0")" && pwd)"
RUNBOOK="$HERE/../../../docs/runbooks/trusted-pool-production-launch.md"
D=$LAB/tmp/check4b
mkdir -p "$D"
CHECK=$D/check4b.py
awk '/^   sudo python3 - "\$COORDINATOR_DB" m8 <<.PY.$/ {on=1; next} on && /^   PY$/ {exit} on {sub(/^   /, ""); print}' "$RUNBOOK" >"$CHECK"
[ -s "$CHECK" ] || { echo "FAIL: step 4b check block not found in the runbook"; exit 1; }
SRC=$LAB/db/coordinator.db
[ -f "$SRC" ] || { echo "FAIL: no lab coordinator database at $SRC"; exit 1; }
python3 - "$SRC" "$D" <<'PY'
import sqlite3, sys, os, base64, json
src, d = sys.argv[1], sys.argv[2]
def copy(name):
    path = os.path.join(d, name)
    if os.path.exists(path):
        os.remove(path)
    t = sqlite3.connect(path)
    try:
        s = sqlite3.connect(f"file:{src}?mode=ro", uri=True)
        s.backup(t)
    except sqlite3.OperationalError:
        # a stopped, checkpointed WAL database opens read-only only as immutable
        if os.path.exists(src + "-wal"):
            raise
        s = sqlite3.connect(f"file:{src}?mode=ro&immutable=1", uri=True)
        s.backup(t)
    s.close()
    return t
def classes(payload):
    snap = base64.b64decode(json.loads(payload)["manifest_snapshot"])
    return {c for c in ("lmstudio_loopback", "omlx_loopback", "mlxlm_loopback", "ollama_loopback")
            if len(c).to_bytes(4, "big") + c.encode() in snap}
# full history as recorded by the lab run
copy("full.db").close()
# only the classes an m8 coordinator replays
t = copy("m8-only.db")
for event_id, payload in t.execute("SELECT id, payload_json FROM trustpool_events WHERE event_type = 'manifest_accepted'").fetchall():
    if classes(payload) & {"lmstudio_loopback", "omlx_loopback"}:
        t.execute("DELETE FROM trustpool_events WHERE id = ?", (event_id,))
t.commit(); t.close()
# a snapshot in an unknown format
t = copy("corrupt.db")
row = t.execute("SELECT id, payload_json FROM trustpool_events WHERE event_type = 'manifest_accepted' ORDER BY id LIMIT 1").fetchone()
p = json.loads(row[1]); p["manifest_snapshot"] = base64.b64encode(b"not-a-snapshot").decode()
t.execute("UPDATE trustpool_events SET payload_json = ? WHERE id = ?", (json.dumps(p), row[0]))
t.commit(); t.close()
# an allowlist string outside the known vocabulary (same length, so the
# snapshot stays well-formed) in the history an m8 target would replay
t = copy("unknown-class.db")
done = False
for event_id, payload in t.execute("SELECT id, payload_json FROM trustpool_events WHERE event_type = 'manifest_accepted' ORDER BY id").fetchall():
    p = json.loads(payload); snap = base64.b64decode(p["manifest_snapshot"])
    for c in ("llamacpp_loopback", "mlxlm_loopback", "ollama_loopback"):
        token = len(c).to_bytes(4, "big") + c.encode()
        if token in snap:
            fake = "x" * (len(c) - len("_loopback")) + "_loopback"
            p["manifest_snapshot"] = base64.b64encode(snap.replace(token, len(c).to_bytes(4, "big") + fake.encode())).decode()
            t.execute("UPDATE trustpool_events SET payload_json = ? WHERE id = ?", (json.dumps(p), event_id))
            done = True
            break
    if done:
        break
assert done, "no llamacpp/mlxlm/ollama allowlist in the lab history"
t.commit(); t.close()
# a snapshot with trailing bytes after a well-formed body
t = copy("trailing.db")
row = t.execute("SELECT id, payload_json FROM trustpool_events WHERE event_type = 'manifest_accepted' ORDER BY id LIMIT 1").fetchone()
p = json.loads(row[1]); p["manifest_snapshot"] = base64.b64encode(base64.b64decode(p["manifest_snapshot"]) + b"\x00").decode()
t.execute("UPDATE trustpool_events SET payload_json = ? WHERE id = ?", (json.dumps(p), row[0]))
t.commit(); t.close()
# a database without any trust-pool history
t = sqlite3.connect(os.path.join(d, "empty.db")); t.execute("CREATE TABLE IF NOT EXISTS x (y)"); t.commit(); t.close()
PY
# expected: "<verdict> <exit>" (the lab history carries no #1816 extension;
# the extension cases are pinned in Go by
# phase4-coordinator/internal/trustpool/rollback_check_runbook_test.go)
declare -a CASES=(
  "full-history-m9|$D/full.db|m9|replayable 0"
  "full-history-p1816|$D/full.db|p1816|replayable 0"
  "full-history-m8|$D/full.db|m8|STOP 1"
  "full-history-v1-only|$D/full.db|v1-only|STOP 1"
  "m8-classes-only-m8|$D/m8-only.db|m8|replayable 0"
  "m8-classes-only-v1-only|$D/m8-only.db|v1-only|STOP 1"
  "no-trustpool-history|$D/empty.db|v1-only|replayable 0"
  "unknown-snapshot-format|$D/corrupt.db|m9|STOP 2"
  "unknown-runtime-class-m9|$D/unknown-class.db|m9|STOP 1"
  "trailing-snapshot-bytes|$D/trailing.db|m9|STOP 2"
  "unknown-tier|$D/full.db|m10|STOP 2"
  "missing-database|$D/does-not-exist.db|m9|STOP 2"
)
fail=0
for c in "${CASES[@]}"; do
  IFS='|' read -r name db tier want <<<"$c"
  out=$(python3 "$CHECK" "$db" "$tier" 2>&1); rc=$?
  got="$(printf '%s\n' "$out" | sed -n 's/^VERDICT: //p') $rc"
  if [ "$got" = "$want" ]; then echo "PASS $name: $got"; else echo "FAIL $name: got '$got' want '$want'"; fail=1; fi
  printf '%s\n' "$out" | grep -v '^VERDICT' | sed 's/^/    /'
done
exit $fail
