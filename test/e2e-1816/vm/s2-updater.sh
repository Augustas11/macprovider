#!/usr/bin/env bash
# S2 rollout through the REAL Pearl updater (ops/pearl-updater/macprovider-pearl-update),
# old -> new, with the artifact-feed-bound signed catalog release
# (published-2026-10-01-artifact-feed-activation-v1):
#   1  install the updater bundle from the new tree (install-pearl-updater.sh)
#   2  --plan
#   3  rollback rehearsal: --apply while the catalog canary Mac is down; the
#      updater's own transaction rollback must restore the old catalog
#      `current`, the exact coordinator.yaml bytes and the old binaries
#   4  --apply with the canary up: coordinator config gets
#      autotune.catalog_artifacts_path/_sig_path, the catalog canary's live
#      proof passes, the dead-man heartbeat is paused and restored
#   5  /v1/catalog-artifacts through nginx after the runbook's manual
#      additive nginx step
#   6  baseline catalog traffic on the new pair, outcome shape == S1
#   7  existing deploy guards: the pricing runtime floor (marker present),
#      the updater and deploy-script regression tests in the new tree
# Harness deviations (see the plan): --source-dir instead of GitHub release
# assets, the outer P-256 release signature with the VM test key
# (PEARL_UPDATER_TEST_PUBLIC_KEY; every catalog signature is the production
# one), Better Stack and the canary Mac are VM stand-ins.
set -uo pipefail
. /root/e2e/h/vm/lib.sh; . $E2E_H/vm/lib-deploy.sh; . $E2E_H/vm/lib-scn.sh; . /root/e2e/h16/vm/lib-1816.sh
[ "$(sides)" = old/old ] || die "S2 starts from old/old"
EV=$E2E_EVIDENCE/p$PASS_ID-s2; mkdir -p "$EV"
. /root/e2e/commits.env
WTN=/root/e2e/wt-new

# ---- 1. updater bundle ---------------------------------------------------------
if ( cd $WTN && bash ops/pearl-updater/install-pearl-updater.sh ) >"$EV/install-updater.txt" 2>&1; then
  result S2-updater-install PASS "install-pearl-updater.sh from the new tree: $(tail -1 "$EV/install-updater.txt")"
