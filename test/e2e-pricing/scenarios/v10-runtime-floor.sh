#!/usr/bin/env bash
# V10 pricing runtime floor (run after V1 wrote /opt/macprovider/.pricing-runtime-floor):
#  a) the NEW deploy script with a pre-#1693 coordinator binary as its incoming
#     artifact -> exit 12 "PRICING RUNTIME FLOOR" before any mutation;
#  b) the OLD (pre-#1693 tag) deploy script -> must not install the old runtime
#     (documented operator-rule gap; the runbook's marker check must catch it);
#  c) the Pearl updater asked to apply the pre-#1693 release -> PricingRuntimeFloorRefused;
#  d) deploy recovery asked to restore a snapshot whose coordinator is pre-#1693
#     -> refuses and keeps the snapshot.
# Each case asserts the host hash is unchanged (d: except the injected snapshot).
set -uo pipefail
. "$(dirname "$0")/../env.sh"
. "$E2E_HARNESS/lib/common.sh"
S=V10
e2e_write_ssh_config
e2e_tunnel_up
floor="$(vm 'cat /opt/macprovider/.pricing-runtime-floor 2>/dev/null' | tr '\n' ' ')"
[ -n "$floor" ] || { e2e_result "$S" FAIL "no floor marker (run V1 first)"; exit 1; }
deploy() { bash -c "cd '$E2E_REPO' && . '$E2E_HARNESS/env.sh' && . '$E2E_HARNESS/lib/common.sh' && e2e_lane_env && bash phase4-coordinator/dist/deploy-pearl-vps.sh"; }

case "${1:-}" in bc|c|restore-c) SKIP_A=1 ;; *) SKIP_A=0 ;; esac
# a) new script, old incoming binary
if [ "$SKIP_A" = 0 ]; then
e2e_checkout "$E2E_TAG_ENABLE"
cp "$E2E_WORK/bins/$E2E_TAG_PRE/coordinator-linux-amd64" "$E2E_REPO/phase4-coordinator/dist/coordinator-linux-amd64"
before="$(e2e_host_hash)"; rc=0
e2e_run_logged 1800 "$E2E_LOGS/V10a.log" deploy || rc=$?
after="$(e2e_host_hash)"
e2e_checkout "$E2E_TAG_ENABLE"
if [ "$rc" = 12 ] && grep -q 'PRICING RUNTIME FLOOR: refusing: the incoming coordinator' "$E2E_LOGS/V10a.log" && [ "$before" = "$after" ]; then
  e2e_result "$S" PASS "a: new deploy script refuses the pre-#1693 incoming binary (rc=12), host unchanged"
else
  e2e_result "$S" FAIL "a: rc=$rc host_changed=$([ "$before" = "$after" ] && echo no || echo yes): $(grep -E 'FLOOR|aborting|refusing' "$E2E_LOGS/V10a.log" | head -n 3 | tr '\n' '|')"
fi
fi

