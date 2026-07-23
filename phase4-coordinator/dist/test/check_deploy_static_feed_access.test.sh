#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_SH="$SCRIPT_DIR/../deploy-pearl-vps.sh"
RECOVER_SH="$SCRIPT_DIR/../coordinator-deploy-recover.sh"
WATCHDOG_UNIT="$SCRIPT_DIR/../systemd/macprovider-coordinator-deploy-watchdog.service"
CATALOG_RUNBOOK="$SCRIPT_DIR/../../../ops/runbooks/catalog-release-provider-upgrade.md"
PEARL_RUNBOOK="$SCRIPT_DIR/../../../ops/runbooks/pearl-release-updater.md"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

bash -n "$DEPLOY_SH"
bash -n "$RECOVER_SH"
[ -f "$WATCHDOG_UNIT" ] || fail "remote deploy watchdog unit is missing"

grep -q '_autotune_release=\\$_autotune_root/releases/$AUTOTUNE_RELEASE_DIR_NAME' "$DEPLOY_SH" ||
  fail "deploy must stage a content-addressed immutable catalog envelope"

grep -q 'install .*tier2-catalog.json \\$_autotune_stage/tier2-catalog.json' "$DEPLOY_SH" &&
  grep -q 'verify-directory --directory \\$_autotune_stage --tier2-public-key-file' "$DEPLOY_SH" ||
  fail "deploy must stage and authenticate Tier-2 inside the release envelope"

grep -q 'CATALOG_REMOTE_PATH_CANONICAL="/opt/macprovider/autotune/current/tier2-catalog.json"' "$DEPLOY_SH" ||
  fail "deploy must accept only the release-bound Tier-2 current path"

grep -q 'never.*writes Tier-2 through the current symlink' "$DEPLOY_SH" &&
  grep -q 'root-owned immutable release directories' "$DEPLOY_SH" ||
  fail "deploy must explain root-owned immutable staging and pointer activation"

