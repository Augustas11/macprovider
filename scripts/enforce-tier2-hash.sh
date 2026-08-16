#!/usr/bin/env bash
# Guarded SPEC-008 C2 enforcement flip with durable remote rollback.

set -euo pipefail

usage() {
  cat <<'USAGE'
usage: scripts/enforce-tier2-hash.sh [--plan|--apply]

Environment:
  SSH_KEY             default: ~/.ssh/pearl_operator_ed25519
  VPS_HOST            default: 159.223.165.194
  VPS_USER            default: root
  SSH_PORT            default: 22
  SSH_KNOWN_HOSTS     default: ~/.ssh/known_hosts
  REMOTE_CONFIG       default: /opt/macprovider/coordinator.yaml
  SERVICE             default: macprovider-coordinator
  COORDINATOR_ORIGIN  must remain https://coordinator.malibu.tech
  GATEWAY_ORIGIN      must remain https://api.malibu.tech
  DEMO_TOKEN          required by --apply
  OPERATOR_KEY        required by --apply
  PROOF_TAG           must be the sealed Pearl coordinator tag v1.8.60
  SSH_BIN             default: ssh

Apply pins these proof programs and rejects substitutes:
  scripts/verify-tier2-live.sh
  /usr/local/sbin/macprovider-pearl-update
  /usr/local/sbin/macprovider-tier2-enforcement-watchdog
  /usr/local/sbin/macprovider-pearl-update-gate
  /etc/systemd/system/macprovider-tier2-enforcement-reconcile.service
  protected-service transaction gate drop-ins

The remote watchdog durably journals the exact config/release identity and
restores require_hash_verified=false after 15 minutes unless every post-flip
proof succeeds and the transaction is explicitly committed.
USAGE
}

mode="plan"
case "${1:---plan}" in
  --plan) mode="plan" ;;
  --apply) mode="apply" ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/pearl_operator_ed25519}"
VPS_HOST="${VPS_HOST:-159.223.165.194}"
VPS_USER="${VPS_USER:-root}"
SSH_PORT="${SSH_PORT:-22}"
SSH_KNOWN_HOSTS="${SSH_KNOWN_HOSTS:-$HOME/.ssh/known_hosts}"
REMOTE_CONFIG="${REMOTE_CONFIG:-/opt/macprovider/coordinator.yaml}"
SERVICE="${SERVICE:-macprovider-coordinator}"
COORDINATOR_ORIGIN="${COORDINATOR_ORIGIN:-https://coordinator.malibu.tech}"
GATEWAY_ORIGIN="${GATEWAY_ORIGIN:-https://api.malibu.tech}"
VERIFY_SCRIPT="${VERIFY_SCRIPT:-$SCRIPT_DIR/verify-tier2-live.sh}"
LOCAL_UPDATER="${LOCAL_UPDATER:-$SCRIPT_DIR/../ops/pearl-updater/macprovider-pearl-update}"
LOCAL_WATCHDOG="${LOCAL_WATCHDOG:-$SCRIPT_DIR/../ops/pearl-updater/macprovider-tier2-enforcement-watchdog}"
LOCAL_GATE="${LOCAL_GATE:-$SCRIPT_DIR/../ops/pearl-updater/macprovider-pearl-update-gate}"
LOCAL_RECONCILE_UNIT="${LOCAL_RECONCILE_UNIT:-$SCRIPT_DIR/../ops/pearl-updater/macprovider-tier2-enforcement-reconcile.service}"
LOCAL_GATE_DROPIN="${LOCAL_GATE_DROPIN:-$SCRIPT_DIR/../ops/pearl-updater/macprovider-pearl-updater-transaction-gate.conf}"
REMOTE_UPDATER="${REMOTE_UPDATER:-/usr/local/sbin/macprovider-pearl-update}"
REMOTE_WATCHDOG="${REMOTE_WATCHDOG:-/usr/local/sbin/macprovider-tier2-enforcement-watchdog}"
REMOTE_GATE="${REMOTE_GATE:-/usr/local/sbin/macprovider-pearl-update-gate}"
REMOTE_RECONCILE_UNIT="${REMOTE_RECONCILE_UNIT:-/etc/systemd/system/macprovider-tier2-enforcement-reconcile.service}"
SSH_BIN="${SSH_BIN:-ssh}"

