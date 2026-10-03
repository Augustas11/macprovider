#!/usr/bin/env bash
# S4 refusals (after S3). Each must fail closed: no debit, no ledger credit,
# no route snapshot for the refused id, and a refused manifest leaves the
# pool's active core unchanged.
#   global route        pool/<Q>/gguf-g with no pool header
#   other pool          pool/<Q>/gguf-g with QN's pool header
#   out-of-bounds price an entry with completion 2,160,001 (max is 2,160,000)
#   catalog overlap     (a) the activation release's GGUF artifact-feed identity
#                       (recommendable row, llamacpp_loopback); (b) a
#                       recommendable catalog MLX snapshot (mlx_cache);
#                       (c) a BLOCKED artifact-feed identity, from a lab-signed
#                       copy of the live release (tools/make-lab-blocked-release.py)
#   unset bounds        coordinator restarted without pool_model_pricing_bounds:
#                       a manifest with entries refused, pool-model traffic refused
#   non-attested non-creator member: e2e-prov-5 (delegated, owner account not
#                       attested) is never bound; with e2e-prov-3 stopped the
#                       pool request is refused
#   runtime outside the allowlist: an lmstudio_loopback entry on Q
#                       (allowlist llamacpp_loopback); and a runtime/format
#                       pairing error (GGUF entry naming mlx_cache)
set -uo pipefail
. /root/e2e/h/vm/lib.sh; . $E2E_H/vm/lib-deploy.sh; . $E2E_H/vm/lib-scn.sh; . /root/e2e/h16/vm/lib-1816.sh
[ "$(sides)" = new/new ] && [ -n "$(pool_id Q)" ] || die "S4 needs S3 (new pair, pools Q/QN)"
EV=$E2E_EVIDENCE/p$PASS_ID-s4; mkdir -p "$EV"
Q=$(pool_id Q); QN=$(pool_id QN); MG=$(pmid Q gguf-g); MN=$(pmid QN mlx-n)
BK="$(cat /root/e2e/buyer-api-key)"

# refused_traffic <label> <run> <model> [headers...]: 2 ns + 1 st, all must be refused.
refused_traffic() {
  local label="$1" run="$2" model="$3"; shift 3
  local s0; s0="$(snapshots_for "$model")"
  MODEL="$model" traffic "$run" "ns=2,st=1" "$@" --workers 1 >/dev/null
  pool_check "$label" "$run" --refused
  local s1; s1="$(snapshots_for "$model")"
  [ "$s0" = "$s1" ] || result "$label-snapshots" FAIL "$((s1 - s0)) new route snapshots for $model"
  python3 -c 'import json,sys
for l in open(sys.argv[1]):
    r=json.loads(l); print(r.get("kind"), r.get("status"), (r.get("body") or "")[:160])' "$E2E_EVIDENCE/$run.load.jsonl" | sort | uniq -c >"$EV/$run.statuses.txt"
  result "$label-codes" INFO "$(tr '\n' ';' <"$EV/$run.statuses.txt" | head -c 500)"
}
# refused_manifest <label> <pool> <expected-code> <models-file> [offline-reason]:
# the coordinator's closed code, or (rc 4) the reviewed offline signer's
# refusal, which validates the same acceptance rules before anything is sent.
refused_manifest() {
  local label="$1" pool="$2" code="$3" mf="$4" offline="${5:-}" d0 d1 out rc before after candidate active
  before="$EV/$label.before-pool.json"; after="$EV/$label.after-pool.json"
  $PM get "$pool" >"$before"
  d0="$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));p=d.get("pool") or d;print(p.get("manifest_core_digest"), p.get("manifest_version"))' "$before")"
  candidate="$(python3 - "$before" "$mf" <<'PY'
import json, sys
before = json.load(open(sys.argv[1])); before = before.get("pool") or before
proposal = json.load(open(sys.argv[2]))
old = {e.get("pool_model_id") for e in before.get("model_entries") or []}
new = [e.get("pool_model_id") for e in proposal.get("model_entries") or [] if e.get("pool_model_id") not in old]
print(new[0] if new else "")
PY
)"
  out="$($PM manifest "$pool" --models-file "$mf" 2>&1)"; rc=$?
  echo "$out" >"$EV/$label.manifest.txt"
  $PM get "$pool" >"$after"
  d1="$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));p=d.get("pool") or d;print(p.get("manifest_core_digest"), p.get("manifest_version"))' "$after")"
  active="$(python3 - "$after" "$candidate" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); p = d.get("pool") or d
