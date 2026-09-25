#!/usr/bin/env bash
# Tier E2 (#1693 pricing lane) on a real "fake Pearl" Lima VM. Rerunnable end to end:
#
#   test/e2e-pricing/run-all.sh            # everything, in order
#   test/e2e-pricing/run-all.sh V1 V4      # just those scenarios (world must exist)
#
# Order: 00 VM + keys -> 01 scratch repo (bare origin, test identities, tags) ->
# 02 linux builds + release-asset stand-ins -> 03 host bootstrap -> 04 seed the
# pre-#1693 world with the real pre-#1693 deploy -> 04b V2d -> 05 the enabling
# rollout per the runbook -> scenarios V1 V10 V4 V6(+V7) V5 V2 V8 V9 V11 V12 V3.
# Results: $E2E_EVIDENCE/results.jsonl (E2E_RUN=<name> -> evidence-<name>/) (one JSON line per assertion);
# logs: $E2E_WORK/logs/. Nothing touches production; see env.sh and bin/.
# Workarounds for bugs found by the first E2 run (fixed in tree; each script
# detects the fix and does nothing on a fixed tree):
#   E2E_NO_GATE_WORKAROUND=1   never apply lib/workaround-gate-trust-root.sh
#   E2E_NO_CANARY_WORKAROUND=1 (set before 01) never patch the step-8 canary
#                              comparator, not even on the pre-#1693 base
# V1R is a re-runnable happy path for an existing world (V1's spec is one-shot).
set -uo pipefail
H="$(cd "$(dirname "$0")" && pwd -P)"
. "$H/env.sh"
export COPYFILE_DISABLE=1
step() { e2e_log "=== $1"; bash "$H/$1" "${@:2}" || e2e_log "=== $1 exited $?"; }
if [ $# -eq 0 ]; then
  # Fresh world: 00b wipes the VM host back to the post-00 layout (the VM
  # itself is kept), 01 recreates the scratch repo and origin from E2E_BRANCH_HEAD.
  step 00-setup-vm.sh && step 00b-reset-host.sh && step 00-setup-vm.sh && step 01-scratch-repo.sh &&
    (cd "$H/fakeprov" && bash build.sh) && step 02-build.sh &&
    step 03-bootstrap-host.sh && step 04-seed-pre-1693.sh && step 04b-pre1693-preflight.sh && step 05-enabling-rollout.sh &&
    step lib/workaround-gate-trust-root.sh
  set -- V1 V10 V4 V6 V5 V2 V8 V9 V11 V12 V3
fi
for v in "$@"; do
  case "$v" in
    V1) step scenarios/v01-happy-path.sh ;;
    V1R) step scenarios/v01r-rerun-happy-path.sh ;;
    V2) step scenarios/v02-preflight-nogo.sh; step scenarios/v02b-request-log-names.sh ;;
    V3) step scenarios/v03-ack-and-new-names.sh ;;
    V4) step scenarios/v04-kill-lane.sh ;;
    V5) step scenarios/v05-power-off.sh ;;
    V6|V7) step scenarios/v06-lease-loss-and-writers.sh ;;
    V8) step scenarios/v08-evidence-failures.sh ;;
    V9) step scenarios/v09-deploy-conflict.sh ;;
    V10) step scenarios/v10-runtime-floor.sh ;;
    V11) step scenarios/v11-renewal-and-content.sh ;;
    V12) step scenarios/v12-wholesale.sh ;;
    *) e2e_log "unknown scenario $v" ;;
  esac
done
python3 - "$E2E_EVIDENCE/results.jsonl" <<'PY'
import json, sys, collections
c = collections.Counter()
for l in open(sys.argv[1]):
    r = json.loads(l); c[(r["scenario"], r["result"])] += 1
for (s, r), n in sorted(c.items()): print("%-18s %-5s %d" % (s, r, n))
PY
