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

grep -q 'flock -n /opt/macprovider/.coordinator-deploy.lock' "$DEPLOY_SH" ||
  fail "deploy must hold a controller-lifetime remote lock"

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

grep -q '/v1/pool/check?provider_id=\$CATALOG_CANARY_PROVIDER_ID&details=deployment' "$DEPLOY_SH" ||
  fail "deploy must gate completion on provider pool admission"

grep -q 'value.get("buyer_serving") is not True' "$DEPLOY_SH" ||
  fail "deploy canary must require explicit buyer-serving capacity"

grep -q 'value.get("catalog_admission_mode") != "current"' "$DEPLOY_SH" ||
  fail "deploy canary must reject legacy and previous catalog admissions"

grep -q 'value.get("catalog_candidate_sha256") != sys.argv\[5\]' "$DEPLOY_SH" ||
  fail "deploy canary must match the active candidate catalog digest"

grep -q '/v1/demand-rank' "$DEPLOY_SH" ||
  fail "deploy smoke must probe /v1/demand-rank"

grep -q 'chmod o+x /opt/macprovider' "$DEPLOY_SH" &&
  fail "deploy must not chmod o+x /opt/macprovider for legacy nginx static feeds"

echo "PASS: deploy autotune feed access guards present"
