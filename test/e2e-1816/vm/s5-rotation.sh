#!/usr/bin/env bash
# S5 rotation and revocation (after S4). The window keeper re-signs each
# pool's staged entries into the next window, so rotation is continuous.
#   a  rotation keeping the entry, under continuous traffic: zero non-200s,
#      every attempt settles, the binding is rebound (pool_manifest_rebound)
#   b  a future-dated (pre-accepted) core that changes the entry price:
#      traffic before it activates bills the CURRENT price (never zero);
#      after it activates (rebind) traffic bills the new price
#   c  R016 attestation of the non-creator member e2e-prov-5: it binds and is
#      paid pool_operator_attested; then the attestation is removed by a later
#      core while its requests are in flight: zero credit; new requests refused
#   d  member revocation in flight (e2e-prov-5 re-attested first): zero credit
#   e  entry removal in flight (QN): in-flight attempts settle at their
#      snapshot's rates; new requests refused; binding revoked
#      pool_manifest_entry_revoked
#   f  SIGHUP reload of pool_model_pricing_bounds and provider_owner_account_ids:
#      takes effect or is refused with a clear log line
set -uo pipefail
. /root/e2e/h/vm/lib.sh; . $E2E_H/vm/lib-deploy.sh; . $E2E_H/vm/lib-scn.sh; . /root/e2e/h16/vm/lib-1816.sh
[ "$(sides)" = new/new ] && [ -n "$(pool_id Q)" ] || die "S5 needs S3"
EV=$E2E_EVIDENCE/p$PASS_ID-s5; mkdir -p "$EV"
Q=$(pool_id Q); QN=$(pool_id QN); MG=$(pmid Q gguf-g); MN=$(pmid QN mlx-n)
QH=(--header "X-MacProvider-Pool-Select:$Q" --header "X-MacProvider-Engine-Select:llamacpp")
QNH=(--header "X-MacProvider-Pool-Select:$QN")
G_RATES2="425000,106250,2160000"
common="-omit-catalog -stream-chunks 20 -nonstream-delay-ms 1500"
gargs() { echo "$common -chunk-delay-ms ${2:-100} -model-id gguf-g-model -model-hash $H_GGUF -model-hash-algorithm macprovider.gguf-file.v1 -runtime-source llamacpp_loopback -admission-key-file /root/e2e/admission-key-$1"; }
nargs() { echo "$common -chunk-delay-ms ${1:-100} -trusted-pool -model-id e2e-mlx-n -model-hash $H_MLX -model-hash-algorithm macprovider.snapshot-manifest.v1 -admission-key-file /root/e2e/admission-key-4"; }
restart_member() { fakeprov_args "$1" "$2"; systemctl restart e2e-fakeprov@$1; sleep 6; }
events_since() { csql "SELECT id, provider_id, state, reason_code, binding_scope, pool_manifest_version FROM model_admission_events WHERE provider_id='$1' AND id > $2 ORDER BY id"; }
max_event() { csql "SELECT COALESCE(MAX(id),0) FROM model_admission_events"; }
# reoffer_5: runbook section 4 "after the new window is active, the member
# submits (or keeps) its offer and restarts serve so its session re-evaluates it".
reoffer_5() {
  systemctl restart e2e-fakeprov@5; sleep 6
  /opt/macprovider/e2e-fakeprov offer -coord-http http://127.0.0.1:8444 -provider-id e2e-prov-5 -token-file /root/e2e/token-e2e-prov-5 \
    -admission-key-file /root/e2e/admission-key-5 -runtime-source llamacpp_loopback -served-model-ref gguf-g-model -catalog-key "" \
    -artifact-hash-algorithm macprovider.gguf-file.v1 -artifact-hash $H_GGUF -out "$EV/$1.json" >"$EV/$1.txt" 2>&1
  sleep 3
}
# sign_change <pool> <label>: sign the staged change now; echo its version.
sign_change() {
  local out; out="$($PM manifest "$1" 2>&1)"; echo "$out" >"$EV/$2.manifest.txt"
  echo "$out" | sed -n 's/^accepted v\([0-9]*\) .*/\1/p'
}
# at_boundary <pool> <version> <lead-s>: sleep until <lead-s> before that window starts.
at_boundary() {
  local nb now; nb="$($PM window "$1" "$2" | cut -d' ' -f1)"; now=$(date +%s)
  [ -n "$nb" ] && [ $((nb - $3)) -gt "$now" ] && sleep $((nb - $3 - now))
  echo "$nb"
}

# ---- a. rotation keeping the entry, continuous traffic ----------------------------------
e0="$(max_event)"
run="$(run_id s5rot)"; rm -f "$E2E_EVIDENCE/$run.load.jsonl" "$EV/rot.stop"
python3 $E2E_H16/tools/probe-loop.py --run "$run" --out "$E2E_EVIDENCE/$run.load.jsonl" --model "$MG" "${QH[@]}" --interval 1 \
  --duration $((POOL_WINDOW_S + 75)) >/dev/null 2>&1
