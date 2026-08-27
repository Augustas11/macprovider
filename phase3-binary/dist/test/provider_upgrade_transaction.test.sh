#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
INSTALL_SH="$REPO_ROOT/phase3-binary/dist/install.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

extract_function() {
  name="$1"
  if [ "$name" = "semantic_merge_config" ]; then
    sed -n '/^semantic_merge_config()/,/^write_config()/p' "$INSTALL_SH" | sed '$d'
    return
  fi
  awk -v start="${name}() {" '
    $0 == start { inside=1 }
    inside { print }
    inside && /^}$/ { exit }
  ' "$INSTALL_SH"
}

for function_name in \
  validate_install_dir validate_port_value \
  release_install_lock acquire_install_lock \
  validate_repair_privilege_domain \
  read_config_provider_id read_config_provider_token_line \
  installed_provider_binary_path restart_safe_incumbent_present \
  repair_safe_incumbent_present prepare_fresh_referral_code \
  quiesce_repair_watchdog_label_for_transaction quiesce_repair_watchdogs_for_transaction \
  remediate_repair_home_write_acl \
  repair_autoupdate_recovery_preflight autoupdate_recovery_supported autoupdate_recovery_tick \
  prepare_staged_config activate_staged_config select_autotune_benchmark_port \
  semantic_merge_config restore_existing_provider_if_start_skipped \
  prefetch_upgrade_autotune_model own_macprovider_cli_holds_live_port \
  validate_staged_entries; do
  extract_function "$function_name" >> "$TMP/helpers.sh"
done

# shellcheck source=/dev/null
source "$TMP/helpers.sh" || exit 1

arm_transaction_recovery_agent() { :; }

if grep -Fq 'model="$(choose_model "$ram_gb")"' "$INSTALL_SH"; then
  echo "installer still selects a model from mutable RAM tables before verified autotune" >&2
  exit 1
fi
if grep -Fq 'check_catalog_ram_metadata "$coordinator_base" "$model"' "$INSTALL_SH"; then
  echo "installer still queries the legacy unsigned catalog selection surface" >&2
  exit 1
fi
python3 - "$INSTALL_SH" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
main = source[source.rindex("\nmain() {"):]
validate_dir = main.index("validate_install_dir")
repair_home_acl = main.index("remediate_repair_home_write_acl")
repair_recovery = main.index("repair_autoupdate_recovery_preflight")
acquire_lock = main.index("acquire_install_lock")
snapshot = main.index("begin_install_transaction")
stage = main.index("stage_release_payload", snapshot)
prepare = main.index("prepare_staged_config", stage)
freshness = main.index("use_fresh_recommendation_if_available", stage)
recommend_gate = main.index('if [ "$AUTOTUNE_RECOMMENDATION_REQUIRED" -eq 1 ]', freshness)
prefetch = main.index("prefetch_upgrade_autotune_model", freshness)
cutover_marker = main.index("mark_install_cutover_started", recommend_gate)
stop = main.index("ensure_port_free 1", recommend_gate)
recommend = main.index("run_autotune_recommend_apply", stop)
install = main.index("install_binary", recommend)
activate = main.index("activate_staged_config", install)
if not validate_dir < repair_home_acl < repair_recovery < acquire_lock < snapshot < stage < prepare < freshness < prefetch < recommend_gate < cutover_marker < stop < recommend < install < activate:
    raise SystemExit("benchmarks are not isolated from the live provider and staged cutover")
transaction = source[source.index("begin_install_transaction() {"):source.index("mark_install_cutover_started() {")]
strict = transaction.index("quiesce_repair_watchdog_label_for_transaction")
generic = transaction.index("reclaim_launchd_service")
if not strict < generic:
    raise SystemExit("repair watchdog shutdown must use strict liveness proof before generic reclaim")
helper = source[source.index("run_macprovider_cli_with_amfi_retry() {"):source.index("detect_existing_port() {")]
if 'local cli_path="$MACPROVIDER_CLI_EXECUTABLE"' not in helper:
    raise SystemExit("recommendation helper is not routed to the staged CLI")
recommend_helper = source[source.index("run_autotune_recommend_apply() {"):source.index("use_fresh_recommendation_if_available() {")]
if '--port "${AUTOTUNE_BENCHMARK_PORT:-19080}" --config "$CONFIG_PATH"' not in recommend_helper:
    raise SystemExit("recommendation benchmarks do not use a reserved non-live port")
if "stage_bundled_repair_payload" not in source:
    raise SystemExit("existing-install repair must stage the Malibu.app bundled CLI")
if "existing-install repair requires MACPROVIDER_BUNDLED_APP from Malibu.app" not in main:
    raise SystemExit("repair without MACPROVIDER_BUNDLED_APP must fail closed")
if "validate_repair_privilege_domain" not in main or "Malibu.app repair supports user-domain LaunchAgents only" not in source:
    raise SystemExit("system-domain repair behavior must be explicit")
coordinator_repair = main.index("Coordinator did not admit the repaired provider yet")
coordinator_commit = main.index("commit_install_transaction", coordinator_repair)
repair_branch = main[coordinator_repair:main.index('elif [ "$EMERGENCY_ROLLBACK" = "1" ]', coordinator_repair)]
if "exit 6" in repair_branch or coordinator_commit <= coordinator_repair:
    raise SystemExit("repair coordinator miss must commit local repair instead of rolling back")
PY

die() {
  exit "$1"
}

HOME="$TMP/home"
mkdir -m 700 "$HOME"
INSTALL_DIR="$HOME/macprovider"
validate_install_dir
[ "$INSTALL_DIR" = "$HOME/macprovider" ] || {
  echo "safe install path was not preserved" >&2
  exit 1
}
for unsafe in / "$HOME" "$HOME/../escape"; do
  if (INSTALL_DIR="$unsafe"; validate_install_dir); then
    echo "unsafe install path unexpectedly passed: $unsafe" >&2
    exit 1
  fi
done
mkdir -m 700 "$HOME/real"
ln -s "$HOME/real" "$HOME/link"
if (INSTALL_DIR="$HOME/link/provider"; validate_install_dir); then
  echo "symlinked install path unexpectedly passed" >&2
  exit 1
fi
mkdir -m 700 "$HOME/custom"
if ! (INSTALL_DIR="$HOME/custom/bin"; validate_install_dir); then
  echo "owner-private custom install path unexpectedly failed" >&2
  exit 1
fi
mkdir -m 777 "$HOME/shared"
chmod 777 "$HOME/shared"
if (INSTALL_DIR="$HOME/shared/provider"; validate_install_dir); then
  echo "world-writable install ancestor unexpectedly passed" >&2
  exit 1
fi

# Malibu repair must be able to recover the exact #941 state where the old
# provider executable is gone but owner-private identity/configuration and
# launchd evidence remain. The evidence gate must suppress referral admission
# only for that validated state, and must fail closed when the manifest is
# missing.
REPAIR_HOME="$TMP/repair-home"
mkdir -m 700 -p \
  "$REPAIR_HOME/.config/macprovider" \
  "$REPAIR_HOME/Library/Application Support/macprovider" \
  "$REPAIR_HOME/Library/LaunchAgents"
