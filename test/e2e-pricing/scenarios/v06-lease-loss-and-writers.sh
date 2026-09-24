#!/usr/bin/env bash
# V6 lease loss + V7 concurrent writers during an open transaction.
# V6: deploy a pricing release; when the journal reaches `verifying` (evidence
#     phase), kill -9 ONLY the lease runner on Pearl (the ssh-side bash that took
#     both locks). Expect: lane exit 6 "LEASE LOST", no rollback, journal kept.
# V7: with that journal open, every other writer must refuse and change nothing
#     (yaml sha, overlay sha, applied-record loaded_at unchanged, no SIGHUP):
#     deploy-pearl-vps.sh (exit 12), content-lane preflight (pricing_txn_absent),
#     Pearl updater --apply, Tier-2 enforcement watchdog --reconcile, Tier-2
#     activation script --apply (shell guard, exit 75), deploy watchdog unit.
# Then --recover-pricing-txn restores the prior pair; O1-O6.
set -euo pipefail
. "$(dirname "$0")/../env.sh"
. "$E2E_HARNESS/lib/common.sh"
e2e_write_ssh_config
e2e_tunnel_up
e2e_push_tools
n="${E2E_V6_SEQ:-$(( $(date +%s) + 13 ))}"
live_label() { vm "python3 -c 'import json;print(json.load(open(\"/opt/macprovider/autotune/current/release.json\"))[\"release_id\"])'"; }
state() { vm 'sha256sum /opt/macprovider/coordinator.yaml /etc/macprovider/coordinator.pearl-overlays.yaml | cut -c1-16 | tr "\n" " "; readlink /opt/macprovider/autotune/current; python3 -c "import json;r=json.load(open(\"/run/macprovider/coordinator-applied-config.json\"));print(r[\"loaded_at\"], r.get(\"billing_snapshot_id\"))"; systemctl show -p MainPID --value macprovider-coordinator' | tr '\n' ' '; }

prior="$(live_label)"
e2e_checkout main
jq -n --arg rid "e2e-v6-$n" --argjson p "$((26000 + (n % 5000)))" \
  '{release_id: $rid, message: "E2E V6 lease loss", change: {"meta-llama/llama-3.2-3b-instruct": [$p, ($p/4|floor), ($p*2)]}, acks: []}' >"$E2E_WORK/v6.json"
C="$(bash "$E2E_HARNESS/lib/make-pricing-commit.sh" main "$E2E_WORK/v6.json")"
label="e2e-v6-$n"; e2e_checkout main
e2e_baseline V6
rc=0; e2e_preflight V6 "$C" || rc=$?
[ "$rc" = 0 ] || { e2e_result V6 FAIL "preflight NO_GO: $(e2e_verdict_failed "$E2E_EVIDENCE/V6-verdict.json")"; exit 1; }
ack="$(e2e_verdict_ack "$E2E_EVIDENCE/V6-verdict.json")"
e2e_load_start V6
# Watcher: at `verifying`, kill -9 only the lock holder whose parent is sshd.
vm "cat > /root/e2e/tools/kill-runner.sh" <<'SH'
set -u
for _ in $(seq 1 3000); do
  p="$(python3 -c 'import json;print(json.load(open("/opt/macprovider/.pricing-txn/txn.json"))["phase"])' 2>/dev/null || echo none)"
  if [ "$p" = verifying ]; then
    for pid in $(fuser /opt/macprovider/.coordinator-deploy.lock 2>/dev/null); do
      pp="$(ps -o ppid= -p "$pid" | tr -d ' ')"
      case "$(ps -o comm= -p "$pp")" in sshd*) kill -9 "$pid"; echo "KILLED runner $pid (parent $pp) at $p" >/root/e2e/v6-killed; exit 0 ;; esac
    done
  fi
  sleep 0.1
done
echo TIMEOUT >/root/e2e/v6-killed
SH
vm "rm -f /root/e2e/v6-killed; nohup bash /root/e2e/tools/kill-runner.sh >/dev/null 2>&1 </dev/null &"
rc=0; e2e_deploy V6 "$C" --pricing-diff-sha256 "$ack" --preflight-verdict "$E2E_EVIDENCE/V6-verdict.json" || rc=$?
killed="$(vm 'cat /root/e2e/v6-killed 2>/dev/null')"
ph="$(e2e_txn_phase)"
if [ "$rc" = 6 ] && [ "$ph" != none ] && grep -q 'LEASE LOST' "$E2E_LOGS/V6-deploy.log" && ! grep -q 'rolling back' "$E2E_LOGS/V6-deploy.log"; then
  e2e_result V6 PASS "lane rc=6 LEASE LOST, no in-lane rollback, journal kept in phase $ph ($killed)"
