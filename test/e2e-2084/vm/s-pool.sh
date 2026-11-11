#!/usr/bin/env bash
# P: a Trusted Pool with a shard group, through the real creator/admin paths,
# on the new pair left by U.
#   - trusted_pools on with the runbook's pool_model_pricing_bounds; gateway
#     trusted-pools feature;
#   - pool S: native (mlx_cache) entry shard-s for the group's snapshot hash,
#     pool_shard_groups/v1 naming the head (max_members 3), every core signed
#     by `coordinator-cli trust-pool-admin sign-manifest --encoding 2
#     --pool-models` (tools/pool-models.py); members head, member, spare;
#   - SPEC-051-R030 disclosure in pool_policy.json / pool_status.json (the
#     "extension removed" half is in F: R028 rotation);
#   - the fake group (head, stage member, spare) connects, the head binds the
#     pool entry through the signed model-admission offer, registers epoch 1,
#     the member and spare say hello, and the coordinator reports available.
set -uo pipefail
. /root/e2e/h/vm/lib.sh; . $E2E_H/vm/lib-deploy.sh; . $E2E_H/vm/lib-scn.sh; . /root/e2e/h16/vm/lib-1816.sh; . /root/e2e/h84/vm/lib-2084.sh
EV=$E2E_EVIDENCE/p$PASS_ID-p; mkdir -p "$EV"
[ "$(sides)" = new/new ] || die "P needs the new pair (U)"
ACCT="$(gwsql "SELECT account_id FROM accounts LIMIT 1")"
FP=/opt/macprovider/e2e-fakeprov

coord_yaml_edit "c.setdefault('trusted_pools', {}).update(enabled=True, refresh_interval_s=1, pool_model_pricing_bounds=json.loads('$BOUNDS_JSON'))"
coord_restart && result P-config PASS "trusted_pools enabled with pool_model_pricing_bounds; shard_groups at the SPEC-051 §4 defaults" \
  || { result P-config FAIL "coordinator did not start: $(journalctl -u macprovider-coordinator -n 5 --no-pager -o cat | tr '\n' ' ' | head -c 500)"; exit 1; }
gw_set features.trusted_pools '{enabled: true, coordinator_authorizes: true}'
gw_restart