PINNED_VERIFY_SCRIPT="$SCRIPT_DIR/verify-tier2-live.sh"
PINNED_LOCAL_UPDATER="$SCRIPT_DIR/../ops/pearl-updater/macprovider-pearl-update"
PINNED_LOCAL_WATCHDOG="$SCRIPT_DIR/../ops/pearl-updater/macprovider-tier2-enforcement-watchdog"
PINNED_LOCAL_GATE="$SCRIPT_DIR/../ops/pearl-updater/macprovider-pearl-update-gate"
PINNED_LOCAL_RECONCILE_UNIT="$SCRIPT_DIR/../ops/pearl-updater/macprovider-tier2-enforcement-reconcile.service"
PINNED_LOCAL_GATE_DROPIN="$SCRIPT_DIR/../ops/pearl-updater/macprovider-pearl-updater-transaction-gate.conf"
PINNED_REMOTE_UPDATER="/usr/local/sbin/macprovider-pearl-update"
PINNED_REMOTE_WATCHDOG="/usr/local/sbin/macprovider-tier2-enforcement-watchdog"
PINNED_REMOTE_GATE="/usr/local/sbin/macprovider-pearl-update-gate"
PINNED_REMOTE_RECONCILE_UNIT="/etc/systemd/system/macprovider-tier2-enforcement-reconcile.service"
TRANSACTION_RE='^[0-9a-f]{64}$'

SSH=()
active_transaction=""

log() { printf '[tier2-enforce] %s\n' "$*" >&2; }
die() { printf '[tier2-enforce] ERROR: %s\n' "$*" >&2; exit 1; }
shell_quote() { printf "%q" "$1"; }

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

require_file() {
  local path="$1"
  [ -f "$path" ] || die "missing file: $path"
}

require_trusted_local_file() {
  local path="$1"
  python3 - "$path" <<'PY'
import os
import stat
import sys

path = sys.argv[1]
st = os.lstat(path)
if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_nlink != 1:
    raise SystemExit(f"untrusted local file identity: {path}")
if stat.S_IMODE(st.st_mode) & 0o022:
    raise SystemExit(f"group/other-writable local file: {path}")
PY
}

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

print_plan() {
  cat <<PLAN
Plan only. No production state was changed.

Would:
1. Prove the complete physical cohort is enforcement-ready.
2. Prove three signed-release buyer-serving cycles with enforcement false.
3. Arm a durable remote journal plus 15-minute systemd rollback watchdog.
4. Atomically change only tier2.require_hash_verified: false -> true and SIGHUP.
5. Require fresh reload evidence and the enforced complete-cohort verifier.
6. Prove three signed-release buyer-serving cycles under enforcement.
7. Reject hash/catalog stop-condition journal events.
8. Recheck the release-bound, bridge-free, hard-disabled-canary posture.
9. Commit the remote transaction; otherwise rollback occurs immediately or by watchdog.

Pinned verifier: $PINNED_VERIFY_SCRIPT
Pinned updater: $PINNED_REMOTE_UPDATER
Pinned watchdog: $PINNED_REMOTE_WATCHDOG
Pinned boot reconciler: $PINNED_REMOTE_RECONCILE_UNIT
Pinned service-start gate: $PINNED_REMOTE_GATE

To apply:
  PROOF_TAG=v1.8.60 DEMO_TOKEN=<token> OPERATOR_KEY=<operator-key> scripts/enforce-tier2-hash.sh --apply
PLAN
}

