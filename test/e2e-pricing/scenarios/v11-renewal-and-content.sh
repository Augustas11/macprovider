#!/usr/bin/env bash
# V11: after a pricing change is live (V1),
#  a) the weekly freshness renewal (scripts/renew-autotune-static-feed.sh --deploy,
#     signed locally with the TEST key from scratch origin/main) passes its
#     continuity check against the pricing-changed live release and publishes;
#  b) a content-only release (demand-rank order change) after it goes through the
#     content lane with no pricing object (PRICING=0) and succeeds.
# O5/O6 after each.
set -euo pipefail
. "$(dirname "$0")/../env.sh"
. "$E2E_HARNESS/lib/common.sh"
e2e_write_ssh_config; e2e_tunnel_up; e2e_push_tools
live_label() { vm "python3 -c 'import json;print(json.load(open(\"/opt/macprovider/autotune/current/release.json\"))[\"release_id\"])'"; }
# A rolled-back/recovered pricing correction (V4/V5/V6/V8) leaves reviewed but
# not-live commits on main; renewals are cut from the live content.
e2e_checkout main
e2e_baseline V11
if [ "${1:-}" != b ]; then
e2e_main_to_live
rc=0
prior="$(live_label)"
e2e_load_start V11a --sampler
e2e_run_logged 2400 "$E2E_LOGS/V11a-renew.log" bash -c "cd '$E2E_REPO' && . '$E2E_HARNESS/env.sh' && . '$E2E_HARNESS/lib/common.sh' && e2e_lane_env && \
  AUTOTUNE_STATIC_KEY_ID='$E2E_AUTOTUNE_KEY_ID' AUTOTUNE_STATIC_PRIVATE_KEY_PATH='$E2E_KEYS/autotune.private.base64' RELEASE_ID_PREFIX=e2e-renew \
  bash scripts/renew-autotune-static-feed.sh --deploy" || rc=$?
sleep 5; load="$(e2e_load_stop V11a)"
live="$(vm 'readlink /opt/macprovider/autotune/current')"
v="$(e2e_oracle V11 --allow-journal --sampler /root/e2e/load/V11a/sampler.jsonl --o2-sequence "$prior,$(live_label)" || true)"
printf '%s\n' "$v" >"$E2E_EVIDENCE/V11a-oracle.json"
o56="$(python3 -c 'import json,sys;v=json.loads(sys.argv[1]);print(v["O5"]["ok"] and v["O6"]["ok"] and v["O2"]["ok"], v["O5"].get("problems"), v["O6"].get("problems"), "O2:", {k: v["O2"].get(k) for k in ("events","events_in_sequence","violations","skipped")})' "$v" 2>/dev/null || echo "? $v")"
case "$o56" in True*) ;; *) rc="$rc+oracle" ;; esac
if [ "$rc" = 0 ]; then e2e_result V11 PASS "a: renewal rc=0, live=$live; O5/O6/O2: $o56; load=$load"
else e2e_result V11 FAIL "a: renewal rc=$rc live=$live O5/O6: $o56; $(grep -iE 'error|drift|fail|refus' "$E2E_LOGS/V11a-renew.log" | tail -n 4 | tr '\n' '|' | cut -c1-600)"; fi

fi
# b) content-only release on top of main.
cd "$E2E_REPO"
[ -z "$(git status --porcelain)" ] || e2e_die dirty
git checkout -q --detach main
python3 - <<'PY'
import json
p = "phase3-binary/catalog/autotune/demand-rank.json"
d = json.load(open(p))
keys = [k for k in d if isinstance(d[k], list)]
PY
python3 scripts/catalog-release.py restamp --release-id "e2e-v11-content-$(date +%s)" --generated-at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null
python3 - <<'PY'
import json
p = "phase3-binary/catalog/autotune/demand-rank.json"
d = json.load(open(p))
# change one demand weight (content change, no price change)
k = sorted(d["rows"])[0]
d["rows"][k]["demand_weight"] = round(d["rows"][k]["demand_weight"] + 0.01, 4)
open(p, "w").write(json.dumps(d, indent=2, sort_keys=True) + "\n")
PY
AUTOTUNE_STATIC_KEY_ID="$E2E_AUTOTUNE_KEY_ID" AUTOTUNE_STATIC_PRIVATE_KEY_PATH="$E2E_KEYS/autotune.private.base64" \
  bash scripts/resign-autotune-static.sh >"$E2E_LOGS/V11b-resign.log" 2>&1 || { tail -5 "$E2E_LOGS/V11b-resign.log"; git checkout -q -- .; git checkout -q main; e2e_die "V11b cut failed"; }
git add -A phase3-binary && git commit -q -m "E2E V11b content-only demand-rank change"
C="$(git rev-parse HEAD)"; git push -q origin "$C:refs/heads/main"; git fetch -q origin; git checkout -q main; git reset -q --hard origin/main
cd - >/dev/null
e2e_checkout main
e2e_baseline V11b
rc=0; e2e_preflight V11b "$C" || rc=$?
pricing="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("pricing"))' "$E2E_EVIDENCE/V11b-verdict.json" 2>/dev/null)"
if [ "$rc" != 0 ]; then
  e2e_result V11 FAIL "b: content preflight NO_GO: $(e2e_verdict_failed "$E2E_EVIDENCE/V11b-verdict.json") | $(for x in $(e2e_verdict_failed "$E2E_EVIDENCE/V11b-verdict.json"); do e2e_verdict_detail "$E2E_EVIDENCE/V11b-verdict.json" "$x" | cut -c1-200; done | tr '\n' '|')"
  exit 0
fi
prior_b="$(live_label)"
e2e_load_start V11b --sampler
rc=0; e2e_deploy V11b "$C" || rc=$?
sleep 5; load="$(e2e_load_stop V11b)"
v="$(e2e_oracle V11b --expect-snapshots 1 --sampler /root/e2e/load/V11b/sampler.jsonl --o2-sequence "$prior_b,$(live_label)" || true)"
printf '%s\n' "$v" >"$E2E_EVIDENCE/V11b-oracle.json"
o56="$(python3 -c 'import json,sys;v=json.loads(sys.argv[1]);print(v["ok"], "O1", v["O1"].get("credits_checked"), "O2", {k: v["O2"].get(k) for k in ("events","events_in_sequence","violations")}, "O3", v["O3"])' "$v" 2>/dev/null || echo "? $v")"
case "$o56" in True*) ;; *) rc="$rc+oracle" ;; esac
if [ "$rc" = 0 ] && [ "$pricing" = None ]; then e2e_result V11 PASS "b: content-only release rc=0, verdict.pricing=null; oracle: $o56; load=$load"
else e2e_result V11 FAIL "b: content deploy rc=$rc pricing=$pricing; $(grep -E 'EVIDENCE|ERROR|ALERT' "$E2E_LOGS/V11b-deploy.log" | head -n 4 | tr '\n' '|'); $o56"; fi