REPAIR_INSTALL_DIR="$REPAIR_HOME/macprovider"
REPAIR_CONFIG_PATH="$REPAIR_HOME/.config/macprovider/config.yaml"
REPAIR_PROVIDER_ID_PATH="$REPAIR_HOME/.config/macprovider/provider_id"
REPAIR_MANIFEST_PATH="$REPAIR_HOME/Library/Application Support/macprovider/install_manifest.json"
REPAIR_PLIST_PATH="$REPAIR_HOME/Library/LaunchAgents/live.malibu.provider.plist"
REPAIR_BINARY_PATH="$REPAIR_HOME/.local/bin/macprovider-cli"
REPAIR_PROVIDER_ID="mp-0123456789abcdef0123456789abcdef"
cat > "$REPAIR_CONFIG_PATH" <<EOF
model: "seed"
provider_id: "$REPAIR_PROVIDER_ID"
coordinator_url: "wss://coordinator.example/ws/provider"
EOF
printf '%s\n' "$REPAIR_PROVIDER_ID" > "$REPAIR_PROVIDER_ID_PATH"
cat > "$REPAIR_MANIFEST_PATH" <<EOF
{
  "install_prefix": "$REPAIR_INSTALL_DIR",
  "binary_path": "$REPAIR_INSTALL_DIR/macprovider-cli",
  "launchd_labels": ["live.malibu.provider"],
  "launchd_plists": ["$REPAIR_PLIST_PATH"]
}
EOF
cat > "$REPAIR_PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>live.malibu.provider</string>
<key>Program</key><string>$REPAIR_INSTALL_DIR/macprovider-cli</string>
</dict></plist>
EOF
chmod 600 "$REPAIR_CONFIG_PATH" "$REPAIR_PROVIDER_ID_PATH" "$REPAIR_MANIFEST_PATH" "$REPAIR_PLIST_PATH"
# Legacy standalone installers commonly left LaunchAgent plists owner-writable
# but group/world-readable under umask 022. Repair admission rejects writes and
# ACLs, not harmless read bits, so Malibu's accepted evidence can be reclaimed.
chmod 644 "$REPAIR_PLIST_PATH"
if chmod +a "group:everyone allow add_file,add_subdirectory" "$REPAIR_HOME" 2>/dev/null; then
  (
    HOME="$REPAIR_HOME"
    INSTALL_DIR="$REPAIR_INSTALL_DIR"
    REPAIR_EXISTING_INSTALL=1
    die() { exit "$1"; }
    validate_install_dir
  ) || {
    echo "repair validate_install_dir rejected the HOME write ACL it must remediate" >&2
    chmod -a "group:everyone allow add_file,add_subdirectory" "$REPAIR_HOME" 2>/dev/null || true
    exit 1
  }
  if (
    HOME="$REPAIR_HOME"
    INSTALL_DIR="$REPAIR_INSTALL_DIR"
    REPAIR_EXISTING_INSTALL=0
    die() { exit "$1"; }
    validate_install_dir
  ); then
    echo "normal validate_install_dir accepted repair-only HOME write ACL tolerance" >&2
    chmod -a "group:everyone allow add_file,add_subdirectory" "$REPAIR_HOME" 2>/dev/null || true
    exit 1
  fi
  chmod -a "group:everyone allow add_file,add_subdirectory" "$REPAIR_HOME" 2>/dev/null || true
fi
if chmod +a "group:everyone deny delete" "$REPAIR_HOME" 2>/dev/null; then
  if chmod +a "group:everyone allow add_file,add_subdirectory" "$REPAIR_HOME" 2>/dev/null; then
    (
      HOME="$REPAIR_HOME"
      INSTALL_DIR="$REPAIR_INSTALL_DIR"
      REPAIR_EXISTING_INSTALL=1
      log() { :; }
      die() { exit "$1"; }
      validate_install_dir
      remediate_repair_home_write_acl
      REPAIR_EXISTING_INSTALL=0
      validate_install_dir
    ) || {
      chmod -a "group:everyone allow add_file,add_subdirectory" "$REPAIR_HOME" 2>/dev/null || true
      chmod -a "group:everyone deny delete" "$REPAIR_HOME" 2>/dev/null || true
      echo "repair did not remediate the HOME write ACL when a safe deny-delete ACL also existed" >&2
      exit 1
    }
    chmod -a "group:everyone allow add_file,add_subdirectory" "$REPAIR_HOME" 2>/dev/null || true
  fi
  chmod -a "group:everyone deny delete" "$REPAIR_HOME" 2>/dev/null || true
fi
if chmod +a "user:$(id -un) allow add_file" "$REPAIR_HOME" 2>/dev/null; then
  if (
    HOME="$REPAIR_HOME"
    INSTALL_DIR="$REPAIR_INSTALL_DIR"
    REPAIR_EXISTING_INSTALL=1
    die() { exit "$1"; }
    validate_install_dir
  ); then
    echo "repair validate_install_dir accepted an arbitrary HOME write ACL" >&2
    chmod -a "user:$(id -un) allow add_file" "$REPAIR_HOME" 2>/dev/null || true
    exit 1
  fi
  chmod -a "user:$(id -un) allow add_file" "$REPAIR_HOME" 2>/dev/null || true
fi
if chmod +a "group:everyone allow add_file,add_subdirectory,writeattr" "$REPAIR_HOME" 2>/dev/null; then
  if (
    HOME="$REPAIR_HOME"
    INSTALL_DIR="$REPAIR_INSTALL_DIR"
    REPAIR_EXISTING_INSTALL=1
    die() { exit "$1"; }
    validate_install_dir
  ); then
    echo "repair validate_install_dir accepted a broader-than-known HOME write ACL" >&2
    chmod -a "group:everyone allow add_file,add_subdirectory,writeattr" "$REPAIR_HOME" 2>/dev/null || true
    exit 1
  fi
  chmod -a "group:everyone allow add_file,add_subdirectory,writeattr" "$REPAIR_HOME" 2>/dev/null || true
fi
if (
  REPAIR_EXISTING_INSTALL=1
  HEADLESS=1
  LAUNCHD_DOMAIN=system
  die() { exit "$1"; }
  validate_repair_privilege_domain
); then
  echo "headless/system Malibu bundled repair did not fail closed explicitly" >&2
  exit 1
