#!/usr/bin/env bash
# S5 Trusted Pool with a v2 runtime_allowlist and a loopback-class member
# (runbook section 9 steps 3-4 after the S2 rollout: new coordinator + new
# gateway, pin on). The member is fakeprov claiming llamacpp_loopback with a
# GGUF identity, an enrolled admission key and a signed, operator-priced
# model-admission offer (no real engine; real engines run on the Studio).
#
# Catalog: the production static release has no catalog-artifacts feed and no
# GGUF member, so this step installs a lab-signed static release (the
# #1690 M6 labtool, lab keys generated in the VM) exactly as the Studio lab
# rig does, and re-points the coordinator's autotune/tier2 config at it. That
# is a harness deviation (a real deploy would ship a signed catalog release).
set -uo pipefail
. /root/e2e/h/vm/lib.sh; . $E2E_H/vm/lib-deploy.sh; . $E2E_H/vm/lib-scn.sh
[ "$(cat /root/e2e/coordinator.side)/$(cat /root/e2e/gateway.side)" = new/new ] || die "S5 needs new/new"
EV=$E2E_EVIDENCE/p$PASS_ID-s5; mkdir -p "$EV"
WT=/root/e2e/wt-new
ROW_KEY=qwen2.5-0.5b-instruct
MLX_ID=mlx-community/Qwen2.5-0.5B-Instruct-4bit
MLX_REV=a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3
MLX_SHA=$(printf 'e2e-1690 placeholder mlx primary' | sha256sum | cut -c1-64)
GGUF_SHA=$(printf 'e2e-1690 fake gguf member' | sha256sum | cut -c1-64)
STATIC=/opt/macprovider/autotune/lab-1690
K=/root/e2e/keys

# ---- lab static release + tier2 (built and signed inside the VM) ------------
if [ ! -x /root/e2e/bins/labtool ]; then
  printf '{"Replace":{"%s/phase4-coordinator/cmd/lab1690m6/main.go":"%s/scripts/lab/1690-m6/labtool/main.go"}}' "$WT" "$WT" >/root/e2e/labtool-overlay.json
  ( cd $WT/phase4-coordinator && go build -overlay /root/e2e/labtool-overlay.json -o /root/e2e/bins/labtool ./cmd/lab1690m6 ) >"$EV/labtool-build.log" 2>&1 || die "labtool build failed"
fi
rm -rf $STATIC; install -d -o root -g macprovider -m 0750 $STATIC
/root/e2e/bins/labtool static-release --out-dir $STATIC --key-file $K/lab-static.ed25519 --release e2e-1690-lab-r1 \
  --generated-at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --row-key $ROW_KEY --mlx-model-id $MLX_ID --mlx-revision $MLX_REV --mlx-sha256 $MLX_SHA \
  --gguf-sha256 $GGUF_SHA --gguf-size 491400032 --gguf-repo Qwen/Qwen2.5-0.5B-Instruct-GGUF --gguf-revision 9217f5db79a29953eb74d5343926648285ec7e67 \
  --gguf-file qwen2.5-0.5b-instruct-q4_k_m.gguf --swift-out $EV/AutotuneCatalog.generated.swift >"$EV/static-release.log" 2>&1 || die "static-release failed: $(tail -3 $EV/static-release.log)"