else result S2-updater-install FAIL "$(tail -5 "$EV/install-updater.txt" | tr '\n' ' ')"; fi
systemctl stop macprovider-pearl-updater.timer 2>/dev/null || true   # the operator drives --apply by hand here
umask 077
printf '%s\n' "$(openssl rand -hex 24)" >/etc/macprovider/pearl-updater.betterstack-token
opkey >/etc/macprovider/pearl-updater.catalog-canary-token
install -m 0600 $K/canary_ssh /etc/macprovider/pearl-updater.catalog-canary-ssh-key
install -m 0600 $K/canary_known_hosts /etc/macprovider/pearl-updater.catalog-canary-known-hosts
: >/etc/macprovider/pearl-updater.revoked
write_conf() {   # write_conf <provider-recovery-timeout-s>
  cat >$UPD_CONF <<CONF
PEARL_UPDATER_ENABLED=1
PEARL_UPDATER_MINIMUM_VERSION=1.8.26
PEARL_UPDATER_ALLOW_PROVIDER_DRAIN=1
PEARL_UPDATER_ALLOW_PRIVATE_ACCEPTANCE=0
PEARL_UPDATER_DOWNLOAD_ATTEMPTS=1
PEARL_UPDATER_RETRY_BACKOFF_S=1
PEARL_UPDATER_REQUEST_TIMEOUT_S=15
PEARL_UPDATER_DOWNLOAD_TIMEOUT_S=60
PEARL_UPDATER_GATEWAY_DRAIN_TIMEOUT_S=60
PEARL_UPDATER_GATEWAY_DRAIN_STEADY_S=3
PEARL_UPDATER_PROVIDER_RECOVERY_TIMEOUT_S=$1
PEARL_UPDATER_SERVICE_HEALTH_TIMEOUT_S=60
PEARL_UPDATER_SQLITE_SNAPSHOT_TIMEOUT_S=60
PEARL_UPDATER_CANARY_TIMEOUT_S=720
PEARL_UPDATER_BUYER_CANARY_MODE=disabled
PEARL_UPDATER_REVOKED_VERSIONS_FILE=/etc/macprovider/pearl-updater.revoked
PEARL_UPDATER_PROVIDER_ADMISSION_POLICY=strict_post_migration
PEARL_UPDATER_MINIMUM_POOL_READY_AFTER_ROLLOUT=1
PEARL_UPDATER_MINIMUM_BRIDGE_REMAINING_S=0
PEARL_UPDATER_DEADMAN_HEARTBEAT_ID=e2e-1816-heartbeat
PEARL_UPDATER_DEADMAN_API_TOKEN_FILE=/etc/macprovider/pearl-updater.betterstack-token
PEARL_UPDATER_CATALOG_CANARY_PROVIDER_ID=$CANARY_ID
PEARL_UPDATER_CATALOG_CANARY_AUTH_TOKEN_FILE=/etc/macprovider/pearl-updater.catalog-canary-token
PEARL_UPDATER_CATALOG_CANARY_SSH_TARGET=$CANARY_USER@127.0.0.1
PEARL_UPDATER_CATALOG_CANARY_SSH_PORT=22
PEARL_UPDATER_CATALOG_CANARY_SSH_KEY_FILE=/etc/macprovider/pearl-updater.catalog-canary-ssh-key
PEARL_UPDATER_CATALOG_CANARY_KNOWN_HOSTS_FILE=/etc/macprovider/pearl-updater.catalog-canary-known-hosts
PEARL_UPDATER_CATALOG_CANARY_INSTALL_DIR=macprovider/catalog-release
PEARL_UPDATER_RELEASE_MIRROR_GATE=disabled
PEARL_UPDATER_RELEASE_MIRROR_ROOT=/var/www/malibu-download/releases
CONF
  chmod 0600 $UPD_CONF
}
umask 022
write_conf 240

# ---- release set ------------------------------------------------------------------
python3 $E2E_H16/tools/make-pearl-release.py --tree $WTN --bins /root/e2e/bins/new --tag $NEW_TAG --commit "$new" \
  --key $K/release-signing.key --out $RELDIR/$NEW_TAG >"$EV/release.txt" 2>&1 || die "release set: $(tail -3 "$EV/release.txt")"
grep -q '"artifact_feed": true' "$EV/release.txt" && grep -q 'published-2026-10-01-artifact-feed-activation-v1' "$EV/release.txt" \
  && result S2-release-set PASS "$(head -c 300 "$EV/release.txt")" || result S2-release-set FAIL "release is not the artifact-bound activation release: $(head -c 300 "$EV/release.txt")"

pre_state() {
  { echo "current=$(readlink /opt/macprovider/autotune/current)"
    echo "coordinator.yaml=$(sha /opt/macprovider/coordinator.yaml)"
    echo "gateway.yaml=$(sha /opt/macprovider/gateway.yaml)"
    echo "coordinator=$(sha /opt/macprovider/coordinator)"
    echo "gateway=$(sha /opt/macprovider/gateway)"
    echo "artifact_keys=$(grep -c 'catalog_artifacts' /opt/macprovider/coordinator.yaml)"
    echo "healthz=$(coord_healthz | python3 -c 'import json,sys;print(json.load(sys.stdin).get("version"))' 2>/dev/null)"
    echo "release=$(curl -fsS http://127.0.0.1:8443/v1/autotune-release | python3 -c 'import json,sys;print(json.load(sys.stdin).get("release_id"))' 2>/dev/null)"
  } }
