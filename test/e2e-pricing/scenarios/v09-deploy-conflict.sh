#!/usr/bin/env bash
# V9 deploy-and-pricing conflict (runbook §Deploy-and-pricing conflict):
# a pricing journal is open (the lane is kill -9'd at `verifying`: candidate pair
# on disk) AND a coordinator deploy rollback snapshot exists (synthesized as a
# deploy that died right after arming its transaction: lib/synth-deploy-
# snapshot.sh, a port of deploy-pearl-vps.sh step 4/9 - the guarded tools cannot
# create this state; a pre-#1693 deploy tag or a hand change can).
# Then `coordinator-pricing-recover --resolve-deploy-conflict` (runbook step 3):
#   r1 coordinator running                         -> exit 1, nothing changed
#   r2 mixed snapshot (prior yaml, candidate current+window) -> exit 1, nothing changed
#   r3 coherent snapshot, pre-#1693 snapshot binary -> exit 1, nothing changed
#   r4 coherent CANDIDATE snapshot                  -> exit 0 resolved candidate; coordinator
#      stays stopped; disk = candidate pair; journal back; snapshot consumed
#   r5 coherent PRIOR snapshot (a second crashed deploy) -> exit 0 resolved prior
# Runbook step 5: start the coordinator: pre-start restores the prior pair, the
# closer finalizes; start the stopped sidecar timers; unfreeze. O1-O6 (+O2).
set -euo pipefail
. "$(dirname "$0")/../env.sh"
. "$E2E_HARNESS/lib/common.sh"
S=V9
e2e_write_ssh_config; e2e_tunnel_up; e2e_push_tools
vm "cat > /root/e2e/tools/phase-killer.sh && chmod 700 /root/e2e/tools/phase-killer.sh" <"$E2E_HARNESS/lib/phase-killer.sh"
vm "cat > /root/e2e/tools/synth-deploy-snapshot.sh && chmod 700 /root/e2e/tools/synth-deploy-snapshot.sh" <"$E2E_HARNESS/lib/synth-deploy-snapshot.sh"
/usr/bin/scp -F "$E2E_SSH_CONFIG" -q "$E2E_WORK/bins/$E2E_TAG_PRE/coordinator-linux-amd64" "$E2E_PEARL:/root/e2e/coordinator-pre1693"
vm "chmod 0750 /root/e2e/coordinator-pre1693"
n="${E2E_V9_SEQ:-$(( $(date +%s) + 19 ))}"
live_label() { vm "python3 -c 'import json;print(json.load(open(\"/opt/macprovider/autotune/current/release.json\"))[\"release_id\"])'"; }
resolve() { vm 'python3 -I /opt/macprovider/coordinator-pricing-recover --resolve-deploy-conflict'; }
digest() { printf '%s %s' "$(e2e_host_hash)" "$(vm 'systemctl show -p MainPID --value macprovider-coordinator; systemctl is-active macprovider-coordinator || true' | tr '\n' ' ')"; }
drop_snapshot() { vm 'rm -rf /opt/macprovider/.coordinator-deploy-rollback'; }

prior="$(live_label)"
e2e_checkout main
jq -n --arg rid "e2e-v9-$n" --argjson p "$((29000 + (n % 5000)))" \
  '{release_id: $rid, message: "E2E V9 deploy-and-pricing conflict", change: {"meta-llama/llama-3.2-3b-instruct": [$p, ($p/4|floor), ($p*2)]}, acks: []}' >"$E2E_WORK/v9.json"
C="$(bash "$E2E_HARNESS/lib/make-pricing-commit.sh" main "$E2E_WORK/v9.json")"
label="e2e-v9-$n"; e2e_checkout main
e2e_baseline V9
rc=0; e2e_preflight V9 "$C" || rc=$?
[ "$rc" = 0 ] || { e2e_result "$S" FAIL "preflight NO_GO: $(e2e_verdict_failed "$E2E_EVIDENCE/V9-verdict.json")"; exit 1; }
ack="$(e2e_verdict_ack "$E2E_EVIDENCE/V9-verdict.json")"
e2e_load_start V9 --sampler
vm "rm -f /root/e2e/kill-v9 /root/e2e/kill-v9.trace; nohup /root/e2e/tools/phase-killer.sh verifying /root/e2e/kill-v9 1500 >/dev/null 2>&1 </dev/null &"
( cd "$E2E_REPO" && e2e_lane_env && exec perl -e 'setpgrp(0,0); exec @ARGV' bash scripts/catalog-content-release.sh --deploy --commit "$C" \
    --pricing-diff-sha256 "$ack" --preflight-verdict "$E2E_EVIDENCE/V9-verdict.json" ) >"$E2E_LOGS/V9-deploy.log" 2>&1 &
