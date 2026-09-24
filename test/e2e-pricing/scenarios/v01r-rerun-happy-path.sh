#!/usr/bin/env bash
# V1R: V1's happy path, re-runnable in an existing world (V1's spec is
# one-shot). A reviewed pricing PR changes the served model's row and adds a
# row with NO acknowledgement file entry: an added row capturing only its own
# key needs none (SPEC-023-R018 rule 2, v0.16.1). Preflight GO -> deploy with
# the ack -> verified -> finalized -> O1-O6. Exercises the under-lock content
# gate's Tier-2 trust root and the service-readable candidate (#1693 E2 bugs 1
# and 2) with no workaround applied.
set -euo pipefail
. "$(dirname "$0")/../env.sh"
. "$E2E_HARNESS/lib/common.sh"
S=V1R
e2e_write_ssh_config; e2e_tunnel_up; e2e_push_tools
n="${E2E_V1R_SEQ:-$(( $(date +%s) + 31 ))}"
live_label() { vm "python3 -c 'import json;print(json.load(open(\"/opt/macprovider/autotune/current/release.json\"))[\"release_id\"])'"; }
prior="$(live_label)"
e2e_checkout main
jq -n --arg rid "e2e-v1r-$n" --arg row "e2e-rerun-$n" --argjson p "$((41000 + (n % 5000)))" \
  '{release_id: $rid, message: "E2E V1R pricing correction with an added row (no self-ack)",
    change: {"meta-llama/llama-3.2-3b-instruct": [$p, ($p/4|floor), ($p*2)]},
    add: {($row): [9000, 2250, 18000]}, acks: []}' >"$E2E_WORK/v1r.json"
C="$(bash "$E2E_HARNESS/lib/make-pricing-commit.sh" main "$E2E_WORK/v1r.json")"
label="e2e-v1r-$n"; e2e_checkout main
e2e_baseline V1R
e2e_load_start V1R
rc=0; e2e_preflight V1R "$C" || rc=$?
if [ "$rc" != 0 ]; then
  failed="$(e2e_verdict_failed "$E2E_EVIDENCE/V1R-verdict.json")"
  e2e_result "$S" FAIL "preflight rc=$rc NO_GO on: $failed | $(for c in $failed; do printf '%s: %s; ' "$c" "$(e2e_verdict_detail "$E2E_EVIDENCE/V1R-verdict.json" "$c" | cut -c1-300)"; done)"
  e2e_load_stop V1R >/dev/null; exit 1
fi
ack="$(e2e_verdict_ack "$E2E_EVIDENCE/V1R-verdict.json")"
e2e_result "$S" PASS "preflight GO with an added row and an empty acknowledgement file; ack $ack"
rc=0; e2e_deploy V1R "$C" --pricing-diff-sha256 "$ack" --preflight-verdict "$E2E_EVIDENCE/V1R-verdict.json" || rc=$?
sleep 5
load="$(e2e_load_stop V1R)"
ph="$(e2e_txn_phase)"; live="$(live_label)"
leftover="$(vm 'ls -d /tmp/macprovider-pricing-candidate.* /tmp/macprovider-autotune-lock.* 2>/dev/null | tr "\n" " "')"
if [ "$rc" = 0 ] && [ "$ph" = none ] && [ "$live" = "$label" ] && [ -z "$leftover" ] &&
   grep -q 'pricing: rate table .* live (diff ' "$E2E_LOGS/V1R-deploy.log"; then
  e2e_result "$S" PASS "deploy rc=0, journal finalized, live=$label, no helper/candidate dirs left: $(grep -m1 'pricing: rate table' "$E2E_LOGS/V1R-deploy.log")"
else
  e2e_result "$S" FAIL "deploy rc=$rc journal=$ph live=$live (want $label) leftover=[$leftover]: $(grep -E 'ERROR|FAILED|ALERT|refus|not mutating' "$E2E_LOGS/V1R-deploy.log" | head -n 5 | tr '\n' '|')"
fi
verdict="$(e2e_oracle V1R --expect-labels "$label" || true)"
printf '%s\n' "$verdict" >"$E2E_EVIDENCE/V1R-oracle.json"
if python3 -c 'import json,sys;sys.exit(0 if json.loads(sys.stdin.read())["ok"] else 1)' <<<"$verdict"; then
  e2e_result "$S" PASS "O1-O6 ok (prior $prior); load: $load"
else
  e2e_result "$S" FAIL "oracle: $(cut -c1-1200 <<<"$verdict"); load: $load"
fi