fi
(
  HOME="$REPAIR_HOME"
  INSTALL_DIR="$REPAIR_INSTALL_DIR"
  BINARY_PATH="$REPAIR_BINARY_PATH"
  CONFIG_PATH="$REPAIR_CONFIG_PATH"
  PROVIDER_ID_PATH="$REPAIR_PROVIDER_ID_PATH"
  MANIFEST_PATH="$REPAIR_MANIFEST_PATH"
  PLIST_PATH="$REPAIR_PLIST_PATH"
  PROVIDER_LABEL="live.malibu.provider"
  DRY_RUN=0
  EMERGENCY_ROLLBACK=0
  REFERRAL_REPLACE_INCUMBENT=0
  REPAIR_EXISTING_INSTALL=1
  REFERRAL_CODE_SOURCE_FILE=""
  FRESH_REFERRAL_BOOTSTRAP=0
  NO_PROMPT=1
  log() { :; }
  die() { exit "$1"; }
  prepare_fresh_referral_code
  [ -z "$REFERRAL_CODE_SOURCE_FILE" ]
  [ "$FRESH_REFERRAL_BOOTSTRAP" -eq 0 ]
)
if chmod +a "group:everyone allow add_file,add_subdirectory" "$REPAIR_HOME" 2>/dev/null; then
  (
    HOME="$REPAIR_HOME"
    INSTALL_DIR="$REPAIR_INSTALL_DIR"
    BINARY_PATH="$REPAIR_BINARY_PATH"
    CONFIG_PATH="$REPAIR_CONFIG_PATH"
    PROVIDER_ID_PATH="$REPAIR_PROVIDER_ID_PATH"
    MANIFEST_PATH="$REPAIR_MANIFEST_PATH"
    PLIST_PATH="$REPAIR_PLIST_PATH"
    PROVIDER_LABEL="live.malibu.provider"
    DRY_RUN=0
    EMERGENCY_ROLLBACK=0
    REFERRAL_REPLACE_INCUMBENT=0
    REPAIR_EXISTING_INSTALL=1
    REFERRAL_CODE_SOURCE_FILE=""
    FRESH_REFERRAL_BOOTSTRAP=0
    NO_PROMPT=1
    log() { :; }
    die() { exit "$1"; }
    prepare_fresh_referral_code
    [ -z "$REFERRAL_CODE_SOURCE_FILE" ]
    [ "$FRESH_REFERRAL_BOOTSTRAP" -eq 0 ]
  ) || {
    echo "repair rejected a write-style ACL on HOME" >&2
    chmod -a "group:everyone allow add_file,add_subdirectory" "$REPAIR_HOME" 2>/dev/null || true
    exit 1
  }
  chmod -a "group:everyone allow add_file,add_subdirectory" "$REPAIR_HOME" 2>/dev/null || true
fi
chmod 664 "$REPAIR_PLIST_PATH"
if (
  HOME="$REPAIR_HOME"
  INSTALL_DIR="$REPAIR_INSTALL_DIR"
  BINARY_PATH="$REPAIR_BINARY_PATH"
  CONFIG_PATH="$REPAIR_CONFIG_PATH"
  PROVIDER_ID_PATH="$REPAIR_PROVIDER_ID_PATH"
  MANIFEST_PATH="$REPAIR_MANIFEST_PATH"
  PLIST_PATH="$REPAIR_PLIST_PATH"
  PROVIDER_LABEL="live.malibu.provider"
  DRY_RUN=0
  EMERGENCY_ROLLBACK=0
  REFERRAL_REPLACE_INCUMBENT=0
  REPAIR_EXISTING_INSTALL=1
  REFERRAL_CODE_SOURCE_FILE=""
  FRESH_REFERRAL_BOOTSTRAP=0
  NO_PROMPT=1
  log() { :; }
  die() { exit "$1"; }
  prepare_fresh_referral_code
); then
  echo "repair accepted a writable LaunchAgent plist" >&2
  exit 1
fi
chmod 644 "$REPAIR_PLIST_PATH"
rm -f "$REPAIR_MANIFEST_PATH"
repair_missing_rc=0
(
  HOME="$REPAIR_HOME"
  INSTALL_DIR="$REPAIR_INSTALL_DIR"
  BINARY_PATH="$REPAIR_BINARY_PATH"
  CONFIG_PATH="$REPAIR_CONFIG_PATH"
  PROVIDER_ID_PATH="$REPAIR_PROVIDER_ID_PATH"
  MANIFEST_PATH="$REPAIR_MANIFEST_PATH"
  PLIST_PATH="$REPAIR_PLIST_PATH"
  PROVIDER_LABEL="live.malibu.provider"
  DRY_RUN=0
  EMERGENCY_ROLLBACK=0
  REFERRAL_REPLACE_INCUMBENT=0
  REPAIR_EXISTING_INSTALL=1
  REFERRAL_CODE_SOURCE_FILE=""
  FRESH_REFERRAL_BOOTSTRAP=0
  NO_PROMPT=1
  log() { :; }
  die() { exit "$1"; }
  prepare_fresh_referral_code
) || repair_missing_rc=$?
if [ "$repair_missing_rc" -eq 0 ]; then
  echo "repair bypassed referral admission without complete evidence" >&2
  exit 1
fi
if [ "$repair_missing_rc" -eq 20 ]; then
  echo "repair evidence failure reused the missing-invite exit 20" >&2
  exit 1
fi
if [ "$repair_missing_rc" -ne 28 ]; then
  echo "repair evidence failure used exit $repair_missing_rc instead of 28" >&2
  exit 1
fi