candidate = sys.argv[2]
print("yes" if candidate and any(e.get("pool_model_id") == candidate for e in p.get("model_entries") or []) else "no")
PY
)"
  if [ $rc != 0 ] && { echo "$out" | grep -q "$code" || { [ $rc = 4 ] && [ -n "$offline" ] && echo "$out" | grep -q "$offline"; }; } && [ -n "$candidate" ] && [ "$active" = no ]; then
    result "$label" PASS "refused ($([ $rc = 4 ] && echo "offline by coordinator-cli sign-manifest: $(echo "$out" | tail -1 | head -c 160)" || echo "by the coordinator: $code")); rejected entry absent (${candidate:-unknown}); core $([ "$d0" = "$d1" ] && echo "unchanged" || echo "rotated by keeper") ($d0 -> $d1)"
  else
    result "$label" FAIL "rc=$rc want $code active_candidate=$active candidate=${candidate:-unknown}: $(echo "$out" | tail -1 | head -c 400); core before/after: $d0 / $d1"
  fi
}
stage_variant() {  # stage_variant <pool> <out> <stage args...>: staged entries + one more, in a separate file
  local pool="$1" out="$2"; shift 2
  cp /root/e2e/pools16/$pool/pool-models.json "$out"
  E2E_POOLS=/root/e2e/pools16 python3 - "$out" "$(pool_id "$pool")" "$@" <<'PY'
import json, sys
out, pid, slug, alg, hsh, runtimes, rates = sys.argv[1:8]
m = json.load(open(out))
p, ch, c = (int(x) for x in rates.split(","))
m["model_entries"].append({"pool_model_id": "pool/%s/%s" % (pid, slug), "artifact_hash_algorithm": alg, "artifact_hash": hsh,
                           "allowed_runtime_sources": sorted(runtimes.split(",")), "license": "Apache-2.0", "paid_serving_attested": True,
                           "pricing": {"prompt_rate_per_mtok": p, "prompt_cache_hit_rate_per_mtok": ch, "completion_rate_per_mtok": c},
                           "disclosure_class": "pool_attested_unverified", "max_context_tokens": 8192})
m["model_entries"].sort(key=lambda e: e["pool_model_id"])
json.dump(m, open(out, "w"), indent=2)
PY
}

# ---- routes ------------------------------------------------------------------------
refused_traffic S4-global-route "$(run_id s4global)" "$MG"
refused_traffic S4-other-pool "$(run_id s4otherpool)" "$MG" --header "X-MacProvider-Pool-Select:$QN"

# ---- manifest acceptance refusals ----------------------------------------------------
stage_variant Q "$EV/oob.json" gguf-oob macprovider.gguf-file.v1 $H_GGUF2 llamacpp_loopback 20000,5000,2160001
refused_manifest S4-out-of-bounds-price Q pool_model_pricing_out_of_bounds "$EV/oob.json"
stage_variant Q "$EV/overlap-gguf.json" cat-gguf macprovider.gguf-file.v1 $H_CAT_GGUF llamacpp_loopback $G_RATES
refused_manifest S4-catalog-overlap-gguf Q pool_model_entry_catalog_overlap "$EV/overlap-gguf.json"
stage_variant QN "$EV/overlap-mlx.json" cat-mlx macprovider.snapshot-manifest.v1 $H_CAT_MLX mlx_cache $N_RATES
refused_manifest S4-catalog-overlap-mlx QN pool_model_entry_catalog_overlap "$EV/overlap-mlx.json"
# (c) blocked artifact-feed identity (GAP D4): a LAB-signed copy of the live
# release blocks a catalog row carrying H_BLK (tools/make-lab-blocked-release.py),
# installed by pointing the effective autotune paths at it (Pearl overlay) and
# SIGHUP; an entry for H_BLK must be refused; then the live config is restored.
H_BLK=$(printf 'e2e-1816 lab blocked gguf' | sha256sum | cut -c1-64)
OVL=/etc/macprovider/coordinator.pearl-overlays.yaml
# The coordinator service has PrivateTmp, so host-side /tmp and /var/tmp
# fixtures are intentionally invisible to it. Keep the synthetic release in
# the service-readable test area under /opt/macprovider instead.
LAB=/opt/macprovider/e2e-lab-blocked-release
[ -f /root/e2e/keys/lab-catalog.pem ] || openssl genpkey -algorithm ed25519 -out /root/e2e/keys/lab-catalog.pem
cp -p "$OVL" "$EV/overlay.pre-lab"
rm -rf "$LAB"; install -d -m 0755 "$LAB"
feeds_dir="$(python3 - "$OVL" <<'PY'
import os, sys, yaml
eff = {}
for p in ("/opt/macprovider/coordinator.yaml", sys.argv[1]):
    eff.update((yaml.safe_load(open(p)) or {}).get("autotune") or {})
