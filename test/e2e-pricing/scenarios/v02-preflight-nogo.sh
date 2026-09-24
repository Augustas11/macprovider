#!/usr/bin/env bash
# V2: every preflight NO_GO leaves the host untouched. Each case injects one
# defect, hashes the host (opt/etc/systemd/sbin/share/run), runs the real
# preflight, asserts rc=3 + the expected failing check, re-hashes, then removes
# the injection. Needs a pricing commit on origin/main (V1's spec is re-cut as
# V2's base when V1 has not run: E2E_V2_COMMIT overrides).
#   a foreign deploy snapshot   b stale installed updater   c overlay pricing key
#   e commit block != release rows   g1 unacked request-log move   g2 unacked
#   catalog-key move   h Unicode/bidi + case-variant request-log names
# (d "pre-#1693 record" runs from 04b-pre1693-preflight.sh while the old runtime is live.)
set -euo pipefail
. "$(dirname "$0")/../env.sh"
. "$E2E_HARNESS/lib/common.sh"
S=V2
e2e_write_ssh_config
e2e_tunnel_up
e2e_push_tools

# pricing commits used here are cut on a side branch (never merged to the bare
# main) unless they need to be on origin/main for the `commit` check; they are
# pushed as main then main is reset back by force in the bare repo afterwards.
push_tmp() { # <spec> -> commit on origin/main (restored by restore_main)
  bash "$E2E_HARNESS/lib/make-pricing-commit.sh" main "$1"
}
ORIG_MAIN="$(git -C "$E2E_REPO" rev-parse origin/main)"
restore_main() {
  git -C "$E2E_REPO" push -q -f origin "$ORIG_MAIN:refs/heads/main"
  git -C "$E2E_REPO" fetch -q origin && git -C "$E2E_REPO" checkout -q main && git -C "$E2E_REPO" reset -q --hard origin/main
}

run_case() { # <case> <commit> <expected failing check regex> <inject cmd> <undo cmd>
  local c="$1" commit="$2" want="$3" inject="$4" undo="$5" before after rc=0 failed detail
  [ -z "$inject" ] || vm "$inject"
  before="$(e2e_host_hash)"
  e2e_preflight "V2$c" "$commit" || rc=$?
  after="$(e2e_host_hash)"
  [ -z "$undo" ] || vm "$undo"
  failed="$(e2e_verdict_failed "$E2E_EVIDENCE/V2$c-verdict.json")"
  detail="$(for x in $failed; do printf '%s: %s; ' "$x" "$(e2e_verdict_detail "$E2E_EVIDENCE/V2$c-verdict.json" "$x" | cut -c1-260)"; done)"
  if [ "$rc" = 3 ] && grep -Eq "$want" <<<"$failed" && [ "$before" = "$after" ]; then
    e2e_result "$S" PASS "case $c: NO_GO on [$failed], host unchanged ($before) | $detail"
  else
    e2e_result "$S" FAIL "case $c: rc=$rc failed=[$failed] want=/$want/ host_before=$before host_after=$after | $detail"
  fi
}

# Base pricing commit: V1's spec on a fresh release id (rows change vs live).
e2e_checkout main
# Runs after V1 (live has row qwen3-4b, no e2e-legacy-model): a pure price change.
p="$(( 40000 + $(date +%s) % 5000 ))"
jq -n --arg rid "e2e-v2-base-$(date +%s)" --argjson p "$p" \
  '{release_id: $rid, message: "E2E V2 base pricing correction", change: {"meta-llama/llama-3.2-3b-instruct": [$p, ($p/4|floor), ($p*2)]}, acks: []}' >"$E2E_WORK/v2-base.json"
C_OK="${E2E_V2_COMMIT:-$(push_tmp "$E2E_WORK/v2-base.json")}"
e2e_checkout main

run_case a "$C_OK" 'pricing_host_state' \
  'install -d -m 0700 /opt/macprovider/.coordinator-deploy-rollback && touch /opt/macprovider/.coordinator-deploy-rollback/e2e-injected' \
  'rm -rf /opt/macprovider/.coordinator-deploy-rollback'
run_case b "$C_OK" 'pricing_host_state' \
  'cp -p /usr/local/sbin/macprovider-pearl-update /root/e2e/updater.bak && echo "# e2e stale copy" >> /usr/local/sbin/macprovider-pearl-update' \
  'cp -p /root/e2e/updater.bak /usr/local/sbin/macprovider-pearl-update'
run_case c "$C_OK" 'pricing_host_state' \
  'cp -p /etc/macprovider/coordinator.pearl-overlays.yaml /root/e2e/overlay.bak && printf "rewards:\n  provider_share: 0.9\n" >> /etc/macprovider/coordinator.pearl-overlays.yaml' \
  'cp -p /root/e2e/overlay.bak /etc/macprovider/coordinator.pearl-overlays.yaml'
restore_main