[ -f $K/tier2.priv ] || ( cd $WT && go run scripts/sign-catalog.go keygen -public-out $K/tier2.pub -private-out $K/tier2.priv ) >/dev/null
cat >$EV/tier2-unsigned.json <<J
{"version":1,"catalog_id":"e2e-1690-tier2","issued_at":"$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ)","expires_at":"$(date -u -d '+7 days' +%Y-%m-%dT%H:%M:%SZ)","models":[{"artifact_kind":"mlx_weight_file","hash_scope":"macprovider.snapshot-manifest.v1","model_id":"$MLX_ID","min_ram_gb":8,"sha256":"$MLX_SHA","source":"e2e-1690"}]}
J
( cd $WT && go run scripts/sign-catalog.go sign -key $K/tier2.priv -key-id e2e-1690-tier2 -out $STATIC/tier2-catalog.json $EV/tier2-unsigned.json ) >/dev/null || die "tier2 sign failed"
chown -R root:macprovider $STATIC; chmod 0640 $STATIC/*
python3 - $STATIC "$(tr -d '\n' <$K/tier2.pub)" <<'PY'
import json, sys, yaml
static, t2 = sys.argv[1], sys.argv[2]
p = "/opt/macprovider/coordinator.yaml"
open(p + ".pre-s5", "w").write(open(p).read())
c = yaml.safe_load(open(p))
pub = open(static + "/static-public-key.base64").read().strip()
a = c["autotune"]
a["public_keys"]["lab-1690-m6-static"] = pub
for f in ("rate_card", "demand_rank", "autotune_candidates", "catalog_artifacts"):
    name = f.replace("_", "-") + ".json"
    a[f + "_path"] = "%s/%s" % (static, name); a[f + "_sig_path"] = "%s/%s.sig" % (static, name)
c.setdefault("tier2", {}).update({"catalog_path": static + "/tier2-catalog.json", "catalog_public_key": t2, "observe_enabled": True, "require_hash_verified": True})
rc = json.load(open(static + "/rate-card.json"))
c["rewards"]["rate_card"] = {k: {"prompt_credits_per_mtok": v["prompt_rate_per_mtok"], "prompt_cache_hit_credits_per_mtok": v["prompt_cache_hit_rate_per_mtok"],
                                 "completion_credits_per_mtok": v["completion_rate_per_mtok"]} for k, v in rc["rows"].items()}
c["trusted_pools"] = dict(c.get("trusted_pools") or {}, enabled=True, refresh_interval_s=1)
open(p, "w").write(yaml.safe_dump(c, sort_keys=False))
PY
since="$(mark)"
systemctl restart macprovider-coordinator
for i in $(seq 1 90); do coord_healthz >/dev/null 2>&1 && break; sleep 1; done
coord_healthz >/dev/null 2>&1 || { journalctl -u macprovider-coordinator -n 30 --no-pager >"$EV/coord-start.txt"; die "coordinator did not start on the lab catalog: $(tail -3 $EV/coord-start.txt)"; }

# ---- providers: natives move to the lab row; e2e-prov-3 is the loopback member
for i in 1 2; do printf 'FAKEPROV_ARGS=-catalog-key %s -model-id %s -stream-chunks 20 -chunk-delay-ms 100 -nonstream-delay-ms 1500\n' $ROW_KEY $MLX_ID >/root/e2e/fakeprov-$i.env; done
printf 'FAKEPROV_ARGS=-catalog-key %s -model-id %s -model-hash %s -model-hash-algorithm macprovider.gguf-file.v1 -runtime-source llamacpp_loopback -admission-key-file /root/e2e/admission-key-3 -stream-chunks 20 -chunk-delay-ms 100 -nonstream-delay-ms 1500\n' $ROW_KEY $MLX_ID $GGUF_SHA >/root/e2e/fakeprov-3.env
systemctl restart e2e-fakeprov@1 e2e-fakeprov@2; systemctl enable --now e2e-fakeprov@3 >/dev/null 2>&1; systemctl restart e2e-fakeprov@3
wait_providers 3 || result S5-providers FAIL "not all 3 providers ready on the lab catalog: $(coord_healthz)"
sleep 3
/opt/macprovider/e2e-fakeprov offer -coord-http http://127.0.0.1:8444 -provider-id e2e-prov-3 -token-file /root/e2e/token-e2e-prov-3 \
  -admission-key-file /root/e2e/admission-key-3 -runtime-source llamacpp_loopback -served-model-ref llamacpp:qwen2.5-0.5b-instruct-q4_k_m \
  -catalog-key $ROW_KEY -gguf-sha256 $GGUF_SHA -out $EV/offer.json >"$EV/offer.txt" 2>&1 \
  && result S5-offer PASS "$(head -c 300 $EV/offer.txt)" || result S5-offer FAIL "$(head -c 500 $EV/offer.txt)"
python3 - $EV <<'PY' >"$EV/decision.txt" 2>&1
import json, sys, urllib.request
ev = sys.argv[1]
offer = json.load(open(ev + "/offer.json"))
key = [l.split("=", 1)[1].strip() for l in open("/etc/macprovider/coordinator.env") if l.startswith("OPERATOR_AUTH_POLICY_A=")][0]
body = {"schema": "model_admission_decision_request.v1", "provider_id": offer["provider_id"], "candidate_id": offer["candidate_id"],
        "next_state": "catalog_priced", "reason_code": "operator_lab_pool_priced",
        "expected_coordinator_event_id": offer["coordinator_event_id"], "idempotency_key": "e2e-1690-priced-1"}
req = urllib.request.Request("http://127.0.0.1:8444/admin/model-admission/decisions", data=json.dumps(body).encode(),
                             headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
try:
    print(json.dumps(json.load(urllib.request.urlopen(req))))
except urllib.error.HTTPError as e:
    print("HTTP", e.code, e.read().decode()[:500]); sys.exit(1)
PY
[ $? = 0 ] && result S5-decision PASS "$(head -c 300 $EV/decision.txt)" || result S5-decision FAIL "$(head -c 500 $EV/decision.txt)"

# ---- pool (runbook section 4 order) + gateway trusted-pool feature ----------
acct="$(gwsql "SELECT account_id FROM accounts LIMIT 1")"
rm -rf /root/e2e/pools/p$PASS_ID
python3 $E2E_H/tools/pool-setup.py create p$PASS_ID --buyer "$acct" --provider e2e-prov-3 --models $MLX_ID --runtime-allowlist llamacpp_loopback >"$EV/pool-create.txt" 2>&1 \
  && result S5-pool-create PASS "v2 pool with runtime_allowlist=llamacpp_loopback promoted: $(tail -1 $EV/pool-create.txt)" \
  || result S5-pool-create FAIL "$(tail -3 $EV/pool-create.txt | tr '\n' ' ')"
POOL="$(cat /root/e2e/pools/p$PASS_ID/pool_id 2>/dev/null)"
[ -n "$POOL" ] || die "no pool id: pool creation did not complete"
rf="$(grep -c REGISTRY_REFRESH_FAILED "$EV/pool-create.txt")"
[ "$rf" = 0 ] || result S5-registry-refresh-race FAIL "$rf admin event(s) answered 500 registry_refresh_failed although durable: $(grep REGISTRY_REFRESH_FAILED "$EV/pool-create.txt" | head -2 | tr '\n' ' ')"
curl_bearer "$(opkey)" -s http://127.0.0.1:8444/admin/trust-pools/pools/$POOL >"$EV/get-pool.json"
curl_bearer "$(opkey)" -s http://127.0.0.1:8444/poolz >"$EV/poolz.json"
gw_set features.trusted_pools '{enabled: true, coordinator_authorizes: true}'
gw_restart
MODEL=$MLX_ID
# How long until the freshly promoted pool actually routes (a single probe per
# 5 s; the dev run saw pool_unavailable right after the first promote).
t=0; code=""
while [ $t -le 120 ]; do
  code="$(curl_bearer "$(cat /root/e2e/buyer-api-key)" -s -o $EV/probe.body -w '%{http_code}' https://api.malibu.tech/v1/chat/completions \
    -H 'Content-Type: application/json' -H "X-MacProvider-Pool-Select: $POOL" -d "{\"model\":\"$MLX_ID\",\"max_tokens\":64,\"messages\":[{\"role\":\"user\",\"content\":\"probe $t\"}]}")"
  [ "$code" = 200 ] && break
  echo "t=$t $code $(head -c 200 $EV/probe.body)" >>"$EV/probe.log"; sleep 5; t=$((t+5))
done
[ "$code" = 200 ] && result S5-pool-routes PASS "first pool 200 after ${t}s ($(wc -l <$EV/probe.log 2>/dev/null || echo 0) earlier non-200s: $(head -1 $EV/probe.log 2>/dev/null | head -c 160))" \
  || result S5-pool-routes FAIL "pool never routed within 120s: $(tail -1 $EV/probe.log)"
run="$(run_id s5pool)"
# The single member has 2 slots; a busy member answers the non-retryable
# pool_no_eligible_member (finding), so pool traffic runs 2 buyers wide.
traffic "$run" "ns=4,st=4,st_dc=1,ns_dc=1" --header "X-MacProvider-Pool-Select:$POOL" --workers 2
DRAIN_MAX=700 settle_and_check S5-pool-traffic "$run" --expect ns=settled,st=settled
src="$(python3 -c "import json;d=json.load(open('$E2E_EVIDENCE/$run.oracle.json'));print(sorted({(r['token_source'],tuple(sorted({s['usage_source'] for s in r['attempt_outputs']}))) for r in d['rows'] if r['res_status']=='settled'}))")"
echo "$src" | grep -q pool_operator_attested && result S5-pool-operator-attested PASS "settled pool requests: $src" \
  || result S5-pool-operator-attested FAIL "no pool_operator_attested settlement: $src"
# native (global) traffic still settles alongside
run="$(run_id s5global)"
traffic "$run" "ns=3,st=3"
settle_and_check S5-global-traffic "$run" --expect ns=settled,st=settled
# the gateway-rollback pre-check (runbook s9) now forbids a gateway rollback
pre="$(gwsql "SELECT COUNT(*) FROM usage_events WHERE token_source = 'pool_operator_attested'")"
[ "$pre" -gt 0 ] && result S5-gw-rollback-precheck PASS "$pre pool_operator_attested usage rows: gateway rollback forbidden (roll forward)" \
  || result S5-gw-rollback-precheck FAIL "pre-check count is 0 after pool traffic"
# coordinator downgrade gate: pools paused, current binary, live DB
python3 $E2E_H/tools/pool-setup.py lifecycle p$PASS_ID paused >"$EV/pause.txt" 2>&1 || result S5-pause FAIL "$(tail -2 $EV/pause.txt)"
for t in 0 1; do
  with_coordinator_env /opt/macprovider/coordinator pool-rollback-preflight \
    --config /opt/macprovider/coordinator.yaml >"$EV/preflight-$t.txt" 2>&1
  echo "rc=$?" >>"$EV/preflight-$t.txt"
  [ $t = 0 ] && sleep 330
done
result S5-pool-rollback-preflight INFO "right after pause: $(tr '\n' ' ' <$EV/preflight-0.txt | head -c 300); after 330s: $(tr '\n' ' ' <$EV/preflight-1.txt | head -c 300)"
grep -q 'rc=0' "$EV/preflight-1.txt" && result S5-preflight-reaches-0 PASS "gate exits 0 once pending deadlines pass" || result S5-preflight-reaches-0 FAIL "gate still non-zero after the pending window"
python3 $E2E_H/tools/pool-setup.py promote p$PASS_ID >"$EV/resume.txt" 2>&1 || true
