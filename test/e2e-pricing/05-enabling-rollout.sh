#!/usr/bin/env bash
# Tier E2 step 5: the #1693 enabling rollout, exactly as
# docs/runbooks/catalog-release-decision-tree.md §"Enabling rollout (once)" says,
# from a clean checkout of the enabling tag ($E2E_TAG_ENABLE). Each runbook step
# is recorded PASS/FAIL/GAP in $E2E_EVIDENCE/results.jsonl.
#   1. updater bundle first (ops/pearl-updater/install-pearl-updater.sh, as root on Pearl)
#   2. runtime pair via the updater (--plan/--apply --tag; GAP in E2 -> stand-in),
#      then the full deploy with CONFIG_MODE=preserve-live FORCE_RESTART=1
#   3. verify the host (healthz tag, Requires/Wants, alert unit, applied record, writer hashes)
#   4. host check: scripts/catalog-content-release.sh --host-check (read-only
#      pricing_host_state at the tag); a no-op --preflight cannot pass by
#      construction (the live release already exists on Pearl)
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$E2E_HARNESS/lib/common.sh"
S=enabling-rollout
e2e_write_ssh_config
e2e_checkout "$E2E_TAG_ENABLE"
e2e_tunnel_up
TAG_COMMIT="$(git -C "$E2E_REPO" rev-parse "$E2E_TAG_ENABLE^{commit}")"

# E2E_05_FROM=4 re-runs only step 4 on an already enabled host.
if [ "${E2E_05_FROM:-1}" -le 3 ]; then
# ---- step 1: updater bundle ---------------------------------------------------
# The runbook says "Run ops/pearl-updater/install-pearl-updater.sh from the tag"
# but not where: the installer must run as root ON Pearl beside a checkout of
# the tag (it installs ../../scripts/* relative to itself).
git -C "$E2E_REPO" archive --format=tar "$E2E_TAG_ENABLE" ops/pearl-updater scripts |
  vm "rm -rf /root/e2e-checkout && mkdir -p /root/e2e-checkout && tar -xf - -C /root/e2e-checkout"
if vm "cd /root/e2e-checkout && bash ops/pearl-updater/install-pearl-updater.sh" >"$E2E_LOGS/$S-step1.log" 2>&1; then
  e2e_result "$S" PASS "step 1 updater bundle installed: $(tail -n 3 "$E2E_LOGS/$S-step1.log" | tr '\n' ' ')"
else
  e2e_result "$S" FAIL "step 1 install-pearl-updater.sh failed: $(tail -n 5 "$E2E_LOGS/$S-step1.log" | tr '\n' ' ')"
  exit 1
fi

# ---- step 2: runtime pair (updater), then the full coordinator deploy -------------
# Runbook step 2a: `macprovider-pearl-update --plan --tag <tag>` then `--apply
# --tag <tag>` as root on Pearl. Run exactly as written but inside `unshare -n`
# (no network namespace: the tier E2 VM must never reach GitHub or Better Stack).
# The updater's production apply needs the Better Stack dead-man token, the #584
# canary authority and a canary-buyer service that tier E2 does not have, so it
# refuses; that is recorded as a GAP and the signed pair is installed by the
# stand-in (lib/install-runtime-pair.sh: same sha-checked assets, same owners).
upd_rc=0
vm "unshare -n /usr/local/sbin/macprovider-pearl-update --plan --tag $E2E_TAG_ENABLE" >"$E2E_LOGS/$S-step2-updater-plan.log" 2>&1 || upd_rc=$?
upd_apply_rc=0
vm "unshare -n /usr/local/sbin/macprovider-pearl-update --apply --tag $E2E_TAG_ENABLE" >"$E2E_LOGS/$S-step2-updater-apply.log" 2>&1 || upd_apply_rc=$?
installed="$(vm "sha256sum /opt/macprovider/coordinator | cut -c1-64")"
want="$(shasum -a 256 "$E2E_WORK/gh-releases/$E2E_TAG_ENABLE/coordinator-linux-amd64" | cut -c1-64)"
if [ "$upd_apply_rc" = 0 ] && [ "$installed" = "$want" ]; then
  e2e_result "$S" PASS "step 2a updater --plan rc=$upd_rc, --apply rc=0 installed the $E2E_TAG_ENABLE pair"
else
  e2e_result "$S" GAP "step 2a updater cannot apply in tier E2 (no network, no Better Stack/#584 canary authority): --plan rc=$upd_rc '$(tail -n 1 "$E2E_LOGS/$S-step2-updater-plan.log" | cut -c1-240)'; --apply rc=$upd_apply_rc '$(tail -n 1 "$E2E_LOGS/$S-step2-updater-apply.log" | cut -c1-240)'; signed pair installed by the stand-in"
  bash "$E2E_HARNESS/lib/install-runtime-pair.sh" "$E2E_TAG_ENABLE"
fi
# Runbook step 2b: the full deploy, CONFIG_MODE=preserve-live, FORCE_RESTART=1
# (Pearl has connected providers; the runbook's policy for the enabling deploy).
rc=0
e2e_run_logged 3600 "$E2E_LOGS/$S-step2.log" bash -c "cd '$E2E_REPO' && . '$E2E_HARNESS/env.sh' && . '$E2E_HARNESS/lib/common.sh' && e2e_lane_env && CONFIG_MODE=preserve-live FORCE_RESTART=1 bash phase4-coordinator/dist/deploy-pearl-vps.sh" || rc=$?
bypass="$(vm 'cat /var/lib/macprovider/last-deploy-bypass.json 2>/dev/null' | tr -d '\n' | cut -c1-200)"
if [ "$rc" = 0 ]; then
  e2e_result "$S" PASS "step 2b deploy (CONFIG_MODE=preserve-live FORCE_RESTART=1) installed $E2E_TAG_ENABLE; bypass record: $bypass"
