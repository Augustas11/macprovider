#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_SH="$SCRIPT_DIR/../deploy-pearl-vps.sh"
RECOVER_SH="$SCRIPT_DIR/../coordinator-deploy-recover.sh"
WATCHDOG_UNIT="$SCRIPT_DIR/../systemd/macprovider-coordinator-deploy-watchdog.service"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

bash -n "$DEPLOY_SH"
bash -n "$RECOVER_SH"
[ -f "$WATCHDOG_UNIT" ] || fail "remote deploy watchdog unit is missing"

grep -q '_autotune_release=\\$_autotune_root/releases/$AUTOTUNE_RELEASE_ID' "$DEPLOY_SH" ||
  fail "deploy must stage an immutable versioned autotune release"

grep -q 'sudo -u macprovider test -r /opt/macprovider/autotune/current/autotune-candidates.json' "$DEPLOY_SH" ||
  fail "deploy smoke must verify macprovider can read autotune feeds"

grep -q 'mv -Tf.*current.next.*current' "$DEPLOY_SH" ||
  fail "deploy must atomically activate the verified release"

grep -q 'restore_regular had-coordinator coordinator' "$RECOVER_SH" ||
  fail "catalog rollback must restore the previous coordinator binary"

grep -q 'restore_regular had-config coordinator.yaml' "$RECOVER_SH" ||
  fail "catalog rollback must restore the previous coordinator config"

grep -q 'COORDINATOR_DEPLOY_ARMED=1' "$DEPLOY_SH" ||
  fail "deploy must arm rollback before replacing live coordinator files"

grep -q '_rollback_stage=.*stage' "$DEPLOY_SH" ||
  fail "deploy must construct rollback state outside the published snapshot path"

grep -q 'touch.*_rollback_stage/complete' "$DEPLOY_SH" ||
  fail "deploy must mark a fully constructed rollback snapshot"

grep -q 'mv.*_rollback_stage.*_rollback' "$DEPLOY_SH" ||
  fail "deploy must atomically publish the complete rollback snapshot"

grep -q 'restore_link_or_file had-service-unit macprovider-coordinator.service' "$RECOVER_SH" ||
  fail "coordinator rollback must restore the previous systemd unit"

grep -q 'release-was-absent' "$RECOVER_SH" ||
  fail "coordinator rollback must remove a newly staged uncommitted release"

grep -q 'restore_link_or_file had-wants-link' "$RECOVER_SH" ||
  fail "coordinator rollback must preserve exact service enablement or masking state"

grep -q 'had-recovery-helper' "$DEPLOY_SH" && grep -q 'had-recovery-helper' "$RECOVER_SH" ||
  fail "coordinator rollback must preserve its durable recovery guard"

grep -q 'had-previous-target' "$RECOVER_SH" ||
  fail "coordinator rollback must preserve the prior catalog bridge state"

grep -q 'had-tier2-catalog' "$DEPLOY_SH" && grep -q 'restore_regular had-tier2-catalog' "$RECOVER_SH" ||
  fail "coordinator rollback must preserve the exact Tier-2 signed catalog"

grep -q 'had-coordinator-cli' "$DEPLOY_SH" && grep -q 'restore_regular had-coordinator-cli' "$RECOVER_SH" ||
  fail "coordinator rollback must preserve the matching operator CLI"

for marker in had-stats-inventory-binary had-stats-billing-binary had-stats-hardware-binary \
  had-stats-inventory-service had-stats-inventory-timer \
  had-stats-billing-service had-stats-billing-timer \
  had-stats-hardware-service had-stats-hardware-timer; do
  grep -q "$marker" "$DEPLOY_SH" && grep -q "$marker" "$RECOVER_SH" ||
    fail "coordinator rollback coverage missing for $marker"
done

for marker in had-nginx-stats-shared had-nginx-stats-security-headers \
  had-nginx-stats-cors-429 had-nginx-stats-proxy-public \
  had-nginx-stats-proxy-partner had-nginx-coordinator-site \
  had-nginx-stats-site had-nginx-coordinator-enabled had-nginx-stats-enabled; do
  grep -q "$marker" "$DEPLOY_SH" && grep -q "$marker" "$RECOVER_SH" ||
    fail "nginx rollback coverage missing for $marker"
done

grep -q 'snapshot_acl /var/lib/macprovider/request-log.sqlite' "$DEPLOY_SH" &&
  grep -q 'restore_acl had-request-log-db-acl' "$RECOVER_SH" ||
  fail "request-log ACL changes must be captured and restored"

grep -q 'try-reload-or-restart nginx' "$RECOVER_SH" ||
  fail "rollback must validate and activate the restored nginx graph"

