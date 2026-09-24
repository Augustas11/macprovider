#!/usr/bin/env bash
# V4: kill -9 the lane at each journal phase, then --recover-pricing-txn.
# For each phase: cut a fresh reviewed pricing commit (new release id, llama row
# moved), deploy it with load running, and when the VM watcher sees the journal
# at <phase> it kill -9s the lease runner + its running command on Pearl while
# the Mac controller's process group is kill -9'd. Expect: prepared / mutating
# / hup-intent / verifying -> recover restores the prior pair (exit 0);
# verified -> recover finalizes the candidate (exit 0). Then O1-O6.
# Usage: v04-kill-lane.sh [phase...]   (default: all five)
set -euo pipefail
. "$(dirname "$0")/../env.sh"
. "$E2E_HARNESS/lib/common.sh"
S=V4
e2e_write_ssh_config
e2e_tunnel_up
e2e_push_tools
vm "cat > /root/e2e/tools/phase-killer.sh && chmod 700 /root/e2e/tools/phase-killer.sh" <"$E2E_HARNESS/lib/phase-killer.sh"
phases="${*:-prepared mutating hup-intent verifying verified}"
n="${E2E_V4_SEQ:-$(date +%s)}"

live_label() { vm "python3 -c 'import json;print(json.load(open(\"/opt/macprovider/autotune/current/release.json\"))[\"release_id\"])'"; }

for ph in $phases; do
  n=$((n + 1))
  prior="$(live_label)"
  e2e_checkout main
  jq -n --arg rid "e2e-v4-$ph-$n" --argjson p "$((16000 + (n % 5000)))" \
    '{release_id: $rid, message: ("E2E V4 kill at " + $rid), change: {"meta-llama/llama-3.2-3b-instruct": [$p, ($p/4|floor), ($p*2)]}, acks: []}' \
    >"$E2E_WORK/v4-$ph.json"
  C="$(bash "$E2E_HARNESS/lib/make-pricing-commit.sh" main "$E2E_WORK/v4-$ph.json")"
  label="e2e-v4-$ph-$n"; e2e_checkout main
  e2e_baseline "V4$ph"
  e2e_load_start "V4$ph"
  rc=0; e2e_preflight "V4$ph" "$C" || rc=$?
  [ "$rc" = 0 ] || { e2e_result "$S" FAIL "$ph: preflight NO_GO: $(e2e_verdict_failed "$E2E_EVIDENCE/V4$ph-verdict.json")"; e2e_load_stop "V4$ph" >/dev/null; continue; }
  ack="$(e2e_verdict_ack "$E2E_EVIDENCE/V4$ph-verdict.json")"
  vm "rm -f /root/e2e/kill-$ph /root/e2e/kill-$ph.trace; nohup /root/e2e/tools/phase-killer.sh $ph /root/e2e/kill-$ph 1500 >/dev/null 2>&1 </dev/null &"
  # The lane in its own process group so the whole controller can be kill -9'd.
  ( cd "$E2E_REPO" && e2e_lane_env && exec perl -e 'setpgrp(0,0); exec @ARGV' bash scripts/catalog-content-release.sh --deploy --commit "$C" \
      --pricing-diff-sha256 "$ack" --preflight-verdict "$E2E_EVIDENCE/V4$ph-verdict.json" ) >"$E2E_LOGS/V4$ph-deploy.log" 2>&1 &
  lane=$!
  killed=""
  for _ in $(seq 1 1500); do
    killed="$(vm "cat /root/e2e/kill-$ph 2>/dev/null" || true)"
    [ -n "$killed" ] && break
    kill -0 "$lane" 2>/dev/null || break
    sleep 1
  done
  kill -9 -- "-$lane" 2>/dev/null || true; wait "$lane" 2>/dev/null || true
  trace="$(vm "cat /root/e2e/kill-$ph.trace 2>/dev/null | awk '{print \$3}' | tr '\n' ' '")"
  if [ -z "$killed" ] || [ "${killed%% *}" != KILLED ]; then
    e2e_result "$S" FAIL "$ph: journal never reached $ph (watcher: ${killed:-none}; trace: $trace; lane log tail: $(tail -n 3 "$E2E_LOGS/V4$ph-deploy.log" | tr '\n' '|'))"
    vm "pkill -f phase-killer.sh" || true; e2e_load_stop "V4$ph" >/dev/null
    continue
  fi
  sleep 3
  at="$(e2e_txn_phase)"
  rc=0; e2e_recover "V4$ph" || rc=$?
  after="$(e2e_txn_phase)"
  live="$(live_label)"
  sleep 5
  load="$(e2e_load_stop "V4$ph")"
  want="$prior"; [ "$ph" = verified ] && want="$label"
  verdict="$(e2e_oracle "V4$ph" --expect-labels "$prior,$label" || true)"
  printf '%s\n' "$verdict" >"$E2E_EVIDENCE/V4$ph-oracle.json"
  ok_oracle="$(python3 -c 'import json,sys;print(json.loads(sys.stdin.read())["ok"])' <<<"$verdict" 2>/dev/null || echo False)"
  msg="$ph: watcher=[$killed] trace=[$trace] journal after kill=$at; recover rc=$rc -> journal=$after; live=$live (want $want); oracle ok=$ok_oracle; recover log: $(grep -E 'coordinator-pricing-recover|recovery' "$E2E_LOGS/V4$ph-recover.log" | tail -n 3 | tr '\n' '|' | cut -c1-500); load=$load"
  if [ "$rc" = 0 ] && [ "$after" = none ] && [ "$live" = "$want" ] && [ "$ok_oracle" = True ]; then
    e2e_result "$S" PASS "$msg"
  else
    e2e_result "$S" FAIL "$msg; oracle=$(cut -c1-1500 <<<"$verdict")"
  fi
done
