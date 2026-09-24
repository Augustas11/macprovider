#!/usr/bin/env bash
# V1 happy path: a reviewed pricing PR changes 3 rows, adds 1, removes 1 (the
# removal moves the request-log name "e2e-legacy-model" onto `default`, acked)
# -> preflight GO -> deploy with the ack -> verified -> finalized; floor marker
# written; O1-O6 with a load generator + O2 sampler running across the SIGHUP.
set -euo pipefail
. "$(dirname "$0")/../env.sh"
. "$E2E_HARNESS/lib/common.sh"
S=V1
e2e_write_ssh_config
e2e_tunnel_up
e2e_push_tools
e2e_checkout main
BASE_COMMIT="$(git -C "$E2E_REPO" rev-parse main)"

# A buyer-controlled name that resolves to the row the PR removes. The request
# itself cannot be served (no provider serves it) but request_log records it.
vm 'k=$(cat /root/e2e/buyer-api-key); for i in 1 2 3; do curl -s -o /dev/null -w "%{http_code} " -H "Authorization: Bearer $k" -H "Content-Type: application/json" \
  -d "{\"model\":\"e2e-legacy-model\",\"max_tokens\":8,\"messages\":[{\"role\":\"user\",\"content\":\"legacy\"}]}" http://127.0.0.1:9443/v1/chat/completions; done; echo;
  sqlite3 /var/lib/macprovider/request-log.sqlite "select count(*) from request_log where model=\"e2e-legacy-model\""'

spec="$E2E_HARNESS/specs/v1-pricing.json"
COMMIT="$(bash "$E2E_HARNESS/lib/make-pricing-commit.sh" main "$spec")"
echo "$COMMIT" >"$E2E_EVIDENCE/V1.commit"
e2e_tables_add B "$COMMIT"
e2e_checkout main
[ "$(git -C "$E2E_REPO" rev-parse main)" = "$COMMIT" ] || e2e_die "main did not advance to the V1 commit"

e2e_baseline V1
e2e_load_start V1 --sampler
rc=0; e2e_preflight V1 "$COMMIT" || rc=$?
failed="$(e2e_verdict_failed "$E2E_EVIDENCE/V1-verdict.json")"
if [ "$rc" != 0 ]; then
  e2e_result "$S" FAIL "preflight rc=$rc NO_GO on: $failed | $(for c in $failed; do printf '%s: %s; ' "$c" "$(e2e_verdict_detail "$E2E_EVIDENCE/V1-verdict.json" "$c" | cut -c1-300)"; done)"
  e2e_load_stop V1 >/dev/null; exit 1
fi
ACK="$(e2e_verdict_ack "$E2E_EVIDENCE/V1-verdict.json")"
grep -F '[catalog-content]   ' "$E2E_LOGS/V1-preflight.log" | grep -F -- '->' >"$E2E_EVIDENCE/V1-price-table.txt" || true
e2e_result "$S" PASS "preflight GO; ack $ACK; price table: $(tr '\n' '|' <"$E2E_EVIDENCE/V1-price-table.txt")"

rc=0; e2e_deploy V1 "$COMMIT" --pricing-diff-sha256 "$ACK" --preflight-verdict "$E2E_EVIDENCE/V1-verdict.json" || rc=$?
sleep 5
load="$(e2e_load_stop V1)"
if [ "$rc" = 0 ] && grep -q 'pricing: rate table .* live (diff ' "$E2E_LOGS/V1-deploy.log"; then
  e2e_result "$S" PASS "deploy rc=0: $(grep -m1 'pricing: rate table' "$E2E_LOGS/V1-deploy.log"); $(grep -m1 -E 'gateway convergence|ALERT \(informational' "$E2E_LOGS/V1-deploy.log" || echo 'no gateway line')"
else
  e2e_result "$S" FAIL "deploy rc=$rc: $(grep -E 'ERROR|FAILED|ALERT|refus' "$E2E_LOGS/V1-deploy.log" | head -n 5 | tr '\n' '|')"
fi
floor="$(vm 'cat /opt/macprovider/.pricing-runtime-floor 2>/dev/null; stat -c %a:%U /opt/macprovider/.pricing-runtime-floor 2>/dev/null' | tr '\n' ' ')"
case "$floor" in *"commit=$COMMIT"*"644:root"*) e2e_result "$S" PASS "floor marker: $floor" ;; *) e2e_result "$S" FAIL "floor marker wrong/missing: $floor" ;; esac
verdict="$(e2e_oracle V1 --expect-snapshots 1 --expect-labels B --sampler /root/e2e/load/V1/sampler.jsonl --o2-sequence A,B || true)"
printf '%s\n' "$verdict" >"$E2E_EVIDENCE/V1-oracle.json"
if python3 -c 'import json,sys;sys.exit(0 if json.loads(sys.stdin.read())["ok"] else 1)' <<<"$verdict"; then
  e2e_result "$S" PASS "O1-O6 ok; load: $load"
else
  e2e_result "$S" FAIL "oracle: $verdict; load: $load"
fi