else
  e2e_result "$S" FAIL "step 2b deploy rc=$rc: $(grep -E 'refusing|aborting|ERROR|FATAL' "$E2E_LOGS/$S-step2.log" | head -n 3 | tr '\n' '|' | cut -c1-500)"
  exit 1
fi

# ---- step 3: verify the host ----------------------------------------------------
writers="$(git -C "$E2E_REPO" show "$E2E_TAG_ENABLE:scripts/pricing-lane-installed-writers.txt" | grep -v '^#' | grep -v '^$')"
bad=""
while read -r inst repo_path; do
  want="$(git -C "$E2E_REPO" show "$E2E_TAG_ENABLE:$repo_path" | shasum -a 256 | cut -d' ' -f1)"
  got="$(vm "sha256sum '$inst' 2>/dev/null | cut -d' ' -f1")"
  [ "$want" = "$got" ] || bad="$bad $inst"
done <<<"$writers"
out="$(vm_script "$E2E_TAG_ENABLE" <<'SH'
tag="$1"
v="$(curl -fsS http://127.0.0.1:8444/healthz | python3 -c 'import json,sys;print(json.load(sys.stdin).get("version"))')"
echo "HEALTHZ=$v"
echo "REQUIRES=$(systemctl show -p Requires --value macprovider-coordinator)"
echo "WANTS=$(systemctl show -p Wants --value macprovider-coordinator)"
echo "ALERT=$(systemctl show -p LoadState --value macprovider-pearl-updater-alert@macprovider-coordinator-pricing-close.service.service)"
python3 -c 'import json;r=json.load(open("/run/macprovider/coordinator-applied-config.json"));print("RECORD="+",".join(k for k in ("rate_table_sha256","signed_rate_card_sha256","autotune_release_id","billing_snapshot_id") if k in r))'
SH
)"
printf '%s\n' "$out" >"$E2E_LOGS/$S-step3.txt"
problems=""
grep -qx "HEALTHZ=$E2E_TAG_ENABLE" <<<"$out" || problems="$problems healthz!=$E2E_TAG_ENABLE;"
grep -q '^REQUIRES=.*macprovider-coordinator-deploy-recovery.service' <<<"$out" || problems="$problems Requires lacks recovery unit;"
grep -q '^WANTS=.*macprovider-coordinator-pricing-close.service' <<<"$out" || problems="$problems Wants lacks closer;"
grep -qx 'ALERT=loaded' <<<"$out" || problems="$problems alert unit not loaded;"
grep -qx 'RECORD=rate_table_sha256,signed_rate_card_sha256,autotune_release_id,billing_snapshot_id' <<<"$out" || problems="$problems applied record fields missing;"
[ -z "$bad" ] || problems="$problems writer hashes differ:$bad;"
if [ -z "$problems" ]; then e2e_result "$S" PASS "step 3 host checks: $(tr '\n' ' ' <<<"$out")"
else e2e_result "$S" FAIL "step 3 host checks:$problems ($(tr '\n' ' ' <<<"$out"))"; fi

fi

# ---- step 4: host check (older trees: the no-op preflight) -------------------------
rc=0
# (no `grep -q` on a pipe: under pipefail its early exit SIGPIPEs git show -> false)
if [ "$(git -C "$E2E_REPO" show "$E2E_TAG_ENABLE:scripts/catalog-content-release.sh" | grep -c -- '--host-check')" -gt 0 ]; then
  e2e_run_logged 1200 "$E2E_LOGS/$S-step4-noop.log" e2e_lane --host-check --commit "$TAG_COMMIT" || rc=$?
else
  e2e_run_logged 1200 "$E2E_LOGS/$S-step4-noop.log" e2e_lane --preflight --commit "$TAG_COMMIT" || rc=$?
fi
verdict="$(grep -E '^\{"checks"' "$E2E_LOGS/$S-step4-noop.log" | tail -n 1)"
printf '%s\n' "$verdict" >"$E2E_EVIDENCE/$S-noop-verdict.json"
failed="$(python3 -c 'import json,sys;v=json.loads(sys.stdin.read() or "{}");print(" ".join("%s(%s)"%(c["name"],c["detail"][:120]) for c in v.get("checks",[]) if not c["ok"]))' <<<"$verdict")"
ran_pricing="$(python3 -c 'import json,sys;v=json.loads(sys.stdin.read() or "{}");print(any(c["name"]=="pricing_host_state" for c in v.get("checks",[])))' <<<"$verdict")"
if [ "$rc" = 0 ] && [ "$ran_pricing" = True ]; then e2e_result "$S" PASS "step 4 --host-check rc=0 (pricing_host_state ran and passed): $(python3 -c 'import json,sys;v=json.loads(sys.stdin.read() or "{}");print(" ".join(c["name"]+"="+("ok" if c["ok"] else "FAIL") for c in v.get("checks",[])))' <<<"$verdict")"
else e2e_result "$S" FAIL "step 4 --host-check on the tag commit rc=$rc: $failed (pricing_host_state ran: $ran_pricing)"; exit 1; fi
