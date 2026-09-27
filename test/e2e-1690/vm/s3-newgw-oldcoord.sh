#!/usr/bin/env bash
# S3 reversed pairing: NEW gateway (schema v14) + OLD coordinator. The
# runbook says it settles as the baseline (header finality, no trailers).
# Also: the same pairing with the pin ON, which the runbook says holds every
# 200 (the old coordinator signs nothing); every hold must still terminate.
set -uo pipefail
. /root/e2e/h/vm/lib.sh; . $E2E_H/vm/lib-deploy.sh; . $E2E_H/vm/lib-scn.sh
[ "$(cat /root/e2e/coordinator.side)/$(cat /root/e2e/gateway.side)" = old/old ] || die "S3 starts from old/old"
run="$(run_id s3base)"
traffic "$run"
settle_and_check S3-baseline-rerun "$run" --expect ns=settled,st=settled
cp "$E2E_EVIDENCE/$run.oracle.json" "$E2E_EVIDENCE/baseline3-p$PASS_ID.oracle.json"
gw_deploy new s3 || result S3-gateway-deploy FAIL "gateway deploy failed"
run="$(run_id s3a)"
traffic "$run"
settle_and_check S3-new-gw-old-coord "$run" --expect ns=settled,st=settled
python3 $E2E_H/tools/compare-shape.py "$E2E_EVIDENCE/baseline3-p$PASS_ID.oracle.json" "$E2E_EVIDENCE/$run.oracle.json" \
  && result S3-shape PASS "outcome shape identical to the old/old baseline" || result S3-shape FAIL "shape differs (see $run.shape.txt)"
# pin on against the old coordinator (documented as held): every hold must end
gw_set coordinator.require_settlement_trailers true; gw_restart
run="$(run_id s3pin)"
since="$(mark)"
traffic "$run" "ns=3,st=3"
sleep 3
h="$(holds_active)"
result S3-pin-on-old-coord INFO "holds right after traffic with the pin on vs an old coordinator: $h (runbook: every 200 held)"
DRAIN_MAX=600 settle_and_check S3-pin-on-old-coord-terminal "$run"
journal_since macprovider-gateway "$since" "$E2E_EVIDENCE/p$PASS_ID-s3pin-gateway.log"
gw_set coordinator.require_settlement_trailers false; gw_restart