validate_verifier_output() {
  local requested="$1"
  local raw="$2"
  python3 - "$requested" "$raw" <<'PY'
import json
import sys

requested = sys.argv[1].removeprefix("--")
payload = json.loads(sys.argv[2])
if not isinstance(payload, dict) or payload.get("mode") != requested:
    raise SystemExit("verifier output does not bind the requested mode")
if payload.get("require_verified") is not (requested == "enforced"):
    raise SystemExit("verifier output does not bind the expected enforcement state")
if int(payload.get("snapshot_manifest_provider_count", 0)) <= 0:
    raise SystemExit("verifier output does not bind a non-empty physical cohort")
PY
}

run_verifier() {
  local requested="$1"
  local output
  output="$(DEMO_TOKEN="$DEMO_TOKEN" \
    OPERATOR_KEY="$OPERATOR_KEY" \
    GATEWAY_ORIGIN="$GATEWAY_ORIGIN" \
    COORDINATOR_ORIGIN="$COORDINATOR_ORIGIN" \
    "$VERIFY_SCRIPT" "$requested")"
  printf '%s\n' "$output"
  validate_verifier_output "$requested" "$output"
}

validate_remote_proof_output() {
  local proof_mode="$1"
  local raw="$2"
  local action count_key
  case "$proof_mode" in
    --prove-current)
      action="prove_current"
      count_key="single_authority_buyer_serving_cycles"
      ;;
    --prove-hash-enforced)
      action="prove_hash_enforced"
      count_key="hash_enforced_buyer_serving_cycles"
      ;;
    *)
      die "unsupported proof mode: $proof_mode"
      ;;
  esac
  python3 - "$action" "$count_key" "$PROOF_TAG" "$raw" <<'PY'
import json
import sys

action, count_key, tag, raw = sys.argv[1:5]
payload = json.loads(raw)
if not isinstance(payload, dict) or payload.get("action") != action:
    raise SystemExit("remote proof output does not bind the requested action")
if payload.get("candidate") != tag or payload.get(count_key) != 3:
    raise SystemExit("remote proof output does not bind the exact tag and three cycles")
if payload.get("tier2_catalog_path") != "/opt/macprovider/autotune/current/tier2-catalog.json":
    raise SystemExit("remote proof output does not bind the single Tier-2 authority")
PY
}

run_remote_proof() {
  local proof_mode="$1"
  local output
  output="$("${SSH[@]}" \
    "$(shell_quote "$REMOTE_UPDATER") $(shell_quote "$proof_mode") --tag $(shell_quote "$PROOF_TAG")")"
  printf '%s\n' "$output"
  validate_remote_proof_output "$proof_mode" "$output"
}

run_remote_watchdog() {
  local action="$1"
  local transaction_id="${2:-}"
  local command
  command="$(shell_quote "$REMOTE_WATCHDOG") $(shell_quote "$action")"
  if [ -n "$transaction_id" ]; then
    command+=" --transaction-id $(shell_quote "$transaction_id")"
  fi
  "${SSH[@]}" "$command"
}

validate_watchdog_output() {
  local expected_action="$1"
  local raw="$2"
  local expected_transaction="${3:-}"
  python3 - "$expected_action" "$expected_transaction" "$raw" <<'PY'
import json
import re
import sys

action, expected_transaction, raw = sys.argv[1:4]
payload = json.loads(raw)
if not isinstance(payload, dict) or payload.get("action") != action:
    raise SystemExit("watchdog output does not bind the requested action")
transaction = payload.get("transaction_id")
if not isinstance(transaction, str) or re.fullmatch(r"[0-9a-f]{64}", transaction) is None:
    raise SystemExit("watchdog output has an invalid transaction identity")
if expected_transaction and transaction != expected_transaction:
    raise SystemExit("watchdog transaction identity changed")
for key in ("previous_config_sha256", "enforced_config_sha256"):
    if not isinstance(payload.get(key), str) or re.fullmatch(r"[0-9a-f]{64}", payload[key]) is None:
        raise SystemExit("watchdog output has an invalid config digest")
release = payload.get("release_pointer")
if not isinstance(release, str) or not release.startswith("/opt/macprovider/autotune/releases/"):
    raise SystemExit("watchdog output has an invalid release pointer")
print(transaction)
PY
}