quiesce_log="$TMP/repair-watchdog-quiesce.log"
(
  REPAIR_EXISTING_INSTALL=1
  LAUNCHD_DOMAIN="gui/$UID"
  WATCHDOG_LABEL="live.malibu.provider-watchdog"
  LEGACY_WATCHDOG_LABEL="live.streamvc.macprovider-watchdog"
  WATCHDOG_DIR="$TMP/watchdog"
  WATCHDOG_PATH="$WATCHDOG_DIR/macprovider-health-monitor"
  WATCHDOG_BOOTSTRAP_PATH="$WATCHDOG_PATH"
  WATCHDOG_PLIST_BOOTSTRAP_PATH="$TMP/launchd/live.malibu.provider-watchdog.plist"
  LEGACY_WATCHDOG_PLIST_BOOTSTRAP_PATH="$TMP/launchd/live.streamvc.macprovider-watchdog.plist"
  mkdir -p "$WATCHDOG_DIR" "$TMP/launchd"
  log() { :; }
  die() { exit "$1"; }
  launchctl_service() {
    case "$1 $2" in
      "print $LAUNCHD_DOMAIN/$WATCHDOG_LABEL")
        [ ! -f "$TMP/current-watchdog-stopped" ] || return 113
        printf '    program = %s\n    path = %s\n' "$WATCHDOG_BOOTSTRAP_PATH" "$WATCHDOG_PLIST_BOOTSTRAP_PATH"
        ;;
      "print $LAUNCHD_DOMAIN/$LEGACY_WATCHDOG_LABEL")
        [ ! -f "$TMP/legacy-watchdog-stopped" ] || return 113
        printf '    program = %s\n    path = %s\n' "$WATCHDOG_PATH" "$LEGACY_WATCHDOG_PLIST_BOOTSTRAP_PATH"
        ;;
      "bootout $LAUNCHD_DOMAIN/$WATCHDOG_LABEL")
        : > "$TMP/current-watchdog-stopped"
        printf 'bootout %s\n' "$WATCHDOG_LABEL" >> "$quiesce_log"
        ;;
      "bootout $LAUNCHD_DOMAIN/$LEGACY_WATCHDOG_LABEL")
        : > "$TMP/legacy-watchdog-stopped"
        printf 'bootout %s\n' "$LEGACY_WATCHDOG_LABEL" >> "$quiesce_log"
        ;;
      *)
        return 113
        ;;
    esac
  }
  launchd_print_loaded() {
    case "$1" in
      "$LAUNCHD_DOMAIN/$WATCHDOG_LABEL")
        [ ! -f "$TMP/current-watchdog-stopped" ]
        ;;
      "$LAUNCHD_DOMAIN/$LEGACY_WATCHDOG_LABEL")
        [ ! -f "$TMP/legacy-watchdog-stopped" ]
        ;;
      *)
        return 70
        ;;
    esac
  }
  quiesce_repair_watchdogs_for_transaction
) || {
  echo "repair preflight did not safely quiesce current and legacy watchdog labels" >&2
  exit 1
}
grep -F "bootout live.malibu.provider-watchdog" "$quiesce_log" >/dev/null
grep -F "bootout live.streamvc.macprovider-watchdog" "$quiesce_log" >/dev/null
(
  REPAIR_EXISTING_INSTALL=0
  LAUNCHD_DOMAIN="gui/$UID"
  WATCHDOG_LABEL="live.malibu.provider-watchdog"
  LEGACY_WATCHDOG_LABEL="live.streamvc.macprovider-watchdog"
  quiesce_repair_watchdogs_for_transaction
)
if (
  REPAIR_EXISTING_INSTALL=1
  LAUNCHD_DOMAIN="gui/$UID"
  WATCHDOG_LABEL="live.malibu.provider-watchdog"
  LEGACY_WATCHDOG_LABEL="live.streamvc.macprovider-watchdog"
  WATCHDOG_DIR="$TMP/watchdog-indeterminate"
  WATCHDOG_PATH="$WATCHDOG_DIR/macprovider-health-monitor"
  WATCHDOG_BOOTSTRAP_PATH="$WATCHDOG_PATH"
  WATCHDOG_PLIST_BOOTSTRAP_PATH="$TMP/launchd/live.malibu.provider-watchdog.plist"
  mkdir -p "$WATCHDOG_DIR" "$TMP/launchd"
  log() { :; }
  die() { exit "$1"; }
  launchctl_service() { return 70; }
  launchd_print_loaded() { return 70; }
  quiesce_repair_watchdogs_for_transaction
); then
  echo "repair treated indeterminate launchd print failure as watchdog absence" >&2
  exit 1
fi
if (
  REPAIR_EXISTING_INSTALL=1
  LAUNCHD_DOMAIN="gui/$UID"
  WATCHDOG_LABEL="live.malibu.provider-watchdog"
  LEGACY_WATCHDOG_LABEL="live.streamvc.macprovider-watchdog"
  WATCHDOG_DIR="$TMP/watchdog-lingering-pid"
  WATCHDOG_PATH="$WATCHDOG_DIR/macprovider-health-monitor"
  WATCHDOG_BOOTSTRAP_PATH="$WATCHDOG_PATH"
  WATCHDOG_PLIST_BOOTSTRAP_PATH="$TMP/launchd/live.malibu.provider-watchdog.plist"
  mkdir -p "$WATCHDOG_DIR" "$TMP/launchd"
  log() { :; }
  die() { exit "$1"; }
  pid_is_live_non_zombie() { return 0; }
  lsof() { printf 'n%s\n' "$WATCHDOG_BOOTSTRAP_PATH"; }
  launchctl_service() {
    case "$1 $2" in
      "print $LAUNCHD_DOMAIN/$WATCHDOG_LABEL")
        [ ! -f "$TMP/current-watchdog-detached" ] || return 113
        printf '    program = %s\n    path = %s\n    pid = 4242\n' "$WATCHDOG_BOOTSTRAP_PATH" "$WATCHDOG_PLIST_BOOTSTRAP_PATH"
        ;;
      "bootout $LAUNCHD_DOMAIN/$WATCHDOG_LABEL")
        : > "$TMP/current-watchdog-detached"
        ;;
      *)
        return 113
        ;;
    esac
  }
  launchd_print_loaded() { return 1; }
  quiesce_repair_watchdogs_for_transaction
); then
  echo "repair accepted a detached but still-live managed watchdog process" >&2
  exit 1
fi
if (
  REPAIR_EXISTING_INSTALL=1
  LAUNCHD_DOMAIN="gui/$UID"
  WATCHDOG_LABEL="live.malibu.provider-watchdog"
  LEGACY_WATCHDOG_LABEL="live.streamvc.macprovider-watchdog"
  WATCHDOG_DIR="$TMP/watchdog-lingering-script-pid"
  WATCHDOG_PATH="$WATCHDOG_DIR/macprovider-health-monitor"
  WATCHDOG_BOOTSTRAP_PATH="$WATCHDOG_PATH"
  WATCHDOG_PLIST_BOOTSTRAP_PATH="$TMP/launchd/live.malibu.provider-watchdog.plist"
  mkdir -p "$WATCHDOG_DIR" "$TMP/launchd"
  log() { :; }
  die() { exit "$1"; }
  pid_is_live_non_zombie() { return 0; }
  lsof() { printf 'n/bin/bash\n'; }
  ps() { printf '/bin/bash %s/watchdog.sh\n' "$WATCHDOG_DIR"; }
  launchctl_service() {
    case "$1 $2" in
      "print $LAUNCHD_DOMAIN/$WATCHDOG_LABEL")
        [ ! -f "$TMP/current-watchdog-script-detached" ] || return 113
        printf '    program = %s/watchdog.sh\n    path = %s\n    pid = 4343\n' "$WATCHDOG_DIR" "$WATCHDOG_PLIST_BOOTSTRAP_PATH"
        ;;
      "bootout $LAUNCHD_DOMAIN/$WATCHDOG_LABEL")
        : > "$TMP/current-watchdog-script-detached"
        ;;
      *)
        return 113
        ;;
    esac
  }
  launchd_print_loaded() { return 1; }
  quiesce_repair_watchdogs_for_transaction
); then
  echo "repair accepted a detached but still-live script watchdog process" >&2
  exit 1
fi

