#!/usr/bin/env bash
# Host driver: push the harness, start the in-VM pass driver detached
# (vm/run-passes.sh, default two full passes of chains A, B, C, each from a
# fresh bootstrap; the #1693 merge gate was "green twice"), and perform the
# one outside-the-host check S6 needs: while nginx returns 503 on the buyer
# routes, curl the forwarded 443 from the Mac. The host only runs
# limactl/ssh/curl; every build and test runs in the VM.
# Usage: run-all.sh [passes] [chains]
set -uo pipefail
. "$(dirname "$0")/env.sh"
passes="${1:-2}"; chains="${2:-ABC}"
bash "$E2E_HARNESS/02-push-harness.sh"
# systemd-run fully detaches the driver: a plain `nohup ... &` inside
# `limactl shell` keeps the session open until the passes end.
vm "systemctl reset-failed e2e-1690-passes 2>/dev/null; systemd-run --unit=e2e-1690-passes --collect -E HOME=/root -p WorkingDirectory=/root/e2e bash -c 'bash h/vm/run-passes.sh $passes $chains >/root/e2e/run-passes.out 2>&1'"
e2e_log "started in-VM run-passes ($passes passes, chains $chains); log /root/e2e/run-passes.out"
bash "$E2E_HARNESS/host-watch-s6.sh"
vm "tar -C /root/e2e -czf - evidence logs" >"$E2E_WORK/evidence.tgz"
vm "cat /root/e2e/evidence/results.jsonl" >"$E2E_WORK/results.jsonl"
python3 - "$E2E_WORK/results.jsonl" <<'PY'
import json, sys, collections
c = collections.Counter(); fails = []
for l in open(sys.argv[1]):
    r = json.loads(l); c[r["result"]] += 1
    if r["result"] in ("FAIL", "BUG"): fails.append(r)
print(dict(c))
for r in fails: print("FAIL", r["scenario"], r["detail"][:300])
PY