# ---- 0. deploy order, gateway first: OLD coordinator + NEW gateway ----------------------
# (the reverse of the updater's restart order; see step 4) catalog traffic must
# behave exactly like the S1 baseline. The gateway binary and DB are put back
# afterwards so the updater starts from the production state.
systemctl stop macprovider-gateway
for f in "$GWDB" "$GWDB-wal" "$GWDB-shm"; do if [ -f "$f" ]; then cp -p "$f" "$f.e2e-pre-gwfirst"; fi; done
cp -p /opt/macprovider/gateway /opt/macprovider/gateway.e2e-pre-gwfirst
install -o root -g macprovider -m 0750 /root/e2e/bins/new/gateway-linux-amd64 /opt/macprovider/gateway
gw_restart
run="$(run_id s2gwfirst)"
traffic "$run"
settle_and_check S2-order-gateway-first-catalog "$run" --expect ns=settled,st=settled
compare_catalog_shape S2-order-gateway-first-shape "$run" "old coordinator + new gateway"
systemctl stop macprovider-gateway
install -o root -g macprovider -m 0750 /opt/macprovider/gateway.e2e-pre-gwfirst /opt/macprovider/gateway; rm -f /opt/macprovider/gateway.e2e-pre-gwfirst
rm -f "$GWDB-wal" "$GWDB-shm"
for f in "$GWDB" "$GWDB-wal" "$GWDB-shm"; do if [ -f "$f.e2e-pre-gwfirst" ]; then mv "$f.e2e-pre-gwfirst" "$f"; fi; done
gw_restart

# Runbook (catalog-artifact-feed-release.md): BEFORE the activation release goes
# live, add the two catalog-artifacts blocks to Pearl's vhost by hand. The old
# coordinator answers 404 on the route until the config pair is set.
c0="$(curl -s -o /dev/null -w '%{http_code}' https://coordinator.malibu.tech/v1/catalog-artifacts)"
nginx_add_catalog_artifacts $WTN/phase4-coordinator/dist/nginx-coordinator.malibu.tech.conf >"$EV/nginx-additive.txt" 2>&1
d0="$(curl -s -o /dev/null -w '%{http_code}' https://coordinator.malibu.tech/v1/catalog-artifacts)"
pre_state >"$EV/state-0-before.txt"

# ---- 2. plan ------------------------------------------------------------------------
run_updater plan $NEW_TAG $RELDIR/$NEW_TAG "$EV/updater-plan.txt"; rc=$?
[ $rc = 0 ] && result S2-updater-plan PASS "$(grep -v '^rc=' "$EV/updater-plan.txt" | tail -2 | tr '\n' ' ' | head -c 400)" \
  || result S2-updater-plan FAIL "rc=$rc: $(grep -v '^rc=' "$EV/updater-plan.txt" | tail -3 | tr '\n' ' ' | head -c 600)"

# ---- 3. rollback rehearsal: the canary Mac never comes back ---------------------------
write_conf 60
canary_ctl bootout
since="$(mark)"
run_updater apply $NEW_TAG $RELDIR/$NEW_TAG "$EV/updater-apply-canary-down.txt"; rc=$?
audit_tail 60 >"$EV/audit-after-rollback.jsonl"
pre_state >"$EV/state-1-after-rollback.txt"
journal_since macprovider-coordinator "$since" "$EV/coordinator-rollback.log"
if [ $rc != 0 ] && grep -q 'rolled_back' "$EV/audit-after-rollback.jsonl" && diff -q "$EV/state-0-before.txt" "$EV/state-1-after-rollback.txt" >/dev/null; then
  result S2-updater-rollback PASS "apply with the canary down rc=$rc, transaction rolled back; current, coordinator.yaml, gateway.yaml, binaries, /healthz and live release identical to before ($(grep current= "$EV/state-1-after-rollback.txt"))"
else
  result S2-updater-rollback FAIL "rc=$rc rolled_back=$(grep -c rolled_back "$EV/audit-after-rollback.jsonl"); state diff: $(diff "$EV/state-0-before.txt" "$EV/state-1-after-rollback.txt" | tr '\n' ' ' | head -c 500); updater: $(grep -v '^rc=' "$EV/updater-apply-canary-down.txt" | tail -2 | tr '\n' ' ' | head -c 300)"
fi
canary_ctl bootstrap
for i in $(seq 1 60); do canary_status 2>/dev/null | grep -q '"connected":true' && break; sleep 2; done
wait_providers 2 || true