units() { vm 'sha256sum /etc/systemd/system/macprovider-coordinator-deploy-recovery.service /opt/macprovider/coordinator-deploy-recover /etc/systemd/system/macprovider-coordinator.service.d/10-deploy-transaction-guard.conf /etc/systemd/system/macprovider-coordinator-pricing-close.service /opt/macprovider/coordinator-pricing-recover 2>&1 | cut -c1-12 | tr "\n" " "; grep -c pricing-recover /etc/systemd/system/macprovider-coordinator-deploy-recovery.service'; }
if [ "${1:-}" != c ] && [ "${1:-}" != restore-c ]; then
# b) old script at the old tag
units_before="$(units)"
e2e_checkout "$E2E_TAG_PRE"
marker="$(vm 'test -e /opt/macprovider/.pricing-runtime-floor && echo present || echo absent')"
before="$(e2e_host_hash)"; rc=0
e2e_run_logged 3600 "$E2E_LOGS/V10b.log" deploy || rc=$?
after="$(e2e_host_hash)"
hz="$(vm 'curl -fsS http://127.0.0.1:8444/healthz' | python3 -c 'import json,sys;print(json.load(sys.stdin).get("version"))' 2>/dev/null || echo '?')"
e2e_checkout main
msg="b: runbook marker check says '$marker' (operator rule: do not deploy a pre-#1693 tag); old deploy run anyway rc=$rc; live version after=$hz; host $([ "$before" = "$after" ] && echo unchanged || echo CHANGED); first refusal: $(grep -m1 -E 'refusing|aborting|Refusing' "$E2E_LOGS/V10b.log" | cut -c1-200)"
units_after="$(units)"
# Runbook §Pricing runtime floor "If a pre-#1693 deploy script ran anyway": its
# step 1 reinstalls its own recovery unit/helper/drop-in; detection is the
# --host-check NO_GO pricing_host_state 'pricing recovery DISABLED'.
hc_rc=0; e2e_run_logged 1200 "$E2E_LOGS/V10b-hostcheck.log" e2e_lane --host-check --commit "$(git -C "$E2E_REPO" rev-parse "$E2E_TAG_ENABLE^{commit}")" || hc_rc=$?
hc="$(grep -E '^\{"checks"' "$E2E_LOGS/V10b-hostcheck.log" | tail -n 1)"; printf '%s\n' "$hc" >"$E2E_EVIDENCE/V10b-hostcheck.json"
hc_detail="$(e2e_verdict_detail "$E2E_EVIDENCE/V10b-hostcheck.json" pricing_host_state 2>/dev/null | cut -c1-300)"
if [ "$hz" = "$E2E_TAG_ENABLE" ] && [ "$rc" != 0 ] && { [ "$units_before" = "$units_after" ] || { [ "$hc_rc" != 0 ] && grep -q 'pricing recovery DISABLED' <<<"$hc_detail"; }; }; then
  e2e_result "$S" PASS "$msg; recovery wiring $([ "$units_before" = "$units_after" ] && echo unchanged || echo "REPLACED by the old script (documented operator-rule gap) and DETECTED: --host-check rc=$hc_rc pricing_host_state: $hc_detail")"
else
  e2e_result "$S" FAIL "$msg; recovery wiring before=[$units_before] after=[$units_after]; --host-check rc=$hc_rc: $hc_detail"
fi
fi
if [ "${1:-}" != c ]; then
# Restore the #1693 wiring with the enabling deploy (runbook fix), then
# --host-check until it passes.
e2e_checkout "$E2E_TAG_ENABLE"
rc=0; e2e_run_logged 3600 "$E2E_LOGS/V10b-restore.log" bash -c "cd '$E2E_REPO' && . '$E2E_HARNESS/env.sh' && . '$E2E_HARNESS/lib/common.sh' && e2e_lane_env && CONFIG_MODE=preserve-live FORCE_RESTART=1 bash phase4-coordinator/dist/deploy-pearl-vps.sh" || rc=$?
hc_rc=0; e2e_run_logged 1200 "$E2E_LOGS/V10b-restore-hostcheck.log" e2e_lane --host-check --commit "$(git -C "$E2E_REPO" rev-parse "$E2E_TAG_ENABLE^{commit}")" || hc_rc=$?
if [ "$rc" = 0 ] && [ "$hc_rc" = 0 ]; then
  e2e_result "$S" PASS "b-fix: enabling deploy re-run rc=0, --host-check rc=0; wiring now [$(units)]"
else
  e2e_result "$S" FAIL "b-fix: enabling deploy re-run rc=$rc ($(grep -E 'refusing|aborting|ERROR' "$E2E_LOGS/V10b-restore.log" | head -n 2 | tr '\n' '|' | cut -c1-300)); --host-check rc=$hc_rc ($(grep -E '^\{"checks"' "$E2E_LOGS/V10b-restore-hostcheck.log" | tail -n 1 | cut -c1-400))"