remote_posture() {
  local expected_enforcement="$1"
  local expected_transaction="${2:-absent}"
  local q_remote_config q_service q_transaction
  q_remote_config="$(shell_quote "$REMOTE_CONFIG")"
  q_service="$(shell_quote "$SERVICE")"
  q_transaction="$(shell_quote "$expected_transaction")"
  "${SSH[@]}" "set -euo pipefail
    test -f $q_remote_config
    test ! -L $q_remote_config
    test \"\$(stat -c '%U' $q_remote_config)\" = root
    test -z \"\$(find $q_remote_config -maxdepth 0 -perm /022 -print -quit)\"
    test \"\$(grep -Ec '^[[:space:]]{2}require_hash_verified:[[:space:]]*$expected_enforcement([[:space:]]|$)' $q_remote_config)\" = 1
    grep -Eq '^[[:space:]]{2}catalog_path:[[:space:]]*/opt/macprovider/autotune/current/tier2-catalog.json([[:space:]]|$)' $q_remote_config
    ! grep -Eq '^[[:space:]]*model_hash_legacy_until:' $q_remote_config /etc/macprovider/coordinator.pearl-overlays.yaml
    test ! -e /opt/macprovider/tier2-catalog.json
    test -f /opt/macprovider/autotune/current/tier2-catalog.json
    grep -Eq '^[[:space:]]*canary_enabled:[[:space:]]*false([[:space:]]|$)' /etc/macprovider/coordinator.pearl-overlays.yaml
    test ! -e /etc/macprovider-canary-buyer/enabled
    test ! -e /etc/macprovider/canary-buyer.enabled
    test -f /var/lib/macprovider-canary-buyer/DISABLED
    test ! -s /var/lib/macprovider-canary-buyer/DISABLED
    test \"\$(stat -c '%U:%G:%a' /var/lib/macprovider-canary-buyer/DISABLED)\" = root:root:644
    test \"\$(systemctl is-enabled canary-buyer.timer 2>/dev/null || true)\" = disabled
    test \"\$(systemctl is-active canary-buyer.timer 2>/dev/null || true)\" = inactive
    test \"\$(systemctl is-active canary-buyer.service 2>/dev/null || true)\" = inactive
    test \"\$(systemctl is-active $q_service)\" = active
    test \"\$(systemctl is-active macprovider-gateway.service)\" = active
    test ! -e /opt/macprovider/.coordinator-deploy-rollback
    test ! -e /var/lib/macprovider-pearl-updater/active-transaction.json
    if [ $q_transaction = active ]; then
      test -f /var/lib/macprovider-pearl-updater/tier2-enforcement-transaction.json
      test \"\$(systemctl is-active macprovider-tier2-enforcement-watchdog.timer)\" = active
    else
      test ! -e /var/lib/macprovider-pearl-updater/tier2-enforcement-transaction.json
    fi
    ! systemctl show -p Environment --value $q_service | grep -Eq '(^|[[:space:]])MODEL_HASH_LEGACY_UNTIL='
    pid=\$(systemctl show -p MainPID --value $q_service)
    test \"\$pid\" -gt 0
    ! tr '\\0' '\\n' < \"/proc/\$pid/environ\" | grep -Eq '^MODEL_HASH_LEGACY_UNTIL='
    printf 'remote_posture=ok enforcement=$expected_enforcement transaction=$expected_transaction\\n'
  "
}

verify_reload_journal() {
  local since="$1"
  "${SSH[@]}" "journalctl -u $(shell_quote "$SERVICE") --since $(shell_quote "$since") --no-pager \
    | grep -E 'tier2 config reloaded'"
}