else
  e2e_result V6 FAIL "lane rc=$rc journal=$ph ($killed): $(grep -E 'LEASE|rolling|ALERT|ERROR' "$E2E_LOGS/V6-deploy.log" | head -n 5 | tr '\n' '|')"
fi
sleep 5

# ---- V7: every writer refuses while the journal is open ------------------------------
before="$(state)"
w() { # <name> <expected rc regex> <cmd...>
  local name="$1" want="$2" rc=0 out after; shift 2
  out="$("$@" 2>&1)" || rc=$?
  after="$(state)"
  if grep -Eqx "$want" <<<"$rc" && [ "$before" = "$after" ]; then
    e2e_result V7 PASS "$name refused rc=$rc, yaml/overlay/current/applied-record/pid unchanged: $(grep -m1 -iE 'refus|journal|pricing' <<<"$out" | cut -c1-240)"
  else
    e2e_result V7 FAIL "$name rc=$rc (want $want); state before=[$before] after=[$after]: $(tail -n 3 <<<"$out" | tr '\n' '|' | cut -c1-400)"
  fi
}
e2e_checkout "$E2E_TAG_ENABLE"
w "deploy-pearl-vps.sh" 12 bash -c "cd '$E2E_REPO' && . '$E2E_HARNESS/env.sh' && . '$E2E_HARNESS/lib/common.sh' && e2e_lane_env && bash phase4-coordinator/dist/deploy-pearl-vps.sh"
e2e_checkout main
w "content lane --preflight" 3 e2e_lane --preflight --commit "$C"
w "Pearl updater --apply" '[1-9][0-9]*' vm '/usr/local/sbin/macprovider-pearl-update --apply --tag v90.1.0'
w "Tier-2 enforcement watchdog --reconcile" '[0-9]+' vm '/usr/local/sbin/macprovider-tier2-enforcement-watchdog --reconcile'
w "activate-tier2-encrypted-leg.sh --apply" '[1-9][0-9]*' bash -c "cd '$E2E_REPO' && . '$E2E_HARNESS/env.sh' && . '$E2E_HARNESS/lib/common.sh' && e2e_lane_env && SSH_BIN='$E2E_HARNESS/bin/ssh' DEMO_TOKEN=x OPERATOR_KEY=\$(cat '$E2E_KEYS/operator_key') bash scripts/activate-tier2-encrypted-leg.sh --apply"
w "deploy watchdog unit start" '[0-9]+' vm 'systemctl start macprovider-coordinator-deploy-watchdog.service; sleep 5; journalctl -u macprovider-coordinator-deploy-watchdog -n 5 -o cat --no-pager'
w "shell guard ccg_refuse_if_pricing_txn" 75 vm '. /opt/macprovider/coordinator-config-guard.sh && ccg_refuse_if_pricing_txn /opt/macprovider'

# ---- recover ------------------------------------------------------------------------------
rc=0; e2e_recover V6 || rc=$?
sleep 5; load="$(e2e_load_stop V6)"
after="$(e2e_txn_phase)"; live="$(live_label)"
verdict="$(e2e_oracle V6 --expect-labels "$prior,$label" || true)"
printf '%s\n' "$verdict" >"$E2E_EVIDENCE/V6-oracle.json"
ok="$(python3 -c 'import json,sys;print(json.loads(sys.stdin.read())["ok"])' <<<"$verdict" 2>/dev/null || echo False)"
if [ "$rc" = 0 ] && [ "$after" = none ] && [ "$live" = "$prior" ] && [ "$ok" = True ]; then
  e2e_result V6 PASS "recover rc=0 restored $prior; oracle ok; load=$load"
else
  e2e_result V6 FAIL "recover rc=$rc journal=$after live=$live (want $prior) oracle=$ok $(cut -c1-1200 <<<"$verdict"); recover log: $(tail -n 4 "$E2E_LOGS/V6-recover.log" | tr '\n' '|')"
fi