$PM init S --allowlist "" >"$EV/init-s.txt" 2>&1 || die "init S: $(tail -2 "$EV/init-s.txt")"
$PM stage S --add shard-s macprovider.snapshot-manifest.v1 $H_SHARD mlx_cache $S_RATES 8192 >/dev/null
$PM stage S --shard-group $HEAD shard-s 3 >/dev/null
cp $E2E_POOLS/S/pool-models.json "$EV/pool-models-s.json"
for p in "S:$HEAD,$M1,$SPARE"; do
  n=${p%%:*}; m=${p#*:}
  if $PM create $n --members $m --buyer "$ACCT" >"$EV/create-$n.txt" 2>&1; then
    result "P-pool-$n-create" PASS "pool $(pool_id $n): approval, root, genesis core (coordinator-cli --pool-models$( [ $n = S ] && echo ' with shard_groups')), members $m, buyer, promote"
  else result "P-pool-$n-create" FAIL "$(tail -3 "$EV/create-$n.txt" | tr '\n' ' ' | head -c 600)"; fi
done
keeper_on
# signed core carries the extension (decoded by the coordinator)
$PM get S >"$EV/get-pool-S.json"
gst="$(sed -n 's/^GATEWAY_SERVICE_TOKEN=//p' /etc/macprovider/coordinator.env)"
for n in S; do
  for doc in pool_policy pool_status; do
    curl_bearer "$gst" -s -H "X-MacProvider-Account: $ACCT" "http://127.0.0.1:8443/v1/trust-pools/$(pool_id $n)/$doc.json" >"$EV/$doc-$n.json"
  done
done
python3 - "$EV" "$(pmid S shard-s)" <<'PY' >"$EV/disclosure.check" 2>&1
import json, sys, os
ev, pm = sys.argv[1], sys.argv[2]
want = "Requests for these models may be served by a group of up to 3 Macs owned by one operator on one local network. Every Mac in the group processes the full prompt and output."
ok = True
for doc in ("pool_policy", "pool_status"):
    s = json.load(open(os.path.join(ev, doc + "-S.json")))
    def find(d):
        if isinstance(d, dict):
            if "multi_mac_serving" in d:
                return d["multi_mac_serving"]
            for v in d.values():
                r = find(v)
                if r is not None:
                    return r
        return None
    ms = find(s)
    good = ms is not None and ms.get("enabled") is True and ms.get("pool_model_ids") == [pm] and ms.get("max_members") == 3 and ms.get("disclosure_text") == want
    leaks = "e2e-prov-1" in json.dumps(ms or {})
    print(doc, json.dumps(ms)[:300], "provider-id-leak:", leaks)
    ok = ok and good and not leaks
sys.exit(0 if ok else 1)
PY
[ $? = 0 ] && result P-disclosure-R030 PASS "$(tr '\n' ' ' <"$EV/disclosure.check" | head -c 600)" || result P-disclosure-R030 FAIL "$(tr '\n' ' ' <"$EV/disclosure.check" | head -c 800)"

# ---- the fake group ------------------------------------------------------------
write_group 1
knob_clear
shard_env 11 head; shard_env 12 member; shard_env 13 member
systemctl enable e2e-shardprov@11 e2e-shardprov@12 e2e-shardprov@13 >/dev/null 2>&1
systemctl restart e2e-shardprov@11 e2e-shardprov@12 e2e-shardprov@13
sleep 8
$FP offer -coord-http http://127.0.0.1:8444 -provider-id $HEAD -token-file /root/e2e/token-$HEAD -admission-key-file /root/e2e/admission-key-$HEAD \
  -runtime-source mlx_cache -served-model-ref $SHARD_MODEL -catalog-key "" -artifact-hash-algorithm macprovider.snapshot-manifest.v1 -artifact-hash $H_SHARD -out "$EV/offer-head.json" >"$EV/offer-head.txt" 2>&1
python3 - "$EV/offer-head.json" "$(pmid S shard-s)" <<'PY' >"$EV/bind-head.txt" 2>&1
import json, sys
s = json.load(open(sys.argv[1])); b = s.get("pool_binding") or {}
print("state=%s scope=%s pool_model_id=%s" % (s.get("admission_state"), b.get("binding_scope"), b.get("pool_model_id")))
sys.exit(0 if s.get("admission_state") == "catalog_priced" and b.get("binding_scope") == "pool" else 1)
PY
[ $? = 0 ] && result P-head-pool-binding PASS "$(cat "$EV/bind-head.txt")" || result P-head-pool-binding FAIL "$(cat "$EV/bind-head.txt" "$EV/offer-head.txt" | tr '\n' ' ' | head -c 600)"
st="$(wait_head true "" 60 1)" && result P-group-available PASS "head status available at epoch 1 ($st); register=$(shard_field $HEAD register_result | head -c 200); member hello=$(shard_field $M1 hello_result | head -c 160); spare hello=$(shard_field $SPARE hello_result | head -c 160)" \
  || result P-group-available FAIL "head state=$st register=$(shard_field $HEAD register_result | head -c 300) m1=$(shard_field $M1 hello_result | head -c 200) spare=$(shard_field $SPARE hello_result | head -c 200) events: $(shard_events '3 min ago' | tail -5 | tr '\n' ' ' | head -c 700)"
rows="$(csql "SELECT group_epoch||':'||length(record_json) FROM shard_group_records WHERE group_provider_id='$HEAD'")"
binds="$(csql "SELECT group_concat(member_device_id||'/'||role||'/'||stage_index, ' ') FROM shard_group_member_bindings WHERE group_provider_id='$HEAD' AND group_epoch=1")"
[ -n "$rows" ] && [ "$binds" = "$M1/stage/1 $SPARE/spare/1" -o "$binds" = "$SPARE/spare/1 $M1/stage/1" ] && result P-durable-record PASS "record rows $rows; bindings $binds" || result P-durable-record FAIL "records=[$rows] bindings=[$binds]"