lane=$!
killed=""
for _ in $(seq 1 1500); do
  killed="$(vm 'cat /root/e2e/kill-v9 2>/dev/null' || true)"; [ -n "$killed" ] && break
  kill -0 "$lane" 2>/dev/null || break; sleep 1
done
kill -9 -- "-$lane" 2>/dev/null || true; wait "$lane" 2>/dev/null || true
sleep 3
ph="$(e2e_txn_phase)"
if [ "${killed%% *}" != KILLED ] || [ "$ph" = none ]; then
  e2e_result "$S" FAIL "setup: lane not killed with an open journal (watcher=[$killed] journal=$ph)"; e2e_load_stop V9 >/dev/null; exit 1
fi
e2e_result "$S" INFO "setup: lane kill -9'd at $ph ($killed); journal open, candidate pair on disk"
# Runbook step 1 (freeze): stop the updater timer; leave the journal alone.
vm 'systemctl stop macprovider-pearl-updater.timer 2>/dev/null || true'
vm 'python3 -c "import json;t=json.load(open(\"/opt/macprovider/.pricing-txn/txn.json\"));print(json.dumps({k:t[k] for k in (\"id\",\"phase\")}), t[\"prior\"][\"current\"], t[\"candidate\"][\"current\"], t[\"prior\"][\"window\"][\"present\"])"' >"$E2E_EVIDENCE/V9-txn.txt"
PRIOR_CUR="$(awk '{print $(NF-2)}' "$E2E_EVIDENCE/V9-txn.txt")"; PRIOR_WIN="$(awk '{print $NF}' "$E2E_EVIDENCE/V9-txn.txt")"

refused() { # <case> <expected message regex>
  local c="$1" want="$2" before after rc=0 out
  before="$(digest)"
  out="$(resolve 2>&1)" || rc=$?
  after="$(digest)"
  if [ "$rc" = 1 ] && grep -Eq "$want" <<<"$out" && [ "$before" = "$after" ]; then
    e2e_result "$S" PASS "$c: --resolve-deploy-conflict refused rc=1, nothing changed: $(grep -m1 -E "$want" <<<"$out" | cut -c1-260)"
  else
    e2e_result "$S" FAIL "$c: rc=$rc (want 1 /$want/) state $([ "$before" = "$after" ] && echo unchanged || echo CHANGED): $(tail -n 3 <<<"$out" | tr '\n' '|' | cut -c1-400)"
  fi
}

# r1: coordinator running (the crash left it up), coherent candidate snapshot.
vm '/root/e2e/tools/synth-deploy-snapshot.sh' >"$E2E_LOGS/V9-synth-r1.log" 2>&1
refused r1 'coordinator must be stopped'
# Runbook: "Leave the coordinator stopped."
vm 'systemctl stop macprovider-coordinator'
# r2: mixed snapshot: prior yaml with the candidate current + window.
drop_snapshot
vm 'SNAP_YAML=/opt/macprovider/.pricing-txn/prior-coordinator.yaml /root/e2e/tools/synth-deploy-snapshot.sh' >"$E2E_LOGS/V9-synth-r2.log" 2>&1
refused r2 'not one coherent journal pair'
# r3: coherent candidate pair, pre-#1693 snapshot binary.
drop_snapshot
vm 'SNAP_COORDINATOR=/root/e2e/coordinator-pre1693 /root/e2e/tools/synth-deploy-snapshot.sh' >"$E2E_LOGS/V9-synth-r3.log" 2>&1
refused r3 'lacks per-generation wholesale pricing'