verify_stop_condition_journal() {
  local since="$1"
  local journal_output
  if ! journal_output="$("${SSH[@]}" \
    "journalctl -u $(shell_quote "$SERVICE") --since $(shell_quote "$since") --no-pager")"; then
    log "could not read the coordinator journal for stop-condition evidence"
    return 1
  fi
  if printf '%s\n' "$journal_output" \
    | grep -Ei '\"event\":\"(model_hash_(algorithm_legacy_bridge|mismatch|uncatalogued|invalid)|hash_required_provider_excluded)\"|\"reason\":\"catalog_unavailable\"|catalog.*identity.*conflict|catalogbind.*(fail|error)'; then
    return 1
  fi
}

rollback_config() {
  local transaction_id="$1"
  local rollback_since output restored_transaction
  rollback_since="$("${SSH[@]}" "date --iso-8601=seconds")"
  [ -n "$rollback_since" ] || return 1
  output="$(run_remote_watchdog --rollback "$transaction_id")" || return 1
  printf '%s\n' "$output"
  restored_transaction="$(validate_watchdog_output rolled_back "$output" "$transaction_id")" || return 1
  [ "$restored_transaction" = "$transaction_id" ] || return 1
  active_transaction=""
  verify_reload_journal "$rollback_since" || return 1
  remote_posture false absent || return 1
  run_verifier --enforce-ready || return 1
}

rollback_and_exit() {
  local reason="$1"
  local transaction_id="$2"
  log "$reason"
  if ! rollback_config "$transaction_id"; then
    die "automatic rollback failed; the durable remote watchdog remains authoritative"
  fi
  exit 1
}

cleanup_active_transaction() {
  local original_status=$?
  trap - EXIT HUP INT TERM
  if [ -n "$active_transaction" ]; then
    log "controller exit detected; requesting immediate durable rollback"
    rollback_config "$active_transaction" || log "immediate rollback failed; remote watchdog remains armed"
  fi
  exit "$original_status"
}

recover_failed_arm() {
  local output recovered_transaction
  log "watchdog arm failed; requesting immediate remote reconciliation"
  if output="$(run_remote_watchdog --reconcile)"; then
    printf '%s\n' "$output"
    recovered_transaction="$(validate_watchdog_output reconciled "$output")" || return 1
    [[ "$recovered_transaction" =~ $TRANSACTION_RE ]] || return 1
  fi
  remote_posture false absent || return 1
  run_verifier --enforce-ready || return 1
}

recover_failed_commit() {
  local transaction_id="$1"
  local output recovered_transaction
  log "watchdog commit response failed; reconciling its durable terminal state"
  output="$(run_remote_watchdog --reconcile)" || return 1
  printf '%s\n' "$output"
  if recovered_transaction="$(
    validate_watchdog_output committed "$output" "$transaction_id"
  )"; then
    [ "$recovered_transaction" = "$transaction_id" ] || return 1
    remote_posture true absent || return 1
    run_verifier --enforced || return 1
    return 0
  fi
  recovered_transaction="$(
    validate_watchdog_output reconciled "$output" "$transaction_id"
  )" || return 1
  [ "$recovered_transaction" = "$transaction_id" ] || return 1
  remote_posture false absent || return 1
  run_verifier --enforce-ready || return 1
  return 2
}

