#!/usr/bin/env bash
# V3 (SPEC-023-R018 rule 2): acknowledgement binding.
#  a) --pricing-diff-sha256 of a different table -> exit 3, host unchanged
#  b) a NEW request-log name that moves rows appears between preflight and deploy,
#     deploy WITH --preflight-verdict -> refused (unacked move of a new name), unchanged
#  c) a NEW benign name (resolves to default before and after) appears, deploy
#     WITHOUT --preflight-verdict -> refused (the re-derived name set moves the digest)
#  d) same benign situation, deploy WITH --preflight-verdict -> accepted (rc 0)
set -euo pipefail
. "$(dirname "$0")/../env.sh"
. "$E2E_HARNESS/lib/common.sh"
S=V3
e2e_write_ssh_config; e2e_tunnel_up; e2e_push_tools
n="${E2E_V3_SEQ:-$(( $(date +%s) + 3 ))}"
seed() { # <model name as a JSON string literal>
  local b; b="$(printf '%s' "$1" | base64 | tr -d '\n')"
  vm "python3 -c 'import base64,datetime,json,sqlite3,sys,uuid
m = json.loads(base64.b64decode(sys.argv[1]).decode(), strict=False)
con = sqlite3.connect(\"/var/lib/macprovider/request-log.sqlite\", timeout=30)
ts = datetime.datetime.now(datetime.timezone.utc).strftime(\"%Y-%m-%dT%H:%M:%S.%fZ\")
con.execute(\"INSERT INTO request_log (ts_utc, request_id, model, latency_ms, routing_ms, status, stream) VALUES (?,?,?,?,?,?,?)\", (ts, \"e2e-seed-\" + uuid.uuid4().hex, m, 10.0, 1.0, 200, 0))
con.commit(); print(\"seeded\", repr(m))' $b"
}
req() { vm "k=\$(cat /root/e2e/buyer-api-key); curl -s -o /dev/null -w '%{http_code}' -H \"Authorization: Bearer \$k\" -H 'Content-Type: application/json' -d '{\"model\":\"$1\",\"max_tokens\":8,\"messages\":[{\"role\":\"user\",\"content\":\"x\"}]}' http://127.0.0.1:9443/v1/chat/completions"; }
e2e_checkout main
jq -n --arg rid "e2e-v3-$n" --argjson p "$((31000 + (n % 5000)))" \
  '{release_id: $rid, message: "E2E V3 ack binding", change: {"meta-llama/llama-3.2-3b-instruct": [$p, ($p/4|floor), ($p*2)]}, remove: ["e2e-legacy-model"], acks: [{"model":"e2e-legacy-model","from_row":"e2e-legacy-model","to_row":"default"}]}' >"$E2E_WORK/v3.json"
# e2e-legacy-model may already be gone (V1 removed it): drop the removal then.
if ! git -C "$E2E_REPO" show main:phase3-binary/catalog/autotune/rate-card-source.json | grep -q '"e2e-legacy-model"'; then
  jq 'del(.remove) | .acks = []' "$E2E_WORK/v3.json" >"$E2E_WORK/v3.tmp" && mv "$E2E_WORK/v3.tmp" "$E2E_WORK/v3.json"
fi
C="$(bash "$E2E_HARNESS/lib/make-pricing-commit.sh" main "$E2E_WORK/v3.json")"
e2e_tables_add V3 "$C"; e2e_checkout main
rc=0; e2e_preflight V3 "$C" || rc=$?
[ "$rc" = 0 ] || { e2e_result "$S" FAIL "preflight NO_GO: $(e2e_verdict_failed "$E2E_EVIDENCE/V3-verdict.json")"; exit 1; }
ack="$(e2e_verdict_ack "$E2E_EVIDENCE/V3-verdict.json")"

check() { # <case> <want rc regex> <deploy args...>
  local c="$1" want="$2" before after rc=0; shift 2
  before="$(e2e_host_hash)"
  e2e_deploy "V3$c" "$C" "$@" || rc=$?
  after="$(e2e_host_hash)"
  local why; why="$(grep -E 'pricing|refus|NO_GO|ERROR|does not match|moved' "$E2E_LOGS/V3$c-deploy.log" | grep -v 'effective price changes' | tail -n 3 | tr '\n' '|' | cut -c1-500)"
  if grep -Eqx "$want" <<<"$rc" && { [ "$want" = 0 ] || [ "$before" = "$after" ]; }; then
    e2e_result "$S" PASS "case $c rc=$rc as expected ($why)"
  else
    e2e_result "$S" FAIL "case $c rc=$rc want=$want host_changed=$([ "$before" = "$after" ] && echo no || echo yes) ($why)"
  fi
}
check a 3 --pricing-diff-sha256 "$(printf '%064d' 0 | tr 0 a)" --preflight-verdict "$E2E_EVIDENCE/V3-verdict.json"
# b: a new name that moves rows (upper-case variant of a real row key resolves
# through NormalizeModelKey to meta-llama/llama-3.2-3b-instruct ... and the new
# qwen row capture is not in this release; use a Qwen3-4B alias that resolves to
# default today and to nothing else tomorrow -> benign). The moving new name is
# an explicit exact key that the release ADDs? none here, so b uses a name that
# the live binary resolves to the changed llama row: that is a price change, not
# a move, so it must be ACCEPTED under rule 2 unless it moves rows.
seed "\"e2e-benign-new-name-$n\""; code=seeded
check c '[1-9]' --pricing-diff-sha256 "$ack"
check d 0 --pricing-diff-sha256 "$ack" --preflight-verdict "$E2E_EVIDENCE/V3-verdict.json"
e2e_result "$S" GAP "case b (new name that MOVES rows between preflight and deploy) needs a row add/remove capturing a fresh name; covered by V2g1/V2h at preflight time only (new-name request code $code)"