# e: the committed coordinator.yaml block disagrees with the release rows.
e2e_checkout main
jq '.release_id = ("e2e-v2e-" + (now|tostring|.[0:10]))' "$E2E_WORK/v2-base.json" >"$E2E_WORK/v2e.json"
C_E="$(E2E_NO_PUSH=1 bash "$E2E_HARNESS/lib/make-pricing-commit.sh" main "$E2E_WORK/v2e.json")"
git -C "$E2E_REPO" checkout -q --detach "$C_E"
python3 - "$E2E_REPO/phase4-coordinator/dist/coordinator.yaml" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p).read()
m = re.search(r"(    meta-llama/llama-3\.2-3b-instruct:\n(?:      .*\n)*?      completion_credits_per_mtok: )(\d+)", s)
s = s[:m.start(2)] + str(int(m.group(2)) + 1) + s[m.end(2):]
open(p, "w").write(s)
PY
git -C "$E2E_REPO" commit -q -am "E2E V2e: coordinator.yaml block drifts from the release rows"
C_E="$(git -C "$E2E_REPO" rev-parse HEAD)"
git -C "$E2E_REPO" push -q origin "$C_E:refs/heads/main"; git -C "$E2E_REPO" fetch -q origin
e2e_checkout main 2>/dev/null || { git -C "$E2E_REPO" checkout -q main; git -C "$E2E_REPO" reset -q --hard origin/main; }
run_case e "$C_E" 'pricing_release|content_gate' '' ''
restore_main

# g1: remove row qwen3-4b acking only its own key; the request-log-only name
# "qwen/qwen3-4b" (normalizes onto that row) moves qwen3-4b -> default unacked.
vm 'k=$(cat /root/e2e/buyer-api-key); curl -s -o /dev/null -H "Authorization: Bearer $k" -H "Content-Type: application/json" -d "{\"model\":\"qwen/qwen3-4b\",\"max_tokens\":64,\"messages\":[{\"role\":\"user\",\"content\":\"x\"}]}" http://127.0.0.1:9443/v1/chat/completions'
e2e_checkout main
jq '.release_id = ("e2e-v2g1-" + (now|tostring|.[0:10])) | .remove = ["qwen3-4b"] | .acks = [{"model":"qwen3-4b","from_row":"qwen3-4b","to_row":"default"}]' "$E2E_WORK/v2-base.json" >"$E2E_WORK/v2g1.json"
C_G1="$(push_tmp "$E2E_WORK/v2g1.json")"; e2e_checkout main
run_case g1 "$C_G1" 'pricing_effective_diff|coordinator_dry_load' '' ''
restore_main

# g2: an added exact row captures a catalog key that resolved to another row.
e2e_checkout main
jq '.release_id = ("e2e-v2g2-" + (now|tostring|.[0:10])) | .add["qwen/qwen3-30b-a3b-instruct-2507"] = [70000, 17500, 140000]' "$E2E_WORK/v2-base.json" >"$E2E_WORK/v2g2.json"
C_G2="$(push_tmp "$E2E_WORK/v2g2.json")"; e2e_checkout main
run_case g2 "$C_G2" 'pricing_effective_diff|coordinator_dry_load|content_gate' '' ''
restore_main

# h: buyer-controlled names outside the key grammar in request_log: a bidi
# override, a zero-width joiner and an upper-case variant of the removed row
# (resolved by the live binary). The upper-case one moves rows without an ack.
vm_script <<'SH'
k=$(cat /root/e2e/buyer-api-key)
for m in 'Qwen/Qwen3-4B' 'qwen3-4b‮gnp.exe' 'qwen3‍4b'; do
  curl -s -o /dev/null -w "%{http_code} " -H "Authorization: Bearer $k" -H "Content-Type: application/json" \
    -d "{\"model\":\"$m\",\"max_tokens\":64,\"messages\":[{\"role\":\"user\",\"content\":\"x\"}]}" http://127.0.0.1:9443/v1/chat/completions
done; echo
sqlite3 /var/lib/macprovider/request-log.sqlite "select distinct hex(model) from request_log where lower(model) like '%qwen3%4b%'"
SH
e2e_checkout main
jq '.release_id = ("e2e-v2h-" + (now|tostring|.[0:10])) | .remove = ["qwen3-4b"] | .acks = [{"model":"qwen3-4b","from_row":"qwen3-4b","to_row":"default"},{"model":"qwen/qwen3-4b","from_row":"qwen3-4b","to_row":"default"}]' "$E2E_WORK/v2-base.json" >"$E2E_WORK/v2h.json"
C_H="$(push_tmp "$E2E_WORK/v2h.json")"; e2e_checkout main
run_case h "$C_H" 'pricing_effective_diff|coordinator_dry_load' '' ''
grep -a -F '[catalog-content]   ' "$E2E_LOGS/V2h-preflight.log" >"$E2E_EVIDENCE/V2h-price-table.txt" || true
if LC_ALL=C grep -q $'\xe2\x80\xae\|\xe2\x80\x8d' "$E2E_LOGS/V2h-preflight.log"; then
  e2e_result "$S" FAIL "case h: a raw bidi/zero-width code point reached the operator's terminal output"
else
  e2e_result "$S" PASS "case h: no raw bidi/zero-width code point in the lane output; table: $(tr '\n' '|' <"$E2E_EVIDENCE/V2h-price-table.txt" | cut -c1-600)"
fi
restore_main