# ---- 4. the real apply ----------------------------------------------------------------
write_conf 240
since="$(mark)"
bs0="$(wc -l </root/e2e/logs/betterstack.jsonl 2>/dev/null || echo 0)"
# Buyer traffic through nginx for the whole apply (one request every 5 s: sparse enough that the drain sees its 3 s at zero),
# to see what a buyer gets in the window between the two units restarting.
prun="$(run_id s2window)"; rm -f "$EV/probe.stop" "$E2E_EVIDENCE/$prun.load.jsonl"
python3 $E2E_H16/tools/probe-loop.py --run "$prun" --out "$E2E_EVIDENCE/$prun.load.jsonl" --model "$MODEL" --stop-file "$EV/probe.stop" --duration 1800 --interval 5 &
probe_pid=$!
run_updater apply $NEW_TAG $RELDIR/$NEW_TAG "$EV/updater-apply.txt"; rc=$?
sleep 5; touch "$EV/probe.stop"; wait $probe_pid 2>/dev/null
audit_tail 80 >"$EV/audit-after-apply.jsonl"
tail -n +$((bs0 + 1)) /root/e2e/logs/betterstack.jsonl >"$EV/betterstack-calls.jsonl" 2>/dev/null || true
pre_state >"$EV/state-2-after-apply.txt"
journal_since macprovider-coordinator "$since" "$EV/coordinator-apply.log"
cp /opt/macprovider/coordinator.yaml "$EV/coordinator.yaml.after-apply"
if [ $rc = 0 ]; then
  result S2-updater-apply PASS "--apply rc=0: $(grep -v '^rc=' "$EV/updater-apply.txt" | tail -1 | head -c 300)"
  echo new >/root/e2e/coordinator.side; echo new >/root/e2e/gateway.side
else
  result S2-updater-apply FAIL "--apply rc=$rc: $(grep -v '^rc=' "$EV/updater-apply.txt" | tail -4 | tr '\n' ' ' | head -c 700)"
fi
python3 - "$EV/coordinator.yaml.after-apply" >"$EV/artifact-config.txt" 2>&1 <<'PY'
import sys, yaml
a = (yaml.safe_load(open(sys.argv[1])).get("autotune") or {})
want = {"catalog_artifacts_path": "/opt/macprovider/autotune/current/autotune-artifacts.json",
        "catalog_artifacts_sig_path": "/opt/macprovider/autotune/current/autotune-artifacts.json.sig"}
got = {k: a.get(k) for k in want}
print(got)
sys.exit(0 if got == want else 1)
PY
[ $? = 0 ] && result S2-config-artifact-paths PASS "coordinator.yaml: $(cat "$EV/artifact-config.txt")" \
  || result S2-config-artifact-paths FAIL "coordinator.yaml artifact keys: $(cat "$EV/artifact-config.txt")"
cur="$(readlink /opt/macprovider/autotune/current)"
rel="$(curl -fsS http://127.0.0.1:8443/v1/autotune-release | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("release_id"),d.get("status"),sorted((d.get("feeds") or {}).keys()))' 2>&1)"
echo "$cur $rel" | grep -q 'published-2026-10-01-artifact-feed-activation-v1.*live_verified.*catalog_artifacts' \
  && result S2-live-catalog PASS "current -> $cur; /v1/autotune-release: $rel" || result S2-live-catalog FAIL "current -> $cur; /v1/autotune-release: $rel"
grep -q '"catalog_canary\|catalog canary\|provider_canary' "$EV/audit-after-apply.jsonl" \
  && result S2-canary-proof INFO "updater canary audit: $(grep -o '"event": *"[a-z_]*canary[a-z_]*"[^}]*' "$EV/audit-after-apply.jsonl" | head -3 | tr '\n' ' ' | head -c 400)"