resolved() { # <case> <side> <expected current target>
  local c="$1" side="$2" cur="$3" rc=0 out st
  out="$(resolve 2>&1)" || rc=$?
  st="$(vm 'test -e /opt/macprovider/.coordinator-deploy-rollback && echo snapshot-kept || echo snapshot-consumed; test -d /opt/macprovider/.pricing-txn && echo journal-back || echo journal-MISSING; ls -a /opt/macprovider | grep -c "^.pricing-txn.conflict-held" || true; systemctl is-active macprovider-coordinator || true' | tr '\n' ' ')"
  if [ "$rc" = 0 ] && grep -q "\"resolved\": \"$side\"" <<<"$out" && [ "$(vm 'readlink /opt/macprovider/autotune/current')" = "$cur" ] &&
     grep -q 'snapshot-consumed journal-back 0 inactive' <<<"$st"; then
    e2e_result "$S" PASS "$c: resolved $side rc=0 ($(grep -m1 '"resolved"' <<<"$out")); $st; disk current=$cur"
  else
    e2e_result "$S" FAIL "$c: rc=$rc want resolved $side, current=$cur; state: $st; out: $(tail -n 4 <<<"$out" | tr '\n' '|' | cut -c1-500)"
  fi
  printf '%s\n' "$out" >"$E2E_EVIDENCE/V9-$c.out"
}
# r4: coherent CANDIDATE pair (what a deploy that crashed now would have saved).
drop_snapshot
vm '/root/e2e/tools/synth-deploy-snapshot.sh' >"$E2E_LOGS/V9-synth-r4.log" 2>&1
resolved r4 candidate "$(vm 'readlink /opt/macprovider/autotune/current')"
# r5: a second crashed deploy whose snapshot carries the PRIOR pair.
win_env=""; [ "$PRIOR_WIN" = True ] && win_env="SNAP_WINDOW=/opt/macprovider/.pricing-txn/prior-window"
vm "SNAP_YAML=/opt/macprovider/.pricing-txn/prior-coordinator.yaml SNAP_CURRENT=$PRIOR_CUR $win_env /root/e2e/tools/synth-deploy-snapshot.sh" >"$E2E_LOGS/V9-synth-r5.log" 2>&1
resolved r5 prior "$PRIOR_CUR"

# Step 5: start the coordinator; pre-start takes the journal on, the closer
# finalizes; then the stopped sidecar timers; step 6 unfreeze.
vm 'systemctl start --no-block macprovider-coordinator'
for _ in $(seq 1 360); do
  [ "$(e2e_txn_phase)" = none ] && vm 'systemctl is-active --quiet macprovider-coordinator && curl -fsS -o /dev/null http://127.0.0.1:8444/healthz' && break
  sleep 5
done
timers="$(python3 -c 'import json,sys
t=set()
for f in sys.argv[1:]:
    for l in open(f):
        l=l.strip()
        if l.startswith("{"):
            try: t.update(json.loads(l).get("stopped_sidecar_timers") or [])
            except ValueError: pass
print(" ".join(sorted(t)))' "$E2E_EVIDENCE/V9-r4.out" "$E2E_EVIDENCE/V9-r5.out")"
[ -z "$timers" ] || vm "systemctl start $timers" || true
vm 'systemctl start macprovider-pearl-updater.timer 2>/dev/null || true'
sleep 10; load="$(e2e_load_stop V9)"
after="$(e2e_txn_phase)"; live="$(live_label)"
jr="$(vm 'journalctl -u macprovider-coordinator-deploy-recovery -u macprovider-coordinator-pricing-close --since "-20 min" -o cat --no-pager | grep -E "pricing-recover" | tail -n 4' | tr '\n' '|' | cut -c1-600)"
verdict="$(e2e_oracle V9 --expect-labels "$prior,$label" --sampler /root/e2e/load/V9/sampler.jsonl --o2-sequence "$prior,$label,$prior" || true)"
printf '%s\n' "$verdict" >"$E2E_EVIDENCE/V9-oracle.json"
ok="$(python3 -c 'import json,sys;print(json.loads(sys.stdin.read())["ok"])' <<<"$verdict" 2>/dev/null || echo False)"
msg="step 5: coordinator started -> journal=$after live=$live (want $prior); timers restarted: [${timers:-none}]; recovery: $jr; oracle ok=$ok; load=$load"
if [ "$after" = none ] && [ "$live" = "$prior" ] && [ "$ok" = True ]; then e2e_result "$S" PASS "$msg"
else e2e_result "$S" FAIL "$msg; oracle=$(cut -c1-1200 <<<"$verdict")"; fi
