#!/usr/bin/env bash
# V2 case d (run while the pre-#1693 runtime is live, i.e. between 04 and 05):
# a pricing release preflight must be NO_GO on pricing_host_state naming the
# enabling runtime release, and change nothing on the host.
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$E2E_HARNESS/lib/common.sh"
e2e_write_ssh_config; e2e_tunnel_up
ORIG_MAIN="$(git -C "$E2E_REPO" rev-parse origin/main)"
e2e_checkout main
jq '.release_id = "e2e-2026-09-24-release-v2d" | .message = "E2E V2d pricing on pre-#1693"' "$E2E_HARNESS/specs/v1-pricing.json" >"$E2E_WORK/v2d.json"
C="$(bash "$E2E_HARNESS/lib/make-pricing-commit.sh" main "$E2E_WORK/v2d.json")"
e2e_checkout main
before="$(e2e_host_hash)"; rc=0
e2e_preflight V2d "$C" || rc=$?
after="$(e2e_host_hash)"
failed="$(e2e_verdict_failed "$E2E_EVIDENCE/V2d-verdict.json")"
detail="$(e2e_verdict_detail "$E2E_EVIDENCE/V2d-verdict.json" pricing_host_state)"
hint="$(grep -q '#1693' <<<"$detail" && echo 'names the #1693 enabling runtime release' || echo 'does NOT show the runbook hint "#1693 enabling runtime release" (record detail is cut at 600 chars after the per-file list)')"
if [ "$rc" = 3 ] && grep -q pricing_host_state <<<"$failed" && [ "$before" = "$after" ]; then
  e2e_result V2 PASS "case d (pre-#1693 live): NO_GO [$failed]; host unchanged; detail $hint: $detail"
else
  e2e_result V2 FAIL "case d: rc=$rc failed=[$failed] pricing_host_state='$detail' host $([ "$before" = "$after" ] && echo unchanged || echo CHANGED)"
fi
git -C "$E2E_REPO" push -q -f origin "$ORIG_MAIN:refs/heads/main"
git -C "$E2E_REPO" fetch -q origin; git -C "$E2E_REPO" checkout -q main; git -C "$E2E_REPO" reset -q --hard origin/main