fi
e2e_checkout main
fi

# c) the updater applying the pre-#1693 release (test mode, local source dir;
#    never GitHub). Records how far it gets before any refusal.
src="$E2E_WORK/gh-releases/$E2E_TAG_PRE"
COPYFILE_DISABLE=1 tar -C "$src" -cf - . | vm "rm -rf /root/e2e/updater-src && mkdir -p /root/e2e/updater-src && tar -xf - -C /root/e2e/updater-src"
before="$(e2e_host_hash)"; rc=0
vm "MACPROVIDER_UPDATER_TESTING=1 timeout 300 /usr/local/sbin/macprovider-pearl-update --apply --tag $E2E_TAG_PRE --source-dir /root/e2e/updater-src" >"$E2E_LOGS/V10c.log" 2>&1 || rc=$?
after="$(e2e_host_hash)"
if grep -q 'PricingRuntimeFloorRefused\|pricing runtime floor' "$E2E_LOGS/V10c.log" && [ "$before" = "$after" ]; then
  e2e_result "$S" PASS "c: updater refuses the pre-#1693 release (rc=$rc): $(grep -m1 -i 'floor' "$E2E_LOGS/V10c.log" | cut -c1-240)"
else
  # How far does it get with apply enabled? A probe copy of the config (apply
  # enabled, a dummy local dead-man token), test mode, no network namespace.
  prc=0
  e2e_updater_probe_conf
  vm "MACPROVIDER_UPDATER_TESTING=1 unshare -n timeout 300 /usr/local/sbin/macprovider-pearl-update --apply --tag $E2E_TAG_PRE --source-dir /root/e2e/updater-src --config /root/e2e/updater-probe.conf" >"$E2E_LOGS/V10c-probe.log" 2>&1 || prc=$?
  after2="$(e2e_host_hash)"
  if grep -q 'PricingRuntimeFloorRefused\|pricing runtime floor' "$E2E_LOGS/V10c-probe.log" && [ "$before" = "$after2" ]; then
    e2e_result "$S" PASS "c (probe config: apply enabled, dummy dead-man token, no network): updater refuses the pre-#1693 release rc=$prc: $(grep -m1 -i 'floor' "$E2E_LOGS/V10c-probe.log" | cut -c1-240)"
  else
    e2e_result "$S" GAP "c: updater never reaches its pricing-floor check (apply() -> require_pricing_runtime_floor) in tier E2: as installed rc=$rc '$(tail -n 1 "$E2E_LOGS/V10c.log" | cut -c1-200)'; with a probe config (apply enabled, dummy dead-man token, unshare -n) rc=$prc stops at '$(grep -v '^$' "$E2E_LOGS/V10c-probe.log" | tail -n 1 | cut -c1-300)' (host $([ "$before" = "$after2" ] && echo unchanged || echo CHANGED)); covered only by ops/pearl-updater/test_pearl_updater.py"
  fi
fi