lock_home="$TMP/lock-home"
lock_config="$lock_home/.config/macprovider"
lock_pending_root="$lock_home/.local/share/macprovider/autoupdate"
if /usr/sbin/sysctl -n kern.bootsessionuuid >/dev/null 2>&1 \
    || [ -r /proc/sys/kernel/random/boot_id ]; then
  mkdir -m 700 -p "$lock_config" "$lock_pending_root"
  printf '{"operation_id":"malformed-repair-marker"}\n' > "$lock_pending_root/pending.json"
  chmod 600 "$lock_pending_root/pending.json"
  (
    HOME="$lock_home"
    CONFIG_DIR="$lock_config"
    INSTALL_LOCK_PATH="$lock_config/install.lock"
    BINARY_PATH="$lock_home/.local/bin/macprovider-cli"
    LOG_DIR="$lock_home/Library/Logs/macprovider"
    LOG_PATH="$lock_home/Library/Logs/macprovider/watchdog.log"
    MACPROVIDER_AUTOUPDATE_STATE_ROOT="$lock_pending_root"
    PROVIDER_MUTATION_ROOT="$lock_pending_root"
    PROVIDER_MUTATION_LOCK_PATH="$lock_pending_root/update.lock"
    PROVIDER_MUTATION_PENDING_PATH="$lock_pending_root/pending.json"
    LABEL="live.malibu.provider"
    LAUNCHD_DOMAIN="gui/$UID"
    REPAIR_EXISTING_INSTALL=1
    DRY_RUN=0
    log() { :; }
    die() { exit "$1"; }
    quiesce_repair_watchdogs_for_transaction() { : > "$lock_pending_root/quiesced"; }
    repair_autoupdate_recovery_preflight
  ) || {
    echo "repair preflight did not route malformed pending.json through autoupdate recovery" >&2
    exit 1
  }
  test -f "$lock_pending_root/quiesced"
  test ! -e "$lock_pending_root/pending.json"
  test "$(find "$lock_pending_root" -name 'pending-quarantined-*.json' | wc -l | tr -d ' ')" = "1"
  (
    HOME="$lock_home"
    CONFIG_DIR="$lock_config"
    INSTALL_LOCK_PATH="$lock_config/install.lock"
    PROVIDER_MUTATION_ROOT="$lock_pending_root"
    PROVIDER_MUTATION_LOCK_PATH="$lock_pending_root/update.lock"
    PROVIDER_MUTATION_PENDING_PATH="$lock_pending_root/pending.json"
    DRY_RUN=0
    REPAIR_EXISTING_INSTALL=1
    INSTALL_LOCK_HELD=0
    INSTALL_LOCK_TOKEN=""
    INSTALL_LOCK_HOLDER_PID=""
    log() { :; }
    die() { exit "$1"; }
    acquire_install_lock
    [ "$INSTALL_LOCK_HELD" -eq 1 ]
    release_install_lock
  ) || {
    echo "repair did not acquire the mutation lock after autoupdate recovery quarantined malformed pending.json" >&2
    exit 1
  }
  marker_deadline="$(python3 - <<'PY'
import datetime
print((datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(minutes=10)).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
)"
  marker_update_id="12345678-1234-4234-9234-123456789abc"
  mkdir -p "$lock_home/.local/bin"
  printf 'target\n' > "$lock_home/.local/bin/macprovider-cli"
  printf 'backup\n' > "$lock_home/.local/bin/.macprovider-cli.rollback-$marker_update_id"
  marker_backup_hash="$(shasum -a 256 "$lock_home/.local/bin/.macprovider-cli.rollback-$marker_update_id" | awk '{ print $1 }')"
  python3 - "$lock_pending_root/pending.json" "$lock_home/.local/bin/macprovider-cli" \
    "$lock_home/.local/bin/.macprovider-cli.rollback-$marker_update_id" "$marker_deadline" "$marker_update_id" \
    "$marker_backup_hash" <<'PY'
import json
import pathlib
import sys