nonok="$(python3 -c 'import json,sys;r=[json.loads(l) for l in open(sys.argv[1])];print(len(r), sum(1 for x in r if x.get("status")!=200), sorted({str(x.get("status",x.get("error")))[:60] for x in r if x.get("status")!=200}))' "$E2E_EVIDENCE/$run.load.jsonl")"
events_since e2e-prov-3 "$e0" >"$EV/rot-events.txt"
grep -q 'pool_manifest_rebound' "$EV/rot-events.txt" && rb=yes || rb=no
set -- $nonok
[ "$2" = 0 ] && [ $rb = yes ] && result S5-rotation-no-gap PASS "$1 requests across a window boundary, 0 non-200; pool_manifest_rebound recorded" \
  || result S5-rotation-no-gap FAIL "requests/non-200: $nonok; rebound=$rb ($(tr '\n' ' ' <"$EV/rot-events.txt" | head -c 300))"
pool_check S5-rotation-settles "$run" --expect ns=settled --pool-model-id "$MG" --rates $G_RATES --usage-source pool_operator_attested --provider e2e-prov-3

# ---- b. future-dated price change -------------------------------------------------------------
$PM stage Q --rates gguf-g $G_RATES2 >/dev/null
v="$(sign_change Q price)"
[ -n "$v" ] || result S5-future-core FAIL "the price-change core was not accepted: $(cat "$EV/price.manifest.txt")"
nb="$($PM window Q "$v" | cut -d' ' -f1)"
result S5-future-core INFO "price change pre-accepted as v$v, not_before in $((nb - $(date +%s))) s"
run="$(run_id s5pre)"
pool_traffic "$run" Q "$MG" llamacpp "ns=2,st=2" 2
pool_check S5-future-core-current-price "$run" --expect ns=settled,st=settled --min-settled 4 --pool-model-id "$MG" --rates $G_RATES \
  --usage-source pool_operator_attested --provider e2e-prov-3
wait_window Q "$v"; sleep 5
run="$(run_id s5post)"
pool_traffic "$run" Q "$MG" llamacpp "ns=2,st=2" 2
pool_check S5-future-core-new-price "$run" --expect ns=settled,st=settled --min-settled 4 --pool-model-id "$MG" --rates $G_RATES2 \
  --usage-source pool_operator_attested --provider e2e-prov-3
G_RATES=$G_RATES2

# ---- c. R016 attestation, then its removal in flight ------------------------------------------
e0="$(max_event)"
$PM stage Q --attest "$MEMBER_ACCT=llamacpp_loopback" >/dev/null
v="$(sign_change Q attest)"; wait_window Q "$v"; sleep 5
reoffer_5 offer-5-attested
events_since e2e-prov-5 "$e0" >"$EV/attest-events.txt"
grep -q '|catalog_priced|pool_manifest_\(re\)\?bound|pool|' "$EV/attest-events.txt" \
  && result S5-attested-member-binds PASS "$(tail -1 "$EV/attest-events.txt")" \
  || result S5-attested-member-binds FAIL "e2e-prov-5 not bound after its owner account was attested: $(tr '\n' ' ' <"$EV/attest-events.txt" | head -c 300)"
systemctl stop e2e-fakeprov@3; sleep 3
run="$(run_id s5att)"
pool_traffic "$run" Q "$MG" llamacpp "ns=2,st=2" 1
pool_check S5-attested-member-paid "$run" --expect ns=settled,st=settled --min-settled 4 --pool-model-id "$MG" --rates $G_RATES \
  --usage-source pool_operator_attested --token-source pool_operator_attested --provider e2e-prov-5
restart_member 5 "$(gargs 5 1000)"       # 20 chunks x 1 s: streams span the boundary
$PM stage Q --unattest "$MEMBER_ACCT" >/dev/null
v="$(sign_change Q unattest)"
nb="$(at_boundary Q "$v" 8)"
run="$(run_id s5unatt)"
pool_traffic "$run" Q "$MG" llamacpp "st=2" 2 &
bg=$!; sleep 25; wait $bg
pool_check S5-attestation-removed-inflight "$run" --zero-credit
run="$(run_id s5unattnew)"
pool_traffic "$run" Q "$MG" llamacpp "ns=1,st=1" 1
pool_check S5-attestation-removed-new-refused "$run" --refused

# ---- d. member revocation in flight (re-attest first) ------------------------------------------
$PM stage Q --attest "$MEMBER_ACCT=llamacpp_loopback" >/dev/null
v="$(sign_change Q reattest)"; wait_window Q "$v"; sleep 5
reoffer_5 offer-5-reattested
run="$(run_id s5rev)"
pool_traffic "$run" Q "$MG" llamacpp "st=2" 2 &
bg=$!; sleep 5
$PM event Q member_revoked --provider-id e2e-prov-5 >"$EV/member-revoked.txt" 2>&1
wait $bg
result S5-member-revoked-event INFO "$(head -c 200 "$EV/member-revoked.txt")"
pool_check S5-member-revoked-inflight "$run" --zero-credit
run="$(run_id s5revnew)"
pool_traffic "$run" Q "$MG" llamacpp "ns=1,st=1" 1
pool_check S5-member-revoked-new-refused "$run" --refused
restart_member 5 "$(gargs 5)"
systemctl start e2e-fakeprov@3; wait_providers 5 || true; sleep 5