apply_changes() {
  require_command "$SSH_BIN"
  require_command python3
  require_command shasum
  require_file "$SSH_KEY"
  require_file "$SSH_KNOWN_HOSTS"
  require_file "$VERIFY_SCRIPT"
  require_file "$LOCAL_UPDATER"
  require_file "$LOCAL_WATCHDOG"
  require_file "$LOCAL_GATE"
  require_file "$LOCAL_RECONCILE_UNIT"
  require_file "$LOCAL_GATE_DROPIN"
  require_trusted_local_file "$SSH_KEY"
  require_trusted_local_file "$SSH_KNOWN_HOSTS"
  require_trusted_local_file "$VERIFY_SCRIPT"
  require_trusted_local_file "$LOCAL_UPDATER"
  require_trusted_local_file "$LOCAL_WATCHDOG"
  require_trusted_local_file "$LOCAL_GATE"
  require_trusted_local_file "$LOCAL_RECONCILE_UNIT"
  require_trusted_local_file "$LOCAL_GATE_DROPIN"
  [ "$VERIFY_SCRIPT" = "$PINNED_VERIFY_SCRIPT" ] || die "VERIFY_SCRIPT is pinned by --apply"
  [ "$LOCAL_UPDATER" = "$PINNED_LOCAL_UPDATER" ] || die "LOCAL_UPDATER is pinned by --apply"
  [ "$LOCAL_WATCHDOG" = "$PINNED_LOCAL_WATCHDOG" ] || die "LOCAL_WATCHDOG is pinned by --apply"
  [ "$LOCAL_GATE" = "$PINNED_LOCAL_GATE" ] || die "LOCAL_GATE is pinned by --apply"
  [ "$LOCAL_RECONCILE_UNIT" = "$PINNED_LOCAL_RECONCILE_UNIT" ] || die "LOCAL_RECONCILE_UNIT is pinned by --apply"
  [ "$LOCAL_GATE_DROPIN" = "$PINNED_LOCAL_GATE_DROPIN" ] || die "LOCAL_GATE_DROPIN is pinned by --apply"
  [ "$REMOTE_UPDATER" = "$PINNED_REMOTE_UPDATER" ] || die "REMOTE_UPDATER is pinned by --apply"
  [ "$REMOTE_WATCHDOG" = "$PINNED_REMOTE_WATCHDOG" ] || die "REMOTE_WATCHDOG is pinned by --apply"
  [ "$REMOTE_GATE" = "$PINNED_REMOTE_GATE" ] || die "REMOTE_GATE is pinned by --apply"
  [ "$REMOTE_RECONCILE_UNIT" = "$PINNED_REMOTE_RECONCILE_UNIT" ] || die "REMOTE_RECONCILE_UNIT is pinned by --apply"
  [ -n "${DEMO_TOKEN:-}" ] || die "DEMO_TOKEN is required by --apply"
  [ -n "${OPERATOR_KEY:-}" ] || die "OPERATOR_KEY is required by --apply"
  [ -n "${PROOF_TAG:-}" ] || die "PROOF_TAG is required by --apply"
  [ "$PROOF_TAG" = "v1.8.60" ] || die "PROOF_TAG must be the sealed Pearl coordinator tag v1.8.60"
  [ -z "${VERIFY_TIER2_FIXTURES:-}" ] || die "VERIFY_TIER2_FIXTURES is forbidden by --apply"
  [ "$COORDINATOR_ORIGIN" = "https://coordinator.malibu.tech" ] || die "COORDINATOR_ORIGIN is pinned in production apply"
  [ "$GATEWAY_ORIGIN" = "https://api.malibu.tech" ] || die "GATEWAY_ORIGIN is pinned in production apply"

  SSH=(
    "$SSH_BIN"
    -i "$SSH_KEY"
    -o BatchMode=yes
    -o IdentitiesOnly=yes
    -o StrictHostKeyChecking=yes
    -o "UserKnownHostsFile=$SSH_KNOWN_HOSTS"
    -o GlobalKnownHostsFile=/dev/null
    -F /dev/null
    -o ConnectTimeout=10
    -p "$SSH_PORT"
    "$VPS_USER@$VPS_HOST"
  )

  local updater_sha watchdog_sha gate_sha reconcile_sha gate_dropin_sha
  updater_sha="$(sha256_file "$LOCAL_UPDATER")"
  watchdog_sha="$(sha256_file "$LOCAL_WATCHDOG")"
  gate_sha="$(sha256_file "$LOCAL_GATE")"
  reconcile_sha="$(sha256_file "$LOCAL_RECONCILE_UNIT")"
  gate_dropin_sha="$(sha256_file "$LOCAL_GATE_DROPIN")"
  "${SSH[@]}" "set -euo pipefail
    test -f $(shell_quote "$REMOTE_UPDATER")
    test ! -L $(shell_quote "$REMOTE_UPDATER")
    test \"\$(stat -c '%U' $(shell_quote "$REMOTE_UPDATER"))\" = root
    test -z \"\$(find $(shell_quote "$REMOTE_UPDATER") -maxdepth 0 -perm /022 -print -quit)\"
    test \"\$(sha256sum $(shell_quote "$REMOTE_UPDATER") | awk '{print \$1}')\" = $(shell_quote "$updater_sha")
    test -x $(shell_quote "$REMOTE_WATCHDOG")
    test ! -L $(shell_quote "$REMOTE_WATCHDOG")
    test \"\$(stat -c '%U:%G:%a' $(shell_quote "$REMOTE_WATCHDOG"))\" = root:root:755
    test \"\$(sha256sum $(shell_quote "$REMOTE_WATCHDOG") | awk '{print \$1}')\" = $(shell_quote "$watchdog_sha")
    test -x $(shell_quote "$REMOTE_GATE")
    test ! -L $(shell_quote "$REMOTE_GATE")
    test \"\$(stat -c '%U:%G:%a' $(shell_quote "$REMOTE_GATE"))\" = root:root:755
    test \"\$(sha256sum $(shell_quote "$REMOTE_GATE") | awk '{print \$1}')\" = $(shell_quote "$gate_sha")
    test -f $(shell_quote "$REMOTE_RECONCILE_UNIT")
    test ! -L $(shell_quote "$REMOTE_RECONCILE_UNIT")
    test \"\$(stat -c '%U:%G:%a' $(shell_quote "$REMOTE_RECONCILE_UNIT"))\" = root:root:644
    test \"\$(sha256sum $(shell_quote "$REMOTE_RECONCILE_UNIT") | awk '{print \$1}')\" = $(shell_quote "$reconcile_sha")
    systemctl is-enabled --quiet macprovider-tier2-enforcement-reconcile.service
    test \"\$(systemctl show -p LoadState --value macprovider-tier2-enforcement-reconcile.service)\" = loaded
    test \"\$(systemctl show -p UnitFileState --value macprovider-tier2-enforcement-reconcile.service)\" = enabled
    test \"\$(systemctl show -p FragmentPath --value macprovider-tier2-enforcement-reconcile.service)\" = $(shell_quote "$REMOTE_RECONCILE_UNIT")
    test -z \"\$(systemctl show -p DropInPaths --value macprovider-tier2-enforcement-reconcile.service)\"
    test \"\$(systemctl show -p NeedDaemonReload --value macprovider-tier2-enforcement-reconcile.service)\" = no
    reconcile_exec=\"\$(systemctl show -p ExecStart --value macprovider-tier2-enforcement-reconcile.service)\"
    case \"\$reconcile_exec\" in
      '{ path=/usr/local/sbin/macprovider-tier2-enforcement-watchdog ; argv[]=/usr/local/sbin/macprovider-tier2-enforcement-watchdog --reconcile ; ignore_errors=no ; '*) ;;
      *) exit 1 ;;
    esac
    test \"\$(printf '%s' \"\$reconcile_exec\" | grep -o 'path=' | wc -l)\" = 1
    for unit in macprovider-coordinator.service macprovider-gateway.service canary-buyer.service macprovider-archive-rotate.service stats-billing-mirror.service; do
      dropin=/etc/systemd/system/\$unit.d/50-pearl-updater-transaction-gate.conf
      test -f \"\$dropin\"
      test ! -L \"\$dropin\"
      test \"\$(stat -c '%U:%G:%a' \"\$dropin\")\" = root:root:644
      test \"\$(sha256sum \"\$dropin\" | awk '{print \$1}')\" = $(shell_quote "$gate_dropin_sha")
      test \"\$(systemctl show -p LoadState --value \"\$unit\")\" = loaded
      test \"\$(systemctl show -p NeedDaemonReload --value \"\$unit\")\" = no
      gate_exec=\"\$(systemctl show -p ExecStartPre --value \"\$unit\")\"
      case \"\$gate_exec\" in
        \"{ path=/usr/local/sbin/macprovider-pearl-update-gate ; argv[]=/usr/local/sbin/macprovider-pearl-update-gate \$unit ; ignore_errors=no ; \"*) ;;
        *) exit 1 ;;
      esac
      test \"\$(printf '%s' \"\$gate_exec\" | grep -o 'path=' | wc -l)\" = 1
    done
  "

  log "checking release-bound, bridge-free, hard-disabled remote posture"
  remote_posture false absent
  log "running strict enforcement-readiness verifier"
  run_verifier --enforce-ready
  log "proving three pre-enforcement buyer-serving cycles"
  run_remote_proof --prove-current

  local mutation_since arm_output armed_transaction
  mutation_since="$("${SSH[@]}" "date --iso-8601=seconds")"
  [ -n "$mutation_since" ] || die "could not capture the remote mutation timestamp"
  log "arming durable remote rollback and applying the enforcement flip"
  if ! arm_output="$(run_remote_watchdog --arm)"; then
    if recover_failed_arm; then
      die "watchdog arm failed; immediate recovery re-proved enforcement=false"
    fi
    die "watchdog arm failed and immediate recovery could not be proven; the durable remote watchdog may remain armed"
  fi
  printf '%s\n' "$arm_output"
  armed_transaction="$(validate_watchdog_output armed "$arm_output")"
  [[ "$armed_transaction" =~ $TRANSACTION_RE ]] || die "watchdog did not return a valid transaction"
  active_transaction="$armed_transaction"
  trap cleanup_active_transaction EXIT HUP INT TERM

  log "checking reload journal evidence"
  verify_reload_journal "$mutation_since" ||
    rollback_and_exit "missing recent Tier-2 reload evidence" "$active_transaction"
  log "running enforced complete-cohort verifier"
  run_verifier --enforced ||
    rollback_and_exit "enforced verifier failed" "$active_transaction"
  log "proving three hash-enforced buyer-serving cycles"
  run_remote_proof --prove-hash-enforced ||
    rollback_and_exit "hash-enforced buyer journey proof failed" "$active_transaction"
  log "checking stop-condition journal evidence"
  verify_stop_condition_journal "$mutation_since" ||
    rollback_and_exit "hash/catalog stop-condition event detected" "$active_transaction"
  log "rechecking enforced posture with rollback watchdog armed"
  remote_posture true active ||
    rollback_and_exit "post-enforcement remote posture check failed" "$active_transaction"

  local commit_output committed_transaction
  if ! commit_output="$(run_remote_watchdog --commit "$active_transaction")"; then
    set +e
    recover_failed_commit "$active_transaction"
    recovery_status=$?
    set -e
    if [ "$recovery_status" -eq 0 ]; then
      active_transaction=""
      trap - EXIT HUP INT TERM
      log "Tier-2 hash enforcement was already committed; terminal cleanup was reconciled and re-proved"
      return
    fi
    if [ "$recovery_status" -eq 2 ]; then
      active_transaction=""
      trap - EXIT HUP INT TERM
      die "commit failed and the durable transaction reconciled to enforcement=false"
    fi
    die "commit failed and its durable terminal state could not be proven"
  fi
  printf '%s\n' "$commit_output"
  committed_transaction="$(validate_watchdog_output committed "$commit_output" "$active_transaction")" ||
    die "committed watchdog output was invalid"
  [ "$committed_transaction" = "$active_transaction" ] ||
    die "committed watchdog transaction identity changed"
  active_transaction=""
  trap - EXIT HUP INT TERM
  log "Tier-2 hash enforcement verified and durably committed"
}

if [ "$mode" = "plan" ]; then
  print_plan
else
  apply_changes
fi
