#!/usr/bin/env bash
# Host driver for the #1816 VM acceptance run:
#   E2E_NEW_REF=<commit-ish> bash test/e2e-1816/run-all.sh [passes] [steps]
# 00 (VM up) -> 01 (both trees into the VM) -> 02 (harness into the VM) ->
# the in-VM pass driver, detached (vm/run-passes.sh; builds, bootstrap and
# scenarios all run in the VM) -> wait -> evidence to $E2E_WORK. The host runs
# limactl, git archive and file copies only.
set -uo pipefail
. "$(dirname "$0")/env.sh"
passes="${1:-2}"; steps="${2:-B1 B2 S1 S2 S3 S4 S5 S6}"
bash "$E2E_HARNESS/00-setup-vm.sh" || e2e_die "VM setup failed"
bash "$E2E_HARNESS/01-sources.sh" || e2e_die "sources failed"
bash "$E2E_HARNESS/02-push-harness.sh" || e2e_die "harness push failed"
vm "rm -f /root/e2e/run-passes-1816.out; systemctl reset-failed e2e-1816-passes 2>/dev/null; systemd-run --unit=e2e-1816-passes --collect -E HOME=/root -p WorkingDirectory=/root/e2e bash -c 'bash h16/vm/run-passes.sh $passes \"$steps\" >/root/e2e/run-passes-1816.out 2>&1'"
e2e_log "started in-VM run-passes ($passes passes: $steps); log /root/e2e/run-passes-1816.out"
while ! vm "grep -q 'ALL-PASSES-DONE\|RUN-PASSES-ABORTED' /root/e2e/run-passes-1816.out" 2>/dev/null; do sleep 30; done
e2e_log "in-VM run finished: $(vm "tail -1 /root/e2e/run-passes-1816.out")"
vm "tar -C /root/e2e -czf - evidence logs" >"$E2E_WORK/evidence.tgz"
vm "cat /root/e2e/evidence/results.jsonl" >"$E2E_WORK/results.jsonl"
python3 - "$E2E_WORK/results.jsonl" <<'PY'
import json, sys, collections
c = collections.Counter(); fails = []
for l in open(sys.argv[1]):
    r = json.loads(l); c[r["result"]] += 1
    if r["result"] in ("FAIL", "BUG", "GAP"): fails.append(r)
print(dict(c))
for r in fails: print(r["result"], r["scenario"], r["detail"][:300])
PY
