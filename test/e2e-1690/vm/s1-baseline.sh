#!/usr/bin/env bash
# S1 baseline: OLD coordinator + OLD gateway (production v1.8.193 pair), paid
# traffic: non-streaming, streaming, buyer disconnect mid-stream, and a
# non-streaming client that closes before reading. The oracle output is the
# reference shape later pairings are compared against.
set -uo pipefail
. /root/e2e/h/vm/lib.sh; . $E2E_H/vm/lib-deploy.sh; . $E2E_H/vm/lib-scn.sh
[ "$(cat /root/e2e/coordinator.side)/$(cat /root/e2e/gateway.side)" = old/old ] || die "S1 needs old/old"
run="$(run_id s1)"
traffic "$run"
settle_and_check S1-baseline "$run" --expect ns=settled,st=settled
cp "$E2E_EVIDENCE/$run.oracle.json" "$E2E_EVIDENCE/baseline-p$PASS_ID.oracle.json"
