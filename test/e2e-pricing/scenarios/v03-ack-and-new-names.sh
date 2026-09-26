#!/usr/bin/env bash
# V3 (SPEC-023-R019 rule 2): acknowledgement binding.
#  a) --pricing-diff-sha256 of a different table -> exit 3, host unchanged
#  b) a NEW request-log name that moves rows appears between preflight and deploy,
#     deploy WITH --preflight-verdict -> refused (unacked move of a new name), unchanged.
#     Own commit: it ADDS row e2e-v3b-<n> (its own key needs no ack); after a GO
#     preflight a buyer name "E2E-V3B-<n>" (normalizes onto the new row; resolved
#     to `default` before) is recorded -> an unacknowledged move of a new name.
#     origin/main is put back afterwards (the commit never ships).
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
ORIG_MAIN="$(git -C "$E2E_REPO" rev-parse origin/main)"
restore_main() {
  git -C "$E2E_REPO" push -q -f origin "$ORIG_MAIN:refs/heads/main"
  git -C "$E2E_REPO" fetch -q origin && git -C "$E2E_REPO" checkout -q main && git -C "$E2E_REPO" reset -q --hard origin/main
}
check() { # <case> <commit> <want rc regex> <deploy args...>
  local c="$1" commit="$2" want="$3" before after rc=0; shift 3
  before="$(e2e_host_hash)"
  e2e_deploy "V3$c" "$commit" "$@" || rc=$?
  after="$(e2e_host_hash)"
  local why; why="$(grep -E 'pricing|refus|NO_GO|ERROR|does not match|moved|moves' "$E2E_LOGS/V3$c-deploy.log" | grep -v 'effective price changes' | tail -n 3 | tr '\n' '|' | cut -c1-600)"
  if grep -Eqx "$want" <<<"$rc" && { [ "$want" = 0 ] || [ "$before" = "$after" ]; }; then
    e2e_result "$S" PASS "case $c rc=$rc as expected ($why)"
  else
    e2e_result "$S" FAIL "case $c rc=$rc want=$want host_changed=$([ "$before" = "$after" ] && echo no || echo yes) ($why)"
  fi
}

# ---- b: a new moving name between preflight and deploy (own commit) -------------
e2e_checkout main
jq -n --arg rid "e2e-v3b-rel-$n" --arg row "e2e-v3b-$n" --argjson p "$((33000 + (n % 5000)))" \
  '{release_id: $rid, message: "E2E V3b added row", change: {"meta-llama/llama-3.2-3b-instruct": [$p, ($p/4|floor), ($p*2)]}, add: {($row): [8000, 2000, 16000]}, acks: []}' >"$E2E_WORK/v3b.json"
CB="$(bash "$E2E_HARNESS/lib/make-pricing-commit.sh" main "$E2E_WORK/v3b.json")"; e2e_checkout main
rc=0; e2e_preflight V3b "$CB" || rc=$?
if [ "$rc" != 0 ]; then
  e2e_result "$S" FAIL "case b: preflight NO_GO before the new name existed: $(e2e_verdict_failed "$E2E_EVIDENCE/V3b-verdict.json")"
else
  ackb="$(e2e_verdict_ack "$E2E_EVIDENCE/V3b-verdict.json")"
  seed "\"E2E-V3B-$n\""
  check b "$CB" '[1-9][0-9]*' --pricing-diff-sha256 "$ackb" --preflight-verdict "$E2E_EVIDENCE/V3b-verdict.json"
fi
restore_main

e2e_checkout main
jq -n --arg rid "e2e-v3-$n" --argjson p "$((31000 + (n % 5000)))" \
  '{release_id: $rid, message: "E2E V3 ack binding", change: {"meta-llama/llama-3.2-3b-instruct": [$p, ($p/4|floor), ($p*2)]}, remove: ["e2e-legacy-model"], acks: [{"model":"e2e-legacy-model","from_row":"e2e-legacy-model","to_row":"default"}]}' >"$E2E_WORK/v3.json"
# e2e-legacy-model may already be gone (V1 removed it): drop the removal then.
if [ "$(git -C "$E2E_REPO" show main:phase3-binary/catalog/autotune/rate-card-source.json | grep -c '"e2e-legacy-model"')" = 0 ]; then
  jq 'del(.remove) | .acks = []' "$E2E_WORK/v3.json" >"$E2E_WORK/v3.tmp" && mv "$E2E_WORK/v3.tmp" "$E2E_WORK/v3.json"
fi
C="$(bash "$E2E_HARNESS/lib/make-pricing-commit.sh" main "$E2E_WORK/v3.json")"
e2e_tables_add V3 "$C"; e2e_checkout main
rc=0; e2e_preflight V3 "$C" || rc=$?
[ "$rc" = 0 ] || { e2e_result "$S" FAIL "preflight NO_GO: $(e2e_verdict_failed "$E2E_EVIDENCE/V3-verdict.json")"; exit 1; }
ack="$(e2e_verdict_ack "$E2E_EVIDENCE/V3-verdict.json")"

check a "$C" 3 --pricing-diff-sha256 "$(printf '%064d' 0 | tr 0 a)" --preflight-verdict "$E2E_EVIDENCE/V3-verdict.json"
# c/d: a NEW benign name (resolves to `default` before and after) appears after
# the preflight: without the verdict the re-derived name set moves the digest.
seed "\"e2e-benign-new-name-$n\""
check c "$C" '[1-9]' --pricing-diff-sha256 "$ack"
prior="$(vm "python3 -c 'import json;print(json.load(open(\"/opt/macprovider/autotune/current/release.json\"))[\"release_id\"])'")"
e2e_baseline V3d; e2e_load_start V3d --sampler
check d "$C" 0 --pricing-diff-sha256 "$ack" --preflight-verdict "$E2E_EVIDENCE/V3-verdict.json"
sleep 5; load="$(e2e_load_stop V3d)"
label="$(jq -r .release_id "$E2E_WORK/v3.json")"
verdict="$(e2e_oracle V3d --expect-snapshots 1 --expect-labels "$label" --sampler /root/e2e/load/V3d/sampler.jsonl --o2-sequence "$prior,$label" || true)"
printf '%s\n' "$verdict" >"$E2E_EVIDENCE/V3d-oracle.json"
if python3 -c 'import json,sys;sys.exit(0 if json.loads(sys.stdin.read())["ok"] else 1)' <<<"$verdict"; then
  e2e_result "$S" PASS "case d O1-O6 ok (O2 sampler across the SIGHUP, $prior -> $label); load: $load"
else
  e2e_result "$S" FAIL "case d oracle: $(cut -c1-1200 <<<"$verdict"); load: $load"
fi