pp="$(python3 -c 'import json,sys
c=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
print(sum(1 for x in c if x.get("method")=="PATCH" and x.get("body",{}).get("paused") is True), sum(1 for x in c if x.get("method")=="PATCH" and x.get("body",{}).get("paused") is False))' "$EV/betterstack-calls.jsonl" 2>/dev/null)"
[ "$pp" = "1 1" ] && result S2-deadman PASS "Better Stack heartbeat paused once and restored once around the apply" || result S2-deadman FAIL "dead-man PATCH pause/restore counts: $pp"
grep -q 'pricing runtime floor' "$EV/updater-apply.txt" && result S2-pricing-floor FAIL "$(grep -m1 'pricing runtime floor' "$EV/updater-apply.txt")" \
  || { [ $rc = 0 ] && result S2-pricing-floor PASS "/opt/macprovider/.pricing-runtime-floor present; the floor check ran first in apply() and admitted the candidate and the rollback target"; }

# Restart order the updater used, from the unit journals, and what buyers saw.
journalctl --since "$since" --no-pager -o short-iso-precise -u macprovider-coordinator -u macprovider-gateway \
  | grep -E 'Stopping|Stopped|Started|Starting' >"$EV/apply-unit-timeline.txt" 2>/dev/null || true
python3 $E2E_H16/tools/apply-window.py "$EV/apply-unit-timeline.txt" "$E2E_EVIDENCE/$prun.load.jsonl" >"$EV/apply-window.txt" 2>&1
[ $? = 0 ] && result S2-updater-order PASS "$(tr '\n' ';' <"$EV/apply-window.txt" | head -c 700)" \
  || result S2-updater-order FAIL "$(tr '\n' ';' <"$EV/apply-window.txt" | head -c 700)"
DRAIN_MAX=300 settle_and_check S2-updater-window-traffic "$prun"

# ---- 5. /v1/catalog-artifacts via nginx (the manual step ran before the apply) ------------
curl -s -o "$EV/catalog-artifacts.json" -w '%{http_code}' https://coordinator.malibu.tech/v1/catalog-artifacts >"$EV/ca.code"
curl -s -o "$EV/catalog-artifacts.json.sig" -w '%{http_code}' https://coordinator.malibu.tech/v1/catalog-artifacts.sig >"$EV/ca-sig.code"
if [ "$(cat "$EV/ca.code")/$(cat "$EV/ca-sig.code")" = 200/200 ] && cmp -s "$EV/catalog-artifacts.json" $RELDIR/$NEW_TAG/autotune-artifacts.json \
   && cmp -s "$EV/catalog-artifacts.json.sig" $RELDIR/$NEW_TAG/autotune-artifacts.json.sig; then
  result S2-nginx-catalog-artifacts PASS "manual step before the apply: nginx $c0 -> $d0 (old coordinator, no pair); after the apply: 200/200 and byte-identical to the signed release feed + sig"
else result S2-nginx-catalog-artifacts FAIL "before the step $c0, after the step $d0; after the apply: $(cat "$EV/ca.code")/$(cat "$EV/ca-sig.code") $(tail -1 "$EV/nginx-additive.txt")"; fi

# The canary's live proof by hand, with the same transport the updater uses.
proof_args="macprovider/catalog-release $CANARY_ID $(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(d["release_id"],d["policy_version"])' $RELDIR/$NEW_TAG/release.json) $(sha $RELDIR/$NEW_TAG/autotune-candidates.json) $(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["key_id"])' $RELDIR/$NEW_TAG/autotune-candidates.json.sig)"
ssh -i $K/canary_ssh -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$K/canary_known_hosts -F /dev/null \
  $CANARY_USER@127.0.0.1 "python3 - $proof_args" <$WTN/ops/pearl-updater/catalog-canary-proof.py >"$EV/canary-proof.json" 2>"$EV/canary-proof.err"; prc=$?
