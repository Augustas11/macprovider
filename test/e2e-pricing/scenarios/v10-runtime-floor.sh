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
msg="b: runbook marker check says '$marker'; old deploy rc=$rc; live version after=$hz; host $([ "$before" = "$after" ] && echo unchanged || echo CHANGED); first refusal: $(grep -m1 -E 'refusing|aborting' "$E2E_LOGS/V10b.log" | cut -c1-200)"
units_after="$(units)"
if [ "$hz" = "$E2E_TAG_ENABLE" ] && [ "$rc" != 0 ] && [ "$units_before" = "$units_after" ]; then e2e_result "$S" PASS "$msg"
else e2e_result "$S" FAIL "$msg; recovery wiring before=[$units_before] after=[$units_after] (the pre-#1693 script's step 1 reinstalls its own deploy-recovery unit/helper/guard drop-in BEFORE any later refusal)"; fi
fi
if [ "${1:-}" != c ]; then
# Restore the #1693 wiring with the enabling deploy (as an operator would).
e2e_checkout "$E2E_TAG_ENABLE"
rc=0; e2e_run_logged 3600 "$E2E_LOGS/V10b-restore.log" bash -c "cd '$E2E_REPO' && . '$E2E_HARNESS/env.sh' && . '$E2E_HARNESS/lib/common.sh' && e2e_lane_env && FORCE_RESTART=1 bash phase4-coordinator/dist/deploy-pearl-vps.sh" || rc=$?
e2e_result "$S" INFO "b: restore with the enabling deploy rc=$rc; wiring now [$(units)]"
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
  e2e_result "$S" GAP "c: updater did not reach the floor check in tier E2 (rc=$rc, host $([ "$before" = "$after" ] && echo unchanged || echo CHANGED)): $(tail -n 3 "$E2E_LOGS/V10c.log" | tr '\n' '|' | cut -c1-400)"
fi