pending, target, backup, deadline, update_id, backup_hash = sys.argv[1:]
pathlib.Path(pending).write_text(json.dumps({
    "backup_path": backup,
    "marker_deadline": deadline,
    "mode": 493,
    "sha256": backup_hash,
    "size": 7,
    "target_path": target,
    "target_version": "1.2.3",
    "update_id": update_id,
}, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
PY
  chmod 600 "$lock_pending_root/pending.json"
  repair_active_pending_rc=0
  (
    HOME="$lock_home"
    CONFIG_DIR="$lock_config"
    INSTALL_LOCK_PATH="$lock_config/install.lock"
    BINARY_PATH="$lock_home/.local/bin/macprovider-cli"
    LOG_DIR="$lock_home/Library/Logs/macprovider"
    LOG_PATH="$lock_home/Library/Logs/macprovider/watchdog.log"
    MACPROVIDER_AUTOUPDATE_STATE_ROOT="$lock_pending_root"
    PROVIDER_MUTATION_ROOT="$lock_pending_root"
    PROVIDER_MUTATION_LOCK_PATH="$lock_pending_root/update.lock"
    PROVIDER_MUTATION_PENDING_PATH="$lock_pending_root/pending.json"
    LABEL="live.malibu.provider"
    LAUNCHD_DOMAIN="gui/$UID"
    REPAIR_EXISTING_INSTALL=1
    DRY_RUN=0
    log() { :; }
    die() { exit "$1"; }
    quiesce_repair_watchdogs_for_transaction() { exit 99; }
    repair_autoupdate_recovery_preflight
  ) || repair_active_pending_rc=$?
  [ "$repair_active_pending_rc" -eq 0 ] || {
    echo "repair autoupdate recovery preflight failed on an active valid pending marker" >&2
    exit 1
  }
  test -f "$lock_pending_root/pending.json"
  (
    HOME="$lock_home"
    CONFIG_DIR="$lock_config"
    INSTALL_LOCK_PATH="$lock_config/install.lock"
    PROVIDER_MUTATION_ROOT="$lock_pending_root"
    PROVIDER_MUTATION_LOCK_PATH="$lock_pending_root/update.lock"
    PROVIDER_MUTATION_PENDING_PATH="$lock_pending_root/pending.json"
    DRY_RUN=0
    REPAIR_EXISTING_INSTALL=1
    INSTALL_LOCK_HELD=0
    INSTALL_LOCK_TOKEN=""
    INSTALL_LOCK_HOLDER_PID=""
    log() { :; }
    die() { exit "$1"; }
    acquire_install_lock
  ) || repair_active_pending_rc=$?
  [ "$repair_active_pending_rc" -eq 73 ] || {
    echo "repair did not preserve active pending.json authority with exit 73" >&2
    exit 1
  }
  normal_active_pending_rc=0
  (
    HOME="$lock_home"
    CONFIG_DIR="$lock_config"
    INSTALL_LOCK_PATH="$lock_config/install.lock"
    PROVIDER_MUTATION_ROOT="$lock_pending_root"
    PROVIDER_MUTATION_LOCK_PATH="$lock_pending_root/update.lock"
    PROVIDER_MUTATION_PENDING_PATH="$lock_pending_root/pending.json"
    DRY_RUN=0
    REPAIR_EXISTING_INSTALL=0
    INSTALL_LOCK_HELD=0
    INSTALL_LOCK_TOKEN=""
    INSTALL_LOCK_HOLDER_PID=""
    log() { :; }
    die() { exit "$1"; }
    acquire_install_lock
  ) || normal_active_pending_rc=$?
  [ "$normal_active_pending_rc" -eq 73 ] || {
    echo "normal install did not reject pending.json with exit 73" >&2
    exit 1
  }
  test -f "$lock_pending_root/pending.json"
  rm -f "$lock_pending_root/pending.json"
  release_backup="$lock_home/.local/bin/.macprovider-cli.release-rollback-$marker_update_id"
  mkdir -m 700 "$release_backup"
  python3 - "$lock_pending_root/pending.json" "$lock_home/.local/bin/macprovider-cli" \
    "$lock_home/.local/bin/.macprovider-cli.rollback-$marker_update_id" "$marker_deadline" "$marker_update_id" \
    "$marker_backup_hash" "$release_backup" <<'PY'
import json
import pathlib
import sys

pending, target, backup, deadline, update_id, backup_hash, release_backup = sys.argv[1:]
pathlib.Path(pending).write_text(json.dumps({
    "backup_path": backup,
    "marker_deadline": deadline,
    "mode": 493,
    "release_backup_path": release_backup,
    "release_backup_sha256": "f" * 64,
    "sha256": backup_hash,
    "size": 7,
    "target_path": target,
    "target_version": "1.2.3",
    "update_id": update_id,
}, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
PY
  chmod 600 "$lock_pending_root/pending.json"
  (
    HOME="$lock_home"
    CONFIG_DIR="$lock_config"
    INSTALL_LOCK_PATH="$lock_config/install.lock"
    BINARY_PATH="$lock_home/.local/bin/macprovider-cli"
    LOG_DIR="$lock_home/Library/Logs/macprovider"
    PROVIDER_MUTATION_ROOT="$lock_pending_root"
    PROVIDER_MUTATION_LOCK_PATH="$lock_pending_root/update.lock"
    PROVIDER_MUTATION_PENDING_PATH="$lock_pending_root/pending.json"
    LABEL="live.malibu.provider"
    LAUNCHD_DOMAIN="gui/$UID"
    REPAIR_EXISTING_INSTALL=1
    DRY_RUN=0
    log() { :; }
    die() { exit "$1"; }
    quiesce_repair_watchdogs_for_transaction() { :; }
    repair_autoupdate_recovery_preflight
  ) || {
    echo "repair preflight failed instead of quarantining a release-backup hash mismatch marker" >&2
    exit 1
  }
  test ! -e "$lock_pending_root/pending.json"
  off_target_dir="$lock_home/off-target"
  mkdir -p "$off_target_dir"
  printf 'offtarget\n' > "$off_target_dir/macprovider-cli"
  printf 'offbackup\n' > "$off_target_dir/.macprovider-cli.rollback-$marker_update_id"
  off_backup_hash="$(shasum -a 256 "$off_target_dir/.macprovider-cli.rollback-$marker_update_id" | awk '{ print $1 }')"
  python3 - "$lock_pending_root/pending.json" "$off_target_dir/macprovider-cli" \
    "$off_target_dir/.macprovider-cli.rollback-$marker_update_id" "$marker_deadline" "$marker_update_id" \
    "$off_backup_hash" <<'PY'
import json
import pathlib
import sys

pending, target, backup, deadline, update_id, backup_hash = sys.argv[1:]
pathlib.Path(pending).write_text(json.dumps({
    "backup_path": backup,
    "marker_deadline": deadline,
    "mode": 493,
    "sha256": backup_hash,
    "size": 10,
    "target_path": target,
    "target_version": "1.2.3",
    "update_id": update_id,
}, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
PY
  chmod 600 "$lock_pending_root/pending.json"
  (
    HOME="$lock_home"
    CONFIG_DIR="$lock_config"
    INSTALL_LOCK_PATH="$lock_config/install.lock"
    BINARY_PATH="$lock_home/.local/bin/macprovider-cli"
    LOG_DIR="$lock_home/Library/Logs/macprovider"
    PROVIDER_MUTATION_ROOT="$lock_pending_root"
    PROVIDER_MUTATION_LOCK_PATH="$lock_pending_root/update.lock"
    PROVIDER_MUTATION_PENDING_PATH="$lock_pending_root/pending.json"
    LABEL="live.malibu.provider"
    LAUNCHD_DOMAIN="gui/$UID"
    REPAIR_EXISTING_INSTALL=1
    DRY_RUN=0
    log() { :; }
    die() { exit "$1"; }
    quiesce_repair_watchdogs_for_transaction() { :; }
    repair_autoupdate_recovery_preflight
  ) || {
    echo "repair preflight failed instead of quarantining an off-target pending marker" >&2
    exit 1
  }
  test ! -e "$lock_pending_root/pending.json"
  printf 'backup\n' > "$lock_home/.local/bin/.macprovider-cli.rollback-$marker_update_id"
  marker_backup_hash="$(shasum -a 256 "$lock_home/.local/bin/.macprovider-cli.rollback-$marker_update_id" | awk '{ print $1 }')"
  python3 - "$lock_pending_root/pending.json" "$lock_home/.local/bin/macprovider-cli" \
    "$lock_home/.local/bin/.macprovider-cli.rollback-$marker_update_id" "$marker_deadline" "$marker_update_id" \
    "$marker_backup_hash" <<'PY'
import json
import pathlib
import sys

pending, target, backup, deadline, update_id, backup_hash = sys.argv[1:]
pathlib.Path(pending).write_text(json.dumps({
    "backup_path": backup,
    "marker_deadline": deadline,
    "mode": 493,
    "sha256": backup_hash,
    "size": 7,
    "target_path": target,
    "target_version": "1.2.3",
    "update_id": update_id,
}, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
PY
  chmod 600 "$lock_pending_root/pending.json"
  if chmod +a "user:$(id -un) allow write" "$lock_pending_root/pending.json" 2>/dev/null; then
    acl_pending_rc=0
    (
      HOME="$lock_home"
      CONFIG_DIR="$lock_config"
      INSTALL_LOCK_PATH="$lock_config/install.lock"
      BINARY_PATH="$lock_home/.local/bin/macprovider-cli"
      LOG_DIR="$lock_home/Library/Logs/macprovider"
      PROVIDER_MUTATION_ROOT="$lock_pending_root"
      PROVIDER_MUTATION_LOCK_PATH="$lock_pending_root/update.lock"
      PROVIDER_MUTATION_PENDING_PATH="$lock_pending_root/pending.json"
      LABEL="live.malibu.provider"
      LAUNCHD_DOMAIN="gui/$UID"
      REPAIR_EXISTING_INSTALL=1
      DRY_RUN=0
      log() { :; }
      die() { exit "$1"; }
      repair_autoupdate_recovery_preflight
    ) 2>/dev/null || acl_pending_rc=$?
    chmod -a "user:$(id -un) allow write" "$lock_pending_root/pending.json" 2>/dev/null || true
    [ "$acl_pending_rc" -ne 0 ] || {
      echo "repair preflight accepted an ACL-writable pending marker" >&2
      exit 1
    }
  fi
  rm -f "$lock_pending_root/pending.json"
  acl_home="$TMP/acl-lock-home"
  acl_config="$acl_home/.config/macprovider"
  acl_pending_root="$acl_home/.local/share/macprovider/autoupdate"
  mkdir -m 700 -p "$acl_config" "$acl_pending_root"
  printf '{"operation_id":"malformed-home-acl-repair-marker"}\n' > "$acl_pending_root/pending.json"
  chmod 600 "$acl_pending_root/pending.json"
  if chmod +a "group:everyone allow add_file,add_subdirectory" "$acl_home" 2>/dev/null; then
    (
      HOME="$acl_home"
      INSTALL_DIR="$acl_home/macprovider"
      CONFIG_DIR="$acl_config"
      INSTALL_LOCK_PATH="$acl_config/install.lock"
      BINARY_PATH="$acl_home/.local/bin/macprovider-cli"
      PROVIDER_MUTATION_ROOT="$acl_pending_root"
      PROVIDER_MUTATION_LOCK_PATH="$acl_pending_root/update.lock"
      PROVIDER_MUTATION_PENDING_PATH="$acl_pending_root/pending.json"
      LOG_DIR="$acl_home/Library/Logs/macprovider"
      LAUNCHD_DOMAIN="gui/$UID"
      REPAIR_EXISTING_INSTALL=1
      DRY_RUN=0
      INSTALL_LOCK_HELD=0
      INSTALL_LOCK_TOKEN=""
      INSTALL_LOCK_HOLDER_PID=""
      log() { :; }
      die() { exit "$1"; }
      quiesce_repair_watchdogs_for_transaction() { :; }
      validate_install_dir
      remediate_repair_home_write_acl
      repair_autoupdate_recovery_preflight
      acquire_install_lock
      [ "$INSTALL_LOCK_HELD" -eq 1 ]
      release_install_lock
      REPAIR_EXISTING_INSTALL=0
      validate_install_dir
    ) || {
      chmod -a "group:everyone allow add_file,add_subdirectory" "$acl_home" 2>/dev/null || true
      echo "repair did not remove the known HOME ACL and recover malformed pending.json" >&2
      exit 1
    }
    chmod -a "group:everyone allow add_file,add_subdirectory" "$acl_home" 2>/dev/null || true
    test ! -e "$acl_pending_root/pending.json"
  fi
else
  echo "SKIP: boot-session identity unavailable; stale pending.json lock-path repair case not run"
fi

complete_payload="$(printf '%s\n' \
  macprovider-cli \
  mlx.metallib \
  compatibility-set.json \
  compatibility-set-local \
  compatibility-set-local/install.sh \
  compatibility-set-local/provider-launch-agent.plist.template \
  compatibility-set-local/updater-rollback.json \
  compatibility-set-local/watchdog-launch-agent.plist.template \
  compatibility-set-local/watchdog.sh \
  Runtime.bundle \
  Runtime.bundle/resource \
  catalog-release \
  catalog-release/release.json \
  catalog-release/trusted-keys.json \
  catalog-release/tier2-catalog.json \
  catalog-release/autotune-candidates.json \
  catalog-release/autotune-candidates.json.sig \
  catalog-release/demand-rank.json \
  catalog-release/demand-rank.json.sig \
  catalog-release/rate-card.json \
  catalog-release/rate-card.json.sig)"
validate_staged_entries "$complete_payload" "test payload"
if (validate_staged_entries "${complete_payload//$'\n'mlx.metallib/}" "test payload"); then
  echo "payload without mlx.metallib unexpectedly passed validation" >&2
  exit 1
fi
if (validate_staged_entries "${complete_payload//$'\n'Runtime.bundle$'\n'Runtime.bundle\/resource/}" "test payload"); then
  echo "payload without a SwiftPM bundle unexpectedly passed validation" >&2
  exit 1
fi
if (validate_staged_entries "${complete_payload//$'\n'catalog-release\/release.json/}" "test payload"); then
  echo "payload without the signed catalog manifest unexpectedly passed validation" >&2
  exit 1
fi
if (validate_staged_entries "${complete_payload//$'\n'catalog-release\/rate-card.json.sig/}" "test payload"); then
  echo "payload without the signed rate-card sidecar unexpectedly passed validation" >&2
  exit 1
fi
if (validate_staged_entries "${complete_payload//$'\n'compatibility-set.json/}" "test payload"); then
  echo "payload without the compatibility-set manifest unexpectedly passed validation" >&2
  exit 1
fi

CONFIG_DIR="$TMP/home/.config/macprovider"
CONFIG_PATH="$CONFIG_DIR/config.yaml"
LIVE_CONFIG_PATH="$CONFIG_PATH"
PROVIDER_ID_PATH="$CONFIG_DIR/provider_id"
LIVE_PROVIDER_ID_PATH="$PROVIDER_ID_PATH"
mkdir -p "$CONFIG_DIR"
cat > "$CONFIG_PATH" <<'EOF'
# operator-owned settings must survive installer upgrades
model: "old/model"
provider_token: "secret-token"
receipt_log_path: "/private/receipts.jsonl"
enable_receipts: false
enable_warm_swap: true
auto_update: false
custom_block:
  nested: keep-me
port: 18080
EOF

semantic_merge_config \
  "$CONFIG_PATH" \
  "new/model" \
  "provider-new" \
  "wss://coordinator.example/ws/provider" \
  "19090"

grep -F 'model: "new/model"' "$CONFIG_PATH" >/dev/null
grep -F 'provider_id: "provider-new"' "$CONFIG_PATH" >/dev/null
grep -F 'coordinator_url: "wss://coordinator.example/ws/provider"' "$CONFIG_PATH" >/dev/null
grep -F 'port: 19090' "$CONFIG_PATH" >/dev/null
grep -F 'provider_token: "secret-token"' "$CONFIG_PATH" >/dev/null
grep -F 'receipt_log_path: "/private/receipts.jsonl"' "$CONFIG_PATH" >/dev/null
grep -F 'enable_receipts: false' "$CONFIG_PATH" >/dev/null
grep -F 'enable_warm_swap: true' "$CONFIG_PATH" >/dev/null
grep -F 'auto_update: false' "$CONFIG_PATH" >/dev/null
grep -F '  nested: keep-me' "$CONFIG_PATH" >/dev/null

semantic_merge_config \
  "$CONFIG_PATH" \
  "new/model" \
  "provider-new" \
  "wss://coordinator.example/ws/provider" \
  "19090" \
  "true"

grep -F 'enable_receipts: true' "$CONFIG_PATH" >/dev/null
[ "$(grep -c '^enable_receipts:' "$CONFIG_PATH")" -eq 1 ]
grep -F 'provider_token: "secret-token"' "$CONFIG_PATH" >/dev/null
grep -F 'receipt_log_path: "/private/receipts.jsonl"' "$CONFIG_PATH" >/dev/null
grep -F 'enable_warm_swap: true' "$CONFIG_PATH" >/dev/null
grep -F 'auto_update: false' "$CONFIG_PATH" >/dev/null
grep -F '  nested: keep-me' "$CONFIG_PATH" >/dev/null

staging_dir="$TMP/staging"
mkdir -p "$staging_dir"
printf 'provider-old\n' > "$LIVE_PROVIDER_ID_PATH"
prepare_staged_config
grep -F 'model: "new/model"' "$STAGED_CONFIG_PATH" >/dev/null
semantic_merge_config "$STAGED_CONFIG_PATH" "staged/model" "provider-staged" "wss://staged.example/ws/provider" "19090"
printf 'provider-staged\n' > "$STAGED_PROVIDER_ID_PATH"
grep -F 'model: "new/model"' "$LIVE_CONFIG_PATH" >/dev/null
activate_staged_config
grep -F 'model: "staged/model"' "$LIVE_CONFIG_PATH" >/dev/null
grep -F 'provider-staged' "$LIVE_PROVIDER_ID_PATH" >/dev/null

PORT=18080
lsof() {
  case "$*" in
    *-iTCP:19080*) printf '123\n' ;;
    *) return 1 ;;
  esac
}
select_autotune_benchmark_port
[ "$AUTOTUNE_BENCHMARK_PORT" = "19081" ] || {
  echo "autotune did not reserve the next free non-live benchmark port" >&2
  exit 1
}
if (MACPROVIDER_AUTOTUNE_PORT=18080; select_autotune_benchmark_port); then
  echo "autotune accepted the live provider port for staged benchmarks" >&2
  exit 1
fi

CONFIG_PATH="$LIVE_CONFIG_PATH"
PROVIDER_ID_PATH="$LIVE_PROVIDER_ID_PATH"
CUTOVER_STARTED=0
INSTALL_TX_WATCHDOG_WAS_ACTIVE=0
WATCHDOG_LABEL="live.malibu.provider-watchdog"
WATCHDOG_PLIST_PATH="$TMP/home/Library/LaunchAgents/live.malibu.provider-watchdog.plist"
log() { :; }

skip_restore_called="$TMP/skip-restore-called"
skip_discard_called="$TMP/skip-discard-called"
(
  SKIP_PROVIDER_START=1
  EXISTING_INSTALL_WAS_PRESENT=1
  rollback_install_transaction() { : > "$skip_restore_called"; }
  discard_install_transaction_before_cutover() { : > "$skip_discard_called"; }
  restore_existing_provider_if_start_skipped
)
test -f "$skip_discard_called"
test ! -f "$skip_restore_called"

(
  SKIP_PROVIDER_START=1
  EXISTING_INSTALL_WAS_PRESENT=1
  CUTOVER_STARTED=1
  rollback_install_transaction() { : > "$skip_restore_called"; }
  restore_existing_provider_if_start_skipped
)
test -f "$skip_restore_called"

( SKIP_PROVIDER_START=1; EXISTING_INSTALL_WAS_PRESENT=0; ! restore_existing_provider_if_start_skipped )

PORT=18080
INSTALL_DIR="$TMP/install"

# prefetch_upgrade_autotune_model retry dead-end fix: a prior install that
# carries no signed-catalog model id (donor-mode / never-started / minimally
# seeded config from an interrupted first run) must NOT die 6 on retry when no
# provider service is running. It should fall through to a fresh recommendation.
(
  lsof() { return 1; }  # nothing holding the port
  EXISTING_INSTALL_WAS_PRESENT=1
  AUTOTUNE_UPGRADE_CANDIDATE_MODEL_ID=""
  INSTALL_TX_SERVICE_WAS_ACTIVE=0
  prefetch_upgrade_autotune_model
) || {
  echo "prefetch dead-ended a retry with no live provider instead of re-tuning" >&2
  exit 1
}

# But when a launchd provider service IS active, prefetch must still fail
# closed rather than stop a live earner for a blind re-tune with no pinned model.
if (
  lsof() { return 1; }
  EXISTING_INSTALL_WAS_PRESENT=1
  AUTOTUNE_UPGRADE_CANDIDATE_MODEL_ID=""
  INSTALL_TX_SERVICE_WAS_ACTIVE=1
  prefetch_upgrade_autotune_model
); then
  echo "prefetch stopped a live launchd provider for a blind re-tune with no pinned model" >&2
  exit 1
fi

# Malibu repair may encounter a stale loaded label after the provider binary
# was removed. Trusted repair evidence plus no serving CLI must not be blocked
# by the ordinary-upgrade live-label guard before launchd reclaim runs.
(
  lsof() { return 1; }
  EXISTING_INSTALL_WAS_PRESENT=1
  AUTOTUNE_UPGRADE_CANDIDATE_MODEL_ID=""
  INSTALL_TX_SERVICE_WAS_ACTIVE=1
  REPAIR_EXISTING_INSTALL=1
  prefetch_upgrade_autotune_model
) || {
  echo "repair dead-ended on a stale loaded provider label without a live CLI" >&2
  exit 1
}

# And when a MANUALLY started macprovider-cli holds the live port (no launchd
# service, so INSTALL_TX_SERVICE_WAS_ACTIVE=0), prefetch must ALSO fail closed --
# INSTALL_TX_SERVICE_WAS_ACTIVE alone is not a sufficient live-provider signal.
if (
  # Mock lsof: report a listener on $PORT whose txt executable is our own CLI.
  # The -d txt query resolves the executable; the -iTCP query lists the pid.
  lsof() {
    case "$*" in
      *-d\ txt*) printf 'n%s/macprovider-cli\n' "$INSTALL_DIR" ;;
      *-iTCP:*) printf '4242\n' ;;
      *) return 1 ;;
    esac
  }
  EXISTING_INSTALL_WAS_PRESENT=1
  AUTOTUNE_UPGRADE_CANDIDATE_MODEL_ID=""
  INSTALL_TX_SERVICE_WAS_ACTIVE=0
  prefetch_upgrade_autotune_model
); then
  echo "prefetch stopped a live MANUAL provider (own CLI on port) for a blind re-tune" >&2
  exit 1
fi

# A FOREIGN process on the port (not our CLI) is not our provider; fall through.
(
  lsof() {
    case "$*" in
      *-d\ txt*) printf 'n/usr/bin/some-other-daemon\n' ;;
      *-iTCP:*) printf '9999\n' ;;
      *) return 1 ;;
    esac
  }
  EXISTING_INSTALL_WAS_PRESENT=1
  AUTOTUNE_UPGRADE_CANDIDATE_MODEL_ID=""
  INSTALL_TX_SERVICE_WAS_ACTIVE=0
  prefetch_upgrade_autotune_model
) || {
  echo "prefetch fail-closed on a foreign (non-CLI) port holder" >&2
  exit 1
}

# No existing install at all: prefetch is a no-op.
(
  lsof() { return 1; }
  EXISTING_INSTALL_WAS_PRESENT=0
  AUTOTUNE_UPGRADE_CANDIDATE_MODEL_ID=""
  INSTALL_TX_SERVICE_WAS_ACTIVE=0
  prefetch_upgrade_autotune_model
) || {
  echo "prefetch failed the fresh-install no-op case" >&2
  exit 1
}

echo "provider upgrade staging, config preservation, and cutover ordering ok"
