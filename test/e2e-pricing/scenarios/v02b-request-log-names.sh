#!/usr/bin/env bash
# V2 cases g1/h with request_log names that actually exist. A buyer request for
# a model no provider serves is answered 404 before request_log records it, so
# "request-log-only" names are SEEDED here as past status-200 rows (synthetic
# history: the names a buyer used while some provider served them).
#   g1: remove row qwen3-4b acking only its own key; seeded name "qwen/qwen3-4b"
#       normalizes onto that row -> unacked move -> NO_GO
#   h : same removal acking qwen3-4b and qwen/qwen3-4b; seeded names outside the
#       key grammar: "Qwen/Qwen3-4B" (binary-resolved, moves -> NO_GO), a bidi
#       override and a zero-width joiner name -> must never reach the terminal raw
set -euo pipefail
. "$(dirname "$0")/../env.sh"
. "$E2E_HARNESS/lib/common.sh"
S=V2
e2e_write_ssh_config; e2e_tunnel_up
ORIG_MAIN="$(git -C "$E2E_REPO" rev-parse origin/main)"
restore_main() {
  git -C "$E2E_REPO" push -q -f origin "$ORIG_MAIN:refs/heads/main"
  git -C "$E2E_REPO" fetch -q origin && git -C "$E2E_REPO" checkout -q main && git -C "$E2E_REPO" reset -q --hard origin/main
}
seed() { # <model name as a JSON string literal>
  local b; b="$(printf '%s' "$1" | base64 | tr -d '\n')"
  vm "python3 -c 'import base64,datetime,json,sqlite3,sys,uuid
m = json.loads(base64.b64decode(sys.argv[1]).decode(), strict=False)
con = sqlite3.connect(\"/var/lib/macprovider/request-log.sqlite\", timeout=30)
ts = datetime.datetime.now(datetime.timezone.utc).strftime(\"%Y-%m-%dT%H:%M:%S.%fZ\")
con.execute(\"INSERT INTO request_log (ts_utc, request_id, model, latency_ms, routing_ms, status, stream) VALUES (?,?,?,?,?,?,?)\", (ts, \"e2e-seed-\" + uuid.uuid4().hex, m, 10.0, 1.0, 200, 0))
con.commit(); print(\"seeded\", repr(m))' $b"
}
run_case() { # <case> <commit> <want regex>
  local c="$1" commit="$2" want="$3" before after rc=0 failed detail
  before="$(e2e_host_hash)"
  e2e_preflight "V2$c" "$commit" || rc=$?
  after="$(e2e_host_hash)"
  failed="$(e2e_verdict_failed "$E2E_EVIDENCE/V2$c-verdict.json")"
  detail="$(for x in $failed; do printf '%s: %s; ' "$x" "$(e2e_verdict_detail "$E2E_EVIDENCE/V2$c-verdict.json" "$x" | cut -c1-400)"; done)"
  if [ "$rc" = 3 ] && grep -Eq "$want" <<<"$failed" && [ "$before" = "$after" ]; then
    e2e_result "$S" PASS "case $c: NO_GO on [$failed], host unchanged | $detail"
  else
    e2e_result "$S" FAIL "case $c: rc=$rc failed=[$failed] want=/$want/ host $([ "$before" = "$after" ] && echo unchanged || echo CHANGED) | $detail"
  fi
}
p="$(( 45000 + $(date +%s) % 5000 ))"
seed '"qwen/qwen3-4b"'
e2e_checkout main
jq -n --arg rid "e2e-v2g1b-$(date +%s)" --argjson p "$p" \
  '{release_id: $rid, message: "E2E V2g1b", change: {"meta-llama/llama-3.2-3b-instruct": [$p, ($p/4|floor), ($p*2)]}, remove: ["qwen3-4b"], acks: [{"model":"qwen3-4b","from_row":"qwen3-4b","to_row":"default"}]}' >"$E2E_WORK/v2g1b.json"
C="$(bash "$E2E_HARNESS/lib/make-pricing-commit.sh" main "$E2E_WORK/v2g1b.json")"; e2e_checkout main
run_case g1b "$C" 'pricing_effective_diff|coordinator_dry_load'
restore_main

seed '"Qwen/Qwen3-4B"'; seed '"qwen3-4b‮gnp.exe"'; seed '"qwen3‍4b"'; seed '"e2e\u001b[31mred"'
e2e_checkout main
jq -n --arg rid "e2e-v2hb-$(date +%s)" --argjson p "$p" \
  '{release_id: $rid, message: "E2E V2hb", change: {"meta-llama/llama-3.2-3b-instruct": [$p, ($p/4|floor), ($p*2)]}, remove: ["qwen3-4b"], acks: [{"model":"qwen3-4b","from_row":"qwen3-4b","to_row":"default"},{"model":"qwen/qwen3-4b","from_row":"qwen3-4b","to_row":"default"}]}' >"$E2E_WORK/v2hb.json"
C="$(bash "$E2E_HARNESS/lib/make-pricing-commit.sh" main "$E2E_WORK/v2hb.json")"; e2e_checkout main
run_case hb "$C" 'pricing_effective_diff|coordinator_dry_load'
grep -a -F '[catalog-content]   ' "$E2E_LOGS/V2hb-preflight.log" >"$E2E_EVIDENCE/V2hb-price-table.txt" || true
if LC_ALL=C grep -q $'\xe2\x80\xae\|\xe2\x80\x8d\|\x1b\[31m' "$E2E_LOGS/V2hb-preflight.log" "$E2E_EVIDENCE/V2hb-verdict.json"; then
  e2e_result "$S" FAIL "case hb: a raw bidi/zero-width/ESC code point reached the lane output or verdict"
else
  e2e_result "$S" PASS "case hb: no raw bidi/zero-width/ESC code point in lane output or verdict; table: $(tr '\n' '|' <"$E2E_EVIDENCE/V2hb-price-table.txt" | cut -c1-800)"
fi
restore_main