freeze_line=$(grep -nF '# Freeze sidecar execution for the release window.' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
binary_install_line=$(grep -nF 'install -o root -g macprovider-stats -m 0750 $DEPLOY_TMP/stats-inventory-sync-linux-amd64' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
sidecar_activate_line=$(grep -nF '# Sidecars remain frozen until every coordinator/catalog/canary check has' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
commit_line=$(grep -nF 'touch /opt/macprovider/.coordinator-deploy-rollback/committed' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
[ -n "$freeze_line" ] && [ -n "$binary_install_line" ] && [ "$freeze_line" -lt "$binary_install_line" ] ||
  fail "stats sidecars must freeze before transaction binaries are replaced"
[ -n "$sidecar_activate_line" ] && [ -n "$commit_line" ] && [ "$sidecar_activate_line" -lt "$commit_line" ] ||
  fail "stats sidecars must reactivate only as the final pre-commit mutation"

grep -q 'flock -n /opt/macprovider/.coordinator-deploy.lock' "$DEPLOY_SH" ||
  fail "deploy must hold a controller-lifetime remote lock"

grep -q 'O_NOFOLLOW' "$DEPLOY_SH" && grep -q 'info.st_nlink != 1' "$DEPLOY_SH" &&
  grep -q 'unsafe coordinator deploy lock' "$DEPLOY_SH" ||
  fail "deploy lock setup must reject symlinks, hardlinks, and unsafe ownership/modes"

grep -q 'sidecar unit did not stop:' "$DEPLOY_SH" ||
  fail "deploy must prove every loaded sidecar is inactive before replacement"

grep -q 'recover interrupted coordinator deploy' "$DEPLOY_SH" ||
  fail "deploy must recover an interrupted transaction before reading live state"

grep -q 'CRITICAL: coordinator deploy rollback failed' "$DEPLOY_SH" ||
  fail "deploy must report rollback failure distinctly"

grep -q 'systemctl start --no-block macprovider-coordinator-deploy-watchdog.service' "$DEPLOY_SH" ||
  fail "deploy must arm a remote watchdog that survives controller loss"

grep -q 'TimeoutStartSec=infinity' "$WATCHDOG_UNIT" &&
  grep -q 'ExecStart=/usr/bin/flock /opt/macprovider/.coordinator-deploy.lock /usr/bin/flock /opt/macprovider/.coordinator-deploy-operation.lock' "$WATCHDOG_UNIT" ||
  fail "remote watchdog must wait for both the deploy lease and in-flight operation barrier"

grep -q 'flock -s 8' "$DEPLOY_SH" ||
  fail "live deploy mutations must hold the shared operation barrier"

armed_line=$(grep -nF 'touch "$DEPLOY_LOCK_WATCHDOG_ARMED"' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
holder_line=$(grep -nF 'DEPLOY_LOCK_PID=$!' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
[ -n "$armed_line" ] && [ -n "$holder_line" ] && [ "$armed_line" -lt "$holder_line" ] ||
  fail "local lock-loss watchdog must be armed before the holder can exit"

grep -q 'kill -TERM.*DEPLOY_CONTROLLER_PID' "$DEPLOY_SH" ||
  fail "lock loss must fail-stop the controller"

grep -q 'Requires=macprovider-coordinator-deploy-recovery.service' "$SCRIPT_DIR/../systemd/macprovider-coordinator-deploy-guard.conf" ||
  fail "coordinator startup must recover orphaned deploy transactions"

grep -q 'ExecStart=/opt/macprovider/coordinator-deploy-recover --pre-start' "$SCRIPT_DIR/../systemd/macprovider-coordinator-deploy-recovery.service" ||
  fail "coordinator startup recovery must run as a separate root oneshot"

grep -q 'OPERATION_LOCK_FILE=' "$RECOVER_SH" && grep -q '\$FLOCK 8' "$RECOVER_SH" ||
  fail "pre-start recovery must wait for any in-flight deploy mutation"

grep -q 'current.bootstrap' "$DEPLOY_SH" ||
  fail "deploy must establish current on first rollout before a possible late abort"

grep -q 'CATALOG_CANARY_PROVIDER_ID is required' "$DEPLOY_SH" ||
  fail "deploy must require an explicit provider canary"

grep -q 'CATALOG_CANARY_AUTH_TOKEN is required' "$DEPLOY_SH" ||
  fail "deploy must require authenticated canary evidence"

grep -q 'CATALOG_CANARY_SSH_TARGET is required' "$DEPLOY_SH" ||
  fail "deploy must require a trusted canary host for exact installed-byte verification"

grep -q 'StrictHostKeyChecking=yes' "$DEPLOY_SH" ||
  fail "trusted canary verification must check the SSH host key"

grep -q '/v1/pool/check?provider_id=\$CATALOG_CANARY_PROVIDER_ID&details=deployment' "$DEPLOY_SH" ||
  fail "deploy must gate completion on provider pool admission"

grep -q 'value.get("buyer_serving") is not True' "$DEPLOY_SH" ||
  fail "deploy canary must require explicit buyer-serving capacity"

grep -q 'value.get("catalog_evidence_source") != "provider_reported"' "$DEPLOY_SH" ||
  fail "deploy must treat coordinator catalog fields as provider-reported compatibility evidence"

grep -q 'value.get("catalog_admission_mode") != "current"' "$DEPLOY_SH" ||
  fail "deploy canary must reject legacy and previous catalog admissions"

grep -q 'value.get("catalog_candidate_sha256") != sys.argv\[5\]' "$DEPLOY_SH" ||
  fail "deploy canary must match the active candidate catalog digest"

grep -q 'canary catalog byte mismatch' "$DEPLOY_SH" ||
  fail "deploy must compare exact installed canary catalog bytes before commit"

grep -q 'canary provider identity mismatch' "$DEPLOY_SH" &&
  grep -q 'live canary provider is not the verified installation binary' "$DEPLOY_SH" &&
  grep -q 'live canary provider status does not match the expected identity and catalog' "$DEPLOY_SH" ||
  fail "exact-byte proof must bind the named provider, live process, and local catalog status"

grep -q 'O_NOFOLLOW' "$DEPLOY_SH" && grep -q 'dir_fd=' "$DEPLOY_SH" ||
  fail "trusted canary files must be opened no-follow through directory file descriptors"

grep -q '/v1/demand-rank' "$DEPLOY_SH" ||
  fail "deploy smoke must probe /v1/demand-rank"

grep -q 'chmod o+x /opt/macprovider' "$DEPLOY_SH" &&
  fail "deploy must not chmod o+x /opt/macprovider for legacy nginx static feeds"

echo "PASS: deploy autotune feed access guards present"
