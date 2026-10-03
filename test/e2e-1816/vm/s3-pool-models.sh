#!/usr/bin/env bash
# S3 trusted pools on, pool-scoped models (docs/runbooks/pool-scoped-model-admission.md
# sections 0-6) on the new pair left by S2:
#   - live coordinator config: trusted_pools.enabled, pool_model_pricing_bounds
#     (runbook section 1 values), provider_owner_account_ids (+ the member's
#     provider-owner key for its delegation); gateway features.trusted_pools;
#   - pool Q (runtime_allowlist llamacpp_loopback): creator-owned member
#     e2e-prov-3, delegated non-creator member e2e-prov-5 (SPEC-043
#     ProviderPoolDelegationV1, owner account in provider_owner_account_ids, NOT
#     attested yet); entry G = a NON-catalog GGUF hash, llamacpp_loopback;
#   - pool QN (native only): member e2e-prov-4; entry N = a NON-catalog
#     snapshot-manifest hash, mlx_cache;
#   - every core signed by `coordinator-cli trust-pool-admin sign-manifest
#     --encoding 2 --pool-models` (tools/pool-models.py);
#   - fake members submit the signed model-admission offer, bind
#     catalog_priced with a pool_binding, and serve pool/<id>/<slug> traffic
#     through nginx -> gateway -> coordinator, all four request kinds;
#   - oracle (tools/pool-oracle.py): entry-price credits computed
#     independently, payable credit, usage_source/token_source/labels, I1-I4.
set -uo pipefail
. /root/e2e/h/vm/lib.sh; . $E2E_H/vm/lib-deploy.sh; . $E2E_H/vm/lib-scn.sh; . /root/e2e/h16/vm/lib-1816.sh
[ "$(sides)" = new/new ] || die "S3 needs the new pair (S2)"
EV=$E2E_EVIDENCE/p$PASS_ID-s3; mkdir -p "$EV"
FP=/opt/macprovider/e2e-fakeprov
ACCT="$(gwsql "SELECT account_id FROM accounts LIMIT 1")"

# ---- config (runbook sections 0-1) ----------------------------------------------
owner_pub="$(openssl pkey -in $K/owner-prov-5.pem -pubout -outform DER | tail -c 32 | base64)"
cp /opt/macprovider/coordinator.yaml "$EV/coordinator.yaml.pre-s3"
coord_yaml_edit "c.setdefault('trusted_pools', {}).update(enabled=True, refresh_interval_s=1, pool_model_pricing_bounds=json.loads('$BOUNDS_JSON'), provider_owner_account_ids={'$MEMBER_ACCT': ['e2e-prov-5']}, provider_owner_public_keys={'e2e-prov-5': '$owner_pub'})"
coord_restart && result S3-config PASS "trusted_pools enabled with pool_model_pricing_bounds and provider_owner_account_ids; coordinator healthy" \
  || { result S3-config FAIL "coordinator did not start with the runbook config: $(journalctl -u macprovider-coordinator -n 5 --no-pager -o cat | tr '\n' ' ' | head -c 500)"; exit 1; }
gw_set features.trusted_pools '{enabled: true, coordinator_authorizes: true}'
gw_restart