print(os.path.dirname(eff["autotune_candidates_path"]))
PY
)"
rate_card_src="$(python3 - "$OVL" <<'PY'
import sys, yaml
eff = {}
for p in ("/opt/macprovider/coordinator.yaml", sys.argv[1]):
    eff.update((yaml.safe_load(open(p)) or {}).get("autotune") or {})
print(eff.get("rate_card_path", ""))
PY
)"
lab_pub="$(python3 $E2E_H16/tools/make-lab-blocked-release.py --feeds "$feeds_dir" --key /root/e2e/keys/lab-catalog.pem \
  --key-id e2e-lab-catalog-v1 --blocked-hash "$H_BLK" --out "$LAB" 2>"$EV/lab-release.err")"
if [ ! -f "$LAB/rate-card.json" ] && [ -n "$rate_card_src" ] && [ -f "$rate_card_src" ]; then
  install -m 0644 "$rate_card_src" "$LAB/rate-card.json"
  openssl pkeyutl -sign -rawin -inkey /root/e2e/keys/lab-catalog.pem -in "$LAB/rate-card.json" \
    | python3 -c 'import base64,json,sys; print(json.dumps({"key_id":"e2e-lab-catalog-v1","alg":"ed25519","signature":base64.b64encode(sys.stdin.buffer.read()).decode()}))' \
    >"$LAB/rate-card.json.sig"
fi
find "$LAB" -type d -exec chmod 0755 {} + 2>/dev/null || true
find "$LAB" -type f -exec chmod 0644 {} + 2>/dev/null || true
if [ -n "$lab_pub" ] && python3 - "$OVL" "$LAB" "$lab_pub" <<'PY'
import sys, yaml
ovl, lab, pub = sys.argv[1:4]
base = (yaml.safe_load(open("/opt/macprovider/coordinator.yaml")) or {}).get("autotune") or {}
o = yaml.safe_load(open(ovl)) or {}
auto = dict(base); auto.update(o.get("autotune") or {})
for key, name in (("rate_card", "rate-card.json"), ("demand_rank", "demand-rank.json"), ("autotune_candidates", "autotune-candidates.json"),
                  ("catalog_artifacts", "autotune-artifacts.json"), ("continuous_batching_policy", "continuous-batching-policy.json")):
    if auto.get(key + "_path"):
        auto[key + "_path"], auto[key + "_sig_path"] = "%s/%s" % (lab, name), "%s/%s.sig" % (lab, name)
keys = dict(auto.get("public_keys") or {}); keys["e2e-lab-catalog-v1"] = pub; auto["public_keys"] = keys
o["autotune"] = auto
open(ovl, "w").write(yaml.safe_dump(o, sort_keys=False))
PY
then
  since="$(mark)"
  kill -HUP "$(systemctl show -p MainPID --value macprovider-coordinator)"; sleep 5
  journal_since macprovider-coordinator "$since" "$EV/lab-hup.log"
  if grep -q 'autotune feed reload rejected' "$EV/lab-hup.log"; then
    result S4-catalog-overlap-blocked FAIL "lab-signed blocked release not loaded: $(grep 'reload rejected' "$EV/lab-hup.log" | head -1 | head -c 300)"
  else
    stage_variant Q "$EV/overlap-blocked.json" blk-gguf macprovider.gguf-file.v1 $H_BLK llamacpp_loopback $G_RATES
    refused_manifest S4-catalog-overlap-blocked Q pool_model_entry_catalog_overlap "$EV/overlap-blocked.json"
  fi
else
  result S4-catalog-overlap-blocked FAIL "lab release not built: $(head -c 300 "$EV/lab-release.err")"
