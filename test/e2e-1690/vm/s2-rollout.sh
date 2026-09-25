#!/usr/bin/env bash
# S2 rollout, runbook docs/runbooks/trusted-pool-production-launch.md section 9,
# executed step by step as an operator would on Pearl.
set -uo pipefail
. /root/e2e/h/vm/lib.sh; . $E2E_H/vm/lib-deploy.sh; . $E2E_H/vm/lib-scn.sh
[ "$(cat /root/e2e/coordinator.side)/$(cat /root/e2e/gateway.side)" = old/old ] || die "S2 starts from old/old"

# --- step 0: drain ledger recovery on the OLD coordinator ---------------------
# The runbook: "let the startup/nightly ledger recovery run to completion (or
# trigger it) and confirm no request is missing its ledger row". It names no
# command for either; the operator's only trigger is a restart (startup scan),
# and the check below is ours.
since="$(mark)"
systemctl restart macprovider-coordinator
for i in $(seq 1 60); do coord_healthz >/dev/null 2>&1 && break; sleep 1; done
wait_providers 2 || true
sleep 5
journal_since macprovider-coordinator "$since" "$E2E_EVIDENCE/p$PASS_ID-s2-step0-coordinator.log"
missing="$(csql "SELECT COUNT(*) FROM request_log rl WHERE rl.status = 200 AND rl.provider_assigned_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM ledger_request_credits l WHERE l.request_id = rl.request_id)")"
grep -ci 'startup.scan\|startup_scan\|recover' "$E2E_EVIDENCE/p$PASS_ID-s2-step0-coordinator.log" >/dev/null && scanlog=yes || scanlog=no
if [ "$missing" = 0 ]; then result S2-step0-drain-recovery PASS "no 200 request_log row without a ledger row (startup-scan log lines: $scanlog)"
else result S2-step0-drain-recovery FAIL "$missing request_log 200 rows lack a ledger row after the startup scan"; fi

# --- step 1: pause pools, deploy the new coordinator, resume -------------------
pools="$(curl -fsS -H "Authorization: Bearer $(opkey)" http://127.0.0.1:8444/admin/trust-pools/pools 2>/dev/null | head -c 300 || echo 'n/a')"
result S2-step1-pools INFO "pools before the coordinator deploy (none expected on the baseline): $pools"
since="$(mark)"
coord_install new
wait_providers 2 || result S2-step1 FAIL "providers did not reconnect to the new coordinator"
journal_since macprovider-coordinator "$since" "$E2E_EVIDENCE/p$PASS_ID-s2-step1-coordinator.log"
v="$(coord_healthz)"
echo "$v" | grep -q '1.8.194' && result S2-step1-healthz PASS "new coordinator /healthz: $(echo "$v" | head -c 160)" \
  || result S2-step1-healthz FAIL "/healthz does not report the new build: $(echo "$v" | head -c 200)"
result S2-step1-updater GAP "no Pearl updater transaction to confirm: coordinator installed by the harness binary swap (see plan, harness limitation H1)"
# new coordinator + OLD gateway: must behave exactly like the baseline
run="$(run_id s2a)"
traffic "$run"
settle_and_check S2-new-coord-old-gw "$run" --expect ns=settled,st=settled
python3 $E2E_H/tools/compare-shape.py "$E2E_EVIDENCE/baseline-p$PASS_ID.oracle.json" "$E2E_EVIDENCE/$run.oracle.json" \
  && result S2-new-coord-old-gw-shape PASS "per-kind outcome shape identical to the baseline" \
  || result S2-new-coord-old-gw-shape FAIL "per-kind outcome shape differs from the baseline (see $run.shape.txt)"
probe_finality p${PASS_ID}s2a-ns >"$E2E_EVIDENCE/p$PASS_ID-s2a-probe.txt" 2>&1 || true

# --- step 2: deploy the gateway (schema v14) -----------------------------------
gw_deploy new rollout || result S2-step2-gateway-deploy FAIL "gateway deploy script failed (see logs)"
sv="$(gwsql 'SELECT MAX(version) FROM schema_migrations')"
[ "$sv" = 14 ] && result S2-step2-schema PASS "gateway schema_migrations max=14" || result S2-step2-schema FAIL "gateway schema version $sv"
run="$(run_id s2b)"
traffic "$run"
settle_and_check S2-new-new "$run" --expect ns=settled,st=settled
probe_finality p${PASS_ID}s2b-ns false >"$E2E_EVIDENCE/p$PASS_ID-s2b-probe-ns.txt" 2>&1 || true
probe_finality p${PASS_ID}s2b-st true >"$E2E_EVIDENCE/p$PASS_ID-s2b-probe-st.txt" 2>&1 || true
if grep -qi 'x-macprovider-settlement-finality-mac' "$E2E_EVIDENCE/p$PASS_ID-s2b-probe-ns.txt" && grep -qi '^trailer' "$E2E_EVIDENCE/p$PASS_ID-s2b-probe-ns.txt"; then
  result S2-new-new-trailers PASS "non-streaming 200 declares finality trailers and carries a MAC"
else result S2-new-new-trailers FAIL "no MAC'd finality trailers on a negotiated non-streaming 200: $(tr '\n' ' ' <"$E2E_EVIDENCE/p$PASS_ID-s2b-probe-ns.txt" | head -c 400)"; fi

# --- step 2a: pin require_settlement_trailers ----------------------------------
gw_set coordinator.require_settlement_trailers true
gw_restart
since="$(mark)"
run="$(run_id s2c)"
traffic "$run"
sleep 3
h="$(holds_active)"
journal_since macprovider-gateway "$since" "$E2E_EVIDENCE/p$PASS_ID-s2c-gateway.log"
mh="$(grep -c 'missing_settlement_finality_trailer\|coordinator finality missing' "$E2E_EVIDENCE/p$PASS_ID-s2c-gateway.log")"
result S2-step2a-holds INFO "holds right after pinned traffic: $h; missing-finality log lines: $mh"
settle_and_check S2-pinned "$run" --expect ns=settled,st=settled
[ "$mh" = 0 ] && result S2-step2a-no-missing-finality PASS "no missing_settlement_finality_trailer with the pin on and nothing on the hop" \
  || result S2-step2a-no-missing-finality FAIL "$mh missing-finality holds with an untouched hop"