# ---- pools (entries staged into the genesis core) -----------------------------------
$PM init Q --allowlist llamacpp_loopback >"$EV/init-q.txt" 2>&1 || die "init Q: $(tail -2 "$EV/init-q.txt")"
$PM init QN --allowlist "" >"$EV/init-qn.txt" 2>&1 || die "init QN: $(tail -2 "$EV/init-qn.txt")"
$PM stage Q --add gguf-g macprovider.gguf-file.v1 $H_GGUF llamacpp_loopback $G_RATES 8192 >/dev/null
$PM stage QN --add mlx-n macprovider.snapshot-manifest.v1 $H_MLX mlx_cache $N_RATES 8192 >/dev/null
cp /root/e2e/pools16/Q/pool-models.json "$EV/pool-models-q.json"; cp /root/e2e/pools16/QN/pool-models.json "$EV/pool-models-qn.json"
for p in Q:e2e-prov-3,e2e-prov-7 QN:e2e-prov-4; do
  n=${p%%:*}; m=${p#*:}
  if $PM create $n --members $m --buyer "$ACCT" >"$EV/create-$n.txt" 2>&1; then
    result "S3-pool-$n-create" PASS "pool $(pool_id $n): approval, root, genesis core with pool_model_entries/v1 (coordinator-cli --pool-models), member $m, buyer, promote"
  else result "S3-pool-$n-create" FAIL "$(tail -3 "$EV/create-$n.txt" | tr '\n' ' ' | head -c 600)"; fi
done
$PM delegate Q --provider e2e-prov-5 --owner-key $K/owner-prov-5.pem >"$EV/delegate.txt" 2>&1 \
  && result S3-delegated-member PASS "e2e-prov-5 admitted to Q under a signed ProviderPoolDelegationV1 grant (non-creator, owner $MEMBER_ACCT)" \
  || result S3-delegated-member FAIL "$(tail -3 "$EV/delegate.txt" | tr '\n' ' ' | head -c 500)"
keeper_on
sleep 3
Q=$(pool_id Q); QN=$(pool_id QN); MG=$(pmid Q gguf-g); MN=$(pmid QN mlx-n)
echo "Q=$Q QN=$QN MG=$MG MN=$MN" >"$EV/ids.txt"
for n in Q QN; do $PM get $n >"$EV/get-pool-$n.json"; done
python3 - "$EV/get-pool-Q.json" "$EV/get-pool-QN.json" "$MG" "$MN" <<'PY' >"$EV/get-pool.check" 2>&1
import json, sys
ok = True
for f, pm in ((sys.argv[1], sys.argv[3]), (sys.argv[2], sys.argv[4])):
    p = json.load(open(f)).get("pool") or json.load(open(f))
    es = p.get("model_entries") or []
    hit = [e for e in es if e.get("pool_model_id") == pm]
    good = len(hit) == 1 and hit[0].get("disclosure_class") == "pool_attested_unverified" and p.get("settlement_mode") == "enforce"
    print(pm, "listed" if hit else "MISSING", hit[0].get("disclosure_class") if hit else "", p.get("settlement_mode"), p.get("runtime_allowlist"), p.get("manifest_core_digest", "")[:16])
    ok = ok and good
sys.exit(0 if ok else 1)
PY
[ $? = 0 ] && result S3-get-pool PASS "$(tr '\n' ';' <"$EV/get-pool.check")" || result S3-get-pool FAIL "$(tr '\n' ';' <"$EV/get-pool.check" | head -c 600)"

# ---- members: fake CLIs (no catalog envelope), signed offers ------------------------
common="-omit-catalog -stream-chunks 20 -chunk-delay-ms 100 -nonstream-delay-ms 1500"
fakeprov_args 3 "$common -model-id gguf-g-model -model-hash $H_GGUF -model-hash-algorithm macprovider.gguf-file.v1 -runtime-source llamacpp_loopback -admission-key-file /root/e2e/admission-key-3 -receipt-key-file /root/e2e/receipt-key-3"
fakeprov_args 5 "$common -model-id gguf-g-model -model-hash $H_GGUF -model-hash-algorithm macprovider.gguf-file.v1 -runtime-source llamacpp_loopback -admission-key-file /root/e2e/admission-key-5 -receipt-key-file /root/e2e/receipt-key-5"
fakeprov_args 7 "$common -model-id gguf-g-model -model-hash $H_GGUF -model-hash-algorithm macprovider.gguf-file.v1 -runtime-source llamacpp_loopback -admission-key-file /root/e2e/admission-key-7 -receipt-key-file /root/e2e/receipt-key-7"
fakeprov_args 4 "$common -trusted-pool -model-id e2e-mlx-n -model-hash $H_MLX -model-hash-algorithm macprovider.snapshot-manifest.v1 -admission-key-file /root/e2e/admission-key-4 -receipt-key-file /root/e2e/receipt-key-4"
systemctl enable e2e-fakeprov@3 e2e-fakeprov@4 e2e-fakeprov@5 >/dev/null 2>&1
systemctl restart e2e-fakeprov@3 e2e-fakeprov@4 e2e-fakeprov@5 e2e-fakeprov@7
wait_providers 5 || result S3-members-connected FAIL "not every member is ready: $(coord_healthz | head -c 300)"
sleep 3
offer() {  # offer <i> <runtime> <served-ref> <alg> <hash> <out>
  $FP offer -coord-http http://127.0.0.1:8444 -provider-id e2e-prov-$1 -token-file /root/e2e/token-e2e-prov-$1 -admission-key-file /root/e2e/admission-key-$1 \
    -runtime-source "$2" -served-model-ref "$3" -catalog-key "" -artifact-hash-algorithm "$4" -artifact-hash "$5" -out "$6.json" >"$6.txt" 2>&1
}
offer 3 llamacpp_loopback gguf-g-model macprovider.gguf-file.v1 $H_GGUF "$EV/offer-3"
offer 4 mlx_cache e2e-mlx-n macprovider.snapshot-manifest.v1 $H_MLX "$EV/offer-4"
offer 5 llamacpp_loopback gguf-g-model macprovider.gguf-file.v1 $H_GGUF "$EV/offer-5"
offer 7 llamacpp_loopback gguf-g-model macprovider.gguf-file.v1 $H_GGUF "$EV/offer-7"
check_binding() {  # check_binding <offer.json> <pmid> <want-bound 1|0>
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
s = json.load(open(sys.argv[1])); b = s.get("pool_binding") or {}
bound = s.get("admission_state") == "catalog_priced" and b.get("binding_scope") == "pool" and b.get("pool_model_id") == sys.argv[2] and s.get("catalog_model_key") is None
print("state=%s binding_scope=%s pool_model_id=%s catalog_model_key=%s digest=%s" % (s.get("admission_state"), b.get("binding_scope"), b.get("pool_model_id"), s.get("catalog_model_key"), str(b.get("manifest_core_digest"))[:16]))
sys.exit(0 if bound == (sys.argv[3] == "1") else 1)
PY
}
check_binding "$EV/offer-3.json" "$MG" 1 >"$EV/bind-3.txt" 2>&1 && result S3-bind-loopback PASS "e2e-prov-3 offer: $(cat "$EV/bind-3.txt")" \
  || result S3-bind-loopback FAIL "e2e-prov-3: $(cat "$EV/bind-3.txt" "$EV/offer-3.txt" | tr '\n' ' ' | head -c 600)"
check_binding "$EV/offer-7.json" "$MG" 1 >"$EV/bind-7.txt" 2>&1 && result S3-bind-loopback-second-member PASS "e2e-prov-7 offer: $(cat "$EV/bind-7.txt")" \
  || result S3-bind-loopback-second-member FAIL "e2e-prov-7: $(cat "$EV/bind-7.txt" "$EV/offer-7.txt" | tr '\n' ' ' | head -c 600)"
# e2e-prov-7 stays bound but offline until S5's member revocation, so every
# other pool-model check has exactly one serving member per pool.
systemctl stop e2e-fakeprov@7
check_binding "$EV/offer-4.json" "$MN" 1 >"$EV/bind-4.txt" 2>&1 && result S3-bind-native PASS "e2e-prov-4 offer: $(cat "$EV/bind-4.txt")" \
  || result S3-bind-native FAIL "e2e-prov-4: $(cat "$EV/bind-4.txt" "$EV/offer-4.txt" | tr '\n' ' ' | head -c 600)"
csql "SELECT provider_id, state, actor, reason_code, binding_scope, pool_model_id, pool_manifest_version FROM model_admission_events WHERE provider_id IN ('e2e-prov-3','e2e-prov-4','e2e-prov-5') ORDER BY id" >"$EV/admission-events.txt" 2>&1
for p in e2e-prov-3 e2e-prov-4; do
  grep "^$p|catalog_priced|pool_manifest:.*|pool_manifest_bound|pool|" "$EV/admission-events.txt" >/dev/null \
    && result "S3-admission-event-$p" PASS "$(grep "^$p|catalog_priced" "$EV/admission-events.txt" | tail -1)" \
    || result "S3-admission-event-$p" FAIL "no catalog_priced/pool_manifest_bound/pool event: $(grep "^$p" "$EV/admission-events.txt" | tail -2 | tr '\n' ' ')"
done
curl_bearer "$(opkey)" -s http://127.0.0.1:8444/poolz >"$EV/poolz.json"
python3 - "$EV/poolz.json" <<'PY' >"$EV/poolz.check" 2>&1
import json, sys
d = json.load(open(sys.argv[1])); rows = d.get("providers") or d.get("pool") or d
rows = rows if isinstance(rows, list) else rows.get("providers", [])
want = {"e2e-prov-3": "llamacpp_loopback", "e2e-prov-4": None}
ok = True
for r in rows:
    pid = r.get("provider_id") or r.get("id")
    if pid in want:
        print(pid, r.get("runtime_source"), r.get("model_hash_algorithm"), r.get("catalog_admission_mode"), r.get("hash_status"), r.get("state"))
        # runbook section 4: a pool entry is pool_entry + uncatalogued (Tier-2), never hash_verified
        ok = ok and r.get("runtime_source") == want[pid] and r.get("catalog_admission_mode") == "pool_entry" \
            and r.get("hash_status") == "uncatalogued" and r.get("state") == "ready"
        want.pop(pid)
sys.exit(0 if ok and not want else 1)
PY
[ $? = 0 ] && result S3-poolz PASS "$(tr '\n' ';' <"$EV/poolz.check")" || result S3-poolz FAIL "$(tr '\n' ';' <"$EV/poolz.check" | head -c 500)"

# ---- buyer view: pool /v1/models lists the entry; global does not -----------------
BK="$(cat /root/e2e/buyer-api-key)"
curl_bearer "$BK" -s https://api.malibu.tech/v1/models -H "X-MacProvider-Pool-Select: $Q" >"$EV/models-pool-q.json"
curl_bearer "$BK" -s https://api.malibu.tech/v1/models >"$EV/models-global.json"
if grep -q "\"$MG\"" "$EV/models-pool-q.json" && ! grep -q "pool/" "$EV/models-global.json"; then
  result S3-models-view PASS "pool view lists $MG ($(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print([(m["id"],m.get("provider_count"),m.get("total_slots")) for m in d["data"] if m["id"].startswith("pool/")])' "$EV/models-pool-q.json" 2>&1)); global list has no pool/ id"
else result S3-models-view FAIL "pool view: $(head -c 300 "$EV/models-pool-q.json"); global has pool/: $(grep -c 'pool/' "$EV/models-global.json")"; fi
# disclosure headers on a single pool request
curl_bearer "$BK" -s -D "$EV/probe-g.headers" -o "$EV/probe-g.body" https://api.malibu.tech/v1/chat/completions -H 'Content-Type: application/json' \
  -H "X-MacProvider-Pool-Select: $Q" -H 'X-MacProvider-Engine-Select: llamacpp' -d "{\"model\":\"$MG\",\"max_tokens\":64,\"messages\":[{\"role\":\"user\",\"content\":\"probe $(date +%s)\"}]}"
grep -qi '^x-macprovider-model-disclosure: pool_attested_unverified' "$EV/probe-g.headers" && grep -qi '^x-macprovider-engine: llamacpp_loopback' "$EV/probe-g.headers" \
  && result S3-disclosure PASS "200 with X-MacProvider-Model-Disclosure: pool_attested_unverified and X-MacProvider-Engine: llamacpp_loopback" \
  || result S3-disclosure FAIL "headers: $(grep -i '^HTTP\|x-macprovider-\(model-disclosure\|engine\)' "$EV/probe-g.headers" | tr -d '\r' | tr '\n' ' ') body: $(head -c 200 "$EV/probe-g.body")"

# ---- pool-model traffic, all four kinds -----------------------------------------------
run="$(run_id s3g)"
pool_traffic "$run" Q "$MG" llamacpp "ns=4,st=4,st_dc=1,ns_dc=1" 2
pool_check S3-pool-traffic-gguf "$run" --expect ns=settled,st=settled --min-settled 8 --pool-model-id "$MG" --rates $G_RATES \
  --usage-source pool_operator_attested --token-source pool_operator_attested --runtime-source llamacpp_loopback --provider e2e-prov-3
run="$(run_id s3n)"
pool_traffic "$run" QN "$MN" "" "ns=4,st=4,st_dc=1,ns_dc=1" 2
pool_check S3-pool-traffic-native "$run" --expect ns=settled,st=settled --min-settled 8 --pool-model-id "$MN" --rates $N_RATES \
  --usage-source coordinator_observed --token-source coordinator_observed --runtime-source null --provider e2e-prov-4
g="$(global_pool_snapshots)"
[ "$g" = 0 ] && result S3-never-global PASS "no route snapshot carries a pool_model_id without a pool_id" || result S3-never-global FAIL "$g pool-model snapshots without a pool"
# ---- deploy order, coordinator first: NEW coordinator + OLD gateway with pool models live ----
# The manual runbook order (trusted-pool-production-launch s9: coordinator,
# then gateway) leaves this pairing up for a while; the Pearl updater never
# serves it (S2-updater-order). Pool-model traffic must fail closed because
# the old gateway cannot send route-snapshot/v2 settlement context; catalog
# traffic must behave like the baseline. Then the new gateway returns and fresh
# pool-model traffic settles normally.
systemctl stop macprovider-gateway
cp -p /opt/macprovider/gateway /opt/macprovider/gateway.e2e-new
install -o root -g macprovider -m 0750 /root/e2e/bins/old/gateway-linux-amd64 /opt/macprovider/gateway
since="$(mark)"
if (gw_restart) >"$EV/oldgw-start.txt" 2>&1; then
  run="$(run_id s3cfpool)"
  pool_traffic "$run" Q "$MG" llamacpp "ns=2,st=2" 2
  sleep 3; h="$(holds_active)"
  journal_since macprovider-gateway "$since" "$EV/oldgw-gateway.log"
  pv="$(grep -c 'invalid_settlement_policy_version' "$EV/oldgw-gateway.log")"
  result S3-order-coordinator-first-holds INFO "new coordinator + old gateway, pool-model traffic: holds right after=$h, invalid_settlement_policy_version log lines=$pv"
  if DRAIN_MAX=120 pool_check S3-order-coordinator-first-pool "$run" --refused \
    && python3 - "$E2E_EVIDENCE/$run.load.jsonl" <<'PY'
import json, sys
for line in open(sys.argv[1]):
    try:
        r = json.loads(line)
    except Exception:
        continue
    if r.get("response_error_code") == "pool_model_requires_gateway_upgrade":
        sys.exit(0)
sys.exit(1)
PY
  then
    result S3-order-coordinator-first-upgrade-refusal PASS "old gateway pool-model traffic is refused with pool_model_requires_gateway_upgrade"
  else
    result S3-order-coordinator-first-upgrade-refusal FAIL "old gateway pool-model traffic did not expose response_error_code=pool_model_requires_gateway_upgrade ($(head -c 400 "$E2E_EVIDENCE/$run.load.jsonl" 2>/dev/null))"
  fi
  cfrun=1
  run="$(run_id s3cfcat)"
  traffic "$run"
  settle_and_check S3-order-coordinator-first-catalog "$run" --expect ns=settled,st=settled
  compare_catalog_shape S3-order-coordinator-first-catalog-shape "$run" "new coordinator + old gateway catalog"
else
  result S3-order-coordinator-first-holds FAIL "the old gateway does not start on the new pair's gateway DB: $(tail -3 "$EV/oldgw-start.txt" | tr '\n' ' ' | head -c 300)"
  cfrun=""
fi
systemctl stop macprovider-gateway
install -o root -g macprovider -m 0750 /opt/macprovider/gateway.e2e-new /opt/macprovider/gateway; rm -f /opt/macprovider/gateway.e2e-new
gw_restart
if [ -n "$cfrun" ]; then
  if wait_pool_model_routeable S3-order-coordinator-first-new-gw-routeable Q "$MG" llamacpp_loopback e2e-prov-3 0 60; then
    run="$(run_id s3cfpoolnew)"
    pool_traffic "$run" Q "$MG" llamacpp "ns=2,st=2" 2
    pool_check S3-order-coordinator-first-pool-after-new-gw "$run" --expect ns=settled,st=settled --min-settled 4 --pool-model-id "$MG" --rates $G_RATES \
      --usage-source pool_operator_attested --token-source pool_operator_attested --provider e2e-prov-3
  else
    result S3-order-coordinator-first-pool-after-new-gw FAIL "skipped traffic because Q/$MG was not routeable after restoring the new gateway"
  fi
fi

# catalog traffic alongside, unchanged
run="$(run_id s3cat)"
traffic "$run" "ns=3,st=3"
settle_and_check S3-catalog-traffic "$run" --expect ns=settled,st=settled