# d) deploy recovery asked to restore a snapshot whose coordinator is pre-#1693:
#    a deploy that died right after arming its transaction (lib/synth-deploy-
#    snapshot.sh, a port of deploy-pearl-vps.sh step 4/9) with the pre-#1693
#    binary as the rollback target. `coordinator-deploy-recover --recover`
#    (the watchdog/operator path; pre-start runs the same code) must refuse and
#    keep the snapshot; then the runbook's fix (replace the snapshot binary with
#    the enabling release's sha-checked coordinator, rerun --recover) completes.
vm "cat > /root/e2e/tools/synth-deploy-snapshot.sh && chmod 700 /root/e2e/tools/synth-deploy-snapshot.sh" <"$E2E_HARNESS/lib/synth-deploy-snapshot.sh"
/usr/bin/scp -F "$E2E_SSH_CONFIG" -q "$E2E_WORK/bins/$E2E_TAG_PRE/coordinator-linux-amd64" "$E2E_PEARL:/root/e2e/coordinator-pre1693"
/usr/bin/scp -F "$E2E_SSH_CONFIG" -q "$E2E_WORK/gh-releases/$E2E_TAG_ENABLE/coordinator-linux-amd64" "$E2E_PEARL:/root/e2e/coordinator-enable"
vm "chmod 0750 /root/e2e/coordinator-pre1693 /root/e2e/coordinator-enable"
want_enable="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["components"]["coordinator"]["sha256"])' "$E2E_WORK/gh-releases/$E2E_TAG_ENABLE/pearl-release.json")"
vm "SNAP_COORDINATOR=/root/e2e/coordinator-pre1693 /root/e2e/tools/synth-deploy-snapshot.sh" >"$E2E_LOGS/V10d-synth.log" 2>&1
armed="$(e2e_host_hash)"; rc=0
vm "/opt/macprovider/coordinator-deploy-recover --recover" >"$E2E_LOGS/V10d.log" 2>&1 || rc=$?
after="$(e2e_host_hash)"
kept="$(vm 'test -f /opt/macprovider/.coordinator-deploy-rollback/complete && echo kept || echo gone')"
live_ok="$(vm 'cmp -s /opt/macprovider/coordinator /root/e2e/coordinator-enable && echo enable-binary || echo OTHER')"
if [ "$rc" != 0 ] && grep -q 'pricing runtime floor' "$E2E_LOGS/V10d.log" && [ "$kept" = kept ] && [ "$armed" = "$after" ] && [ "$live_ok" = enable-binary ]; then
  e2e_result "$S" PASS "d: coordinator-deploy-recover --recover refuses the pre-#1693 rollback target rc=$rc, snapshot kept, host unchanged, live binary still the enabling one: $(grep -m1 'pricing runtime floor' "$E2E_LOGS/V10d.log" | cut -c1-240)"
else
  e2e_result "$S" FAIL "d: rc=$rc snapshot=$kept host $([ "$armed" = "$after" ] && echo unchanged || echo CHANGED) live=$live_ok: $(tail -n 3 "$E2E_LOGS/V10d.log" | tr '\n' '|' | cut -c1-400)"
fi
# Runbook fix (two operators): replace the snapshot binary with the enabling
# release's coordinator after checking its sha256, then --recover.
rc=0
vm "set -e; [ \"\$(sha256sum /root/e2e/coordinator-enable | cut -c1-64)\" = '$want_enable' ]; install -m 0750 -o root -g macprovider /root/e2e/coordinator-enable /opt/macprovider/.coordinator-deploy-rollback/coordinator; /opt/macprovider/coordinator-deploy-recover --recover" >"$E2E_LOGS/V10d-fix.log" 2>&1 || rc=$?
kept="$(vm 'test -e /opt/macprovider/.coordinator-deploy-rollback && echo kept || echo gone')"
hc_rc=0; e2e_run_logged 1200 "$E2E_LOGS/V10d-hostcheck.log" e2e_lane --host-check --commit "$(git -C "$E2E_REPO" rev-parse "$E2E_TAG_ENABLE^{commit}")" || hc_rc=$?
if [ "$rc" = 0 ] && [ "$kept" = gone ] && [ "$hc_rc" = 0 ]; then
  e2e_result "$S" PASS "d-fix: sha-checked enabling binary into the snapshot, --recover rc=0, snapshot consumed, --host-check rc=0"
else
  e2e_result "$S" FAIL "d-fix: --recover rc=$rc snapshot=$kept --host-check rc=$hc_rc: $(tail -n 3 "$E2E_LOGS/V10d-fix.log" | tr '\n' '|' | cut -c1-300) $(grep -E '^\{"checks"' "$E2E_LOGS/V10d-hostcheck.log" | tail -n 1 | cut -c1-300)"
fi
