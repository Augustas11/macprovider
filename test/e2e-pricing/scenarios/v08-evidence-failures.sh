#!/usr/bin/env bash
# V8 evidence failures -> the lane rolls yaml + current + window back together
# (exit 4) and proves the prior pair live, journal finalized:
#  stop   : `systemctl stop macprovider-coordinator` when the journal reaches verifying
#  lock   : hold an EXCLUSIVE SQLite write lock on coordinator.db from hup-intent for
#           25 s, so the SIGHUP's billing snapshot cannot commit ("billing config
#           reload rejected")
#  stale  : the served card stays stale: from hup-intent for 25 s the candidate's
#           rate-card.json is unreadable to the coordinator (mode 0000), so the
#           SIGHUP's feed reload keeps card A and the reload parity-rejects; the
#           mode is restored before the lane's evidence watch ends
# Usage: v08-evidence-failures.sh [stop|lock|stale ...]
set -euo pipefail
. "$(dirname "$0")/../env.sh"
. "$E2E_HARNESS/lib/common.sh"
S=V8
e2e_write_ssh_config; e2e_tunnel_up; e2e_push_tools; e2e_journal_capture "$S${E2E_RUN:+-$E2E_RUN}"
cases="${*:-stop lock stale}"
n="${E2E_V8_SEQ:-$(( $(date +%s) + 17 ))}"
live_label() { vm "python3 -c 'import json;print(json.load(open(\"/opt/macprovider/autotune/current/release.json\"))[\"release_id\"])'"; }
for c in $cases; do
  n=$((n + 1)); prior="$(live_label)"
  prior_state="$(vm 'sha256sum /opt/macprovider/coordinator.yaml | cut -c1-16; readlink /opt/macprovider/autotune/current; sha256sum /opt/macprovider/autotune/.previous-target 2>/dev/null | cut -c1-16' | tr '\n' ' ')"
  e2e_checkout main
  jq -n --arg rid "e2e-v8-$c-$n" --argjson p "$((36000 + (n % 5000)))" \
    '{release_id: $rid, message: "E2E V8 evidence failure", change: {"meta-llama/llama-3.2-3b-instruct": [$p, ($p/4|floor), ($p*2)]}, acks: []}' >"$E2E_WORK/v8-$c.json"
  C="$(bash "$E2E_HARNESS/lib/make-pricing-commit.sh" main "$E2E_WORK/v8-$c.json")"
  label="e2e-v8-$c-$n"; e2e_checkout main
  e2e_baseline "V8$c"
  rc=0; e2e_preflight "V8$c" "$C" || rc=$?
  [ "$rc" = 0 ] || { e2e_result "$S" FAIL "$c: preflight NO_GO: $(e2e_verdict_failed "$E2E_EVIDENCE/V8$c-verdict.json")"; continue; }
  ack="$(e2e_verdict_ack "$E2E_EVIDENCE/V8$c-verdict.json")"
  e2e_load_start "V8$c" --sampler
  case "$c" in
    stop) action='systemctl stop macprovider-coordinator'; at=verifying ;;
    stale) action='true'; at=hup-intent ;;  # phase-killer PHASE_ACTION=unreadable-card (2 ms poll)
    lock) action='nohup python3 -c "import sqlite3,time;c=sqlite3.connect(\"/var/lib/macprovider/request-log.sqlite\",timeout=60);c.execute(\"BEGIN EXCLUSIVE\");time.sleep(25);c.rollback()" >/root/e2e/v8-lock.log 2>&1 &'; at=hup-intent ;;
  esac
  vm "cat > /root/e2e/tools/v8-$c.sh" <<SH
for _ in \$(seq 1 6000); do
  p="\$(python3 -c 'import json;print(json.load(open("/opt/macprovider/.pricing-txn/txn.json"))["phase"])' 2>/dev/null || echo none)"
  if [ "\$p" = "$at" ]; then $action; echo "fired at \$p" >/root/e2e/v8-$c.fired; exit 0; fi
  sleep 0.05
done
SH
  if [ "$c" = lock ] || [ "$c" = stale ]; then
    pa=sqlite-lock; [ "$c" = stale ] && pa=unreadable-card
    vm "cat > /root/e2e/tools/phase-killer.sh && chmod 700 /root/e2e/tools/phase-killer.sh" <"$E2E_HARNESS/lib/phase-killer.sh"
    vm "rm -f /root/e2e/v8-$c.fired /root/e2e/v8-$c.fired.trace; PHASE_ACTION=$pa nohup /root/e2e/tools/phase-killer.sh hup-intent /root/e2e/v8-$c.fired 1500 >/dev/null 2>&1 </dev/null &"
  else
    vm "rm -f /root/e2e/v8-$c.fired; nohup bash /root/e2e/tools/v8-$c.sh >/dev/null 2>&1 </dev/null &"
  fi
  rc=0; e2e_deploy "V8$c" "$C" --pricing-diff-sha256 "$ack" --preflight-verdict "$E2E_EVIDENCE/V8$c-verdict.json" || rc=$?
  # E2E FIX: under `set -e` a plain `x=$(cmd)` assignment aborts the whole
  # script if cmd's exit status is nonzero (e.g. the .fired marker was never
  # written because the deploy failed before reaching the target phase, as
  # when the lease could not be acquired at all) -- tolerate that so the
  # remaining cases still run and this case's own result is still recorded.
  fired="$(vm "cat /root/e2e/v8-$c.fired 2>/dev/null" || true)"
  vm 'systemctl is-active --quiet macprovider-coordinator || systemctl start macprovider-coordinator' || true
  sleep 10
  load="$(e2e_load_stop "V8$c")"
  post_state="$(vm 'sha256sum /opt/macprovider/coordinator.yaml | cut -c1-16; readlink /opt/macprovider/autotune/current; sha256sum /opt/macprovider/autotune/.previous-target 2>/dev/null | cut -c1-16' | tr '\n' ' ')"
  ph="$(e2e_txn_phase)"; live="$(live_label)"
  verdict="$(e2e_oracle "V8$c" --expect-labels "$prior,$label" --sampler "/root/e2e/load/V8$c/sampler.jsonl" --o2-sequence "$prior,$label,$prior" || true)"
  printf '%s\n' "$verdict" >"$E2E_EVIDENCE/V8$c-oracle.json"
  ok="$(python3 -c 'import json,sys;print(json.loads(sys.stdin.read())["ok"])' <<<"$verdict" 2>/dev/null || echo False)"
  why="$(grep -E 'EVIDENCE|rolled back|ROLLBACK|ALERT|pricing journal' "$E2E_LOGS/V8$c-deploy.log" | head -n 6 | tr '\n' '|' | cut -c1-700)"
  msg="$c ($fired): lane rc=$rc; journal=$ph; live=$live (want $prior); yaml/current/window before=[$prior_state] after=[$post_state]; oracle ok=$ok; $why; load=$load"
  if [ "$rc" = 4 ] && [ "$ph" = none ] && [ "$live" = "$prior" ] && [ "$prior_state" = "$post_state" ] && [ "$ok" = True ]; then
    e2e_result "$S" PASS "$msg"
  else
    e2e_result "$S" FAIL "$msg; oracle=$(cut -c1-1200 <<<"$verdict")"
  fi
done