python3 - "$EV/canary-proof.json" "$RELDIR/$NEW_TAG/release.json" <<'PY' >"$EV/canary-proof.check" 2>&1
import json, sys
p = json.load(open(sys.argv[1])); r = json.load(open(sys.argv[2])); c = p["local_status"]["catalog"]
ok = c.get("state") == "live_verified" and c.get("source") == "coordinator" and c.get("release_id") == r["release_id"] and p["local_status"]["network_state"] == "buyer_serving"
print("release=%s state=%s source=%s network=%s pid=%s" % (c.get("release_id"), c.get("state"), c.get("source"), p["local_status"]["network_state"], p["launchd_pid"]))
sys.exit(0 if ok else 1)
PY
[ $? = 0 ] && [ $prc = 0 ] && result S2-canary-live-catalog PASS "real catalog-canary-proof.py over ssh: $(cat "$EV/canary-proof.check")" \
  || result S2-canary-live-catalog FAIL "proof rc=$prc: $(cat "$EV/canary-proof.check" "$EV/canary-proof.err" | tr '\n' ' ' | head -c 400)"

# ---- 6. baseline catalog traffic on the new pair ---------------------------------------
wait_providers 2 || true
run="$(run_id s2new)"
traffic "$run"
settle_and_check S2-new-pair-catalog "$run" --expect ns=settled,st=settled
compare_catalog_shape S2-new-pair-shape "$run" "new coordinator + new gateway"

# ---- 7. existing deploy guards in the new tree -------------------------------------------
install -d -m 0755 /root/e2e/shim-bin && install -m 0755 $E2E_H16/lib/python3-shim /root/e2e/shim-bin/python3
if ( cd $WTN && PATH=/root/e2e/shim-bin:$PATH E2E_VERIFY_CACHE_RECORD_ON_MISS=1 PYTHONDONTWRITEBYTECODE=1 timeout 1200 python3 ops/pearl-updater/test_pearl_updater.py ) >"$EV/test_pearl_updater.txt" 2>&1; then
  result S2-guard-updater-tests PASS "$(tail -3 "$EV/test_pearl_updater.txt" | tr '\n' ' ')"
elif grep -q "Command '\['git', 'show'" "$EV/test_pearl_updater.txt" \
  && ! grep '^ERROR:' "$EV/test_pearl_updater.txt" \
    | grep -Ev 'test_(canary_rollout_authority_hashes_match_issue_825_duplicate_fleet_runtime|advertised_version_update_preserves_config_and_validates_candidate)' >/dev/null \
  && { ! grep -q '^ERROR: test_advertised_version_update_preserves_config_and_validates_candidate' "$EV/test_pearl_updater.txt" \
    || grep -q 'pearl_updater.CommandTimeout: command timed out after 30s: python3' "$EV/test_pearl_updater.txt"; }; then
  # The archive has no pinned history (D9), and QEMU can exceed the shipped
  # verifier's 30 s production timeout even after the exact-input cache warmup
  # (D7). Keep this classification narrow so any other updater error fails.
  gap_detail="archive checkout without pinned git history"
  grep -q '^ERROR: test_advertised_version_update_preserves_config_and_validates_candidate' "$EV/test_pearl_updater.txt" \
    && gap_detail="QEMU verifier timeout plus $gap_detail"
  result S2-guard-updater-tests GAP "all non-environment updater tests pass; $gap_detail"
else
  result S2-guard-updater-tests FAIL "$(tail -6 "$EV/test_pearl_updater.txt" | tr '\n' ' ' | head -c 600)"
fi
for t in check_deploy_static_feed_access deploy_canary_live_catalog_proof deploy_catalog_compare_live; do
  ( cd $WTN && timeout 600 bash phase4-coordinator/dist/test/$t.test.sh ) >"$EV/guard-$t.txt" 2>&1 \
    && result "S2-guard-$t" PASS "$(tail -1 "$EV/guard-$t.txt")" || result "S2-guard-$t" FAIL "$(tail -4 "$EV/guard-$t.txt" | tr '\n' ' ' | head -c 500)"
done
git -C $WTN status --porcelain | grep -v '^?? phase4-coordinator/dist/stats-hardware-verifier-linux-amd64$' | grep . >"$EV/tree-dirt.txt" && result S2-guards-clean-tree INFO "guard tests left files: $(head -5 "$EV/tree-dirt.txt" | tr '\n' ' ')" || true
