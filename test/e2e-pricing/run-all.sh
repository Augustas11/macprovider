#!/usr/bin/env bash
# Tier E2 (#1693 pricing lane) on a real "fake Pearl" Lima VM. Rerunnable end to end:
#
#   test/e2e-pricing/run-all.sh            # everything, in order
#   test/e2e-pricing/run-all.sh V1 V4      # just those scenarios (world must exist)
#
# Order: 00 VM + keys -> 01 scratch repo (bare origin, test identities, tags) ->
# 02 linux builds + release-asset stand-ins -> 03 host bootstrap -> 04 seed the
# pre-#1693 world with the real pre-#1693 deploy -> 04b V2d -> 05 the enabling
# rollout per the runbook -> scenarios V1 V2 V4 V5 V6(+V7) V10 V3 V8 V11 V12.
# Results: $E2E_WORK/evidence/results.jsonl (one JSON line per assertion);
# logs: $E2E_WORK/logs/. Nothing touches production; see env.sh and bin/.
# Reproduce the reported product bugs instead of testing past them:
#   E2E_NO_GATE_WORKAROUND=1   skip lib/workaround-gate-trust-root.sh: every --deploy
#                              aborts under the lease (V1 fails "remote publish aborted")
#   E2E_NO_CANARY_WORKAROUND=1 (set before 01) every deploy-pearl-vps.sh fails its
#                              step-8 exact-byte canary (rate-card files omitted)
set -uo pipefail
H="$(cd "$(dirname "$0")" && pwd -P)"
. "$H/env.sh"
export COPYFILE_DISABLE=1
step() { e2e_log "=== $1"; bash "$H/$1" "${@:2}" || e2e_log "=== $1 exited $?"; }
if [ $# -eq 0 ]; then
  step 00-setup-vm.sh && step 01-scratch-repo.sh && (cd "$H/fakeprov" && bash build.sh) && step 02-build.sh &&
    step 03-bootstrap-host.sh && step 04-seed-pre-1693.sh && step 04b-pre1693-preflight.sh && step 05-enabling-rollout.sh &&
    step lib/workaround-gate-trust-root.sh
  set -- V1 V10 V4 V6 V5 V2 V8 V11 V12 V3
fi
for v in "$@"; do
  case "$v" in
    V1) step scenarios/v01-happy-path.sh ;;
    V2) step scenarios/v02-preflight-nogo.sh; step scenarios/v02b-request-log-names.sh ;;
    V3) step scenarios/v03-ack-and-new-names.sh ;;
    V4) step scenarios/v04-kill-lane.sh ;;
    V5) step scenarios/v05-power-off.sh ;;
    V6|V7) step scenarios/v06-lease-loss-and-writers.sh ;;
    V8) step scenarios/v08-evidence-failures.sh ;;
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