activation_line=$(grep -nF 'ln -sfn releases/$AUTOTUNE_RELEASE_DIR_NAME' "$DEPLOY_SH" | tail -n1 | cut -d: -f1)
stage_tier2_line=$(grep -nF 'install -o root -g macprovider -m 0640 $DEPLOY_TMP/tier2-catalog.json \$_autotune_stage/tier2-catalog.json' "$DEPLOY_SH" | tail -n1 | cut -d: -f1)
legacy_remove_line=$(grep -nF 'rm -f /opt/macprovider/tier2-catalog.json' "$DEPLOY_SH" | tail -n1 | cut -d: -f1)
restart_line=$(grep -nF 'systemctl restart macprovider-coordinator' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
[ -n "$stage_tier2_line" ] && [ -n "$activation_line" ] &&
  [ "$stage_tier2_line" -lt "$activation_line" ] ||
  fail "Tier-2 must be staged in the immutable release before current activation"
[ -n "$legacy_remove_line" ] && [ -n "$restart_line" ] &&
  [ "$activation_line" -lt "$legacy_remove_line" ] && [ "$legacy_remove_line" -lt "$restart_line" ] ||
  fail "deploy must remove the independent Tier-2 bridge after current activation and before coordinator restart"

if grep -Eq 'install .* /opt/macprovider/tier2-catalog\.json|install .* \$CATALOG_REMOTE_PATH_CANONICAL' "$DEPLOY_SH"; then
  fail "successful deploy must not install Tier-2 through the independent path or current symlink"
fi

grep -q '_tier2_migration_gate_remote_script()' "$DEPLOY_SH" &&
  grep -q 'legacy Tier-2 catalog bytes differ from active autotune/current release' "$DEPLOY_SH" ||
  fail "deploy must preflight legacy Tier-2 bridge byte equality before mutation"
grep -q 'ROOT = "/opt/macprovider"' "$DEPLOY_SH" &&
  ! grep -q 'MACPROVIDER_ROOT' "$DEPLOY_SH" &&
  grep -q 'O_NOFOLLOW' "$DEPLOY_SH" &&
  grep -q 'dir_fd=' "$DEPLOY_SH" &&
  grep -q 'info.st_nlink != 1' "$DEPLOY_SH" ||
  fail "Tier-2 migration gate must be fixed-root and no-follow/dirfd hardened"
grep -q 'unsafe transient autotune/current.next exists before deploy activation' "$DEPLOY_SH" &&
  grep -q 'unsafe autotune/.previous-target contents before Tier-2 migration' "$DEPLOY_SH" ||
  fail "Tier-2 migration gate must reject unsafe current.next and .previous-target state"
grep -q 'os.open(tmp_name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | NOFOLLOW' "$DEPLOY_SH" &&
  grep -q "os.rename(tmp_name, '.previous-target', src_dir_fd=autotune_fd, dst_dir_fd=autotune_fd)" "$DEPLOY_SH" ||
  fail "deploy must publish .previous-target via no-follow temp and atomic rename"

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

grep -q 'flock -n /run/lock/macprovider-pearl-updater.lock flock -n /opt/macprovider/.coordinator-deploy.lock' "$DEPLOY_SH" &&
  grep -q 'unsafe global Pearl deployment lock' "$DEPLOY_SH" ||
  fail "direct deploy and signed updater must share one validated global mutation lock"

grep -q 'cmp -s \$DEPLOY_TMP/coordinator-linux-amd64 /opt/macprovider/coordinator' "$DEPLOY_SH" &&
  ! grep -q 'install -o root -g macprovider -m 0750 \$DEPLOY_TMP/coordinator-linux-amd64 /opt/macprovider/coordinator' "$DEPLOY_SH" ||
  fail "direct catalog deploy must not replace one half of the signed coordinator/gateway pair"

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

[ "$(grep -c 'coordinator-deploy-recover --recover-under-global' "$DEPLOY_SH")" -eq 2 ] ||
  fail "controller-held recovery must not recursively reacquire the global deploy lock"

grep -q 'TimeoutStartSec=infinity' "$WATCHDOG_UNIT" &&
  grep -q 'ExecStart=/opt/macprovider/coordinator-deploy-recover --recover' "$WATCHDOG_UNIT" &&
  grep -q 'GLOBAL_LOCK_FILE=' "$RECOVER_SH" &&
  grep -q '\$FLOCK 7' "$RECOVER_SH" &&
  grep -q '\$FLOCK 9' "$RECOVER_SH" &&
  grep -q '\$FLOCK 8' "$RECOVER_SH" ||
  fail "remote watchdog recovery must own the global, deploy, and operation locks in order"

grep -q 'flock -s 8' "$DEPLOY_SH" ||
  fail "live deploy mutations must hold the shared operation barrier"

armed_line=$(grep -nF 'touch "$DEPLOY_LOCK_WATCHDOG_ARMED"' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
holder_line=$(grep -nF 'DEPLOY_LOCK_PID=$!' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
[ -n "$armed_line" ] && [ -n "$holder_line" ] && [ "$armed_line" -lt "$holder_line" ] ||
  fail "local lock-loss watchdog must be armed before the holder can exit"

grep -q 'kill -TERM.*DEPLOY_CONTROLLER_PID' "$DEPLOY_SH" ||
  fail "lock loss must fail-stop the controller"

grep -q '\["/usr/sbin/lsof", "-nP", "-a", "-p", str(pid), "-d", "txt", "-F", "Dfin"\]' "$DEPLOY_SH" &&
  grep -q 'text_device == binary_info.st_dev' "$DEPLOY_SH" &&
  grep -q 'text_inode == binary_info.st_ino' "$DEPLOY_SH" &&
  ! grep -q 'process_info = os.stat(process_path' "$DEPLOY_SH" ||
  fail "canary executable proof must compare the running text vnode, not the replaced pathname"

grep -q 'Requires=macprovider-coordinator-deploy-recovery.service' "$SCRIPT_DIR/../systemd/macprovider-coordinator-deploy-guard.conf" ||
  fail "coordinator startup must recover orphaned deploy transactions"

grep -q 'ExecStart=/opt/macprovider/coordinator-deploy-recover --pre-start' "$SCRIPT_DIR/../systemd/macprovider-coordinator-deploy-recovery.service" ||
  fail "coordinator startup recovery must run as a separate root oneshot"

grep -q 'OPERATION_LOCK_FILE=' "$RECOVER_SH" && grep -q '\$FLOCK -n 7' "$RECOVER_SH" &&
  grep -q '\$FLOCK -n 9' "$RECOVER_SH" && grep -q '\$FLOCK 8' "$RECOVER_SH" ||
  fail "pre-start recovery must respect the global deploy lease and wait for in-flight mutation"

grep -q 'current.bootstrap' "$DEPLOY_SH" ||
  fail "deploy must establish current on first rollout before a possible late abort"

grep -q 'CATALOG_CANARY_PROVIDER_ID is required' "$DEPLOY_SH" ||
  fail "deploy must require an explicit provider canary"

grep -q 'CATALOG_CANARY_AUTH_TOKEN is required' "$DEPLOY_SH" ||
  fail "deploy must require authenticated canary evidence"

token_validator_tmp="$(mktemp)"
trap 'rm -f "$token_validator_tmp"' EXIT
awk '/^_validate_catalog_canary_auth_token\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$DEPLOY_SH" > "$token_validator_tmp"
grep -qF '_validate_catalog_canary_auth_token()' "$token_validator_tmp" ||
  fail "deploy must keep an extractable portable canary token validator"
# BSD grep rejects interval upper bounds greater than 255. Length checks belong
# in Bash so the production deploy remains portable on the operator Mac.
if grep -qF '{32,512}' "$DEPLOY_SH"; then
  fail "deploy must not use a BSD-grep-incompatible {32,512} interval"
fi
# shellcheck disable=SC1090
. "$token_validator_tmp"
token_31="$(printf '%031d' 0)"
token_32="$(printf '%032d' 0)"
token_512="$(printf '%0512d' 0)"
token_513="$(printf '%0513d' 0)"
! _validate_catalog_canary_auth_token "$token_31" ||
  fail "canary token validator must reject 31-byte tokens"
_validate_catalog_canary_auth_token "$token_32" ||
  fail "canary token validator must accept safe 32-byte tokens"
_validate_catalog_canary_auth_token "$token_512" ||
  fail "canary token validator must accept safe 512-byte tokens"
! _validate_catalog_canary_auth_token "$token_513" ||
  fail "canary token validator must reject 513-byte tokens"
! _validate_catalog_canary_auth_token "${token_32}!" ||
  fail "canary token validator must reject unsafe characters"
! _validate_catalog_canary_auth_token "${token_32}"$'\n''url = "https://attacker.invalid/"' ||
  fail "canary token validator must reject newline curl-config injection"
! _validate_catalog_canary_auth_token "${token_32}"$'\r''header = "X-Injected: yes"' ||
  fail "canary token validator must reject carriage-return curl-config injection"

deadline_alarm_tmp="$(mktemp)"
trap 'rm -f "$token_validator_tmp" "$deadline_alarm_tmp"' EXIT
awk '/^_run_with_deadline_alarm\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$DEPLOY_SH" > "$deadline_alarm_tmp"
grep -qF '_run_with_deadline_alarm()' "$deadline_alarm_tmp" ||
  fail "deploy must keep an extractable subprocess deadline helper"
# shellcheck disable=SC1090
. "$deadline_alarm_tmp"
deadline_start="$SECONDS"
if _run_with_deadline_alarm 1 sh -c 'sleep 30'; then
  fail "subprocess deadline helper must terminate a hung command"
fi
[ "$((SECONDS - deadline_start))" -lt 5 ] ||
  fail "subprocess deadline helper did not enforce its wall-clock bound"
_run_with_deadline_alarm 2 sh -c 'exit 0' ||
  fail "subprocess deadline helper must preserve successful commands"

deadline_parser_tmp="$(mktemp)"
trap 'rm -f "$token_validator_tmp" "$deadline_alarm_tmp" "$deadline_parser_tmp"' EXIT
awk '/^_parse_model_hash_legacy_until\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$DEPLOY_SH" > "$deadline_parser_tmp"
grep -qF '_parse_model_hash_legacy_until()' "$deadline_parser_tmp" ||
  fail "deploy must keep an extractable MODEL_HASH_LEGACY_UNTIL parser"
# shellcheck disable=SC1090
. "$deadline_parser_tmp"
deadline='2030-01-02T03:04:05Z'
[ "$(_parse_model_hash_legacy_until "  $deadline  ")" = "$deadline" ] ||
  fail "legacy deadline parser must accept an unquoted scalar"
[ "$(_parse_model_hash_legacy_until "  \"$deadline\"  ")" = "$deadline" ] ||
  fail "legacy deadline parser must strip matching double quotes"
[ "$(_parse_model_hash_legacy_until "  '$deadline'  ")" = "$deadline" ] ||
  fail "legacy deadline parser must strip matching single quotes"
[ -z "$(_parse_model_hash_legacy_until '   ')" ] ||
  fail "legacy deadline parser must preserve an absent deadline as empty"
if _parse_model_hash_legacy_until '2030-01-02T03:04:05Z trailing' >/dev/null 2>&1; then
  fail "legacy deadline parser must reject multiple scalar tokens"
fi

grep -q 'CATALOG_CANARY_SSH_TARGET is required' "$DEPLOY_SH" ||
  fail "deploy must require a trusted canary host for exact installed-byte verification"

grep -q 'StrictHostKeyChecking=yes' "$DEPLOY_SH" ||
  fail "trusted canary verification must check the SSH host key"

! grep -q '/usr/bin/proc_pidpath' "$DEPLOY_SH" ||
  fail "Mac canary proof must not depend on nonexistent /usr/bin/proc_pidpath"

grep -q 'assigned_id=\$CANARY_ASSIGNED_QUERY&details=deployment' "$DEPLOY_SH" ||
  fail "deploy must gate completion on the exact proved provider session"

proof_retry_line=$(grep -nF 'if run_catalog_canary_mac_proof "$CANARY_PROOF_TIMEOUT_S" > "$CANARY_INSTALLED_BODY"' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
session_rebind_line=$(grep -nF 'read -r CANARY_ASSIGNED_ID CANARY_CATALOG_ROW_IDENTITY <<< "$CANARY_BINDING"' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
session_query_line=$(grep -nF 'CANARY_STATUS=$(curl --config "$CANARY_CURL_CONFIG"' "$DEPLOY_SH" | head -n1 | cut -d: -f1)
[ -n "$proof_retry_line" ] && [ -n "$session_rebind_line" ] && [ -n "$session_query_line" ] &&
  [ "$proof_retry_line" -lt "$session_rebind_line" ] && [ "$session_rebind_line" -lt "$session_query_line" ] ||
  fail "each canary recovery attempt must re-prove the Mac and bind the query to that attempt's session"

grep -q 'CANARY_RECOVERY_DEADLINE=' "$DEPLOY_SH" &&
  grep -q '_run_with_deadline_alarm "$timeout_s" "${CANARY_SSH\[@\]}"' "$DEPLOY_SH" &&
  grep -q 'rm -f "$CANARY_INSTALLED_BODY" "$CANARY_POOL_BODY"' "$DEPLOY_SH" &&
  grep -q 'waiting for exact catalog canary recovery' "$DEPLOY_SH" ||
  fail "deploy must retry full canary proof within a wall-clock deadline and discard stale attempt output"

grep -q 'os.O_RDONLY | nofollow | nonblock' "$DEPLOY_SH" ||
  fail "Mac proof must open untrusted file entries without blocking on special files"

grep -q 'value.get("assigned_id") != sys.argv\[3\]' "$DEPLOY_SH" ||
  fail "deploy must reject coordinator evidence for a different assigned session"

grep -q 'local_status.get("network_state") != "buyer_serving"' "$DEPLOY_SH" ||
  fail "deploy must prove the canary Mac reports buyer-serving network state"

grep -q 'value.get("buyer_serving") is not True' "$DEPLOY_SH" ||
  fail "deploy canary must require explicit buyer-serving capacity"

grep -q 'value.get("catalog_evidence_source") != "provider_reported"' "$DEPLOY_SH" ||
  fail "deploy must treat coordinator catalog fields as provider-reported compatibility evidence"

grep -q 'value.get("catalog_admission_mode") != "current"' "$DEPLOY_SH" ||
  fail "deploy canary must reject legacy and previous catalog admissions"

grep -A1 -F '  "$STATIC_DEMAND_SIG" \' "$DEPLOY_SH" |
  grep -qF '  "$AUTOTUNE_TIER2_JSON" <<'"'"'PY'"'"'' ||
  fail "deploy canary expected-byte set must include the release-bound Tier-2 catalog"

grep -q 'value.get("catalog_candidate_sha256") != sys.argv\[6\]' "$DEPLOY_SH" ||
  fail "deploy canary must match the active candidate catalog digest"

grep -q 'read -r CANARY_ASSIGNED_ID CANARY_CATALOG_ROW_IDENTITY' "$DEPLOY_SH" &&
  grep -q 'catalog.get("policy_version") != expected_policy_version' "$DEPLOY_SH" &&
  grep -q 'catalog.get("row_identity", "")' "$DEPLOY_SH" &&
  grep -q 'canary local catalog proof is not bound to the coordinator-admitted envelope' "$DEPLOY_SH" ||
  fail "deploy canary must cross-bind exact policy and row between coordinator and Mac proof"

grep -q 'canary catalog byte mismatch' "$DEPLOY_SH" ||
  fail "deploy must compare exact installed canary catalog bytes before commit"

grep -q 'canary provider identity mismatch' "$DEPLOY_SH" &&
  grep -q 'live canary provider text vnode is stale or not the verified installation binary' "$DEPLOY_SH" &&
  grep -q 'live canary provider status does not match the expected identity and catalog' "$DEPLOY_SH" ||
  fail "exact-byte proof must bind the named provider, live process, and local catalog status"

grep -q 'O_NOFOLLOW' "$DEPLOY_SH" && grep -q 'dir_fd=' "$DEPLOY_SH" ||
  fail "trusted canary files must be opened no-follow through directory file descriptors"

grep -q '/v1/demand-rank' "$DEPLOY_SH" ||
  fail "deploy smoke must probe /v1/demand-rank"

grep -q 'chmod o+x /opt/macprovider' "$DEPLOY_SH" &&
  fail "deploy must not chmod o+x /opt/macprovider for legacy nginx static feeds"

grep -q 'KEEP_DOWNLOADS=1 scripts/verify-tier2-provider-release.sh' "$CATALOG_RUNBOOK" &&
  grep -q 'prior provider live' "$CATALOG_RUNBOOK" &&
  grep -q 'MACPROVIDER_EMERGENCY_ROLLBACK=1' "$CATALOG_RUNBOOK" ||
  fail "catalog runbook must prefetch without mutation and document bounded emergency rollback"

grep -q 'PEARL_UPDATER_PROVIDER_ADMISSION_POLICY=bridge_required' "$PEARL_RUNBOOK" &&
  grep -q 'PEARL_UPDATER_MINIMUM_POOL_READY_AFTER_ROLLOUT=' "$PEARL_RUNBOOK" &&
  grep -q 'PEARL_UPDATER_MINIMUM_BRIDGE_REMAINING_S=' "$PEARL_RUNBOOK" &&
  ! grep -q 'proc_pidpath' "$PEARL_RUNBOOK" ||
  fail "Pearl rollout runbook must bind bridge capacity policy and valid Mac proof tooling"

grep -q 'set -euo pipefail' "$CATALOG_RUNBOOK" &&
  grep -q 'legacy_bridge is not zero' "$CATALOG_RUNBOOK" &&
  grep -q 'test "$(wc -l <"$EVIDENCE")" -ge 31' "$CATALOG_RUNBOOK" ||
  fail "catalog runbook must provide fail-fast continuous zero-bridge evidence"

echo "PASS: deploy autotune feed access guards present"