# ---- e. entry removal in flight (QN) -------------------------------------------------------------
e0="$(max_event)"
restart_member 4 "$(nargs 1000)"
$PM stage QN --remove mlx-n >/dev/null
v="$(sign_change QN remove)"
nb="$(at_boundary QN "$v" 8)"
run="$(run_id s5rm)"
pool_traffic "$run" QN "$MN" "" "st=2" 2 &
bg=$!; sleep 25; wait $bg
pool_check S5-entry-removed-inflight-settles "$run" --expect st=settled --min-settled 2 --pool-model-id "$MN" --rates $N_RATES \
  --usage-source coordinator_observed --provider e2e-prov-4
run="$(run_id s5rmnew)"
pool_traffic "$run" QN "$MN" "" "ns=1,st=1" 1
pool_check S5-entry-removed-new-refused "$run" --refused
events_since e2e-prov-4 "$e0" >"$EV/remove-events.txt"
grep -q 'pool_manifest_entry_revoked' "$EV/remove-events.txt" && result S5-entry-removed-binding-revoked PASS "$(grep pool_manifest_entry_revoked "$EV/remove-events.txt" | tail -1)" \
  || result S5-entry-removed-binding-revoked FAIL "no pool_manifest_entry_revoked for e2e-prov-4: $(tr '\n' ' ' <"$EV/remove-events.txt" | head -c 300)"
restart_member 4 "$(nargs)"

# ---- f. SIGHUP reload of the bounds and the owner accounts ------------------------------------
cp /opt/macprovider/coordinator.yaml "$EV/coordinator.yaml.pre-hup"
coord_yaml_edit "c['trusted_pools']['pool_model_pricing_bounds']['max_completion_rate_per_mtok'] = 50000; c['trusted_pools']['provider_owner_account_ids'] = {'acct-e2e-1816-other': ['e2e-prov-5']}"
since="$(mark)"
kill -HUP "$(systemctl show -p MainPID --value macprovider-coordinator)"; sleep 4
journal_since macprovider-coordinator "$since" "$EV/hup.log"
coord_healthz >/dev/null 2>&1 || result S5-sighup FAIL "coordinator not healthy after SIGHUP"
cp /root/e2e/pools16/QN/pool-models.json "$EV/hup-entry.json"
python3 - "$EV/hup-entry.json" "$QN" "$H_MLX2" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
m["model_entries"].append({"pool_model_id": "pool/%s/mlx-hup" % sys.argv[2], "artifact_hash_algorithm": "macprovider.snapshot-manifest.v1",
    "artifact_hash": sys.argv[3], "allowed_runtime_sources": ["mlx_cache"], "license": "Apache-2.0", "paid_serving_attested": True,
    "pricing": {"prompt_rate_per_mtok": 30000, "prompt_cache_hit_rate_per_mtok": 7500, "completion_rate_per_mtok": 60000},
    "disclosure_class": "pool_attested_unverified", "max_context_tokens": 8192})
json.dump(m, open(sys.argv[1], "w"))
PY
out="$($PM manifest QN --models-file "$EV/hup-entry.json" 2>&1)"; echo "$out" >"$EV/hup-manifest.txt"
reload_lines="$(grep -i 'reload' "$EV/hup.log" | tr '\n' ' ' | head -c 400)"
if echo "$out" | grep -q pool_model_pricing_out_of_bounds; then
  result S5-sighup-bounds PASS "after SIGHUP the tightened bounds apply: completion 60000 > new max 50000 refused ($reload_lines)"
elif grep -qi 'pool_model_pricing_bounds.*\(restart\|reject\|refus\)\|reload rejected' "$EV/hup.log"; then
  result S5-sighup-bounds PASS "reload refused clearly: $reload_lines"
else
  result S5-sighup-bounds FAIL "bounds change silently ignored on SIGHUP: entry at completion 60000 (new max 50000) $(echo "$out" | head -c 120); reload log: $reload_lines"
fi
grep -qi 'provider_owner_account_ids' "$EV/hup.log" && result S5-sighup-owner-accounts PASS "$(grep -i provider_owner_account_ids "$EV/hup.log" | head -1 | head -c 300)" \
  || result S5-sighup-owner-accounts FAIL "provider_owner_account_ids change on SIGHUP neither applied nor refused in the log ($reload_lines)"
install -o root -g root -m 0644 "$EV/coordinator.yaml.pre-hup" /opt/macprovider/coordinator.yaml
coord_restart || die "coordinator did not restart after S5"
wait_providers 5 || true