fi
cp -p "$EV/overlay.pre-lab" "$OVL"
kill -HUP "$(systemctl show -p MainPID --value macprovider-coordinator)"; sleep 5
stage_variant Q "$EV/rt-not-allowed.json" gguf-lmstudio macprovider.gguf-file.v1 $H_GGUF2 lmstudio_loopback $G_RATES
refused_manifest S4-runtime-not-allowlisted Q pool_model_entry_runtime_not_allowed "$EV/rt-not-allowed.json" "allowed by the core"
stage_variant Q "$EV/rt-pairing.json" gguf-mlxcache macprovider.gguf-file.v1 $H_GGUF2 mlx_cache $G_RATES
refused_manifest S4-runtime-pairing Q pool_model_entry_runtime_pairing "$EV/rt-pairing.json" "incompatible artifact format"

# ---- non-attested non-creator member ------------------------------------------------
st5="$(python3 -c 'import json,sys;s=json.load(open(sys.argv[1]));print(s.get("admission_state"), bool(s.get("pool_binding")))' $E2E_EVIDENCE/p$PASS_ID-s3/offer-5.json 2>&1)"
csql "SELECT state, reason_code, binding_scope FROM model_admission_events WHERE provider_id='e2e-prov-5' ORDER BY id" >"$EV/admission-prov5.txt"
if [ "$st5" != "catalog_priced True" ] && ! grep -q '^catalog_priced|pool_manifest_bound' "$EV/admission-prov5.txt"; then
  result S4-non-attested-member-unbound PASS "e2e-prov-5 (delegated, owner $MEMBER_ACCT not attested) offer: $st5; never bound"
else result S4-non-attested-member-unbound FAIL "non-attested non-creator member bound: offer $st5; events $(tr '\n' ' ' <"$EV/admission-prov5.txt")"; fi
systemctl stop e2e-fakeprov@3; sleep 3
refused_traffic S4-non-attested-member-serves "$(run_id s4prov5)" "$MG" --header "X-MacProvider-Pool-Select:$Q" --header "X-MacProvider-Engine-Select:llamacpp"
c5="$(csql "SELECT COUNT(*) FROM ledger_request_credits WHERE provider_id='e2e-prov-5' AND provider_credits > 0")"
[ "$c5" = 0 ] && result S4-non-attested-member-no-credit PASS "no positive ledger credit for e2e-prov-5" || result S4-non-attested-member-no-credit FAIL "$c5 positive credits for e2e-prov-5"
systemctl start e2e-fakeprov@3; wait_providers 5 || true

# ---- unset bounds (last: restarts the coordinator) -----------------------------------
cp /opt/macprovider/coordinator.yaml "$EV/coordinator.yaml.with-bounds"
coord_yaml_edit "c['trusted_pools'].pop('pool_model_pricing_bounds', None)"
if coord_restart; then
  wait_providers 5 || true; sleep 5
  stage_variant QN "$EV/unset.json" mlx-n2 macprovider.snapshot-manifest.v1 $H_MLX2 mlx_cache $N_RATES
  refused_manifest S4-bounds-unset-manifest QN pool_model_pricing_bounds_unset "$EV/unset.json"
  refused_traffic S4-bounds-unset-route "$(run_id s4unset)" "$MN" --header "X-MacProvider-Pool-Select:$QN"
else result S4-bounds-unset-manifest FAIL "coordinator did not start without bounds while entries exist: $(journalctl -u macprovider-coordinator -n 4 --no-pager -o cat | tr '\n' ' ' | head -c 400)"; fi
install -o root -g root -m 0644 "$EV/coordinator.yaml.with-bounds" /opt/macprovider/coordinator.yaml
fresh_event="$(csql "SELECT COALESCE(MAX(id),0) FROM model_admission_events")"
coord_restart || die "coordinator did not come back with the bounds"
wait_providers 5 || true
# the pools still route after the refusals
if wait_pool_model_routeable S4-post-restore-routeable Q "$MG" llamacpp_loopback e2e-prov-3 "$fresh_event" 90; then
  run="$(run_id s4after)"
  pool_traffic "$run" Q "$MG" llamacpp "ns=2,st=2" 2
  pool_check S4-pool-still-routes "$run" --expect ns=settled,st=settled --min-settled 4 --pool-model-id "$MG" --rates $G_RATES \
    --usage-source pool_operator_attested --token-source pool_operator_attested --runtime-source llamacpp_loopback --provider e2e-prov-3
else
  result S4-pool-still-routes FAIL "skipped traffic because Q/$MG was not routeable after the final bounds restore; see $EV/S4-post-restore-routeable.*"
fi
