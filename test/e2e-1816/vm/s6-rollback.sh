#!/usr/bin/env bash
# S6 rollback with pool-model cores present (after S5):
#   1  docs/runbooks/pool-scoped-model-admission.md section 7, in order of
#      speed: pause Q (an in-flight attempt settles from its snapshot; new
#      pool requests fail closed; catalog traffic untouched), then retire QN
#      (pause first; retired answers delivery_drain_pending until drained);
#      entry removal and member revocation ran in S5
#   2  the coordinator rollback preflight with pool-model (extension) cores in
#      the durable store: it must refuse a target coordinator that cannot
#      replay them (the S2 rollback bullet; it needs S3's cores to exist)
#   3  docs/runbooks/trusted-pool-production-launch.md section 9 rollback,
#      literally (the shared #1690 vm/s6-rollback.sh: nginx 503, drain holds,
#      pin off, gateway pre-check, coordinator preflight + binary rollback,
#      resume, no ledger row lost, traffic after)
#   4  what the rolled-back (old) coordinator does with the extension cores
set -uo pipefail
. /root/e2e/h/vm/lib.sh; . $E2E_H/vm/lib-deploy.sh; . $E2E_H/vm/lib-scn.sh; . /root/e2e/h16/vm/lib-1816.sh
[ "$(sides)" = new/new ] && [ -n "$(pool_id Q)" ] || die "S6 needs S3-S5"
EV=$E2E_EVIDENCE/p$PASS_ID-s6-pool; mkdir -p "$EV"
Q=$(pool_id Q); QN=$(pool_id QN); MG=$(pmid Q gguf-g)
GR="$(python3 -c 'import json,sys;m=json.load(open(sys.argv[1]));e=[x for x in m["model_entries"] if x["pool_model_id"].endswith("/gguf-g")][0]["pricing"];print("%d,%d,%d"%(e["prompt_rate_per_mtok"],e["prompt_cache_hit_rate_per_mtok"],e["completion_rate_per_mtok"]))' /root/e2e/pools16/Q/pool-models.json)"

# ---- 1. pause Q with one attempt in flight ----------------------------------------------------
fakeprov_args 3 "-omit-catalog -stream-chunks 20 -chunk-delay-ms 500 -nonstream-delay-ms 1500 -model-id gguf-g-model -model-hash $H_GGUF -model-hash-algorithm macprovider.gguf-file.v1 -runtime-source llamacpp_loopback -admission-key-file /root/e2e/admission-key-3 -receipt-key-file /root/e2e/receipt-key-3"
systemctl restart e2e-fakeprov@3; sleep 8
run="$(run_id s6pause)"
pool_traffic "$run" Q "$MG" llamacpp "st=1" 1 &
bg=$!; wait_run_route_snapshots "$run" 1 30 || result S6-pause-inflight-barrier FAIL "stream was not routed before pause"
$PM lifecycle Q paused >"$EV/pause.txt" 2>&1 && result S6-pool-pause PASS "set-lifecycle paused: $(head -c 120 "$EV/pause.txt")" || result S6-pool-pause FAIL "$(head -c 300 "$EV/pause.txt")"
wait $bg
pool_check S6-pause-inflight-settles "$run" --expect st=settled --min-settled 1 --pool-model-id "$MG" --rates "$GR" --usage-source pool_operator_attested --provider e2e-prov-3
run="$(run_id s6pausednew)"
pool_traffic "$run" Q "$MG" llamacpp "ns=1,st=1" 1
pool_check S6-paused-new-refused "$run" --refused
run="$(run_id s6pausedcat)"
traffic "$run" "ns=2,st=2"
settle_and_check S6-paused-catalog-untouched "$run" --expect ns=settled,st=settled
$PM lifecycle QN paused >"$EV/pause-qn.txt" 2>&1
$PM lifecycle QN retired >"$EV/retire-qn.txt" 2>&1; rrc=$?
result S6-pool-retire INFO "QN paused then retired: rc=$rrc $(head -c 300 "$EV/retire-qn.txt")"
[ $rrc = 0 ] || grep -q delivery_drain_pending "$EV/retire-qn.txt" \
  && result S6-pool-retire-accepted PASS "retire after pause: $(head -c 160 "$EV/retire-qn.txt")" \
  || result S6-pool-retire-accepted FAIL "$(head -c 300 "$EV/retire-qn.txt")"
keeper_off

# ---- 2. coordinator rollback preflight with extension cores present ----------------------------
# the snapshot is base64 in payload_json, so this counts accepted manifests, not extension cores
cores="$(csql "SELECT COUNT(*) FROM trustpool_events WHERE event_type='manifest_accepted'" 2>/dev/null || echo '?')"
with_coordinator_env /opt/macprovider/coordinator pool-rollback-preflight --config /opt/macprovider/coordinator.yaml \
  --config-overlay /etc/macprovider/coordinator.pearl-overlays.yaml --target-tier m9 >"$EV/preflight.txt" 2>&1; prc=$?
if [ $prc != 0 ] && grep -qi 'extension\|pool_model_entries\|replay' "$EV/preflight.txt"; then
  result S6-preflight-extension-cores PASS "pool-rollback-preflight refuses (rc=$prc) with pool-model extension cores present: $(head -c 300 "$EV/preflight.txt")"
else
  result S6-preflight-extension-cores FAIL "pool-rollback-preflight rc=$prc does not refuse a rollback target that cannot replay pool_model_entries/v1 cores (accepted manifests in the store: $cores): $(tr '\n' ' ' <"$EV/preflight.txt" | head -c 300)"
fi

# ---- 3. the full trusted-pool rollback (runbook s9), shared with #1690 -------------------------
since="$(mark)"
PASS_ID=$PASS_ID bash $E2E_H/vm/s6-rollback.sh

# ---- 4. the old coordinator and the extension cores ----------------------------------------------
journal_since macprovider-coordinator "$since" "$EV/coordinator-after-rollback.log"
if [ "$(cat /root/e2e/coordinator.side)" = old ]; then
  ext="$(grep -ci 'extension\|reconstruct\|trust.pool.*disabl\|registry.*disabl' "$EV/coordinator-after-rollback.log")"
  curl_bearer "$(opkey)" -s http://127.0.0.1:8444/admin/trust-pools/pools/$Q >"$EV/old-get-pool-q.json"
  curl_bearer "$(opkey)" -s http://127.0.0.1:8444/poolz >"$EV/old-poolz.json"
  result S6-old-coordinator-extension-cores INFO "old coordinator on the store with pool-model cores: $ext log lines naming extensions/reconstruct/disable ($(grep -i 'extension\|reconstruct\|trust.pool.*disabl\|registry.*disabl' "$EV/coordinator-after-rollback.log" | head -2 | tr '\n' ' ' | head -c 400)); get-pool Q: $(head -c 200 "$EV/old-get-pool-q.json")"
fi
