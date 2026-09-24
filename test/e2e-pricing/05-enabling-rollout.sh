#!/usr/bin/env bash
# Tier E2 step 5: the #1693 enabling rollout, exactly as
# docs/runbooks/catalog-release-decision-tree.md §"Enabling rollout (once)" says,
# from a clean checkout of the enabling tag ($E2E_TAG_ENABLE). Each runbook step
# is recorded PASS/FAIL/GAP in $E2E_EVIDENCE/results.jsonl.
#   1. updater bundle first (ops/pearl-updater/install-pearl-updater.sh, as root on Pearl)
#   2. full coordinator deploy (deploy-pearl-vps.sh)
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

# ---- step 2: full coordinator deploy -------------------------------------------
# As written the deploy is expected to install the #1693 coordinator. It refuses
# unless the signed coordinator/gateway pair is already installed by
# macprovider-pearl-update (ops/runbooks/pearl-release-updater.md). Run it as
# written first to record that, then with the updater stand-in.
rc=0
e2e_run_logged 3600 "$E2E_LOGS/$S-step2-as-written.log" bash -c "cd '$E2E_REPO' && . '$E2E_HARNESS/env.sh' && . '$E2E_HARNESS/lib/common.sh' && e2e_lane_env && FORCE_RESTART=1 bash phase4-coordinator/dist/deploy-pearl-vps.sh" || rc=$?
if [ "$rc" = 0 ]; then
  e2e_result "$S" PASS "step 2 deploy as written installed $E2E_TAG_ENABLE"
else
  e2e_result "$S" FAIL "step 2 as written: deploy-pearl-vps.sh rc=$rc: $(grep -m1 -E 'refusing|aborting' "$E2E_LOGS/$S-step2-as-written.log" || tail -n 1 "$E2E_LOGS/$S-step2-as-written.log")"
  bash "$E2E_HARNESS/lib/install-runtime-pair.sh" "$E2E_TAG_ENABLE"
  rc=0
  e2e_run_logged 3600 "$E2E_LOGS/$S-step2.log" bash -c "cd '$E2E_REPO' && . '$E2E_HARNESS/env.sh' && . '$E2E_HARNESS/lib/common.sh' && e2e_lane_env && FORCE_RESTART=1 bash phase4-coordinator/dist/deploy-pearl-vps.sh" || rc=$?
  [ "$rc" = 0 ] || { e2e_result "$S" FAIL "step 2 deploy after the updater stand-in rc=$rc: $(tail -n 3 "$E2E_LOGS/$S-step2.log" | tr '\n' ' ')"; exit 1; }
  e2e_result "$S" GAP "step 2 needed 'macprovider-pearl-update --apply --tag $E2E_TAG_ENABLE' first (updater stand-in used); then deploy-pearl-vps.sh rc=0"
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

# ---- step 4: host check (older trees: the no-op preflight) -------------------------
rc=0
if git -C "$E2E_REPO" show "$E2E_TAG_ENABLE:scripts/catalog-content-release.sh" | grep -q -- '--host-check'; then
  e2e_run_logged 1200 "$E2E_LOGS/$S-step4-noop.log" e2e_lane --host-check --commit "$TAG_COMMIT" || rc=$?
else
  e2e_run_logged 1200 "$E2E_LOGS/$S-step4-noop.log" e2e_lane --preflight --commit "$TAG_COMMIT" || rc=$?
fi
verdict="$(grep -E '^\{"checks"' "$E2E_LOGS/$S-step4-noop.log" | tail -n 1)"
printf '%s\n' "$verdict" >"$E2E_EVIDENCE/$S-noop-verdict.json"
failed="$(python3 -c 'import json,sys;v=json.loads(sys.stdin.read() or "{}");print(" ".join("%s(%s)"%(c["name"],c["detail"][:120]) for c in v.get("checks",[]) if not c["ok"]))' <<<"$verdict")"
ran_pricing="$(python3 -c 'import json,sys;v=json.loads(sys.stdin.read() or "{}");print(any(c["name"]=="pricing_host_state" for c in v.get("checks",[])))' <<<"$verdict")"
if [ "$rc" = 0 ]; then e2e_result "$S" PASS "step 4 no-op preflight GO (pricing_host_state ran: $ran_pricing)"
else e2e_result "$S" FAIL "step 4 no-op preflight on the tag commit rc=$rc NO_GO: $failed (pricing_host_state ran: $ran_pricing)"; fi
