#!/usr/bin/env bash
# V5: hard power-off Pearl at each journal phase, boot, and let the host recover
# on its own: deploy-recovery pre-start restores (or finalizes a terminal
# journal) before the coordinator boots; the closer finalizes
# `restored-unverified` from the boot record. The power-off is an in-guest
# SysRq 'o' fired by the phase watcher the moment the journal reaches <phase>
# (no sync, no clean shutdown; `limactl stop -f` from the Mac cannot hit a
# millisecond phase window), then `limactl stop -f` + start to reboot.
# Expect after boot, with no operator action: journal gone, the served pair is
# the prior (candidate for `verified`), O1-O6.
# Usage: v05-power-off.sh [phase...]
set -euo pipefail
. "$(dirname "$0")/../env.sh"
. "$E2E_HARNESS/lib/common.sh"
S=V5
e2e_write_ssh_config
e2e_tunnel_up
e2e_push_tools
phases="${*:-prepared mutating hup-intent verifying verified}"
n="${E2E_V5_SEQ:-$(( $(date +%s) + 7 ))}"
cp "$E2E_HARNESS/lib/phase-killer.sh" "$E2E_WORK/phase-poweroff.sh"

live_label() { vm "python3 -c 'import json;print(json.load(open(\"/opt/macprovider/autotune/current/release.json\"))[\"release_id\"])'"; }

wait_vm() { # until root ssh works again
  local i
  for i in $(seq 1 120); do e2e_write_ssh_config 2>/dev/null && e2e_repin_hostkey 2>/dev/null && vm true 2>/dev/null && return 0; sleep 5; done
  return 1
}

for ph in $phases; do
  n=$((n + 1))
  vm "cat > /root/e2e/tools/phase-poweroff.sh && chmod 700 /root/e2e/tools/phase-poweroff.sh" <"$E2E_WORK/phase-poweroff.sh"
  prior="$(live_label)"
  e2e_checkout main
  jq -n --arg rid "e2e-v5-$ph-$n" --argjson p "$((21000 + (n % 5000)))" \
    '{release_id: $rid, message: ("E2E V5 power-off at " + $rid), change: {"meta-llama/llama-3.2-3b-instruct": [$p, ($p/4|floor), ($p*2)]}, acks: []}' \
    >"$E2E_WORK/v5-$ph.json"
  C="$(bash "$E2E_HARNESS/lib/make-pricing-commit.sh" main "$E2E_WORK/v5-$ph.json")"
  label="e2e-v5-$ph-$n"; e2e_checkout main
  e2e_baseline "V5$ph"
  rc=0; e2e_preflight "V5$ph" "$C" || rc=$?
  [ "$rc" = 0 ] || { e2e_result "$S" FAIL "$ph: preflight NO_GO: $(e2e_verdict_failed "$E2E_EVIDENCE/V5$ph-verdict.json")"; continue; }
  ack="$(e2e_verdict_ack "$E2E_EVIDENCE/V5$ph-verdict.json")"
  e2e_load_start "V5$ph"
  vm "rm -f /root/e2e/off-$ph*; PHASE_ACTION=poweroff nohup /root/e2e/tools/phase-poweroff.sh $ph /root/e2e/off-$ph 1500 >/dev/null 2>&1 </dev/null &"
  ( cd "$E2E_REPO" && e2e_lane_env && exec perl -e 'setpgrp(0,0); exec @ARGV' bash scripts/catalog-content-release.sh --deploy --commit "$C" \
      --pricing-diff-sha256 "$ack" --preflight-verdict "$E2E_EVIDENCE/V5$ph-verdict.json" ) >"$E2E_LOGS/V5$ph-deploy.log" 2>&1 &
  lane=$!
  down=0
  for _ in $(seq 1 1500); do
    if ! /usr/bin/ssh -F "$E2E_SSH_CONFIG" -o ConnectTimeout=5 "$E2E_PEARL" true 2>/dev/null; then down=1; break; fi
    kill -0 "$lane" 2>/dev/null || break
    sleep 1
  done
  sleep 20
  kill -9 -- "-$lane" 2>/dev/null || true; wait "$lane" 2>/dev/null || true
  lane_tail="$(grep -E 'LEASE LOST|ERROR|exit|ALERT' "$E2E_LOGS/V5$ph-deploy.log" | tail -n 3 | tr '\n' '|')"
  if [ "$down" != 1 ]; then
    e2e_result "$S" FAIL "$ph: VM never powered off (journal never reached $ph?); lane: $lane_tail"
    continue
  fi
  limactl stop -f "$E2E_VM" >/dev/null 2>&1 || true
  limactl start "$E2E_VM" --timeout 20m >"$E2E_LOGS/V5$ph-boot.log" 2>&1 || true
  wait_vm || { e2e_result "$S" FAIL "$ph: VM did not come back"; exit 1; }
  e2e_tunnel_up
  # Give pre-start + coordinator boot + closer (<= 300 s lock wait + 120 s record wait) time.
  for _ in $(seq 1 90); do
    [ "$(e2e_txn_phase)" = none ] && vm 'systemctl is-active --quiet macprovider-coordinator' && break
    sleep 5
  done
  trace="$(vm "cat /root/e2e/off-$ph.trace 2>/dev/null | awk '{print \$3}' | tr '\n' ' '")"
  after="$(e2e_txn_phase)"
  units="$(vm 'for u in macprovider-coordinator macprovider-coordinator-deploy-recovery macprovider-coordinator-pricing-close; do printf "%s=%s " $u $(systemctl is-active $u); done; systemctl is-failed macprovider-pearl-updater-alert@macprovider-coordinator-pricing-close.service.service 2>/dev/null')"
  jr="$(vm 'journalctl -b -u macprovider-coordinator-deploy-recovery -u macprovider-coordinator-pricing-close -o cat --no-pager | grep -E "pricing-recover|pricing" | tail -n 6' | tr '\n' '|' | cut -c1-900)"
  manual=""
  if [ "$after" != none ]; then
    rrc=0; e2e_recover "V5$ph" || rrc=$?
    manual="journal left in '$after' after boot -> runbook --recover-pricing-txn rc=$rrc ($(grep -E 'coordinator-pricing-recover' "$E2E_LOGS/V5$ph-recover.log" | tail -n 2 | tr '\n' '|' | cut -c1-300)) -> $(e2e_txn_phase)"
  fi
  live="$(live_label)"
  want="$prior"; [ "$ph" = verified ] && want="$label"
  e2e_load_start "V5$ph-after"; sleep 30; load="$(e2e_load_stop "V5$ph-after")"
  verdict="$(e2e_oracle "V5$ph" --expect-labels "$prior,$label" || true)"
  printf '%s\n' "$verdict" >"$E2E_EVIDENCE/V5$ph-oracle.json"
  ok_oracle="$(python3 -c 'import json,sys;print(json.loads(sys.stdin.read())["ok"])' <<<"$verdict" 2>/dev/null || echo False)"
  msg="$ph: trace=[$trace] lane=[$lane_tail]; after boot journal=$after; $manual; live=$live (want $want) units: $units; recovery journal: $jr; oracle ok=$ok_oracle; load after boot=$load"
  if [ "$after" = none ] && [ "$live" = "$want" ] && [ "$ok_oracle" = True ]; then e2e_result "$S" PASS "$msg"
  else e2e_result "$S" FAIL "$msg; oracle=$(cut -c1-1500 <<<"$verdict")"; fi
done
