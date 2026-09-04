#!/usr/bin/env bash
# Public Mac Provider installer for https://get.malibu.tech/install.sh.
#
# Launchd template substitutions performed by this script:
#   __USER_HOME__       -> absolute installing user's HOME
#   __BINARY_PATH__     -> absolute ~/.local/bin/macprovider-cli path
#   __LOG_DIR__         -> absolute ~/Library/Logs/macprovider path
#   __CONFIG_PATH__     -> absolute provider config path

set -euo pipefail

# Malibu may provide a one-shot owner-only file containing a referral code.
# Capture only that path, then remove it from the environment before any child
# process is launched. For a direct fresh install, this script creates the same
# protected file from an interactive prompt. The code never enters process
# arguments, environment, or logs; the CLI validates and consumes the file.
REFERRAL_CODE_SOURCE_FILE="${MACPROVIDER_REFERRAL_CODE_FILE:-}"
CREATED_REFERRAL_CODE_SOURCE_FILE=0
FRESH_REFERRAL_BOOTSTRAP=0
REFERRAL_REPLACE_INCUMBENT="${MACPROVIDER_REFERRAL_REPLACE_INCUMBENT:-0}"
REPAIR_EXISTING_INSTALL="${MACPROVIDER_REPAIR_EXISTING_INSTALL:-0}"
BUNDLED_CLI="${MACPROVIDER_BUNDLED_CLI:-}"
BUNDLED_APP="${MACPROVIDER_BUNDLED_APP:-}"
REFERRAL_BOOTSTRAP_COMPLETED=0
HEADLESS_REPAIR_INCUMBENT_BINARY=""
HEADLESS_REPAIR_INCUMBENT_SHA256=""
unset MACPROVIDER_REFERRAL_CODE_FILE
unset MACPROVIDER_REFERRAL_REPLACE_INCUMBENT
unset MACPROVIDER_REPAIR_EXISTING_INSTALL
unset MACPROVIDER_BUNDLED_CLI
unset MACPROVIDER_BUNDLED_APP

GITHUB_REPO="${MACPROVIDER_GITHUB_REPO:-Augustas11/macprovider}"
MACPROVIDER_MIN_SUPPORTED_VERSION="v1.7.11"
MACPROVIDER_MIN_EMERGENCY_VERSION="v1.8.30"
MACPROVIDER_MIN_HEADLESS_VERSION="v1.8.108"
COORDINATOR_URL_DEFAULT="wss://coordinator.malibu.tech/ws/provider"
COORDINATOR_BASE_DEFAULT="https://coordinator.malibu.tech"
INSTALL_DIR="${MACPROVIDER_INSTALL_DIR:-$HOME/macprovider}"
BIN_DIR="$HOME/.local/bin"
BINARY_PATH="$BIN_DIR/macprovider-cli"
# Malibu-branded PATH alias (#1261): additive `malibu-cli` command. The shipped
# binary and this canonical entrypoint keep the macprovider-cli name.
ALIAS_BINARY_PATH="$BIN_DIR/malibu-cli"
CONFIG_DIR="$HOME/.config/macprovider"
CONFIG_PATH="$CONFIG_DIR/config.yaml"
PROVIDER_ID_PATH="$CONFIG_DIR/provider_id"
REPLACEMENT_CANDIDATE_DIR="$CONFIG_DIR/replacement-candidate"
REPLACEMENT_CANDIDATE_PROVIDER_ID_PATH="$REPLACEMENT_CANDIDATE_DIR/provider_id"
RECOMMENDATION_PATH="$CONFIG_DIR/last-recommendation.json"
INSTALL_LOCK_PATH="$CONFIG_DIR/install.lock"
PROVIDER_MUTATION_ROOT="$HOME/.local/share/macprovider/autoupdate"
PROVIDER_MUTATION_LOCK_PATH="$PROVIDER_MUTATION_ROOT/update.lock"
PROVIDER_MUTATION_PENDING_PATH="$PROVIDER_MUTATION_ROOT/pending.json"
INSTALL_RECOVERY_LABEL="live.malibu.provider-install-recovery"
HEADLESS="${MACPROVIDER_HEADLESS:-0}"
HEADLESS_USER="${MACPROVIDER_HEADLESS_USER:-}"
if [ "$HEADLESS" = "1" ]; then
  LAUNCHD_DOMAIN="system"
  LAUNCHD_MANAGED_DIR="$CONFIG_DIR/launchd"
  LAUNCHD_BOOTSTRAP_DIR="/Library/LaunchDaemons"
else
  LAUNCHD_DOMAIN="gui/$UID"
  LAUNCHD_MANAGED_DIR="$HOME/Library/LaunchAgents"
  LAUNCHD_BOOTSTRAP_DIR="$LAUNCHD_MANAGED_DIR"
fi
INSTALL_RECOVERY_PLIST_PATH="$LAUNCHD_MANAGED_DIR/${INSTALL_RECOVERY_LABEL}.plist"
HEADLESS_RECOVERY_TRUST_PATH="/Library/Application Support/macprovider/install-recovery.sha256"
SUDO_BIN="/usr/bin/sudo"
LAUNCHCTL_BIN="/bin/launchctl"
ROOT_PYTHON3_BIN="/usr/bin/python3"
SYSTEM_LAUNCHD_DIR="/Library/LaunchDaemons"
LOCAL_USER_HOME_ROOT="/Users"
LIVE_CONFIG_PATH="$CONFIG_PATH"
LIVE_PROVIDER_ID_PATH="$PROVIDER_ID_PATH"
MANIFEST_DIR="$HOME/Library/Application Support/macprovider"
MANIFEST_PATH="$MANIFEST_DIR/install_manifest.json"
# The provider lifecycle-state file is authored by the CLI (ProviderLifecycleState
# .defaultURL). Because it can be left in a transactional intermediate state such
# as rollback_in_progress that only a lifecycle-aware CLI can clear, it must be
# part of the install transaction so a rollback to a legacy incumbent restores
# the exact prior contents (or prior absence) instead of stranding a stale state.
LIFECYCLE_STATE_PATH="$MANIFEST_DIR/lifecycle/state-v1.json"
# The CLI serializes the lifecycle store behind sibling lock files. The install
# transaction acquires the same locks around both snapshot and restore so a
# concurrent operator pause or lease mutation cannot be lost or clobbered, and
# it reconciles the operation-bound lease after a rollback. The lock files
# themselves are synchronization primitives and are never snapshotted, moved,
# or deleted.
LIFECYCLE_LEASE_PATH="$MANIFEST_DIR/lifecycle/lease.json"
LIFECYCLE_STATE_LOCK_PATH="$MANIFEST_DIR/lifecycle/.state-v1.json.lock"
LIFECYCLE_LEASE_LOCK_PATH="$MANIFEST_DIR/lifecycle/.lease.json.lock"
EXISTING_INSTALL_WAS_PRESENT=0
PROVIDER_LABEL="live.malibu.provider"
LEGACY_PROVIDER_LABEL="live.streamvc.macprovider"
PLIST_PATH="$LAUNCHD_MANAGED_DIR/live.malibu.provider.plist"
PLIST_BOOTSTRAP_PATH="$LAUNCHD_BOOTSTRAP_DIR/live.malibu.provider.plist"
LEGACY_PLIST_PATH="$LAUNCHD_MANAGED_DIR/live.streamvc.macprovider.plist"
LEGACY_PLIST_BOOTSTRAP_PATH="$LAUNCHD_BOOTSTRAP_DIR/live.streamvc.macprovider.plist"
LOG_DIR="$HOME/Library/Logs/macprovider"
# Issue #191: ship the macprovider-watchdog LaunchAgent alongside
# the main provider so every operator gets the silent-disconnect
# safety net. Source lives in ops/macprovider-watchdog/; we inline
# the scripts here so the public installer remains a single curl-able
# artifact.
WATCHDOG_DIR="$HOME/.local/share/macprovider-watchdog"
# Installed without a .sh suffix so macOS Login Items shows a readable
# background-item name instead of "watchdog.sh".
WATCHDOG_PATH="$WATCHDOG_DIR/macprovider-health-monitor"
if [ "$HEADLESS" = "1" ]; then
  WATCHDOG_BOOTSTRAP_PATH="/Library/Application Support/macprovider/macprovider-health-monitor"
  HEADLESS_WATCHDOG_LOG_DIR="/Library/Logs/macprovider"
  HEADLESS_WATCHDOG_STATE_DIR="/Library/Application Support/macprovider/watchdog-state"
else
  WATCHDOG_BOOTSTRAP_PATH="$WATCHDOG_PATH"
  HEADLESS_WATCHDOG_LOG_DIR=""
  HEADLESS_WATCHDOG_STATE_DIR=""
fi
WATCHDOG_PLIST_PATH="$LAUNCHD_MANAGED_DIR/live.malibu.provider-watchdog.plist"
WATCHDOG_PLIST_BOOTSTRAP_PATH="$LAUNCHD_BOOTSTRAP_DIR/live.malibu.provider-watchdog.plist"
WATCHDOG_LABEL="live.malibu.provider-watchdog"
LEGACY_WATCHDOG_PLIST_PATH="$LAUNCHD_MANAGED_DIR/live.streamvc.macprovider-watchdog.plist"
LEGACY_WATCHDOG_PLIST_BOOTSTRAP_PATH="$LAUNCHD_BOOTSTRAP_DIR/live.streamvc.macprovider-watchdog.plist"
LEGACY_WATCHDOG_LABEL="live.streamvc.macprovider-watchdog"
NO_WATCHDOG="${MACPROVIDER_NO_WATCHDOG:-0}"
DRY_RUN=0
NO_PROMPT="${MACPROVIDER_NO_PROMPT:-0}"
NO_LAUNCHD="${MACPROVIDER_NO_LAUNCHD:-0}"
EMERGENCY_ROLLBACK="${MACPROVIDER_EMERGENCY_ROLLBACK:-0}"
EMERGENCY_CONFIG_BACKUP="${MACPROVIDER_EMERGENCY_CONFIG_BACKUP:-}"
EMERGENCY_CONFIG_SHA256="${MACPROVIDER_EMERGENCY_CONFIG_SHA256:-}"
EMERGENCY_STAGED_CONFIG_SHA256=""
EMERGENCY_STAGED_CONFIG_TOKENLESS_SHA256=""
EMERGENCY_MODEL=""
ACCEPTANCE_METADATA_PATH=""
ACCEPTANCE_METADATA_SIGNATURE_PATH=""
TMPDIR_PATH=""
staging_dir=""
STAGED_CONFIG_PATH=""
STAGED_PROVIDER_ID_PATH=""
AUTOTUNE_BENCHMARK_PORT=""
AUTOTUNE_UPGRADE_CANDIDATE_MODEL_ID=""
AUTOTUNE_PREFETCH_RECEIPT_PATH=""
MACPROVIDER_CLI_EXECUTABLE="$INSTALL_DIR/macprovider-cli"
LIFECYCLE_STAGED_CLI_TRUSTED=0
LAUNCHD_INSTALLED=0
WATCHDOG_INSTALLED=0
MANUAL_PID=""
SKIP_PROVIDER_START=0
INSTALL_TX_ACTIVE=0
INSTALL_TX_COMMITTED=0
INSTALL_TX_BACKUP=""
INSTALL_TX_SERVICE_WAS_ACTIVE=0
INSTALL_TX_LEGACY_SERVICE_WAS_ACTIVE=0
INSTALL_TX_HAD_INSTALL_DIR=0
INSTALL_TX_HAD_BINARY_PATH=0
INSTALL_TX_HAD_CONFIG=0
INSTALL_TX_HAD_PROVIDER_ID=0
INSTALL_TX_HAD_RECOMMENDATION=0
INSTALL_TX_HAD_PLIST=0
INSTALL_TX_HAD_LEGACY_PLIST=0
INSTALL_TX_HAD_WATCHDOG_DIR=0
INSTALL_TX_HAD_WATCHDOG_PLIST=0
INSTALL_TX_HAD_LEGACY_WATCHDOG_PLIST=0
INSTALL_TX_HAD_MANIFEST=0
INSTALL_TX_HAD_LIFECYCLE_STATE=0
INSTALL_TX_SERVICE_WAS_DISABLED=0
INSTALL_TX_WATCHDOG_WAS_ACTIVE=0
INSTALL_TX_LEGACY_WATCHDOG_WAS_ACTIVE=0
INSTALL_TX_WATCHDOG_WAS_DISABLED=0
INSTALL_TX_ROLLING_BACK=0
INSTALL_TX_BINARY_KIND="symlink"
INSTALL_LOCK_HELD=0
INSTALL_LOCK_TOKEN=""
INSTALL_LOCK_HOLDER_PID=""
CUTOVER_STARTED=0
AUTOTUNE_RECOMMENDATION_REQUIRED=0
LIFECYCLE_INSTALL_OPERATION_ID="install:$$"

log() { printf "[macprovider-install] %s\n" "$*"; }
die() {
  code="$1"
  shift
  printf "[macprovider-install] ERROR: %s\n" "$*" >&2
  exit "$code"
}

validate_provider_token_environment() {
  if [ -n "${MACPROVIDER_PROVIDER_TOKEN:-}" ]; then
    unset MACPROVIDER_PROVIDER_TOKEN
    die 7 "MACPROVIDER_PROVIDER_TOKEN is not accepted by the installer; use tokenless bootstrap so credentials are minted directly into protected custody"
  fi
}

validate_launchd_mode() {
  case "$HEADLESS" in
    0) return 0 ;;
    1) ;;
    *) die 7 "MACPROVIDER_HEADLESS must be 0 or 1" ;;
  esac
  [ "$NO_LAUNCHD" != "1" ] \
    || die 7 "headless mode requires system LaunchDaemon installation; MACPROVIDER_NO_LAUNCHD=1 is not supported"
  [ "$NO_WATCHDOG" != "1" ] \
    || die 7 "headless mode requires the system watchdog LaunchDaemon; MACPROVIDER_NO_WATCHDOG=1 is not supported"
  if [ "$UID" -eq 0 ]; then
    detected_user="$HEADLESS_USER"
    [ -n "$detected_user" ] || detected_user="${SUDO_USER:-}"
    case "$detected_user" in
      ''|root|*[!A-Za-z0-9._-]*)
        die 7 "headless mode could not safely determine a non-root fleet user; set MACPROVIDER_HEADLESS_USER and invoke the installer as that account"
        ;;
      *)
        die 7 "headless mode detected fleet user '$detected_user', but must run as that account so protected data remains user-owned; rerun without sudo"
        ;;
    esac
  fi
  invoking_user="$(id -un)" \
    || die 7 "could not determine the invoking fleet user"
  [ -n "$HEADLESS_USER" ] || HEADLESS_USER="$invoking_user"
  case "$HEADLESS_USER" in
    ''|root|*[!A-Za-z0-9._-]*) die 7 "MACPROVIDER_HEADLESS_USER must name a non-root local account" ;;
  esac
  [ "$HEADLESS_USER" = "$invoking_user" ] \
    || die 7 "headless protected data must be installed by its owner; SSH as '$HEADLESS_USER' and rerun"
  id "$HEADLESS_USER" >/dev/null 2>&1 \
    || die 7 "MACPROVIDER_HEADLESS_USER does not identify a local account: $HEADLESS_USER"
  [ -x "$SUDO_BIN" ] \
    || die 7 "headless mode requires sudo for system launchd installation"
  [ -x "$ROOT_PYTHON3_BIN" ] \
    || die 7 "headless mode requires the trusted system interpreter at $ROOT_PYTHON3_BIN"
  "$SUDO_BIN" -n true >/dev/null 2>&1 \
    || die 7 "headless mode requires non-interactive sudo for system launchd installation and recovery"
}

validate_headless_install_topology() {
  if [ "$HEADLESS" != "1" ]; then
    for system_plist in \
      "${SYSTEM_LAUNCHD_DIR:-/Library/LaunchDaemons}/live.malibu.provider.plist" \
      "${SYSTEM_LAUNCHD_DIR:-/Library/LaunchDaemons}/live.streamvc.macprovider.plist" \
      "${SYSTEM_LAUNCHD_DIR:-/Library/LaunchDaemons}/live.malibu.provider-watchdog.plist" \
      "${SYSTEM_LAUNCHD_DIR:-/Library/LaunchDaemons}/live.streamvc.macprovider-watchdog.plist"; do
      [ ! -e "$system_plist" ] \
        || die 7 "consumer mode will not replace an existing headless LaunchDaemon install; remove or migrate $system_plist before retrying"
    done
    for system_target in \
      "system/live.malibu.provider" \
      "system/live.streamvc.macprovider" \
      "system/live.malibu.provider-watchdog" \
      "system/live.streamvc.macprovider-watchdog"; do
      require_launchd_service_absent "$system_target" \
        "consumer mode will not replace a loaded headless LaunchDaemon service"
    done
    return 0
  fi
  for consumer_plist in \
    "$HOME/Library/LaunchAgents/live.malibu.provider.plist" \
    "$HOME/Library/LaunchAgents/live.streamvc.macprovider.plist" \
    "$HOME/Library/LaunchAgents/live.malibu.provider-watchdog.plist" \
    "$HOME/Library/LaunchAgents/live.streamvc.macprovider-watchdog.plist" \
    "${LOCAL_USER_HOME_ROOT:-/Users}"/*/Library/LaunchAgents/live.malibu.provider.plist \
    "${LOCAL_USER_HOME_ROOT:-/Users}"/*/Library/LaunchAgents/live.streamvc.macprovider.plist \
    "${LOCAL_USER_HOME_ROOT:-/Users}"/*/Library/LaunchAgents/live.malibu.provider-watchdog.plist \
    "${LOCAL_USER_HOME_ROOT:-/Users}"/*/Library/LaunchAgents/live.streamvc.macprovider-watchdog.plist; do
    if [ -e "$consumer_plist" ]; then
      die 7 "headless mode will not replace an existing consumer LaunchAgent install; remove or migrate $consumer_plist before retrying"
    fi
  done
  for gui_target in \
    "gui/$UID/live.malibu.provider" \
    "gui/$UID/live.streamvc.macprovider" \
    "gui/$UID/live.malibu.provider-watchdog" \
    "gui/$UID/live.streamvc.macprovider-watchdog"; do
    require_launchd_service_absent "$gui_target" \
      "headless mode will not replace a loaded consumer LaunchAgent service"
  done
  for user_home in "${LOCAL_USER_HOME_ROOT:-/Users}"/*; do
    [ -d "$user_home" ] || continue
    user_uid="$(path_owner_uid "$user_home" || true)"
    case "$user_uid" in
      ''|0|"$UID") continue ;;
    esac
    for gui_target in \
      "gui/$user_uid/live.malibu.provider" \
      "gui/$user_uid/live.streamvc.macprovider" \
      "gui/$user_uid/live.malibu.provider-watchdog" \
      "gui/$user_uid/live.streamvc.macprovider-watchdog"; do
      require_launchd_service_absent "$gui_target" \
        "headless mode will not replace another user's loaded consumer LaunchAgent service"
    done
  done
}

path_owner_uid() {
  python3 - "$1" <<'PY'
import os
import sys

print(os.stat(sys.argv[1], follow_symlinks=False).st_uid)
PY
}

launchd_print_loaded() {
  target="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$target" "${LAUNCHCTL_BIN:-/bin/launchctl}" <<'PY'
import subprocess
import sys

target, launchctl = sys.argv[1:]
try:
    result = subprocess.run(
        [launchctl, "print", target],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=2,
        check=False,
    )
except (OSError, subprocess.TimeoutExpired):
    raise SystemExit(70)
if result.returncode == 0:
    raise SystemExit(0)
if result.returncode in {1, 3, 113}:
    raise SystemExit(1)
if result.returncode == 125 and target.startswith("gui/"):
    # On SSH-only Macs with no Aqua login session, launchd can report the
    # per-user GUI domain itself as unavailable. For a GUI LaunchAgent conflict
    # probe in headless mode, that is absence, not an indeterminate system state.
    raise SystemExit(1)
raise SystemExit(70)
PY
  else
    "${LAUNCHCTL_BIN:-/bin/launchctl}" print "$target" >/dev/null 2>&1
  fi
}

require_launchd_service_absent() {
  target="$1"
  message="$2"
  if launchd_print_loaded "$target"; then
    die 7 "$message: $target"
  else
    status="$?"
  fi
  [ "$status" -eq 1 ] \
    || die 7 "could not determine launchd service state for $target"
}

launchctl_service() {
  if [ "${HEADLESS:-0}" = "1" ]; then
    "${SUDO_BIN:-/usr/bin/sudo}" -n "${LAUNCHCTL_BIN:-/bin/launchctl}" "$@"
  else
    launchctl "$@"
  fi
}

validate_headless_launchdaemon_plist() {
  plist_path="$1"
  bootstrap_path="$2"
  expected_label="$3"
  expected_program="$4"
  [ "$HEADLESS" = "1" ] || return 0
  python3 - "$plist_path" "$bootstrap_path" "$HEADLESS_USER" \
    "$expected_label" "$expected_program" "$CONFIG_PATH" \
    "${LAUNCHD_BOOTSTRAP_DIR:-/Library/LaunchDaemons}" \
    "${HEADLESS_WATCHDOG_LOG_DIR:-/Library/Logs/macprovider}" \
    "${HEADLESS_WATCHDOG_STATE_DIR:-/Library/Application Support/macprovider/watchdog-state}" <<'PY'
import os
import plistlib
import sys

path, bootstrap, user, label, program, config, bootstrap_dir, watchdog_log_dir, watchdog_state_dir = sys.argv[1:]
if bootstrap != f"{bootstrap_dir}/{label}.plist":
    raise SystemExit("unexpected LaunchDaemon target")
with open(path, "rb") as handle:
    payload = plistlib.load(handle)
arguments = payload.get("ProgramArguments")
environment = payload.get("EnvironmentVariables")
if payload.get("Label") != label:
    raise SystemExit("unexpected LaunchDaemon identity")
if not isinstance(arguments, list) or not arguments or arguments[0] != program:
    raise SystemExit("unexpected LaunchDaemon program")
if label == "live.malibu.provider":
    if payload.get("UserName") != user:
        raise SystemExit("unexpected provider LaunchDaemon user")
    if arguments != [program, "serve", "--config", config]:
        raise SystemExit("unexpected provider LaunchDaemon arguments")
    if payload.get("KeepAlive") is not True:
        raise SystemExit("unexpected provider LaunchDaemon KeepAlive")
elif label == "live.malibu.provider-watchdog":
    if "UserName" in payload:
        raise SystemExit("watchdog LaunchDaemon must remain root-owned")
    if arguments != [program]:
        raise SystemExit("unexpected watchdog LaunchDaemon arguments")
if not isinstance(environment, dict):
    raise SystemExit("missing LaunchDaemon environment")
if environment.get("MACPROVIDER_HEADLESS") != "1":
    raise SystemExit("missing headless mode")
if environment.get("MACPROVIDER_HEADLESS_USER") != user:
    raise SystemExit("unexpected headless user")
if environment.get("MACPROVIDER_LAUNCHD_DOMAIN") != "system":
    raise SystemExit("unexpected launchd domain")
if environment.get("MACPROVIDER_PROTECTED_CREDENTIAL_ROOT") != os.path.join(os.path.dirname(config), "protected-credentials"):
    raise SystemExit("unexpected protected credential root")
if label == "live.malibu.provider-watchdog" and environment.get("MACPROVIDER_LAUNCHCTL") != "/bin/launchctl":
    raise SystemExit("unexpected watchdog launchctl path")
if label == "live.malibu.provider-watchdog" and environment.get("MACPROVIDER_LOG_DIR") != watchdog_log_dir:
    raise SystemExit("unexpected watchdog log dir")
if label == "live.malibu.provider-watchdog" and environment.get("MACPROVIDER_WATCHDOG_STATE_DIR") != watchdog_state_dir:
    raise SystemExit("unexpected watchdog state dir")
PY
}

snapshot_headless_launchdaemon_plist() {
  plist_path="$1"
  bootstrap_path="$2"
  expected_label="$3"
  expected_program="$4"
  [ "$HEADLESS" = "1" ] || return 0
  python3 - "$plist_path" "$bootstrap_path" "$HEADLESS_USER" \
    "$expected_label" "$expected_program" "$CONFIG_PATH" \
    "${LAUNCHD_BOOTSTRAP_DIR:-/Library/LaunchDaemons}" <<'PY'
import base64
import os
import plistlib
import stat
import sys

path, bootstrap, user, label, program, config, bootstrap_dir = sys.argv[1:]
if bootstrap != f"{bootstrap_dir}/{label}.plist":
    raise SystemExit("unexpected LaunchDaemon target")
fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0))
try:
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        raise SystemExit("unsafe LaunchDaemon source")
    data = os.read(fd, 1048577)
    if len(data) > 1048576:
        raise SystemExit("LaunchDaemon source too large")
finally:
    os.close(fd)
payload = plistlib.loads(data)
arguments = payload.get("ProgramArguments")
environment = payload.get("EnvironmentVariables")
if payload.get("Label") != label:
    raise SystemExit("unexpected LaunchDaemon identity")
if not isinstance(arguments, list) or not arguments or arguments[0] != program:
    raise SystemExit("unexpected LaunchDaemon program")
if label == "live.malibu.provider":
    if payload.get("UserName") != user:
        raise SystemExit("unexpected provider LaunchDaemon user")
    if arguments != [program, "serve", "--config", config]:
        raise SystemExit("unexpected provider LaunchDaemon arguments")
    if payload.get("KeepAlive") is not True:
        raise SystemExit("unexpected provider LaunchDaemon KeepAlive")
elif label == "live.malibu.provider-watchdog":
    if "UserName" in payload:
        raise SystemExit("watchdog LaunchDaemon must remain root-owned")
    if arguments != [program]:
        raise SystemExit("unexpected watchdog LaunchDaemon arguments")
if not isinstance(environment, dict):
    raise SystemExit("missing LaunchDaemon environment")
if environment.get("MACPROVIDER_HEADLESS") != "1":
    raise SystemExit("missing headless mode")
if environment.get("MACPROVIDER_HEADLESS_USER") != user:
    raise SystemExit("unexpected headless user")
if environment.get("MACPROVIDER_LAUNCHD_DOMAIN") != "system":
    raise SystemExit("unexpected launchd domain")
if environment.get("MACPROVIDER_PROTECTED_CREDENTIAL_ROOT") != os.path.join(os.path.dirname(config), "protected-credentials"):
    raise SystemExit("unexpected protected credential root")
if label == "live.malibu.provider-watchdog" and environment.get("MACPROVIDER_LAUNCHCTL") != "/bin/launchctl":
    raise SystemExit("unexpected watchdog launchctl path")
sys.stdout.write(base64.b64encode(data).decode("ascii"))
PY
}

publish_root_file_from_base64() {
  target_path="$1"
  mode="$2"
  payload_b64="$3"
  MACPROVIDER_ROOT_FILE_B64="$payload_b64" \
    "${SUDO_BIN:-/usr/bin/sudo}" -n "${ROOT_PYTHON3_BIN:-/usr/bin/python3}" - "$target_path" "$mode" <<'PY'
import base64
import os
import sys
import uuid

target = sys.argv[1]
mode = int(sys.argv[2], 8)
payload = base64.b64decode(os.environ["MACPROVIDER_ROOT_FILE_B64"], validate=True)
directory = os.path.dirname(target)
temporary = os.path.join(directory, f".{os.path.basename(target)}.{uuid.uuid4()}.tmp")
fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), mode)
try:
    written = 0
    while written < len(payload):
        progress = os.write(fd, payload[written:])
        if progress <= 0:
            raise RuntimeError("short write while publishing root file")
        written += progress
    os.fchmod(fd, mode)
    if os.geteuid() == 0:
        os.fchown(fd, 0, 0)
    os.fsync(fd)
finally:
    os.close(fd)
os.replace(temporary, target)
dir_fd = os.open(directory, os.O_RDONLY)
try:
    os.fsync(dir_fd)
finally:
    os.close(dir_fd)
PY
}

verify_published_launchd_payload() {
  bootstrap_path="$1"
  expected_b64="$2"
  [ "$HEADLESS" = "1" ] || return 0
  published_b64="$("${SUDO_BIN:-/usr/bin/sudo}" -n "${ROOT_PYTHON3_BIN:-/usr/bin/python3}" - "$bootstrap_path" <<'PY'
import base64
import os
import sys

path = sys.argv[1]
with open(path, "rb") as handle:
    sys.stdout.write(base64.b64encode(handle.read()).decode("ascii"))
PY
)" || return 70
  [ "$published_b64" = "$expected_b64" ]
}

publish_launchd_plist() {
  source_path="$1"
  bootstrap_path="$2"
  expected_label="${3:-}"
  expected_program="${4:-}"
  if [ "${HEADLESS:-0}" = "1" ]; then
    validate_headless_launchdaemon_plist "$source_path" "$bootstrap_path" \
      "$expected_label" "$expected_program" || return 70
    plist_payload_b64="$(snapshot_headless_launchdaemon_plist "$source_path" "$bootstrap_path" \
      "$expected_label" "$expected_program")" || return 70
    publish_root_file_from_base64 "$bootstrap_path" 0644 "$plist_payload_b64" || return 70
    if ! verify_published_launchd_payload "$bootstrap_path" "$plist_payload_b64" \
      || ! validate_headless_launchdaemon_plist "$bootstrap_path" "$bootstrap_path" \
        "$expected_label" "$expected_program"; then
      "${SUDO_BIN:-/usr/bin/sudo}" -n /bin/rm -f "$bootstrap_path" >/dev/null 2>&1 || true
      return 70
    fi
  elif [ "$source_path" != "$bootstrap_path" ]; then
    cp "$source_path" "$bootstrap_path"
  fi
}

publish_headless_recovery_trust() {
  recovery_dir="$1"
  [ "$HEADLESS" = "1" ] || return 0
  trust_staging="$CONFIG_DIR/.install-recovery-trust.$$"
  {
    printf '%s\n' "$recovery_dir"
    shasum -a 256 "$recovery_dir/state.sh" | awk '{print $1}'
    shasum -a 256 "$recovery_dir/recover.sh" | awk '{print $1}'
  } | write_atomic_install_file "$trust_staging" 0600 || return 70
  "${SUDO_BIN:-/usr/bin/sudo}" -n /bin/mkdir -p "$(dirname "$HEADLESS_RECOVERY_TRUST_PATH")" || return 70
  trust_payload_b64="$(python3 - "$trust_staging" <<'PY'
import base64
import sys

with open(sys.argv[1], "rb") as handle:
    sys.stdout.write(base64.b64encode(handle.read()).decode("ascii"))
PY
)" || return 70
  publish_root_file_from_base64 "$HEADLESS_RECOVERY_TRUST_PATH" 0600 "$trust_payload_b64" || return 70
  rm -f "$trust_staging" || return 70
  verify_headless_recovery_trust "$recovery_dir" || return 70
}

verify_headless_recovery_trust() {
  recovery_dir="$1"
  [ "$HEADLESS" = "1" ] || return 0
  trust_payload="$("${SUDO_BIN:-/usr/bin/sudo}" -n /bin/cat "$HEADLESS_RECOVERY_TRUST_PATH" 2>/dev/null)" || return 70
  expected_dir="$(printf '%s\n' "$trust_payload" | sed -n '1p')"
  expected_state_sha="$(printf '%s\n' "$trust_payload" | sed -n '2p')"
  expected_recover_sha="$(printf '%s\n' "$trust_payload" | sed -n '3p')"
  [ "$(printf '%s\n' "$trust_payload" | awk 'END { print NR }')" -eq 3 ] || return 70
  [ "$expected_dir" = "$recovery_dir" ] || return 70
  [ "$expected_state_sha" = "$(shasum -a 256 "$recovery_dir/state.sh" | awk '{print $1}')" ] || return 70
  [ "$expected_recover_sha" = "$(shasum -a 256 "$recovery_dir/recover.sh" | awk '{print $1}')" ] || return 70
}

retire_headless_recovery_trust() {
  [ "$HEADLESS" = "1" ] || return 0
  "${SUDO_BIN:-/usr/bin/sudo}" -n /bin/rm -f "$HEADLESS_RECOVERY_TRUST_PATH"
}

verify_published_launchd_plist() {
  source_path="$1"
  bootstrap_path="$2"
  [ "$HEADLESS" = "1" ] || return 0
  "${SUDO_BIN:-/usr/bin/sudo}" -n /usr/bin/python3 - "$source_path" "$bootstrap_path" "$(id -u)" <<'PY'
import ctypes
import errno
import os
import stat
import sys

source_path, bootstrap_path, source_uid_text = sys.argv[1:]
source_uid = int(source_uid_text)
max_bytes = 1024 * 1024
nofollow = getattr(os, "O_NOFOLLOW", 0)
nonblock = getattr(os, "O_NONBLOCK", 0)


def no_acl(fd):
    if sys.platform != "darwin":
        return True
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        acl_get_fd_np = libc.acl_get_fd_np
        acl_get_fd_np.argtypes = [ctypes.c_int, ctypes.c_int]
        acl_get_fd_np.restype = ctypes.c_void_p
        acl_free = libc.acl_free
        acl_free.argtypes = [ctypes.c_void_p]
        acl_free.restype = ctypes.c_int
    except (AttributeError, OSError):
        return False
    ctypes.set_errno(0)
    acl = acl_get_fd_np(fd, 0x00000100)  # ACL_TYPE_EXTENDED
    if acl:
        acl_free(acl)
        return False
    return ctypes.get_errno() in (0, errno.ENOENT)


def expected_bootstrap_uid(path):
    if path.startswith("/Library/LaunchDaemons/"):
        return 0
    return source_uid


def read_checked(path, expected_uid):
    try:
        fd = os.open(path, os.O_RDONLY | nonblock | nofollow)
    except OSError:
        raise SystemExit(1)
    try:
        before = os.fstat(fd)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_uid != expected_uid
            or before.st_nlink != 1
            or before.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
            or before.st_size < 0
            or before.st_size > max_bytes
            or not no_acl(fd)
        ):
            raise SystemExit(1)
        payload = bytearray()
        while len(payload) < before.st_size:
            chunk = os.read(fd, min(65536, before.st_size - len(payload)))
            if not chunk:
                raise SystemExit(1)
            payload.extend(chunk)
        after = os.fstat(fd)
        path_info = os.lstat(path)
        if (
            (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns)
            != (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns)
            or stat.S_ISLNK(path_info.st_mode)
            or (path_info.st_dev, path_info.st_ino) != (before.st_dev, before.st_ino)
        ):
            raise SystemExit(1)
        return bytes(payload)
    finally:
        os.close(fd)


source = read_checked(source_path, source_uid)
bootstrap = read_checked(bootstrap_path, expected_bootstrap_uid(bootstrap_path))
if source != bootstrap:
    raise SystemExit(1)
PY
}

record_lifecycle_state() {
  local lifecycle_state="$1"
  local lifecycle_reason="$2"
  local lifecycle_cli="$BINARY_PATH"
  [ "$DRY_RUN" -eq 0 ] || return 0
  if [ "${LIFECYCLE_STAGED_CLI_TRUSTED:-0}" -eq 1 ] \
    && [ -x "${MACPROVIDER_CLI_EXECUTABLE:-}" ]; then
    lifecycle_cli="$MACPROVIDER_CLI_EXECUTABLE"
  fi
  [ -x "$lifecycle_cli" ] || return 1
  local lifecycle_args=(
    lifecycle-state transition
    --state "$lifecycle_state"
    --reason-code "$lifecycle_reason"
    --writer installer
    --operation-id "$LIFECYCLE_INSTALL_OPERATION_ID"
  )
  [ -z "${provider_id:-}" ] || lifecycle_args+=(--provider-id "$provider_id")
  [ -z "${model:-}" ] || lifecycle_args+=(--model-id "$model")
  local lifecycle_rc=0
  if command -v python3 >/dev/null 2>&1; then
    if python3 - "$lifecycle_cli" "${lifecycle_args[@]}" >/dev/null <<'PY'
import subprocess
import sys

command = [sys.argv[1], *sys.argv[2:]]
try:
    result = subprocess.run(
        command,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=5,
        check=False,
    )
except (OSError, subprocess.TimeoutExpired):
    raise SystemExit(124)
raise SystemExit(result.returncode)
PY
    then
      return 0
    else
      lifecycle_rc=$?
    fi
  elif "$lifecycle_cli" "${lifecycle_args[@]}" >/dev/null; then
    return 0
  else
    lifecycle_rc=$?
  fi
  if [ "${EMERGENCY_ROLLBACK:-0}" = "1" ]; then
    log "Emergency target predates the lifecycle-state contract; rollback remains protected by the install transaction."
    return 0
  fi
  [ "$lifecycle_rc" -ne 124 ] || log "Lifecycle-state writer timed out; rollback remains protected by the install transaction."
  return 1
}

validate_install_dir() {
validated="$({ python3 - "$INSTALL_DIR" "$HOME" "${REPAIR_EXISTING_INSTALL:-0}" <<'PY'
import os
import stat
import sys
import ctypes
import errno
import ctypes
import errno
import grp
import re

raw, raw_home, repair_raw = sys.argv[1:]
if not raw.startswith("/"):
    raise SystemExit("install directory must be absolute")
if any(part in {".", ".."} for part in raw.split("/")):
    raise SystemExit("install directory must not contain traversal components")

home = os.path.normpath(raw_home)
target = os.path.normpath(raw)
repair_mode = repair_raw == "1"
if target == home:
    raise SystemExit("install directory must not be HOME itself")
try:
    if os.path.commonpath([home, target]) != home:
        raise SystemExit("install directory must be inside HOME")
except ValueError:
    raise SystemExit("install directory must be inside HOME")

uid = os.getuid()
uuid_pattern = re.compile(
    r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-"
    r"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
)

def repair_home_write_acl(fields, path, everyone_gid, allow_home_acl_write=False):
    if not repair_mode or os.path.normpath(path) != home:
        return False
    if (
        len(fields) != 6
        or fields[0] != "group"
        or not uuid_pattern.fullmatch(fields[1])
        or fields[2] != "everyone"
        or fields[3] != str(everyone_gid)
        or fields[4] != "allow"
    ):
        return False
    permissions = set(filter(None, fields[5].split(",")))
    return permissions == {"write", "append"}

def safe_directory_acl(path):
    if sys.platform != "darwin":
        return True
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        acl_get_fd_np = libc.acl_get_fd_np
        acl_get_fd_np.argtypes = [ctypes.c_int, ctypes.c_int]
        acl_get_fd_np.restype = ctypes.c_void_p
        acl_to_text = libc.acl_to_text
        acl_to_text.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_long)]
        acl_to_text.restype = ctypes.c_void_p
        acl_free = libc.acl_free
        acl_free.argtypes = [ctypes.c_void_p]
        acl_free.restype = ctypes.c_int
    except (AttributeError, OSError):
        return False

    directory_fd = os.open(
        path,
        os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0),
    )
    try:
        ctypes.set_errno(0)
        acl = acl_get_fd_np(directory_fd, 0x00000100)  # ACL_TYPE_EXTENDED
        if not acl:
            return ctypes.get_errno() in (0, errno.ENOENT)
        try:
            text_length = ctypes.c_long()
            text_pointer = acl_to_text(acl, ctypes.byref(text_length))
            if not text_pointer:
                return False
            try:
                lines = ctypes.string_at(text_pointer, text_length.value).decode(
                    "utf-8", errors="strict"
                ).splitlines()
            finally:
                acl_free(text_pointer)

            everyone_gid = grp.getgrnam("everyone").gr_gid
            if len(lines) < 2 or lines[0] != "!#acl 1":
                return False
            for line in lines[1:]:
                fields = line.split(":")
                if repair_home_write_acl(fields, path, everyone_gid):
                    continue
                if (
                    len(fields) != 6
                    or fields[0] != "group"
                    or not uuid_pattern.fullmatch(fields[1])
                    or fields[2] != "everyone"
                    or fields[3] != str(everyone_gid)
                    or fields[4] != "deny"
                    or fields[5] != "delete"
                ):
                    return False
            return True
        finally:
            acl_free(acl)
    finally:
        os.close(directory_fd)

current = home
relative = os.path.relpath(target, home)
for component in ["."] + relative.split(os.sep):
    if component != ".":
        current = os.path.join(current, component)
    if not os.path.lexists(current):
        continue
    info = os.lstat(current)
    if stat.S_ISLNK(info.st_mode):
        raise SystemExit(f"install path contains symlink component: {current}")
    if not stat.S_ISDIR(info.st_mode):
        raise SystemExit(f"install path component is not a directory: {current}")
    if info.st_uid != uid:
        raise SystemExit(f"install path component is not owned by the installing user: {current}")
    if info.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        raise SystemExit(f"install path component is group/world-writable: {current}")
    if not safe_directory_acl(current):
        raise SystemExit(f"install path component has an unsafe ACL: {current}")

print(target)
PY
  } 2>&1)" || die 7 "unsafe MACPROVIDER_INSTALL_DIR: $validated"
  INSTALL_DIR="$validated"
}

remediate_repair_home_write_acl() {
  [ "${REPAIR_EXISTING_INSTALL:-0}" -eq 1 ] || return 0
  acl_status="$({ python3 - "$HOME" <<'PY'
import ctypes
import errno
import grp
import os
import re
import sys

home = os.path.normpath(sys.argv[1])
if sys.platform != "darwin":
    print("absent")
    raise SystemExit(0)

uuid_pattern = re.compile(
    r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-"
    r"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
)

def exact_home_write_acl(fields, everyone_gid):
    if (
        len(fields) != 6
        or fields[0] != "group"
        or not uuid_pattern.fullmatch(fields[1])
        or fields[2] != "everyone"
        or fields[3] != str(everyone_gid)
        or fields[4] != "allow"
    ):
        return False
    permissions = set(filter(None, fields[5].split(",")))
    return permissions == {"write", "append"}

def safe_deny_delete_acl(fields, everyone_gid):
    return (
        len(fields) == 6
        and fields[0] == "group"
        and bool(uuid_pattern.fullmatch(fields[1]))
        and fields[2] == "everyone"
        and fields[3] == str(everyone_gid)
        and fields[4] == "deny"
        and fields[5] == "delete"
    )

try:
    libc = ctypes.CDLL(None, use_errno=True)
    acl_get_fd_np = libc.acl_get_fd_np
    acl_get_fd_np.argtypes = [ctypes.c_int, ctypes.c_int]
    acl_get_fd_np.restype = ctypes.c_void_p
    acl_to_text = libc.acl_to_text
    acl_to_text.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_long)]
    acl_to_text.restype = ctypes.c_void_p
    acl_free = libc.acl_free
    acl_free.argtypes = [ctypes.c_void_p]
    acl_free.restype = ctypes.c_int
except (AttributeError, OSError):
    raise SystemExit("acl inspection unavailable")

directory_fd = os.open(home, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0))
try:
    ctypes.set_errno(0)
    acl = acl_get_fd_np(directory_fd, 0x00000100)  # ACL_TYPE_EXTENDED
    if not acl:
        if ctypes.get_errno() in (0, errno.ENOENT):
            print("absent")
            raise SystemExit(0)
        raise SystemExit("acl inspection failed")
    try:
        text_length = ctypes.c_long()
        text_pointer = acl_to_text(acl, ctypes.byref(text_length))
        if not text_pointer:
            raise SystemExit("acl inspection failed")
        try:
            lines = ctypes.string_at(text_pointer, text_length.value).decode(
                "utf-8", errors="strict"
            ).splitlines()
        finally:
            acl_free(text_pointer)
        everyone_gid = grp.getgrnam("everyone").gr_gid
        if len(lines) < 2 or lines[0] != "!#acl 1":
            raise SystemExit("acl inspection failed")
        matches = 0
        for line in lines[1:]:
            fields = line.split(":")
            if exact_home_write_acl(fields, everyone_gid):
                matches += 1
                continue
            if safe_deny_delete_acl(fields, everyone_gid):
                continue
            raise SystemExit("unexpected HOME ACL shape")
        print("remove" if matches else "absent")
    finally:
        acl_free(acl)
finally:
    os.close(directory_fd)
PY
  } 2>&1)" || die 70 "could not inspect repair HOME ACL"
  [ "$acl_status" = "remove" ] || return 0
  /bin/chmod -a "group:everyone allow add_file,add_subdirectory" "$HOME" \
    || die 70 "could not remove repair HOME ACL barrier"
  log "Repair preflight: removed the known HOME ACL barrier before provider directory mutation."
  old_repair_mode="$REPAIR_EXISTING_INSTALL"
  REPAIR_EXISTING_INSTALL=0
  validate_install_dir
  REPAIR_EXISTING_INSTALL="$old_repair_mode"
}

validate_port_value() {
  value="$1"
  case "$value" in
    ''|*[!0-9]*) die 7 "port must be numeric in [1024, 65535] (got: $value)" ;;
  esac
  if [ "$value" -lt 1024 ] || [ "$value" -gt 65535 ]; then
    die 7 "port must be in [1024, 65535] (got: $value)"
  fi
}

# Replace a provider executable through a fresh inode in the target directory.
# Copying directly over a path that macOS has already executed can retain a
# stale AMFI/code-signing cache for that vnode and make the newly installed,
# otherwise-valid binary die with SIGKILL. Keeping the temporary file beside
# the target also makes the final rename atomic.
atomic_replace_provider_binary() {
  local source="$1"
  local target="$2"
  local rc=0
  python3 - "$source" "$target" <<'PY' 2>/dev/null || rc=$?
import os
import stat
import sys
import tempfile

source, target = sys.argv[1:]
target_directory = os.path.dirname(target) or "."
temporary_fd = -1
temporary = ""
replaced = False

try:
    source_fd = os.open(source, os.O_RDONLY | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_NOFOLLOW", 0))
    try:
        source_info = os.fstat(source_fd)
        if not stat.S_ISREG(source_info.st_mode):
            raise RuntimeError("provider_binary_source_not_regular")
        temporary_fd, temporary = tempfile.mkstemp(
            prefix=".macprovider-cli.install.",
            dir=target_directory,
        )
        while True:
            chunk = os.read(source_fd, 1024 * 1024)
            if not chunk:
                break
            offset = 0
            while offset < len(chunk):
                written = os.write(temporary_fd, chunk[offset:])
                if written <= 0:
                    raise RuntimeError("provider_binary_write_failed")
                offset += written
        os.fchmod(temporary_fd, 0o755)
        os.fsync(temporary_fd)
    finally:
        os.close(source_fd)
        if temporary_fd >= 0:
            os.close(temporary_fd)
            temporary_fd = -1

    if os.path.isdir(target):
        raise RuntimeError("provider_binary_target_is_directory")
    os.replace(temporary, target)
    temporary = ""
    replaced = True
    directory_fd = os.open(target_directory, os.O_RDONLY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)
except Exception:
    if replaced:
        raise SystemExit(10)
    raise
finally:
    if temporary_fd >= 0:
        os.close(temporary_fd)
    if temporary:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
PY
  if [ "$rc" -eq 0 ]; then
    return 0
  fi
  if [ "$rc" -eq 10 ]; then
    log "binary activation: replacement occurred but directory durability could not be confirmed for $target; transaction rollback remains armed" >&2
    return 10
  fi
  log "binary activation: durable atomic replacement failed for $target; the prior target was left in place" >&2
  return 1
}

# Retry macprovider-cli up to two additional times if the first
# post-install invocation is SIGKILL'd by the kernel with a CODESIGNING
# "Invalid Page" / "Taskgated Invalid Signature" verdict. Two failure
# flavors have been observed:
#
#   FLAVOR 1 — Transient AMFI race. Observed 2026-07-03 on Apple M5
#     macOS 26.5 with a freshly-installed v1.7.9 pkg: `autotune
#     --recommend --freshness-check` was reported "Killed: 9" (bash
#     exit 137) on the FIRST invocation right after `installer -pkg`,
#     and the immediately-repeated invocation of the SAME command by
#     the SAME shell succeeded. This is a race between the pkg
#     installer's post-install AMFI signature revalidation and our
#     first execve; the 2s sleep is sufficient to let AMFI settle.
#
#   FLAVOR 2 — AMFI cache pinned to the pkg-installer inode. Observed
#     2026-07-03 on the same M5 during the v1.7.10 install: BOTH the
#     first invocation AND the 2s-later retry were SIGKILL'd, but the
#     binary's `codesign --verify --deep --strict` passed cleanly and
#     the SAME binary content ran fine when copied to a different
#     path. The AMFI kernel cache had a stuck rejection tied to the
#     specific inode that `installer -pkg` created. The fix is to stage
#     identical bytes beside the target and atomically rename the fresh inode
#     into place, which forces AMFI to re-evaluate without a missing-path gap.
#     See PR #339 for the reproduction and root cause.
#
# The helper's escalation ladder for bash rc 137:
#   attempt 1: run
#     └── 137 → log + sleep 2 + attempt 2 (FLAVOR 1 fix)
#         └── 137 → log + atomic fresh-inode replacement + attempt 3
#             │           (FLAVOR 2 fix)
#             └── 137 → log "genuine signature failure" + return 137
# Any non-137 rc anywhere in the ladder returns immediately.
#
# Only SIGKILL / bash rc 137 is retried — other non-zero exits
# (including autotune's exit-10 "stale recommendation" signal, and
# other signal-terminated codes such as 134 SIGABRT / 138 SIGBUS /
# 139 SIGSEGV) pass through unchanged so we do not mask real crashes.
#
# This helper MUST be called from `if run_..._retry ...; then` or
# `run_..._retry ... || ...` so that `set -e` (enabled at the top of
# this script) does not fire on the pass-through non-zero return.
#
# Diagnostic lines are written to stderr so they remain visible even
# when callers redirect the helper's stdout to `/dev/null` (as the
# freshness-check call site does).
run_macprovider_cli_with_amfi_retry() {
  local rc=0
  local cli_path="$MACPROVIDER_CLI_EXECUTABLE"
  if [ "${HEADLESS:-0}" = "1" ]; then
    MACPROVIDER_PROTECTED_CREDENTIAL_ROOT="$CONFIG_DIR/protected-credentials" \
      "$cli_path" "$@" || rc=$?
  else
    "$cli_path" "$@" || rc=$?
  fi
  if [ "$rc" -ne 137 ]; then
    return "$rc"
  fi
  log "macprovider-cli was SIGKILL'd on first invocation (rc=$rc); likely a transient AMFI code-signature race after pkg install. Retrying once after 2s." >&2
  sleep 2
  rc=0
  if [ "${HEADLESS:-0}" = "1" ]; then
    MACPROVIDER_PROTECTED_CREDENTIAL_ROOT="$CONFIG_DIR/protected-credentials" \
      "$cli_path" "$@" || rc=$?
  else
    "$cli_path" "$@" || rc=$?
  fi
  if [ "$rc" -ne 137 ]; then
    return "$rc"
  fi
  log "macprovider-cli was SIGKILL'd again on the 2s retry; the AMFI cache may be pinned to the pkg-installer inode. Refreshing the binary inode via an atomic same-directory replacement and retrying once more." >&2
  local replacement_rc=0
  atomic_replace_provider_binary "$cli_path" "$cli_path" || replacement_rc=$?
  if [ "$replacement_rc" -ne 0 ]; then
    if [ "$replacement_rc" -eq 10 ]; then
      log "inode refresh: replacement occurred but directory durability was unconfirmed; transaction recovery remains armed." >&2
      return "$rc"
    fi
    log "inode refresh: atomic same-bytes replacement failed; leaving the original binary in place." >&2
    return "$rc"
  fi
  rc=0
  if [ "${HEADLESS:-0}" = "1" ]; then
    MACPROVIDER_PROTECTED_CREDENTIAL_ROOT="$CONFIG_DIR/protected-credentials" \
      "$cli_path" "$@" || rc=$?
  else
    "$cli_path" "$@" || rc=$?
  fi
  if [ "$rc" -eq 137 ]; then
    log "macprovider-cli was SIGKILL'd after the inode refresh; this is likely a genuine signature failure rather than the AMFI cache." >&2
  fi
  return "$rc"
}

detect_existing_port() {
  if [ -f "$CONFIG_PATH" ]; then
    awk -F: '/^port:/ {gsub(/ /, "", $2); print $2; exit}' "$CONFIG_PATH" 2>/dev/null
  fi
}

# F-603-V7-1: upgrade-in-place must preserve the prior configured port
# unless the operator explicitly overrides it. Otherwise existing installs
# on 18080 regress to the default 8080 and collide with unrelated services.
if [ -n "${MACPROVIDER_PORT:-}" ]; then
  PORT="$MACPROVIDER_PORT"
elif EXISTING_PORT="$(detect_existing_port)" && [ -n "$EXISTING_PORT" ]; then
  PORT="$EXISTING_PORT"
  log "Detected existing config port: $PORT (override with MACPROVIDER_PORT=N)"
else
  PORT="8080"
fi

usage() {
  cat <<'USAGE'
Usage: bash install.sh [--dry-run]

Environment overrides:
  MACPROVIDER_GITHUB_REPO        owner/repo for GitHub Releases
  MACPROVIDER_VERSION            pin installer to vMAJOR.MINOR.PATCH
                                 (pipe-side form: curl ... | MACPROVIDER_VERSION=v1.7.11 bash)
  MACPROVIDER_ACCEPTANCE_ASSET_DIR
                                 absolute owner-only directory containing a
                                 protected, non-public signed candidate; requires
                                 all exact acceptance identity pins below and
                                 never contacts Releases
  MACPROVIDER_ACCEPTANCE_COMMIT exact 40-hex candidate commit
  MACPROVIDER_ACCEPTANCE_CONTROL_COMMIT
                                 exact 40-hex trusted-main signer commit
  MACPROVIDER_ACCEPTANCE_RUN_ID exact GitHub Actions run id
  MACPROVIDER_ACCEPTANCE_RUN_ATTEMPT
                                 exact positive GitHub Actions run attempt
  MACPROVIDER_COORDINATOR_URL    coordinator WebSocket URL
  MACPROVIDER_PORT               local HTTP port
  MACPROVIDER_INSTALL_DIR        support dir for binary + bundles
  MACPROVIDER_RELEASE_FORMAT     auto, pkg, or tar (default: auto)
  MACPROVIDER_NO_PROMPT=1        use defaults without interactive prompts
  MACPROVIDER_HEADLESS=1         explicit SSH-only fleet mode; installs the
                                 provider and watchdog in launchd's system domain
  MACPROVIDER_HEADLESS_USER      named non-root account that owns protected
                                 provider data and runs both LaunchDaemons;
                                 defaults to the invoking non-root account
  MACPROVIDER_NO_LAUNCHD=1       expert/debug only: skip BOTH the provider
                                 launchd service and its companion watchdog
  MACPROVIDER_NO_WATCHDOG=1      expert/debug only: install the provider
                                 launchd service but skip the watchdog
  MACPROVIDER_REFERRAL_REPLACE_INCUMBENT=1
                                 explicit Malibu fresh-provider replacement:
                                 redeem the invite against a new provider
                                 identity; incumbent files and config remain
                                 unchanged until cutover, and rollback restores
                                 them if replacement admission fails
  MACPROVIDER_EMERGENCY_ROLLBACK=1
                                 operator-only signed rollback to an explicit
                                 MACPROVIDER_VERSION; commits only through an
                                 active legacy_bridge admission
  MACPROVIDER_SKIP_HF_CHECK=1    skip HuggingFace lookup on custom model id
USAGE
}

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die 7 "unknown argument: $arg" ;;
  esac
done

release_install_lock() {
  [ "$INSTALL_LOCK_HELD" -eq 1 ] || return 0
  case "$INSTALL_LOCK_HOLDER_PID" in
    ''|*[!0-9]*) return 70 ;;
  esac
  kill -TERM "$INSTALL_LOCK_HOLDER_PID" >/dev/null 2>&1 || true
  wait "$INSTALL_LOCK_HOLDER_PID" >/dev/null 2>&1 || true
  INSTALL_LOCK_HELD=0
  INSTALL_LOCK_TOKEN=""
  INSTALL_LOCK_HOLDER_PID=""
}

assert_install_lock_ownership() {
  [ "$DRY_RUN" -eq 0 ] || return 0
  [ "$INSTALL_LOCK_HELD" -eq 1 ] \
    || die 70 "installer lock is not held; refusing protected install mutation"
  case "$INSTALL_LOCK_HOLDER_PID" in
    ''|*[!0-9]*) die 70 "installer lock helper identity is invalid; refusing protected install mutation" ;;
  esac
  [ -n "$INSTALL_LOCK_TOKEN" ] \
    || die 70 "installer lock token is missing; refusing protected install mutation"
  python3 - "$HOME" "$CONFIG_DIR" "$INSTALL_LOCK_PATH" "$PROVIDER_MUTATION_ROOT" \
    "$PROVIDER_MUTATION_LOCK_PATH" "$$" "$INSTALL_LOCK_TOKEN" "$INSTALL_LOCK_HOLDER_PID" <<'PY' \
    || die 70 "installer lock ownership was lost; refusing protected install mutation"
import fcntl
import ctypes
import json
import os
import stat
import subprocess
import sys

home, config_dir, lock_path, mutation_root, mutation_lock_path, owner_pid_text, token, holder_pid_text = sys.argv[1:]
owner_pid = int(owner_pid_text)
holder_pid = int(holder_pid_text)
uid = os.getuid()

def process_start(pid):
    result = subprocess.run(
        ["ps", "-p", str(pid), "-o", "lstart="],
        check=False,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip() if result.returncode == 0 else ""

def boot_session():
    result = subprocess.run(
        ["/usr/sbin/sysctl", "-n", "kern.bootsessionuuid"],
        check=False,
        capture_output=True,
        text=True,
    )
    value = result.stdout.strip()
    if value:
        return value
    try:
        with open("/proc/sys/kernel/random/boot_id", encoding="ascii") as handle:
            return handle.read().strip()
    except OSError:
        return ""

home = os.path.normpath(home)
config_dir = os.path.normpath(config_dir)
mutation_root = os.path.normpath(mutation_root)
if os.path.commonpath([home, config_dir]) != home:
    raise SystemExit("config directory escaped HOME")
if os.path.commonpath([home, mutation_root]) != home:
    raise SystemExit("provider mutation directory escaped HOME")
directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
directory_fd = os.open(config_dir, directory_flags)
lock_fd = None
mutation_directory_fd = None
mutation_lock_fd = None
try:
    lock_fd = os.open(
        os.path.basename(lock_path),
        os.O_RDWR | getattr(os, "O_NOFOLLOW", 0),
        dir_fd=directory_fd,
    )
    info = os.fstat(lock_fd)
    if (
        not stat.S_ISREG(info.st_mode)
        or info.st_uid != uid
        or (stat.S_ISREG(info.st_mode) and info.st_nlink != 1)
        or stat.S_IMODE(info.st_mode) != 0o600
    ):
        raise RuntimeError("installer lock is not an owned private regular file")
    payload = os.read(lock_fd, 4097)
    if len(payload) > 4096:
        raise RuntimeError("installer lock record is oversized")
    record = json.loads(payload.decode("utf-8"))
    current_boot = boot_session()
    if not current_boot:
        raise RuntimeError("could not identify the current boot session")
    expected = {
        "pid": owner_pid,
        "process_start": process_start(owner_pid),
        "boot_session": current_boot,
        "token": token,
        "holder_pid": holder_pid,
        "holder_process_start": process_start(holder_pid),
    }
    if not expected["process_start"] or not expected["holder_process_start"]:
        raise RuntimeError("installer owner or lock helper is no longer live")
    if record != expected:
        raise RuntimeError("installer lock record no longer matches this process")
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        pass
    else:
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
        raise RuntimeError("installer lock helper no longer owns the kernel lock")
    mutation_directory_fd = os.open(mutation_root, directory_flags)
    mutation_lock_fd = os.open(
        os.path.basename(mutation_lock_path),
        os.O_RDWR | getattr(os, "O_NOFOLLOW", 0),
        dir_fd=mutation_directory_fd,
    )
    mutation_info = os.fstat(mutation_lock_fd)
    if not stat.S_ISREG(mutation_info.st_mode) or mutation_info.st_uid != uid or mutation_info.st_nlink != 1 or mutation_info.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        raise RuntimeError("provider mutation inner lock is not an owned private regular file")
    try:
        fcntl.flock(mutation_lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        pass
    else:
        fcntl.flock(mutation_lock_fd, fcntl.LOCK_UN)
        raise RuntimeError("installer helper no longer owns the provider mutation inner lock")
finally:
    if mutation_lock_fd is not None:
        os.close(mutation_lock_fd)
    if mutation_directory_fd is not None:
        os.close(mutation_directory_fd)
    if lock_fd is not None:
        os.close(lock_fd)
    os.close(directory_fd)
PY
}

acquire_install_lock() {
  [ "$DRY_RUN" -eq 0 ] || return 0
  lock_status_path="$(mktemp "${TMPDIR:-/tmp}/macprovider-install-lock.XXXXXX")" \
    || die 70 "could not allocate installer lock handshake"
  python3 - "$HOME" "$CONFIG_DIR" "$INSTALL_LOCK_PATH" "$PROVIDER_MUTATION_ROOT" \
    "$PROVIDER_MUTATION_LOCK_PATH" "$PROVIDER_MUTATION_PENDING_PATH" "$$" "$lock_status_path" \
    "${REPAIR_EXISTING_INSTALL:-0}" <<'PY' &
import fcntl
import ctypes
import errno
import grp
import json
import os
import pwd
import re
import secrets
import signal
import stat
import subprocess
import sys
import time

home, config_dir, lock_path, mutation_root, mutation_lock_path, mutation_pending_path, owner_pid_text, status_path, repair_raw = sys.argv[1:]
owner_pid = int(owner_pid_text)
uid = os.getuid()
repair_mode = repair_raw == "1"
provider_user = pwd.getpwuid(uid).pw_name
uuid_pattern = re.compile(
    r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-"
    r"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
)

def write_status(value):
    flags = os.O_WRONLY | os.O_TRUNC | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(status_path, flags)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != uid:
            raise RuntimeError("unsafe installer lock handshake")
        os.write(fd, (value + "\n").encode("utf-8"))
        os.fsync(fd)
    finally:
        os.close(fd)

def process_start(pid):
    result = subprocess.run(
        ["ps", "-p", str(pid), "-o", "lstart="],
        check=False,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip() if result.returncode == 0 else ""

def boot_session():
    result = subprocess.run(
        ["/usr/sbin/sysctl", "-n", "kern.bootsessionuuid"],
        check=False,
        capture_output=True,
        text=True,
    )
    value = result.stdout.strip()
    if value:
        return value
    try:
        with open("/proc/sys/kernel/random/boot_id", encoding="ascii") as handle:
            return handle.read().strip()
    except OSError:
        return ""

def repair_home_write_acl(fields, path, everyone_gid, allow_home_acl_write=False):
    if not repair_mode or not allow_home_acl_write or os.path.normpath(path) != home:
        return False
    if (
        len(fields) != 6
        or fields[0] != "group"
        or not uuid_pattern.fullmatch(fields[1])
        or fields[2] != "everyone"
        or fields[3] != str(everyone_gid)
        or fields[4] != "allow"
    ):
        return False
    permissions = set(filter(None, fields[5].split(",")))
    return permissions == {"write", "append"}

def reject_non_owner_write_acl(path, allow_home_acl_write=False):
    if sys.platform != "darwin":
        return
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        acl_get_fd_np = libc.acl_get_fd_np
        acl_get_fd_np.argtypes = [ctypes.c_int, ctypes.c_int]
        acl_get_fd_np.restype = ctypes.c_void_p
        acl_to_text = libc.acl_to_text
        acl_to_text.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_long)]
        acl_to_text.restype = ctypes.c_void_p
        acl_free = libc.acl_free
        acl_free.argtypes = [ctypes.c_void_p]
        acl_free.restype = ctypes.c_int
    except (AttributeError, OSError) as exc:
        raise RuntimeError("provider mutation ACL inspection unavailable") from exc
    directory_fd = os.open(
        path,
        os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0),
    )
    try:
        ctypes.set_errno(0)
        acl = acl_get_fd_np(directory_fd, 0x00000100)  # ACL_TYPE_EXTENDED
        if not acl:
            if ctypes.get_errno() in (0, errno.ENOENT):
                return
            raise RuntimeError("provider mutation ACL inspection failed")
        try:
            text_length = ctypes.c_long()
            text_pointer = acl_to_text(acl, ctypes.byref(text_length))
            if not text_pointer:
                raise RuntimeError("provider mutation ACL inspection failed")
            try:
                lines = ctypes.string_at(text_pointer, text_length.value).decode(
                    "utf-8", errors="strict"
                ).splitlines()
            finally:
                acl_free(text_pointer)
            everyone_gid = grp.getgrnam("everyone").gr_gid
            if len(lines) < 2 or lines[0] != "!#acl 1":
                raise RuntimeError("provider mutation ACL inspection failed")
            write_permissions = {"write", "append", "add_file", "add_subdirectory", "writeattr", "writeextattr", "delete_child"}
            for line in lines[1:]:
                fields = line.split(":")
                if repair_home_write_acl(fields, path, everyone_gid, allow_home_acl_write=allow_home_acl_write):
                    continue
                if len(fields) != 6:
                    raise RuntimeError("provider mutation ACL inspection failed")
                permissions = set(filter(None, fields[5].split(",")))
                if permissions & write_permissions:
                    if fields[0] == "user" and fields[2] == provider_user:
                        continue
                    raise RuntimeError("provider mutation path has non-owner-write ACL")
        finally:
            acl_free(acl)
    finally:
        os.close(directory_fd)

home = os.path.normpath(home)
config_dir = os.path.normpath(config_dir)
mutation_root = os.path.normpath(mutation_root)
if os.path.commonpath([home, config_dir]) != home:
    raise SystemExit("config directory must remain inside HOME")
if os.path.commonpath([home, mutation_root]) != home:
    raise SystemExit("provider mutation directory must remain inside HOME")
current = home
reject_non_owner_write_acl(home, allow_home_acl_write=True)
for component in os.path.relpath(config_dir, home).split(os.sep):
    current = os.path.join(current, component)
    try:
        info = os.lstat(current)
    except FileNotFoundError:
        os.mkdir(current, 0o700)
        info = os.lstat(current)
    if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
        raise SystemExit(f"config path is not a no-follow directory: {current}")
    if info.st_uid != uid or info.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        raise SystemExit(f"config path is not private to the installing user: {current}")

directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
directory_fd = os.open(config_dir, directory_flags)
lock_fd = None
mutation_directory_fd = None
mutation_lock_fd = None
try:
    flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
    lock_fd = os.open(os.path.basename(lock_path), flags, 0o600, dir_fd=directory_fd)
    info = os.fstat(lock_fd)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != uid or info.st_nlink != 1:
        raise RuntimeError("installer lock is not an owned private regular file")
    os.fchmod(lock_fd, 0o600)
    if stat.S_IMODE(os.fstat(lock_fd).st_mode) != 0o600:
        raise RuntimeError("installer lock mode could not be normalized to 0600")
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        write_status("busy")
        raise SystemExit(73)
    current_boot = boot_session()
    if not current_boot:
        raise RuntimeError("could not identify the current boot session")
    existing_payload = os.read(lock_fd, 4097)
    if len(existing_payload) > 4096:
        raise RuntimeError("installer lock record is oversized")
    if existing_payload.strip():
        try:
            existing = json.loads(existing_payload.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise RuntimeError("installer lock record is invalid") from error
        existing_pid = existing.get("pid")
        existing_start = existing.get("process_start")
        existing_boot = existing.get("boot_session")
        if (
            isinstance(existing_pid, int)
            and isinstance(existing_start, str)
            and existing_start
            and existing_boot == current_boot
            and process_start(existing_pid) == existing_start
        ):
            # The kernel-lock helper may have crashed or been killed while its
            # installer owner remained active. The durable owner record fences
            # out a replacement claimant until that exact owner identity dies.
            write_status("busy")
            raise SystemExit(73)
    current = home
    for component in os.path.relpath(mutation_root, home).split(os.sep):
        current = os.path.join(current, component)
        try:
            info = os.lstat(current)
        except FileNotFoundError:
            os.mkdir(current, 0o700)
            info = os.lstat(current)
        if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
            raise RuntimeError(f"provider mutation path is not a no-follow directory: {current}")
        if info.st_uid != uid or info.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
            raise RuntimeError(f"provider mutation path is not private to the installing user: {current}")
        reject_non_owner_write_acl(current)
    mutation_directory_fd = os.open(mutation_root, directory_flags)
    mutation_lock_fd = os.open(
        os.path.basename(mutation_lock_path),
        os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0),
        0o600,
        dir_fd=mutation_directory_fd,
    )
    mutation_info = os.fstat(mutation_lock_fd)
    if not stat.S_ISREG(mutation_info.st_mode) or mutation_info.st_uid != uid or mutation_info.st_nlink != 1 or mutation_info.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        raise RuntimeError("provider mutation inner lock is not an owned private regular file")
    try:
        fcntl.flock(mutation_lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        write_status("mutation-busy")
        raise SystemExit(73)
    try:
        pending_info = os.lstat(mutation_pending_path)
    except FileNotFoundError:
        pending_info = None
    if pending_info is not None:
        if not stat.S_ISREG(pending_info.st_mode) or stat.S_ISLNK(pending_info.st_mode) or pending_info.st_uid != uid or pending_info.st_nlink != 1 or pending_info.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
            raise RuntimeError("pending provider mutation marker is unsafe")
        write_status("mutation-pending")
        raise SystemExit(73)
    token = secrets.token_hex(32)
    parent_start = process_start(owner_pid)
    if not parent_start:
        raise RuntimeError("installer parent process disappeared before lock acquisition")
    record = {
        "pid": owner_pid,
        "process_start": parent_start,
        "boot_session": current_boot,
        "token": token,
        "holder_pid": os.getpid(),
        "holder_process_start": process_start(os.getpid()),
    }
    payload = (json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
    os.lseek(lock_fd, 0, os.SEEK_SET)
    os.ftruncate(lock_fd, 0)
    os.write(lock_fd, payload)
    os.fsync(lock_fd)
    os.fsync(directory_fd)
    write_status(f"ok:{token}")
    stopping = False
    def stop(_signum, _frame):
        nonlocal_stopping[0] = True
    nonlocal_stopping = [False]
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    while not nonlocal_stopping[0]:
        if process_start(owner_pid) != parent_start:
            break
        time.sleep(0.25)
except SystemExit:
    raise
except BaseException as error:
    try:
        write_status(f"error:{error}")
    except BaseException:
        pass
    raise
finally:
    if mutation_lock_fd is not None:
        os.close(mutation_lock_fd)
    if mutation_directory_fd is not None:
        os.close(mutation_directory_fd)
    if lock_fd is not None:
        os.close(lock_fd)
    os.close(directory_fd)
PY
  INSTALL_LOCK_HOLDER_PID=$!
  lock_wait=0
  while [ "$lock_wait" -lt 100 ] && [ ! -s "$lock_status_path" ]; do
    if ! kill -0 "$INSTALL_LOCK_HOLDER_PID" >/dev/null 2>&1; then
      break
    fi
    sleep 0.05
    lock_wait=$((lock_wait + 1))
  done
  lock_result="$(cat "$lock_status_path" 2>/dev/null || true)"
  rm -f "$lock_status_path"
  case "$lock_result" in
    ok:*) INSTALL_LOCK_TOKEN="${lock_result#ok:}" ;;
    busy)
      wait "$INSTALL_LOCK_HOLDER_PID" >/dev/null 2>&1 || true
      INSTALL_LOCK_HOLDER_PID=""
      die 73 "another macprovider installer is active; wait for it to finish"
      ;;
    mutation-busy)
      wait "$INSTALL_LOCK_HOLDER_PID" >/dev/null 2>&1 || true
      INSTALL_LOCK_HOLDER_PID=""
      die 73 "another provider update is active; wait for it to finish"
      ;;
    mutation-pending)
      wait "$INSTALL_LOCK_HOLDER_PID" >/dev/null 2>&1 || true
      INSTALL_LOCK_HOLDER_PID=""
      die 73 "a provider update is awaiting coordinator admission or recovery; wait for it to finish"
      ;;
    *)
      kill -TERM "$INSTALL_LOCK_HOLDER_PID" >/dev/null 2>&1 || true
      wait "$INSTALL_LOCK_HOLDER_PID" >/dev/null 2>&1 || true
      INSTALL_LOCK_HOLDER_PID=""
      die 70 "could not acquire the no-follow installer lock: ${lock_result#error:}"
      ;;
  esac
  INSTALL_LOCK_HELD=1
}

recover_orphaned_install_transactions() {
  [ "$DRY_RUN" -eq 0 ] || return 0
  assert_install_lock_ownership
  orphan_list="$(python3 - "$CONFIG_DIR" <<'PY'
import os
import stat
import sys

root = sys.argv[1]
uid = os.getuid()
for name in sorted(os.listdir(root)):
    if not name.startswith("install-recovery-") or name.endswith(".staging") or ".committed." in name:
        continue
    path = os.path.join(root, name)
    info = os.lstat(path)
    if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode) or info.st_uid != uid:
        raise SystemExit(f"unsafe orphan recovery bundle: {path}")
    for required in ("state.sh", "recover.sh"):
        child = os.path.join(path, required)
        child_info = os.lstat(child)
        if not stat.S_ISREG(child_info.st_mode) or stat.S_ISLNK(child_info.st_mode) or child_info.st_uid != uid:
            raise SystemExit(f"unsafe orphan recovery artifact: {child}")
    print(path)
PY
  )" || die 70 "could not safely enumerate orphan install transactions"
  [ -n "$orphan_list" ] || return 0
  while IFS= read -r orphan; do
    [ -n "$orphan" ] || continue
    log "Recovering interrupted install transaction before starting a new install: $orphan"
    verify_headless_recovery_trust "$orphan" \
      || die 70 "interrupted headless install recovery did not match its root-owned trust receipt"
    recovery_rc=0
    bash "$orphan/recover.sh" || recovery_rc=$?
    if [ "$recovery_rc" -eq 75 ]; then
      wait_attempt=0
      while [ "$wait_attempt" -lt 30 ] && [ -d "$orphan" ]; do
        sleep 1
        wait_attempt=$((wait_attempt + 1))
      done
      [ ! -d "$orphan" ] || die 75 "interrupted install recovery is still active: $orphan"
      continue
    fi
    [ "$recovery_rc" -eq 0 ] || die 70 "interrupted install recovery failed; run exactly: bash '$orphan/recover.sh'"
    rm -rf "$orphan" || die 70 "recovered orphan transaction could not be retired: $orphan"
    fsync_directory_path "$CONFIG_DIR" \
      || die 70 "recovered orphan transaction retirement was not durable: $orphan"
    retire_headless_recovery_trust \
      || die 70 "recovered orphan transaction trust receipt could not be retired"
  done <<EOF
$orphan_list
EOF
}

restore_existing_provider_if_start_skipped() {
  [ "$SKIP_PROVIDER_START" -eq 1 ] || return 1
  [ "$EXISTING_INSTALL_WAS_PRESENT" -eq 1 ] || return 1
  if [ "$CUTOVER_STARTED" -eq 0 ]; then
    discard_install_transaction_before_cutover || return 1
    log "The active provider release remained online and unchanged."
    return 0
  fi
  log "No replacement provider will be started; restoring the previous ready provider release."
  rollback_install_transaction || return 1
  log "Previous provider release restored. The requested update was not activated."
  return 0
}

cleanup() {
  cleanup_rc=$?
  trap - EXIT
  if [ "$INSTALL_TX_ACTIVE" -eq 1 ] && [ "$INSTALL_TX_COMMITTED" -ne 1 ]; then
    if [ "$CUTOVER_STARTED" -eq 0 ]; then
      discard_install_transaction_before_cutover || cleanup_rc=70
    elif ! rollback_install_transaction; then
      cleanup_rc=70
    fi
  fi
  if [ -n "$TMPDIR_PATH" ] && [ -d "$TMPDIR_PATH" ]; then
    if ! rm -rf "$TMPDIR_PATH"; then
      log "ERROR: failed to remove temporary installer directory: $TMPDIR_PATH"
      if [ "$cleanup_rc" -eq 0 ]; then
        cleanup_rc=70
      fi
    fi
  fi
  if [ "${CREATED_REFERRAL_CODE_SOURCE_FILE:-0}" -eq 1 ] \
      && [ -n "${REFERRAL_CODE_SOURCE_FILE:-}" ]; then
    rm -f -- "$REFERRAL_CODE_SOURCE_FILE" || cleanup_rc=70
    REFERRAL_CODE_SOURCE_FILE=""
    CREATED_REFERRAL_CODE_SOURCE_FILE=0
  fi
  if ! release_install_lock; then
    log "ERROR: installer lock ownership could not be released safely: $INSTALL_LOCK_PATH"
    if [ "$cleanup_rc" -eq 0 ]; then
      cleanup_rc=70
    fi
  fi
  exit "$cleanup_rc"
}
trap cleanup EXIT

transaction_path_exists() {
  [ -e "$1" ] || [ -L "$1" ]
}

transaction_file_or_absent() {
  transaction_path_exists "$1" || return 0
  [ -f "$1" ] && [ ! -L "$1" ]
}

transaction_directory_or_absent() {
  transaction_path_exists "$1" || return 0
  [ -d "$1" ] && [ ! -L "$1" ]
}

transaction_binary_or_absent() {
  transaction_path_exists "$1" || return 0
  [ -L "$1" ] || { [ -f "$1" ] && [ ! -L "$1" ]; }
}

validate_transaction_path_kinds() {
  transaction_binary_or_absent "$BINARY_PATH" \
    || die 70 "the previous CLI path is not a regular file or symlink"
  transaction_file_or_absent "$CONFIG_PATH" \
    || die 70 "the previous config is not a regular file"
  transaction_file_or_absent "$PROVIDER_ID_PATH" \
    || die 70 "the previous provider id is not a regular file"
  transaction_file_or_absent "$RECOMMENDATION_PATH" \
    || die 70 "the previous recommendation is not a regular file"
  transaction_file_or_absent "$PLIST_PATH" \
    || die 70 "the previous launchd plist is not a regular file"
  transaction_directory_or_absent "$WATCHDOG_DIR" \
    || die 70 "the previous watchdog directory is not a directory"
  transaction_file_or_absent "$WATCHDOG_PLIST_PATH" \
    || die 70 "the previous watchdog plist is not a regular file"
  transaction_file_or_absent "$MANIFEST_PATH" \
    || die 70 "the previous install manifest is not a regular file"
}

validate_transaction_filesystems() {
  python3 - \
    "$CONFIG_DIR" \
    "$INSTALL_DIR" \
    "$BINARY_PATH" \
    "$CONFIG_PATH" \
    "$PROVIDER_ID_PATH" \
    "$RECOMMENDATION_PATH" \
    "$PLIST_PATH" \
    "$WATCHDOG_DIR" \
    "$WATCHDOG_PLIST_PATH" \
    "$MANIFEST_PATH" <<'PY'
import os
import stat
import sys

config_dir, *paths = sys.argv[1:]
config_device = os.stat(config_dir).st_dev
for path in paths:
    if not os.path.lexists(path):
        continue
    parent = os.path.dirname(path)
    parent_device = os.stat(parent).st_dev
    if parent_device != config_device:
        raise SystemExit("transaction path is on a different filesystem: %s" % path)
    info = os.lstat(path)
    if info.st_dev != config_device:
        raise SystemExit("transaction path is a mounted filesystem: %s" % path)
PY
}

install_tx_path_matches() {
  source_path="$1"
  copied_path="$2"
  path_kind="$3"
  python3 - "$source_path" "$copied_path" "$path_kind" <<'PY'
import os
import stat
import sys

source_path, copied_path, path_kind = sys.argv[1:]
nofollow = getattr(os, "O_NOFOLLOW", 0)
nonblock = getattr(os, "O_NONBLOCK", 0)


def identity(info):
    return (
        info.st_dev,
        info.st_ino,
        info.st_size,
        info.st_mtime_ns,
        info.st_ctime_ns,
    )


def compare_regular(source_fd, copied_fd):
    source_info = os.fstat(source_fd)
    copied_info = os.fstat(copied_fd)
    if not stat.S_ISREG(source_info.st_mode) or not stat.S_ISREG(copied_info.st_mode):
        return False
    source_identity = identity(source_info)
    copied_identity = identity(copied_info)
    while True:
        source_chunk = os.read(source_fd, 65536)
        copied_chunk = os.read(copied_fd, 65536)
        if source_chunk != copied_chunk:
            return False
        if not source_chunk:
            break
    return identity(os.fstat(source_fd)) == source_identity and identity(os.fstat(copied_fd)) == copied_identity


def compare_directory(source_fd, copied_fd):
    source_names = set(os.listdir(source_fd))
    copied_names = set(os.listdir(copied_fd))
    if source_names != copied_names:
        return False
    for name in source_names:
        source_info = os.lstat(name, dir_fd=source_fd)
        copied_info = os.lstat(name, dir_fd=copied_fd)
        source_type = stat.S_IFMT(source_info.st_mode)
        copied_type = stat.S_IFMT(copied_info.st_mode)
        if source_type != copied_type:
            return False
        if stat.S_ISDIR(source_info.st_mode):
            source_child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | nofollow, dir_fd=source_fd)
            copied_child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | nofollow, dir_fd=copied_fd)
            try:
                if not compare_directory(source_child, copied_child):
                    return False
            finally:
                os.close(copied_child)
                os.close(source_child)
        elif stat.S_ISLNK(source_info.st_mode):
            if os.readlink(name, dir_fd=source_fd) != os.readlink(name, dir_fd=copied_fd):
                return False
        elif stat.S_ISREG(source_info.st_mode):
            source_file = os.open(name, os.O_RDONLY | nonblock | nofollow, dir_fd=source_fd)
            copied_file = os.open(name, os.O_RDONLY | nonblock | nofollow, dir_fd=copied_fd)
            try:
                if not compare_regular(source_file, copied_file):
                    return False
            finally:
                os.close(copied_file)
                os.close(source_file)
        else:
            return False
    return True


source_info = os.lstat(source_path)
copied_info = os.lstat(copied_path)
if path_kind == "symlink":
    raise SystemExit(0 if stat.S_ISLNK(copied_info.st_mode) and os.readlink(source_path) == os.readlink(copied_path) else 1)
if path_kind == "file":
    if not stat.S_ISREG(source_info.st_mode) or not stat.S_ISREG(copied_info.st_mode):
        raise SystemExit(1)
    source_fd = os.open(source_path, os.O_RDONLY | nonblock | nofollow)
    copied_fd = os.open(copied_path, os.O_RDONLY | nonblock | nofollow)
    try:
        raise SystemExit(0 if compare_regular(source_fd, copied_fd) else 1)
    finally:
        os.close(copied_fd)
        os.close(source_fd)
if path_kind != "directory" or not stat.S_ISDIR(source_info.st_mode) or not stat.S_ISDIR(copied_info.st_mode):
    raise SystemExit(1)
source_fd = os.open(source_path, os.O_RDONLY | os.O_DIRECTORY | nofollow)
copied_fd = os.open(copied_path, os.O_RDONLY | os.O_DIRECTORY | nofollow)
try:
    raise SystemExit(0 if compare_directory(source_fd, copied_fd) else 1)
finally:
    os.close(copied_fd)
    os.close(source_fd)
PY
}

stage_install_tx_symlink() {
  source_path="$1"
  copied_path="$2"
  python3 - "$source_path" "$copied_path" <<'PY'
import os
import stat
import sys

source_path, copied_path = sys.argv[1:]
uid = os.getuid()
nofollow = getattr(os, "O_NOFOLLOW", 0)
source_before = os.lstat(source_path)
if (
    not stat.S_ISLNK(source_before.st_mode)
    or source_before.st_uid != uid
    or source_before.st_nlink != 1
):
    raise SystemExit("unsafe transaction symlink")
target = os.readlink(source_path)
source_after = os.lstat(source_path)
if (
    (source_after.st_dev, source_after.st_ino, source_after.st_mtime_ns, source_after.st_ctime_ns)
    != (source_before.st_dev, source_before.st_ino, source_before.st_mtime_ns, source_before.st_ctime_ns)
):
    raise SystemExit("transaction symlink changed during snapshot")

destination_parent = os.path.dirname(copied_path)
destination_name = os.path.basename(copied_path)
parent_fd = os.open(destination_parent, os.O_RDONLY | os.O_DIRECTORY | nofollow)
temporary_name = ".%s.symlink-%s" % (destination_name, os.urandom(16).hex())
try:
    os.symlink(target, temporary_name, dir_fd=parent_fd)
    os.replace(temporary_name, destination_name, src_dir_fd=parent_fd, dst_dir_fd=parent_fd)
    os.fsync(parent_fd)
    copied = os.readlink(destination_name, dir_fd=parent_fd)
    if copied != target:
        raise SystemExit("transaction symlink destination changed")
finally:
    try:
        os.unlink(temporary_name, dir_fd=parent_fd)
    except FileNotFoundError:
        pass
    os.close(parent_fd)
PY
}

stage_install_tx_path() {
  source_path="$1"
  copied_path="$2"
  path_kind="$3"
  case "$path_kind" in
    directory)
      python3 - "$source_path" "$copied_path" <<'PY'
import os
import shutil
import stat
import sys
import ctypes
import errno

source_path, copied_path = sys.argv[1:]
uid = os.getuid()
nofollow = getattr(os, "O_NOFOLLOW", 0)
nonblock = getattr(os, "O_NONBLOCK", 0)

if os.environ.get("INSTALL_TX_DIRECTORY_COPY_FAULT") == "fail-backup-cp":
    raise SystemExit("injected install transaction directory-copy failure")


def no_acl(fd):
    if sys.platform != "darwin":
        return True
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        get_acl = libc.acl_get_fd_np
        get_acl.argtypes = [ctypes.c_int, ctypes.c_int]
        get_acl.restype = ctypes.c_void_p
        free_acl = libc.acl_free
        free_acl.argtypes = [ctypes.c_void_p]
        free_acl.restype = ctypes.c_int
    except (AttributeError, OSError):
        return False
    ctypes.set_errno(0)
    acl = get_acl(fd, 0x00000100)
    if acl:
        free_acl(acl)
        return False
    return ctypes.get_errno() in (0, errno.ENOENT)


def read_extended_attributes(fd):
    if sys.platform != "darwin":
        return []
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        list_xattrs = libc.flistxattr
        list_xattrs.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32]
        list_xattrs.restype = ctypes.c_ssize_t
        get_xattr = libc.fgetxattr
        get_xattr.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
        get_xattr.restype = ctypes.c_ssize_t
    except (AttributeError, OSError):
        raise SystemExit("extended-attribute API is unavailable")
    size = list_xattrs(fd, None, 0, 0)
    if size < 0:
        raise SystemExit("could not enumerate source extended attributes")
    if size == 0:
        return []
    names_buffer = ctypes.create_string_buffer(size)
    actual_size = list_xattrs(fd, names_buffer, size, 0)
    if actual_size < 0:
        raise SystemExit("could not read source extended attributes")
    names = names_buffer.raw[:actual_size].split(b"\0")
    attributes = []
    for raw_name in names:
        if not raw_name:
            continue
        value_size = get_xattr(fd, raw_name, None, 0, 0, 0)
        if value_size < 0:
            raise SystemExit("could not read source extended attribute")
        value_buffer = ctypes.create_string_buffer(value_size) if value_size else None
        if value_size and get_xattr(fd, raw_name, value_buffer, value_size, 0, 0) != value_size:
            raise SystemExit("could not read source extended attribute")
        value = b"" if value_buffer is None else bytes(value_buffer.raw[:value_size])
        attributes.append((raw_name, value))
    return attributes


def write_extended_attributes(fd, attributes):
    if sys.platform != "darwin":
        return
    try:
        set_xattr = ctypes.CDLL(None, use_errno=True).fsetxattr
        set_xattr.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
        set_xattr.restype = ctypes.c_int
    except (AttributeError, OSError):
        raise SystemExit("extended-attribute API is unavailable")
    for name, value in attributes:
        value_buffer = ctypes.create_string_buffer(value) if value else None
        if set_xattr(fd, name, value_buffer, len(value), 0, 0) != 0:
            raise SystemExit("could not preserve extended attribute")


def preserve_metadata(source_fd, destination_fd, info, label):
    if (
        info.st_uid != uid
        or (stat.S_ISREG(info.st_mode) and info.st_nlink != 1)
        or info.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
        or getattr(info, "st_flags", 0) != 0
        or not no_acl(source_fd)
    ):
        raise SystemExit("unsupported metadata in install transaction source: %s" % label)
    attributes = read_extended_attributes(source_fd)
    os.fchmod(destination_fd, stat.S_IMODE(info.st_mode))
    os.utime(destination_fd, ns=(info.st_atime_ns, info.st_mtime_ns))
    write_extended_attributes(destination_fd, attributes)
    destination_info = os.fstat(destination_fd)
    if (
        stat.S_IMODE(destination_info.st_mode) != stat.S_IMODE(info.st_mode)
        or destination_info.st_atime_ns != info.st_atime_ns
        or destination_info.st_mtime_ns != info.st_mtime_ns
        or dict(read_extended_attributes(destination_fd)) != dict(attributes)
    ):
        raise SystemExit("destination metadata changed during copy")


def copy_regular(source_fd, destination_fd, name):
    source = os.open(name, os.O_RDONLY | nonblock | nofollow, dir_fd=source_fd)
    temporary = ".%s.snapshot-%s" % (name, os.urandom(16).hex())
    output = None
    try:
        before = os.fstat(source)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_uid != uid
            or before.st_nlink != 1
            or before.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
            or not no_acl(source)
        ):
            raise SystemExit("unsupported special file in install transaction source: %s" % name)
        payload = bytearray()
        while len(payload) < before.st_size:
            chunk = os.read(source, min(65536, before.st_size - len(payload)))
            if not chunk:
                raise SystemExit("install transaction source was truncated: %s" % name)
            payload.extend(chunk)
        after = os.fstat(source)
        if (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns) != (
            before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns
        ):
            raise SystemExit("install transaction source changed during copy: %s" % name)
        output = os.open(
            temporary,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | nofollow,
            stat.S_IMODE(before.st_mode),
            dir_fd=destination_fd,
        )
        offset = 0
        while offset < len(payload):
            offset += os.write(output, payload[offset:])
        preserve_metadata(source, output, before, name)
        os.fsync(output)
        os.close(output)
        output = None
        os.replace(temporary, name, src_dir_fd=destination_fd, dst_dir_fd=destination_fd)
        temporary = None
    finally:
        if output is not None:
            os.close(output)
        if temporary is not None:
            try:
                os.unlink(temporary, dir_fd=destination_fd)
            except FileNotFoundError:
                pass
        os.close(source)


def copy_directory(source_fd, destination_fd):
    for name in os.listdir(source_fd):
        info = os.lstat(name, dir_fd=source_fd)
        if stat.S_ISDIR(info.st_mode):
            os.mkdir(name, stat.S_IMODE(info.st_mode) & 0o7777, dir_fd=destination_fd)
            child_source = os.open(name, os.O_RDONLY | os.O_DIRECTORY | nofollow, dir_fd=source_fd)
            child_destination = os.open(name, os.O_RDONLY | os.O_DIRECTORY | nofollow, dir_fd=destination_fd)
            try:
                copy_directory(child_source, child_destination)
                preserve_metadata(child_source, child_destination, info, name)
                os.fsync(child_destination)
            finally:
                os.close(child_destination)
                os.close(child_source)
        elif stat.S_ISLNK(info.st_mode):
            if info.st_uid != uid or info.st_nlink != 1:
                raise SystemExit("unsafe symlink in install transaction source: %s" % name)
            target = os.readlink(name, dir_fd=source_fd)
            os.symlink(target, name, dir_fd=destination_fd)
        elif stat.S_ISREG(info.st_mode):
            copy_regular(source_fd, destination_fd, name)
        else:
            raise SystemExit("unsupported special file in install transaction source: %s" % name)


source = os.open(source_path, os.O_RDONLY | os.O_DIRECTORY | nofollow)
try:
    source_info = os.fstat(source)
    if source_info.st_uid != uid or not stat.S_ISDIR(source_info.st_mode):
        raise SystemExit("unsafe install transaction source directory")
    os.mkdir(copied_path, 0o700)
    destination = os.open(copied_path, os.O_RDONLY | os.O_DIRECTORY | nofollow)
    try:
        try:
            copy_directory(source, destination)
            preserve_metadata(source, destination, source_info, source_path)
            os.fsync(destination)
        except BaseException:
            shutil.rmtree(copied_path, ignore_errors=True)
            raise
    finally:
        os.close(destination)
finally:
    os.close(source)
PY
      ;;
    symlink) stage_install_tx_symlink "$source_path" "$copied_path" ;;
    file)
      # Recovery inputs are authoritative. Copy them through descriptors so a
      # pathname replacement cannot turn the snapshot into attacker-selected
      # content, and publish the destination atomically with a private mode.
      python3 - "$source_path" "$copied_path" <<'PY'
import ctypes
import errno
import os
import stat
import sys

source_path, copied_path = sys.argv[1:]
uid = os.getuid()
max_bytes = 1024 * 1024
nofollow = getattr(os, "O_NOFOLLOW", 0)
nonblock = getattr(os, "O_NONBLOCK", 0)


def no_acl(fd):
    if sys.platform != "darwin":
        return True
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        get_acl = libc.acl_get_fd_np
        get_acl.argtypes = [ctypes.c_int, ctypes.c_int]
        get_acl.restype = ctypes.c_void_p
        free_acl = libc.acl_free
        free_acl.argtypes = [ctypes.c_void_p]
        free_acl.restype = ctypes.c_int
    except (AttributeError, OSError):
        return False
    ctypes.set_errno(0)
    acl = get_acl(fd, 0x00000100)
    if acl:
        free_acl(acl)
        return False
    return ctypes.get_errno() in (0, errno.ENOENT)


def read_extended_attributes(fd):
    if sys.platform != "darwin":
        return []
    libc = ctypes.CDLL(None, use_errno=True)
    list_xattrs = libc.flistxattr
    list_xattrs.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32]
    list_xattrs.restype = ctypes.c_ssize_t
    get_xattr = libc.fgetxattr
    get_xattr.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
    get_xattr.restype = ctypes.c_ssize_t
    size = list_xattrs(fd, None, 0, 0)
    if size < 0:
        raise SystemExit("could not enumerate source extended attributes")
    if size == 0:
        return []
    names_buffer = ctypes.create_string_buffer(size)
    actual_size = list_xattrs(fd, names_buffer, size, 0)
    if actual_size < 0:
        raise SystemExit("could not read source extended attributes")
    attributes = []
    for raw_name in names_buffer.raw[:actual_size].split(b"\0"):
        if not raw_name:
            continue
        value_size = get_xattr(fd, raw_name, None, 0, 0, 0)
        if value_size < 0:
            raise SystemExit("could not read source extended attribute")
        value_buffer = ctypes.create_string_buffer(value_size) if value_size else None
        if value_size and get_xattr(fd, raw_name, value_buffer, value_size, 0, 0) != value_size:
            raise SystemExit("could not read source extended attribute")
        attributes.append((raw_name, b"" if value_buffer is None else bytes(value_buffer.raw[:value_size])))
    return attributes


def write_extended_attributes(fd, attributes):
    if sys.platform != "darwin":
        return
    libc = ctypes.CDLL(None, use_errno=True)
    set_xattr = libc.fsetxattr
    set_xattr.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
    set_xattr.restype = ctypes.c_int
    for name, value in attributes:
        value_buffer = ctypes.create_string_buffer(value) if value else None
        if set_xattr(fd, name, value_buffer, len(value), 0, 0) != 0:
            raise SystemExit("could not preserve extended attribute")


def safe_regular(fd, info, label):
    if (
        not stat.S_ISREG(info.st_mode)
        or info.st_uid != uid
        or (stat.S_ISREG(info.st_mode) and info.st_nlink != 1)
        or info.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
        or getattr(info, "st_flags", 0) != 0
        or info.st_size < 0
        or info.st_size > max_bytes
        or not no_acl(fd)
    ):
        raise SystemExit(f"unsafe recovery snapshot {label}")


source_fd = os.open(source_path, os.O_RDONLY | nonblock | nofollow)
try:
    before = os.fstat(source_fd)
    safe_regular(source_fd, before, source_path)
    source_mode = stat.S_IMODE(before.st_mode)
    attributes = read_extended_attributes(source_fd)
    payload = bytearray()
    while len(payload) < before.st_size:
        chunk = os.read(source_fd, min(65536, before.st_size - len(payload)))
        if not chunk:
            raise SystemExit("recovery snapshot was truncated")
        payload.extend(chunk)
    after = os.fstat(source_fd)
    path_info = os.lstat(source_path)
    if (
        (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns)
        != (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns)
        or stat.S_ISLNK(path_info.st_mode)
        or (path_info.st_dev, path_info.st_ino) != (before.st_dev, before.st_ino)
    ):
        raise SystemExit("recovery snapshot changed during copy")
finally:
    os.close(source_fd)

parent_path = os.path.dirname(copied_path)
parent_fd = os.open(parent_path, os.O_RDONLY | os.O_DIRECTORY | nofollow)
temporary_name = ".%s.restore-%s" % (os.path.basename(copied_path), os.urandom(16).hex())
temporary_fd = None
try:
    parent_info = os.fstat(parent_fd)
    if (
        not stat.S_ISDIR(parent_info.st_mode)
        or parent_info.st_uid != uid
        or parent_info.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
        or not no_acl(parent_fd)
    ):
        raise SystemExit("unsafe recovery snapshot destination")
    temporary_fd = os.open(
        temporary_name,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | nofollow,
        source_mode,
        dir_fd=parent_fd,
    )
    os.fchmod(temporary_fd, source_mode)
    offset = 0
    while offset < len(payload):
        offset += os.write(temporary_fd, payload[offset:])
    write_extended_attributes(temporary_fd, attributes)
    os.utime(temporary_fd, ns=(before.st_atime_ns, before.st_mtime_ns))
    os.fsync(temporary_fd)
    os.close(temporary_fd)
    temporary_fd = None
    os.replace(temporary_name, os.path.basename(copied_path), src_dir_fd=parent_fd, dst_dir_fd=parent_fd)
    temporary_name = None
    os.fsync(parent_fd)
    verify_fd = os.open(
        os.path.basename(copied_path),
        os.O_RDONLY | nonblock | nofollow,
        dir_fd=parent_fd,
    )
    try:
        verify_info = os.fstat(verify_fd)
        safe_regular(verify_fd, verify_info, copied_path)
        if stat.S_IMODE(verify_info.st_mode) != source_mode:
            raise SystemExit("recovery snapshot destination mode changed")
        if dict(read_extended_attributes(verify_fd)) != dict(attributes):
            raise SystemExit("recovery snapshot destination metadata changed")
        if os.read(verify_fd, len(payload) + 1) != payload:
            raise SystemExit("recovery snapshot destination changed")
    finally:
        os.close(verify_fd)
finally:
    if temporary_fd is not None:
        os.close(temporary_fd)
    if temporary_name is not None:
        try:
            os.unlink(temporary_name, dir_fd=parent_fd)
        except FileNotFoundError:
            pass
    os.close(parent_fd)
PY
      ;;
    *) return 1 ;;
  esac
  install_tx_path_matches "$source_path" "$copied_path" "$path_kind"
}

# Launchd plists identify the service being displaced, so snapshot them with
# descriptor-backed checks rather than a path-following cp. A plist that is a
# symlink, hard link, non-regular file, foreign-owned file, oversized file, or
# replaced while it is being copied is not safe recovery input.
stage_install_tx_plist() {
  source_path="$1"
  copied_path="$2"
  expected_label="$3"
  expected_program="$4"
  alternate_program="$5"
  if [ "$#" -ge 7 ]; then
    alternate_program_2="$6"
    expected_user="$7"
  else
    alternate_program_2=""
    expected_user="${6:-}"
  fi
  python3 - "$source_path" "$copied_path" "$expected_label" "$expected_program" "$alternate_program" "$alternate_program_2" "$expected_user" <<'PY'
import os
import plistlib
import stat
import subprocess
import sys
import ctypes
import errno

source_path, copied_path, expected_label, expected_program, alternate_program, alternate_program_2, expected_user = sys.argv[1:]
uid = os.getuid()
max_bytes = 1024 * 1024
nofollow = getattr(os, "O_NOFOLLOW", 0)
nonblock = getattr(os, "O_NONBLOCK", 0)


def fail(message):
    sys.stderr.write("plist_snapshot_failed:%s\n" % message)
    raise SystemExit(1)


def read_bounded(fd):
    data = bytearray()
    while len(data) <= max_bytes:
        chunk = os.read(fd, 65536)
        if not chunk:
            return bytes(data)
        data.extend(chunk)
    fail("oversized")


source_fd = os.open(source_path, os.O_RDONLY | nonblock | nofollow)
destination_created = False
try:
    before = os.fstat(source_fd)
    if not stat.S_ISREG(before.st_mode):
        fail("not_regular")
    if before.st_uid != uid:
        fail("not_owned")
    if before.st_nlink != 1:
        fail("hardlinked")
    if before.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        fail("group_or_world_writable")
    if before.st_size > max_bytes:
        fail("oversized")
    payload = read_bounded(source_fd)
    if len(payload) != before.st_size:
        fail("source_size_changed")

    def source_identity(info):
        return (
            info.st_dev,
            info.st_ino,
            info.st_mode,
            info.st_uid,
            info.st_nlink,
            info.st_size,
            info.st_mtime_ns,
            info.st_ctime_ns,
        )

    before_identity = source_identity(before)

    def verify_source():
        current = os.fstat(source_fd)
        if source_identity(current) != before_identity:
            fail("source_metadata_changed")
        os.lseek(source_fd, 0, os.SEEK_SET)
        if read_bounded(source_fd) != payload:
            fail("source_contents_changed")
        path_info = os.lstat(source_path)
        if stat.S_ISLNK(path_info.st_mode) or source_identity(path_info) != before_identity:
            fail("source_path_replaced")

    def verify_acl():
        # The shipped installer is macOS-only, and this recovery harness is
        # also exercised on Linux CI. Keep ACL enforcement on the Darwin
        # descriptor API; all portable descriptor, owner, mode, link-count,
        # identity, and content checks remain active on every platform.
        if sys.platform != "darwin":
            return

        try:
            libc = ctypes.CDLL(None, use_errno=True)
            acl_get_fd_np = libc.acl_get_fd_np
            acl_get_fd_np.argtypes = [ctypes.c_int, ctypes.c_int]
            acl_get_fd_np.restype = ctypes.c_void_p
            acl_free = libc.acl_free
            acl_free.argtypes = [ctypes.c_void_p]
            acl_free.restype = ctypes.c_int
        except (AttributeError, OSError):
            fail("acl_uninspectable")
        ctypes.set_errno(0)
        acl = acl_get_fd_np(source_fd, 0x00000100)  # ACL_TYPE_EXTENDED
        if acl:
            acl_free(acl)
            fail("acl_present")
        if ctypes.get_errno() != errno.ENOENT:
            fail("acl_uninspectable")

    verify_acl()
    try:
        plist = plistlib.loads(payload)
    except Exception:
        fail("invalid_plist")
    if not isinstance(plist, dict) or plist.get("Label") != expected_label:
        fail("unexpected_label")
    if expected_user:
        user_name = plist.get("UserName")
        if expected_label.endswith("-watchdog"):
            if user_name is not None:
                fail("unexpected_user")
        elif user_name != expected_user:
            fail("unexpected_user")
    program = plist.get("Program")
    if "Program" in plist and (not isinstance(program, str) or not program):
        fail("invalid_program")
    arguments = plist.get("ProgramArguments")
    if "ProgramArguments" in plist:
        if (
            not isinstance(arguments, list)
            or not arguments
            or not all(isinstance(argument, str) and argument for argument in arguments)
        ):
            fail("invalid_program_arguments")
    if program is None and arguments is None:
        fail("missing_program_identity")
    effective_program = program if program is not None else arguments[0]
    allowed_programs = [expected_program, alternate_program]
    if alternate_program_2:
        allowed_programs.append(alternate_program_2)
    if effective_program not in allowed_programs:
        fail("unexpected_program")

    previous_umask = os.umask(0o077)
    try:
        destination_fd = os.open(
            copied_path,
            os.O_RDWR | os.O_CREAT | os.O_EXCL | nofollow,
            0o600,
        )
    finally:
        os.umask(previous_umask)
    destination_created = True
    try:
        written = 0
        while written < len(payload):
            progress = os.write(destination_fd, payload[written:])
            if progress <= 0:
                fail("destination_write")
            written += progress
        os.fchmod(destination_fd, stat.S_IMODE(before.st_mode) & ~0o022)
        os.fsync(destination_fd)
        verify_source()
        verify_acl()
        destination_info = os.fstat(destination_fd)
        if (
            not stat.S_ISREG(destination_info.st_mode)
            or destination_info.st_uid != uid
            or destination_info.st_nlink != 1
            or destination_info.st_size != len(payload)
        ):
            fail("destination_unsafe")
        os.lseek(destination_fd, 0, os.SEEK_SET)
        if read_bounded(destination_fd) != payload:
            fail("destination_mismatch")
    finally:
        os.close(destination_fd)

    verify_source()
    verify_acl()
finally:
    os.close(source_fd)
    if destination_created:
        try:
            final_info = os.lstat(copied_path)
            if not stat.S_ISREG(final_info.st_mode) or final_info.st_nlink != 1:
                os.unlink(copied_path)
        except FileNotFoundError:
            pass
PY
}

# Snapshot the CLI-owned lifecycle-state file into the recovery staging area
# with the same posture the real store enforces, holding the store's lock file
# so a concurrent operator transition cannot be lost. The snapshot follows no
# symlinks, validates ownership/type/nlink/mode/size, copies with umask 077
# into a freshly created 0600 destination, and re-verifies the source after the
# copy (lstat again + byte compare). It writes `had=1` to the meta file when a
# state file was snapshotted (restore reads the snapshot record directly under
# the lock). Exit non-zero (before any live mutation) on violation or lock
# timeout. Absence of the state file is a normal, non-fatal outcome reported as
# had=0.
stage_lifecycle_snapshot() {
  state_path="$1"
  lock_path="$2"
  destination_path="$3"
  meta_path="$4"
  LIFECYCLE_SNAPSHOT_FAULT="${LIFECYCLE_SNAPSHOT_FAULT:-}" \
  python3 - "$state_path" "$lock_path" "$destination_path" "$meta_path" <<'PY'
import errno
import fcntl
import ctypes
import json
import os
import stat
import sys
import time

state_path, lock_path, destination_path, meta_path = sys.argv[1:]
uid = os.getuid()
MAX_STATE_BYTES = 1024 * 1024
LOCK_TIMEOUT_SECONDS = 10.0
# Fault-injection hook (tests only). "short-write" forces os.write to report a
# single truncated byte count so the write loop's short-write handling and the
# staged-file byte-compare abort BEFORE had=1 is published.
FAULT = os.environ.get("LIFECYCLE_SNAPSHOT_FAULT", "")


def fail(message):
    sys.stderr.write("lifecycle_snapshot_failed:%s\n" % message)
    raise SystemExit(70)


def lstat_or_none(path):
    try:
        return os.lstat(path)
    except FileNotFoundError:
        return None


def write_all(fd, payload):
    # Persist every byte: os.write may write fewer than requested, so loop until
    # the whole payload lands and reject any zero/negative progress rather than
    # trusting a single call (which could silently truncate the snapshot).
    total = 0
    forced_short = FAULT == "short-write"
    while total < len(payload):
        chunk = payload[total:]
        if forced_short and total == 0 and len(chunk) > 1:
            # Simulate a kernel short write of a single byte on the first call.
            written = os.write(fd, chunk[:1])
        else:
            written = os.write(fd, chunk)
        if written <= 0:
            fail("lifecycle_snapshot_write_no_progress")
        total += written
        if forced_short:
            # Stop after the injected short write so the destination is left
            # truncated; the post-write byte-compare must then abort.
            break
    return total


parent = os.path.dirname(state_path)
parent_st = lstat_or_none(parent)
if parent_st is None:
    # No lifecycle directory: an incumbent that predates the lifecycle contract.
    # There is nothing to lock (the store's lock lives inside this directory),
    # so re-read the parent to confirm it is STILL absent before publishing
    # had=0. Residual race: a concurrent CLI could create the directory and a
    # state file in the window between this double-read and the installer's
    # subsequent mutation; that is out of scope for a byte snapshot with no lock
    # to hold and is bounded by the installer transaction lock taken elsewhere.
    if lstat_or_none(parent) is not None:
        fail("lifecycle_parent_appeared_during_snapshot")
    with open(meta_path, "w", encoding="utf-8") as handle:
        handle.write("had=0\n")
    raise SystemExit(0)
if stat.S_ISLNK(parent_st.st_mode):
    fail("lifecycle_parent_symlink")
if not stat.S_ISDIR(parent_st.st_mode):
    fail("lifecycle_parent_not_directory")
if parent_st.st_uid != uid:
    fail("lifecycle_parent_not_owned")
if stat.S_IMODE(parent_st.st_mode) != 0o700:
    fail("lifecycle_parent_mode:%o" % stat.S_IMODE(parent_st.st_mode))

# Acquire the store's lock (O_NOFOLLOW, owned, non-symlink, 0600) with a bounded
# timeout so a concurrent CLI transition serializes against the snapshot.
lock_st = lstat_or_none(lock_path)
if lock_st is not None and stat.S_ISLNK(lock_st.st_mode):
    fail("lifecycle_lock_symlink")
lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0), 0o600)
try:
    lock_desc = os.fstat(lock_fd)
    if (
        not stat.S_ISREG(lock_desc.st_mode)
        or lock_desc.st_uid != uid
        or lock_desc.st_nlink != 1
        or stat.S_IMODE(lock_desc.st_mode) & 0o077
    ):
        fail("lifecycle_lock_invalid")
    deadline = time.monotonic() + LOCK_TIMEOUT_SECONDS
    while True:
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except OSError as error:
            if error.errno not in (errno.EACCES, errno.EAGAIN):
                raise
            if time.monotonic() >= deadline:
                fail("lifecycle_lock_contended")
            time.sleep(0.05)

    st = lstat_or_none(state_path)
    if st is None:
        with open(meta_path, "w", encoding="utf-8") as handle:
            handle.write("had=0\n")
        raise SystemExit(0)
    if stat.S_ISLNK(st.st_mode):
        fail("lifecycle_state_symlink")
    if not stat.S_ISREG(st.st_mode):
        fail("lifecycle_state_not_regular")
    if st.st_uid != uid:
        fail("lifecycle_state_not_owned")
    if st.st_nlink != 1:
        fail("lifecycle_state_hardlinked")
    if stat.S_IMODE(st.st_mode) != 0o600:
        fail("lifecycle_state_mode:%o" % stat.S_IMODE(st.st_mode))
    if st.st_size > MAX_STATE_BYTES:
        fail("lifecycle_state_oversized:%d" % st.st_size)

    # Read the exact bytes through an O_NOFOLLOW descriptor and confirm the
    # descriptor still refers to the lstat'd inode (defeats a swap between the
    # lstat and open).
    src_fd = os.open(state_path, os.O_RDONLY | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_NOFOLLOW", 0))
    try:
        src_desc = os.fstat(src_fd)
        if (src_desc.st_dev, src_desc.st_ino) != (st.st_dev, st.st_ino):
            fail("lifecycle_state_raced")
        if not stat.S_ISREG(src_desc.st_mode) or src_desc.st_uid != uid or src_desc.st_nlink != 1:
            fail("lifecycle_state_desc_invalid")
        payload = b""
        while len(payload) <= MAX_STATE_BYTES:
            chunk = os.read(src_fd, 65536)
            if not chunk:
                break
            payload += chunk
        if len(payload) > MAX_STATE_BYTES:
            fail("lifecycle_state_oversized_read")
    finally:
        os.close(src_fd)

    # Write the snapshot into a freshly created 0600 destination with umask 077.
    # A pre-existing destination is refused (O_EXCL) so the snapshot cannot land
    # on an attacker-planted target.
    previous_umask = os.umask(0o077)
    try:
        dest_fd = os.open(
            destination_path,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
            0o600,
        )
    finally:
        os.umask(previous_umask)
    dest_dev = None
    dest_ino = None
    try:
        dest_desc = os.fstat(dest_fd)
        dest_dev, dest_ino = dest_desc.st_dev, dest_desc.st_ino
        write_all(dest_fd, payload)
        os.fsync(dest_fd)
    finally:
        os.close(dest_fd)

    # Prove the DESTINATION now holds exactly the captured payload before
    # publishing had=1. Reopen the staged file with O_NOFOLLOW, confirm it is
    # the same owned regular inode we just created (not a swapped/planted
    # target), revalidate type/link-count/mode/size, and byte-compare its
    # contents against the payload. Any mismatch (e.g. a short write) aborts
    # BEFORE the meta file is written, so no truncated snapshot is ever
    # published or later restored.
    verify_fd = os.open(destination_path, os.O_RDONLY | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_NOFOLLOW", 0))
    try:
        verify_desc = os.fstat(verify_fd)
        if (verify_desc.st_dev, verify_desc.st_ino) != (dest_dev, dest_ino):
            fail("lifecycle_snapshot_dest_raced")
        if not stat.S_ISREG(verify_desc.st_mode):
            fail("lifecycle_snapshot_dest_not_regular")
        if verify_desc.st_uid != uid:
            fail("lifecycle_snapshot_dest_not_owned")
        if verify_desc.st_nlink != 1:
            fail("lifecycle_snapshot_dest_hardlinked")
        if stat.S_IMODE(verify_desc.st_mode) != 0o600:
            fail("lifecycle_snapshot_dest_mode:%o" % stat.S_IMODE(verify_desc.st_mode))
        if verify_desc.st_size != len(payload):
            fail("lifecycle_snapshot_dest_size:%d" % verify_desc.st_size)
        staged = b""
        while len(staged) <= MAX_STATE_BYTES:
            chunk = os.read(verify_fd, 65536)
            if not chunk:
                break
            staged += chunk
    finally:
        os.close(verify_fd)
    if staged != payload:
        fail("lifecycle_snapshot_dest_byte_mismatch")

    # Re-verify the source has not changed underneath the copy (lstat again +
    # byte compare) while still holding the lock.
    reverify = lstat_or_none(state_path)
    if reverify is None:
        fail("lifecycle_state_vanished")
    if (
        stat.S_ISLNK(reverify.st_mode)
        or (reverify.st_dev, reverify.st_ino) != (st.st_dev, st.st_ino)
        or reverify.st_size != st.st_size
    ):
        fail("lifecycle_state_changed_during_copy")
    recheck_fd = os.open(state_path, os.O_RDONLY | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_NOFOLLOW", 0))
    try:
        recheck_desc = os.fstat(recheck_fd)
        if (recheck_desc.st_dev, recheck_desc.st_ino) != (st.st_dev, st.st_ino):
            fail("lifecycle_state_raced_recheck")
        recheck = b""
        while len(recheck) <= MAX_STATE_BYTES:
            chunk = os.read(recheck_fd, 65536)
            if not chunk:
                break
            recheck += chunk
    finally:
        os.close(recheck_fd)
    if recheck != payload:
        fail("lifecycle_state_byte_mismatch")

    # The snapshot's writer/pause posture is not threaded through the meta file:
    # restore_lifecycle_state re-reads it from the snapshot and the live file
    # under the lock so no snapshot-time value can go stale.
    with open(meta_path, "w", encoding="utf-8") as handle:
        handle.write("had=1\n")
finally:
    os.close(lock_fd)
PY
}

secure_private_directory() {
  directory_path="$1"
  python3 - "$directory_path" <<'PY'
import ctypes
import errno
import os
import stat
import sys

path = sys.argv[1]
fd = os.open(
    path,
    os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0),
)
try:
    os.fchmod(fd, 0o700)
    info = os.fstat(fd)
    if (
        not stat.S_ISDIR(info.st_mode)
        or info.st_uid != os.getuid()
        or info.st_nlink < 1
        or info.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
    ):
        raise SystemExit("private directory is unsafe")
    if sys.platform == "darwin":
        try:
            libc = ctypes.CDLL(None, use_errno=True)
            acl_get_fd_np = libc.acl_get_fd_np
            acl_get_fd_np.argtypes = [ctypes.c_int, ctypes.c_int]
            acl_get_fd_np.restype = ctypes.c_void_p
            acl_free = libc.acl_free
            acl_free.argtypes = [ctypes.c_void_p]
            acl_free.restype = ctypes.c_int
        except (AttributeError, OSError):
            raise SystemExit("private directory ACL API is unavailable")
        ctypes.set_errno(0)
        acl = acl_get_fd_np(fd, 0x00000100)  # ACL_TYPE_EXTENDED
        if acl:
            acl_free(acl)
            raise SystemExit("private directory has an extended ACL")
        if ctypes.get_errno() != errno.ENOENT:
            raise SystemExit("private directory ACL verification failed")
    os.fsync(fd)
finally:
    os.close(fd)
PY
}

write_install_recovery_artifacts() {
  recovery_dir="$1"
  state_path="$recovery_dir/state.sh"
  recovery_script="$recovery_dir/recover.sh"
  recovery_headless_incumbent_sha256=""
  : "${LAUNCHD_DOMAIN:=gui/$UID}"
  : "${HEADLESS:=0}"
  : "${HEADLESS_USER:=}"
  : "${PLIST_BOOTSTRAP_PATH:=$PLIST_PATH}"
  : "${LEGACY_PLIST_BOOTSTRAP_PATH:=$LEGACY_PLIST_PATH}"
  : "${WATCHDOG_PLIST_BOOTSTRAP_PATH:=$WATCHDOG_PLIST_PATH}"
  : "${LEGACY_WATCHDOG_PLIST_BOOTSTRAP_PATH:=$LEGACY_WATCHDOG_PLIST_PATH}"
  if headless_acceptance_repair_mode; then
    [ -n "${HEADLESS_REPAIR_INCUMBENT_BINARY:-}" ] || return 1
    recovery_headless_incumbent_sha256="${HEADLESS_REPAIR_INCUMBENT_SHA256:-}"
    case "$recovery_headless_incumbent_sha256" in
      [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
      *) return 1 ;;
    esac
  fi

  {
    printf 'REC_INSTALL_DIR=%q\n' "$INSTALL_DIR"
    printf 'REC_BINARY_PATH=%q\n' "$BINARY_PATH"
    printf 'REC_CONFIG_PATH=%q\n' "$CONFIG_PATH"
    printf 'REC_PROVIDER_ID_PATH=%q\n' "$PROVIDER_ID_PATH"
    printf 'REC_RECOMMENDATION_PATH=%q\n' "$RECOMMENDATION_PATH"
    printf 'REC_PROVIDER_LABEL=%q\n' "$PROVIDER_LABEL"
    printf 'REC_PLIST_PATH=%q\n' "$PLIST_PATH"
    printf 'REC_PLIST_BOOTSTRAP_PATH=%q\n' "$PLIST_BOOTSTRAP_PATH"
    printf 'REC_WATCHDOG_DIR=%q\n' "$WATCHDOG_DIR"
    printf 'REC_WATCHDOG_PLIST_PATH=%q\n' "$WATCHDOG_PLIST_PATH"
    printf 'REC_WATCHDOG_PLIST_BOOTSTRAP_PATH=%q\n' "$WATCHDOG_PLIST_BOOTSTRAP_PATH"
    printf 'REC_WATCHDOG_LABEL=%q\n' "$WATCHDOG_LABEL"
    printf 'REC_MANIFEST_PATH=%q\n' "$MANIFEST_PATH"
    printf 'REC_LIFECYCLE_STATE_PATH=%q\n' "$LIFECYCLE_STATE_PATH"
    printf 'REC_LIFECYCLE_LEASE_PATH=%q\n' "$LIFECYCLE_LEASE_PATH"
    printf 'REC_LIFECYCLE_STATE_LOCK_PATH=%q\n' "$LIFECYCLE_STATE_LOCK_PATH"
    printf 'REC_LIFECYCLE_LEASE_LOCK_PATH=%q\n' "$LIFECYCLE_LEASE_LOCK_PATH"
    printf 'REC_LIFECYCLE_INSTALL_OPERATION_ID=%q\n' "${LIFECYCLE_INSTALL_OPERATION_ID:-}"
    printf 'REC_LOG_DIR=%q\n' "$LOG_DIR"
    printf 'REC_INSTALL_RECOVERY_LABEL=%q\n' "$INSTALL_RECOVERY_LABEL"
    printf 'REC_INSTALL_RECOVERY_PLIST_PATH=%q\n' "$INSTALL_RECOVERY_PLIST_PATH"
    printf 'REC_LAUNCHD_DOMAIN=%q\n' "$LAUNCHD_DOMAIN"
    printf 'REC_HEADLESS=%q\n' "$HEADLESS"
    printf 'REC_HEADLESS_USER=%q\n' "$HEADLESS_USER"
    if headless_acceptance_repair_mode; then
      printf 'REC_HEADLESS_REPAIR_INCUMBENT_BINARY=%q\n' "${HEADLESS_REPAIR_INCUMBENT_BINARY:-}"
      printf 'REC_HEADLESS_REPAIR_INCUMBENT_SHA256=%q\n' "$recovery_headless_incumbent_sha256"
    else
      printf 'REC_HEADLESS_REPAIR_INCUMBENT_BINARY=%q\n' ""
      printf 'REC_HEADLESS_REPAIR_INCUMBENT_SHA256=%q\n' ""
    fi
    printf 'REC_INSTALL_LOCK_PATH=%q\n' "$INSTALL_LOCK_PATH"
    printf 'REC_INSTALL_LOCK_TOKEN=%q\n' "$INSTALL_LOCK_TOKEN"
    printf 'REC_INSTALLER_PID=%q\n' "$$"
    printf 'REC_INSTALLER_PROCESS_START=%q\n' "$(ps -p $$ -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    printf 'REC_INSTALLER_BOOT_SESSION=%q\n' "$(/usr/sbin/sysctl -n kern.bootsessionuuid 2>/dev/null || true)"
    printf 'REC_MANUAL_READY_TIMEOUT_SECONDS=%q\n' "15"
    printf 'REC_UID=%q\n' "$UID"
    printf 'REC_HAD_INSTALL_DIR=%q\n' "$INSTALL_TX_HAD_INSTALL_DIR"
    printf 'REC_HAD_BINARY_PATH=%q\n' "$INSTALL_TX_HAD_BINARY_PATH"
    printf 'REC_HAD_CONFIG=%q\n' "$INSTALL_TX_HAD_CONFIG"
    printf 'REC_HAD_PROVIDER_ID=%q\n' "$INSTALL_TX_HAD_PROVIDER_ID"
    printf 'REC_HAD_RECOMMENDATION=%q\n' "$INSTALL_TX_HAD_RECOMMENDATION"
    printf 'REC_HAD_PLIST=%q\n' "$INSTALL_TX_HAD_PLIST"
    printf 'REC_HAD_LEGACY_PLIST=%q\n' "$INSTALL_TX_HAD_LEGACY_PLIST"
    printf 'REC_HAD_WATCHDOG_DIR=%q\n' "$INSTALL_TX_HAD_WATCHDOG_DIR"
    printf 'REC_HAD_WATCHDOG_PLIST=%q\n' "$INSTALL_TX_HAD_WATCHDOG_PLIST"
    printf 'REC_HAD_LEGACY_WATCHDOG_PLIST=%q\n' "$INSTALL_TX_HAD_LEGACY_WATCHDOG_PLIST"
    printf 'REC_HAD_MANIFEST=%q\n' "$INSTALL_TX_HAD_MANIFEST"
    printf 'REC_HAD_LIFECYCLE_STATE=%q\n' "$INSTALL_TX_HAD_LIFECYCLE_STATE"
    printf 'REC_SERVICE_WAS_ACTIVE=%q\n' "$INSTALL_TX_SERVICE_WAS_ACTIVE"
    printf 'REC_LEGACY_SERVICE_WAS_ACTIVE=%q\n' "$INSTALL_TX_LEGACY_SERVICE_WAS_ACTIVE"
    printf 'REC_LEGACY_PROVIDER_LABEL=%q\n' "$LEGACY_PROVIDER_LABEL"
    printf 'REC_LEGACY_PLIST_PATH=%q\n' "$LEGACY_PLIST_PATH"
    printf 'REC_LEGACY_PLIST_BOOTSTRAP_PATH=%q\n' "$LEGACY_PLIST_BOOTSTRAP_PATH"
    printf 'REC_SERVICE_WAS_DISABLED=%q\n' "$INSTALL_TX_SERVICE_WAS_DISABLED"
    printf 'REC_WATCHDOG_WAS_ACTIVE=%q\n' "$INSTALL_TX_WATCHDOG_WAS_ACTIVE"
    printf 'REC_LEGACY_WATCHDOG_WAS_ACTIVE=%q\n' "$INSTALL_TX_LEGACY_WATCHDOG_WAS_ACTIVE"
    printf 'REC_LEGACY_WATCHDOG_LABEL=%q\n' "$LEGACY_WATCHDOG_LABEL"
    printf 'REC_LEGACY_WATCHDOG_PLIST_PATH=%q\n' "$LEGACY_WATCHDOG_PLIST_PATH"
    printf 'REC_LEGACY_WATCHDOG_PLIST_BOOTSTRAP_PATH=%q\n' "$LEGACY_WATCHDOG_PLIST_BOOTSTRAP_PATH"
    printf 'REC_WATCHDOG_WAS_DISABLED=%q\n' "$INSTALL_TX_WATCHDOG_WAS_DISABLED"
    printf 'REC_BINARY_KIND=%q\n' "$INSTALL_TX_BINARY_KIND"
    printf 'REC_REFERRAL_REPLACE_INCUMBENT=%q\n' "$REFERRAL_REPLACE_INCUMBENT"
  } | write_atomic_install_file "$state_path" 0600 || return 1

  write_atomic_install_file "$recovery_script" 0700 <<'RECOVERY_SCRIPT'
#!/usr/bin/env bash
set -u

RECOVERY_DIR="$(cd "$(dirname "$0")" && pwd)" || exit 70
verify_recovery_artifact() {
  artifact_path="$1"
  expected_payload="${2-}"
  python3 - "$artifact_path" "$expected_payload" <<'PY'
import ctypes
import errno
import os
import stat
import sys

path, expected = sys.argv[1:]
max_bytes = 1024 * 1024
fd = os.open(
    path,
    os.O_RDONLY | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_NOFOLLOW", 0),
)
try:
    before = os.fstat(fd)
    if (
        not stat.S_ISREG(before.st_mode)
        or before.st_uid != os.getuid()
        or before.st_nlink != 1
        or before.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
        or before.st_size > max_bytes
    ):
        raise SystemExit("recovery artifact is unsafe")
    if sys.platform == "darwin":
        try:
            libc = ctypes.CDLL(None, use_errno=True)
            acl_get_fd_np = libc.acl_get_fd_np
            acl_get_fd_np.argtypes = [ctypes.c_int, ctypes.c_int]
            acl_get_fd_np.restype = ctypes.c_void_p
            acl_free = libc.acl_free
            acl_free.argtypes = [ctypes.c_void_p]
            acl_free.restype = ctypes.c_int
        except (AttributeError, OSError):
            raise SystemExit("recovery artifact ACL API is unavailable")
        ctypes.set_errno(0)
        acl = acl_get_fd_np(fd, 0x00000100)  # ACL_TYPE_EXTENDED
        if acl:
            acl_free(acl)
            raise SystemExit("recovery artifact has an extended ACL")
        if ctypes.get_errno() != errno.ENOENT:
            raise SystemExit("recovery artifact ACL verification failed")
    data = os.read(fd, before.st_size + 1)
    if len(data) != before.st_size:
        raise SystemExit("recovery artifact was truncated")
    after = os.fstat(fd)
    if (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns) != (
        before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns
    ):
        raise SystemExit("recovery artifact changed during verification")
    path_info = os.lstat(path)
    if stat.S_ISLNK(path_info.st_mode) or (path_info.st_dev, path_info.st_ino) != (before.st_dev, before.st_ino):
        raise SystemExit("recovery artifact path was replaced")
    if expected and data != (expected + "\n").encode("utf-8"):
        raise SystemExit("recovery marker payload is invalid")
finally:
    os.close(fd)
PY
}
verify_recovery_artifact "$RECOVERY_DIR/state.sh" || exit 70
verify_recovery_artifact "$RECOVERY_DIR/recover.sh" || exit 70
for recovery_marker in cutover-started provider-service-created watchdog-service-created new-manual.pid; do
  if [ -e "$RECOVERY_DIR/$recovery_marker" ] || [ -L "$RECOVERY_DIR/$recovery_marker" ]; then
    case "$recovery_marker" in
      cutover-started) recovery_marker_payload="cutover-started" ;;
      provider-service-created|watchdog-service-created) recovery_marker_payload="transaction-created" ;;
      new-manual.pid) recovery_marker_payload="" ;;
    esac
    verify_recovery_artifact "$RECOVERY_DIR/$recovery_marker" "$recovery_marker_payload" || exit 70
  fi
done
# shellcheck disable=SC1091
. "$RECOVERY_DIR/state.sh" || exit 70
REC_PROVIDER_LABEL="${REC_PROVIDER_LABEL:-live.malibu.provider}"
REC_LEGACY_PROVIDER_LABEL="${REC_LEGACY_PROVIDER_LABEL:-live.streamvc.macprovider}"
REC_LEGACY_PLIST_PATH="${REC_LEGACY_PLIST_PATH:-$HOME/Library/LaunchAgents/live.streamvc.macprovider.plist}"
REC_LEGACY_SERVICE_WAS_ACTIVE="${REC_LEGACY_SERVICE_WAS_ACTIVE:-0}"
REC_HAD_LEGACY_PLIST="${REC_HAD_LEGACY_PLIST:-0}"
REC_LEGACY_WATCHDOG_LABEL="${REC_LEGACY_WATCHDOG_LABEL:-live.streamvc.macprovider-watchdog}"
REC_LEGACY_WATCHDOG_PLIST_PATH="${REC_LEGACY_WATCHDOG_PLIST_PATH:-$HOME/Library/LaunchAgents/live.streamvc.macprovider-watchdog.plist}"
REC_LEGACY_WATCHDOG_WAS_ACTIVE="${REC_LEGACY_WATCHDOG_WAS_ACTIVE:-0}"
REC_HAD_LEGACY_WATCHDOG_PLIST="${REC_HAD_LEGACY_WATCHDOG_PLIST:-0}"
REC_LAUNCHD_DOMAIN="${REC_LAUNCHD_DOMAIN:-gui/$REC_UID}"
REC_HEADLESS="${REC_HEADLESS:-0}"
REC_BINARY_PATH="${REC_BINARY_PATH:-}"
REC_HEADLESS_REPAIR_INCUMBENT_BINARY="${REC_HEADLESS_REPAIR_INCUMBENT_BINARY:-}"
REC_HEADLESS_REPAIR_INCUMBENT_SHA256="${REC_HEADLESS_REPAIR_INCUMBENT_SHA256:-}"
REC_PLIST_BOOTSTRAP_PATH="${REC_PLIST_BOOTSTRAP_PATH:-$REC_PLIST_PATH}"
REC_LEGACY_PLIST_BOOTSTRAP_PATH="${REC_LEGACY_PLIST_BOOTSTRAP_PATH:-$REC_LEGACY_PLIST_PATH}"
REC_WATCHDOG_PLIST_BOOTSTRAP_PATH="${REC_WATCHDOG_PLIST_BOOTSTRAP_PATH:-$REC_WATCHDOG_PLIST_PATH}"
REC_LEGACY_WATCHDOG_PLIST_BOOTSTRAP_PATH="${REC_LEGACY_WATCHDOG_PLIST_BOOTSTRAP_PATH:-$REC_LEGACY_WATCHDOG_PLIST_PATH}"

validate_headless_recovery_targets() {
  [ "$REC_HEADLESS" = "1" ] || return 0
  current_user="$(id -un)" || return 70
  managed_dir="$(dirname "$REC_CONFIG_PATH")/launchd"
  [ "$REC_LAUNCHD_DOMAIN" = "system" ] || return 70
  [ "$REC_HEADLESS_USER" = "$current_user" ] || return 70
  [ "$REC_PROVIDER_LABEL" = "live.malibu.provider" ] || return 70
  [ "$REC_LEGACY_PROVIDER_LABEL" = "live.streamvc.macprovider" ] || return 70
  [ "$REC_WATCHDOG_LABEL" = "live.malibu.provider-watchdog" ] || return 70
  [ "$REC_LEGACY_WATCHDOG_LABEL" = "live.streamvc.macprovider-watchdog" ] || return 70
  [ "$REC_PLIST_PATH" = "$managed_dir/live.malibu.provider.plist" ] || return 70
  [ "$REC_LEGACY_PLIST_PATH" = "$managed_dir/live.streamvc.macprovider.plist" ] || return 70
  [ "$REC_WATCHDOG_PLIST_PATH" = "$managed_dir/live.malibu.provider-watchdog.plist" ] || return 70
  [ "$REC_LEGACY_WATCHDOG_PLIST_PATH" = "$managed_dir/live.streamvc.macprovider-watchdog.plist" ] || return 70
  [ "$REC_PLIST_BOOTSTRAP_PATH" = "/Library/LaunchDaemons/live.malibu.provider.plist" ] || return 70
  [ "$REC_LEGACY_PLIST_BOOTSTRAP_PATH" = "/Library/LaunchDaemons/live.streamvc.macprovider.plist" ] || return 70
  [ "$REC_WATCHDOG_PLIST_BOOTSTRAP_PATH" = "/Library/LaunchDaemons/live.malibu.provider-watchdog.plist" ] || return 70
  [ "$REC_LEGACY_WATCHDOG_PLIST_BOOTSTRAP_PATH" = "/Library/LaunchDaemons/live.streamvc.macprovider-watchdog.plist" ] || return 70
  if [ -n "$REC_HEADLESS_REPAIR_INCUMBENT_BINARY" ]; then
    [ "$REC_HEADLESS_REPAIR_INCUMBENT_SHA256" != "" ] || return 70
    case "$REC_HEADLESS_REPAIR_INCUMBENT_SHA256" in
      [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
      *) return 70 ;;
    esac
    case "$REC_HEADLESS_REPAIR_INCUMBENT_BINARY" in
      "$HOME"/*) ;;
      *) return 70 ;;
    esac
  fi
}
validate_headless_recovery_targets || {
  printf '[macprovider-recovery] Headless recovery state contains an unsafe privileged launchd target.\n' >&2
  exit 70
}

validate_recovery_incumbent_provider_binary() {
  [ -n "$REC_HEADLESS_REPAIR_INCUMBENT_BINARY" ] || return 0
  [ "$REC_HEADLESS" = "1" ] || return 70
  [ "$REC_LAUNCHD_DOMAIN" = "system" ] || return 70
  python3 - "$REC_HEADLESS_REPAIR_INCUMBENT_BINARY" "$REC_HEADLESS_REPAIR_INCUMBENT_SHA256" <<'PY'
import ctypes
import errno
import hashlib
import os
import stat
import sys

path, expected_sha256 = sys.argv[1:]
if not os.path.isabs(path):
    raise SystemExit("incumbent binary path is not absolute")
if len(expected_sha256) != 64 or any(character not in "0123456789abcdef" for character in expected_sha256):
    raise SystemExit("incumbent binary digest is invalid")
nofollow = getattr(os, "O_NOFOLLOW", 0)
fd = os.open(path, os.O_RDONLY | getattr(os, "O_NONBLOCK", 0) | nofollow)
try:
    info = os.fstat(fd)
    path_info = os.lstat(path)
    if (
        not stat.S_ISREG(info.st_mode)
        or path_info.st_dev != info.st_dev
        or path_info.st_ino != info.st_ino
        or stat.S_ISLNK(path_info.st_mode)
        or info.st_uid != os.getuid()
        or info.st_nlink != 1
        or info.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
        or not info.st_mode & stat.S_IXUSR
    ):
        raise SystemExit("unsafe incumbent binary")
    if sys.platform == "darwin":
        try:
            libc = ctypes.CDLL(None, use_errno=True)
            acl_get_fd_np = libc.acl_get_fd_np
            acl_get_fd_np.argtypes = [ctypes.c_int, ctypes.c_int]
            acl_get_fd_np.restype = ctypes.c_void_p
            acl_free = libc.acl_free
            acl_free.argtypes = [ctypes.c_void_p]
            acl_free.restype = ctypes.c_int
        except (AttributeError, OSError):
            raise SystemExit("incumbent binary ACL API is unavailable")
        ctypes.set_errno(0)
        acl = acl_get_fd_np(fd, 0x00000100)  # ACL_TYPE_EXTENDED
        if acl:
            acl_free(acl)
            raise SystemExit("incumbent binary has an extended ACL")
        if ctypes.get_errno() != errno.ENOENT:
            raise SystemExit("incumbent binary ACL verification failed")
    digest = hashlib.sha256()
    while True:
        chunk = os.read(fd, 65536)
        if not chunk:
            break
        digest.update(chunk)
    after = os.fstat(fd)
    if (
        (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns)
        != (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)
    ):
        raise SystemExit("incumbent binary changed during verification")
    if digest.hexdigest() != expected_sha256:
        raise SystemExit("incumbent binary digest changed")
finally:
    os.close(fd)
PY
}
validate_recovery_incumbent_provider_binary || {
  printf '[macprovider-recovery] Headless recovery state contains an unsafe incumbent provider binary.\n' >&2
  exit 70
}

recovery_launchctl() {
  if [ "$REC_HEADLESS" = "1" ]; then
    /usr/bin/sudo -n /bin/launchctl "$@"
  else
    launchctl "$@"
  fi
}

# F6 (#1364): `launchctl bootstrap` can transiently return "Input/output error"
# on a launchd domain that is briefly refusing new services (observed 6/6 on an
# isolated GUI domain during acceptance; it cleared only after a re-login). A
# single failed bootstrap previously tripped `recovery_failed` -> exit 70,
# leaving the provider down AND a preserved bundle that hard-blocked the next
# install. Retry with a short linear backoff, booting out any half-loaded label
# between attempts, so a transient domain I/O error clears in place instead of
# wedging recovery. A label that is already loaded (a prior partial bootstrap)
# is treated as success; the caller still verifies the launchd identity.
recovery_bootstrap_service() {
  bootstrap_domain="$1"
  bootstrap_plist_path="$2"
  bootstrap_label="$3"
  bootstrap_attempt=0
  bootstrap_max_attempts="${MACPROVIDER_RECOVERY_BOOTSTRAP_ATTEMPTS:-5}"
  bootstrap_backoff_unit="${MACPROVIDER_RECOVERY_BOOTSTRAP_BACKOFF_SECONDS:-2}"
  while :; do
    bootstrap_attempt=$((bootstrap_attempt + 1))
    if recovery_launchctl bootstrap "$bootstrap_domain" "$bootstrap_plist_path" >/dev/null 2>&1; then
      return 0
    fi
    if recovery_launchctl print "$bootstrap_domain/$bootstrap_label" >/dev/null 2>&1; then
      return 0
    fi
    if [ "$bootstrap_attempt" -ge "$bootstrap_max_attempts" ]; then
      return 1
    fi
    recovery_log "launchctl bootstrap of $bootstrap_label was refused (attempt ${bootstrap_attempt}/${bootstrap_max_attempts}); booting out any partial load and retrying."
    recovery_launchctl bootout "$bootstrap_domain/$bootstrap_label" >/dev/null 2>&1 || true
    sleep "$(( bootstrap_attempt * bootstrap_backoff_unit ))"
  done
}

# Same failure as recovery_failed but with the concrete, non-folklore
# remediation for a launchd domain that keeps refusing a (re)start: the
# previous provider files are restored on disk, only the service is not
# running, and a re-login / reboot recreates the domain so the preserved
# recover.sh can finish.
recovery_bootstrap_failed() {
  recovery_log "$1"
  recovery_log "The previous provider files are restored on disk, but launchd refused to (re)start the service after retries — usually a transient launchd domain I/O error."
  recovery_log "Log out and back in (or reboot) to recreate the launchd session, then retry exactly: bash '$RECOVERY_DIR/recover.sh'"
  exit 70
}

validate_recovery_launchdaemon_plist() {
  managed_path="$1"
  bootstrap_path="$2"
  python3 - "$managed_path" "$bootstrap_path" "$REC_HEADLESS_USER" \
    "$REC_INSTALL_DIR/macprovider-cli" "$REC_BINARY_PATH" "$REC_HEADLESS_REPAIR_INCUMBENT_BINARY" \
    "/Library/Application Support/macprovider/macprovider-health-monitor" "$REC_CONFIG_PATH" <<'PY'
import os
import plistlib
import sys

path, bootstrap_path, user, provider_program, provider_alternate, provider_alternate_2, watchdog_program, config_path = sys.argv[1:]
provider_programs = [provider_program]
legacy_provider_programs = [provider_program]
if provider_alternate:
    provider_programs.append(provider_alternate)
    legacy_provider_programs.append(provider_alternate)
if provider_alternate_2:
    provider_programs.append(provider_alternate_2)
allowed = {
    "/Library/LaunchDaemons/live.malibu.provider.plist": ("live.malibu.provider", provider_programs),
    "/Library/LaunchDaemons/live.streamvc.macprovider.plist": ("live.streamvc.macprovider", legacy_provider_programs),
    "/Library/LaunchDaemons/live.malibu.provider-watchdog.plist": ("live.malibu.provider-watchdog", [watchdog_program]),
    "/Library/LaunchDaemons/live.streamvc.macprovider-watchdog.plist": ("live.streamvc.macprovider-watchdog", [watchdog_program]),
}
expected = allowed.get(bootstrap_path)
if expected is None:
    raise SystemExit("unexpected LaunchDaemon target")
with open(path, "rb") as handle:
    payload = plistlib.load(handle)
arguments = payload.get("ProgramArguments")
environment = payload.get("EnvironmentVariables")
if payload.get("Label") != expected[0]:
    raise SystemExit("unexpected LaunchDaemon identity")
if not isinstance(arguments, list) or not arguments or arguments[0] not in expected[1]:
    raise SystemExit("unexpected LaunchDaemon program")
if expected[0].endswith("-watchdog"):
    if "UserName" in payload:
        raise SystemExit("watchdog LaunchDaemon must remain root-owned")
else:
    if payload.get("UserName") != user:
        raise SystemExit("unexpected provider LaunchDaemon user")
if not isinstance(environment, dict):
    raise SystemExit("missing LaunchDaemon environment")
if environment.get("MACPROVIDER_HEADLESS") != "1" or environment.get("MACPROVIDER_LAUNCHD_DOMAIN") != "system":
    raise SystemExit("missing headless LaunchDaemon binding")
if environment.get("MACPROVIDER_HEADLESS_USER") != user:
    raise SystemExit("unexpected LaunchDaemon fleet user")
if environment.get("MACPROVIDER_PROTECTED_CREDENTIAL_ROOT") != os.path.join(os.path.dirname(config_path), "protected-credentials"):
    raise SystemExit("unexpected protected credential root")
if expected[0] == "live.malibu.provider" and environment.get("MACPROVIDER_CONFIG") != config_path:
    raise SystemExit("unexpected provider config path")
if expected[0] == "live.malibu.provider-watchdog" and environment.get("MACPROVIDER_CONFIG_PATH") != config_path:
    raise SystemExit("unexpected watchdog config path")
PY
}

snapshot_recovery_launchdaemon_plist() {
  managed_path="$1"
  bootstrap_path="$2"
  python3 - "$managed_path" "$bootstrap_path" "$REC_HEADLESS_USER" \
    "$REC_INSTALL_DIR/macprovider-cli" "$REC_BINARY_PATH" "$REC_HEADLESS_REPAIR_INCUMBENT_BINARY" \
    "/Library/Application Support/macprovider/macprovider-health-monitor" "$REC_CONFIG_PATH" <<'PY'
import base64
import os
import plistlib
import stat
import sys

path, bootstrap_path, user, provider_program, provider_alternate, provider_alternate_2, watchdog_program, config_path = sys.argv[1:]
provider_programs = [provider_program]
legacy_provider_programs = [provider_program]
if provider_alternate:
    provider_programs.append(provider_alternate)
    legacy_provider_programs.append(provider_alternate)
if provider_alternate_2:
    provider_programs.append(provider_alternate_2)
allowed = {
    "/Library/LaunchDaemons/live.malibu.provider.plist": ("live.malibu.provider", provider_programs),
    "/Library/LaunchDaemons/live.streamvc.macprovider.plist": ("live.streamvc.macprovider", legacy_provider_programs),
    "/Library/LaunchDaemons/live.malibu.provider-watchdog.plist": ("live.malibu.provider-watchdog", [watchdog_program]),
    "/Library/LaunchDaemons/live.streamvc.macprovider-watchdog.plist": ("live.streamvc.macprovider-watchdog", [watchdog_program]),
}
expected = allowed.get(bootstrap_path)
if expected is None:
    raise SystemExit("unexpected LaunchDaemon target")
fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0))
try:
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        raise SystemExit("unsafe LaunchDaemon source")
    data = os.read(fd, 1048577)
    if len(data) > 1048576:
        raise SystemExit("LaunchDaemon source too large")
finally:
    os.close(fd)
payload = plistlib.loads(data)
arguments = payload.get("ProgramArguments")
environment = payload.get("EnvironmentVariables")
if payload.get("Label") != expected[0]:
    raise SystemExit("unexpected LaunchDaemon identity")
if not isinstance(arguments, list) or not arguments or arguments[0] not in expected[1]:
    raise SystemExit("unexpected LaunchDaemon program")
if expected[0].endswith("-watchdog"):
    if "UserName" in payload:
        raise SystemExit("watchdog LaunchDaemon must remain root-owned")
else:
    if payload.get("UserName") != user:
        raise SystemExit("unexpected provider LaunchDaemon user")
if not isinstance(environment, dict):
    raise SystemExit("missing LaunchDaemon environment")
if environment.get("MACPROVIDER_HEADLESS") != "1" or environment.get("MACPROVIDER_LAUNCHD_DOMAIN") != "system":
    raise SystemExit("missing headless LaunchDaemon binding")
if environment.get("MACPROVIDER_HEADLESS_USER") != user:
    raise SystemExit("unexpected LaunchDaemon fleet user")
if environment.get("MACPROVIDER_PROTECTED_CREDENTIAL_ROOT") != os.path.join(os.path.dirname(config_path), "protected-credentials"):
    raise SystemExit("unexpected protected credential root")
if expected[0] == "live.malibu.provider" and environment.get("MACPROVIDER_CONFIG") != config_path:
    raise SystemExit("unexpected provider config path")
if expected[0] == "live.malibu.provider-watchdog" and environment.get("MACPROVIDER_CONFIG_PATH") != config_path:
    raise SystemExit("unexpected watchdog config path")
sys.stdout.write(base64.b64encode(data).decode("ascii"))
PY
}

recovery_publish_root_file_from_base64() {
  target_path="$1"
  mode="$2"
  payload_b64="$3"
  MACPROVIDER_ROOT_FILE_B64="$payload_b64" /usr/bin/sudo -n /usr/bin/python3 - "$target_path" "$mode" <<'PY'
import base64
import os
import sys
import uuid

target = sys.argv[1]
mode = int(sys.argv[2], 8)
payload = base64.b64decode(os.environ["MACPROVIDER_ROOT_FILE_B64"], validate=True)
directory = os.path.dirname(target)
temporary = os.path.join(directory, f".{os.path.basename(target)}.{uuid.uuid4()}.tmp")
fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), mode)
try:
    written = 0
    while written < len(payload):
        progress = os.write(fd, payload[written:])
        if progress <= 0:
            raise RuntimeError("short write while publishing root file")
        written += progress
    os.fchmod(fd, mode)
    if os.geteuid() == 0:
        os.fchown(fd, 0, 0)
    os.fsync(fd)
finally:
    os.close(fd)
os.replace(temporary, target)
dir_fd = os.open(directory, os.O_RDONLY)
try:
    os.fsync(dir_fd)
finally:
    os.close(dir_fd)
PY
}

sync_recovery_launchd_plist() {
  managed_path="$1"
  bootstrap_path="$2"
  had_previous="$3"
  [ "$REC_HEADLESS" = "1" ] || return 0
  if [ "$had_previous" -eq 1 ]; then
    validate_recovery_launchdaemon_plist "$managed_path" "$bootstrap_path" || return 70
    plist_payload_b64="$(snapshot_recovery_launchdaemon_plist "$managed_path" "$bootstrap_path")" || return 70
    recovery_publish_root_file_from_base64 "$bootstrap_path" 0644 "$plist_payload_b64"
  else
    /usr/bin/sudo -n /bin/rm -f "$bootstrap_path"
  fi
}

recovery_log() { printf '[macprovider-recovery] %s\n' "$*" >&2; }
acquire_recovery_claim() {
  claim_status="$(mktemp "${TMPDIR:-/tmp}/macprovider-recovery-claim.XXXXXX")" || return 70
  python3 - "$RECOVERY_DIR/recovery.lock" "$$" "$claim_status" <<'PY' &
import fcntl
import json
import os
import signal
import stat
import subprocess
import sys
import time

path, parent_pid_text, status_path = sys.argv[1:]
parent_pid = int(parent_pid_text)
uid = os.getuid()
def process_start(pid):
    return subprocess.run(
        ["ps", "-p", str(pid), "-o", "lstart="], check=False,
        capture_output=True, text=True,
    ).stdout.strip()
def boot_session():
    value = subprocess.run(
        ["/usr/sbin/sysctl", "-n", "kern.bootsessionuuid"], check=False,
        capture_output=True, text=True,
    ).stdout.strip()
    if value:
        return value
    try:
        with open("/proc/sys/kernel/random/boot_id", encoding="ascii") as handle:
            return handle.read().strip()
    except OSError:
        return ""
def write_status(value):
    fd = os.open(status_path, os.O_WRONLY | os.O_TRUNC | getattr(os, "O_NOFOLLOW", 0))
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != uid:
            raise RuntimeError("unsafe recovery lock handshake")
        os.write(fd, (value + "\n").encode("utf-8"))
        os.fsync(fd)
    finally:
        os.close(fd)
flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
fd = os.open(path, flags, 0o600)
try:
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        raise RuntimeError("unsafe recovery lock")
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        write_status("busy")
        raise SystemExit(75)
    current_boot = boot_session()
    if not current_boot:
        raise RuntimeError("could not identify recovery boot session")
    existing_payload = os.read(fd, 4097)
    if len(existing_payload) > 4096:
        raise RuntimeError("recovery lock record is oversized")
    if existing_payload.strip():
        try:
            existing = json.loads(existing_payload.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise RuntimeError("recovery lock record is invalid") from error
        existing_pid = existing.get("pid")
        existing_start = existing.get("process_start")
        if (
            isinstance(existing_pid, int)
            and isinstance(existing_start, str)
            and existing_start
            and existing.get("boot_session") == current_boot
            and process_start(existing_pid) == existing_start
        ):
            write_status("busy")
            raise SystemExit(75)
    parent_start = process_start(parent_pid)
    if not parent_start:
        raise RuntimeError("recovery parent disappeared")
    record = {
        "pid": parent_pid,
        "process_start": parent_start,
        "boot_session": current_boot,
        "holder_pid": os.getpid(),
        "holder_process_start": process_start(os.getpid()),
    }
    payload = (json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
    os.lseek(fd, 0, os.SEEK_SET)
    os.ftruncate(fd, 0)
    os.write(fd, payload)
    os.fsync(fd)
    write_status("ok")
    stopping = [False]
    signal.signal(signal.SIGTERM, lambda _signal, _frame: stopping.__setitem__(0, True))
    while not stopping[0]:
        current = process_start(parent_pid)
        if current != parent_start:
            break
        time.sleep(0.25)
except SystemExit:
    raise
except BaseException as error:
    try:
        write_status(f"error:{error}")
    except BaseException:
        pass
    raise
finally:
    os.close(fd)
PY
  RECOVERY_CLAIM_HOLDER_PID=$!
  claim_wait=0
  while [ "$claim_wait" -lt 100 ] && [ ! -s "$claim_status" ]; do
    kill -0 "$RECOVERY_CLAIM_HOLDER_PID" >/dev/null 2>&1 || break
    sleep 0.05
    claim_wait=$((claim_wait + 1))
  done
  claim_result="$(cat "$claim_status" 2>/dev/null || true)"
  rm -f "$claim_status"
  case "$claim_result" in
    ok) return 0 ;;
    busy)
      wait "$RECOVERY_CLAIM_HOLDER_PID" >/dev/null 2>&1 || true
      RECOVERY_CLAIM_HOLDER_PID=""
      recovery_log "Recovery is already active for this transaction."
      return 75
      ;;
    *)
      kill -TERM "$RECOVERY_CLAIM_HOLDER_PID" >/dev/null 2>&1 || true
      wait "$RECOVERY_CLAIM_HOLDER_PID" >/dev/null 2>&1 || true
      RECOVERY_CLAIM_HOLDER_PID=""
      recovery_log "Could not acquire recovery claim: ${claim_result#error:}"
      return 70
      ;;
  esac
}
release_recovery_claim() {
  if [ -n "${RECOVERY_CLAIM_HOLDER_PID:-}" ]; then
    kill -TERM "$RECOVERY_CLAIM_HOLDER_PID" >/dev/null 2>&1 || true
    wait "$RECOVERY_CLAIM_HOLDER_PID" >/dev/null 2>&1 || true
  fi
}
acquire_recovery_claim || exit $?
trap release_recovery_claim EXIT
path_exists() { [ -e "$1" ] || [ -L "$1" ]; }
fsync_directory_path() {
  directory_path="$1"
  python3 - "$directory_path" <<'PY'
import os
import stat
import sys

path = sys.argv[1]
fd = os.open(
    path,
    os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0),
)
try:
    info = os.fstat(fd)
    if (
        not stat.S_ISDIR(info.st_mode)
        or info.st_uid != os.getuid()
        or info.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
    ):
        raise SystemExit("unsafe recovery parent directory")
    os.fsync(fd)
finally:
    os.close(fd)
PY
}
durable_move() {
  local move_source="$1"
  local move_destination="$2"
  mv "$move_source" "$move_destination" || return 1
  fsync_directory_path "$(dirname "$move_source")" || return 1
  fsync_directory_path "$(dirname "$move_destination")" || return 1
}
paths_match() {
  source_path="$1"
  copied_path="$2"
  path_kind="$3"
  python3 - "$source_path" "$copied_path" "$path_kind" <<'PY'
import os
import stat
import sys

source_path, copied_path, path_kind = sys.argv[1:]
nofollow = getattr(os, "O_NOFOLLOW", 0)
nonblock = getattr(os, "O_NONBLOCK", 0)


def identity(info):
    return (
        info.st_dev,
        info.st_ino,
        info.st_size,
        info.st_mtime_ns,
        info.st_ctime_ns,
    )


def compare_regular(source_fd, copied_fd):
    source_info = os.fstat(source_fd)
    copied_info = os.fstat(copied_fd)
    if not stat.S_ISREG(source_info.st_mode) or not stat.S_ISREG(copied_info.st_mode):
        return False
    source_identity = identity(source_info)
    copied_identity = identity(copied_info)
    while True:
        source_chunk = os.read(source_fd, 65536)
        copied_chunk = os.read(copied_fd, 65536)
        if source_chunk != copied_chunk:
            return False
        if not source_chunk:
            break
    return identity(os.fstat(source_fd)) == source_identity and identity(os.fstat(copied_fd)) == copied_identity


def compare_directory(source_fd, copied_fd):
    source_names = set(os.listdir(source_fd))
    copied_names = set(os.listdir(copied_fd))
    if source_names != copied_names:
        return False
    for name in source_names:
        source_info = os.lstat(name, dir_fd=source_fd)
        copied_info = os.lstat(name, dir_fd=copied_fd)
        source_type = stat.S_IFMT(source_info.st_mode)
        copied_type = stat.S_IFMT(copied_info.st_mode)
        if source_type != copied_type:
            return False
        if stat.S_ISDIR(source_info.st_mode):
            source_child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | nofollow, dir_fd=source_fd)
            copied_child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | nofollow, dir_fd=copied_fd)
            try:
                if not compare_directory(source_child, copied_child):
                    return False
            finally:
                os.close(copied_child)
                os.close(source_child)
        elif stat.S_ISLNK(source_info.st_mode):
            if os.readlink(name, dir_fd=source_fd) != os.readlink(name, dir_fd=copied_fd):
                return False
        elif stat.S_ISREG(source_info.st_mode):
            source_file = os.open(name, os.O_RDONLY | nonblock | nofollow, dir_fd=source_fd)
            copied_file = os.open(name, os.O_RDONLY | nonblock | nofollow, dir_fd=copied_fd)
            try:
                if not compare_regular(source_file, copied_file):
                    return False
            finally:
                os.close(copied_file)
                os.close(source_file)
        else:
            return False
    return True


source_info = os.lstat(source_path)
copied_info = os.lstat(copied_path)
if path_kind == "symlink":
    raise SystemExit(0 if stat.S_ISLNK(copied_info.st_mode) and os.readlink(source_path) == os.readlink(copied_path) else 1)
if path_kind == "file":
    if not stat.S_ISREG(source_info.st_mode) or not stat.S_ISREG(copied_info.st_mode):
        raise SystemExit(1)
    source_fd = os.open(source_path, os.O_RDONLY | nonblock | nofollow)
    copied_fd = os.open(copied_path, os.O_RDONLY | nonblock | nofollow)
    try:
        raise SystemExit(0 if compare_regular(source_fd, copied_fd) else 1)
    finally:
        os.close(copied_fd)
        os.close(source_fd)
if path_kind != "directory" or not stat.S_ISDIR(source_info.st_mode) or not stat.S_ISDIR(copied_info.st_mode):
    raise SystemExit(1)
source_fd = os.open(source_path, os.O_RDONLY | os.O_DIRECTORY | nofollow)
copied_fd = os.open(copied_path, os.O_RDONLY | os.O_DIRECTORY | nofollow)
try:
    raise SystemExit(0 if compare_directory(source_fd, copied_fd) else 1)
finally:
    os.close(copied_fd)
    os.close(source_fd)
PY
}
stage_restore_file() {
  source_path="$1"
  candidate_path="$2"
  python3 - "$source_path" "$candidate_path" <<'PY'
import ctypes
import errno
import os
import stat
import sys

source_path, candidate_path = sys.argv[1:]
uid = os.getuid()
nofollow = getattr(os, "O_NOFOLLOW", 0)
nonblock = getattr(os, "O_NONBLOCK", 0)
max_bytes = 1024 * 1024


def no_acl(fd):
    if sys.platform != "darwin":
        return True
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        get_acl = libc.acl_get_fd_np
        get_acl.argtypes = [ctypes.c_int, ctypes.c_int]
        get_acl.restype = ctypes.c_void_p
        free_acl = libc.acl_free
        free_acl.argtypes = [ctypes.c_void_p]
        free_acl.restype = ctypes.c_int
    except (AttributeError, OSError):
        return False
    ctypes.set_errno(0)
    acl = get_acl(fd, 0x00000100)
    if acl:
        free_acl(acl)
        return False
    return ctypes.get_errno() in (0, errno.ENOENT)


def read_extended_attributes(fd):
    if sys.platform != "darwin":
        return []
    libc = ctypes.CDLL(None, use_errno=True)
    list_xattrs = libc.flistxattr
    list_xattrs.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32]
    list_xattrs.restype = ctypes.c_ssize_t
    get_xattr = libc.fgetxattr
    get_xattr.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
    get_xattr.restype = ctypes.c_ssize_t
    size = list_xattrs(fd, None, 0, 0)
    if size < 0:
        raise SystemExit("could not enumerate source extended attributes")
    if size == 0:
        return []
    names_buffer = ctypes.create_string_buffer(size)
    actual_size = list_xattrs(fd, names_buffer, size, 0)
    if actual_size < 0:
        raise SystemExit("could not read source extended attributes")
    attributes = []
    for raw_name in names_buffer.raw[:actual_size].split(b"\0"):
        if not raw_name:
            continue
        value_size = get_xattr(fd, raw_name, None, 0, 0, 0)
        if value_size < 0:
            raise SystemExit("could not read source extended attribute")
        value_buffer = ctypes.create_string_buffer(value_size) if value_size else None
        if value_size and get_xattr(fd, raw_name, value_buffer, value_size, 0, 0) != value_size:
            raise SystemExit("could not read source extended attribute")
        attributes.append((raw_name, b"" if value_buffer is None else bytes(value_buffer.raw[:value_size])))
    return attributes


def write_extended_attributes(fd, attributes):
    if sys.platform != "darwin":
        return
    libc = ctypes.CDLL(None, use_errno=True)
    set_xattr = libc.fsetxattr
    set_xattr.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
    set_xattr.restype = ctypes.c_int
    for name, value in attributes:
        value_buffer = ctypes.create_string_buffer(value) if value else None
        if set_xattr(fd, name, value_buffer, len(value), 0, 0) != 0:
            raise SystemExit("could not preserve extended attribute")


def validate(fd, info):
    if (
        not stat.S_ISREG(info.st_mode)
        or info.st_uid != uid
        or info.st_nlink != 1
        or info.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
        or getattr(info, "st_flags", 0) != 0
        or info.st_size < 0
        or info.st_size > max_bytes
        or not no_acl(fd)
    ):
        raise SystemExit("unsafe restore file")


source_fd = os.open(source_path, os.O_RDONLY | nonblock | nofollow)
try:
    before = os.fstat(source_fd)
    validate(source_fd, before)
    source_mode = stat.S_IMODE(before.st_mode)
    attributes = read_extended_attributes(source_fd)
    payload = bytearray()
    while len(payload) < before.st_size:
        chunk = os.read(source_fd, min(65536, before.st_size - len(payload)))
        if not chunk:
            raise SystemExit("restore source was truncated")
        payload.extend(chunk)
    after = os.fstat(source_fd)
    path_info = os.lstat(source_path)
    if (
        (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns)
        != (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns)
        or stat.S_ISLNK(path_info.st_mode)
        or (path_info.st_dev, path_info.st_ino) != (before.st_dev, before.st_ino)
    ):
        raise SystemExit("restore source changed during copy")
finally:
    os.close(source_fd)

parent_fd = os.open(os.path.dirname(candidate_path), os.O_RDONLY | os.O_DIRECTORY | nofollow)
temporary_name = ".%s.restore-%s" % (os.path.basename(candidate_path), os.urandom(16).hex())
temporary_fd = None
try:
    parent_info = os.fstat(parent_fd)
    if (
        not stat.S_ISDIR(parent_info.st_mode)
        or parent_info.st_uid != uid
        or parent_info.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
        or not no_acl(parent_fd)
    ):
        raise SystemExit("unsafe restore destination")
    temporary_fd = os.open(
        temporary_name,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | nofollow,
        source_mode,
        dir_fd=parent_fd,
    )
    os.fchmod(temporary_fd, source_mode)
    offset = 0
    while offset < len(payload):
        offset += os.write(temporary_fd, payload[offset:])
    write_extended_attributes(temporary_fd, attributes)
    os.utime(temporary_fd, ns=(before.st_atime_ns, before.st_mtime_ns))
    os.fsync(temporary_fd)
    os.close(temporary_fd)
    temporary_fd = None
    os.replace(temporary_name, os.path.basename(candidate_path), src_dir_fd=parent_fd, dst_dir_fd=parent_fd)
    temporary_name = None
    os.fsync(parent_fd)
    verify_fd = os.open(
        os.path.basename(candidate_path),
        os.O_RDONLY | nonblock | nofollow,
        dir_fd=parent_fd,
    )
    try:
        verify = os.fstat(verify_fd)
        validate(verify_fd, verify)
        if stat.S_IMODE(verify.st_mode) != source_mode:
            raise SystemExit("restore destination mode changed")
        if dict(read_extended_attributes(verify_fd)) != dict(attributes):
            raise SystemExit("restore destination metadata changed")
        if os.read(verify_fd, len(payload) + 1) != payload:
            raise SystemExit("restore destination changed")
    finally:
        os.close(verify_fd)
finally:
    if temporary_fd is not None:
        os.close(temporary_fd)
    if temporary_name is not None:
        try:
            os.unlink(temporary_name, dir_fd=parent_fd)
        except FileNotFoundError:
            pass
    os.close(parent_fd)
PY
}
stage_restore_symlink() {
  source_path="$1"
  candidate_path="$2"
  python3 - "$source_path" "$candidate_path" <<'PY'
import os
import stat
import sys

source_path, candidate_path = sys.argv[1:]
source_info = os.lstat(source_path)
if not stat.S_ISLNK(source_info.st_mode) or source_info.st_uid != os.getuid():
    raise SystemExit("unsafe restore symlink")
target = os.readlink(source_path)
parent_fd = os.open(os.path.dirname(candidate_path), os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0))
temporary_name = ".%s.restore-%s" % (os.path.basename(candidate_path), os.urandom(16).hex())
try:
    os.symlink(target, temporary_name, dir_fd=parent_fd)
    os.replace(temporary_name, os.path.basename(candidate_path), src_dir_fd=parent_fd, dst_dir_fd=parent_fd)
    temporary_name = None
    os.fsync(parent_fd)
    if os.readlink(os.path.join(os.path.dirname(candidate_path), os.path.basename(candidate_path))) != target:
        raise SystemExit("restore symlink changed")
finally:
    if temporary_name is not None:
        try:
            os.unlink(temporary_name, dir_fd=parent_fd)
        except FileNotFoundError:
            pass
    os.close(parent_fd)
PY
}
stage_restore_directory() {
  source_path="$1"
  candidate_path="$2"
  python3 - "$source_path" "$candidate_path" <<'PY'
import ctypes
import errno
import os
import stat
import sys

source_path, candidate_path = sys.argv[1:]
uid = os.getuid()
nofollow = getattr(os, "O_NOFOLLOW", 0)
nonblock = getattr(os, "O_NONBLOCK", 0)


def no_acl(fd):
    if sys.platform != "darwin":
        return True
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        get_acl = libc.acl_get_fd_np
        get_acl.argtypes = [ctypes.c_int, ctypes.c_int]
        get_acl.restype = ctypes.c_void_p
        free_acl = libc.acl_free
        free_acl.argtypes = [ctypes.c_void_p]
        free_acl.restype = ctypes.c_int
    except (AttributeError, OSError):
        return False
    ctypes.set_errno(0)
    acl = get_acl(fd, 0x00000100)
    if acl:
        free_acl(acl)
        return False
    return ctypes.get_errno() in (0, errno.ENOENT)


def read_extended_attributes(fd):
    if sys.platform != "darwin":
        return []
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        list_xattrs = libc.flistxattr
        list_xattrs.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32]
        list_xattrs.restype = ctypes.c_ssize_t
        get_xattr = libc.fgetxattr
        get_xattr.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
        get_xattr.restype = ctypes.c_ssize_t
    except (AttributeError, OSError):
        raise SystemExit("extended-attribute API is unavailable")
    size = list_xattrs(fd, None, 0, 0)
    if size < 0:
        raise SystemExit("could not enumerate source extended attributes")
    if size == 0:
        return []
    names_buffer = ctypes.create_string_buffer(size)
    actual_size = list_xattrs(fd, names_buffer, size, 0)
    if actual_size < 0:
        raise SystemExit("could not read source extended attributes")
    names = names_buffer.raw[:actual_size].split(b"\0")
    attributes = []
    for raw_name in names:
        if not raw_name:
            continue
        value_size = get_xattr(fd, raw_name, None, 0, 0, 0)
        if value_size < 0:
            raise SystemExit("could not read source extended attribute")
        value_buffer = ctypes.create_string_buffer(value_size) if value_size else None
        if value_size and get_xattr(fd, raw_name, value_buffer, value_size, 0, 0) != value_size:
            raise SystemExit("could not read source extended attribute")
        value = b"" if value_buffer is None else bytes(value_buffer.raw[:value_size])
        attributes.append((raw_name, value))
    return attributes


def write_extended_attributes(fd, attributes):
    if sys.platform != "darwin":
        return
    try:
        set_xattr = ctypes.CDLL(None, use_errno=True).fsetxattr
        set_xattr.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
        set_xattr.restype = ctypes.c_int
    except (AttributeError, OSError):
        raise SystemExit("extended-attribute API is unavailable")
    for name, value in attributes:
        value_buffer = ctypes.create_string_buffer(value) if value else None
        if set_xattr(fd, name, value_buffer, len(value), 0, 0) != 0:
            raise SystemExit("could not preserve extended attribute")


def preserve_metadata(source_fd, destination_fd, info, label):
    if (
        info.st_uid != uid
        or (stat.S_ISREG(info.st_mode) and info.st_nlink != 1)
        or info.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
        or getattr(info, "st_flags", 0) != 0
        or not no_acl(source_fd)
    ):
        raise SystemExit("unsupported metadata in restore directory: %s" % label)
    attributes = read_extended_attributes(source_fd)
    os.fchmod(destination_fd, stat.S_IMODE(info.st_mode))
    os.utime(destination_fd, ns=(info.st_atime_ns, info.st_mtime_ns))
    write_extended_attributes(destination_fd, attributes)
    destination_info = os.fstat(destination_fd)
    if (
        stat.S_IMODE(destination_info.st_mode) != stat.S_IMODE(info.st_mode)
        or destination_info.st_atime_ns != info.st_atime_ns
        or destination_info.st_mtime_ns != info.st_mtime_ns
        or dict(read_extended_attributes(destination_fd)) != dict(attributes)
    ):
        raise SystemExit("destination metadata changed during copy")


def copy_regular(source_fd, destination_fd, name):
    source = os.open(name, os.O_RDONLY | nonblock | nofollow, dir_fd=source_fd)
    temporary = ".%s.restore-%s" % (name, os.urandom(16).hex())
    output = None
    try:
        before = os.fstat(source)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_uid != uid
            or before.st_nlink != 1
            or before.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
            or not no_acl(source)
        ):
            raise SystemExit("unsupported special file in restore directory: %s" % name)
        payload = bytearray()
        while len(payload) < before.st_size:
            chunk = os.read(source, min(65536, before.st_size - len(payload)))
            if not chunk:
                raise SystemExit("restore directory source was truncated: %s" % name)
            payload.extend(chunk)
        after = os.fstat(source)
        if (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns) != (
            before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns
        ):
            raise SystemExit("restore directory source changed during copy: %s" % name)
        output = os.open(
            temporary,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | nofollow,
            stat.S_IMODE(before.st_mode),
            dir_fd=destination_fd,
        )
        offset = 0
        while offset < len(payload):
            offset += os.write(output, payload[offset:])
        preserve_metadata(source, output, before, name)
        os.fsync(output)
        os.close(output)
        output = None
        os.replace(temporary, name, src_dir_fd=destination_fd, dst_dir_fd=destination_fd)
        temporary = None
    finally:
        if output is not None:
            os.close(output)
        if temporary is not None:
            try:
                os.unlink(temporary, dir_fd=destination_fd)
            except FileNotFoundError:
                pass
        os.close(source)


def copy_directory(source_fd, destination_fd):
    for name in os.listdir(source_fd):
        info = os.lstat(name, dir_fd=source_fd)
        if stat.S_ISDIR(info.st_mode):
            os.mkdir(name, stat.S_IMODE(info.st_mode) & 0o7777, dir_fd=destination_fd)
            child_source = os.open(name, os.O_RDONLY | os.O_DIRECTORY | nofollow, dir_fd=source_fd)
            child_destination = os.open(name, os.O_RDONLY | os.O_DIRECTORY | nofollow, dir_fd=destination_fd)
            try:
                copy_directory(child_source, child_destination)
                preserve_metadata(child_source, child_destination, info, name)
                os.fsync(child_destination)
            finally:
                os.close(child_destination)
                os.close(child_source)
        elif stat.S_ISLNK(info.st_mode):
            if info.st_uid != uid or info.st_nlink != 1:
                raise SystemExit("unsafe symlink in restore directory: %s" % name)
            os.symlink(os.readlink(name, dir_fd=source_fd), name, dir_fd=destination_fd)
        elif stat.S_ISREG(info.st_mode):
            copy_regular(source_fd, destination_fd, name)
        else:
            raise SystemExit("unsupported special file in restore directory: %s" % name)


source = os.open(source_path, os.O_RDONLY | os.O_DIRECTORY | nofollow)
try:
    source_info = os.fstat(source)
    if not stat.S_ISDIR(source_info.st_mode) or source_info.st_uid != os.getuid():
        raise SystemExit("unsafe restore directory")
    os.mkdir(candidate_path, 0o700)
    destination = os.open(candidate_path, os.O_RDONLY | os.O_DIRECTORY | nofollow)
    try:
        copy_directory(source, destination)
        preserve_metadata(source, destination, source_info, source_path)
        os.fsync(destination)
    finally:
        os.close(destination)
finally:
    os.close(source)
PY
}
stage_restore() {
  source_path="$1"
  candidate_path="$2"
  path_kind="$3"
  if [ "${INSTALL_TX_TEST_RESTORE_COPY_FAULT:-}" = "fail-restore-cp" ]; then
    log "injected restore-copy failure"
    return 1
  fi
  case "$path_kind" in
    directory) stage_restore_directory "$source_path" "$candidate_path" || return 1 ;;
    symlink) stage_restore_symlink "$source_path" "$candidate_path" || return 1 ;;
    file) stage_restore_file "$source_path" "$candidate_path" || return 1 ;;
    *) return 1 ;;
  esac
  paths_match "$source_path" "$candidate_path" "$path_kind"
}
preserve_unmanaged_install_entries() {
  live_path="$1"
  candidate_path="$2"
  python3 - "$live_path" "$candidate_path" <<'PY'
import ctypes
import errno
import os
import re
import shutil
import stat
import sys

live_path, candidate_path = sys.argv[1:]
uid = os.getuid()
nofollow = getattr(os, "O_NOFOLLOW", 0)
nonblock = getattr(os, "O_NONBLOCK", 0)
managed_bundle = re.compile(r".*\.bundle$")


def installer_owned(name):
    return name in {
        "macprovider-cli",
        "mlx.metallib",
        "THIRD-PARTY-NOTICES.txt",
        "compatibility-set.json",
        "compatibility-set-local",
        "catalog-release",
    } or bool(managed_bundle.fullmatch(name)) or bool(
        re.fullmatch(r"macprovider-cli\.v[0-9.]+\.bak", name)
    )


def no_acl(fd):
    if sys.platform != "darwin":
        return True
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        get_acl = libc.acl_get_fd_np
        get_acl.argtypes = [ctypes.c_int, ctypes.c_int]
        get_acl.restype = ctypes.c_void_p
        free_acl = libc.acl_free
        free_acl.argtypes = [ctypes.c_void_p]
        free_acl.restype = ctypes.c_int
    except (AttributeError, OSError):
        return False
    ctypes.set_errno(0)
    acl = get_acl(fd, 0x00000100)
    if acl:
        free_acl(acl)
        return False
    return ctypes.get_errno() in (0, errno.ENOENT)


def read_extended_attributes(fd):
    if sys.platform != "darwin":
        return []
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        list_xattrs = libc.flistxattr
        list_xattrs.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32]
        list_xattrs.restype = ctypes.c_ssize_t
        get_xattr = libc.fgetxattr
        get_xattr.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
        get_xattr.restype = ctypes.c_ssize_t
    except (AttributeError, OSError):
        raise SystemExit("extended-attribute API is unavailable")
    size = list_xattrs(fd, None, 0, 0)
    if size < 0:
        raise SystemExit("could not enumerate source extended attributes")
    if size == 0:
        return []
    names_buffer = ctypes.create_string_buffer(size)
    actual_size = list_xattrs(fd, names_buffer, size, 0)
    if actual_size < 0:
        raise SystemExit("could not read source extended attributes")
    names = names_buffer.raw[:actual_size].split(b"\0")
    attributes = []
    for raw_name in names:
        if not raw_name:
            continue
        value_size = get_xattr(fd, raw_name, None, 0, 0, 0)
        if value_size < 0:
            raise SystemExit("could not read source extended attribute")
        value_buffer = ctypes.create_string_buffer(value_size) if value_size else None
        if value_size and get_xattr(fd, raw_name, value_buffer, value_size, 0, 0) != value_size:
            raise SystemExit("could not read source extended attribute")
        value = b"" if value_buffer is None else bytes(value_buffer.raw[:value_size])
        attributes.append((raw_name, value))
    return attributes


def write_extended_attributes(fd, attributes):
    if sys.platform != "darwin":
        return
    try:
        set_xattr = ctypes.CDLL(None, use_errno=True).fsetxattr
        set_xattr.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
        set_xattr.restype = ctypes.c_int
    except (AttributeError, OSError):
        raise SystemExit("extended-attribute API is unavailable")
    for name, value in attributes:
        value_buffer = ctypes.create_string_buffer(value) if value else None
        if set_xattr(fd, name, value_buffer, len(value), 0, 0) != 0:
            raise SystemExit("could not preserve extended attribute")


def preserve_metadata(source_fd, destination_fd, info, label):
    if (
        info.st_uid != uid
        or (stat.S_ISREG(info.st_mode) and info.st_nlink != 1)
        or info.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
        or getattr(info, "st_flags", 0) != 0
        or not no_acl(source_fd)
    ):
        raise SystemExit("unsupported metadata in mixed install content: %s" % label)
    attributes = read_extended_attributes(source_fd)
    os.fchmod(destination_fd, stat.S_IMODE(info.st_mode))
    os.utime(destination_fd, ns=(info.st_atime_ns, info.st_mtime_ns))
    write_extended_attributes(destination_fd, attributes)
    destination_info = os.fstat(destination_fd)
    if (
        stat.S_IMODE(destination_info.st_mode) != stat.S_IMODE(info.st_mode)
        or destination_info.st_atime_ns != info.st_atime_ns
        or destination_info.st_mtime_ns != info.st_mtime_ns
        or dict(read_extended_attributes(destination_fd)) != dict(attributes)
    ):
        raise SystemExit("destination metadata changed during copy")


def copy_regular(source_fd, destination_fd, name):
    source = os.open(name, os.O_RDONLY | nonblock | nofollow, dir_fd=source_fd)
    temporary = ".%s.preserve-%s" % (name, os.urandom(16).hex())
    output = None
    try:
        before = os.fstat(source)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_uid != uid
            or before.st_nlink != 1
            or before.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
            or not no_acl(source)
        ):
            raise SystemExit("unsupported special file in mixed install content: %s" % name)
        payload = bytearray()
        while len(payload) < before.st_size:
            chunk = os.read(source, min(65536, before.st_size - len(payload)))
            if not chunk:
                raise SystemExit("mixed install content was truncated: %s" % name)
            payload.extend(chunk)
        after = os.fstat(source)
        if (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns) != (
            before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns
        ):
            raise SystemExit("mixed install content changed during copy: %s" % name)
        output = os.open(
            temporary,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | nofollow,
            stat.S_IMODE(before.st_mode),
            dir_fd=destination_fd,
        )
        offset = 0
        while offset < len(payload):
            offset += os.write(output, payload[offset:])
        preserve_metadata(source, output, before, name)
        os.fsync(output)
        os.close(output)
        output = None
        os.replace(temporary, name, src_dir_fd=destination_fd, dst_dir_fd=destination_fd)
        temporary = None
    finally:
        if output is not None:
            os.close(output)
        if temporary is not None:
            try:
                os.unlink(temporary, dir_fd=destination_fd)
            except FileNotFoundError:
                pass
        os.close(source)


def copy_entry(source_fd, destination_fd, name):
    info = os.lstat(name, dir_fd=source_fd)
    if stat.S_ISDIR(info.st_mode):
        os.mkdir(name, stat.S_IMODE(info.st_mode) & 0o7777, dir_fd=destination_fd)
        child_source = os.open(name, os.O_RDONLY | os.O_DIRECTORY | nofollow, dir_fd=source_fd)
        child_destination = os.open(name, os.O_RDONLY | os.O_DIRECTORY | nofollow, dir_fd=destination_fd)
        try:
            for child_name in os.listdir(child_source):
                copy_entry(child_source, child_destination, child_name)
            preserve_metadata(child_source, child_destination, info, name)
            os.fsync(child_destination)
        finally:
            os.close(child_destination)
            os.close(child_source)
    elif stat.S_ISLNK(info.st_mode):
        if info.st_uid != uid or info.st_nlink != 1:
            raise SystemExit("unsafe symlink in mixed install content: %s" % name)
        os.symlink(os.readlink(name, dir_fd=source_fd), name, dir_fd=destination_fd)
    elif stat.S_ISREG(info.st_mode):
        copy_regular(source_fd, destination_fd, name)
    else:
        raise SystemExit("unsupported special file in mixed install content: %s" % name)


def remove_candidate(path):
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        return
    if stat.S_ISDIR(info.st_mode) and not stat.S_ISLNK(info.st_mode):
        shutil.rmtree(path)
    else:
        os.unlink(path)


live = os.open(live_path, os.O_RDONLY | os.O_DIRECTORY | nofollow)
candidate = os.open(candidate_path, os.O_RDONLY | os.O_DIRECTORY | nofollow)
try:
    for name in os.listdir(live):
        if installer_owned(name):
            continue
        remove_candidate(os.path.join(candidate_path, name))
        copy_entry(live, candidate, name)
    os.fsync(candidate)
finally:
    os.close(candidate)
    os.close(live)
PY
}
swap_restore() {
  item_name="$1"
  destination_path="$2"
  candidate_path="$3"
  had_previous="$4"
  if [ "$item_name" = "install-dir" ] && [ "${REC_INSTALL_DIR_PREMOVED:-0}" -eq 1 ]; then
    path_exists "$destination_path" && return 1
    if [ "$had_previous" -eq 1 ]; then
      durable_move "$candidate_path" "$destination_path" || return 1
    fi
    return 0
  fi
  if path_exists "$destination_path"; then
    durable_move "$destination_path" "$FAILED_CURRENT_DIR/$item_name" || return 1
  fi
  if [ "$had_previous" -eq 1 ]; then
    durable_move "$candidate_path" "$destination_path" || return 1
  fi
}
# Restore the lifecycle-state file coherently instead of a raw byte swap:
#   * hold the store's lock across read + swap so a concurrent operator pause is
#     not lost (A-01);
#   * re-read the CURRENT live record first and preserve a durable operator
#     pause the snapshot did not have (A-01.2);
#   * translate an updater-written snapshot into an installer-owned
#     rollback_in_progress record so a restored lifecycle-aware CLI cannot be
#     permanently fenced on a dead operation (A-01.3); installer/serve/opaque
#     snapshots restore byte-exact, absence restores as removal (A-01);
#   * after the final rename/removal, verify the final file (byte compare vs the
#     intended record, regular type, mode) or verified absence, then fsync the
#     restored file and its parent directory before reporting success (S-M3).
# The RECOVERY_LIFECYCLE_FAULT hook lets fault-injection tests interrupt between
# the move-aside and the move-in without changing the production path.
restore_lifecycle_state() {
  RECOVERY_LIFECYCLE_FAULT="${RECOVERY_LIFECYCLE_FAULT:-}" \
  python3 - \
    "$REC_LIFECYCLE_STATE_PATH" \
    "${REC_LIFECYCLE_STATE_LOCK_PATH:-}" \
    "$RECOVERY_DIR/lifecycle-state-v1.json" \
    "$FAILED_CURRENT_DIR/lifecycle-state-v1.json" \
    "${REC_HAD_LIFECYCLE_STATE:-0}" \
    "${REC_LIFECYCLE_INSTALL_OPERATION_ID:-}" \
    <<'PY'
import errno
import fcntl
import json
import os
import stat
import sys
import time
import uuid
from datetime import datetime, timezone

(state_path, lock_path, snapshot_path, aside_path, had_text,
 install_operation_id) = sys.argv[1:]
had_snapshot = had_text == "1"
fault = os.environ.get("RECOVERY_LIFECYCLE_FAULT", "")
uid = os.getuid()
MAX_STATE_BYTES = 1024 * 1024
LOCK_TIMEOUT_SECONDS = 10.0
AUTHORITY = "macprovider_cli"
SCHEMA_VERSION = 1
RESERVED_TRANSLATION_REASON = "install_rollback_restored_translated"


def fail(message):
    sys.stderr.write("lifecycle_restore_failed:%s\n" % message)
    raise SystemExit(1)


def lstat_or_none(path):
    try:
        return os.lstat(path)
    except FileNotFoundError:
        return None


def read_bytes_nofollow(path):
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_NOFOLLOW", 0))
    try:
        data = b""
        while len(data) <= MAX_STATE_BYTES:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            data += chunk
        if len(data) > MAX_STATE_BYTES:
            fail("lifecycle_state_oversized")
        return data
    finally:
        os.close(fd)


def parse_record(data):
    try:
        record = json.loads(data.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return None
    return record if isinstance(record, dict) else None


def encode_record(record):
    # Match the store's JSONEncoder(.sortedKeys): compact, alphabetically
    # sorted keys, UTF-8, no trailing newline.
    return (json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")


def atomic_write(path, data):
    parent = os.path.dirname(path)
    temporary = os.path.join(
        parent, ".%s.recover-tmp-%s" % (os.path.basename(path), uuid.uuid4().hex)
    )
    previous_umask = os.umask(0o077)
    try:
        fd = os.open(
            temporary,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
            0o600,
        )
    finally:
        os.umask(previous_umask)
    try:
        os.write(fd, data)
        os.fsync(fd)
        os.fchmod(fd, 0o600)
    finally:
        os.close(fd)
    os.replace(temporary, path)


def fsync_dir(path):
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


# Acquire the store lock (bounded, fail closed) when a lock path is known.
lock_fd = None
if lock_path:
    lock_st = lstat_or_none(lock_path)
    if lock_st is not None and stat.S_ISLNK(lock_st.st_mode):
        fail("lifecycle_lock_symlink")
    lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0), 0o600)
    lock_desc = os.fstat(lock_fd)
    if (
        not stat.S_ISREG(lock_desc.st_mode)
        or lock_desc.st_uid != uid
        or lock_desc.st_nlink != 1
        or stat.S_IMODE(lock_desc.st_mode) & 0o077
    ):
        os.close(lock_fd)
        fail("lifecycle_lock_invalid")
    deadline = time.monotonic() + LOCK_TIMEOUT_SECONDS
    while True:
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except OSError as error:
            if error.errno not in (errno.EACCES, errno.EAGAIN):
                os.close(lock_fd)
                raise
            if time.monotonic() >= deadline:
                os.close(lock_fd)
                fail("lifecycle_lock_contended")
            time.sleep(0.05)

try:
    # Read the CURRENT live record under the lock for pause reconciliation and
    # to advance sequence past whatever the failed transaction wrote.
    current_st = lstat_or_none(state_path)
    current_record = None
    current_sequence = 0
    current_paused = False
    if current_st is not None and not stat.S_ISLNK(current_st.st_mode) and stat.S_ISREG(current_st.st_mode):
        current_bytes = read_bytes_nofollow(state_path)
        current_record = parse_record(current_bytes)
        if current_record is not None:
            raw_seq = current_record.get("sequence")
            if isinstance(raw_seq, int) and not isinstance(raw_seq, bool) and raw_seq > 0:
                current_sequence = raw_seq
            if current_record.get("operator_paused") is True:
                current_paused = True

    snapshot_bytes = None
    snapshot_record = None
    if had_snapshot:
        snap_st = lstat_or_none(snapshot_path)
        if snap_st is None or stat.S_ISLNK(snap_st.st_mode) or not stat.S_ISREG(snap_st.st_mode):
            fail("lifecycle_snapshot_missing")
        snapshot_bytes = read_bytes_nofollow(snapshot_path)
        snapshot_record = parse_record(snapshot_bytes)

    # Decide the exact bytes (or absence) to become durable.
    remove_state = not had_snapshot
    target_bytes = None
    if had_snapshot:
        snapshot_paused = bool(
            snapshot_record is not None and snapshot_record.get("operator_paused") is True
        )
        snapshot_writer = snapshot_record.get("writer") if snapshot_record is not None else None
        if snapshot_writer == "updater":
            # Translating a maintenance-owned record into an installer-owned
            # rollback_in_progress record. serve is always permitted to leave an
            # installer-written maintenance state, so a restored lifecycle-aware
            # CLI cannot be fenced on a dead updater operation.
            # Start from the FULL snapshot record and replace only the
            # transition-owned fields. The Swift ProviderLifecycleStateRecord
            # constructor carries the last_restart / last_rejection /
            # last_watchdog journals forward on every transition and only
            # refreshes the journal whose trigger this transition matches. For
            # an installer-written rollback_in_progress transition (writer
            # installer, state rollback_in_progress, which is an update state),
            # the constructor mints a NEW last_update event from this transition
            # and preserves last_restart / last_rejection / last_watchdog. We
            # mirror that exactly so Malibu (InstalledProviderMonitor) keeps
            # displaying the restart/rejection/watchdog history and observes the
            # installer's rollback summary in last_update.
            base = dict(snapshot_record)
            snap_seq = base.get("sequence")
            snap_seq = snap_seq if isinstance(snap_seq, int) and not isinstance(snap_seq, bool) else 0
            next_sequence = max(snap_seq, current_sequence) + 1
            transition_id = str(uuid.uuid4()).lower()
            previous_transition_id = base.get("transition_id")
            transition_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.") \
                + "%03dZ" % (datetime.now(timezone.utc).microsecond // 1000)
            fresh_operation_id = install_operation_id or ("install-rollback:%d" % os.getpid())
            if not fresh_operation_id.startswith("install-rollback:"):
                fresh_operation_id = "install-rollback:%s" % fresh_operation_id

            translated = dict(base)
            translated["version"] = (
                base.get("version") if isinstance(base.get("version"), int)
                and not isinstance(base.get("version"), bool) else SCHEMA_VERSION
            )
            translated["sequence"] = next_sequence
            translated["transition_id"] = transition_id
            translated["transition_at"] = transition_at
            translated["state"] = "rollback_in_progress"
            translated["reason_code"] = RESERVED_TRANSLATION_REASON
            translated["authority"] = AUTHORITY
            translated["writer"] = "installer"
            translated["operation_id"] = fresh_operation_id
            # Durable operator pause survives the rollback even if the
            # incumbent snapshot was taken before it was set.
            translated["operator_paused"] = bool(snapshot_paused or current_paused)
            # Chain to the snapshot's transition; drop a non-chaining value.
            if isinstance(previous_transition_id, str) and previous_transition_id:
                translated["previous_transition_id"] = previous_transition_id
            else:
                translated.pop("previous_transition_id", None)

            # SignificantEvent for this installer maintenance transition. Mirrors
            # ProviderLifecycleStateRecord.SignificantEvent: sequence,
            # transition_id, transition_at, state, reason_code, writer,
            # compatibility_set_id (nil-omitted), operation_id.
            update_event = {
                "sequence": next_sequence,
                "transition_id": transition_id,
                "transition_at": transition_at,
                "state": "rollback_in_progress",
                "reason_code": RESERVED_TRANSLATION_REASON,
                "writer": "installer",
                "operation_id": fresh_operation_id,
            }
            compat = base.get("compatibility_set_id")
            if isinstance(compat, str) and compat:
                update_event["compatibility_set_id"] = compat
            # rollback_in_progress is an update state, so the constructor refreshes
            # last_update to this transition; the other journals carry forward
            # unchanged from the snapshot (already copied by dict(base)).
            translated["last_update"] = update_event
            target_bytes = encode_record(translated)
        elif snapshot_record is not None and (current_paused and not snapshot_paused):
            # Byte-exact restore would otherwise drop a durable operator pause
            # set during the transaction; preserve it on the restored record.
            reconciled = dict(snapshot_record)
            reconciled["operator_paused"] = True
            target_bytes = encode_record(reconciled)
        else:
            # Installer-written, serve-written, or opaque snapshot with no pause
            # to reconcile: restore byte-exact as today.
            target_bytes = snapshot_bytes

    # Move the current live file aside (durable failed-install evidence), then
    # honor an injected interruption before the move-in, then write the intended
    # record atomically. The lock is held across the whole critical section.
    if current_st is not None:
        os.replace(state_path, aside_path)
    if fault == "between-aside-and-move-in":
        fail("lifecycle_restore_interrupted_between_aside_and_move_in")
    if remove_state:
        # Absence restore: nothing to write.
        pass
    else:
        atomic_write(state_path, target_bytes)
    fsync_dir(os.path.dirname(state_path))
    if fault == "post-swap-verify-failure":
        # Simulate a post-swap durability/verification defect.
        fail("lifecycle_restore_post_swap_verification_forced")

    # Verify the FINAL durable outcome before reporting success (S-M3).
    final_st = lstat_or_none(state_path)
    if remove_state:
        if final_st is not None:
            fail("lifecycle_restore_absence_not_durable")
    else:
        if final_st is None:
            fail("lifecycle_restore_final_missing")
        if stat.S_ISLNK(final_st.st_mode) or not stat.S_ISREG(final_st.st_mode):
            fail("lifecycle_restore_final_not_regular")
        if stat.S_IMODE(final_st.st_mode) != 0o600:
            fail("lifecycle_restore_final_mode:%o" % stat.S_IMODE(final_st.st_mode))
        final_bytes = read_bytes_nofollow(state_path)
        if final_bytes != target_bytes:
            fail("lifecycle_restore_final_byte_mismatch")
finally:
    if lock_fd is not None:
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_UN)
        finally:
            os.close(lock_fd)
PY
}
# Reconcile the operation-bound lease after the state restore, under the lease
# lock (A-05): remove lease.json when it belongs to the rolled-back install
# operation or its owner PID is dead; preserve it when a live foreign process
# owns it. The lock files themselves are never snapshotted, moved, or deleted.
reconcile_lifecycle_lease() {
  python3 - \
    "${REC_LIFECYCLE_LEASE_PATH:-}" \
    "${REC_LIFECYCLE_LEASE_LOCK_PATH:-}" \
    "${REC_LIFECYCLE_INSTALL_OPERATION_ID:-}" \
    <<'PY'
import ctypes
import errno
import fcntl
import json
import os
import stat
import struct
import subprocess
import sys
import time

lease_path, lock_path, install_operation_id = sys.argv[1:]
if not lease_path:
    raise SystemExit(0)
uid = os.getuid()
#
# ======================================================================
# COMPLETE DIVERGENCE INVENTORY (reconciler-vs-Swift-store).
# ======================================================================
# The reconciler's contract is that its PRESERVE-set is a SUBSET of Swift's
# read-acceptance set: it may REMOVE a lease Swift would keep (bounded
# availability delay -- the CLI re-mints a fresh lease one store cycle later),
# but it must NEVER PRESERVE a lease Swift would reject on read (that would
# restart-loop the provider, because serve startup only falls back on
# handoffNotPrepared and, for an invalid-owner RECORD, on leaseNotValid). Every
# place the shell mirror is not byte-identical to the Swift validators is one of
# the following FOUR deliberate, documented conservative divergences. Each is
# ONE-DIRECTIONAL fail-toward-removal (the shell may only REMOVE a record Swift
# would keep, never PRESERVE one Swift would reject), so the preserve-set is now
# a TOTAL subset of Swift's read-acceptance with NO fail-open remaining. Each is
# annotated at its implementation site; this is the consolidated inventory with
# each divergence's DIRECTION:
#
#   1. Stricter printable-ASCII identity policy (ascii_identity_scalar, applied
#      to operation_id / provider_id / service_identity). Swift trims with
#      Foundation's trimmingCharacters(.whitespacesAndNewlines) then compares
#      trimmed == value; shell requires every scalar to be printable ASCII
#      0x21..0x7e instead of reproducing Foundation's trim set.
#      DIRECTION: fail-toward-removal (strictly-stricter). Any value outside the
#      ASCII set is REMOVED; the store never WRITES such identities, so the
#      at-most-theoretical false-removal (e.g. a non-ASCII provider_id) is a
#      bounded availability delay, never a restart loop.
#
#   2. Duplicate-key STRICT REJECTION vs Foundation keep-first (_strict_pairs).
#      Foundation's JSONDecoder keeps the FIRST value for a duplicate key;
#      Python's default keeps the LAST. Rather than replicate keep-first, shell
#      REJECTS any duplicate-key document outright.
#      DIRECTION: fail-toward-removal. A duplicate-key file Foundation would
#      accept keeping-first is REMOVED here; removal self-heals.
#
#   3. GLOBAL rejection of float / NaN / Infinity JSON tokens, even in fields the
#      shell otherwise ignores (strict_json_loads parse_float / parse_constant).
#      Foundation rejects these only where a numeric field is decoded; shell
#      rejects them anywhere in the document.
#      DIRECTION: fail-toward-removal. A record carrying a stray float in an
#      unread field that Foundation would accept is REMOVED here; removal
#      self-heals.
#
#   4. TRAILING-SLASH rejection of target_executable_path, including the
#      filesystem-root path "/" that Swift accepts STRUCTURALLY
#      (valid_target_path). Swift's standardizedFileURL guard accepts "/"; shell's
#      conservative component rule rejects any trailing slash (so "/" too).
#      DIRECTION: fail-toward-removal. A "/"-valued target path (never a
#      plausible executable, never emitted by the store) is REMOVED here; removal
#      self-heals.
#
# ELIMINATED (was item 1 in prior revisions): owner liveness at SECOND
# resolution. The reconciler previously compared owner.process_start_us TRUNCATED
# to whole seconds (`ps lstart`) against the live pid's start second, a bounded
# FAIL-OPEN that could PRESERVE a same-second/same-boot pid-reuse record Swift's
# exact-microsecond identity rejects. The prior acceptance rationale (Swift
# re-validates and replaces downstream) held for the ordinary owner-liveness path
# but NOT for an ADOPTED handoff record: such a record routes through owner
# liveness here (state != "prepared"), yet on the Swift side serve startup adopts
# via adoptStartupHandoff, whose adopted branch (ProviderLifecycleLease.swift
# ~620) rejects an invalid owner with leaseNotValid(.ownerProcessMissingOrReused)
# rather than transparently re-minting -- so a same-second false-preserve here
# could feed the CLI a record it rejects. owner_is_live now reads the EXACT
# kernel start timeval via sysctl(KERN_PROC_PID) -> kinfo_proc.p_starttime (see
# process_start_microseconds), the same value Swift reads via
# proc_pidinfo(PROC_PIDTBSDINFO), and compares at full microsecond precision.
# The fail-open is gone; the paired Swift startup fallback (MacProviderCLI.swift:
# leaseNotValid now also falls back to replaceable acquisition) additionally
# hardens the pre-existing invalid-owner adopted-record surface.
#
# All boot/clock-window, storage-envelope, and structural checks are
# at-least-as-strict subsets of Swift with NO divergence (the shared-validity
# gate mirrors validationFailure ~888..894 exactly, the owner-liveness check
# mirrors ~904 EXACTLY at microsecond precision, and the prepared-handoff
# exemption mirrors the ~895 branch). The four above are the complete set, all
# fail-toward-removal, so the preserve-set is a TOTAL subset of Swift's.
# ======================================================================
#
# The Swift store enforces ProviderLifecycleLeaseStore.maximumRecordBytes = 16 KiB
# on EVERY read (validateOpenFile, called from readRecordIfPresent before the
# JSONDecoder runs): a record larger than 16 KiB is rejected as .unsafeStorage
# and never decoded. The reconciler must apply the identical ceiling as a
# conservative subset -- a >16 KiB file Swift rejects on read must not be
# preserved here (that would restart-loop the provider), so we reject it too and
# remove the lease. (An underestimate would be UNSAFE only if Swift accepted a
# file we rejected, but Swift's ceiling is exactly 16 KiB, so matching it is
# at-least-as-strict.)
MAX_LEASE_BYTES = 16 * 1024
LOCK_TIMEOUT_SECONDS = 10.0


def fail(message):
    sys.stderr.write("lifecycle_lease_reconcile_failed:%s\n" % message)
    raise SystemExit(1)


def _strict_pairs(values):
    # Foundation's JSONDecoder keeps the FIRST value for a duplicate key; Python's
    # default json.loads keeps the LAST. A record whose duplicate key changes
    # meaning between the two parsers could let the shell PRESERVE a record whose
    # Foundation-visible value Swift rejects. Rather than replicate keep-first, we
    # reject duplicate keys outright: for any duplicate-key file Foundation either
    # also rejects it (it does not, but) or accepts it keeping-first, and in the
    # accept case removing the lease is the safe direction (removal self-heals),
    # so strict rejection is at-least-as-strict.
    result = {}
    for key, value in values:
        if key in result:
            raise ValueError("duplicate key")
        result[key] = value
    return result


def _reject_surrogates(node):
    # Python's json accepts \uD800-\uDFFF escapes and yields lone surrogate code
    # points in the resulting str; Foundation's JSONDecoder rejects unpaired
    # surrogates. Worse, a lone surrogate can later raise an UNCAUGHT
    # UnicodeEncodeError deep inside a validator (e.g. value.encode("utf-8")),
    # which would crash the reconciler instead of failing toward removal. Scan
    # every decoded string for surrogate code points and reject the record if any
    # is present (str keys and values, recursively through dict/list).
    if isinstance(node, str):
        for char in node:
            if 0xD800 <= ord(char) <= 0xDFFF:
                raise ValueError("surrogate in string")
    elif isinstance(node, dict):
        for key, value in node.items():
            _reject_surrogates(key)
            _reject_surrogates(value)
    elif isinstance(node, list):
        for item in node:
            _reject_surrogates(item)


def strict_json_loads(text):
    # Parse a lease record with Foundation-comparable strictness: reject
    # NaN/Infinity/-Infinity (parse_constant) and bare floats (parse_float) that
    # Foundation's JSONDecoder would reject, reject duplicate keys
    # (object_pairs_hook, keep-first divergence), and reject unpaired surrogate
    # escapes. Mirrors the strict-loader already used for acceptance-candidate
    # metadata elsewhere in this installer. Returns the decoded value, or raises
    # ValueError on any strictness failure (the caller turns that into removal).
    value = json.loads(
        text,
        object_pairs_hook=_strict_pairs,
        parse_constant=lambda raw: (_ for _ in ()).throw(ValueError(raw)),
        parse_float=lambda raw: (_ for _ in ()).throw(ValueError(raw)),
    )
    _reject_surrogates(value)
    return value


def lstat_or_none(path):
    try:
        return os.lstat(path)
    except FileNotFoundError:
        return None


def lease_has_extended_acl(path):
    # Mirror the Swift store's rejectExtendedACL (called from validateOpenFile on
    # EVERY read): a lease file carrying an extended (non-mode) ACL is rejected as
    # .unsafeStorage and never decoded, because an ACL could grant another
    # principal read/write to the single-writer lease. Return True if an extended
    # ACL is present, False if provably absent, and None if presence cannot be
    # determined -- the caller treats None as "decline preservation" (removal),
    # since we can only preserve a lease Swift would also accept.
    #
    # Detection via `ls -lde`: on macOS an extended ACL renders as one or more
    # numbered entries (" 0: user:... allow ...") on the lines AFTER the mode
    # line, and the mode string carries a trailing "+" (e.g. "-rw-------+"). We
    # treat EITHER signal as ACL-present. If `ls` is unavailable or its output is
    # unparseable, return None (decline) rather than guessing absence.
    try:
        result = subprocess.run(
            ["/bin/ls", "-lde", path],
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError:
        return None
    if result.returncode != 0:
        return None
    lines = result.stdout.splitlines()
    if not lines:
        return None
    mode_field = lines[0].split(" ", 1)[0] if lines[0] else ""
    if not mode_field:
        return None
    if mode_field.endswith("+"):
        return True
    # Numbered ACL entry lines follow the mode line, e.g. " 0: user:foo allow ...".
    for line in lines[1:]:
        stripped = line.strip()
        if stripped and stripped[0].isdigit() and ":" in stripped.split(None, 1)[0]:
            return True
    return False


def lease_dir_has_extended_acl(path):
    # Directory-flavored ACL gate for the trusted lifecycle directory. Swift's
    # validateTrustedDirectory rejects a directory carrying an extended ACL. We
    # treat both "ACL present" and "presence undeterminable" (None) as unsafe:
    # we may only preserve a lease Swift would also read, and Swift declines to
    # read a lease whose directory it cannot confirm ACL-free.
    return lease_has_extended_acl(path) is not False


def pid_alive(pid):
    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False


def boot_session():
    try:
        result = subprocess.run(
            ["/usr/sbin/sysctl", "-n", "kern.bootsessionuuid"],
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError:
        return ""
    value = result.stdout.strip() if result.returncode == 0 else ""
    if value:
        return value
    try:
        with open("/proc/sys/kernel/random/boot_id", encoding="ascii") as handle:
            return handle.read().strip()
    except OSError:
        return ""


def process_start_microseconds(pid):
    # EXACT-microsecond process-start identity, mirroring the value the Swift
    # store persists as owner.process_start_us. Swift's live environment reads
    # it via proc_pidinfo(PROC_PIDTBSDINFO) -> pbi_start_tvsec*1e6 +
    # pbi_start_tvusec (ProviderLifecycleLease.swift ~255..272). That start-time
    # timeval originates from the same kernel `p_starttime` field that
    # sysctl(CTL_KERN, KERN_PROC, KERN_PROC_PID, pid) exposes as the FIRST field
    # of `struct kinfo_proc` (kp_proc.p_un.__p_starttime, a `struct timeval`).
    # We read that timeval here so python and Swift compute BYTE-IDENTICAL
    # microsecond values from the kernel (verified empirically: proc_pidinfo and
    # this sysctl path return the same combined microseconds for a live pid; the
    # conformance self-check test asserts a store-written live-pid lease is
    # PRESERVED and its process_start_us+1 copy is REMOVED). This ELIMINATES the
    # former second-resolution fail-open: shell now applies the SAME exact
    # identity Swift's validationFailure -> .ownerProcessMissingOrReused applies,
    # so a same-second pid-reuse record is no longer preservable here.
    #
    # `struct timeval` on 64-bit Darwin: __darwin_time_t tv_sec (int64) followed
    # by __darwin_suseconds_t tv_usec (int32). We unpack the leading 12 bytes of
    # the kinfo_proc blob as "=qi" (native, no padding: int64 then int32).
    #
    # Directionality on ANY failure (sysctl error, short/implausible blob, parse
    # error) is fail-toward-removal: return None so owner_is_live() declines to
    # preserve (removal self-heals; the restored CLI mints a fresh lease one
    # store cycle later), never a false preserve.
    if not isinstance(pid, int) or isinstance(pid, bool) or not (1 <= pid <= 2**31 - 1):
        return None
    if sys.platform != "darwin":
        return None
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        libc.sysctl.argtypes = [
            ctypes.POINTER(ctypes.c_int), ctypes.c_uint, ctypes.c_void_p,
            ctypes.POINTER(ctypes.c_size_t), ctypes.c_void_p, ctypes.c_size_t,
        ]
        libc.sysctl.restype = ctypes.c_int
        # CTL_KERN=1, KERN_PROC=14, KERN_PROC_PID=1.
        mib = (ctypes.c_int * 4)(1, 14, 1, pid)
        size = ctypes.c_size_t(0)
        # First call sizes the kinfo_proc result; a dead/reaped pid yields size 0.
        if libc.sysctl(mib, 4, None, ctypes.byref(size), None, 0) != 0:
            return None
        if size.value < 12:
            # No process (or a truncated result): cannot read a start timeval.
            return None
        buffer = ctypes.create_string_buffer(size.value)
        buffer_size = ctypes.c_size_t(size.value)
        if libc.sysctl(mib, 4, buffer, ctypes.byref(buffer_size), None, 0) != 0:
            return None
        data = buffer.raw[:buffer_size.value]
        if len(data) < 12:
            return None
        # p_starttime is the FIRST field of kinfo_proc: timeval{int64 sec; int32 usec}.
        tv_sec, tv_usec = struct.unpack_from("=qi", data, 0)
    except (OSError, ValueError, struct.error):
        return None
    # Plausibility: a real start time is a positive epoch with usec in [0, 1e6).
    # An implausible value is fail-toward-removal (None), never a false preserve.
    if tv_sec <= 0 or not (0 <= tv_usec < 1_000_000):
        return None
    combined = tv_sec * 1_000_000 + tv_usec
    if not (1 <= combined <= 2**63 - 1):
        return None
    return combined


def owner_is_live(owner):
    # A live foreign owner is preserved only when EVERY identity check the
    # Swift store applies (validationFailure / .ownerProcessMissingOrReused)
    # can be reproduced and passes: pid alive, boot_session unchanged, and the
    # owner's EXACT-microsecond process-start identity confirmed. The shell now
    # reads the identical kernel start timeval Swift reads (see
    # process_start_microseconds), so this comparison is byte-for-byte the same
    # identity Swift enforces at ProviderLifecycleLease.swift ~904
    # (environment.processStartMicroseconds(record.owner.pid) ==
    # record.owner.processStartMicroseconds). An unverifiable process-start
    # (owner missing it, or the sysctl read failing/implausible) returns None
    # from process_start_microseconds and is treated as NOT preservable: fail
    # toward single-writer so a stale lease from the failed transaction is
    # cleared rather than protected.
    #
    # This check is now at-least-as-strict as Swift's in EVERY respect: the
    # former bounded fail-open (same-second pid reuse preserved here but rejected
    # by Swift) is ELIMINATED, because the comparison below is the same exact
    # microsecond compare Swift runs. A reused pid whose replacement started even
    # one microsecond apart -- including within the same whole second -- is now
    # REJECTED here exactly as Swift rejects it (.ownerProcessMissingOrReused).
    if not isinstance(owner, dict):
        return False
    owner_pid = owner.get("pid")
    owner_start = owner.get("process_start_us")
    owner_boot = owner.get("boot_session")
    # WIRE-TYPE BOUNDS (Finding 1, R5 CODE-M) on the ordinary-liveness path too:
    # owner.pid is Swift Int32 and process_start_us is Swift Int64, so a value
    # outside the type range could never have been decoded by the Swift store.
    # Bound them BEFORE pid_alive/process_start_microseconds do arithmetic or
    # syscalls: os.kill(pid, 0) raises OverflowError (uncaught by pid_alive) for
    # a pid beyond C int range, so an Int32-overflow pid would otherwise crash
    # the reconciler instead of failing toward removal. Any out-of-range value
    # returns False here -> the dead-owner path (and then the structural mirror)
    # -> removal, never a preserve or a crash.
    if (
        not isinstance(owner_pid, int)
        or isinstance(owner_pid, bool)
        or not (1 <= owner_pid <= 2**31 - 1)
        or not isinstance(owner_start, int)
        or isinstance(owner_start, bool)
        or not (1 <= owner_start <= 2**63 - 1)
        or not isinstance(owner_boot, str)
        or not owner_boot
    ):
        return False
    if not pid_alive(owner_pid):
        return False
    current_boot = boot_session()
    if not current_boot or owner_boot != current_boot:
        # A boot-session mismatch (or unknown current boot) means the pid is a
        # post-reboot coincidence, not the original owner: treat as dead.
        return False
    live_start_us = process_start_microseconds(owner_pid)
    if live_start_us is None:
        # Unverifiable process-start identity: fail toward single-writer.
        return False
    # EXACT-microsecond identity, mirroring Swift ProviderLifecycleLease.swift
    # ~904. No truncation: a same-second pid reuse whose start differs by even
    # one microsecond is rejected here exactly as Swift rejects it.
    return live_start_us == owner_start


def wall_milliseconds():
    # Mirror ProviderLifecycleLeaseEnvironment.live.wallMilliseconds:
    # floor(Date().timeIntervalSince1970 * 1000).
    return int(time.time() * 1_000)


def monotonic_nanoseconds():
    # Mirror ProviderLifecycleLeaseEnvironment.live.monotonicNanoseconds:
    # clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW). Python's CLOCK_MONOTONIC_RAW
    # reads the identical Darwin kernel clock (nanoseconds since boot), so the
    # cross-process monotonic comparison is faithful -- it is only meaningful
    # because the prepared-handoff exemption below also requires the lease's
    # boot_session to match the current boot, which is precisely what keeps the
    # monotonic base comparable across the maintenance owner's process and this
    # reconciler process. If this platform lacks CLOCK_MONOTONIC_RAW, return
    # None so the caller declines the monotonic-dependent exemption (the lease
    # then follows the ordinary owner-liveness path -> removal, never a false
    # preserve).
    clock_id = getattr(time, "CLOCK_MONOTONIC_RAW", None)
    if clock_id is None:
        return None
    try:
        return int(time.clock_gettime_ns(clock_id))
    except (OSError, AttributeError, ValueError):
        return None


def record_matches_swift_structure(record):
    # Mirror EVERY invariant the Swift store's validateRecordStructure /
    # validateStartupHandoffStructure enforce (ProviderLifecycleLease.swift,
    # validationFailure runs validateRecordStructure FIRST, before ANY
    # preservation branch -- the boot/clock/owner-liveness checks and the
    # prepared-handoff exemption at line 895 all run AFTER it). This must
    # therefore gate EVERY preservation branch in the reconciler, because a
    # record the shell PRESERVES but Swift would reject as .invalidField /
    # .durationOutOfRange / .unsupportedVersion is the harmful outcome:
    # inspect() later rejects it, the restored CLI's fallback re-acquires only
    # on handoffNotPrepared, and the provider restart-loops. Directionality is
    # fail-toward-removal: anything this mirror cannot positively verify returns
    # False so the lease follows the ordinary owner-liveness path (-> removal),
    # never a false preserve.
    #
    # SCOPE (R6 CODE-M4): this is the BASE structural validator for ANY lease
    # record, whether or not it carries a startup handoff -- exactly like Swift's
    # validateRecordStructure, which validates the record for both `startup` and
    # `maintenance` kinds and only descends into validateStartupHandoffStructure
    # when `record.startupHandoff` is present. The ordinary live-foreign-owner
    # preservation path (a plain startup lease with no handoff) is gated on this
    # too, so a live owner cannot rescue a structurally invalid record.
    if not isinstance(record, dict):
        return False

    # --- primitive helpers mirroring the Swift validators ---
    #
    # WIRE-TYPE BOUNDS (Finding 1, R5 CODE-M). Swift's JSONDecoder decodes each
    # numeric field into an EXACT fixed-width integer type; a JSON number that
    # does not fit that type makes the decode FAIL, so inspect() rejects the
    # record and -- if the shell had preserved it -- the restored CLI's fallback
    # (which only re-acquires on handoffNotPrepared) leaves the provider in a
    # restart loop. Preserving such a record is therefore the harmful outcome.
    # So EVERY numeric wire field is bounded to its exact Swift type here,
    # BEFORE any arithmetic, and is required to be a JSON integer (not a float,
    # string, or bool -- Python's bool is an int subclass, hence the explicit
    # bool rejection in is_int). These bounds are exactly-as-strict as Swift for
    # the range check and strictly-stricter nowhere it matters:
    #   owner.pid                    -> Swift Int32 -> [1, 2**31 - 1]
    #   process_start_us             -> Swift Int64 -> [1, 2**63 - 1]
    #   issued/expires_wall_ms       -> Swift Int64 -> [.., 2**63 - 1]
    #   issued/expires_monotonic_ns  -> Swift Int64 -> [.., 2**63 - 1]
    #   startup_lease_duration_ms    -> Swift Int64 -> [1, 2**63 - 1]
    # (`version` fields are Swift Int but the shell already pins them to the
    # exact schema constant 1, which is inside every integer type's range, so no
    # separate Int64 bound is needed for them.)
    INT32_MAX = 2**31 - 1  # Swift Int32.max
    INT64_MAX = 2**63 - 1  # Swift Int64.max

    def is_int(value):
        # A JSON integer that is not a bool (Python bool subclasses int; Swift's
        # JSONDecoder rejects `true`/`false` for an integer field).
        return isinstance(value, int) and not isinstance(value, bool)

    def is_int32(value):
        # Fits Swift Int32 (owner.pid). Any value outside [-2**31, 2**31 - 1]
        # overflows Int32 and fails JSONDecoder; callers additionally require
        # the store-specific positivity bound (pid > 0).
        return is_int(value) and -(INT32_MAX + 1) <= value <= INT32_MAX

    def is_int64(value):
        # Fits Swift Int64 (all timestamp/duration/process-start fields). Any
        # value outside [-2**63, 2**63 - 1] overflows Int64 and fails
        # JSONDecoder; callers additionally require the store-specific lower
        # bound (> 0 or >= 0).
        return is_int(value) and -(INT64_MAX + 1) <= value <= INT64_MAX

    def ascii_identity_scalar(text):
        # STRICTLY-STRICTER-THAN-FOUNDATION identity rule (Finding 2, R5 CODE-M).
        # Swift trims operation_id / provider_id / service_identity with
        # Foundation's trimmingCharacters(.whitespacesAndNewlines), whose scalar
        # set (e.g. U+200B ZERO WIDTH SPACE and other format/whitespace scalars)
        # is NOT identical to Python str.strip(); mirroring the trim with
        # str.strip() lets a U+200B-prefixed identity pass the shell yet fail the
        # Swift store's own trimmed == value guard -> a false preserve ->
        # restart loop. Rather than reproduce Foundation's trim set, we require
        # EVERY scalar to be printable ASCII in 0x21..0x7e: no whitespace of any
        # kind anywhere (so trivially trim-stable under BOTH Python and
        # Foundation semantics), and no control/format scalars. The Swift store
        # only ever WRITES such values for these three fields -- operation ids
        # like "serve:<uuid>" / "install-rollback:<id>" / "provider-restart-N",
        # launchd-label service identities, and config provider ids -- so any
        # value outside this set cannot have been emitted by the store, and its
        # removal self-heals via fresh acquisition (bounded availability delay,
        # never a restart loop). The one theoretical false-removal is a
        # deliberately non-ASCII provider_id, which declines the exemption
        # (bounded availability delay), never a restart loop.
        for char in text:
            code = ord(char)
            if code < 0x21 or code > 0x7E:
                return False
        return True

    def valid_operation_id(value):
        # validateOperationID, made strictly-stricter: str, non-empty, utf8
        # <= 128, and every scalar printable ASCII 0x21..0x7e (subsumes Swift's
        # trimmed == value and >= 0x20 && not-C1 checks; see
        # ascii_identity_scalar).
        if not isinstance(value, str):
            return False
        if not value or len(value.encode("utf-8")) > 128:
            return False
        return ascii_identity_scalar(value)

    def valid_handoff_identity(value, *, forbid_slash):
        # validateHandoffIdentity, made strictly-stricter: str, non-empty, utf8
        # <= 256, every scalar printable ASCII 0x21..0x7e; service_identity
        # additionally must not contain "/" (kept from Swift).
        if not isinstance(value, str):
            return False
        if not value or len(value.encode("utf-8")) > 256:
            return False
        if not ascii_identity_scalar(value):
            return False
        if forbid_slash and "/" in value:
            return False
        return True

    def valid_uuid(value):
        # UUID(uuidString:) accepts the canonical 8-4-4-4-12 hex form. Reject
        # anything else so a malformed lease_id/handoff_id is not preserved.
        if not isinstance(value, str):
            return False
        parts = value.split("-")
        if len(parts) != 5:
            return False
        if [len(part) for part in parts] != [8, 4, 4, 4, 12]:
            return False
        return all(
            char in "0123456789abcdefABCDEF"
            for part in parts
            for char in part
        )

    def valid_target_path(value):
        # validateTargetExecutablePath, made STRICTLY-STRICTER-THAN-BOTH-
        # NORMALIZERS (Finding 2, R6 remaining-surface item 2). Swift rejects
        # unless `path == URL(fileURLWithPath: path).standardizedFileURL.path`;
        # the previous shell mirror used `os.path.normpath(value) == value`.
        # Neither normalizer is a substring of the other (normpath collapses
        # "a/b/../c" -> "a/c" and strips trailing "/", while Foundation's
        # standardizedFileURL applies its own URL-path rules), so a path that is
        # its-own-normpath but NOT its-own-standardizedFileURL (or vice versa)
        # produces a false PRESERVE -> shell keeps a path Swift rejects ->
        # restart loop, the exact defect class this round eliminates. Rather
        # than reproduce EITHER normalizer, we require conservative component
        # rules that are at-least-as-strict as BOTH: an absolute path made of
        # non-empty components, none of which is "." or "..", with no trailing
        # slash. Every rejection below is a path the Swift store never emits for
        # target_executable_path -- the store persists an already-standardized
        # absolute executable path resolved from the running process
        # (executablePath(pid) / standardizedFileURL.path), which by
        # construction is absolute, has no empty / "." / ".." components, and no
        # trailing slash -- so any value we reject is corruption or forgery, and
        # its removal self-heals via fresh acquisition (bounded availability
        # delay, never a restart loop). Non-ASCII bytes are permitted: a
        # non-ASCII home directory yields a legitimate non-ASCII executable
        # path, and none of these component rules inspect byte class.
        #
        # AT-LEAST-AS-STRICT PROOF. A value V passing these rules is a "/"-led
        # sequence of one-or-more components c1/.../cn where each ci is
        # non-empty and ci not in {".", ".."} and V does not end in "/".
        #   * V is its own os.path.normpath: normpath only mutates a path by
        #     collapsing duplicate/leading-internal slashes (excluded: no empty
        #     component => no "//"), removing "." components (excluded), resolving
        #     ".." against a prior component (excluded), or stripping a trailing
        #     "/" (excluded). With none of its rewrite triggers present,
        #     normpath(V) == V. So V passes the OLD normpath mirror.
        #   * V is its own URL(fileURLWithPath: V).standardizedFileURL.path:
        #     standardizedFileURL resolves "." and ".." components and collapses
        #     empty path segments; with none present and V absolute, the
        #     standardized path equals V. So V passes the Swift guard.
        # Thus {V : passes new rule} is a subset of both {V : normpath(V)==V}
        # and {V : standardizedFileURL(V)==V}: the new rule is at-least-as-strict
        # than BOTH, with no semantic mirroring of either normalizer remaining.
        if not isinstance(value, str):
            return False
        if not value.startswith("/"):
            return False
        if "\x00" in value:
            return False
        if len(value.encode("utf-8")) > 1024 * 4:
            return False
        if value.endswith("/"):
            # Trailing slash (including the bare-root "/" case, which is anyway
            # never a plausible executable path). normpath strips it and
            # standardizedFileURL drops it -> both would rewrite V, so V is not
            # its own normal form under either.
            return False
        # value[1:] is the component sequence after the leading "/"; splitting on
        # "/" yields each component. An empty component means "//" (a duplicate
        # slash); "." / ".." are the relative components both normalizers
        # rewrite.
        for component in value[1:].split("/"):
            if component == "" or component == "." or component == "..":
                return False
        return True

    def valid_sha256(value):
        # validatedSHA256: exactly 64 bytes of lowercase hex.
        if not isinstance(value, str):
            return False
        if len(value.encode("utf-8")) != 64:
            return False
        return all(char in "0123456789abcdef" for char in value)

    def duration_ok(issued, expires, *, max_ms):
        # Mirror the shared duration algebra: no overflow (Python ints are
        # unbounded, so overflow can't occur -- this is inherently at least as
        # strict as Swift's Int64 overflow guard), 0 < wallDuration <= max_ms,
        # and monotonicDuration == wallDuration * 1_000_000. Returns the wall
        # duration on success, or None on failure.
        wall_duration = expires - issued
        if wall_duration <= 0 or wall_duration > max_ms:
            return None
        return wall_duration

    # --- record-level structure (validateRecordStructure) ---
    # `version` is Swift Int: JSONDecoder decodes it into an integer and rejects
    # `true`/`false`. Python's bool subclasses int, so `record.get("version") != 1`
    # alone would let a JSON `true` pass (True == 1). Require a real (non-bool)
    # integer equal to the schema constant, matching Swift's decode-then-compare.
    if not is_int(record.get("version")) or record.get("version") != 1:
        return False
    if not valid_uuid(record.get("lease_id")):
        return False
    if not valid_operation_id(record.get("operation_id")):
        return False

    owner = record.get("owner")
    if not isinstance(owner, dict):
        return False
    owner_pid = owner.get("pid")
    owner_start = owner.get("process_start_us")
    owner_boot = owner.get("boot_session")
    # owner.pid is Swift Int32: bound to [1, 2**31 - 1] BEFORE any use. A pid of
    # 2**31 passes an unbounded positivity check but overflows Int32 in
    # JSONDecoder -> false preserve. process_start_us is Swift Int64.
    if not is_int32(owner_pid) or owner_pid <= 0:
        return False
    if not is_int64(owner_start) or owner_start <= 0:
        return False
    if not isinstance(owner_boot, str) or not owner_boot:
        return False
    if len(owner_boot.encode("utf-8")) > 256:
        return False

    record_issued_wall = record.get("issued_wall_ms")
    record_expires_wall = record.get("expires_wall_ms")
    record_issued_mono = record.get("issued_monotonic_ns")
    record_expires_mono = record.get("expires_monotonic_ns")
    # All four are Swift Int64: bound to [.., 2**63 - 1] BEFORE the duration
    # algebra below (a value of 2**63 overflows Int64 in JSONDecoder ->
    # false preserve). The store-specific lower bounds follow.
    for value in (
        record_issued_wall,
        record_expires_wall,
        record_issued_mono,
        record_expires_mono,
    ):
        if not is_int64(value):
            return False
    if record_issued_wall <= 0 or record_issued_mono < 0:
        return False

    # Swift's ProviderLifecycleLeaseKind decodes ONLY "startup" or "maintenance"
    # (any other string fails JSONDecoder). The record duration ceiling is
    # kind-specific: maintenance 20 min, startup 30 min
    # (ProviderLifecycleLeaseKind.maximumDurationMilliseconds). The prior mirror
    # pinned kind == "maintenance" because it only ran for prepared-handoff
    # records; as the BASE validator (R6 CODE-M4) it must accept both kinds so a
    # plain `startup` lease with a live owner is structurally validated too.
    # The handoff `state` gate below still enforces prepared -> maintenance and
    # adopted -> startup exactly as Swift does.
    record_kind = record.get("kind")
    record_kind_max_ms = {
        "maintenance": 20 * 60 * 1_000,
        "startup": 30 * 60 * 1_000,
    }.get(record_kind)
    if record_kind_max_ms is None:
        return False
    record_wall_duration = duration_ok(
        record_issued_wall, record_expires_wall, max_ms=record_kind_max_ms
    )
    if record_wall_duration is None:
        return False
    if record_expires_mono - record_issued_mono != record_wall_duration * 1_000_000:
        return False

    # --- handoff-level structure (validateStartupHandoffStructure) ---
    # Swift descends into validateStartupHandoffStructure ONLY when a handoff is
    # present (`if let handoff = record.startupHandoff`). A record with NO handoff
    # (the ordinary startup/maintenance lease) is structurally complete at this
    # point. A `startup_handoff` present but not a JSON object is malformed ->
    # Swift's decode would reject it -> False.
    handoff = record.get("startup_handoff")
    if handoff is None:
        return True
    if not isinstance(handoff, dict):
        return False
    # handoff.version is Swift Int too (same JSON-bool caveat as record.version).
    if not is_int(handoff.get("version")) or handoff.get("version") != 1:
        return False
    if not valid_uuid(handoff.get("handoff_id")):
        return False
    # Operation-identity equality between record and handoff (Swift requires
    # handoff.operationID == record.operationID and handoff.bootSession ==
    # record.owner.bootSession).
    if handoff.get("operation_id") != record.get("operation_id"):
        return False
    if handoff.get("boot_session") != owner_boot:
        return False
    if not valid_operation_id(handoff.get("operation_id")):
        return False
    if not valid_handoff_identity(handoff.get("provider_id"), forbid_slash=False):
        return False
    if not valid_handoff_identity(handoff.get("service_identity"), forbid_slash=True):
        return False
    if not valid_target_path(handoff.get("target_executable_path")):
        return False
    if not valid_sha256(handoff.get("target_executable_sha256")):
        return False

    handoff_issued_wall = handoff.get("issued_wall_ms")
    handoff_expires_wall = handoff.get("expires_wall_ms")
    handoff_issued_mono = handoff.get("issued_monotonic_ns")
    handoff_expires_mono = handoff.get("expires_monotonic_ns")
    handoff_lease_duration = handoff.get("startup_lease_duration_ms")
    # All five are Swift Int64: bound to [.., 2**63 - 1] BEFORE the duration
    # algebra below. The store-specific lower bounds follow.
    for value in (
        handoff_issued_wall,
        handoff_expires_wall,
        handoff_issued_mono,
        handoff_expires_mono,
        handoff_lease_duration,
    ):
        if not is_int64(value):
            return False
    if handoff_issued_wall <= 0 or handoff_issued_mono < 0:
        return False
    handoff_max_ms = 5 * 60 * 1_000  # ProviderLifecycleStartupHandoff.maximumDurationMilliseconds
    handoff_wall_duration = duration_ok(
        handoff_issued_wall, handoff_expires_wall, max_ms=handoff_max_ms
    )
    if handoff_wall_duration is None:
        return False
    if handoff_expires_mono - handoff_issued_mono != handoff_wall_duration * 1_000_000:
        return False
    startup_max_ms = 30 * 60 * 1_000  # startup kind maximumDurationMilliseconds
    if handoff_lease_duration <= 0 or handoff_lease_duration > startup_max_ms:
        return False

    # Handoff-state gate (Swift's `switch handoff.state`):
    #   .prepared -> record.kind == .maintenance AND handoff.expires* <=
    #                record.expires* (window containment);
    #   .adopted  -> record.kind == .startup (no containment requirement).
    # Any other state string fails JSONDecoder (the enum has exactly these two
    # cases) -> reject. This subsumes the previous prepared-only mirror while
    # keeping the reconciler at-least-as-strict for adopted handoffs, whose
    # live-owner record now flows through the base validator instead of being
    # preserved unvalidated.
    handoff_state = handoff.get("state")
    if handoff_state == "prepared":
        if record_kind != "maintenance":
            return False
        if handoff_expires_wall > record_expires_wall:
            return False
        if handoff_expires_mono > record_expires_mono:
            return False
    elif handoff_state == "adopted":
        if record_kind != "startup":
            return False
    else:
        return False

    return True


def record_shared_validity_ok(record):
    # Mirror the SHARED validity checks the Swift store's validationFailure
    # (ProviderLifecycleLease.swift ~888..894) runs AFTER validateRecordStructure
    # and BEFORE it branches to EITHER preservation path -- the prepared-handoff
    # exemption at ~895 OR the owner process-start liveness check at ~904. Those
    # four guards, in Swift's exact order, are:
    #
    #     guard environment.bootSession() == record.owner.bootSession  -> .bootSessionChanged
    #     guard wallNow    >= record.issuedWallMilliseconds             -> .wallClockBeforeIssue
    #     guard monotonicNow >= record.issuedMonotonicNanoseconds       -> .monotonicClockBeforeIssue
    #     guard wallNow    <  record.expiresWallMilliseconds            -> .wallExpired
    #     guard monotonicNow <  record.expiresMonotonicNanoseconds      -> .monotonicExpired
    #
    # The reconciler previously ran only structure -> owner_is_live (pid/boot/
    # process-start) -> prepared exemption. owner_is_live did NOT check the
    # record's wall/monotonic WINDOWS, so a live foreign owner whose record clock
    # window did not bracket `now` (issued in the future, or already expired, on
    # either the wall or the monotonic axis) was PRESERVED by the shell yet
    # REJECTED by Swift's validationFailure. For a handoff-bearing lease, serve
    # startup only falls back on handoffNotPrepared (MacProviderCLI.swift ~1413),
    # so preserving such a record can restart-loop rollback startup. This gate
    # closes that divergence by running Swift's shared window/boot checks BEFORE
    # both preservation branches, exactly where Swift runs them.
    #
    # Directionality is fail-toward-removal: anything this cannot positively
    # verify (missing CLOCK_MONOTONIC_RAW, unknown boot, malformed window) returns
    # False so the lease is REMOVED. record_matches_swift_structure has already
    # bounded and typed the four window fields (Int64, issued_wall > 0,
    # issued_mono >= 0, duration algebra), so this reads them as plain ints.
    if not isinstance(record, dict):
        return False
    owner = record.get("owner")
    if not isinstance(owner, dict):
        return False
    owner_boot = owner.get("boot_session")
    if not isinstance(owner_boot, str) or not owner_boot:
        return False
    current_boot = boot_session()
    if not current_boot or owner_boot != current_boot:
        # Swift's .bootSessionChanged: a boot-session mismatch (or unknown
        # current boot) means the record's monotonic base is not comparable and
        # the owner is a post-reboot coincidence. Fail toward removal.
        return False

    issued_wall = record.get("issued_wall_ms")
    expires_wall = record.get("expires_wall_ms")
    issued_mono = record.get("issued_monotonic_ns")
    expires_mono = record.get("expires_monotonic_ns")
    for value in (issued_wall, expires_wall, issued_mono, expires_mono):
        if not isinstance(value, int) or isinstance(value, bool):
            return False

    wall_now = wall_milliseconds()
    monotonic_now = monotonic_nanoseconds()
    if monotonic_now is None:
        # No CLOCK_MONOTONIC_RAW on this platform: we cannot reproduce Swift's
        # monotonic comparison, so we cannot confirm the record is in-window.
        # Decline preservation (removal) as elsewhere -- never a false preserve.
        return False

    # Swift's guards, same axes and strictness: now must be at-or-after issue and
    # strictly before expiry on BOTH the wall and monotonic axes.
    if wall_now < issued_wall or wall_now >= expires_wall:
        return False
    if monotonic_now < issued_mono or monotonic_now >= expires_mono:
        return False
    return True


def record_has_prepared_handoff(record):
    # True iff the record carries a `.prepared` startup handoff, mirroring the
    # SELECTOR of Swift's validationFailure branch (ProviderLifecycleLease.swift
    # ~895: `if let handoff = record.startupHandoff, handoff.state == .prepared`).
    # This decides WHICH preservation path applies -- the prepared-handoff
    # exemption (handoff-window governed) vs the ordinary owner-liveness check --
    # exactly as Swift's if/else does. By the time this runs, structure has
    # already been validated, so a present-but-malformed handoff cannot reach
    # here; but this is deliberately a shape-only predicate (no structural
    # re-check) so it can never itself flip a record from the exemption path to
    # the owner-liveness path and thereby preserve something Swift rejects.
    if not isinstance(record, dict):
        return False
    handoff = record.get("startup_handoff")
    return isinstance(handoff, dict) and handoff.get("state") == "prepared"


def prepared_handoff_preserves(record):
    # Mirror the prepared-handoff validity exception in the Swift store's
    # validationFailure (ProviderLifecycleLease.swift, `if let handoff =
    # record.startupHandoff, handoff.state == .prepared`). The store
    # INTENTIONALLY exempts an unexpired prepared startup handoff from the
    # owner process-start liveness check so launchd can adopt the handoff AFTER
    # the maintenance process that prepared it has exited. A rollback-bound
    # lease is handled by the caller (belongs_to_rollback) and is NOT routed
    # here, so this only ever preserves a foreign lease whose operation is
    # unrelated to the rolled-back transaction.
    #
    # The exemption requires, exactly as Swift does before reaching line 895:
    #   * a record that passes the FULL Swift structural validation
    #     (validateRecordStructure / validateStartupHandoffStructure), checked
    #     first via record_matches_swift_structure -- a record the shell
    #     preserves but Swift's inspect() would reject as .invalidField would
    #     restart-loop the provider, so anything unverifiable is declined here;
    #   * state == "prepared";
    #   * boot_session matches the current boot for BOTH record.owner and the
    #     handoff (Swift enforces handoff.bootSession == record.owner.bootSession
    #     structurally, and validationFailure guards record.owner.bootSession
    #     against the live boot);
    #   * wall-clock: now >= issued and now < expires for BOTH record and
    #     handoff;
    #   * monotonic: now >= issued and now < expires for BOTH record and
    #     handoff (same-boot comparable via the boot_session match above).
    # Any missing/malformed field or an expired/before-issue window means the
    # exemption does NOT apply and the lease follows the ordinary path.
    #
    # NOTE (MEDIUM fix): the caller now runs record_shared_validity_ok BEFORE
    # this exemption, so the record's boot/wall/monotonic window is ALREADY
    # confirmed in-bracket by the time we get here (matching Swift's ~888..894
    # running before the ~895 prepared branch). The record-window and boot
    # re-checks below are therefore redundant with that gate; they are KEPT so
    # this function remains a correct standalone predicate (and still enforces
    # the HANDOFF window, which the shared gate does not touch -- Swift's ~896..
    # 901 handoff-window guards).
    if not isinstance(record, dict):
        return False
    handoff = record.get("startup_handoff")
    if not isinstance(handoff, dict):
        return False
    if handoff.get("state") != "prepared":
        return False
    # FULL Swift structural validation FIRST: a record the shell preserves but
    # Swift's inspect() would reject as .invalidField restart-loops the
    # provider. record_matches_swift_structure fails toward removal on anything
    # it cannot positively verify, so it must gate the exemption before the
    # boot/window checks below.
    if not record_matches_swift_structure(record):
        return False
    owner = record.get("owner")
    if not isinstance(owner, dict):
        return False
    owner_boot = owner.get("boot_session")
    handoff_boot = handoff.get("boot_session")
    if (
        not isinstance(owner_boot, str)
        or not owner_boot
        or not isinstance(handoff_boot, str)
        or not handoff_boot
    ):
        return False
    current_boot = boot_session()
    if not current_boot or owner_boot != current_boot or handoff_boot != current_boot:
        return False

    def valid_window(container):
        issued_wall = container.get("issued_wall_ms")
        expires_wall = container.get("expires_wall_ms")
        issued_mono = container.get("issued_monotonic_ns")
        expires_mono = container.get("expires_monotonic_ns")
        for value in (issued_wall, expires_wall, issued_mono, expires_mono):
            if not isinstance(value, int) or isinstance(value, bool):
                return None
        return (issued_wall, expires_wall, issued_mono, expires_mono)

    record_window = valid_window(record)
    handoff_window = valid_window(handoff)
    if record_window is None or handoff_window is None:
        return False

    wall_now = wall_milliseconds()
    monotonic_now = monotonic_nanoseconds()
    if monotonic_now is None:
        # Cannot reproduce Swift's monotonic comparison on this platform: do
        # not grant the exemption. The lease falls back to owner-liveness.
        return False

    for issued_wall, expires_wall, issued_mono, expires_mono in (
        record_window,
        handoff_window,
    ):
        if wall_now < issued_wall or wall_now >= expires_wall:
            return False
        if monotonic_now < issued_mono or monotonic_now >= expires_mono:
            return False
    return True


lock_fd = None
if lock_path:
    lock_st = lstat_or_none(lock_path)
    if lock_st is not None and stat.S_ISLNK(lock_st.st_mode):
        fail("lifecycle_lease_lock_symlink")
    lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0), 0o600)
    lock_desc = os.fstat(lock_fd)
    if (
        not stat.S_ISREG(lock_desc.st_mode)
        or lock_desc.st_uid != uid
        or lock_desc.st_nlink != 1
        or stat.S_IMODE(lock_desc.st_mode) & 0o077
    ):
        os.close(lock_fd)
        fail("lifecycle_lease_lock_invalid")
    deadline = time.monotonic() + LOCK_TIMEOUT_SECONDS
    while True:
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except OSError as error:
            if error.errno not in (errno.EACCES, errno.EAGAIN):
                os.close(lock_fd)
                raise
            if time.monotonic() >= deadline:
                os.close(lock_fd)
                fail("lifecycle_lease_lock_contended")
            time.sleep(0.05)

try:
    lease_st = lstat_or_none(lease_path)
    if lease_st is None:
        # No lease to reconcile. This is the ONLY path CI exercises for the
        # non-gated cases, and it is fully portable (no Darwin primitive touched).
        raise SystemExit(0)

    # -- NON-DARWIN FAIL-TOWARD-REMOVAL (portability guard) ------------------
    # Owner-identity evaluation (owner_is_live -> process_start_microseconds,
    # boot_session) depends on Darwin-only primitives: the sysctl(KERN_PROC_PID)
    # -> kinfo_proc.p_starttime ABI read via ctypes libc.sysctl, and
    # `/usr/sbin/sysctl -n kern.bootsessionuuid`. On glibc `libc.sysctl` is
    # ABSENT (accessing it raises AttributeError, which the syscall wrappers do
    # NOT catch), so evaluating an EXISTING lease off-Darwin could crash the
    # reconciler instead of resolving it. Production never runs this installer
    # off macOS; only Linux CI reaches here, and only when a fixture injects a
    # lease. Fail toward REMOVAL with a logged reason: removal is always the safe
    # direction (a restored CLI re-mints a fresh lease one store cycle later),
    # and it keeps ALL Darwin-only initialization strictly lazy -- no CDLL setup,
    # no sysctl, no kinfo_proc parsing is ever reached on a non-Darwin platform.
    if sys.platform != "darwin":
        sys.stderr.write(
            "lifecycle_lease_reconcile_removed_non_darwin:platform=%s\n" % sys.platform
        )
        try:
            os.unlink(lease_path)
        except FileNotFoundError:
            pass
        parent = os.path.dirname(lease_path)
        try:
            dir_fd = os.open(parent, os.O_RDONLY)
            try:
                os.fsync(dir_fd)
            finally:
                os.close(dir_fd)
        except OSError:
            pass
        if lstat_or_none(lease_path) is not None:
            fail("lifecycle_lease_removal_not_durable")
        raise SystemExit(0)

    # -- PRE-PARSE STORAGE GATE (R6 CODE-M3) ---------------------------------
    # Mirror EXACTLY the envelope the Swift store enforces on EVERY read
    # (validateOpenFile, called from readRecordIfPresent BEFORE JSONDecoder):
    # regular file, owned by us, st_nlink == 1, mode == 0600, no extended ACL,
    # and size <= 16 KiB (maximumRecordBytes). Any violation is a record Swift
    # would reject as .unsafeStorage and never decode, so preserving it would
    # restart-loop the provider. Per the reconciler's design rule, every such
    # divergence fails toward REMOVAL (self-healing) rather than a loud recovery
    # abort: a fresh CLI re-mints a clean lease. Removal of our own lease path
    # (under a 0700 HOME-owned directory, opened O_NOFOLLOW / lstat only) is
    # always safe -- unlink never dereferences a symlink and never needs the
    # file's own perms, only the parent directory's, which we own.
    #
    # st_flags is deliberately NOT checked: the Swift read path does not inspect
    # st_flags, so adding it would over-reach beyond "at-least-as-strict subset".
    #
    # The TRUSTED-DIRECTORY gate mirrors Swift's inspect() path too: inspect()
    # calls validateTrustedDirectory(createIfMissing:false) BEFORE reading the
    # lease, and a directory that is not a real dir owned by us with mode EXACTLY
    # 0700 and no extended ACL makes inspect() return .missing -- i.e. Swift
    # would refuse to read the lease at all. So a lease in a lax directory is one
    # Swift rejects on read; the reconciler must not preserve it. Declining
    # preservation (removal) is safe: the CLI's ensureTrustedDirectory recreates
    # the 0700 directory on the next acquire.
    remove = False
    storage_ok = True
    parent_dir = os.path.dirname(lease_path)
    parent_st = lstat_or_none(parent_dir)
    if (
        parent_st is None
        or stat.S_ISLNK(parent_st.st_mode)
        or not stat.S_ISDIR(parent_st.st_mode)
        or parent_st.st_uid != uid
        or stat.S_IMODE(parent_st.st_mode) != 0o700
    ):
        storage_ok = False  # untrusted directory: Swift inspect() -> .missing
    elif lease_dir_has_extended_acl(parent_dir):
        storage_ok = False  # dir extended ACL (or undeterminable): Swift rejects
    elif stat.S_ISLNK(lease_st.st_mode) or not stat.S_ISREG(lease_st.st_mode):
        storage_ok = False  # symlink or non-regular: Swift .unsafeStorage
    elif lease_st.st_uid != uid:
        storage_ok = False  # wrong owner: Swift .unsafeStorage
    elif lease_st.st_nlink != 1:
        storage_ok = False  # hard link: Swift "hard link" .unsafeStorage
    elif stat.S_IMODE(lease_st.st_mode) != 0o600:
        storage_ok = False  # mode != 0600: Swift "mode is not 0600" .unsafeStorage
    elif lease_st.st_size > MAX_LEASE_BYTES:
        storage_ok = False  # oversized: Swift "record too large" .unsafeStorage
    else:
        # Extended-ACL check mirrors Swift's rejectExtendedACL. ACL present OR
        # presence-undeterminable both decline preservation (removal), since we
        # may only preserve a lease Swift would also accept.
        acl_present = lease_has_extended_acl(lease_path)
        if acl_present is None or acl_present:
            storage_ok = False

    if not storage_ok:
        # Storage envelope Swift would reject on read -> remove (self-healing).
        remove = True
        record = None
    else:
        fd = os.open(lease_path, os.O_RDONLY | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_NOFOLLOW", 0))
        try:
            raw = b""
            while len(raw) <= MAX_LEASE_BYTES:
                chunk = os.read(fd, 65536)
                if not chunk:
                    break
                raw += chunk
        finally:
            os.close(fd)
        # -- STRICT PARSE (R6 CODE-M2) --------------------------------------
        # Parse with Foundation-comparable strictness (reject NaN/Infinity, bare
        # floats, duplicate keys keep-first divergence, unpaired surrogates).
        # ANY strictness failure -- or a lone surrogate that would otherwise
        # raise UnicodeEncodeError deep in a validator -- becomes REMOVAL here,
        # never a reconciler crash: the broad except catches every parse-path
        # exception and routes it to removal.
        try:
            record = strict_json_loads(raw.decode("utf-8"))
        except Exception:
            record = None

    if remove:
        # Already decided by the storage gate; skip the record decision below.
        pass
    elif not isinstance(record, dict):
        # A malformed / strictly-rejected lease from the failed transaction is
        # not a live protected process; clear it so a restored CLI can mint a
        # fresh lease.
        remove = True
    else:
        # -- DECISION ORDER (R6 CODE-M4) ------------------------------------
        # Swift's validationFailure validates the record STRUCTURE FIRST, before
        # any boot/clock/owner-liveness check and before the prepared-handoff
        # exemption. Mirror that order exactly so NO preservation branch (live
        # owner OR prepared handoff) can rescue a record Swift's inspect() would
        # reject on read as .invalidField / .durationOutOfRange /
        # .unsupportedVersion (which would restart-loop the provider).
        #
        #   parse-strict -> storage gate  (both already done above)
        #   -> rollback-bound?  => REMOVE (valid regardless of structure: a
        #                          record we are undoing must never survive, and
        #                          removal is safe for a structurally invalid one)
        #   -> structure valid? => (no) REMOVE
        #   -> shared validity (boot + record wall/monotonic windows)? => (no) REMOVE
        #   -> record carries a `prepared` handoff?
        #        yes => prepared handoff exemption (handoff window)? KEEP else REMOVE
        #        no  => owner live? KEEP else REMOVE
        #
        # The last split MIRRORS Swift's validationFailure branch structure
        # EXACTLY (ProviderLifecycleLease.swift ~895..907): after the shared
        # boot/window checks, Swift takes `if let handoff = record.startupHandoff,
        # handoff.state == .prepared { ...handoff-window checks...; return nil }`
        # and ONLY reaches the owner process-start liveness check (~904) in the
        # ELSE case (no prepared handoff). For a record that carries a prepared
        # handoff, Swift's acceptance is governed SOLELY by the handoff window --
        # owner liveness is NEVER consulted. A previous order that ran
        # owner_is_live for ALL records would PRESERVE a live-owner record whose
        # prepared HANDOFF window is expired, yet Swift's inspect() rejects it as
        # .wallExpired at the handoff-window check -> restart loop (serve only
        # falls back on handoffNotPrepared). Routing prepared-handoff records
        # exclusively through the exemption closes that surface.
        #
        # The shared-validity gate mirrors validationFailure's boot/window checks
        # (ProviderLifecycleLease.swift ~888..894), which Swift runs AFTER
        # validateRecordStructure and BEFORE it branches to EITHER preservation
        # path (the prepared-handoff exemption OR the owner process-start
        # liveness check). owner_is_live checks only pid/boot/process-start, NOT
        # the record's wall/monotonic WINDOWS, so without this gate a LIVE
        # foreign owner with an out-of-window record would be PRESERVED here yet
        # REJECTED by Swift's validationFailure -- a restart-loop for a
        # handoff-bearing lease (serve only falls back on handoffNotPrepared).
        # Running it before BOTH branches keeps the reconciler's preserve-set a
        # subset of Swift's read-acceptance.
        #
        # The Swift ProviderLifecycleLeaseStore persists the owner NESTED under
        # `owner` (owner.pid / owner.process_start_us / owner.boot_session).
        lease_operation = record.get("operation_id")
        owner = record.get("owner")
        belongs_to_rollback = bool(
            install_operation_id
            and isinstance(lease_operation, str)
            and lease_operation == install_operation_id
        )
        if belongs_to_rollback:
            # A lease minted by the rolled-back transaction is removed
            # regardless of structure or any prepared handoff it carries: the
            # operation it authorizes is being undone, so its handoff (and the
            # operation/service/path/hash authorization inside it) must not
            # survive. Removal is safe even for a structurally invalid record;
            # only PRESERVATION requires structural validity.
            remove = True
        elif not record_matches_swift_structure(record):
            # Swift validates structure FIRST for EVERY record. A structurally
            # invalid record can never be preserved -- not by a live owner, not
            # by a prepared handoff -- because Swift's inspect() would reject it.
            # This gate runs BEFORE owner-liveness so a LIVE owner cannot rescue
            # an invalid record (the R6 CODE-M4 fix).
            remove = True
        elif not record_shared_validity_ok(record):
            # Swift's validationFailure runs the SHARED boot/window checks
            # (~888..894) AFTER structure and BEFORE either preservation branch.
            # A record whose boot session no longer matches, or whose wall or
            # monotonic window does not bracket `now`, is rejected by Swift's
            # inspect() regardless of owner liveness -- so a LIVE owner must NOT
            # rescue an out-of-window record (that would restart-loop a
            # handoff-bearing lease). This gate runs BEFORE the prepared/owner
            # split, exactly as Swift orders it (the MEDIUM fix).
            remove = True
        elif record_has_prepared_handoff(record):
            # MIRROR Swift's `if let handoff = record.startupHandoff,
            # handoff.state == .prepared { ... }` branch (~895..903): when the
            # record carries a `prepared` handoff, Swift's acceptance is governed
            # SOLELY by the handoff-window exemption -- it NEVER consults owner
            # liveness for such a record (the owner process-start check at ~904
            # is only reached in the ELSE / no-handoff case). So route
            # prepared-handoff records EXCLUSIVELY through the exemption: a live
            # owner must NOT rescue a record whose prepared handoff window is
            # expired (Swift rejects it as .wallExpired -> restart loop). The
            # store intentionally exempts an unexpired `.prepared` handoff from
            # owner liveness so launchd can adopt it AFTER the maintenance
            # process that prepared it has exited; prepared_handoff_preserves
            # checks the handoff window (and re-checks structure/boot/record
            # window, redundant but harmless) exactly as Swift's ~896..901 do.
            remove = not prepared_handoff_preserves(record)
        elif owner_is_live(owner):
            # No prepared handoff: MIRROR Swift's ELSE branch (~904), the owner
            # process-start liveness check. Structurally valid, in-window +
            # ordinary live foreign owner -> preserved.
            remove = False
        else:
            # No prepared handoff, structurally valid, in-window, but dead owner:
            # clear it (Swift's .ownerProcessMissingOrReused).
            remove = True

    if remove:
        try:
            os.unlink(lease_path)
        except FileNotFoundError:
            pass
        parent = os.path.dirname(lease_path)
        dir_fd = os.open(parent, os.O_RDONLY)
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
        # Assert the removal is durable.
        if lstat_or_none(lease_path) is not None:
            fail("lifecycle_lease_removal_not_durable")
finally:
    if lock_fd is not None:
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_UN)
        finally:
            os.close(lock_fd)
PY
}
recovery_failed() {
  recovery_log "$1"
  recovery_log "Recovery data was preserved. Retry exactly: bash '$RECOVERY_DIR/recover.sh'"
  exit 70
}
service_loaded() {
  recovery_launchctl print "$REC_LAUNCHD_DOMAIN/$1" >/dev/null 2>&1
}
service_identity_matches() {
  service_label="$1"
  expected_path="$2"
  expected_program="$3"
  alternate_program="$4"
  alternate_program_2="${5:-}"
  service_details="$(recovery_launchctl print "$REC_LAUNCHD_DOMAIN/$service_label" 2>/dev/null | head -c 65537)" || return 1
  [ "${#service_details}" -le 65536 ] || return 1
  program_count="$(printf '%s\n' "$service_details" | awk '/^[[:space:]]*program = / { count++ } END { print count + 0 }')"
  path_count="$(printf '%s\n' "$service_details" | awk '/^[[:space:]]*path = / { count++ } END { print count + 0 }')"
  [ "$program_count" -eq 1 ] || return 1
  [ "$path_count" -eq 1 ] || return 1
  service_program="$(printf '%s\n' "$service_details" | sed -n 's/^[[:space:]]*program = //p')"
  service_path="$(printf '%s\n' "$service_details" | sed -n 's/^[[:space:]]*path = //p')"
  [ "$service_path" = "$expected_path" ] || return 1
  [ "$service_program" = "$expected_program" ] \
    || [ "$service_program" = "$alternate_program" ] \
    || { [ -n "$alternate_program_2" ] && [ "$service_program" = "$alternate_program_2" ]; }
}
stop_loaded_service() {
  service_label="$1"
  expected_path="$2"
  expected_program="$3"
  alternate_program="$4"
  if [ "$#" -ge 6 ]; then
    alternate_program_2="$5"
    failure_message="$6"
  else
    alternate_program_2=""
    failure_message="$5"
  fi
  if ! service_loaded "$service_label"; then
    return 0
  fi
  service_identity_matches "$service_label" "$expected_path" "$expected_program" "$alternate_program" "$alternate_program_2" \
    || recovery_failed "$failure_message has an unexpected launchd identity"
  recovery_launchctl bootout "$REC_LAUNCHD_DOMAIN/$service_label" >/dev/null 2>&1 \
    || recovery_failed "$failure_message could not be stopped"
}

# Before the durable cutover marker exists, the installer has not touched the
# provider binary, config, launchd service, or manual process. Only the
# watchdog may have been suspended while recovery was armed. Recover that
# guard service without booting out or replacing the healthy incumbent.
if [ ! -e "$RECOVERY_DIR/cutover-started" ] && [ ! -L "$RECOVERY_DIR/cutover-started" ]; then
  if [ "$REC_SERVICE_WAS_ACTIVE" -eq 1 ]; then
    if ! recovery_launchctl print "$REC_LAUNCHD_DOMAIN/$REC_PROVIDER_LABEL" >/dev/null 2>&1; then
      [ "$REC_HAD_PLIST" -eq 1 ] \
        || recovery_failed "the prior provider service disappeared before cutover and no launchd plist was preserved"
      paths_match "$RECOVERY_DIR/provider.plist" "$REC_PLIST_PATH" file \
        || recovery_failed "the pre-cutover provider plist changed after the recovery snapshot"
      recovery_bootstrap_service "$REC_LAUNCHD_DOMAIN" "$REC_PLIST_BOOTSTRAP_PATH" "$REC_PROVIDER_LABEL" \
        || recovery_bootstrap_failed "could not restore the unexpectedly inactive pre-cutover provider service"
      recovery_launchctl kickstart -k "$REC_LAUNCHD_DOMAIN/$REC_PROVIDER_LABEL" >/dev/null 2>&1 \
        || recovery_failed "could not start the unexpectedly inactive pre-cutover provider service"
    fi
    service_identity_matches "$REC_PROVIDER_LABEL" "$REC_PLIST_BOOTSTRAP_PATH" \
      "$REC_INSTALL_DIR/macprovider-cli" "$REC_BINARY_PATH" "$REC_HEADLESS_REPAIR_INCUMBENT_BINARY" \
      || recovery_failed "pre-cutover provider service has an unexpected identity"
  fi
  if [ "$REC_LEGACY_SERVICE_WAS_ACTIVE" -eq 1 ]; then
    if ! recovery_launchctl print "$REC_LAUNCHD_DOMAIN/$REC_LEGACY_PROVIDER_LABEL" >/dev/null 2>&1; then
      [ "$REC_HAD_LEGACY_PLIST" -eq 1 ] \
        || recovery_failed "the prior legacy provider service disappeared before cutover and no launchd plist was preserved"
      paths_match "$RECOVERY_DIR/legacy-provider.plist" "$REC_LEGACY_PLIST_PATH" file \
        || recovery_failed "the pre-cutover legacy provider plist changed after the recovery snapshot"
      recovery_bootstrap_service "$REC_LAUNCHD_DOMAIN" "$REC_LEGACY_PLIST_BOOTSTRAP_PATH" "$REC_LEGACY_PROVIDER_LABEL" \
        || recovery_bootstrap_failed "could not restore the unexpectedly inactive pre-cutover legacy provider service"
      recovery_launchctl kickstart -k "$REC_LAUNCHD_DOMAIN/$REC_LEGACY_PROVIDER_LABEL" >/dev/null 2>&1 \
        || recovery_failed "could not start the unexpectedly inactive pre-cutover legacy provider service"
    fi
    service_identity_matches "$REC_LEGACY_PROVIDER_LABEL" "$REC_LEGACY_PLIST_BOOTSTRAP_PATH" \
      "$REC_INSTALL_DIR/macprovider-cli" "$REC_BINARY_PATH" \
      || recovery_failed "pre-cutover legacy provider service has an unexpected identity"
  fi
  if [ "$REC_WATCHDOG_WAS_ACTIVE" -eq 1 ]; then
    if ! recovery_launchctl print "$REC_LAUNCHD_DOMAIN/$REC_WATCHDOG_LABEL" >/dev/null 2>&1; then
      [ "$REC_HAD_WATCHDOG_PLIST" -eq 1 ] \
        || recovery_failed "the prior watchdog was active but no launchd plist was preserved"
      paths_match "$RECOVERY_DIR/watchdog.plist" "$REC_WATCHDOG_PLIST_PATH" file \
        || recovery_failed "the pre-cutover watchdog plist changed after the recovery snapshot"
      recovery_bootstrap_service "$REC_LAUNCHD_DOMAIN" "$REC_WATCHDOG_PLIST_BOOTSTRAP_PATH" "$REC_WATCHDOG_LABEL" \
        || recovery_bootstrap_failed "could not restore the pre-cutover watchdog service"
    fi
    recovery_launchctl kickstart -k "$REC_LAUNCHD_DOMAIN/$REC_WATCHDOG_LABEL" >/dev/null 2>&1 \
      || recovery_failed "could not start the pre-cutover watchdog service"
    service_identity_matches "$REC_WATCHDOG_LABEL" "$REC_WATCHDOG_PLIST_BOOTSTRAP_PATH" \
      "/Library/Application Support/macprovider/macprovider-health-monitor" "$REC_WATCHDOG_DIR/macprovider-health-monitor" "$REC_WATCHDOG_DIR/watchdog.sh" \
      || recovery_failed "pre-cutover watchdog service has an unexpected identity"
  fi
  if [ "$REC_LEGACY_WATCHDOG_WAS_ACTIVE" -eq 1 ]; then
    if ! recovery_launchctl print "$REC_LAUNCHD_DOMAIN/$REC_LEGACY_WATCHDOG_LABEL" >/dev/null 2>&1; then
      [ "$REC_HAD_LEGACY_WATCHDOG_PLIST" -eq 1 ] \
        || recovery_failed "the prior legacy watchdog was active but no launchd plist was preserved"
      paths_match "$RECOVERY_DIR/legacy-watchdog.plist" "$REC_LEGACY_WATCHDOG_PLIST_PATH" file \
        || recovery_failed "the pre-cutover legacy watchdog plist changed after the recovery snapshot"
      recovery_bootstrap_service "$REC_LAUNCHD_DOMAIN" "$REC_LEGACY_WATCHDOG_PLIST_BOOTSTRAP_PATH" "$REC_LEGACY_WATCHDOG_LABEL" \
        || recovery_bootstrap_failed "could not restore the pre-cutover legacy watchdog service"
    fi
    recovery_launchctl kickstart -k "$REC_LAUNCHD_DOMAIN/$REC_LEGACY_WATCHDOG_LABEL" >/dev/null 2>&1 \
      || recovery_failed "could not start the pre-cutover legacy watchdog service"
    service_identity_matches "$REC_LEGACY_WATCHDOG_LABEL" "$REC_LEGACY_WATCHDOG_PLIST_BOOTSTRAP_PATH" \
      "/Library/Application Support/macprovider/macprovider-health-monitor" "$REC_WATCHDOG_DIR/macprovider-health-monitor" "$REC_WATCHDOG_DIR/watchdog.sh" \
      || recovery_failed "pre-cutover legacy watchdog service has an unexpected identity"
  fi
  recovery_log "Cutover never started; incumbent provider files and process were left untouched."
  exit 0
fi
if [ -L "$RECOVERY_DIR/cutover-started" ] || [ ! -f "$RECOVERY_DIR/cutover-started" ]; then
  recovery_failed "install cutover marker is unsafe"
fi
pid_is_live_non_zombie() {
  candidate_pid="$1"
  kill -0 "$candidate_pid" >/dev/null 2>&1 || return 1
  candidate_state="$(ps -p "$candidate_pid" -o stat= 2>/dev/null | awk '{print $1}')"
  case "$candidate_state" in
    Z*|'') return 1 ;;
    *) return 0 ;;
  esac
}
stop_owned_manual_provider() {
  candidate_pid="$1"
  expected_executable="$2"
  alternate_executable="${3:-}"
  second_alternate_executable=""
  expected_port="${4:-}"
  if [ "$#" -ge 5 ]; then
    second_alternate_executable="${4:-}"
    expected_port="${5:-}"
  fi
  if [ -n "$expected_port" ]; then
    observed_port_pids="$(lsof -nP -iTCP:"$expected_port" -sTCP:LISTEN -t 2>/dev/null || true)"
    printf '%s\n' "$observed_port_pids" | grep -Fxq "$candidate_pid" || return 1
  fi
  observed_executable="$(lsof -nP -a -p "$candidate_pid" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1)"
  if [ "$observed_executable" != "$expected_executable" ] \
    && { [ -z "$alternate_executable" ] || [ "$observed_executable" != "$alternate_executable" ]; } \
    && { [ -z "$second_alternate_executable" ] || [ "$observed_executable" != "$second_alternate_executable" ]; }; then
    return 1
  fi
  kill -TERM "$candidate_pid" >/dev/null 2>&1 || return 1
  stop_attempt=0
  while [ "$stop_attempt" -lt 20 ] && pid_is_live_non_zombie "$candidate_pid"; do
    sleep 0.1
    stop_attempt=$((stop_attempt + 1))
  done
  if pid_is_live_non_zombie "$candidate_pid"; then
    observed_executable="$(lsof -nP -a -p "$candidate_pid" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1)"
    if [ "$observed_executable" != "$expected_executable" ] \
      && { [ -z "$alternate_executable" ] || [ "$observed_executable" != "$alternate_executable" ]; } \
      && { [ -z "$second_alternate_executable" ] || [ "$observed_executable" != "$second_alternate_executable" ]; }; then
      return 1
    fi
    kill -KILL "$candidate_pid" >/dev/null 2>&1 || return 1
    stop_attempt=0
    while [ "$stop_attempt" -lt 20 ] && pid_is_live_non_zombie "$candidate_pid"; do
      sleep 0.1
      stop_attempt=$((stop_attempt + 1))
    done
  fi
  ! pid_is_live_non_zombie "$candidate_pid"
}
preserve_failed_bootstrap_identity() {
  failed_config="$1"
  restored_config="$2"
  restored_provider_id="$3"
  [ -f "$failed_config" ] || return 0
  python3 - "$failed_config" "$restored_config" "$restored_provider_id" <<'PY'
import json
import os
import re
import sys

failed_path, restored_path, provider_id_path = sys.argv[1:]

def scalar(text, key):
    prefix = key + ":"
    values = [line[len(prefix):].strip() for line in text.splitlines() if line.startswith(prefix)]
    if not values:
        return None
    raw = values[-1]
    if raw.startswith('"'):
        try:
            return json.loads(raw)
        except Exception as error:
            raise SystemExit(f"invalid {key} scalar") from error
    return raw

def has_one_canonical_true(text, key):
    prefix = key + ":"
    values = [
        line[len(prefix):].strip()
        for line in text.splitlines()
        if line.startswith(prefix)
    ]
    return values == ["true"]

with open(failed_path, "r", encoding="utf-8") as handle:
    failed_text = handle.read()
provider_id = scalar(failed_text, "provider_id")
token = scalar(failed_text, "provider_token")
receipts_enabled = has_one_canonical_true(failed_text, "enable_receipts")
if not isinstance(provider_id, str) or re.fullmatch(r"mp-[0-9a-f]{32}", provider_id) is None:
    # Ordinary operator-issued identities are restored from the transaction
    # backup unchanged. Only installer-bootstrap identities participate in
    # durable same-key recovery and therefore need cross-rollback preservation.
    raise SystemExit(0)
if token is not None and (not isinstance(token, str) or re.fullmatch(r"[0-9a-f]{64}", token) is None):
    raise SystemExit(0)

if os.path.exists(restored_path):
    with open(restored_path, "r", encoding="utf-8") as handle:
        restored_text = handle.read()
    lines = []
    for line in restored_text.splitlines():
        if line.startswith("provider_id:"):
            continue
        # A failed v1.8.34+ bootstrap can be tokenless because its bearer is
        # already in CLI Keychain. If transaction rollback restored an older
        # token-bearing config, preserve that compatibility bearer so the old
        # binary remains viable. Only replace it when the failed config itself
        # carries an exact bootstrap token.
        if token is not None and line.startswith("provider_token:"):
            continue
        if receipts_enabled and line.startswith("enable_receipts:"):
            continue
        lines.append(line)
    lines.append("provider_id: " + json.dumps(provider_id))
    if token is not None:
        lines.append("provider_token: " + token)
    if receipts_enabled:
        lines.append("enable_receipts: true")
    updated = "\n".join(lines) + "\n"
else:
    lines = [
        line
        for line in failed_text.splitlines()
        if not line.startswith("enable_receipts:")
    ]
    if receipts_enabled:
        lines.append("enable_receipts: true")
    updated = "\n".join(lines) + "\n"

parent = os.path.dirname(restored_path)
os.makedirs(parent, mode=0o700, exist_ok=True)
temporary = restored_path + ".credential.tmp"
with open(temporary, "w", encoding="utf-8") as handle:
    handle.write(updated)
    handle.flush()
    os.fsync(handle.fileno())
os.chmod(temporary, 0o600)
os.replace(temporary, restored_path)

provider_id_parent = os.path.dirname(provider_id_path)
os.makedirs(provider_id_parent, mode=0o700, exist_ok=True)
provider_id_temporary = provider_id_path + ".credential.tmp"
with open(provider_id_temporary, "w", encoding="utf-8") as handle:
    handle.write(provider_id + "\n")
    handle.flush()
    os.fsync(handle.fileno())
os.chmod(provider_id_temporary, 0o600)
os.replace(provider_id_temporary, provider_id_path)

for directory in {parent, provider_id_parent}:
    directory_fd = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)
PY
}

RUN_ID="$(python3 -c 'import secrets; print(secrets.token_hex(16))')" \
  || recovery_failed "could not create recovery run id"
RESTORE_STAGING_DIR="$(mktemp -d "$RECOVERY_DIR/restore.XXXXXX")" \
  || recovery_failed "could not create randomized restore staging directory"
chmod 700 "$RESTORE_STAGING_DIR" \
  || recovery_failed "could not secure randomized restore staging directory"
INSTALL_CANDIDATE="$RESTORE_STAGING_DIR/install-dir"
BINARY_CANDIDATE="$RESTORE_STAGING_DIR/binary-path"
CONFIG_CANDIDATE="$RESTORE_STAGING_DIR/config.yaml"
PROVIDER_ID_CANDIDATE="$RESTORE_STAGING_DIR/provider_id"
RECOMMENDATION_CANDIDATE="$RESTORE_STAGING_DIR/last-recommendation.json"
PLIST_CANDIDATE="$RESTORE_STAGING_DIR/provider.plist"
LEGACY_PLIST_CANDIDATE="$RESTORE_STAGING_DIR/legacy-provider.plist"
WATCHDOG_DIR_CANDIDATE="$RESTORE_STAGING_DIR/watchdog-dir"
WATCHDOG_PLIST_CANDIDATE="$RESTORE_STAGING_DIR/watchdog.plist"
LEGACY_WATCHDOG_PLIST_CANDIDATE="$RESTORE_STAGING_DIR/legacy-watchdog.plist"
MANIFEST_CANDIDATE="$RESTORE_STAGING_DIR/install-manifest.json"
FAILED_CURRENT_DIR="$RECOVERY_DIR/failed-current/$RUN_ID"

# Prove every requested restore can be copied byte-for-byte before touching the
# currently installed paths. A failure here leaves both old and new installs as-is.
if [ "$REC_HAD_INSTALL_DIR" -eq 1 ]; then
  stage_restore "$RECOVERY_DIR/install-dir" "$INSTALL_CANDIDATE" directory || recovery_failed "could not stage and verify the previous install directory"
fi
if [ "$REC_HAD_BINARY_PATH" -eq 1 ]; then
  stage_restore "$RECOVERY_DIR/binary-path" "$BINARY_CANDIDATE" "$REC_BINARY_KIND" || recovery_failed "could not stage and verify the previous CLI path"
fi
if [ "$REC_HAD_CONFIG" -eq 1 ]; then
  stage_restore "$RECOVERY_DIR/config.yaml" "$CONFIG_CANDIDATE" file || recovery_failed "could not stage and verify the previous config"
fi
if [ "$REC_HAD_PROVIDER_ID" -eq 1 ]; then
  stage_restore "$RECOVERY_DIR/provider_id" "$PROVIDER_ID_CANDIDATE" file || recovery_failed "could not stage and verify the previous provider id"
fi
if [ "$REC_HAD_RECOMMENDATION" -eq 1 ]; then
  stage_restore "$RECOVERY_DIR/last-recommendation.json" "$RECOMMENDATION_CANDIDATE" file || recovery_failed "could not stage and verify the previous recommendation"
fi
if [ "$REC_HAD_PLIST" -eq 1 ]; then
  stage_restore "$RECOVERY_DIR/provider.plist" "$PLIST_CANDIDATE" file || recovery_failed "could not stage and verify the previous launchd plist"
fi
if [ "$REC_HAD_LEGACY_PLIST" -eq 1 ]; then
  stage_restore "$RECOVERY_DIR/legacy-provider.plist" "$LEGACY_PLIST_CANDIDATE" file || recovery_failed "could not stage and verify the previous legacy launchd plist"
fi
if [ "$REC_HAD_WATCHDOG_DIR" -eq 1 ]; then
  stage_restore "$RECOVERY_DIR/watchdog-dir" "$WATCHDOG_DIR_CANDIDATE" directory || recovery_failed "could not stage and verify the previous watchdog directory"
fi
if [ "$REC_HAD_WATCHDOG_PLIST" -eq 1 ]; then
  stage_restore "$RECOVERY_DIR/watchdog.plist" "$WATCHDOG_PLIST_CANDIDATE" file || recovery_failed "could not stage and verify the previous watchdog plist"
fi
if [ "$REC_HAD_LEGACY_WATCHDOG_PLIST" -eq 1 ]; then
  stage_restore "$RECOVERY_DIR/legacy-watchdog.plist" "$LEGACY_WATCHDOG_PLIST_CANDIDATE" file || recovery_failed "could not stage and verify the previous legacy watchdog plist"
fi
if [ "$REC_HAD_MANIFEST" -eq 1 ]; then
  stage_restore "$RECOVERY_DIR/install-manifest.json" "$MANIFEST_CANDIDATE" file || recovery_failed "could not stage and verify the previous install manifest"
fi
# The lifecycle-state file is not pre-staged as a plain byte candidate: it is
# restored under the store's lock by restore_lifecycle_state (translate/pause
# reconcile/atomic write/verify/fsync), reading the snapshot directly.

REC_INSTALL_DIR_PREMOVED=0
if [ "$REC_HAD_INSTALL_DIR" -eq 1 ] && ! path_exists "$REC_INSTALL_DIR"; then
  prior_failed_current_dir=""
  for existing_failed_current_dir in "$RECOVERY_DIR/failed-current"/*; do
    if [ -d "$existing_failed_current_dir" ] && [ ! -L "$existing_failed_current_dir" ] \
      && [ -d "$existing_failed_current_dir/install-dir" ] \
      && [ ! -L "$existing_failed_current_dir/install-dir" ]; then
      [ -z "$prior_failed_current_dir" ] \
        || recovery_failed "multiple interrupted install-directory move-asides were found"
      prior_failed_current_dir="$existing_failed_current_dir"
    fi
  done
  if [ -n "$prior_failed_current_dir" ]; then
    FAILED_CURRENT_DIR="$prior_failed_current_dir"
    REC_INSTALL_DIR_PREMOVED=1
    fsync_directory_path "$FAILED_CURRENT_DIR" || recovery_failed "could not validate the interrupted install-directory move-aside"
  fi
fi
if [ "$REC_INSTALL_DIR_PREMOVED" -eq 0 ]; then
  mkdir -p "$FAILED_CURRENT_DIR" || recovery_failed "could not create durable failed-install storage"
fi
chmod 700 "$RECOVERY_DIR/failed-current" "$FAILED_CURRENT_DIR" || recovery_failed "could not secure durable failed-install storage"
if [ "$REC_SERVICE_WAS_ACTIVE" -eq 1 ]; then
  [ "$REC_HAD_PLIST" -eq 1 ] || recovery_failed "the prior provider service was active but no recoverable plist was preserved"
  if [ -f "$RECOVERY_DIR/provider-service-created" ] && [ ! -L "$RECOVERY_DIR/provider-service-created" ]; then
    stop_loaded_service "$REC_PROVIDER_LABEL" "$REC_PLIST_BOOTSTRAP_PATH" \
      "$REC_INSTALL_DIR/macprovider-cli" "$REC_BINARY_PATH" "$REC_HEADLESS_REPAIR_INCUMBENT_BINARY" \
      "the transaction provider service"
  else
    stop_loaded_service "$REC_PROVIDER_LABEL" "$REC_PLIST_BOOTSTRAP_PATH" \
      "$REC_INSTALL_DIR/macprovider-cli" "$REC_BINARY_PATH" "$REC_HEADLESS_REPAIR_INCUMBENT_BINARY" \
      "the incumbent provider service"
  fi
else
  if [ -f "$RECOVERY_DIR/provider-service-created" ] && [ ! -L "$RECOVERY_DIR/provider-service-created" ]; then
    stop_loaded_service "$REC_PROVIDER_LABEL" "$REC_PLIST_BOOTSTRAP_PATH" \
      "$REC_INSTALL_DIR/macprovider-cli" "$REC_BINARY_PATH" "$REC_HEADLESS_REPAIR_INCUMBENT_BINARY" \
      "the transaction provider service"
  fi
  service_loaded "$REC_PROVIDER_LABEL" && recovery_failed "provider service is active even though it was inactive before the failed install"
fi
if [ "$REC_LEGACY_SERVICE_WAS_ACTIVE" -eq 1 ]; then
  [ "$REC_HAD_LEGACY_PLIST" -eq 1 ] || recovery_failed "the prior legacy provider service was active but no recoverable plist was preserved"
  stop_loaded_service "$REC_LEGACY_PROVIDER_LABEL" "$REC_LEGACY_PLIST_BOOTSTRAP_PATH" \
    "$REC_INSTALL_DIR/macprovider-cli" "$REC_BINARY_PATH" \
    "the incumbent legacy provider service"
fi
if [ "$REC_WATCHDOG_WAS_ACTIVE" -eq 1 ]; then
  [ "$REC_HAD_WATCHDOG_PLIST" -eq 1 ] || recovery_failed "the prior watchdog was active but no recoverable plist was preserved"
  stop_loaded_service "$REC_WATCHDOG_LABEL" "$REC_WATCHDOG_PLIST_BOOTSTRAP_PATH" \
    "/Library/Application Support/macprovider/macprovider-health-monitor" "$REC_WATCHDOG_DIR/macprovider-health-monitor" "$REC_WATCHDOG_DIR/watchdog.sh" \
    "the transaction watchdog service"
else
  if [ -f "$RECOVERY_DIR/watchdog-service-created" ] && [ ! -L "$RECOVERY_DIR/watchdog-service-created" ]; then
    stop_loaded_service "$REC_WATCHDOG_LABEL" "$REC_WATCHDOG_PLIST_BOOTSTRAP_PATH" \
      "/Library/Application Support/macprovider/macprovider-health-monitor" "$REC_WATCHDOG_DIR/macprovider-health-monitor" "$REC_WATCHDOG_DIR/watchdog.sh" \
      "the transaction watchdog service"
  fi
  service_loaded "$REC_WATCHDOG_LABEL" && recovery_failed "watchdog service is active even though it was inactive before the failed install"
fi
if [ "$REC_LEGACY_WATCHDOG_WAS_ACTIVE" -eq 1 ]; then
  [ "$REC_HAD_LEGACY_WATCHDOG_PLIST" -eq 1 ] || recovery_failed "the prior legacy watchdog was active but no recoverable plist was preserved"
  stop_loaded_service "$REC_LEGACY_WATCHDOG_LABEL" "$REC_LEGACY_WATCHDOG_PLIST_BOOTSTRAP_PATH" \
    "/Library/Application Support/macprovider/macprovider-health-monitor" "$REC_WATCHDOG_DIR/macprovider-health-monitor" "$REC_WATCHDOG_DIR/watchdog.sh" \
    "the incumbent legacy watchdog service"
fi
# INSTALL_DIR intentionally permits unrelated support files. Stop all owners
# first, then move the live directory to a stable private name before merging
# unmanaged entries into the staged incumbent. If the merge fails, restore the
# rename so the original install remains reachable for a later retry.
if [ "$REC_HAD_INSTALL_DIR" -eq 1 ]; then
  if [ "$REC_INSTALL_DIR_PREMOVED" -eq 0 ]; then
    path_exists "$REC_INSTALL_DIR" || recovery_failed "the previous install directory disappeared before rollback"
    durable_move "$REC_INSTALL_DIR" "$FAILED_CURRENT_DIR/install-dir" \
      || recovery_failed "could not stabilize the previous install directory before rollback"
    REC_INSTALL_DIR_PREMOVED=1
  else
    path_exists "$FAILED_CURRENT_DIR/install-dir" \
      || recovery_failed "the interrupted install-directory move-aside disappeared before rollback"
  fi
  if ! preserve_unmanaged_install_entries "$FAILED_CURRENT_DIR/install-dir" "$INSTALL_CANDIDATE"; then
    durable_move "$FAILED_CURRENT_DIR/install-dir" "$REC_INSTALL_DIR" \
      || recovery_failed "could not restore the previous install directory after preserving unrelated content"
    REC_INSTALL_DIR_PREMOVED=0
    recovery_failed "could not preserve unrelated install-directory content"
  fi
fi
if [ -s "$RECOVERY_DIR/new-manual.pid" ]; then
  NEW_MANUAL_PID="$(cat "$RECOVERY_DIR/new-manual.pid")"
  case "$NEW_MANUAL_PID" in
    ''|*[!0-9]*) recovery_failed "recorded manual provider pid is invalid" ;;
  esac
  if pid_is_live_non_zombie "$NEW_MANUAL_PID"; then
    stop_owned_manual_provider "$NEW_MANUAL_PID" "$REC_INSTALL_DIR/macprovider-cli" \
      || recovery_failed "could not stop and prove death of the failed manual provider process"
  fi
fi

swap_restore install-dir "$REC_INSTALL_DIR" "$INSTALL_CANDIDATE" "$REC_HAD_INSTALL_DIR" || recovery_failed "could not restore the previous install directory"
swap_restore binary-path "$REC_BINARY_PATH" "$BINARY_CANDIDATE" "$REC_HAD_BINARY_PATH" || recovery_failed "could not restore the previous CLI path"
swap_restore config.yaml "$REC_CONFIG_PATH" "$CONFIG_CANDIDATE" "$REC_HAD_CONFIG" || recovery_failed "could not restore the previous config"
swap_restore provider_id "$REC_PROVIDER_ID_PATH" "$PROVIDER_ID_CANDIDATE" "$REC_HAD_PROVIDER_ID" || recovery_failed "could not restore the previous provider id"
swap_restore last-recommendation.json "$REC_RECOMMENDATION_PATH" "$RECOMMENDATION_CANDIDATE" "$REC_HAD_RECOMMENDATION" || recovery_failed "could not restore the previous recommendation"
if [ "${REC_REFERRAL_REPLACE_INCUMBENT:-0}" = "1" ] && { [ "$REC_HAD_CONFIG" -eq 1 ] || [ "$REC_HAD_PROVIDER_ID" -eq 1 ]; }; then
  recovery_log "Fresh provider replacement failed; preserving restored incumbent identity instead of the failed replacement identity."
else
  preserve_failed_bootstrap_identity "$FAILED_CURRENT_DIR/config.yaml" "$REC_CONFIG_PATH" "$REC_PROVIDER_ID_PATH" \
    || recovery_failed "could not preserve the installer bootstrap identity through rollback"
fi
swap_restore provider.plist "$REC_PLIST_PATH" "$PLIST_CANDIDATE" "$REC_HAD_PLIST" || recovery_failed "could not restore the previous launchd plist"
swap_restore legacy-provider.plist "$REC_LEGACY_PLIST_PATH" "$LEGACY_PLIST_CANDIDATE" "$REC_HAD_LEGACY_PLIST" || recovery_failed "could not restore the previous legacy launchd plist"
swap_restore watchdog-dir "$REC_WATCHDOG_DIR" "$WATCHDOG_DIR_CANDIDATE" "$REC_HAD_WATCHDOG_DIR" || recovery_failed "could not restore the previous watchdog directory"
swap_restore watchdog.plist "$REC_WATCHDOG_PLIST_PATH" "$WATCHDOG_PLIST_CANDIDATE" "$REC_HAD_WATCHDOG_PLIST" || recovery_failed "could not restore the previous watchdog plist"
swap_restore legacy-watchdog.plist "$REC_LEGACY_WATCHDOG_PLIST_PATH" "$LEGACY_WATCHDOG_PLIST_CANDIDATE" "$REC_HAD_LEGACY_WATCHDOG_PLIST" || recovery_failed "could not restore the previous legacy watchdog plist"
sync_recovery_launchd_plist "$REC_PLIST_PATH" "$REC_PLIST_BOOTSTRAP_PATH" "$REC_HAD_PLIST" || recovery_failed "could not republish the previous provider LaunchDaemon plist"
sync_recovery_launchd_plist "$REC_LEGACY_PLIST_PATH" "$REC_LEGACY_PLIST_BOOTSTRAP_PATH" "$REC_HAD_LEGACY_PLIST" || recovery_failed "could not republish the previous legacy provider LaunchDaemon plist"
sync_recovery_launchd_plist "$REC_WATCHDOG_PLIST_PATH" "$REC_WATCHDOG_PLIST_BOOTSTRAP_PATH" "$REC_HAD_WATCHDOG_PLIST" || recovery_failed "could not republish the previous watchdog LaunchDaemon plist"
sync_recovery_launchd_plist "$REC_LEGACY_WATCHDOG_PLIST_PATH" "$REC_LEGACY_WATCHDOG_PLIST_BOOTSTRAP_PATH" "$REC_HAD_LEGACY_WATCHDOG_PLIST" || recovery_failed "could not republish the previous legacy watchdog LaunchDaemon plist"
swap_restore install-manifest.json "$REC_MANIFEST_PATH" "$MANIFEST_CANDIDATE" "$REC_HAD_MANIFEST" || recovery_failed "could not restore the previous install manifest"
# The lifecycle-state file is restored last so the transactional intermediate
# state (rollback_in_progress) authored before recovery began stays observable
# for the whole rollback, and the reconciled prior contents (or prior absence)
# are the final durable outcome. restore_lifecycle_state holds the store's lock
# across the read + swap, preserves a durable operator pause set during the
# transaction, translates an updater-written snapshot into an installer-owned
# record so a restored lifecycle-aware CLI cannot be fenced on a dead operation,
# verifies the final file/absence, and fsyncs the file and its parent directory
# before recovery can report success.
restore_lifecycle_state || recovery_failed "could not restore the previous lifecycle state"
# Reconcile the operation-bound lease so a stale/dead-owner lease from the
# failed transaction cannot survive rollback while a live foreign owner is
# preserved. The lock files themselves are never touched.
reconcile_lifecycle_lease || recovery_failed "could not reconcile the lifecycle lease after rollback"

if [ "$REC_SERVICE_WAS_DISABLED" -eq 1 ]; then
  recovery_launchctl disable "$REC_LAUNCHD_DOMAIN/$REC_PROVIDER_LABEL" >/dev/null 2>&1 || recovery_failed "could not restore the disabled provider service state"
else
  recovery_launchctl enable "$REC_LAUNCHD_DOMAIN/$REC_PROVIDER_LABEL" >/dev/null 2>&1 || recovery_failed "could not restore the enabled provider service state"
fi
if [ "$REC_SERVICE_WAS_ACTIVE" -eq 1 ]; then
  [ "$REC_HAD_PLIST" -eq 1 ] || recovery_failed "previous service was active but no previous plist was preserved"
  recovery_bootstrap_service "$REC_LAUNCHD_DOMAIN" "$REC_PLIST_BOOTSTRAP_PATH" "$REC_PROVIDER_LABEL" || recovery_bootstrap_failed "could not bootstrap the previous provider service"
  recovery_launchctl kickstart -k "$REC_LAUNCHD_DOMAIN/$REC_PROVIDER_LABEL" >/dev/null 2>&1 || recovery_failed "could not kickstart the previous provider service"
  service_identity_matches "$REC_PROVIDER_LABEL" "$REC_PLIST_BOOTSTRAP_PATH" \
    "$REC_INSTALL_DIR/macprovider-cli" "$REC_BINARY_PATH" "$REC_HEADLESS_REPAIR_INCUMBENT_BINARY" \
    || recovery_failed "previous provider service has an unexpected identity"
elif [ "$REC_LEGACY_SERVICE_WAS_ACTIVE" -eq 1 ]; then
  [ "$REC_HAD_LEGACY_PLIST" -eq 1 ] || recovery_failed "previous legacy service was active but no previous plist was preserved"
  recovery_bootstrap_service "$REC_LAUNCHD_DOMAIN" "$REC_LEGACY_PLIST_BOOTSTRAP_PATH" "$REC_LEGACY_PROVIDER_LABEL" || recovery_bootstrap_failed "could not bootstrap the previous legacy provider service"
  recovery_launchctl kickstart -k "$REC_LAUNCHD_DOMAIN/$REC_LEGACY_PROVIDER_LABEL" >/dev/null 2>&1 || recovery_failed "could not kickstart the previous legacy provider service"
  service_identity_matches "$REC_LEGACY_PROVIDER_LABEL" "$REC_LEGACY_PLIST_BOOTSTRAP_PATH" \
    "$REC_INSTALL_DIR/macprovider-cli" "$REC_BINARY_PATH" \
    || recovery_failed "previous legacy provider service has an unexpected identity"
else
  if recovery_launchctl print "$REC_LAUNCHD_DOMAIN/$REC_PROVIDER_LABEL" >/dev/null 2>&1; then
    recovery_failed "provider service is active even though it was inactive before the failed install"
  fi
  if recovery_launchctl print "$REC_LAUNCHD_DOMAIN/$REC_LEGACY_PROVIDER_LABEL" >/dev/null 2>&1; then
    recovery_failed "legacy provider service is active even though it was inactive before the failed install"
  fi
fi

if [ "$REC_WATCHDOG_WAS_DISABLED" -eq 1 ]; then
  recovery_launchctl disable "$REC_LAUNCHD_DOMAIN/$REC_WATCHDOG_LABEL" >/dev/null 2>&1 || recovery_failed "could not restore the disabled watchdog service state"
else
  recovery_launchctl enable "$REC_LAUNCHD_DOMAIN/$REC_WATCHDOG_LABEL" >/dev/null 2>&1 || recovery_failed "could not restore the enabled watchdog service state"
fi
if [ "$REC_WATCHDOG_WAS_ACTIVE" -eq 1 ]; then
  [ "$REC_HAD_WATCHDOG_PLIST" -eq 1 ] || recovery_failed "previous watchdog was active but no previous plist was preserved"
  recovery_bootstrap_service "$REC_LAUNCHD_DOMAIN" "$REC_WATCHDOG_PLIST_BOOTSTRAP_PATH" "$REC_WATCHDOG_LABEL" || recovery_bootstrap_failed "could not bootstrap the previous watchdog service"
  recovery_launchctl kickstart -k "$REC_LAUNCHD_DOMAIN/$REC_WATCHDOG_LABEL" >/dev/null 2>&1 || recovery_failed "could not kickstart the previous watchdog service"
  service_identity_matches "$REC_WATCHDOG_LABEL" "$REC_WATCHDOG_PLIST_BOOTSTRAP_PATH" \
    "/Library/Application Support/macprovider/macprovider-health-monitor" "$REC_WATCHDOG_DIR/macprovider-health-monitor" "$REC_WATCHDOG_DIR/watchdog.sh" \
    || recovery_failed "previous watchdog service has an unexpected identity"
elif [ "$REC_LEGACY_WATCHDOG_WAS_ACTIVE" -eq 1 ]; then
  [ "$REC_HAD_LEGACY_WATCHDOG_PLIST" -eq 1 ] || recovery_failed "previous legacy watchdog was active but no previous plist was preserved"
  recovery_bootstrap_service "$REC_LAUNCHD_DOMAIN" "$REC_LEGACY_WATCHDOG_PLIST_BOOTSTRAP_PATH" "$REC_LEGACY_WATCHDOG_LABEL" || recovery_bootstrap_failed "could not bootstrap the previous legacy watchdog service"
  recovery_launchctl kickstart -k "$REC_LAUNCHD_DOMAIN/$REC_LEGACY_WATCHDOG_LABEL" >/dev/null 2>&1 || recovery_failed "could not kickstart the previous legacy watchdog service"
  service_identity_matches "$REC_LEGACY_WATCHDOG_LABEL" "$REC_LEGACY_WATCHDOG_PLIST_BOOTSTRAP_PATH" \
    "/Library/Application Support/macprovider/macprovider-health-monitor" "$REC_WATCHDOG_DIR/macprovider-health-monitor" "$REC_WATCHDOG_DIR/watchdog.sh" \
    || recovery_failed "previous legacy watchdog service has an unexpected identity"
else
  if recovery_launchctl print "$REC_LAUNCHD_DOMAIN/$REC_WATCHDOG_LABEL" >/dev/null 2>&1; then
    recovery_failed "watchdog service is active even though it was inactive before the failed install"
  fi
  if recovery_launchctl print "$REC_LAUNCHD_DOMAIN/$REC_LEGACY_WATCHDOG_LABEL" >/dev/null 2>&1; then
    recovery_failed "legacy watchdog service is active even though it was inactive before the failed install"
  fi
fi

if [ -s "$RECOVERY_DIR/manual-provider.json" ]; then
  [ "$REC_SERVICE_WAS_ACTIVE" -eq 0 ] || recovery_failed "manual provider record conflicts with an active prior launchd service"
  [ "$REC_LEGACY_SERVICE_WAS_ACTIVE" -eq 0 ] || recovery_failed "manual provider record conflicts with an active prior legacy launchd service"
  mkdir -p "$REC_LOG_DIR" || recovery_failed "could not recreate the previous manual provider log directory"
  python3 - "$RECOVERY_DIR/manual-provider.json" "$REC_INSTALL_DIR/macprovider-cli" \
    "$REC_LOG_DIR/macprovider.out.log" "$REC_LOG_DIR/macprovider.err.log" \
    "$RECOVERY_DIR/manual-restored.pid" "$REC_MANUAL_READY_TIMEOUT_SECONDS" <<'PY' \
    || recovery_failed "could not restart the previous manual provider safely"
import base64
import hashlib
import json
import os
import signal
import subprocess
import sys
import time

record_path, executable, stdout_path, stderr_path, pid_path, timeout_text = sys.argv[1:]
with open(record_path, "r", encoding="utf-8") as handle:
    record = json.load(handle)
if set(record) != {"version", "arguments_b64", "environment_b64", "working_directory_b64", "binary_sha256", "port"} or record["version"] != 3:
    raise SystemExit("invalid manual provider recovery schema")
encoded_arguments = record["arguments_b64"]
if not isinstance(encoded_arguments, list) or len(encoded_arguments) > 128:
    raise SystemExit("invalid manual provider arguments")
arguments = []
for encoded in encoded_arguments:
    if not isinstance(encoded, str) or len(encoded) > 8192:
        raise SystemExit("invalid manual provider argument encoding")
    try:
        argument = base64.b64decode(encoded, validate=True)
    except Exception as error:
        raise SystemExit("invalid manual provider argument encoding") from error
    if base64.b64encode(argument).decode("ascii") != encoded or b"\x00" in argument or len(argument) > 4096:
        raise SystemExit("invalid manual provider argument encoding")
    arguments.append(argument)
if sum(map(len, arguments)) > 65536:
    raise SystemExit("manual provider argument bounds exceeded")
try:
    working_directory = base64.b64decode(record["working_directory_b64"], validate=True)
except Exception as error:
    raise SystemExit("invalid manual provider working directory") from error
if (base64.b64encode(working_directory).decode("ascii") != record["working_directory_b64"]
        or b"\x00" in working_directory or not working_directory.startswith(b"/")
        or len(working_directory) > 4096 or not os.path.isdir(working_directory)):
    raise SystemExit("invalid manual provider working directory")
encoded_environment = record["environment_b64"]
if not isinstance(encoded_environment, list) or len(encoded_environment) > 512:
    raise SystemExit("invalid manual provider environment")
environment = {}
environment_bytes = 0
for encoded in encoded_environment:
    if not isinstance(encoded, str) or len(encoded) > 16384:
        raise SystemExit("invalid manual provider environment encoding")
    try:
        entry = base64.b64decode(encoded, validate=True)
    except Exception as error:
        raise SystemExit("invalid manual provider environment encoding") from error
    if base64.b64encode(entry).decode("ascii") != encoded or b"\x00" in entry or len(entry) > 8192 or b"=" not in entry:
        raise SystemExit("invalid manual provider environment encoding")
    key, value = entry.split(b"=", 1)
    if not key or b"=" in key or key in environment:
        raise SystemExit("invalid manual provider environment key")
    environment[key] = value
    environment_bytes += len(entry)
if environment_bytes > 262144:
    raise SystemExit("manual provider environment bounds exceeded")
port = record["port"]
if isinstance(port, bool) or not isinstance(port, int) or not 1024 <= port <= 65535:
    raise SystemExit("invalid manual provider port")
expected_port = str(port).encode("ascii")
if not any(
    (argument == b"--port" and index + 1 < len(arguments) and arguments[index + 1] == expected_port)
    or argument == b"--port=" + expected_port
    for index, argument in enumerate(arguments)
):
    raise SystemExit("manual provider port binding missing")
with open(executable, "rb") as handle:
    digest = hashlib.sha256(handle.read()).hexdigest()
if digest != record["binary_sha256"]:
    raise SystemExit("restored manual provider binary does not match captured last-known-good binary")
try:
    ready_timeout = int(timeout_text)
except ValueError as error:
    raise SystemExit("invalid manual provider readiness timeout") from error
if not 1 <= ready_timeout <= 60:
    raise SystemExit("invalid manual provider readiness timeout")

process = None
cleanup_armed = False
temporary = pid_path + ".tmp"

def terminate_process_group(child):
    """Stop the restored provider and every descendant in its private session."""
    process_group = child.pid  # start_new_session=True makes the child its PGID.

    def signal_group(signal_number):
        try:
            os.killpg(process_group, signal_number)
        except ProcessLookupError:
            pass

    if child.poll() is None:
        signal_group(signal.SIGTERM)
    try:
        child.wait(timeout=2)
    except subprocess.TimeoutExpired:
        signal_group(signal.SIGKILL)
        child.wait(timeout=2)

    # The leader may have exited while a descendant remains in the private
    # session. Prove that the process group has drained before reporting the
    # recovery failure; otherwise a retry can inherit an orphaned listener.
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        try:
            os.killpg(process_group, 0)
        except ProcessLookupError:
            return
        except PermissionError:
            break
        time.sleep(0.05)
    signal_group(signal.SIGKILL)
    try:
        child.wait(timeout=2)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process_group, 0)
    except ProcessLookupError:
        return
    raise RuntimeError(f"restored manual provider process group {process_group} survived cleanup")

try:
    with open(stdout_path, "ab", buffering=0) as stdout, open(stderr_path, "ab", buffering=0) as stderr:
        process = subprocess.Popen(
            [os.fsencode(executable), *arguments], cwd=working_directory, env=environment,
            stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr,
            start_new_session=True, close_fds=True,
        )
        cleanup_armed = True
    deadline = time.monotonic() + ready_timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError("restored manual provider exited before binding its previous port")
        probe = subprocess.run(
            ["lsof", "-nP", "-a", "-p", str(process.pid), f"-iTCP:{port}", "-sTCP:LISTEN", "-t"],
            check=False, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=2,
        )
        owners = [line.strip() for line in probe.stdout.splitlines() if line.strip()]
        if probe.returncode == 0 and owners and all(owner == str(process.pid).encode("ascii") for owner in owners):
            with open(temporary, "w", encoding="ascii") as handle:
                handle.write(f"{process.pid}\n")
                handle.flush()
                os.fsync(handle.fileno())
            os.chmod(temporary, 0o600)
            os.replace(temporary, pid_path)
            directory_fd = os.open(os.path.dirname(pid_path), os.O_RDONLY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
            cleanup_armed = False
            break
        time.sleep(0.1)
    else:
        raise RuntimeError("restored manual provider did not bind its previous port")
except BaseException as original_error:
    cleanup_error = None
    if cleanup_armed and process is not None:
        try:
            terminate_process_group(process)
        except BaseException as error:
            cleanup_error = error
    for path in (temporary, pid_path):
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
    if cleanup_error is not None:
        raise RuntimeError(f"manual provider recovery failed and cleanup could not prove death: {cleanup_error}") from original_error
    raise
PY
  RESTORED_MANUAL_PID="$(cat "$RECOVERY_DIR/manual-restored.pid")"
  case "$RESTORED_MANUAL_PID" in
    ''|*[!0-9]*) recovery_failed "restored manual provider pid is invalid" ;;
  esac
  recovery_log "Restored prior manual provider pid=$RESTORED_MANUAL_PID with exact prior argv and port ownership."
fi

recovery_log "Previous provider, recommendation, watchdog, manifest, service, and manual-process states were restored and verified."
rm -rf "$RESTORE_STAGING_DIR" || recovery_failed "could not retire randomized restore staging directory"
fsync_directory_path "$(dirname "$RESTORE_STAGING_DIR")" \
  || recovery_failed "could not durably retire randomized restore staging directory"
exit 0
RECOVERY_SCRIPT
  bash -n "$recovery_script" || return 1
  observer_script="$recovery_dir/observe.sh"
  write_atomic_install_file "$observer_script" 0700 <<'OBSERVER_SCRIPT'
#!/usr/bin/env bash
set -u

RECOVERY_DIR="$(cd "$(dirname "$0")" && pwd)" || exit 70
# shellcheck disable=SC1091
. "$RECOVERY_DIR/state.sh" || exit 70

process_start() {
  ps -p "$1" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

while [ -d "$RECOVERY_DIR" ] \
  && [ "$(/usr/sbin/sysctl -n kern.bootsessionuuid 2>/dev/null || true)" = "$REC_INSTALLER_BOOT_SESSION" ] \
  && [ "$(process_start "$REC_INSTALLER_PID")" = "$REC_INSTALLER_PROCESS_START" ]; do
  sleep 1
done

[ -d "$RECOVERY_DIR" ] || exit 0
exec python3 - "$RECOVERY_DIR" "$REC_INSTALL_LOCK_PATH" \
  "$REC_INSTALL_RECOVERY_PLIST_PATH" "$REC_UID" "$REC_INSTALL_RECOVERY_LABEL" <<'PY'
import fcntl
import os
import shutil
import stat
import subprocess
import sys

recovery_dir, lock_path, plist_path, uid, label = sys.argv[1:]

def fsync_directory(path):
    fd = os.open(
        path,
        os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0),
    )
    try:
        info = os.fstat(fd)
        if (
            not stat.S_ISDIR(info.st_mode)
            or info.st_uid != os.getuid()
            or info.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
        ):
            raise RuntimeError("unsafe recovery parent directory")
        os.fsync(fd)
    finally:
        os.close(fd)

lock_fd = os.open(lock_path, os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
try:
    info = os.fstat(lock_fd)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        raise SystemExit("unsafe installer lock; automatic recovery refused")
    fcntl.flock(lock_fd, fcntl.LOCK_EX)
    if not os.path.isdir(recovery_dir):
        raise SystemExit(0)
    result = subprocess.run(["bash", os.path.join(recovery_dir, "recover.sh")], check=False)
    if result.returncode == 75:
        raise SystemExit(0)
    if result.returncode != 0:
        print(
            f"[macprovider-recovery] Automatic interrupted-install recovery failed. "
            f"Run exactly: bash {os.path.join(recovery_dir, 'recover.sh')!r}",
            file=sys.stderr,
        )
        raise SystemExit(result.returncode)
    recovery_parent = os.path.dirname(recovery_dir)
    shutil.rmtree(recovery_dir)
    fsync_directory(recovery_parent)
    try:
        os.unlink(plist_path)
    except FileNotFoundError:
        pass
    fsync_directory(os.path.dirname(plist_path))
    subprocess.run(
        ["launchctl", "bootout", f"gui/{uid}/{label}"],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
finally:
    os.close(lock_fd)
PY
OBSERVER_SCRIPT
  bash -n "$observer_script" || return 1
  [ -s "$state_path" ] && [ -s "$recovery_script" ] && [ -s "$observer_script" ]
}

fsync_directory_path() {
  directory_path="$1"
  python3 - "$directory_path" <<'PY'
import os
import stat
import sys

path = sys.argv[1]
fd = os.open(
    path,
    os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0),
)
try:
    info = os.fstat(fd)
    if (
        not stat.S_ISDIR(info.st_mode)
        or info.st_uid != os.getuid()
        or info.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
    ):
        raise SystemExit("unsafe directory for durable rename")
    os.fsync(fd)
finally:
    os.close(fd)
PY
}

disarm_install_recovery_agent() {
  if [ "$HEADLESS" = "1" ]; then
    retire_headless_recovery_trust
    return
  fi
  launchctl_service bootout "$LAUNCHD_DOMAIN/$INSTALL_RECOVERY_LABEL" >/dev/null 2>&1 || true
  rm -f "$INSTALL_RECOVERY_PLIST_PATH" || return 70
  fsync_directory_path "$(dirname "$INSTALL_RECOVERY_PLIST_PATH")" || return 70
}

arm_install_recovery_agent() {
  [ -n "$INSTALL_TX_BACKUP" ] && [ -x "$INSTALL_TX_BACKUP/observe.sh" ] || return 70
  if [ "$HEADLESS" = "1" ]; then
    publish_headless_recovery_trust "$INSTALL_TX_BACKUP" || return 70
    log "Headless mode: durable interrupted-install recovery is deferred until the next installer invocation."
    return 0
  fi
  mkdir -p "$(dirname "$INSTALL_RECOVERY_PLIST_PATH")" || return 70
  disarm_install_recovery_agent || return 70
  python3 - "$INSTALL_RECOVERY_LABEL" "$INSTALL_TX_BACKUP/observe.sh" \
    "$INSTALL_TX_BACKUP/recovery-observer.out.log" "$INSTALL_TX_BACKUP/recovery-observer.err.log" <<'PY' \
    | write_atomic_install_file "$INSTALL_RECOVERY_PLIST_PATH" 0600 \
    || return 70
import plistlib
import sys

label, observer, stdout_path, stderr_path = sys.argv[1:]
payload = {
    "Label": label,
    "ProgramArguments": ["/bin/bash", observer],
    "RunAtLoad": True,
    "KeepAlive": False,
    "StandardOutPath": stdout_path,
    "StandardErrorPath": stderr_path,
}
sys.stdout.buffer.write(plistlib.dumps(payload, fmt=plistlib.FMT_XML, sort_keys=True))
PY
  launchctl_service bootstrap "$LAUNCHD_DOMAIN" "$INSTALL_RECOVERY_PLIST_PATH" >/dev/null 2>&1 || return 70
  launchctl_service kickstart -k "$LAUNCHD_DOMAIN/$INSTALL_RECOVERY_LABEL" >/dev/null 2>&1 || return 70
}

launchd_label_is_disabled() {
  label="$1"
  disabled_state="$(launchctl_service print-disabled "$LAUNCHD_DOMAIN" 2>/dev/null || true)"
  case "$disabled_state" in
    *'"'"$label"'" => true'*) return 0 ;;
    *) return 1 ;;
  esac
}

capture_manual_provider_for_recovery() {
  manual_pid="$1"
  [ "$INSTALL_TX_ACTIVE" -eq 1 ] || die 70 "manual provider capture requires an active install transaction"
  [ "$INSTALL_TX_SERVICE_WAS_ACTIVE" -eq 0 ] || return 0
  [ "$INSTALL_TX_LEGACY_SERVICE_WAS_ACTIVE" -eq 0 ] || return 0
  case "$manual_pid" in
    ''|*[!0-9]*) die 70 "manual provider pid is invalid" ;;
  esac
  manual_executable="$(lsof -nP -a -p "$manual_pid" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1)"
  [ -n "$manual_executable" ] \
    || die 70 "could not capture the existing manual provider invocation before stopping it"
  manual_cwd="$(lsof -nP -a -p "$manual_pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1)"
  [ -n "$manual_cwd" ] \
    || die 70 "could not capture the existing manual provider working directory before stopping it"
  python3 - "$manual_pid" "$manual_executable" "$INSTALL_DIR/macprovider-cli" "$BINARY_PATH" \
    "$manual_cwd" "$PORT" "$INSTALL_TX_BACKUP/manual-provider.json" <<'PY' \
    || die 70 "existing manual provider invocation was not safe to preserve; current provider was left running"
import base64
import ctypes
import hashlib
import json
import os
import struct
import sys

pid_text, observed_executable, install_executable, path_executable, observed_cwd, port, output = sys.argv[1:]
if sys.platform != "darwin":
    raise SystemExit("exact process argv capture requires macOS KERN_PROCARGS2")
try:
    pid = int(pid_text)
except ValueError as error:
    raise SystemExit("invalid manual provider pid") from error
observed = os.path.realpath(observed_executable)
trusted = {os.path.realpath(path) for path in (install_executable, path_executable) if os.path.exists(path)}
if observed not in trusted:
    raise SystemExit("manual provider executable is not a trusted installed macprovider-cli")

libc = ctypes.CDLL(None, use_errno=True)
libc.sysctlbyname.argtypes = [
    ctypes.c_char_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_size_t), ctypes.c_void_p, ctypes.c_size_t,
]
libc.sysctlbyname.restype = ctypes.c_int
libc.sysctl.argtypes = [
    ctypes.POINTER(ctypes.c_int), ctypes.c_uint, ctypes.c_void_p,
    ctypes.POINTER(ctypes.c_size_t), ctypes.c_void_p, ctypes.c_size_t,
]
libc.sysctl.restype = ctypes.c_int
argmax = ctypes.c_int()
argmax_size = ctypes.c_size_t(ctypes.sizeof(argmax))
if libc.sysctlbyname(b"kern.argmax", ctypes.byref(argmax), ctypes.byref(argmax_size), None, 0) != 0:
    raise OSError(ctypes.get_errno(), "sysctl kern.argmax failed")
if argmax.value <= ctypes.sizeof(ctypes.c_int) or argmax.value > 16 * 1024 * 1024:
    raise SystemExit("invalid kern.argmax value")
mib = (ctypes.c_int * 3)(1, 49, pid)  # CTL_KERN, KERN_PROCARGS2, pid
buffer = ctypes.create_string_buffer(argmax.value)
buffer_size = ctypes.c_size_t(argmax.value)
if libc.sysctl(mib, 3, buffer, ctypes.byref(buffer_size), None, 0) != 0:
    raise OSError(ctypes.get_errno(), "sysctl KERN_PROCARGS2 failed")
data = buffer.raw[:buffer_size.value]
if len(data) < ctypes.sizeof(ctypes.c_int):
    raise SystemExit("truncated KERN_PROCARGS2 result")
argc = struct.unpack_from("=i", data)[0]
if not 1 <= argc <= 129:
    raise SystemExit("invalid KERN_PROCARGS2 argc")
offset = ctypes.sizeof(ctypes.c_int)
executable_end = data.find(b"\x00", offset)
if executable_end <= offset:
    raise SystemExit("missing KERN_PROCARGS2 executable")
kernel_executable = data[offset:executable_end]
offset = executable_end
while offset < len(data) and data[offset] == 0:
    offset += 1
argv = []
for _ in range(argc):
    argument_end = data.find(b"\x00", offset)
    if argument_end < offset:
        raise SystemExit("truncated KERN_PROCARGS2 argv")
    argv.append(data[offset:argument_end])
    offset = argument_end + 1
if os.path.realpath(os.fsdecode(kernel_executable)) != observed:
    raise SystemExit("kernel process executable does not match the observed executable")
if not argv or os.path.realpath(os.fsdecode(argv[0])) != observed:
    raise SystemExit("kernel argv executable does not match the observed executable")
arguments = argv[1:]
if len(arguments) > 128 or any(b"\x00" in argument or len(argument) > 4096 for argument in arguments):
    raise SystemExit("manual provider argument bounds exceeded")
if sum(map(len, arguments)) > 65536:
    raise SystemExit("manual provider argument bounds exceeded")
environment = []
while offset < len(data):
    entry_end = data.find(b"\x00", offset)
    if entry_end < offset:
        raise SystemExit("truncated KERN_PROCARGS2 environment")
    if entry_end == offset:
        break
    entry = data[offset:entry_end]
    if b"=" not in entry:
        break
    environment.append(entry)
    offset = entry_end + 1
if len(environment) > 512 or any(len(entry) > 8192 for entry in environment) or sum(map(len, environment)) > 262144:
    raise SystemExit("manual provider environment bounds exceeded")
environment_keys = [entry.split(b"=", 1)[0] for entry in environment]
if any(not key or b"=" in key for key in environment_keys) or len(set(environment_keys)) != len(environment_keys):
    raise SystemExit("manual provider environment is invalid")
working_directory = os.path.realpath(observed_cwd)
if not os.path.isabs(working_directory) or not os.path.isdir(working_directory):
    raise SystemExit("manual provider working directory is invalid")
port_bytes = port.encode("ascii")
if not any(
    (argument == b"--port" and index + 1 < len(arguments) and arguments[index + 1] == port_bytes)
    or argument == b"--port=" + port_bytes
    for index, argument in enumerate(arguments)
):
    raise SystemExit("manual provider does not bind the installer target port")
with open(observed, "rb") as handle:
    digest = hashlib.sha256(handle.read()).hexdigest()
record = {
    "version": 3,
    "arguments_b64": [base64.b64encode(argument).decode("ascii") for argument in arguments],
    "environment_b64": [base64.b64encode(entry).decode("ascii") for entry in environment],
    "working_directory_b64": base64.b64encode(os.fsencode(working_directory)).decode("ascii"),
    "binary_sha256": digest,
    "port": int(port),
}
temporary = output + ".tmp"
with open(temporary, "w", encoding="utf-8") as handle:
    json.dump(record, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
    handle.flush()
    os.fsync(handle.fileno())
os.chmod(temporary, 0o600)
os.replace(temporary, output)
directory_fd = os.open(os.path.dirname(output), os.O_RDONLY)
try:
    os.fsync(directory_fd)
finally:
    os.close(directory_fd)
PY
}

pid_is_live_non_zombie() {
  candidate_pid="$1"
  kill -0 "$candidate_pid" >/dev/null 2>&1 || return 1
  candidate_state="$(ps -p "$candidate_pid" -o stat= 2>/dev/null | awk '{print $1}')"
  case "$candidate_state" in
    Z*|'') return 1 ;;
    *) return 0 ;;
  esac
}

stop_owned_manual_provider() {
  candidate_pid="$1"
  expected_executable="$2"
  alternate_executable="${3:-}"
  second_alternate_executable=""
  expected_port="${4:-}"
  if [ "$#" -ge 5 ]; then
    second_alternate_executable="${4:-}"
    expected_port="${5:-}"
  fi
  if [ -n "$expected_port" ]; then
    observed_port_pids="$(lsof -nP -iTCP:"$expected_port" -sTCP:LISTEN -t 2>/dev/null || true)"
    printf '%s\n' "$observed_port_pids" | grep -Fxq "$candidate_pid" || return 1
  fi
  observed_executable="$(lsof -nP -a -p "$candidate_pid" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1)"
  if [ "$observed_executable" != "$expected_executable" ] \
    && { [ -z "$alternate_executable" ] || [ "$observed_executable" != "$alternate_executable" ]; } \
    && { [ -z "$second_alternate_executable" ] || [ "$observed_executable" != "$second_alternate_executable" ]; }; then
    return 1
  fi
  kill -TERM "$candidate_pid" >/dev/null 2>&1 || return 1
  stop_attempt=0
  while [ "$stop_attempt" -lt 20 ] && pid_is_live_non_zombie "$candidate_pid"; do
    sleep 0.1
    stop_attempt=$((stop_attempt + 1))
  done
  if pid_is_live_non_zombie "$candidate_pid"; then
    observed_executable="$(lsof -nP -a -p "$candidate_pid" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1)"
    if [ "$observed_executable" != "$expected_executable" ] \
      && { [ -z "$alternate_executable" ] || [ "$observed_executable" != "$alternate_executable" ]; } \
      && { [ -z "$second_alternate_executable" ] || [ "$observed_executable" != "$second_alternate_executable" ]; }; then
      return 1
    fi
    kill -KILL "$candidate_pid" >/dev/null 2>&1 || return 1
    stop_attempt=0
    while [ "$stop_attempt" -lt 20 ] && pid_is_live_non_zombie "$candidate_pid"; do
      sleep 0.1
      stop_attempt=$((stop_attempt + 1))
    done
  fi
  if ! pid_is_live_non_zombie "$candidate_pid"; then
    wait "$candidate_pid" >/dev/null 2>&1 || true
    return 0
  fi
  return 1
}

begin_install_transaction() {
  [ "$DRY_RUN" -eq 0 ] || return 0
  assert_install_lock_ownership
  validate_transaction_path_kinds
  if [ "${REPAIR_EXISTING_INSTALL:-0}" -eq 1 ]; then
    repair_incumbent_present_for_current_mode \
      || die 28 "trusted existing-install evidence changed before the transaction snapshot"
  fi
  recovery_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  recovery_staging="$CONFIG_DIR/install-recovery-$recovery_id.staging"
  INSTALL_TX_BACKUP="$CONFIG_DIR/install-recovery-$recovery_id"
  mkdir -p "$CONFIG_DIR" || die 70 "could not create config directory for durable install recovery"
  validate_transaction_filesystems \
    || die 70 "provider recovery paths must share the config filesystem for atomic rollback"
  mkdir "$recovery_staging" || die 70 "could not create durable install recovery staging directory: $recovery_staging"
  secure_private_directory "$recovery_staging" \
    || die 70 "could not secure durable install recovery staging directory: $recovery_staging"
  if [ -d "$INSTALL_DIR" ]; then
    stage_install_tx_path "$INSTALL_DIR" "$recovery_staging/install-dir" directory \
      || die 70 "could not stage and verify the previous install directory; current install was not changed (partial recovery data: $recovery_staging)"
    INSTALL_TX_HAD_INSTALL_DIR=1
  fi
  if [ -e "$BINARY_PATH" ] || [ -L "$BINARY_PATH" ]; then
    if [ -L "$BINARY_PATH" ]; then
      INSTALL_TX_BINARY_KIND="symlink"
      stage_install_tx_path "$BINARY_PATH" "$recovery_staging/binary-path" symlink \
        || die 70 "could not stage and verify the previous CLI path; current install was not changed (partial recovery data: $recovery_staging)"
    else
      INSTALL_TX_BINARY_KIND="file"
      stage_install_tx_path "$BINARY_PATH" "$recovery_staging/binary-path" file \
        || die 70 "could not stage and verify the previous CLI path; current install was not changed (partial recovery data: $recovery_staging)"
    fi
    INSTALL_TX_HAD_BINARY_PATH=1
  fi
  if [ -f "$CONFIG_PATH" ]; then
    stage_install_tx_path "$CONFIG_PATH" "$recovery_staging/config.yaml" file \
      || die 70 "could not stage and verify the previous config; current install was not changed (partial recovery data: $recovery_staging)"
    INSTALL_TX_HAD_CONFIG=1
  fi
  if [ -f "$PROVIDER_ID_PATH" ]; then
    stage_install_tx_path "$PROVIDER_ID_PATH" "$recovery_staging/provider_id" file \
      || die 70 "could not stage and verify the previous provider id; current install was not changed (partial recovery data: $recovery_staging)"
    INSTALL_TX_HAD_PROVIDER_ID=1
  fi
  if [ -f "$RECOMMENDATION_PATH" ]; then
    stage_install_tx_path "$RECOMMENDATION_PATH" "$recovery_staging/last-recommendation.json" file \
      || die 70 "could not stage and verify the previous recommendation; current install was not changed (partial recovery data: $recovery_staging)"
    INSTALL_TX_HAD_RECOMMENDATION=1
  fi
  if [ -f "$PLIST_PATH" ]; then
    verify_published_launchd_plist "$PLIST_PATH" "$PLIST_BOOTSTRAP_PATH" \
      || die 70 "managed provider plist does not match the published LaunchDaemon plist; current install was not changed"
    provider_snapshot_alternate=""
    if headless_acceptance_repair_mode; then
      provider_snapshot_alternate="${HEADLESS_REPAIR_INCUMBENT_BINARY:-}"
    fi
    stage_install_tx_plist "$PLIST_PATH" "$recovery_staging/provider.plist" \
      "$PROVIDER_LABEL" "$INSTALL_DIR/macprovider-cli" "$BINARY_PATH" "$provider_snapshot_alternate" "${HEADLESS_USER:-}" \
      || die 70 "could not stage and verify the previous launchd plist; current install was not changed (partial recovery data: $recovery_staging)"
    INSTALL_TX_HAD_PLIST=1
  fi
  if [ -d "$WATCHDOG_DIR" ]; then
    stage_install_tx_path "$WATCHDOG_DIR" "$recovery_staging/watchdog-dir" directory \
      || die 70 "could not stage and verify the previous watchdog directory; current install was not changed (partial recovery data: $recovery_staging)"
    INSTALL_TX_HAD_WATCHDOG_DIR=1
  fi
  if [ -f "$WATCHDOG_PLIST_PATH" ]; then
    verify_published_launchd_plist "$WATCHDOG_PLIST_PATH" "$WATCHDOG_PLIST_BOOTSTRAP_PATH" \
      || die 70 "managed watchdog plist does not match the published LaunchDaemon plist; current install was not changed"
    stage_install_tx_plist "$WATCHDOG_PLIST_PATH" "$recovery_staging/watchdog.plist" \
      "$WATCHDOG_LABEL" "${WATCHDOG_BOOTSTRAP_PATH:-$WATCHDOG_PATH}" "$WATCHDOG_PATH" "$WATCHDOG_DIR/watchdog.sh" "${HEADLESS_USER:-}" \
      || die 70 "could not stage and verify the previous watchdog plist; current install was not changed (partial recovery data: $recovery_staging)"
    INSTALL_TX_HAD_WATCHDOG_PLIST=1
  fi
  if [ -f "$MANIFEST_PATH" ]; then
    stage_install_tx_path "$MANIFEST_PATH" "$recovery_staging/install-manifest.json" file \
      || die 70 "could not stage and verify the previous install manifest; current install was not changed (partial recovery data: $recovery_staging)"
    INSTALL_TX_HAD_MANIFEST=1
  fi
  # The lifecycle-state file is snapshotted under the store's lock with strict
  # symlink/owner/type/nlink/mode/size validation (S-M2). Absence is recorded as
  # had=0 and restored as absence. The writer/pause posture used for restore-time
  # translation and pause reconciliation (A-01) is re-read directly from the
  # snapshot and the live file under the lock at restore time, so no snapshot-time
  # capture is threaded through here.
  lifecycle_snapshot_meta="$recovery_staging/.lifecycle-snapshot-meta"
  stage_lifecycle_snapshot "$LIFECYCLE_STATE_PATH" "$LIFECYCLE_STATE_LOCK_PATH" \
    "$recovery_staging/lifecycle-state-v1.json" "$lifecycle_snapshot_meta" \
    || die 70 "could not safely snapshot the previous lifecycle state; current install was not changed (partial recovery data: $recovery_staging)"
  if grep -qx 'had=1' "$lifecycle_snapshot_meta" 2>/dev/null; then
    INSTALL_TX_HAD_LIFECYCLE_STATE=1
  fi
  rm -f "$lifecycle_snapshot_meta"
  if [ "$INSTALL_TX_HAD_INSTALL_DIR" -eq 1 ] || [ "$INSTALL_TX_HAD_BINARY_PATH" -eq 1 ] || [ "$INSTALL_TX_HAD_MANIFEST" -eq 1 ]; then
    EXISTING_INSTALL_WAS_PRESENT=1
  fi
  if launchctl_service print "$LAUNCHD_DOMAIN/$PROVIDER_LABEL" >/dev/null 2>&1; then
    INSTALL_TX_SERVICE_WAS_ACTIVE=1
  fi
  if launchctl_service print "$LAUNCHD_DOMAIN/$LEGACY_PROVIDER_LABEL" >/dev/null 2>&1; then
    INSTALL_TX_LEGACY_SERVICE_WAS_ACTIVE=1
  fi
  if [ "$INSTALL_TX_LEGACY_SERVICE_WAS_ACTIVE" -eq 1 ]; then
    [ -f "$LEGACY_PLIST_PATH" ] \
      || {
        rm -rf -- "$recovery_staging" \
          || die 70 "loaded legacy provider has no recoverable launchd plist and partial recovery data could not be removed"
        die 70 "loaded legacy provider has no recoverable launchd plist; current install was not changed"
      }
    verify_published_launchd_plist "$LEGACY_PLIST_PATH" "$LEGACY_PLIST_BOOTSTRAP_PATH" \
      || die 70 "managed legacy provider plist does not match the published LaunchDaemon plist; current install was not changed"
    stage_install_tx_plist "$LEGACY_PLIST_PATH" "$recovery_staging/legacy-provider.plist" \
      "$LEGACY_PROVIDER_LABEL" "$INSTALL_DIR/macprovider-cli" "$BINARY_PATH" "${HEADLESS_USER:-}" \
      || die 70 "could not stage and verify the previous legacy launchd plist; current install was not changed (partial recovery data: $recovery_staging)"
    INSTALL_TX_HAD_LEGACY_PLIST=1
  fi
  if launchd_label_is_disabled "$PROVIDER_LABEL"; then
    INSTALL_TX_SERVICE_WAS_DISABLED=1
  fi
  if launchctl_service print "$LAUNCHD_DOMAIN/$WATCHDOG_LABEL" >/dev/null 2>&1; then
    INSTALL_TX_WATCHDOG_WAS_ACTIVE=1
  fi
  if launchctl_service print "$LAUNCHD_DOMAIN/$LEGACY_WATCHDOG_LABEL" >/dev/null 2>&1; then
    INSTALL_TX_LEGACY_WATCHDOG_WAS_ACTIVE=1
  fi
  if [ "$INSTALL_TX_LEGACY_WATCHDOG_WAS_ACTIVE" -eq 1 ]; then
    [ -f "$LEGACY_WATCHDOG_PLIST_PATH" ] \
      || {
        rm -rf -- "$recovery_staging" \
          || die 70 "loaded legacy watchdog has no recoverable launchd plist and partial recovery data could not be removed"
        die 70 "loaded legacy watchdog has no recoverable launchd plist; current install was not changed"
      }
    verify_published_launchd_plist "$LEGACY_WATCHDOG_PLIST_PATH" "$LEGACY_WATCHDOG_PLIST_BOOTSTRAP_PATH" \
      || die 70 "managed legacy watchdog plist does not match the published LaunchDaemon plist; current install was not changed"
    stage_install_tx_plist "$LEGACY_WATCHDOG_PLIST_PATH" "$recovery_staging/legacy-watchdog.plist" \
      "$LEGACY_WATCHDOG_LABEL" "${WATCHDOG_BOOTSTRAP_PATH:-$WATCHDOG_PATH}" "$WATCHDOG_PATH" "$WATCHDOG_DIR/watchdog.sh" "${HEADLESS_USER:-}" \
      || die 70 "could not stage and verify the previous legacy watchdog plist; current install was not changed (partial recovery data: $recovery_staging)"
    INSTALL_TX_HAD_LEGACY_WATCHDOG_PLIST=1
  fi
  if launchd_label_is_disabled "$WATCHDOG_LABEL"; then
    INSTALL_TX_WATCHDOG_WAS_DISABLED=1
  fi
  # A loaded service without an owner-safe plist snapshot cannot be reclaimed
  # before cutover or restored after rollback. Abort before publishing or
  # arming durable recovery rather than entering an unrecoverable transaction.
  if [ "$INSTALL_TX_SERVICE_WAS_ACTIVE" -eq 1 ] && [ "$INSTALL_TX_HAD_PLIST" -ne 1 ]; then
    rm -rf -- "$recovery_staging" \
      || die 70 "loaded provider has no recoverable launchd plist and partial recovery data could not be removed"
    die 70 "loaded provider has no recoverable launchd plist; current install was not changed"
  fi
  if [ "$INSTALL_TX_LEGACY_SERVICE_WAS_ACTIVE" -eq 1 ] && [ "$INSTALL_TX_HAD_LEGACY_PLIST" -ne 1 ]; then
    rm -rf -- "$recovery_staging" \
      || die 70 "loaded legacy provider has no recoverable launchd plist and partial recovery data could not be removed"
    die 70 "loaded legacy provider has no recoverable launchd plist; current install was not changed"
  fi
  if [ "$INSTALL_TX_WATCHDOG_WAS_ACTIVE" -eq 1 ] && [ "$INSTALL_TX_HAD_WATCHDOG_PLIST" -ne 1 ]; then
    rm -rf -- "$recovery_staging" \
      || die 70 "loaded watchdog has no recoverable launchd plist and partial recovery data could not be removed"
    die 70 "loaded watchdog has no recoverable launchd plist; current install was not changed"
  fi
  if [ "$INSTALL_TX_LEGACY_WATCHDOG_WAS_ACTIVE" -eq 1 ] && [ "$INSTALL_TX_HAD_LEGACY_WATCHDOG_PLIST" -ne 1 ]; then
    rm -rf -- "$recovery_staging" \
      || die 70 "loaded legacy watchdog has no recoverable launchd plist and partial recovery data could not be removed"
    die 70 "loaded legacy watchdog has no recoverable launchd plist; current install was not changed"
  fi
  write_install_recovery_artifacts "$recovery_staging" \
    || die 70 "could not create verified recovery instructions; current install was not changed (partial recovery data: $recovery_staging)"
  if ! mv "$recovery_staging" "$INSTALL_TX_BACKUP" \
    || ! fsync_directory_path "$CONFIG_DIR"; then
    if [ -d "$INSTALL_TX_BACKUP" ] && mv "$INSTALL_TX_BACKUP" "$recovery_staging"; then
      fsync_directory_path "$CONFIG_DIR" || true
    fi
    die 70 "could not publish durable recovery data; current install was not changed (partial recovery data: $recovery_staging)"
  fi
  INSTALL_TX_ACTIVE=1
  assert_install_lock_ownership
  arm_install_recovery_agent \
    || die 70 "could not arm independent interrupted-install recovery before live mutation"
  if [ "$INSTALL_TX_WATCHDOG_WAS_ACTIVE" -eq 1 ]; then
    if [ "${REPAIR_EXISTING_INSTALL:-0}" -eq 1 ]; then
      quiesce_repair_watchdog_label_for_transaction \
        "$WATCHDOG_LABEL" "$WATCHDOG_PLIST_BOOTSTRAP_PATH" "${WATCHDOG_BOOTSTRAP_PATH:-$WATCHDOG_PATH}" "$WATCHDOG_DIR/watchdog.sh" \
        || die 70 "could not safely stop the existing watchdog for repair"
    else
      reclaim_launchd_service "$WATCHDOG_LABEL" \
        || die 70 "could not suspend the existing watchdog for the protected install transaction"
    fi
  fi
  if [ "$INSTALL_TX_LEGACY_WATCHDOG_WAS_ACTIVE" -eq 1 ]; then
    if [ "${REPAIR_EXISTING_INSTALL:-0}" -eq 1 ]; then
      quiesce_repair_watchdog_label_for_transaction \
        "$LEGACY_WATCHDOG_LABEL" "$LEGACY_WATCHDOG_PLIST_BOOTSTRAP_PATH" "${WATCHDOG_BOOTSTRAP_PATH:-$WATCHDOG_PATH}" "$WATCHDOG_DIR/watchdog.sh" \
        || die 70 "could not safely stop the existing legacy watchdog for repair"
    else
      reclaim_legacy_launchd_service "$LEGACY_WATCHDOG_LABEL" "$LEGACY_WATCHDOG_PLIST_BOOTSTRAP_PATH" "$WATCHDOG_PATH" "$WATCHDOG_DIR/watchdog.sh" \
        || die 70 "could not suspend the existing legacy watchdog for the protected install transaction"
    fi
  fi
}

mark_install_cutover_started() {
  [ "$CUTOVER_STARTED" -eq 0 ] || return 0
  [ "$INSTALL_TX_ACTIVE" -eq 1 ] && [ -n "$INSTALL_TX_BACKUP" ] \
    || die 70 "install cutover cannot start without durable recovery"
  assert_install_lock_ownership
  write_install_tx_marker "$INSTALL_TX_BACKUP/cutover-started" "cutover-started" \
    || die 70 "could not durably mark install cutover before live provider mutation"
  CUTOVER_STARTED=1
}

write_install_tx_marker() {
  marker_path="$1"
  marker_payload="${2:-transaction-created}"
  python3 - "$marker_path" "$marker_payload" <<'PY'
import ctypes
import errno
import os
import stat
import sys

path, payload_text = sys.argv[1:]
parent_path = os.path.dirname(path)
marker_name = os.path.basename(path)
directory_fd = os.open(
    parent_path,
    os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0),
)
directory_info = os.fstat(directory_fd)
if (
    not stat.S_ISDIR(directory_info.st_mode)
    or directory_info.st_uid != os.getuid()
    or directory_info.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
):
    os.close(directory_fd)
    raise RuntimeError("unsafe install transaction marker parent")
if sys.platform == "darwin":
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        acl_get_fd_np = libc.acl_get_fd_np
        acl_get_fd_np.argtypes = [ctypes.c_int, ctypes.c_int]
        acl_get_fd_np.restype = ctypes.c_void_p
        acl_free = libc.acl_free
        acl_free.argtypes = [ctypes.c_void_p]
        acl_free.restype = ctypes.c_int
    except (AttributeError, OSError):
        os.close(directory_fd)
        raise RuntimeError("install transaction marker ACL API is unavailable")
    ctypes.set_errno(0)
    acl = acl_get_fd_np(directory_fd, 0x00000100)  # ACL_TYPE_EXTENDED
    if acl:
        acl_free(acl)
        os.close(directory_fd)
        raise RuntimeError("install transaction marker parent has an extended ACL")
    if ctypes.get_errno() != errno.ENOENT:
        os.close(directory_fd)
        raise RuntimeError("install transaction marker parent ACL verification failed")

flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
fd = os.open(marker_name, flags, 0o600, dir_fd=directory_fd)
try:
    info = os.fstat(fd)
    if (
        not stat.S_ISREG(info.st_mode)
        or info.st_uid != os.getuid()
        or info.st_nlink != 1
        or info.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
    ):
        raise RuntimeError("unsafe install transaction marker")
    payload = (payload_text + "\n").encode("utf-8")
    written = 0
    while written < len(payload):
        progress = os.write(fd, payload[written:])
        if progress <= 0:
            raise RuntimeError("install transaction marker write made no progress")
        written += progress
    os.fsync(fd)
finally:
    os.close(fd)
try:
    os.fsync(directory_fd)
finally:
    os.close(directory_fd)
PY
}

discard_install_transaction_before_cutover() {
  [ "$CUTOVER_STARTED" -eq 0 ] || return 1
  log "Discarding staged install files without stopping or replacing the active provider."
  verify_headless_recovery_trust "$INSTALL_TX_BACKUP" \
    || die 70 "headless pre-cutover recovery did not match its root-owned trust receipt"
  if ! bash "$INSTALL_TX_BACKUP/recover.sh"; then
    log "ERROR: pre-cutover cleanup failed; recovery data was preserved at $INSTALL_TX_BACKUP"
    return 70
  fi
  if ! disarm_install_recovery_agent; then
    log "ERROR: pre-cutover cleanup succeeded but the interrupted-install recovery agent could not be disarmed"
    return 70
  fi
  if ! rm -rf "$INSTALL_TX_BACKUP"; then
    log "ERROR: pre-cutover cleanup succeeded but recovery data could not be retired: $INSTALL_TX_BACKUP"
    return 70
  fi
  if ! fsync_directory_path "$CONFIG_DIR"; then
    log "ERROR: pre-cutover cleanup succeeded but recovery retirement was not durable: $INSTALL_TX_BACKUP"
    return 70
  fi
  INSTALL_TX_ACTIVE=0
  log "The incumbent provider was never stopped; only staged update files were discarded."
}

rollback_install_transaction() {
  if [ "$INSTALL_TX_ROLLING_BACK" -eq 1 ]; then
    return 70
  fi
  INSTALL_TX_ROLLING_BACK=1
  record_lifecycle_state rollback_in_progress install_admission_failed \
    || log "WARNING: could not persist rollback lifecycle state before restoring the previous install"
  log "Install did not pass admission; restoring the previous provider installation."
  if [ -n "$MANUAL_PID" ] && pid_is_live_non_zombie "$MANUAL_PID"; then
    if ! stop_owned_manual_provider "$MANUAL_PID" "$INSTALL_DIR/macprovider-cli"; then
      log "ERROR: could not stop and prove death of the failed manual provider process; recovery data was preserved at $INSTALL_TX_BACKUP"
      INSTALL_TX_ROLLING_BACK=0
      return 70
    fi
  fi
  verify_headless_recovery_trust "$INSTALL_TX_BACKUP" \
    || die 70 "headless rollback recovery did not match its root-owned trust receipt"
  if ! bash "$INSTALL_TX_BACKUP/recover.sh"; then
    log "ERROR: automatic rollback failed; recovery data was preserved at $INSTALL_TX_BACKUP"
    log "Run exactly: bash '$INSTALL_TX_BACKUP/recover.sh'"
    INSTALL_TX_ROLLING_BACK=0
    return 70
  fi
  if ! disarm_install_recovery_agent; then
    log "ERROR: rollback succeeded but the interrupted-install recovery agent could not be disarmed"
    INSTALL_TX_ROLLING_BACK=0
    return 70
  fi
  if ! rm -rf "$INSTALL_TX_BACKUP"; then
    log "ERROR: rollback succeeded but verified recovery data could not be removed: $INSTALL_TX_BACKUP"
    log "Run exactly if recovery is needed again: bash '$INSTALL_TX_BACKUP/recover.sh'"
    INSTALL_TX_ROLLING_BACK=0
    return 70
  fi
  if ! fsync_directory_path "$CONFIG_DIR"; then
    log "ERROR: rollback succeeded but recovery retirement was not durable: $INSTALL_TX_BACKUP"
    INSTALL_TX_ROLLING_BACK=0
    return 70
  fi
  log "Previous provider files and service state were restored and verified."
  INSTALL_TX_ACTIVE=0
  INSTALL_TX_ROLLING_BACK=0
}

commit_install_transaction() {
  assert_install_lock_ownership
  if [ -n "$INSTALL_TX_BACKUP" ] && [ -d "$INSTALL_TX_BACKUP" ]; then
    retired_recovery="${INSTALL_TX_BACKUP}.committed.$$"
    mv "$INSTALL_TX_BACKUP" "$retired_recovery" \
      || die 70 "new install passed admission but durable recovery data could not be retired: $INSTALL_TX_BACKUP"
    fsync_directory_path "$CONFIG_DIR" \
      || die 70 "new install passed admission but recovery retirement was not durable: $retired_recovery"
    # Crossing this rename is the no-rollback boundary. From here onward the
    # recovery bundle cannot be mistaken for an active transaction even if
    # best-effort cleanup fails partway through.
    INSTALL_TX_COMMITTED=1
    INSTALL_TX_ACTIVE=0
    disarm_install_recovery_agent \
      || die 70 "new install committed but interrupted-install recovery could not be disarmed"
    if [ "${REFERRAL_REPLACE_INCUMBENT:-0}" = "1" ] && ! retire_replacement_candidate_provider_id; then
      log "WARNING: install committed but replacement candidate retry marker could not be removed: $REPLACEMENT_CANDIDATE_DIR"
    fi
    if ! rm -rf "$retired_recovery"; then
      log "WARNING: install committed but retired recovery data could not be removed: $retired_recovery"
    elif ! fsync_directory_path "$CONFIG_DIR"; then
      log "WARNING: install committed but recovery retirement was not durable: $retired_recovery"
    fi
    return 0
  fi
  INSTALL_TX_COMMITTED=1
  INSTALL_TX_ACTIVE=0
  if [ "${REFERRAL_REPLACE_INCUMBENT:-0}" = "1" ] && ! retire_replacement_candidate_provider_id; then
    log "WARNING: install committed but replacement candidate retry marker could not be removed: $REPLACEMENT_CANDIDATE_DIR"
  fi
}

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf "[dry-run] "
    printf "%q " "$@"
    printf "\n"
  else
    "$@"
  fi
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die 2 "missing required tool: $1"
}

# The installer relies on python3 in dozens of places. On a stock, non-developer
# Mac `command -v python3` still succeeds because /usr/bin/python3 exists as an
# Xcode Command Line Tools *stub*. Invoking that stub triggers the OS
# "Install Command Line Developer Tools" dialog, which appears BEHIND the Malibu
# window and blocks the installer indefinitely (looks like a hang at
# "Starting installer"). Detect the non-functional stub WITHOUT invoking it
# (xcode-select -p does not trigger the install prompt), kick off the CLT
# installer for the user (consumer/GUI only), and exit fast with a dedicated,
# actionable code the app surfaces as a clear message. (#1285)
# Bounded "does this python3 actually run?" probe. Executes a trivial program
# with a hard time budget so a BROKEN or BLOCKING interpreter (e.g. a hung shim
# earlier in PATH, or a python3 with a missing dylib) fails fast with die 8
# instead of hanging the whole install at the first real python3 call. macOS has
# no GNU `timeout`, so enforce the budget with a background job + kill.
#
# CRITICAL: probe with the SAME stdin-script style the installer actually uses
# (`python3 - ...` fed a heredoc, e.g. validate_install_dir at the first real
# call), NOT `python3 -c`. A shim can exit 0 for `-c` yet block reading stdin on
# `python3 -`, which would let the probe pass and the installer still hang. (#1286)
# Returns 0 only if python3 exits 0 within the budget; non-zero on failure/crash;
# 124 on timeout.
_python3_runs_quickly() {
  local py="$1" budget waited=0 pid
  # Validate/clamp the (normally-unset) budget override so a bogus or huge value
  # can't defeat the "fast" guarantee.
  budget="${MACPROVIDER_PY_PROBE_BUDGET:-8}"
  case "$budget" in ''|*[!0-9]*) budget=8 ;; esac
  [ "$budget" -ge 1 ] 2>/dev/null || budget=8
  [ "$budget" -le 60 ] 2>/dev/null || budget=60
  "$py" - >/dev/null 2>&1 <<'PYEOF' &
import sys
sys.exit(0)
PYEOF
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    sleep 1
    waited=$((waited + 1))
    [ "$waited" -lt "$budget" ] && continue
    # Reap the interpreter AND any children it spawned (e.g. a shim's `sleep`),
    # so a wedged probe leaves nothing behind.
    pkill -P "$pid" 2>/dev/null || true
    kill -TERM "$pid" 2>/dev/null || true
    sleep 1
    pkill -KILL -P "$pid" 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    return 124
  done
  wait "$pid"
}

# Confirm one python3 path is present AND genuinely usable, or die 8. For the CLT
# stub at /usr/bin/python3 we must NOT execute it blindly (that pops the hidden
# "Install Command Line Developer Tools" dialog and hangs), so we first prove the
# selected developer directory actually contains a real python3; only then is it
# safe to probe. Any other python3 is a real interpreter path we probe directly —
# presence via `command -v` is not enough, since a broken/blocking python3 would
# otherwise sail through and hang the next real call. (#1285/#1286)
_python3_usable_or_die() {
  local py="$1" ctx="$2" devdir
  [ -n "$py" ] || die 8 "This Mac is missing python3, which provider setup requires ($ctx). Install Apple's Command Line Developer Tools (xcode-select --install) or a working python3, then try again."
  if [ "$py" = "/usr/bin/python3" ]; then
    # `xcode-select -p` only prints the selected path (no install prompt) and can
    # be stale/removed, so require the resolved tool to actually exist+execute
    # before we dare run /usr/bin/python3.
    devdir="$(xcode-select -p 2>/dev/null || true)"
    if [ -z "$devdir" ] || [ ! -x "$devdir/usr/bin/python3" ]; then
      if [ "${HEADLESS:-0}" != "1" ]; then
        # Best-effort: open the GUI Command Line Tools installer for the user.
        xcode-select --install >/dev/null 2>&1 || true
        die 8 "This Mac needs Apple's Command Line Developer Tools to finish provider setup (they include python3). A system installer has been opened — click Install, wait for it to finish, then reopen Malibu."
      fi
      die 8 "This Mac is missing Apple's Command Line Developer Tools, which provider setup requires (they include python3). Install them with: xcode-select --install, then re-run the installer."
    fi
    # CLT is selected and backed by a real python3 -> /usr/bin/python3 delegates
    # to it and is safe to probe below.
  fi
  _python3_runs_quickly "$py" \
    || die 8 "This Mac's python3 ($py) is present but did not run correctly ($ctx) — it may be broken or a stub. Install Apple's Command Line Developer Tools (xcode-select --install) or a working python3, then try again."
}

ensure_python3_usable() {
  # (1) The interpreter that user-context python3 calls resolve to (the first is
  # validate_install_dir, immediately after this guard).
  _python3_usable_or_die "$(command -v python3 2>/dev/null || true)" "user interpreter"
  # (2) In headless mode, privileged root helpers ALWAYS run ROOT_PYTHON3_BIN
  # (/usr/bin/python3) under sudo. When the resolved user interpreter is a
  # different python3 (e.g. Homebrew), the check above does NOT prove the system
  # interpreter is usable, so validate it independently. (#1286 MEDIUM)
  if [ "${HEADLESS:-0}" = "1" ] \
     && [ "$(command -v python3 2>/dev/null || true)" != "${ROOT_PYTHON3_BIN:-/usr/bin/python3}" ]; then
    _python3_usable_or_die "${ROOT_PYTHON3_BIN:-/usr/bin/python3}" "system root interpreter"
  fi
}

read_line() {
  REPLY=""
  # In curl-pipe-bash invocations, /dev/tty often exists as a character
  # device but `read < /dev/tty` fails with "Device not configured" and
  # prints noise to stderr. Suppress that noise + fall through to empty
  # REPLY (callers use defaults via $NO_PROMPT or prompt_yes_no's default
  # arg). v1.2.1 install.sh's `[ -r /dev/tty ]` check passed when the
  # device existed but the read still failed; v1.2.2 silences the
  # failure path.
  # Try to open /dev/tty via fd 4; the { exec ...; } 2>/dev/null pattern
  # is necessary because bash's input-redirection failure on `< /dev/tty`
  # prints to stderr BEFORE the `2>/dev/null` on the read line takes
  # effect. By opening explicitly here and silencing stderr on the exec,
  # we cleanly detect "is /dev/tty actually usable" without noise.
  if [ -c /dev/tty ] && { exec 4</dev/tty; } 2>/dev/null; then
    IFS= read -r REPLY <&4 2>/dev/null || REPLY=""
    exec 4<&-
  else
    IFS= read -r REPLY 2>/dev/null || REPLY=""
  fi
}

restart_safe_incumbent_present() {
  installed_binary="$(installed_provider_binary_path)"
  [ -n "$installed_binary" ] || return 1
  existing_provider_id="$(read_config_provider_id || true)"
  [ -n "$existing_provider_id" ] || return 1

  if [ -n "$(read_config_provider_token_line || true)" ]; then
    return 0
  fi
  if "$installed_binary" credentials verify --config "$CONFIG_PATH" >/dev/null 2>&1; then
    return 0
  fi
  [ -f "$MANIFEST_PATH" ] && [ -f "$PLIST_PATH" ]
}

# Malibu may request repair after the provider executable was removed while
# the owner-private config, provider identity, manifest, and LaunchAgent plist
# survived. This bypasses only referral admission; the evidence itself is
# revalidated descriptor-first and must identify this install's provider label
# and executable paths. The later transaction snapshots the same files again
# before any live mutation.
repair_safe_incumbent_present() {
  python3 - \
    "$CONFIG_PATH" \
    "$PROVIDER_ID_PATH" \
    "$MANIFEST_PATH" \
    "$PLIST_PATH" \
    "$INSTALL_DIR" \
    "$BINARY_PATH" \
    "$PROVIDER_LABEL" <<'PY' 2>/dev/null
import ctypes
import errno
import json
import os
import plistlib
import re
import stat
import sys
import grp

config_path, provider_id_path, manifest_path, plist_path, install_dir, binary_path, label = sys.argv[1:]
uid = os.getuid()
nofollow = getattr(os, "O_NOFOLLOW", 0)
nonblock = getattr(os, "O_NONBLOCK", 0)
max_bytes = 1024 * 1024


def no_acl(fd):
    if sys.platform != "darwin":
        return True
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        acl_get_fd_np = libc.acl_get_fd_np
        acl_get_fd_np.argtypes = [ctypes.c_int, ctypes.c_int]
        acl_get_fd_np.restype = ctypes.c_void_p
        acl_free = libc.acl_free
        acl_free.argtypes = [ctypes.c_void_p]
        acl_free.restype = ctypes.c_int
    except (AttributeError, OSError):
        return False
    ctypes.set_errno(0)
    acl = acl_get_fd_np(fd, 0x00000100)  # ACL_TYPE_EXTENDED
    if acl:
        acl_free(acl)
        return False
    return ctypes.get_errno() in (0, errno.ENOENT)


def safe_directory_acl(fd):
    if sys.platform != "darwin":
        return True
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        acl_get_fd_np = libc.acl_get_fd_np
        acl_get_fd_np.argtypes = [ctypes.c_int, ctypes.c_int]
        acl_get_fd_np.restype = ctypes.c_void_p
        acl_to_text = libc.acl_to_text
        acl_to_text.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_long)]
        acl_to_text.restype = ctypes.c_void_p
        acl_free = libc.acl_free
        acl_free.argtypes = [ctypes.c_void_p]
        acl_free.restype = ctypes.c_int
    except (AttributeError, OSError):
        return False
    ctypes.set_errno(0)
    acl = acl_get_fd_np(fd, 0x00000100)
    if not acl:
        return ctypes.get_errno() in (0, errno.ENOENT)
    try:
        text_length = ctypes.c_long()
        text_pointer = acl_to_text(acl, ctypes.byref(text_length))
        if not text_pointer:
            return False
        try:
            lines = ctypes.string_at(text_pointer, text_length.value).decode(
                "utf-8", errors="strict"
            ).splitlines()
        finally:
            acl_free(text_pointer)
        everyone_gid = grp.getgrnam("everyone").gr_gid
        if len(lines) < 2 or lines[0] != "!#acl 1":
            return False
        uuid_pattern = re.compile(
            r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-"
            r"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
        )
        return all(
            (fields := line.split(":"))
            and len(fields) == 6
            and fields[0] == "group"
            and bool(uuid_pattern.fullmatch(fields[1]))
            and fields[2] == "everyone"
            and fields[3] == str(everyone_gid)
            and fields[4] == "deny"
            and fields[5] == "delete"
            for line in lines[1:]
        )
    finally:
        acl_free(acl)


def safe_parent_chain(path):
    home = os.path.normpath(os.path.expanduser("~"))
    parent = os.path.normpath(os.path.dirname(path))
    try:
        if os.path.commonpath([home, parent]) != home:
            return False
    except ValueError:
        return False
    # $HOME itself may carry a write-style ACL (stranded autoupdate). Confirm
    # owner/mode/no-follow, but do not apply the descendant ACL predicate.
    home_fd = os.open(
        home,
        os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | nofollow,
    )
    try:
        home_info = os.fstat(home_fd)
        if (
            not stat.S_ISDIR(home_info.st_mode)
            or home_info.st_uid != uid
            or home_info.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
        ):
            return False
    finally:
        os.close(home_fd)
    current = home
    relative = os.path.relpath(parent, home)
    components = [] if relative == "." else relative.split(os.sep)
    for component in components:
        current = os.path.join(current, component)
        directory_fd = os.open(
            current,
            os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | nofollow,
        )
        try:
            info = os.fstat(directory_fd)
            if (
                not stat.S_ISDIR(info.st_mode)
                or info.st_uid != uid
                or info.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
                or not safe_directory_acl(directory_fd)
            ):
                return False
        finally:
            os.close(directory_fd)
    return True


def read_owned(path):
    if not safe_parent_chain(path):
        raise RuntimeError("unsafe repair evidence parent chain")
    fd = os.open(path, os.O_RDONLY | nonblock | nofollow)
    try:
        before = os.fstat(fd)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_uid != uid
            or before.st_nlink != 1
            or stat.S_IMODE(before.st_mode) & (stat.S_IWGRP | stat.S_IWOTH)
            or before.st_size < 0
            or before.st_size > max_bytes
            or not no_acl(fd)
        ):
            raise RuntimeError("unsafe repair evidence")
        payload = bytearray()
        while len(payload) < before.st_size:
            chunk = os.read(fd, min(65536, before.st_size - len(payload)))
            if not chunk:
                raise RuntimeError("repair evidence truncated")
            payload.extend(chunk)
        after = os.fstat(fd)
        path_info = os.lstat(path)
        if (
            (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns)
            != (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns)
            or stat.S_ISLNK(path_info.st_mode)
            or (path_info.st_dev, path_info.st_ino) != (before.st_dev, before.st_ino)
        ):
            raise RuntimeError("repair evidence changed during read")
        return bytes(payload)
    finally:
        os.close(fd)


config = read_owned(config_path).decode("utf-8")
provider_id = read_owned(provider_id_path).decode("utf-8").strip()
config_ids = []
for line in config.splitlines():
    match = re.match(r'^provider_id:\s*"?([^"\s]+)"?\s*$', line)
    if match:
        config_ids.append(match.group(1))
if config_ids != [provider_id]:
    raise SystemExit(1)

manifest = json.loads(read_owned(manifest_path).decode("utf-8"))
labels = manifest.get("launchd_labels") if isinstance(manifest, dict) else None
plists = manifest.get("launchd_plists") if isinstance(manifest, dict) else None
if (
    not isinstance(manifest, dict)
    or manifest.get("install_prefix") != install_dir
    or manifest.get("binary_path") != os.path.join(install_dir, "macprovider-cli")
    or not isinstance(labels, list)
    or not all(isinstance(value, str) for value in labels)
    or (labels and label not in labels)
    or not isinstance(plists, list)
    or not all(isinstance(value, str) for value in plists)
    or plist_path not in plists
):
    raise SystemExit(1)

# #1289: a legitimate install can lose its LaunchAgent plist (and leave its
# manifest launchd_labels empty) when a prior install stalled before the
# launchd layer was written. That is a degraded-but-recoverable incumbent, not
# a non-incumbent attempting a referral bypass: ownership is still proven by
# the owner-private config (provider_id matches), the provider_id file, the
# installed binary, and the manifest (install_prefix / binary_path, and the
# expected plist path listed in launchd_plists). The repair transaction
# re-creates the plist, so validate its contents only when the file is present;
# a genuinely-absent plist is acceptable and left for repair to rebuild.
try:
    plist_raw = read_owned(plist_path)
except FileNotFoundError:
    plist_raw = None
if plist_raw is not None:
    plist = plistlib.loads(plist_raw)
    if not isinstance(plist, dict) or plist.get("Label") != label:
        raise SystemExit(1)
    program = plist.get("Program")
    arguments = plist.get("ProgramArguments")
    if program is None:
        if not isinstance(arguments, list) or not arguments:
            raise SystemExit(1)
        program = arguments[0]
    if program not in (os.path.join(install_dir, "macprovider-cli"), binary_path):
        raise SystemExit(1)
PY
}

headless_acceptance_repair_mode() {
  [ "${REPAIR_EXISTING_INSTALL:-0}" -eq 1 ] || return 1
  [ "${HEADLESS:-0}" = "1" ] || return 1
  [ "${LAUNCHD_DOMAIN:-}" = "system" ] || return 1
  [ -n "${MACPROVIDER_ACCEPTANCE_ASSET_DIR:-}" ] || return 1
  [ -z "${BUNDLED_APP:-}" ] || return 1
}

provider_executable_owned_for_current_mode() {
  local candidate="$1"
  [ "$candidate" = "$INSTALL_DIR/macprovider-cli" ] && return 0
  [ -n "${BINARY_PATH:-}" ] && [ "$candidate" = "$BINARY_PATH" ] && return 0
  if headless_acceptance_repair_mode \
    && [ -n "${HEADLESS_REPAIR_INCUMBENT_BINARY:-}" ] \
    && [ "$candidate" = "$HEADLESS_REPAIR_INCUMBENT_BINARY" ]; then
    return 0
  fi
  return 1
}

headless_acceptance_repair_safe_incumbent_present() {
  local incumbent_binary
  local incumbent_evidence
  local incumbent_sha256
  headless_acceptance_repair_mode || return 1
  [ -f "$PLIST_PATH" ] || return 1
  [ -f "$PLIST_BOOTSTRAP_PATH" ] || return 1
  verify_published_launchd_plist "$PLIST_PATH" "$PLIST_BOOTSTRAP_PATH" || return 1
  launchctl_service print "$LAUNCHD_DOMAIN/$PROVIDER_LABEL" >/dev/null 2>&1 || return 1
  incumbent_evidence="$(python3 - \
    "$CONFIG_PATH" \
    "$PROVIDER_ID_PATH" \
    "$PLIST_PATH" \
    "$HEADLESS_USER" \
    "$PROVIDER_LABEL" \
    "$CONFIG_DIR" <<'PY' 2>/dev/null
import ctypes
import errno
import grp
import hashlib
import os
import plistlib
import re
import stat
import sys

config_path, provider_id_path, plist_path, headless_user, label, config_dir = sys.argv[1:]
uid = os.getuid()
nofollow = getattr(os, "O_NOFOLLOW", 0)
nonblock = getattr(os, "O_NONBLOCK", 0)
max_bytes = 1024 * 1024


def no_acl(fd):
    if sys.platform != "darwin":
        return True
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        acl_get_fd_np = libc.acl_get_fd_np
        acl_get_fd_np.argtypes = [ctypes.c_int, ctypes.c_int]
        acl_get_fd_np.restype = ctypes.c_void_p
        acl_free = libc.acl_free
        acl_free.argtypes = [ctypes.c_void_p]
        acl_free.restype = ctypes.c_int
    except (AttributeError, OSError):
        return False
    ctypes.set_errno(0)
    acl = acl_get_fd_np(fd, 0x00000100)
    if acl:
        acl_free(acl)
        return False
    return ctypes.get_errno() in (0, errno.ENOENT)


def safe_directory_acl(fd):
    if sys.platform != "darwin":
        return True
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        acl_get_fd_np = libc.acl_get_fd_np
        acl_get_fd_np.argtypes = [ctypes.c_int, ctypes.c_int]
        acl_get_fd_np.restype = ctypes.c_void_p
        acl_to_text = libc.acl_to_text
        acl_to_text.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_long)]
        acl_to_text.restype = ctypes.c_void_p
        acl_free = libc.acl_free
        acl_free.argtypes = [ctypes.c_void_p]
        acl_free.restype = ctypes.c_int
    except (AttributeError, OSError):
        return False
    ctypes.set_errno(0)
    acl = acl_get_fd_np(fd, 0x00000100)
    if not acl:
        return ctypes.get_errno() in (0, errno.ENOENT)
    try:
        text_length = ctypes.c_long()
        text_pointer = acl_to_text(acl, ctypes.byref(text_length))
        if not text_pointer:
            return False
        try:
            lines = ctypes.string_at(text_pointer, text_length.value).decode(
                "utf-8", errors="strict"
            ).splitlines()
        finally:
            acl_free(text_pointer)
        everyone_gid = grp.getgrnam("everyone").gr_gid
        if len(lines) < 2 or lines[0] != "!#acl 1":
            return False
        uuid_pattern = re.compile(
            r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-"
            r"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
        )
        return all(
            (fields := line.split(":"))
            and len(fields) == 6
            and fields[0] == "group"
            and bool(uuid_pattern.fullmatch(fields[1]))
            and fields[2] == "everyone"
            and fields[3] == str(everyone_gid)
            and fields[4] == "deny"
            and fields[5] == "delete"
            for line in lines[1:]
        )
    finally:
        acl_free(acl)


def safe_parent_chain(path):
    home = os.path.normpath(os.path.expanduser("~"))
    parent = os.path.normpath(os.path.dirname(path))
    try:
        if os.path.commonpath([home, parent]) != home:
            return False
    except ValueError:
        return False
    home_fd = os.open(
        home,
        os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | nofollow,
    )
    try:
        home_info = os.fstat(home_fd)
        if (
            not stat.S_ISDIR(home_info.st_mode)
            or home_info.st_uid != uid
            or home_info.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
        ):
            return False
    finally:
        os.close(home_fd)
    current = home
    relative = os.path.relpath(parent, home)
    components = [] if relative == "." else relative.split(os.sep)
    for component in components:
        current = os.path.join(current, component)
        directory_fd = os.open(
            current,
            os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | nofollow,
        )
        try:
            info = os.fstat(directory_fd)
            if (
                not stat.S_ISDIR(info.st_mode)
                or info.st_uid != uid
                or info.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
                or not safe_directory_acl(directory_fd)
            ):
                return False
        finally:
            os.close(directory_fd)
    return True


def read_owned(path):
    if not safe_parent_chain(path):
        raise RuntimeError("unsafe headless repair evidence parent chain")
    fd = os.open(path, os.O_RDONLY | nonblock | nofollow)
    try:
        before = os.fstat(fd)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_uid != uid
            or before.st_nlink != 1
            or stat.S_IMODE(before.st_mode) & (stat.S_IWGRP | stat.S_IWOTH)
            or before.st_size < 0
            or before.st_size > max_bytes
            or not no_acl(fd)
        ):
            raise RuntimeError("unsafe headless repair evidence")
        payload = bytearray()
        while len(payload) < before.st_size:
            chunk = os.read(fd, min(65536, before.st_size - len(payload)))
            if not chunk:
                raise RuntimeError("headless repair evidence truncated")
            payload.extend(chunk)
        after = os.fstat(fd)
        path_info = os.lstat(path)
        if (
            (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns)
            != (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns)
            or stat.S_ISLNK(path_info.st_mode)
            or (path_info.st_dev, path_info.st_ino) != (before.st_dev, before.st_ino)
        ):
            raise RuntimeError("headless repair evidence changed during read")
        return bytes(payload)
    finally:
        os.close(fd)


def simple_values(config, key):
    pattern = re.compile(rf'^{re.escape(key)}:\s*"?([^"\s]+)"?\s*$')
    values = []
    for line in config.splitlines():
        match = pattern.match(line)
        if match:
            values.append(match.group(1))
    return values


config = read_owned(config_path).decode("utf-8")
provider_id = read_owned(provider_id_path).decode("utf-8").strip()
if simple_values(config, "provider_id") != [provider_id]:
    raise SystemExit(1)
if simple_values(config, "credential_store") != ["protected_file"]:
    raise SystemExit(1)
if simple_values(config, "auto_update_enabled") != ["false"]:
    raise SystemExit(1)
provider_token_patterns = [
    re.compile(r"^provider_token[ \t]*:"),
    re.compile(r"^'provider_token'[ \t]*:"),
    re.compile(r'^"provider_token"[ \t]*:'),
    re.compile(r'^"provider\\u005ftoken"[ \t]*:'),
]
if any(any(pattern.match(line) for pattern in provider_token_patterns) for line in config.splitlines()):
    raise SystemExit(1)

plist = plistlib.loads(read_owned(plist_path))
arguments = plist.get("ProgramArguments")
environment = plist.get("EnvironmentVariables")
if plist.get("Label") != label:
    raise SystemExit(1)
if plist.get("UserName") != headless_user:
    raise SystemExit(1)
if (
    not isinstance(arguments, list)
    or not arguments
    or arguments != [arguments[0], "serve", "--config", config_path]
):
    raise SystemExit(1)
program = plist.get("Program")
if program is not None and program != arguments[0]:
    raise SystemExit(1)
incumbent_binary = arguments[0]
if not os.path.isabs(incumbent_binary) or not safe_parent_chain(incumbent_binary):
    raise SystemExit(1)
if not isinstance(environment, dict):
    raise SystemExit(1)
if environment.get("MACPROVIDER_CREDENTIAL_STORE") != "protected_file":
    raise SystemExit(1)
if environment.get("MACPROVIDER_PROTECTED_CREDENTIAL_ROOT") != os.path.join(config_dir, "protected-credentials"):
    raise SystemExit(1)
if environment.get("MACPROVIDER_HEADLESS") != "1":
    raise SystemExit(1)
if environment.get("MACPROVIDER_HEADLESS_USER") != headless_user:
    raise SystemExit(1)
if environment.get("MACPROVIDER_LAUNCHD_DOMAIN") != "system":
    raise SystemExit(1)
binary_fd = os.open(incumbent_binary, os.O_RDONLY | nonblock | nofollow)
try:
    binary_info = os.fstat(binary_fd)
    if (
        not stat.S_ISREG(binary_info.st_mode)
        or binary_info.st_uid != uid
        or binary_info.st_nlink != 1
        or stat.S_IMODE(binary_info.st_mode) & (stat.S_IWGRP | stat.S_IWOTH)
        or not no_acl(binary_fd)
        or not (stat.S_IMODE(binary_info.st_mode) & stat.S_IXUSR)
    ):
        raise SystemExit(1)
    digest = hashlib.sha256()
    while True:
        chunk = os.read(binary_fd, 65536)
        if not chunk:
            break
        digest.update(chunk)
    after_binary_info = os.fstat(binary_fd)
    path_info = os.lstat(incumbent_binary)
    if (
        (after_binary_info.st_dev, after_binary_info.st_ino, after_binary_info.st_size, after_binary_info.st_mtime_ns, after_binary_info.st_ctime_ns)
        != (binary_info.st_dev, binary_info.st_ino, binary_info.st_size, binary_info.st_mtime_ns, binary_info.st_ctime_ns)
        or stat.S_ISLNK(path_info.st_mode)
        or (path_info.st_dev, path_info.st_ino) != (binary_info.st_dev, binary_info.st_ino)
    ):
        raise SystemExit(1)
finally:
    os.close(binary_fd)
print(incumbent_binary)
print(digest.hexdigest())
PY
  )" || return 1
  incumbent_binary="$(printf '%s\n' "$incumbent_evidence" | sed -n '1p')"
  incumbent_sha256="$(printf '%s\n' "$incumbent_evidence" | sed -n '2p')"
  [ -n "$incumbent_binary" ] || return 1
  case "$incumbent_sha256" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) return 1 ;;
  esac
  MACPROVIDER_CREDENTIAL_STORE=protected_file \
  MACPROVIDER_PROTECTED_CREDENTIAL_ROOT="$CONFIG_DIR/protected-credentials" \
  MACPROVIDER_HEADLESS=1 \
  MACPROVIDER_HEADLESS_USER="$HEADLESS_USER" \
  MACPROVIDER_LAUNCHD_DOMAIN=system \
    "$incumbent_binary" credentials verify --config "$CONFIG_PATH" >/dev/null 2>&1 || return 1
  HEADLESS_REPAIR_INCUMBENT_BINARY="$incumbent_binary"
  HEADLESS_REPAIR_INCUMBENT_SHA256="$incumbent_sha256"
}

repair_incumbent_present_for_current_mode() {
  if headless_acceptance_repair_mode; then
    headless_acceptance_repair_safe_incumbent_present
  else
    repair_safe_incumbent_present
  fi
}

validate_supplied_referral_code_file() {
  referral_source_rc=0
  python3 - "$REFERRAL_CODE_SOURCE_FILE" <<'PY' || referral_source_rc=$?
import os
import stat
import sys

path = sys.argv[1]
try:
    path_info = os.lstat(path)
except FileNotFoundError:
    raise SystemExit(20)
except OSError:
    raise SystemExit(21)

if (
    not stat.S_ISREG(path_info.st_mode)
    or path_info.st_uid != os.geteuid()
    or path_info.st_nlink != 1
    or stat.S_IMODE(path_info.st_mode) != 0o600
    or path_info.st_size < 1
    or path_info.st_size > 256
):
    raise SystemExit(21)

descriptor = -1
try:
    descriptor = os.open(
        path,
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0),
    )
    open_info = os.fstat(descriptor)
except OSError:
    raise SystemExit(21)
finally:
    if descriptor >= 0:
        os.close(descriptor)

if (
    path_info.st_dev != open_info.st_dev
    or path_info.st_ino != open_info.st_ino
    or not stat.S_ISREG(open_info.st_mode)
    or open_info.st_uid != os.geteuid()
    or open_info.st_nlink != 1
    or stat.S_IMODE(open_info.st_mode) != 0o600
    or open_info.st_size < 1
    or open_info.st_size > 256
):
    raise SystemExit(21)
PY
  case "$referral_source_rc" in
    0) return 0 ;;
    20) die 20 "an invite code is required for a new private pre-beta provider" ;;
    *) die 21 "the invite-code handoff must be an owner-only 0600 regular file" ;;
  esac
}

prepare_fresh_referral_code() {
  [ "$DRY_RUN" -eq 0 ] || return 0
  [ "$EMERGENCY_ROLLBACK" != "1" ] || return 0
  case "$REFERRAL_REPLACE_INCUMBENT" in
    0|1) ;;
    *) die 7 "MACPROVIDER_REFERRAL_REPLACE_INCUMBENT must be 0 or 1" ;;
  esac
  case "$REPAIR_EXISTING_INSTALL" in
    0) ;;
    1)
      repair_incumbent_present_for_current_mode \
        || die 28 "trusted existing-install evidence is required for Malibu repair"
      log "Trusted existing-install evidence found; repairing without a referral code."
      return 0
      ;;
    *) die 7 "MACPROVIDER_REPAIR_EXISTING_INSTALL must be 0 or 1" ;;
  esac
  if restart_safe_incumbent_present; then
    if [ "$REFERRAL_REPLACE_INCUMBENT" != "1" ]; then
      return 0
    fi
    log "Fresh provider replacement requested; incumbent files and config stay unchanged until replacement cutover."
  fi
  if [ -n "$REFERRAL_CODE_SOURCE_FILE" ]; then
    validate_supplied_referral_code_file
    FRESH_REFERRAL_BOOTSTRAP=1
    return 0
  fi

  if [ "$NO_PROMPT" = "1" ]; then
    die 20 "an invite code is required for a new private pre-beta provider"
  fi

  printf "Malibu private pre-beta invite code (required): " >&2
  read_line
  referral_code="$REPLY"
  REPLY=""
  [ -n "$referral_code" ] \
    || die 20 "an invite code is required for a new private pre-beta provider"

  previous_umask="$(umask)"
  umask 077
  referral_path="$(mktemp "${TMPDIR:-/tmp}/macprovider-referral.XXXXXX")" || {
    umask "$previous_umask"
    referral_code=""
    die 70 "could not create the protected invite-code handoff"
  }
  umask "$previous_umask"
  REFERRAL_CODE_SOURCE_FILE="$referral_path"
  CREATED_REFERRAL_CODE_SOURCE_FILE=1
  FRESH_REFERRAL_BOOTSTRAP=1
  chmod -N "$referral_path" 2>/dev/null || chmod 600 "$referral_path" \
    || die 70 "could not protect the invite-code handoff"
  printf "%s" "$referral_code" > "$referral_path" \
    || die 70 "could not write the protected invite-code handoff"
  referral_code=""
  python3 - "$referral_path" <<'PY' \
    || die 70 "invite-code handoff is not an owner-only regular file"
import os
import stat
import sys

info = os.lstat(sys.argv[1])
if (
    not stat.S_ISREG(info.st_mode)
    or info.st_uid != os.geteuid()
    or info.st_nlink != 1
    or stat.S_IMODE(info.st_mode) != 0o600
):
    raise SystemExit(1)
PY
  referral_path=""
  log "Invite code accepted for secure one-time CLI validation."
}

# v1.2.2: pre-flight port collision detection. Without this, install
# proceeds, launchd loads, the binary crashes on bind, and the timeout
# path hides the real cause. Surface the collision early with a clear fix.
ensure_port_free() {
  stop_own_provider="${1:-0}"
  if [ "$DRY_RUN" -eq 1 ]; then
    return
  fi
  if [ "$stop_own_provider" -eq 1 ]; then
    assert_install_lock_ownership
  fi
  validate_port_value "$PORT"
  if ! command -v lsof >/dev/null 2>&1; then
    die 2 "missing required tool: lsof"
  fi
  holding_pids="$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null || true)"
  if [ -z "$holding_pids" ]; then
    return
  fi
  holding_cmd="$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | awk 'NR==2 {print $1 " (pid " $2 ")"}')"

  # F-603-V7-2: an existing macprovider-cli on this port is the normal
  # upgrade-in-place case. Stop that service and continue; only foreign
  # holders should block the install.
  own_provider_holds_port=0
  for holding_pid in $holding_pids; do
    holding_executable="$(lsof -a -p "$holding_pid" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1)"
    if provider_executable_owned_for_current_mode "$holding_executable"; then
      own_provider_holds_port=1
      break
    fi
  done
  if [ "$own_provider_holds_port" -eq 1 ]; then
    if [ "$stop_own_provider" != "1" ]; then
      log "Existing macprovider-cli holding port $PORT; will stop it after release verification."
      return
    fi
    log "Existing macprovider-cli holding port $PORT; stopping it for upgrade-in-place."
    if [ "$INSTALL_TX_SERVICE_WAS_ACTIVE" -eq 0 ] && [ "$INSTALL_TX_LEGACY_SERVICE_WAS_ACTIVE" -eq 0 ]; then
      case "$holding_pids" in
        *$'\n'*) die 70 "multiple manual macprovider-cli processes hold port $PORT; refusing ambiguous recovery capture" ;;
      esac
      capture_manual_provider_for_recovery "$holding_pids"
    fi
    reclaim_launchd_service "$PROVIDER_LABEL" \
      || die 5 "could not reclaim existing provider launchd service"
    reclaim_legacy_launchd_service "$LEGACY_PROVIDER_LABEL" "$LEGACY_PLIST_BOOTSTRAP_PATH" "$INSTALL_DIR/macprovider-cli" "$BINARY_PATH" \
      || die 5 "could not reclaim legacy provider launchd service"
    sleep 2
    if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | grep -q .; then
      log "Port $PORT still held after launchctl bootout; stopping each revalidated macprovider-cli PID."
      for holding_pid in $holding_pids; do
        if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | grep -Fxq "$holding_pid"; then
          stop_owned_manual_provider "$holding_pid" "$INSTALL_DIR/macprovider-cli" "$BINARY_PATH" "${HEADLESS_REPAIR_INCUMBENT_BINARY:-}" "$PORT" \
            || die 70 "could not safely stop macprovider-cli pid $holding_pid after revalidating executable and port ownership"
        fi
      done
    fi
    if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | grep -q .; then
      die 6 "could not stop existing macprovider-cli on port $PORT; please stop manually and retry"
    fi
    log "Port $PORT freed; proceeding with upgrade."
    return
  fi

  log "ERROR: port $PORT is already in use by ${holding_cmd:-another process}."
  log "Either stop that process, or set MACPROVIDER_PORT to a free port and re-run."
  log "Note: env var must be on the bash side of the pipe, not the curl side:"
  log "  curl -fsSL https://get.malibu.tech/install.sh | MACPROVIDER_PORT=18080 bash"
  die 6 "port $PORT busy; macprovider-cli cannot bind"
}

# Reclaim by launchd service target rather than plist path. A standalone
# install and Malibu share the provider label, so an older loaded job can
# continue to own the label even after its plist path has been replaced.
# A label-wide bootout is only allowed inside a durable install transaction
# with an owner-validated prior plist snapshot. The print record is bounded
# and its executable must be one of the provider/watchdog paths emitted by
# this installer; otherwise an unrelated job cannot be stopped accidentally.
reclaim_launchd_service() {
  local label="$1"
  local service_target="$LAUNCHD_DOMAIN/$label"
  local expected_program
  local legacy_program
  local repair_program
  local expected_plist
  local had_plist
  repair_program=""
  case "$label" in
    "$PROVIDER_LABEL")
      expected_program="$INSTALL_DIR/macprovider-cli"
      legacy_program="$BINARY_PATH"
      if headless_acceptance_repair_mode; then
        repair_program="${HEADLESS_REPAIR_INCUMBENT_BINARY:-}"
      fi
      expected_plist="$PLIST_BOOTSTRAP_PATH"
      had_plist="${INSTALL_TX_HAD_PLIST:-0}"
      ;;
    "$WATCHDOG_LABEL")
      expected_program="${WATCHDOG_BOOTSTRAP_PATH:-$WATCHDOG_PATH}"
      legacy_program="$WATCHDOG_DIR/watchdog.sh"
      expected_plist="$WATCHDOG_PLIST_BOOTSTRAP_PATH"
      had_plist="${INSTALL_TX_HAD_WATCHDOG_PLIST:-0}"
      ;;
    *)
      log "Refusing to reclaim unknown launchd label: $label"
      return 1
      ;;
  esac
  local service_details
  if ! service_details="$(launchctl_service print "$service_target" 2>/dev/null | head -c 65537)"; then
    if [ -n "$service_details" ]; then
      log "Refusing to reclaim $label because its launchd identity exceeded the inspection limit."
      return 1
    fi
    # A fresh install has no incumbent plist. Absence of the label is safe;
    # only a loaded incumbent requires a durable snapshot before bootout.
    return 0
  fi
  [ -n "$service_details" ] || return 1
  if [ "${#service_details}" -gt 65536 ]; then
    log "Refusing to reclaim $label because its launchd identity exceeded the inspection limit."
    return 1
  fi
  if [ "${INSTALL_TX_ACTIVE:-0}" -ne 1 ] || [ "$had_plist" -ne 1 ]; then
    log "Refusing to reclaim loaded $label without a durable owner-safe recovery plist."
    return 1
  fi
  local program_line
  program_line="$(printf '%s\n' "$service_details" | sed -n 's/^[[:space:]]*program = //p' | head -n 1)"
  if [ -z "$program_line" ]; then
    log "Refusing to reclaim $label because launchd did not provide an executable identity."
    return 1
  fi
  local program_count
  program_count="$(printf '%s\n' "$service_details" | awk '/^[[:space:]]*program = / { count++ } END { print count + 0 }')"
  if [ "$program_count" -ne 1 ]; then
    log "Refusing to reclaim $label because launchd returned an ambiguous executable identity."
    return 1
  fi
  local plist_path
  plist_path="$(printf '%s\n' "$service_details" | sed -n 's/^[[:space:]]*path = //p' | head -n 1)"
  local plist_path_count
  plist_path_count="$(printf '%s\n' "$service_details" | awk '/^[[:space:]]*path = / { count++ } END { print count + 0 }')"
  if [ "$plist_path_count" -ne 1 ] || [ "$plist_path" != "$expected_plist" ]; then
    log "Refusing to reclaim $label because launchd plist identity is unexpected: ${plist_path:-<missing>}"
    return 1
  fi
  if [ "$program_line" != "$expected_program" ] \
    && [ "$program_line" != "$legacy_program" ] \
    && { [ -z "$repair_program" ] || [ "$program_line" != "$repair_program" ]; }; then
    log "Refusing to reclaim $label with unexpected executable: $program_line"
    return 1
  fi
  log "Reclaiming existing $label launchd service before replacing its plist."
  launchctl_service bootout "$service_target" >/dev/null 2>&1
}

reclaim_legacy_launchd_service() {
  local label="$1"
  local expected_plist="$2"
  local expected_program="$3"
  local legacy_program="$4"
  local service_target="$LAUNCHD_DOMAIN/$label"
  local service_details
  if ! service_details="$(launchctl_service print "$service_target" 2>/dev/null | head -c 65537)"; then
    return 0
  fi
  [ -n "$service_details" ] || return 1
  [ "${#service_details}" -le 65536 ] || return 1
  local program_line
  program_line="$(printf '%s\n' "$service_details" | sed -n 's/^[[:space:]]*program = //p' | head -n 1)"
  local program_count
  program_count="$(printf '%s\n' "$service_details" | awk '/^[[:space:]]*program = / { count++ } END { print count + 0 }')"
  local plist_path
  plist_path="$(printf '%s\n' "$service_details" | sed -n 's/^[[:space:]]*path = //p' | head -n 1)"
  local plist_path_count
  plist_path_count="$(printf '%s\n' "$service_details" | awk '/^[[:space:]]*path = / { count++ } END { print count + 0 }')"
  if [ "$program_count" -ne 1 ] || [ "$plist_path_count" -ne 1 ]; then
    log "Refusing to reclaim legacy $label because launchd returned an ambiguous identity."
    return 1
  fi
  if [ "$plist_path" != "$expected_plist" ]; then
    log "Refusing to reclaim legacy $label because launchd plist identity is unexpected: ${plist_path:-<missing>}"
    return 1
  fi
  if [ "$program_line" != "$expected_program" ] && [ "$program_line" != "$legacy_program" ]; then
    log "Refusing to reclaim legacy $label with unexpected executable: $program_line"
    return 1
  fi
  log "Reclaiming legacy $label launchd service before installing Malibu labels."
  launchctl_service bootout "$service_target" >/dev/null 2>&1
}

quiesce_repair_watchdog_label_for_transaction() {
  local label="$1"
  local expected_plist="$2"
  local expected_program="$3"
  local legacy_program="$4"
  local service_target="$LAUNCHD_DOMAIN/$label"
  local service_details
  local print_rc=0
  service_details="$(launchctl_service print "$service_target" 2>/dev/null | head -c 65537)" || print_rc=$?
  if [ "$print_rc" -ne 0 ]; then
    if [ "${#service_details}" -gt 65536 ]; then
      log "Refusing repair transaction watchdog quiesce for $label because launchd identity exceeded the inspection limit."
      return 1
    fi
    local loaded_rc=0
    launchd_print_loaded "$service_target" || loaded_rc=$?
    if [ "$loaded_rc" -eq 0 ]; then
      log "Refusing repair transaction watchdog quiesce for $label because launchd identity changed during inspection."
      return 1
    fi
    [ "$loaded_rc" -eq 1 ] || {
      log "Refusing repair transaction watchdog quiesce for $label because launchd state is indeterminate."
      return 1
    }
    return 0
  fi
  [ -n "$service_details" ] || return 1
  if [ "${#service_details}" -gt 65536 ]; then
    log "Refusing repair transaction watchdog quiesce for $label because launchd identity exceeded the inspection limit."
    return 1
  fi

  local program_line
  local program_count
  local plist_path
  local plist_path_count
  local watchdog_pid
  local watchdog_pid_count
  program_line="$(printf '%s\n' "$service_details" | sed -n 's/^[[:space:]]*program = //p' | head -n 1)"
  program_count="$(printf '%s\n' "$service_details" | awk '/^[[:space:]]*program = / { count++ } END { print count + 0 }')"
  plist_path="$(printf '%s\n' "$service_details" | sed -n 's/^[[:space:]]*path = //p' | head -n 1)"
  plist_path_count="$(printf '%s\n' "$service_details" | awk '/^[[:space:]]*path = / { count++ } END { print count + 0 }')"
  watchdog_pid="$(printf '%s\n' "$service_details" | sed -n 's/^[[:space:]]*pid = //p' | head -n 1)"
  watchdog_pid_count="$(printf '%s\n' "$service_details" | awk '/^[[:space:]]*pid = / { count++ } END { print count + 0 }')"
  if [ "$program_count" -ne 1 ] || [ "$plist_path_count" -ne 1 ]; then
    log "Refusing repair transaction watchdog quiesce for $label because launchd returned an ambiguous identity."
    return 1
  fi
  if [ "$watchdog_pid_count" -gt 1 ]; then
    log "Refusing repair transaction watchdog quiesce for $label because launchd returned ambiguous process identity."
    return 1
  fi
  case "$watchdog_pid" in
    ''|*[!0-9]*) [ -z "$watchdog_pid" ] || return 1 ;;
  esac
  if [ "$plist_path" != "$expected_plist" ]; then
    log "Refusing repair transaction watchdog quiesce for $label because launchd plist identity is unexpected."
    return 1
  fi
  if [ "$program_line" != "$expected_program" ] && [ "$program_line" != "$legacy_program" ]; then
    log "Refusing repair transaction watchdog quiesce for $label because launchd executable identity is unexpected."
    return 1
  fi

  log "Repair preflight: stopping loaded watchdog $label before validating and replacing provider software."
  launchctl_service bootout "$service_target" >/dev/null 2>&1 || return 1
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    local loaded_rc=0
    launchd_print_loaded "$service_target" || loaded_rc=$?
    if [ "$loaded_rc" -ne 0 ]; then
      if [ "$loaded_rc" -ne 1 ]; then
        log "Refusing to continue repair because launchd state for watchdog $label is indeterminate after bootout."
        return 1
      fi
      if [ -n "$watchdog_pid" ] && pid_is_live_non_zombie "$watchdog_pid"; then
        local observed_executable
        local observed_command
        observed_executable="$(lsof -nP -a -p "$watchdog_pid" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1)"
        observed_command="$(ps -p "$watchdog_pid" -o command= 2>/dev/null | head -n 1 || true)"
        if [ "$observed_executable" = "$expected_program" ] || [ "$observed_executable" = "$legacy_program" ] || [ -z "$observed_executable" ]; then
          log "Refusing to continue repair because watchdog pid $watchdog_pid remained live after bootout."
          return 1
        fi
        if [ -z "$observed_command" ] \
          || printf '%s\n' "$observed_command" | grep -F -- "$expected_program" >/dev/null \
          || printf '%s\n' "$observed_command" | grep -F -- "$legacy_program" >/dev/null; then
          log "Refusing to continue repair because watchdog pid $watchdog_pid still matched managed command identity after bootout."
          return 1
        fi
      fi
      return 0
    fi
    sleep 0.1
  done
  log "Refusing to continue repair because watchdog $label remained loaded after bootout."
  return 1
}

quiesce_repair_watchdogs_for_transaction() {
  [ "${REPAIR_EXISTING_INSTALL:-0}" -eq 1 ] || return 0
  quiesce_repair_watchdog_label_for_transaction \
    "$WATCHDOG_LABEL" "$WATCHDOG_PLIST_BOOTSTRAP_PATH" "${WATCHDOG_BOOTSTRAP_PATH:-$WATCHDOG_PATH}" "$WATCHDOG_DIR/watchdog.sh" \
    || die 5 "could not safely stop existing Malibu watchdog before repair validation"
  quiesce_repair_watchdog_label_for_transaction \
    "$LEGACY_WATCHDOG_LABEL" "$LEGACY_WATCHDOG_PLIST_BOOTSTRAP_PATH" "${WATCHDOG_BOOTSTRAP_PATH:-$WATCHDOG_PATH}" "$WATCHDOG_DIR/watchdog.sh" \
    || die 5 "could not safely stop existing legacy watchdog before repair validation"
}

prompt_yes_no() {
  prompt="$1"
  default="$2"
  if [ "$NO_PROMPT" = "1" ]; then
    log "$prompt $default (non-interactive default)"
    [ "$default" = "Y" ]
    return
  fi

  printf "%s " "$prompt"
  read_line
  answer="$REPLY"
  answer="${answer:-$default}"
  case "$answer" in
    y|Y|yes|YES) return 0 ;;
    n|N|no|NO) return 1 ;;
    *) return 1 ;;
  esac
}

reject_newlines() {
  name="$1"
  value="$2"
  case "$value" in
    *$'\n'*|*$'\r'*) die 7 "$name must not contain newlines" ;;
  esac
}

xml_escape() {
  printf "%s" "$1" | sed \
    -e 's/&/\&amp;/g' \
    -e 's/</\&lt;/g' \
    -e 's/>/\&gt;/g' \
    -e 's/"/\&quot;/g' \
    -e "s/'/\&apos;/g"
}

yaml_escape() {
  printf "%s" "$1" | sed \
    -e 's/\\/\\\\/g' \
    -e 's/"/\\"/g'
}

json_escape() {
  printf "%s" "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
}

urlencode() {
  local input="$1"
  local output=""
  local i char hex
  for ((i = 0; i < ${#input}; i++)); do
    char="${input:i:1}"
    case "$char" in
      [a-zA-Z0-9.~_-]) output="${output}${char}" ;;
      *) printf -v hex '%%%02X' "'$char"; output="${output}${hex}" ;;
    esac
  done
  printf "%s" "$output"
}

coordinator_http_base() {
  coordinator_url="$1"
  case "$coordinator_url" in
    wss://coordinator.malibu.tech/ws/provider) printf "%s" "$COORDINATOR_BASE_DEFAULT" ;;
    wss://*) printf "https://%s" "${coordinator_url#wss://}" | sed -E 's#/ws/provider/?$##' ;;
    *) die 7 "coordinator URL must start with wss://" ;;
  esac
}

detect_platform() {
  os="$(uname -s)"
  arch="$(uname -m)"
  [ "$os" = "Darwin" ] || die 1 "macOS is required; found $os"
  [ "$arch" = "arm64" ] || die 1 "Apple Silicon arm64 is required; found $arch"
  require_tool sw_vers
  macos_version="$(sw_vers -productVersion)"
  macos_major="${macos_version%%.*}"
  case "$macos_major" in
    ''|*[!0-9]*) die 1 "could not determine macOS version from '$macos_version'" ;;
  esac
  [ "$macos_major" -ge 14 ] || die 1 "macOS 14 Sonoma or newer is required; found $macos_version"
}

detect_ram_gb() {
  bytes="$(sysctl -n hw.memsize 2>/dev/null || true)"
  if [ -z "$bytes" ]; then
    printf "[macprovider-install] Could not read hw.memsize; defaulting to 8 GB model tier.\n" >&2
    bytes=8589934592
  fi
  awk "BEGIN { printf \"%d\", ($bytes + 1073741823) / 1073741824 }"
}

model_default_for_ram() {
  ram_gb="$1"
  if [ "$ram_gb" -lt 12 ]; then
    printf "mlx-community/Llama-3.2-3B-Instruct-4bit"
  elif [ "$ram_gb" -lt 16 ]; then
    printf "mlx-community/Qwen3-4B-Instruct-2507-4bit"
  elif [ "$ram_gb" -lt 24 ]; then
    printf "mlx-community/Qwen2.5-7B-Instruct-4bit"
  elif [ "$ram_gb" -lt 32 ]; then
    printf "mlx-community/Qwen2.5-14B-Instruct-4bit"
  elif [ "$ram_gb" -lt 48 ]; then
    printf "mlx-community/Qwen3-32B-4bit"
  elif [ "$ram_gb" -lt 64 ]; then
    printf "mlx-community/Llama-3.3-70B-Instruct-4bit"
  else
    printf "mlx-community/Qwen3-Next-80B-A3B-Instruct-4bit"
  fi
}

known_min_ram_gb_for_model() {
  case "$1" in
    mlx-community/Llama-3.2-3B-Instruct-4bit) printf "8" ;;
    mlx-community/Qwen3-4B-Instruct-2507-4bit) printf "12" ;;
    mlx-community/Qwen2.5-7B-Instruct-4bit) printf "16" ;;
    mlx-community/DeepSeek-R1-0528-Qwen3-8B-4bit) printf "16" ;;
    mlx-community/Qwen2.5-14B-Instruct-4bit) printf "24" ;;
    mlx-community/Qwen3-32B-4bit) printf "32" ;;
    mlx-community/Qwen2.5-Coder-32B-Instruct-4bit) printf "32" ;;
    mlx-community/Llama-3.3-70B-Instruct-4bit) printf "48" ;;
    mlx-community/Qwen3-Next-80B-A3B-Instruct-4bit) printf "64" ;;
  esac
}

known_weight_gb_for_model() {
  case "$1" in
    mlx-community/Llama-3.2-3B-Instruct-4bit) printf "2" ;;
    mlx-community/Qwen3-4B-Instruct-2507-4bit) printf "2" ;;
    mlx-community/Qwen2.5-7B-Instruct-4bit) printf "4" ;;
    mlx-community/DeepSeek-R1-0528-Qwen3-8B-4bit) printf "4" ;;
    mlx-community/Qwen2.5-14B-Instruct-4bit) printf "8" ;;
    mlx-community/Qwen3-32B-4bit) printf "18" ;;
    mlx-community/Qwen2.5-Coder-32B-Instruct-4bit) printf "17" ;;
    mlx-community/Llama-3.3-70B-Instruct-4bit) printf "35" ;;
    mlx-community/Qwen3-Next-80B-A3B-Instruct-4bit) printf "40" ;;
  esac
}

# SPEC-003 v0.9 FR-D2: enforce safe HuggingFace repo id format.
# Path-component charset (A-Za-z0-9._-) plus a single "/" separator. Any
# deviation from "org/name" is rejected — this id is interpolated into a URL
# and a YAML field, so traversal/newlines/whitespace must not slip through.
validate_hf_id() {
  id="$1"
  reject_newlines "model id" "$id"
  case "$id" in
    */*/*|*/) die 7 "model id must be in the form org/name (got: $id)" ;;
    */*) ;;
    *) die 7 "model id must be in the form org/name (got: $id)" ;;
  esac
  case "$id" in
    *[!A-Za-z0-9._/-]*) die 7 "model id contains invalid characters; allowed: A-Z a-z 0-9 . _ - /" ;;
  esac
  case "$id" in
    /*|*/) die 7 "model id must be in the form org/name (got: $id)" ;;
  esac
  # Round-2 hardening (codex code/security MAJOR): reject "." / ".." path
  # components even though the charset filter allows them. Otherwise an id
  # like "org/.." or "../name" passes the format check and could be
  # path-normalized into the HF URL or later treated as a relative local
  # model path by the binary.
  hf_org="${id%/*}"
  hf_name="${id##*/}"
  case "$hf_org" in
    .|..) die 7 "model id org segment cannot be \".\" or \"..\"" ;;
  esac
  case "$hf_name" in
    .|..) die 7 "model id name segment cannot be \".\" or \"..\"" ;;
  esac
}

# SPEC-003 v0.9 FR-D2: estimate weight size in GB from HF repo name.
# Parses N params from "...3B...", "...7B...", "...1.7B..." patterns and a
# quantization hint (4bit/8bit/bf16/fp16/q4/q8). Returns an integer GB to
# stdout or empty if the name can't be parsed — callers treat empty as
# "skip fit check, warn user".
estimate_weights_gb_from_name() {
  id="$1"
  # Round-2 (codex code MAJOR): match "NxMB" Mixture-of-Experts shape FIRST
  # (e.g. "Mixtral-8x7B" — 8 experts of 7B each, total ~56B params). The
  # single-N pattern below would otherwise capture only the "7B" half and
  # under-count memory by ~N×, letting the fit check pass a model that
  # would OOM the host.
  moe_match="$(printf "%s" "$id" | grep -oE '[0-9]+x[0-9]+(\.[0-9]+)?[Bb]' | head -n1)"
  if [ -n "$moe_match" ]; then
    experts="${moe_match%%x*}"
    per_rest="${moe_match#*x}"
    per_b="${per_rest%[Bb]}"
    params_b="$(awk -v e="$experts" -v p="$per_b" 'BEGIN { printf "%g", e * p }')"
  else
    params_b="$(printf "%s" "$id" | grep -oE '[0-9]+(\.[0-9]+)?[Bb]' | head -n1 | tr -d 'Bb')"
  fi
  [ -n "$params_b" ] || return 0
  quant_lc="$(printf "%s" "$id" | tr '[:upper:]' '[:lower:]')"
  case "$quant_lc" in
    *4bit*|*-q4*|*_q4*) bytes_per_param=0.5 ;;
    *8bit*|*-q8*|*_q8*) bytes_per_param=1.0 ;;
    *bf16*|*fp16*|*-f16*) bytes_per_param=2.0 ;;
    *) bytes_per_param=2.0 ;;
  esac
  awk -v p="$params_b" -v b="$bytes_per_param" \
    'BEGIN { gb = p * b; if (gb < 1) gb = 1; printf "%d", gb + 0.5 }'
}

hf_safetensors_gb_from_api_body() {
  body="$1"
  printf "%s" "$body" | tr '\n\r' '  ' | awk '
    {
      data = $0
      while (match(data, /"rfilename"[[:space:]]*:[[:space:]]*"[^"]*\.safetensors"/)) {
        data = substr(data, RSTART + RLENGTH)
        window = substr(data, 1, 700)
        if (match(window, /"size"[[:space:]]*:[[:space:]]*[0-9]+/)) {
          value = substr(window, RSTART, RLENGTH)
          gsub(/[^0-9]/, "", value)
          total += value + 0
        }
      }
    }
    END {
      if (total > 0) {
        printf "%d", int((total + 1073741824 - 1) / 1073741824)
      }
    }
  '
}

ram_floor_for_weight_gb() {
  weight_gb="$1"
  awk -v w="$weight_gb" '
    BEGIN {
      if (w <= 2) print 8;
      else if (w <= 3) print 12;
      else if (w <= 5) print 16;
      else if (w <= 9) print 24;
      else if (w <= 20) print 32;
      else if (w <= 38) print 48;
      else print 64;
    }
  '
}

confirm_model_fit_override() {
  reason="$1"
  if [ "$NO_PROMPT" = "1" ]; then
    die 7 "$reason; refusing non-interactive install"
  fi
  log "WARNING: $reason"
  prompt_yes_no "Proceed anyway? [y/N]" "N" || die 7 "aborted by user"
}

enforce_model_min_ram_floor() {
  id="$1"
  ram_gb="$2"
  min_ram_gb="$3"
  source="$4"
  if [ "$ram_gb" -lt "$min_ram_gb" ]; then
    confirm_model_fit_override "$source requires ${min_ram_gb} GB RAM for $id, but this Mac has ${ram_gb} GB"
  else
    log "Model fits: $id requires ${min_ram_gb} GB RAM by $source; this Mac has ${ram_gb} GB."
  fi
}

enforce_model_ram_fit_from_weight_gb() {
  id="$1"
  ram_gb="$2"
  weight_gb="$3"
  source="$4"
  min_ram_gb="$(ram_floor_for_weight_gb "$weight_gb")"
  if [ "$ram_gb" -lt "$min_ram_gb" ]; then
    confirm_model_fit_override "$source reports ~${weight_gb} GB safetensors; recommended RAM floor is ${min_ram_gb} GB for $id, but this Mac has ${ram_gb} GB"
  else
    log "Model fits: $source reports ~${weight_gb} GB safetensors; recommended RAM floor is ${min_ram_gb} GB and this Mac has ${ram_gb} GB."
  fi
}

enforce_model_ram_fit() {
  id="$1"
  ram_gb="$2"
  min_ram_gb="$(known_min_ram_gb_for_model "$id")"
  if [ -n "$min_ram_gb" ]; then
    enforce_model_min_ram_floor "$id" "$ram_gb" "$min_ram_gb" "model table"
    return 0
  fi

  est_gb="$(estimate_weights_gb_from_name "$id")"
  if [ -z "$est_gb" ]; then
    log "WARNING: could not estimate weight size from model name; skipping fit check."
    return 0
  fi
  # Headroom: ~6 GB for macOS (3-4 GB) + Metal + mlx runtime + binary +
  # KV cache. This matches the existing RAM-tier policy where the 7B (~4 GB)
  # default targets 16 GB Macs, not 8 GB Macs.
  comfortable_gb=$((est_gb + 6))
  if [ "$ram_gb" -ge "$comfortable_gb" ]; then
    log "Model fits: ~${est_gb} GB weights on ${ram_gb} GB Mac (working set ~${comfortable_gb} GB)."
    return 0
  fi
  if [ "$ram_gb" -ge "$((est_gb + 2))" ]; then
    confirm_model_fit_override "tight fit — ~${est_gb} GB weights on ${ram_gb} GB Mac; may swap or OOM under load"
    return 0
  fi
  confirm_model_fit_override "~${est_gb} GB weights will not fit on ${ram_gb} GB Mac"
}

catalog_min_ram_from_body() {
  catalog_body="$1"
  model_id="$2"
  printf "%s" "$catalog_body" | tr '\n\r' '  ' | awk -v id="$model_id" '
    BEGIN { RS = "}"; }
    index($0, "\"model_id\"") && index($0, "\"" id "\"") {
      if (match($0, /"min_ram_gb"[[:space:]]*:[[:space:]]*[1-9][0-9]*/)) {
        value = substr($0, RSTART, RLENGTH)
        gsub(/[^0-9]/, "", value)
        print value
      }
      exit
    }
  '
}

check_catalog_ram_metadata() {
  coordinator_base="$1"
  model_id="$2"
  ram_gb="$3"
  if [ "${MACPROVIDER_SKIP_CATALOG_CHECK:-0}" = "1" ]; then
    return 1
  fi
  if ! command -v curl >/dev/null 2>&1; then
    log "WARNING: curl not found; using built-in model RAM estimates."
    return 1
  fi

  catalog_url="$coordinator_base/catalog/current"
  body_and_code="$(curl -sSL -m 5 -o - -w '\n__HTTP_STATUS__%{http_code}' "$catalog_url" 2>/dev/null || printf '\n__HTTP_STATUS__network_error')"
  http_code="${body_and_code##*__HTTP_STATUS__}"
  catalog_body="${body_and_code%__HTTP_STATUS__*}"
  if [ "$http_code" != "200" ]; then
    log "WARNING: could not read signed catalog $catalog_url (status $http_code); using built-in model RAM estimates."
    return 1
  fi

  catalog_id="$(printf "%s" "$catalog_body" | sed -n 's/.*"catalog_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  if [ -z "$catalog_id" ]; then
    log "WARNING: signed catalog did not include catalog_id; using built-in model RAM estimates."
    return 1
  fi

  min_ram_gb="$(catalog_min_ram_from_body "$catalog_body" "$model_id")"
  if [ -n "$min_ram_gb" ]; then
    if [ "$ram_gb" -lt "$min_ram_gb" ]; then
      confirm_model_fit_override "catalog $catalog_id requires ${min_ram_gb} GB RAM for $model_id, but this Mac has ${ram_gb} GB"
    else
      log "Catalog fit: $model_id requires ${min_ram_gb} GB RAM; this Mac has ${ram_gb} GB."
    fi
    return 0
  fi
  log "WARNING: catalog $catalog_id has no min_ram_gb metadata; using built-in model RAM estimates."
  return 1
}

# SPEC-003 v0.9 FR-D2: pre-install validation of a user-supplied HuggingFace
# model id. Hard-blocks on inaccessible (401/403/404 — HF returns 401 for both
# gated and nonexistent repos) and on non-MLX repos. Warns and prompts on
# tight/over-RAM fit; user may override. Network errors downgrade to a
# "skipped" warning so a flaky HF doesn't brick installs, but the local
# name-based RAM-fit guard still runs. All output goes to stderr — caller's
# stdout is reserved for the chosen id.
hf_check_model() {
  id="$1"
  ram_gb="$2"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "Dry run: would check model $id on HuggingFace."
    enforce_model_ram_fit "$id" "$ram_gb"
    return 0
  fi
  if [ "${MACPROVIDER_SKIP_HF_CHECK:-0}" = "1" ]; then
    log "Skipping HuggingFace check (MACPROVIDER_SKIP_HF_CHECK=1)."
    enforce_model_ram_fit "$id" "$ram_gb"
    return 0
  fi
  if ! command -v curl >/dev/null 2>&1; then
    log "curl not found; skipping HuggingFace check."
    enforce_model_ram_fit "$id" "$ram_gb"
    return 0
  fi
  log "Checking model $id on HuggingFace…"
  api_url="https://huggingface.co/api/models/$id?blobs=true"
  # -f omitted so 4xx bodies still reach us; status is routed explicitly below.
  body_and_code="$(curl -sSL -m 10 -o - -w '\n__HTTP_STATUS__%{http_code}' "$api_url" 2>/dev/null || printf '\n__HTTP_STATUS__network_error')"
  http_code="${body_and_code##*__HTTP_STATUS__}"
  body="${body_and_code%__HTTP_STATUS__*}"
  case "$http_code" in
    200) ;;
    401|403|404)
      die 7 "model $id is not accessible on HuggingFace (private, gated, or doesn't exist). For a gated repo, use 'macprovider-cli models switch' post-install with HF_TOKEN set."
      ;;
    network_error)
      log "WARNING: could not reach HuggingFace API; using local RAM-fit estimate only."
      enforce_model_ram_fit "$id" "$ram_gb"
      return 0
      ;;
    *)
      log "WARNING: unexpected HuggingFace API status $http_code; using local RAM-fit estimate only."
      enforce_model_ram_fit "$id" "$ram_gb"
      return 0
      ;;
  esac

  # MLX detection: mlx-community/* repos are mlx by convention, plus any repo
  # that declares mlx as library_name or carries an "mlx" tag.
  is_mlx=0
  case "$id" in
    mlx-community/*) is_mlx=1 ;;
  esac
  if [ "$is_mlx" -eq 0 ]; then
    # Round-2 (codex code MINOR): flatten the body to one line before the
    # tags regex. HF currently returns minified JSON, but a future format
    # change to pretty-printed bodies would defeat the bracketed-class
    # match because grep -E reads line-by-line.
    flat_body="$(printf "%s" "$body" | tr -d '\n\r')"
    if printf "%s" "$flat_body" | grep -qE '"library_name"[[:space:]]*:[[:space:]]*"mlx"|"tags"[[:space:]]*:[[:space:]]*\[[^]]*"mlx"'; then
      is_mlx=1
    fi
  fi
  if [ "$is_mlx" -eq 0 ]; then
    die 7 "model $id is not an MLX repo. macprovider runs MLX-format models only. Pick an mlx-community/* variant or convert with mlx_lm.convert."
  fi

  hf_weight_gb="$(hf_safetensors_gb_from_api_body "$body")"
  if [ -n "$hf_weight_gb" ]; then
    enforce_model_ram_fit_from_weight_gb "$id" "$ram_gb" "$hf_weight_gb" "HuggingFace"
  else
    enforce_model_ram_fit "$id" "$ram_gb"
  fi
}

choose_model() {
  ram_gb="$1"
  if [ -n "${MACPROVIDER_MODEL:-}" ]; then
    # Env-var override is an explicit power-user path, but it must still pass
    # the local RAM-fit guard. Keep the previous reachability behavior for
    # private/gated repos; NO_PROMPT oversized models fail loud with exit 7
    # instead of silently downloading multi-GB weights that cannot fit.
    validate_hf_id "$MACPROVIDER_MODEL"
    enforce_model_ram_fit "$MACPROVIDER_MODEL" "$ram_gb" >&2
    printf "%s" "$MACPROVIDER_MODEL"
    return
  fi

  default_model="$(model_default_for_ram "$ram_gb")"
  if [ "$NO_PROMPT" = "1" ]; then
    printf "%s" "$default_model"
    return
  fi

  printf "[macprovider-install] Detected approximately %s GB RAM.\n" "$ram_gb" >&2
  printf "Choose a model:\n" >&2
  printf "  1) mlx-community/Llama-3.2-3B-Instruct-4bit      ~2 GB, 8 GB Macs\n" >&2
  printf "  2) mlx-community/Qwen3-4B-Instruct-2507-4bit     ~2 GB, 12 GB+ Macs\n" >&2
  printf "  3) mlx-community/Qwen2.5-7B-Instruct-4bit        ~4 GB, 16 GB Macs\n" >&2
  printf "  4) mlx-community/DeepSeek-R1-0528-Qwen3-8B-4bit  ~4 GB, 16 GB+ Macs\n" >&2
  printf "  5) mlx-community/Qwen2.5-14B-Instruct-4bit       ~8 GB, 24 GB+ Macs\n" >&2
  printf "  6) mlx-community/Qwen3-32B-4bit                  ~18 GB, 32 GB+ Macs\n" >&2
  printf "  7) mlx-community/Qwen2.5-Coder-32B-Instruct-4bit ~17 GB, 32 GB+ Macs\n" >&2
  printf "  8) mlx-community/Llama-3.3-70B-Instruct-4bit     ~35 GB, 48 GB+ Macs\n" >&2
  printf "  9) mlx-community/Qwen3-Next-80B-A3B-Instruct-4bit ~40 GB, 64 GB+ Macs\n" >&2
  printf "  c) custom HuggingFace MLX model id\n" >&2
  printf "Selection [default: %s]: " "$default_model" >&2
  read_line
  selection="$REPLY"
  case "$selection" in
    1) printf "mlx-community/Llama-3.2-3B-Instruct-4bit" ;;
    2) printf "mlx-community/Qwen3-4B-Instruct-2507-4bit" ;;
    3) printf "mlx-community/Qwen2.5-7B-Instruct-4bit" ;;
    4) printf "mlx-community/DeepSeek-R1-0528-Qwen3-8B-4bit" ;;
    5) printf "mlx-community/Qwen2.5-14B-Instruct-4bit" ;;
    6) printf "mlx-community/Qwen3-32B-4bit" ;;
    7) printf "mlx-community/Qwen2.5-Coder-32B-Instruct-4bit" ;;
    8) printf "mlx-community/Llama-3.3-70B-Instruct-4bit" ;;
    9) printf "mlx-community/Qwen3-Next-80B-A3B-Instruct-4bit" ;;
    c|C)
      printf "HuggingFace model id (org/name): " >&2
      read_line
      custom_id="$REPLY"
      [ -n "$custom_id" ] || die 7 "custom model id cannot be empty"
      validate_hf_id "$custom_id"
      hf_check_model "$custom_id" "$ram_gb" >&2
      printf "%s" "$custom_id"
      ;;
    "") printf "%s" "$default_model" ;;
    *) die 7 "invalid model selection" ;;
  esac
}

generate_fresh_provider_id() {
  random_suffix="$(openssl rand -hex 16)" \
    || die 7 "could not generate a high-entropy provider auth principal"
  case "$random_suffix" in
    *[!0-9a-f]*|'') die 7 "unexpected provider auth principal encoding" ;;
  esac
  [ "${#random_suffix}" -eq 32 ] || die 7 "unexpected provider auth principal length"
  printf "mp-%s" "$random_suffix"
}

read_replacement_candidate_provider_id() {
  [ -f "${REPLACEMENT_CANDIDATE_PROVIDER_ID_PATH:-}" ] || return 1
  [ ! -L "$REPLACEMENT_CANDIDATE_PROVIDER_ID_PATH" ] \
    || die 7 "stored replacement candidate provider_id must not be a symlink"
  candidate="$(cat "$REPLACEMENT_CANDIDATE_PROVIDER_ID_PATH")" \
    || die 7 "could not read stored replacement candidate provider_id"
  case "$candidate" in
    mp-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) die 7 "stored replacement candidate provider_id is invalid" ;;
  esac
  printf "%s" "$candidate"
}

persist_replacement_candidate_provider_id() {
  [ "${REFERRAL_REPLACE_INCUMBENT:-0}" = "1" ] || return 0
  [ "${FRESH_REFERRAL_BOOTSTRAP:-0}" -eq 1 ] || return 0
  [ -n "${provider_id:-}" ] || die 7 "replacement candidate provider_id was not selected"
  case "$provider_id" in
    mp-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) die 7 "replacement candidate provider_id is invalid" ;;
  esac
  python3 - "$REPLACEMENT_CANDIDATE_DIR" "$REPLACEMENT_CANDIDATE_PROVIDER_ID_PATH" "$provider_id" <<'PY' \
    || die 70 "could not persist replacement candidate provider identity for retry"
import os
import stat
import sys
import tempfile

directory, output, provider_id = sys.argv[1:]
os.makedirs(directory, mode=0o700, exist_ok=True)
dir_info = os.stat(directory, follow_symlinks=False)
if not stat.S_ISDIR(dir_info.st_mode) or dir_info.st_uid != os.getuid() or stat.S_IMODE(dir_info.st_mode) != 0o700:
    raise SystemExit(70)
fd, temporary = tempfile.mkstemp(prefix=".provider_id.", dir=directory)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(provider_id)
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(temporary, 0o600)
    os.replace(temporary, output)
    directory_fd = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)
finally:
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
PY
}

retire_replacement_candidate_provider_id() {
  [ -n "${REPLACEMENT_CANDIDATE_DIR:-}" ] || return 0
  [ -e "$REPLACEMENT_CANDIDATE_DIR" ] || return 0
  rm -rf "$REPLACEMENT_CANDIDATE_DIR" \
    || return 1
}

choose_provider_id() {
  if [ "${REFERRAL_REPLACE_INCUMBENT:-0}" = "1" ] && [ "${FRESH_REFERRAL_BOOTSTRAP:-0}" -eq 1 ]; then
    if [ -f "${REPLACEMENT_CANDIDATE_PROVIDER_ID_PATH:-}" ]; then
      replacement_candidate="$(read_replacement_candidate_provider_id)"
      live_provider_id_file="$(cat "$PROVIDER_ID_PATH" 2>/dev/null || true)"
      live_config_provider_id="$(read_config_provider_id || true)"
      if [ "$replacement_candidate" = "$live_provider_id_file" ] || [ "$replacement_candidate" = "$live_config_provider_id" ]; then
        log "Discarding committed replacement candidate retry marker for active provider_id."
        retire_replacement_candidate_provider_id \
          || log "WARNING: committed replacement candidate retry marker could not be removed: $REPLACEMENT_CANDIDATE_DIR"
        generate_fresh_provider_id
        return
      fi
      printf "%s" "$replacement_candidate"
      return
    fi
    generate_fresh_provider_id
    return
  fi

  if [ -f "$PROVIDER_ID_PATH" ]; then
    saved="$(cat "$PROVIDER_ID_PATH")"
    if [ -n "$saved" ]; then
      printf "%s" "$saved"
      return
    fi
  fi

  existing="$(read_config_provider_id || true)"
  if [ -n "$existing" ]; then
    printf "%s" "$existing"
    return
  fi

  generate_fresh_provider_id
}

is_bootstrap_principal() {
  candidate="$1"
  case "$candidate" in
    mp-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) return 0 ;;
    *) return 1 ;;
  esac
}

choose_coordinator_url() {
  if [ -n "${MACPROVIDER_COORDINATOR_URL:-}" ]; then
    printf "%s" "$MACPROVIDER_COORDINATOR_URL"
    return
  fi
  if [ "$NO_PROMPT" = "1" ]; then
    printf "%s" "$COORDINATOR_URL_DEFAULT"
    return
  fi

  printf "Coordinator URL [default: %s]: " "$COORDINATOR_URL_DEFAULT" >&2
  read_line
  value="$REPLY"
  printf "%s" "${value:-$COORDINATOR_URL_DEFAULT}"
}

validate_inputs() {
  model="$1"
  provider_id="$2"
  coordinator_url="$3"
  reject_newlines "model" "$model"
  reject_newlines "provider_id" "$provider_id"
  reject_newlines "coordinator_url" "$coordinator_url"
  case "$model" in
    *[!A-Za-z0-9._/:+-]*) die 7 "model contains unsupported characters" ;;
  esac
  case "$provider_id" in
    ''|*[!a-z0-9-]*) die 7 "provider_id contains unsupported characters" ;;
  esac
  case "$coordinator_url" in
    wss://*) ;;
    *) die 7 "coordinator URL must start with wss://" ;;
  esac
}

latest_release_tag() {
  # Scan the recent release list and pick the newest tag that names a
  # macprovider-cli release (tag matches ^v[0-9], e.g. v1.3.1). The
  # /releases/latest endpoint can't be trusted on its own: it returns
  # whichever release is flagged "Latest" repo-wide, so any unrelated
  # release published under the same repo (e.g. macprovider-verify
  # under tag verify-vX.Y.Z) silently hijacks the installer.
  api_url="https://api.github.com/repos/${GITHUB_REPO}/releases?per_page=30"
  # Bound network stalls: --connect-timeout guards a captive portal / black-holed
  # socket, --speed-limit/--speed-time abort a mid-transfer stall, and --retry
  # rides out transient failures. Without these the installer hangs indefinitely
  # on a stalled GitHub API socket and the Malibu UI is stuck at "Starting
  # installer…" (its progress monitor only tracks macprovider-cli processes).
  json="$(curl -fsSL --connect-timeout 15 --speed-limit 1024 --speed-time 120 --retry 3 --retry-connrefused --retry-max-time 300 "$api_url")" || die 3 "failed to query GitHub Releases API: $api_url"
  tag="$(
    printf "%s" "$json" \
      | awk '
          function maybe_print_release(obj, tag, prerelease) {
            tag = ""
            prerelease = "false"
            if (match(obj, /"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"/)) {
              tag = substr(obj, RSTART, RLENGTH)
              sub(/^"tag_name"[[:space:]]*:[[:space:]]*"/, "", tag)
              sub(/"$/, "", tag)
            }
            if (match(obj, /"prerelease"[[:space:]]*:[[:space:]]*true/)) {
              prerelease = "true"
            }
            if (tag ~ /^v[0-9]+\.[0-9]+\.[0-9]+$/ && prerelease != "true") {
              print tag
              exit
            }
          }
          {
            data = data $0 "\n"
          }
          END {
            depth = 0
            in_string = 0
            escaped = 0
            start = 0
            for (i = 1; i <= length(data); i++) {
              ch = substr(data, i, 1)
              if (in_string) {
                if (escaped) {
                  escaped = 0
                } else if (ch == "\\") {
                  escaped = 1
                } else if (ch == "\"") {
                  in_string = 0
                }
                continue
              }
              if (ch == "\"") {
                in_string = 1
              } else if (ch == "{") {
                depth++
                if (depth == 1) {
                  start = i
                }
              } else if (ch == "}") {
                if (depth == 1 && start > 0) {
                  maybe_print_release(substr(data, start, i - start + 1))
                  start = 0
                }
                depth--
              }
            }
          }
        '
  )"
  [ -n "$tag" ] || die 3 "no non-prerelease macprovider-cli release (tag ^v[0-9]) found in recent GitHub Releases"
  printf "%s" "$tag"
}

version_at_least() (
  candidate_version="$1"
  floor_version="$2"
  IFS=.
  set -- ${candidate_version#v}
  a_major="$1"
  a_minor="$2"
  a_patch="$3"
  set -- ${floor_version#v}
  b_major="$1"
  b_minor="$2"
  b_patch="$3"

  [ "$a_major" -gt "$b_major" ] && exit 0
  [ "$a_major" -lt "$b_major" ] && exit 1
  [ "$a_minor" -gt "$b_minor" ] && exit 0
  [ "$a_minor" -lt "$b_minor" ] && exit 1
  [ "$a_patch" -ge "$b_patch" ]
)

validate_macprovider_version_tag() {
  local tag="$1"
  case "$tag" in
    *[[:space:]]*|*[[:cntrl:]]*) die 7 "MACPROVIDER_VERSION must not contain whitespace or control characters" ;;
  esac
  if ! [[ "$tag" =~ ^v(0|[1-9][0-9]{0,8})[.](0|[1-9][0-9]{0,8})[.](0|[1-9][0-9]{0,8})$ ]]; then
    die 7 "MACPROVIDER_VERSION must be a canonical vMAJOR.MINOR.PATCH with bounded numeric components"
  fi
  if ! version_at_least "$tag" "$MACPROVIDER_MIN_SUPPORTED_VERSION"; then
    die 7 "MACPROVIDER_VERSION $tag is below supported rollback floor $MACPROVIDER_MIN_SUPPORTED_VERSION"
  fi
}

validate_headless_release_tag() {
  local tag="$1"
  [ "$HEADLESS" = "1" ] || return 0
  validate_macprovider_version_tag "$tag"
  if ! version_at_least "$tag" "$MACPROVIDER_MIN_HEADLESS_VERSION"; then
    die 7 "headless mode requires macprovider-cli $MACPROVIDER_MIN_HEADLESS_VERSION or newer; $tag does not support SSH-only protected-file fleet installation"
  fi
}

validate_headless_acceptance_source() {
  [ "$HEADLESS" = "1" ] || return 0
  [ -z "${BUNDLED_APP:-}" ] \
    || die 7 "MACPROVIDER_BUNDLED_APP is not accepted in headless mode; use a signed acceptance asset bundle"
  missing_fields=""
  for field in \
    MACPROVIDER_ACCEPTANCE_ASSET_DIR \
    MACPROVIDER_VERSION \
    MACPROVIDER_ACCEPTANCE_COMMIT \
    MACPROVIDER_ACCEPTANCE_CONTROL_COMMIT \
    MACPROVIDER_ACCEPTANCE_RUN_ID \
    MACPROVIDER_ACCEPTANCE_RUN_ATTEMPT; do
    eval "field_value=\${$field:-}"
    [ -n "$field_value" ] || missing_fields="${missing_fields}${missing_fields:+, }$field"
  done
  [ -z "$missing_fields" ] \
    || die 7 "headless mode requires a signed acceptance asset bundle and exact provenance pins; missing: $missing_fields"
}

validate_repair_privilege_domain() {
  [ "${REPAIR_EXISTING_INSTALL:-0}" -eq 1 ] || return 0
  if [ "${HEADLESS:-0}" = "1" ] || [ "${LAUNCHD_DOMAIN:-}" = "system" ]; then
    if headless_acceptance_repair_mode; then
      return 0
    fi
    die 7 "Malibu.app repair supports user-domain LaunchAgents only; headless/system LaunchDaemon repair requires the signed acceptance fallback"
  fi
}

resolve_release_tag() {
  case "${EMERGENCY_ROLLBACK:-0}" in
    0|1) ;;
    *) die 7 "MACPROVIDER_EMERGENCY_ROLLBACK must be 0 or 1" ;;
  esac
  if [ "${EMERGENCY_ROLLBACK:-0}" = "1" ] && [ -z "${MACPROVIDER_VERSION:-}" ]; then
    die 7 "emergency rollback requires MACPROVIDER_VERSION pinned to the prior signed tag"
  fi
  acceptance_identity_fields=0
  [ -z "${MACPROVIDER_ACCEPTANCE_ASSET_DIR:-}" ] || acceptance_identity_fields=$((acceptance_identity_fields + 1))
  [ -z "${MACPROVIDER_VERSION:-}" ] || acceptance_identity_fields=$((acceptance_identity_fields + 1))
  [ -z "${MACPROVIDER_ACCEPTANCE_COMMIT:-}" ] || acceptance_identity_fields=$((acceptance_identity_fields + 1))
  [ -z "${MACPROVIDER_ACCEPTANCE_CONTROL_COMMIT:-}" ] || acceptance_identity_fields=$((acceptance_identity_fields + 1))
  [ -z "${MACPROVIDER_ACCEPTANCE_RUN_ID:-}" ] || acceptance_identity_fields=$((acceptance_identity_fields + 1))
  [ -z "${MACPROVIDER_ACCEPTANCE_RUN_ATTEMPT:-}" ] || acceptance_identity_fields=$((acceptance_identity_fields + 1))
  if [ "$acceptance_identity_fields" -ne 0 ] && [ -n "${MACPROVIDER_ACCEPTANCE_ASSET_DIR:-}" ]; then
    [ "$acceptance_identity_fields" -eq 6 ] \
      || die 7 "acceptance candidates require version, candidate/control commits, and run id/attempt together"
    [ "$GITHUB_REPO" = "Augustas11/macprovider" ] \
      || die 7 "acceptance candidates are bound to repository Augustas11/macprovider"
    [[ "$MACPROVIDER_ACCEPTANCE_COMMIT" =~ ^[0-9a-f]{40}$ ]] \
      || die 7 "MACPROVIDER_ACCEPTANCE_COMMIT must be exactly 40 lowercase hex characters"
    [[ "$MACPROVIDER_ACCEPTANCE_CONTROL_COMMIT" =~ ^[0-9a-f]{40}$ ]] \
      || die 7 "MACPROVIDER_ACCEPTANCE_CONTROL_COMMIT must be exactly 40 lowercase hex characters"
    [[ "$MACPROVIDER_ACCEPTANCE_RUN_ID" =~ ^[1-9][0-9]{0,19}$ ]] \
      || die 7 "MACPROVIDER_ACCEPTANCE_RUN_ID must be a positive decimal GitHub Actions run id"
    [[ "$MACPROVIDER_ACCEPTANCE_RUN_ATTEMPT" =~ ^[1-9][0-9]{0,9}$ ]] \
      || die 7 "MACPROVIDER_ACCEPTANCE_RUN_ATTEMPT must be a positive decimal run attempt"
  elif [ -n "${MACPROVIDER_ACCEPTANCE_COMMIT:-}${MACPROVIDER_ACCEPTANCE_CONTROL_COMMIT:-}${MACPROVIDER_ACCEPTANCE_RUN_ID:-}${MACPROVIDER_ACCEPTANCE_RUN_ATTEMPT:-}" ]; then
    die 7 "acceptance identity fields require MACPROVIDER_ACCEPTANCE_ASSET_DIR"
  fi
  if [ -n "${MACPROVIDER_VERSION:-}" ]; then
    validate_macprovider_version_tag "$MACPROVIDER_VERSION"
    if [ "${EMERGENCY_ROLLBACK:-0}" = "1" ] && ! version_at_least "$MACPROVIDER_VERSION" "$MACPROVIDER_MIN_EMERGENCY_VERSION"; then
      die 7 "emergency rollback target $MACPROVIDER_VERSION predates the config-compatible floor $MACPROVIDER_MIN_EMERGENCY_VERSION"
    fi
    printf "%s" "$MACPROVIDER_VERSION"
  else
    tag="$(latest_release_tag)"
    printf "%s" "$tag"
  fi
}

validated_acceptance_asset_dir() {
  raw="$1"
  python3 - "$raw" <<'PY'
import os
import stat
import sys

raw = sys.argv[1]
if not raw.startswith("/") or any(part in {".", ".."} for part in raw.split("/")):
    raise SystemExit("acceptance asset directory must be an absolute canonical path")
path = os.path.normpath(raw)
if os.path.realpath(path) != path:
    raise SystemExit("acceptance asset directory must not contain symlinks")
root = os.lstat(path)
if not stat.S_ISDIR(root.st_mode) or root.st_uid != os.getuid() or root.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
    raise SystemExit("acceptance asset directory must be owned by the installing user and not group/world-writable")
entries = os.listdir(path)
if not 1 <= len(entries) <= 64:
    raise SystemExit("acceptance asset directory has an invalid asset count")
total = 0
for name in entries:
    if not name or name in {".", ".."} or "/" in name or "\x00" in name:
        raise SystemExit("acceptance asset directory contains an invalid name")
    candidate = os.path.join(path, name)
    info = os.lstat(candidate)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
        raise SystemExit("acceptance assets must be owned regular files without hard links")
    if info.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        raise SystemExit("acceptance assets must not be group/world-writable")
    total += info.st_size
    if total > 8 * 1024 * 1024 * 1024:
        raise SystemExit("acceptance asset directory exceeds the size limit")
print(path)
PY
}

validated_bundled_cli() {
  raw="$1"
  python3 - "$raw" <<'PY'
import os
import stat
import sys

raw = sys.argv[1]
if not raw.startswith("/") or any(part in {".", ".."} for part in raw.split("/")):
    raise SystemExit("bundled CLI path must be an absolute canonical path")
path = os.path.realpath(raw)
info = os.lstat(path)
if not stat.S_ISREG(info.st_mode):
    raise SystemExit("bundled CLI must be a regular file")
if info.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
    raise SystemExit("bundled CLI must not be group/world-writable")
if not os.access(path, os.R_OK | os.X_OK):
    raise SystemExit("bundled CLI must be readable and executable by the installing user")
if info.st_size < 16 or info.st_size > 512 * 1024 * 1024:
    raise SystemExit("bundled CLI has an invalid size")
print(path)
PY
}

validated_bundled_app() {
  raw="$1"
  python3 - "$raw" <<'PY'
import os
import stat
import sys

raw = sys.argv[1]
if not raw.startswith("/") or any(part in {".", ".."} for part in raw.split("/")):
    raise SystemExit("bundled Malibu.app path must be an absolute canonical path")
path = os.path.realpath(raw)
info = os.lstat(path)
if not stat.S_ISDIR(info.st_mode):
    raise SystemExit("bundled Malibu.app must be a directory")
if not path.endswith(".app"):
    raise SystemExit("bundled payload must be a Malibu.app bundle")
if info.st_mode & stat.S_IWOTH:
    raise SystemExit("bundled Malibu.app must not be world-writable")
if not os.access(path, os.R_OK | os.X_OK):
    raise SystemExit("bundled Malibu.app must be readable by the installing user")
required = [
    os.path.join(path, "Contents/MacOS/macprovider-cli"),
    os.path.join(path, "Contents/Resources/compatibility-set.json"),
]
for candidate in required:
    if not os.path.isfile(candidate):
        raise SystemExit(f"Malibu.app is missing {os.path.relpath(candidate, path)}")
for directory in (
    os.path.join(path, "Contents/Resources/compatibility-set-local"),
    os.path.join(path, "Contents/Resources/catalog-release"),
):
    if not os.path.isdir(directory):
        raise SystemExit(f"Malibu.app is missing {os.path.relpath(directory, path)}")
print(path)
PY
}

stage_bundled_repair_payload() {
  [ "${REPAIR_EXISTING_INSTALL:-0}" -eq 1 ] \
    || die 7 "bundled CLI staging is only allowed for existing-install repair"
  [ -n "${BUNDLED_APP:-}" ] \
    || die 7 "existing-install repair requires MACPROVIDER_BUNDLED_APP from Malibu.app"
  [ -n "${MACPROVIDER_ACCEPTANCE_ASSET_DIR:-}" ] \
    && die 7 "bundled repair cannot mix acceptance assets"
  [ "${EMERGENCY_ROLLBACK:-0}" = "1" ] \
    && die 7 "bundled repair cannot mix emergency rollback"
  bundled_app="$(validated_bundled_app "$BUNDLED_APP")" \
    || die 7 "unsafe MACPROVIDER_BUNDLED_APP"
  if [ -n "${BUNDLED_CLI:-}" ]; then
    bundled_cli="$(validated_bundled_cli "$BUNDLED_CLI")" \
      || die 7 "unsafe MACPROVIDER_BUNDLED_CLI"
    [ "$bundled_cli" = "$(validated_bundled_cli "$bundled_app/Contents/MacOS/macprovider-cli")" ] \
      || die 7 "MACPROVIDER_BUNDLED_CLI must be the Malibu.app embedded provider CLI"
  else
    bundled_cli="$(validated_bundled_cli "$bundled_app/Contents/MacOS/macprovider-cli")" \
      || die 7 "Malibu.app is missing an executable provider CLI"
  fi
  [ -n "$TMPDIR_PATH" ] || die 5 "bundled repair staging requires a temp directory"
  staging_dir="$TMPDIR_PATH/staging"
  rm -rf "$staging_dir"
  mkdir -p "$staging_dir"
  cp -p "$bundled_cli" "$staging_dir/macprovider-cli" \
    || die 5 "failed to stage the Malibu.app bundled provider CLI"
  chmod 0755 "$staging_dir/macprovider-cli" \
    || die 5 "failed to mark the staged bundled provider CLI executable"
  [ -x "$staging_dir/macprovider-cli" ] \
    || die 5 "staged bundled macprovider-cli is not executable"
  macos_dir="$bundled_app/Contents/MacOS"
  resources_dir="$bundled_app/Contents/Resources"
  [ -f "$macos_dir/mlx.metallib" ] \
    || die 5 "Malibu.app is missing mlx.metallib next to the bundled provider CLI"
  cp -p "$macos_dir/mlx.metallib" "$staging_dir/mlx.metallib" \
    || die 5 "failed to stage mlx.metallib from Malibu.app"
  find "$macos_dir" -mindepth 1 -maxdepth 1 -name '*.bundle' -exec cp -R {} "$staging_dir"/ \;
  cp -p "$resources_dir/compatibility-set.json" "$staging_dir/compatibility-set.json" \
    || die 5 "failed to stage compatibility-set.json from Malibu.app"
  cp -R "$resources_dir/compatibility-set-local" "$staging_dir/compatibility-set-local" \
    || die 5 "failed to stage compatibility-set-local from Malibu.app"
  cp -R "$resources_dir/catalog-release" "$staging_dir/catalog-release" \
    || die 5 "failed to stage catalog-release from Malibu.app"
  if [ -f "$resources_dir/THIRD-PARTY-NOTICES.txt" ]; then
    cp -p "$resources_dir/THIRD-PARTY-NOTICES.txt" "$staging_dir/THIRD-PARTY-NOTICES.txt" \
      || die 5 "failed to stage THIRD-PARTY-NOTICES.txt from Malibu.app"
  fi
  staged_version="$("$staging_dir/macprovider-cli" --version 2>/dev/null | tr -d '\r\n')" \
    || die 5 "bundled provider CLI did not report a version"
  case "$staged_version" in
    v*) ;;
    *) staged_version="v$staged_version" ;;
  esac
  [ "$staged_version" = "$tag" ] \
    || die 5 "bundled provider CLI version $staged_version does not match pinned repair target $tag"
  manifest_version="$(python3 - "$staging_dir/compatibility-set.json" <<'PY'
import json, sys
envelope = json.load(open(sys.argv[1], encoding="utf-8"))
version = envelope["signed"]["components"]["provider_cli"]["version"]
print("v" + version if not str(version).startswith("v") else version)
PY
)" || die 5 "Malibu.app compatibility-set.json is not a signed provider payload"
  [ "$manifest_version" = "$tag" ] \
    || die 5 "Malibu.app compatibility-set.json version $manifest_version does not match pinned repair target $tag"
  MACPROVIDER_CLI_EXECUTABLE="$staging_dir/macprovider-cli"
  asset_kind="bundled"
  asset_path="$bundled_cli"
  log "Staged Malibu.app bundled provider CLI $staged_version and matching compatibility set without downloading GitHub release assets."
}

download_release() {
  tag="$1"
  tarball_asset="macprovider-cli-${tag}-darwin-arm64.tar.gz"
  pkg_asset="macprovider-cli-${tag}-darwin-arm64.pkg"
  base="https://github.com/${GITHUB_REPO}/releases/download/${tag}"
  TMPDIR_PATH="$(mktemp -d)"
  tarball_path="$TMPDIR_PATH/$tarball_asset"
  pkg_path="$TMPDIR_PATH/$pkg_asset"
  checksums_path="$TMPDIR_PATH/checksums.txt"
  checksums_sig_path="$TMPDIR_PATH/checksums.txt.sig"
  ACCEPTANCE_METADATA_PATH=""
  ACCEPTANCE_METADATA_SIGNATURE_PATH=""
  asset_path=""
  asset_kind=""

  acceptance_dir=""
  if [ -n "${MACPROVIDER_ACCEPTANCE_ASSET_DIR:-}" ]; then
    [ -z "${MACPROVIDER_CHECKSUM_PUBLIC_KEY_PEM:-}" ] \
      || die 7 "acceptance candidates cannot override the embedded release signing key"
    acceptance_dir="$(validated_acceptance_asset_dir "$MACPROVIDER_ACCEPTANCE_ASSET_DIR")" \
      || die 7 "unsafe MACPROVIDER_ACCEPTANCE_ASSET_DIR"
    [ -f "$acceptance_dir/checksums.txt" ] \
      && [ -f "$acceptance_dir/acceptance-candidate.json" ] \
      && [ -f "$acceptance_dir/acceptance-candidate.json.sig" ] \
      || die 3 "acceptance candidate is missing checksums.txt or domain-separated acceptance metadata"
    [ ! -e "$acceptance_dir/checksums.txt.sig" ] \
      || die 4 "acceptance candidate must not contain a production checksums.txt.sig"
    cp "$acceptance_dir/checksums.txt" "$checksums_path" \
      || die 3 "failed to stage acceptance checksums.txt"
    ACCEPTANCE_METADATA_PATH="$TMPDIR_PATH/acceptance-candidate.json"
    ACCEPTANCE_METADATA_SIGNATURE_PATH="$TMPDIR_PATH/acceptance-candidate.json.sig"
    cp "$acceptance_dir/acceptance-candidate.json" "$ACCEPTANCE_METADATA_PATH" \
      || die 3 "failed to stage acceptance-candidate.json"
    cp "$acceptance_dir/acceptance-candidate.json.sig" "$ACCEPTANCE_METADATA_SIGNATURE_PATH" \
      || die 3 "failed to stage acceptance-candidate.json.sig"
    log "Using protected non-public acceptance assets for $tag."
  else
    curl -fL --connect-timeout 15 --speed-limit 1024 --speed-time 120 --retry 3 --retry-connrefused --retry-max-time 300 "$base/checksums.txt" -o "$checksums_path" || die 3 "failed to download checksums.txt"
    curl -fL --connect-timeout 15 --speed-limit 1024 --speed-time 120 --retry 3 --retry-connrefused --retry-max-time 300 "$base/checksums.txt.sig" -o "$checksums_sig_path" || die 3 "failed to download checksums.txt.sig"
  fi
  verify_checksum_signature

  release_format="${MACPROVIDER_RELEASE_FORMAT:-auto}"
  case "$release_format" in
    auto|pkg|tar) ;;
    *) die 7 "MACPROVIDER_RELEASE_FORMAT must be auto, pkg, or tar" ;;
  esac

  if [ "$release_format" != "tar" ]; then
    pkg_expected="$(checksum_for_asset "$pkg_asset")"
    if [ -n "$pkg_expected" ]; then
      if [ -n "$acceptance_dir" ]; then
        [ -f "$acceptance_dir/$pkg_asset" ] || die 3 "acceptance candidate is missing $pkg_asset"
        cp "$acceptance_dir/$pkg_asset" "$pkg_path" || die 3 "failed to stage acceptance package"
      else
        log "Downloading signed package $pkg_asset from GitHub Releases."
        curl -fL --connect-timeout 15 --speed-limit 1024 --speed-time 120 --retry 3 --retry-connrefused --retry-max-time 300 "$base/$pkg_asset" -o "$pkg_path" || die 3 "failed to download release package"
      fi
      asset_path="$pkg_path"
      asset_kind="pkg"
      log "Using signed package release asset: $pkg_asset"
      return
    fi
    [ "$release_format" = "auto" ] || die 3 "checksums.txt has no entry for $pkg_asset"
    log "Signed release manifest has no package for $tag; falling back to tarball."
  fi

  if [ -n "$acceptance_dir" ]; then
    [ -f "$acceptance_dir/$tarball_asset" ] || die 3 "acceptance candidate is missing $tarball_asset"
    cp "$acceptance_dir/$tarball_asset" "$tarball_path" || die 3 "failed to stage acceptance tarball"
  else
    log "Downloading $tarball_asset from GitHub Releases."
    curl -fL --connect-timeout 15 --speed-limit 1024 --speed-time 120 --retry 3 --retry-connrefused --retry-max-time 300 "$base/$tarball_asset" -o "$tarball_path" || die 3 "failed to download release tarball"
  fi
  asset_path="$tarball_path"
  asset_kind="tar"
}

write_checksum_public_key() {
  if [ -n "${MACPROVIDER_CHECKSUM_PUBLIC_KEY_PEM:-}" ]; then
    printf "%s\n" "$MACPROVIDER_CHECKSUM_PUBLIC_KEY_PEM"
    return
  fi
  cat <<'EOF'
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEwwd0Vzj35OP8DlZU+0lUa8vI9gHK
09J48LDizWScsH6rutnZLkKnGQ4X5Q8lT9L5mglF8Ba0DDoUXKrFfSAX4Q==
-----END PUBLIC KEY-----
EOF
}

write_acceptance_public_key() {
  # Synced byte-for-byte from security/acceptance-candidate-signing-public.pem.
  cat <<'EOF'
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEH3cSQs2LWFX2fP980/bheMCDuDRl
9Rk7C3PxvOE96Lm1Iy2oZGgB7sA99226bl8irZKV2L9o7IL/2/mL/F0m8A==
-----END PUBLIC KEY-----
EOF
}

verify_checksum_signature() {
  public_key_path="$TMPDIR_PATH/release-signing-public.pem"
  if [ -n "$ACCEPTANCE_METADATA_PATH" ]; then
    write_acceptance_public_key > "$public_key_path"
  else
    write_checksum_public_key > "$public_key_path"
  fi
  if grep -q "REPLACE_WITH_MACPROVIDER" "$public_key_path"; then
    die 3 "release signing public key is not configured in install.sh"
  fi
  if [ -n "$ACCEPTANCE_METADATA_PATH" ]; then
    signature_payload_path="$TMPDIR_PATH/acceptance-candidate.signature-payload"
    acceptance_signature_der_path="$TMPDIR_PATH/acceptance-candidate.signature.der"
    python3 - "$ACCEPTANCE_METADATA_PATH" "$ACCEPTANCE_METADATA_SIGNATURE_PATH" \
      "$checksums_path" "$GITHUB_REPO" "$tag" \
      "$MACPROVIDER_ACCEPTANCE_COMMIT" "$MACPROVIDER_ACCEPTANCE_CONTROL_COMMIT" \
      "$MACPROVIDER_ACCEPTANCE_RUN_ID" "$MACPROVIDER_ACCEPTANCE_RUN_ATTEMPT" \
      "$signature_payload_path" "$acceptance_signature_der_path" <<'PY' \
      || die 4 "acceptance-candidate metadata validation failed"
import base64
import datetime as dt
import hashlib
import json
import pathlib
import re
import sys

metadata_path, signature_path, checksums_path, repository, tag, candidate_commit, control_commit, run_id, run_attempt_raw, payload_path, signature_der_path = sys.argv[1:]
metadata = pathlib.Path(metadata_path).read_bytes()
checksums = pathlib.Path(checksums_path).read_bytes()
if not 0 < len(metadata) <= 16_384:
    raise SystemExit("metadata size")

def pairs(values):
    result = {}
    for key, value in values:
        if key in result:
            raise ValueError("duplicate key")
        result[key] = value
    return result

value = json.loads(
    metadata.decode("utf-8"),
    object_pairs_hook=pairs,
    parse_constant=lambda raw: (_ for _ in ()).throw(ValueError(raw)),
    parse_float=lambda raw: (_ for _ in ()).throw(ValueError(raw)),
)
fields = {
    "candidate_commit", "candidate_ref", "channel", "checksums", "compatibility_set_id",
    "control_commit", "expires_at", "issued_at", "repository", "run_attempt", "run_id",
    "schema_version", "signing", "tag",
}
canonical = (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()
if not isinstance(value, dict) or set(value) != fields or metadata != canonical:
    raise SystemExit("noncanonical metadata")
if value.get("schema_version") != "macprovider.acceptance-candidate.v1" or value.get("channel") != "acceptance":
    raise SystemExit("wrong domain")
if repository != "Augustas11/macprovider" or not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag):
    raise SystemExit("invalid expected identity")
if not re.fullmatch(r"[0-9a-f]{40}", candidate_commit) or not re.fullmatch(r"[0-9a-f]{40}", control_commit):
    raise SystemExit("invalid expected identity")
if not re.fullmatch(r"[1-9][0-9]{0,19}", run_id) or not re.fullmatch(r"[1-9][0-9]{0,9}", run_attempt_raw):
    raise SystemExit("invalid expected identity")
if any(value.get(name) != expected for name, expected in {
    "repository": repository, "tag": tag, "candidate_commit": candidate_commit,
    "control_commit": control_commit, "run_id": run_id, "run_attempt": int(run_attempt_raw),
}.items()):
    raise SystemExit("wrong expected identity")
candidate_ref = value.get("candidate_ref")
if not isinstance(candidate_ref, str) or not re.fullmatch(r"refs/heads/[A-Za-z0-9](?:[A-Za-z0-9._/-]{0,253}[A-Za-z0-9])?", candidate_ref):
    raise SystemExit("invalid candidate ref")
branch = candidate_ref.removeprefix("refs/heads/")
if ".." in branch or "@{" in branch or "//" in branch or branch.endswith(".") or any(
    not component or component.startswith(".") or component.endswith(".") or component.endswith(".lock")
    for component in branch.split("/")
):
    raise SystemExit("invalid candidate ref")
set_id = f"{repository}:{tag}@{candidate_commit}"
if value.get("compatibility_set_id") != set_id:
    raise SystemExit("wrong compatibility set")
checksums_descriptor = value.get("checksums")
if checksums_descriptor != {"name": "checksums.txt", "sha256": hashlib.sha256(checksums).hexdigest()}:
    raise SystemExit("wrong checksums digest")
if value.get("signing") != {
    "algorithm": "ecdsa-p256-sha256", "key_id": "macprovider-acceptance-p256-v1",
}:
    raise SystemExit("wrong signing descriptor")

def timestamp(name):
    raw = value.get(name)
    if not isinstance(raw, str) or not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", raw):
        raise SystemExit("invalid timestamp")
    parsed = dt.datetime.strptime(raw, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
    if parsed.strftime("%Y-%m-%dT%H:%M:%SZ") != raw:
        raise SystemExit("invalid timestamp")
    return parsed

issued_at = timestamp("issued_at")
expires_at = timestamp("expires_at")
now = dt.datetime.now(dt.timezone.utc)
if not 300 <= (expires_at - issued_at).total_seconds() <= 86_400:
    raise SystemExit("invalid validity window")
if issued_at > now + dt.timedelta(minutes=5) or expires_at <= now:
    raise SystemExit("expired or future candidate")
pathlib.Path(payload_path).write_bytes(b"macprovider.acceptance-candidate.v1\n" + metadata)
encoded_with_newline = pathlib.Path(signature_path).read_bytes()
if not encoded_with_newline.endswith(b"\n") or b"\n" in encoded_with_newline[:-1]:
    raise SystemExit("invalid signature encoding")
encoded = encoded_with_newline[:-1]
try:
    signature = base64.b64decode(encoded, validate=True)
except ValueError:
    raise SystemExit("invalid signature encoding")
if base64.b64encode(signature) != encoded or not 64 <= len(signature) <= 80:
    raise SystemExit("invalid signature encoding")
pathlib.Path(signature_der_path).write_bytes(signature)
PY
    openssl dgst -sha256 \
      -verify "$public_key_path" \
      -signature "$acceptance_signature_der_path" \
      "$signature_payload_path" >/dev/null \
      || die 4 "acceptance-candidate metadata signature verification failed"
    log "Domain-separated acceptance-candidate metadata signature verified."
  else
    openssl dgst -sha256 \
      -verify "$public_key_path" \
      -signature "$checksums_sig_path" \
      "$checksums_path" >/dev/null || die 4 "checksums.txt signature verification failed"
    log "checksums.txt signature verified."
  fi
}

checksum_for_asset() {
  asset_name="$1"
  awk -v asset="$asset_name" '$2 == asset { print $1; exit }' "$checksums_path"
}

verify_sha256() {
  asset_name="$(basename "$asset_path")"
  expected="$(checksum_for_asset "$asset_name")"
  [ -n "$expected" ] || die 4 "checksums.txt has no entry for $asset_name"
  actual="$(shasum -a 256 "$asset_path" | awk '{print $1}')"
  [ "$actual" = "$expected" ] || die 4 "checksum mismatch for $asset_name"
  log "SHA256 verified."
}

validate_tarball() {
  entries="$(tar tzf "$asset_path")" || die 5 "failed to list release tarball"
  [ -n "$entries" ] || die 5 "release tarball is empty"

  validate_staged_entries "$entries" "tarball"
  if tar tvzf "$asset_path" | awk '{print substr($1,1,1), $0}' | grep -E '^[lhbcp]' >/dev/null; then
    die 5 "release tarball contains unsafe link or device members"
  fi
}

validate_staged_entries() {
  entries="$1"
  label="$2"
  has_binary=0
  has_metallib=0
  has_bundle=0
  has_bundled_metallib=0
  has_catalog_manifest=0
  has_catalog_keyring=0
  has_catalog_tier2=0
  has_catalog_candidates=0
  has_catalog_candidates_signature=0
  has_catalog_demand=0
  has_catalog_demand_signature=0
  has_catalog_rate_card=0
  has_catalog_rate_card_signature=0
  has_compatibility_set=0
  has_local_install_contract=0
  has_local_provider_plist=0
  has_local_updater_metadata=0
  has_local_watchdog_plist=0
  has_local_watchdog_script=0
  while IFS= read -r entry; do
    normalized_entry="$entry"
    while :; do
      case "$normalized_entry" in
        ./*) normalized_entry="${normalized_entry#./}" ;;
        *) break ;;
      esac
    done
    case "$normalized_entry" in
      ""|.) continue ;;
    esac
    case "$normalized_entry" in
      /*|*"/../"*|../*|*/..|..)
        die 5 "unsafe tarball path: $entry"
        ;;
      macprovider-cli)
        has_binary=1
        ;;
      mlx.metallib)
        has_metallib=1
        ;;
      mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib)
        has_bundle=1
        has_bundled_metallib=1
        ;;
      THIRD-PARTY-NOTICES.txt)
        ;;
      compatibility-set.json)
        has_compatibility_set=1
        ;;
      compatibility-set-local|compatibility-set-local/)
        ;;
      compatibility-set-local/install.sh)
        has_local_install_contract=1
        ;;
      compatibility-set-local/provider-launch-agent.plist.template)
        has_local_provider_plist=1
        ;;
      compatibility-set-local/updater-rollback.json)
        has_local_updater_metadata=1
        ;;
      compatibility-set-local/watchdog-launch-agent.plist.template)
        has_local_watchdog_plist=1
        ;;
      compatibility-set-local/watchdog.sh)
        has_local_watchdog_script=1
        ;;
      *.bundle|*.bundle/*)
        has_bundle=1
        ;;
      catalog-release|catalog-release/)
        ;;
      catalog-release/release.json)
        has_catalog_manifest=1
        ;;
      catalog-release/trusted-keys.json)
        has_catalog_keyring=1
        ;;
      catalog-release/tier2-catalog.json)
        has_catalog_tier2=1
        ;;
      catalog-release/autotune-candidates.json)
        has_catalog_candidates=1
        ;;
      catalog-release/autotune-candidates.json.sig)
        has_catalog_candidates_signature=1
        ;;
      catalog-release/demand-rank.json)
        has_catalog_demand=1
        ;;
      catalog-release/demand-rank.json.sig)
        has_catalog_demand_signature=1
        ;;
      catalog-release/rate-card.json)
        has_catalog_rate_card=1
        ;;
      catalog-release/rate-card.json.sig)
        has_catalog_rate_card_signature=1
        ;;
      *)
        die 5 "unexpected $label member: $entry"
        ;;
    esac
  done <<EOF
$entries
EOF

  [ "$has_binary" -eq 1 ] || die 5 "$label does not contain macprovider-cli"
  [ "$has_bundle" -eq 1 ] || die 5 "$label does not contain a SwiftPM resource bundle"
  catalog_member_count=$((
    has_catalog_manifest +
    has_catalog_keyring +
    has_catalog_tier2 +
    has_catalog_candidates +
    has_catalog_candidates_signature +
    has_catalog_demand +
    has_catalog_demand_signature +
    has_catalog_rate_card +
    has_catalog_rate_card_signature
  ))
  if [ "${EMERGENCY_ROLLBACK:-0}" = "1" ] && [ "$catalog_member_count" -eq 0 ]; then
    [ "$has_metallib" -eq 1 ] || [ "$has_bundled_metallib" -eq 1 ] \
      || die 5 "$label does not contain signed MLX Metal kernels"
    log "Emergency rollback accepted a signed legacy payload without catalog assets."
  else
    [ "$has_metallib" -eq 1 ] || die 5 "$label does not contain mlx.metallib"
    [ "$has_catalog_manifest" -eq 1 ] || die 5 "$label does not contain catalog-release/release.json"
    [ "$has_catalog_keyring" -eq 1 ] || die 5 "$label does not contain catalog-release/trusted-keys.json"
    [ "$has_catalog_tier2" -eq 1 ] || die 5 "$label does not contain catalog-release/tier2-catalog.json"
    [ "$has_catalog_candidates" -eq 1 ] || die 5 "$label does not contain catalog-release/autotune-candidates.json"
    [ "$has_catalog_candidates_signature" -eq 1 ] || die 5 "$label does not contain catalog-release/autotune-candidates.json.sig"
    [ "$has_catalog_demand" -eq 1 ] || die 5 "$label does not contain catalog-release/demand-rank.json"
    [ "$has_catalog_demand_signature" -eq 1 ] || die 5 "$label does not contain catalog-release/demand-rank.json.sig"
    [ "$has_catalog_rate_card" -eq 1 ] || die 5 "$label does not contain catalog-release/rate-card.json"
    [ "$has_catalog_rate_card_signature" -eq 1 ] || die 5 "$label does not contain catalog-release/rate-card.json.sig"
    if [ "$has_compatibility_set" -ne 1 ]; then
      if [ "${EMERGENCY_ROLLBACK:-0}" = "1" ]; then
        log "Emergency rollback accepted a signed legacy payload without compatibility-set.json."
      else
        die 5 "$label does not contain compatibility-set.json"
      fi
    fi
    if [ "$has_compatibility_set" -eq 1 ]; then
      [ "$has_local_install_contract" -eq 1 ] || die 5 "$label does not contain compatibility-set-local/install.sh"
      [ "$has_local_provider_plist" -eq 1 ] || die 5 "$label does not contain the provider launchd template"
      [ "$has_local_updater_metadata" -eq 1 ] || die 5 "$label does not contain updater rollback metadata"
      [ "$has_local_watchdog_plist" -eq 1 ] || die 5 "$label does not contain the watchdog launchd template"
      [ "$has_local_watchdog_script" -eq 1 ] || die 5 "$label does not contain the watchdog script"
    fi
  fi
}

# Gatekeeper (`spctl -a -t install`) is the notarization/tamper gate and works
# offline from a stapled ticket. `xcrun stapler validate` additionally hits
# Apple's CloudKit ticket-delivery endpoint and fails closed on clock-skew or
# TLS interception even when the package is genuinely notarized — that must not
# strand a provider after Gatekeeper already accepted the asset (#1301).
STAPLER_ONLINE_LOOKUP_HINT="Couldn't complete Apple's notarization-ticket lookup (TLS/CloudKit). Check this Mac's date & time (set automatically) and any VPN/proxy/content-filter"

validate_package() {
  require_tool pkgutil
  gatekeeper_passed=0
  if command -v spctl >/dev/null 2>&1; then
    spctl -a -vv -t install "$asset_path" || die 4 "package failed Gatekeeper assessment"
    log "Package Gatekeeper assessment passed."
    gatekeeper_passed=1
  else
    log "spctl not found; package checksum was verified but Gatekeeper assessment was skipped."
  fi
  if command -v xcrun >/dev/null 2>&1 && xcrun --find stapler >/dev/null 2>&1; then
    stapler_output=""
    if stapler_output="$(xcrun stapler validate "$asset_path" 2>&1)"; then
      log "Package stapler validation passed."
    elif [ "$gatekeeper_passed" -eq 1 ]; then
      stapler_excerpt="$(
        printf '%s' "$stapler_output" \
          | tr '\n\r\t' '   ' \
          | LC_ALL=C tr -cd '[:print:] ' \
          | cut -c 1-512
      )"
      log "WARNING: stapler_validate=advisory_online_lookup_failed after Gatekeeper accepted the package; continuing. ${STAPLER_ONLINE_LOOKUP_HINT}. stapler: ${stapler_excerpt}"
    else
      die 4 "${STAPLER_ONLINE_LOOKUP_HINT}, then Retry."
    fi
  else
    if [ "$gatekeeper_passed" -eq 1 ]; then
      log "stapler not found; local package stapler validation skipped."
    else
      die 4 "couldn't verify package notarization (spctl and stapler were not found). Ensure PATH includes /usr/bin and /usr/sbin, then Retry."
    fi
  fi
}

validate_release_payload() {
  case "$asset_kind" in
    tar) validate_tarball ;;
    pkg) validate_package ;;
    *) die 5 "release asset was not selected" ;;
  esac
}

stage_release_payload() {
  staging_dir="$TMPDIR_PATH/staging"
  rm -rf "$staging_dir"
  mkdir -p "$staging_dir"

  case "$asset_kind" in
    bundled)
      stage_bundled_repair_payload
      return
      ;;
    tar)
      tar xzf "$asset_path" -C "$staging_dir" || die 5 "failed to extract release tarball"
      ;;
    pkg)
      expanded_dir="$TMPDIR_PATH/pkg-expanded"
      rm -rf "$expanded_dir"
      pkgutil --expand-full "$asset_path" "$expanded_dir" || die 5 "failed to expand release package"
      [ -d "$expanded_dir/Payload" ] || die 5 "expanded package does not contain Payload"
      payload_entries="$(cd "$expanded_dir/Payload" && find . -mindepth 1 -print)" \
        || die 5 "failed to list expanded package payload"
      validate_staged_entries "$payload_entries" "package payload"
      if find "$expanded_dir/Payload" \( -type l -o -type b -o -type c -o -type p \) -print -quit | grep -q .; then
        die 5 "package payload contains unsafe link or device members"
      fi
      cp -R "$expanded_dir/Payload/." "$staging_dir"/
      ;;
    *)
      die 5 "release asset was not selected"
      ;;
  esac
  chmod +x "$staging_dir/macprovider-cli" 2>/dev/null || true
  [ -x "$staging_dir/macprovider-cli" ] || die 5 "staged macprovider-cli is not executable"
  MACPROVIDER_CLI_EXECUTABLE="$staging_dir/macprovider-cli"
}

prepare_staged_config() {
  [ -n "$staging_dir" ] || die 5 "release payload must be staged before config preparation"
  STAGED_CONFIG_PATH="$staging_dir/config.yaml"
  STAGED_PROVIDER_ID_PATH="$staging_dir/provider_id"
  if [ "${REFERRAL_REPLACE_INCUMBENT:-0}" = "1" ] && [ "${FRESH_REFERRAL_BOOTSTRAP:-0}" -eq 1 ]; then
    log "Staging a fresh provider identity; incumbent config and CLI credential stay untouched until replacement cutover."
    CONFIG_PATH="$STAGED_CONFIG_PATH"
    PROVIDER_ID_PATH="$STAGED_PROVIDER_ID_PATH"
    return
  fi
  if [ -f "$LIVE_CONFIG_PATH" ]; then
    cp "$LIVE_CONFIG_PATH" "$STAGED_CONFIG_PATH" || die 5 "failed to stage existing provider config"
    chmod 600 "$STAGED_CONFIG_PATH" 2>/dev/null || true
  fi
  if [ -f "$LIVE_PROVIDER_ID_PATH" ]; then
    cp "$LIVE_PROVIDER_ID_PATH" "$STAGED_PROVIDER_ID_PATH" || die 5 "failed to stage existing provider identity"
    chmod 600 "$STAGED_PROVIDER_ID_PATH" 2>/dev/null || true
  fi
  CONFIG_PATH="$STAGED_CONFIG_PATH"
  PROVIDER_ID_PATH="$STAGED_PROVIDER_ID_PATH"
}

activate_staged_config() {
  if [ "${INSTALL_TX_ACTIVE:-0}" -eq 1 ] && [ -n "${INSTALL_TX_BACKUP:-}" ]; then
    assert_install_lock_ownership
  fi
  [ -n "$STAGED_CONFIG_PATH" ] && [ -f "$STAGED_CONFIG_PATH" ] \
    || die 5 "staged provider config is missing at cutover"
  mkdir -p "$CONFIG_DIR"
  config_temp="$LIVE_CONFIG_PATH.install.$$"
  cp "$STAGED_CONFIG_PATH" "$config_temp" || die 5 "failed to prepare provider config activation"
  chmod 600 "$config_temp" 2>/dev/null || true
  mv "$config_temp" "$LIVE_CONFIG_PATH" || die 5 "failed to activate provider config"
  if [ -f "$STAGED_PROVIDER_ID_PATH" ]; then
    provider_id_temp="$LIVE_PROVIDER_ID_PATH.install.$$"
    cp "$STAGED_PROVIDER_ID_PATH" "$provider_id_temp" || die 5 "failed to prepare provider identity activation"
    chmod 600 "$provider_id_temp" 2>/dev/null || true
    mv "$provider_id_temp" "$LIVE_PROVIDER_ID_PATH" || die 5 "failed to activate provider identity"
  fi
  CONFIG_PATH="$LIVE_CONFIG_PATH"
  PROVIDER_ID_PATH="$LIVE_PROVIDER_ID_PATH"
}

semantic_merge_config() {
  config_path="$1"
  model_value="$2"
  provider_id_value="$3"
  coordinator_url_value="$4"
  port_value="$5"
  enable_receipts_value="${6:-}"
  credential_store_value="${7:-}"
  auto_update_enabled_value="${8:-}"
  python3 - "$config_path" "$model_value" "$provider_id_value" "$coordinator_url_value" "$port_value" "$enable_receipts_value" "$credential_store_value" "$auto_update_enabled_value" <<'PY'
import json
import os
import re
import sys
import tempfile

path, model, provider_id, coordinator_url, port, enable_receipts, credential_store, auto_update_enabled = sys.argv[1:]
owned = {
    "coordinator_url": json.dumps(coordinator_url),
    "provider_id": json.dumps(provider_id),
    "port": str(int(port)),
}
if model:
    owned["model"] = json.dumps(model)
if enable_receipts:
    if enable_receipts != "true":
        raise SystemExit("enable_receipts installer override must be true or empty")
    owned["enable_receipts"] = "true"
if credential_store:
    if credential_store not in ("keychain", "protected_file"):
        raise SystemExit("credential_store installer override must be keychain, protected_file, or empty")
    owned["credential_store"] = credential_store
if auto_update_enabled:
    if auto_update_enabled not in ("true", "false"):
        raise SystemExit("auto_update_enabled installer override must be true, false, or empty")
    owned["auto_update_enabled"] = auto_update_enabled
try:
    with open(path, "r", encoding="utf-8") as handle:
        lines = handle.read().splitlines()
except FileNotFoundError:
    lines = []

merged = []
seen = set()
top_level_key = re.compile(r"^([A-Za-z_][A-Za-z0-9_-]*)[ \t]*:")
for line in lines:
    match = top_level_key.match(line)
    key = match.group(1) if match else None
    if key not in owned:
        merged.append(line)
        continue
    if key in seen:
        continue
    merged.append(f"{key}: {owned[key]}")
    seen.add(key)

for key in ("model", "coordinator_url", "provider_id", "port", "enable_receipts", "credential_store", "auto_update_enabled"):
    if key not in owned:
        continue
    if key not in seen:
        merged.append(f"{key}: {owned[key]}")

directory = os.path.dirname(path)
os.makedirs(directory, mode=0o700, exist_ok=True)
fd, temporary = tempfile.mkstemp(prefix=".config.yaml.merge-", dir=directory)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write("\n".join(merged) + "\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)
finally:
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
PY
}

enable_fresh_referral_receipts() {
  [ "$FRESH_REFERRAL_BOOTSTRAP" -eq 1 ] || return 0
  existing_model="$(read_config_model || true)"
  credential_store_value=""
  auto_update_enabled_value=""
  [ "${HEADLESS:-0}" = "1" ] && credential_store_value="protected_file"
  [ "${HEADLESS:-0}" = "1" ] && auto_update_enabled_value="false"
  semantic_merge_config \
    "$CONFIG_PATH" \
    "$existing_model" \
    "$provider_id" \
    "$coordinator_url" \
    "$PORT" \
    "true" \
    "$credential_store_value" \
    "$auto_update_enabled_value"
}

enforce_headless_config_overrides() {
  [ "$HEADLESS" = "1" ] || return 0
  existing_model="$(read_config_model || true)"
  semantic_merge_config \
    "$CONFIG_PATH" \
    "$existing_model" \
    "$provider_id" \
    "$coordinator_url" \
    "$PORT" \
    "" \
    "protected_file" \
    "false"
}

write_config() {
  model="$1"
  provider_id="$2"
  coordinator_url="$3"
  run mkdir -p "$CONFIG_DIR"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "Would semantic-merge provider identity, coordinator URL, and port into $CONFIG_PATH; verified autotune supplies model provenance."
    return
  fi
  provider_id_temp="$PROVIDER_ID_PATH.tmp.$$"
  printf "%s\n" "$provider_id" > "$provider_id_temp"
  chmod 600 "$provider_id_temp" 2>/dev/null || true
  mv "$provider_id_temp" "$PROVIDER_ID_PATH"
  credential_store_value=""
  auto_update_enabled_value=""
  [ "${HEADLESS:-0}" = "1" ] && credential_store_value="protected_file"
  [ "${HEADLESS:-0}" = "1" ] && auto_update_enabled_value="false"
  semantic_merge_config "$CONFIG_PATH" "$model" "$provider_id" "$coordinator_url" "$PORT" "" "$credential_store_value" "$auto_update_enabled_value"
  chmod 600 "$CONFIG_PATH" "$PROVIDER_ID_PATH" 2>/dev/null || true
}

read_config_model() {
  [ -f "$CONFIG_PATH" ] || return 1
  awk -F: '
    /^model:/ {
      value=$0
      sub(/^model:[[:space:]]*/, "", value)
      gsub(/^"|"$/, "", value)
      gsub(/\\\//, "/", value)
      print value
      exit
    }
  ' "$CONFIG_PATH"
}

read_config_provider_token_line() {
  [ -f "$CONFIG_PATH" ] || return 1
  run_macprovider_cli_with_amfi_retry credentials config-token-status --config "$CONFIG_PATH" >/dev/null \
    || return 1
  printf "provider_token: <redacted>\n"
}

scrub_config_provider_token() {
  [ -f "$CONFIG_PATH" ] || return 0
  run_macprovider_cli_with_amfi_retry credentials scrub-config-token --config "$CONFIG_PATH" >/dev/null
}

read_config_provider_id() {
  [ -f "$CONFIG_PATH" ] || return 1
  awk -F: '
    /^provider_id:/ {
      value=$0
      sub(/^provider_id:[[:space:]]*/, "", value)
      gsub(/^"|"$/, "", value)
      print value
      exit
    }
  ' "$CONFIG_PATH"
}

read_config_artifact_sha() {
  [ -f "$CONFIG_PATH" ] || return 1
  awk -F: '
    /^model_artifact_sha256:/ {
      value=$0
      sub(/^model_artifact_sha256:[[:space:]]*/, "", value)
      gsub(/^"|"$/, "", value)
      print value
      exit
    }
  ' "$CONFIG_PATH"
}

read_config_artifact_path() {
  [ -f "$CONFIG_PATH" ] || return 1
  awk -F: '
    /^model_artifact_path:/ {
      value=$0
      sub(/^model_artifact_path:[[:space:]]*/, "", value)
      gsub(/^"|"$/, "", value)
      # A quoted path (e.g. under ".../Application Support/...") may arrive with
      # JSON-escaped slashes ("\/Users\/..."). Unescape so the absolute-path
      # check (`case "$p" in /*)`) sees a real leading "/".
      gsub(/\\\//, "/", value)
      print value
      exit
    }
  ' "$CONFIG_PATH"
}

read_config_catalog_model_id() {
  [ -f "$CONFIG_PATH" ] || return 1
  awk -F: '
    /^model_catalog_model_id:/ {
      value=$0
      sub(/^model_catalog_model_id:[[:space:]]*/, "", value)
      gsub(/^"|"$/, "", value)
      gsub(/\\\//, "/", value)
      print value
      exit
    }
  ' "$CONFIG_PATH"
}

read_config_donor_mode() {
  [ -f "$CONFIG_PATH" ] || return 1
  awk -F: '
    /^donor_mode:/ {
      value=$0
      sub(/^donor_mode:[[:space:]]*/, "", value)
      gsub(/^"|"$/, "", value)
      print value
      exit
    }
  ' "$CONFIG_PATH"
}

publish_bootstrap_identity_for_rollback() {
  [ -n "${STAGED_CONFIG_PATH:-}" ] && [ "$CONFIG_PATH" = "$STAGED_CONFIG_PATH" ] \
    || return 0
  [ -z "$(read_config_provider_token_line || true)" ] \
    || die 70 "refusing to publish a bootstrap identity from a config that still contains a provider bearer"
  if [ "${REFERRAL_REPLACE_INCUMBENT:-0}" = "1" ] && [ "${FRESH_REFERRAL_BOOTSTRAP:-0}" -eq 1 ] && [ "${CUTOVER_STARTED:-0}" -eq 0 ]; then
    log "Fresh provider replacement preflight redeemed the invite without publishing candidate identity over the incumbent config."
    return 0
  fi
  # Publish only the tokenless provider principal. The CLI keeps the bearer in
  # Keychain. Recovery moves this config aside and preserves its high-entropy
  # principal, so an interrupted referral request retries against the same
  # coordinator registration instead of generating a second identity.
  assert_install_lock_ownership
  mark_install_cutover_started
  mkdir -p "$CONFIG_DIR"
  bootstrap_config_temp="$LIVE_CONFIG_PATH.bootstrap.$$"
  cp "$STAGED_CONFIG_PATH" "$bootstrap_config_temp" \
    || die 70 "could not preserve the bootstrapped provider identity for rollback"
  chmod 600 "$bootstrap_config_temp" 2>/dev/null || true
  mv "$bootstrap_config_temp" "$LIVE_CONFIG_PATH" \
    || die 70 "could not publish the bootstrapped provider identity for rollback"
  if [ -f "$STAGED_PROVIDER_ID_PATH" ]; then
    bootstrap_provider_id_temp="$LIVE_PROVIDER_ID_PATH.bootstrap.$$"
    cp "$STAGED_PROVIDER_ID_PATH" "$bootstrap_provider_id_temp" \
      || die 70 "could not preserve the bootstrapped provider identity for rollback"
    chmod 600 "$bootstrap_provider_id_temp" 2>/dev/null || true
    mv "$bootstrap_provider_id_temp" "$LIVE_PROVIDER_ID_PATH" \
      || die 70 "could not publish the bootstrapped provider identity for rollback"
  fi
}

ensure_provider_credentials() {
  local attempted_referral_bootstrap=0
  credential_already_present=0
  if [ -n "$(read_config_provider_token_line || true)" ]; then
    run_macprovider_cli_with_amfi_retry credentials import --config "$CONFIG_PATH" \
      || die 6 "provider credential migration into CLI credential custody failed"
    run_macprovider_cli_with_amfi_retry credentials verify --config "$CONFIG_PATH" \
      || die 6 "provider credential migration verification failed"
    if [ "$HEADLESS" = "1" ]; then
      scrub_config_provider_token \
        || die 6 "provider credential was imported but could not be scrubbed from headless config"
      [ -z "$(read_config_provider_token_line || true)" ] \
        || die 6 "provider credential was imported but remains in headless config"
    fi
    [ -n "${REFERRAL_CODE_SOURCE_FILE:-}" ] || return 0
    credential_already_present=1
  else
    credential_verify_rc=0
    run_macprovider_cli_with_amfi_retry credentials verify --config "$CONFIG_PATH" \
      || credential_verify_rc=$?
    case "$credential_verify_rc" in
      0)
        [ -n "${REFERRAL_CODE_SOURCE_FILE:-}" ] || return 0
        credential_already_present=1
        ;;
      3)
        if headless_acceptance_repair_mode; then
          die 6 "headless acceptance repair credential custody changed after incumbent verification; refusing to bootstrap over protected-file state"
        fi
        ;;
      *) die 6 "existing CLI Keychain credential is unavailable or invalid; refusing unsafe bootstrap" ;;
    esac
  fi
  if [ "$credential_already_present" -eq 0 ]; then
    provider_id="$(read_config_provider_id || true)"
    case "$provider_id" in
      mp-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
      *) die 6 "tokenless credential bootstrap requires a fresh high-entropy mp-* provider ID; this existing predictable ID needs an operator-issued ownership credential" ;;
    esac
    log "Acquiring first-install provider credential before evidence admission."
  else
    log "Reconciling interrupted referral bootstrap with the existing CLI-owned credential."
  fi
  referral_onboarding_dir="$CONFIG_DIR/onboarding"
  mkdir -p "$referral_onboarding_dir" \
    || die 70 "could not create durable CLI onboarding state"
  chmod 700 "$referral_onboarding_dir" \
    || die 70 "could not protect durable CLI onboarding state"
  bootstrap_auth_args=(bootstrap-auth --timeout-seconds 30 --config "$CONFIG_PATH")
  if [ -n "${REFERRAL_CODE_SOURCE_FILE:-}" ]; then
    attempted_referral_bootstrap=1
    bootstrap_auth_args+=(--referral-code-file "$REFERRAL_CODE_SOURCE_FILE")
    if [ "${REFERRAL_REPLACE_INCUMBENT:-0}" = "1" ] && [ "${FRESH_REFERRAL_BOOTSTRAP:-0}" -eq 1 ]; then
      bootstrap_auth_args+=(--replace-referral-journal)
    fi
    # The journal and Keychain credential are bound to this provider ID. Make
    # the tokenless identity rollback-durable before the request can redeem the
    # referral and persist a bearer, including abrupt response-loss exits.
    if [ "$credential_already_present" -eq 0 ]; then
      publish_bootstrap_identity_for_rollback
    fi
  fi
  bootstrap_auth_rc=0
  run_macprovider_cli_with_amfi_retry "${bootstrap_auth_args[@]}" || bootstrap_auth_rc=$?
  case "$bootstrap_auth_rc" in
    0) ;;
    20|21|22|23|24|25|26|27)
      # Stable referral outcomes are part of the Malibu/installer/CLI
      # capability contract. Preserve them through transaction rollback so
      # Malibu can render a truthful, recoverable state without log scraping.
      exit "$bootstrap_auth_rc"
      ;;
    *) die 6 "provider credential bootstrap failed before evidence admission" ;;
  esac
  run_macprovider_cli_with_amfi_retry credentials verify --config "$CONFIG_PATH" \
    || die 6 "provider credential bootstrap completed without restart-safe CLI custody"
  if [ "$attempted_referral_bootstrap" -eq 1 ]; then
    REFERRAL_BOOTSTRAP_COMPLETED=1
    REFERRAL_CODE_SOURCE_FILE=""
    CREATED_REFERRAL_CODE_SOURCE_FILE=0
    return 0
  fi
  if [ -z "${REFERRAL_CODE_SOURCE_FILE:-}" ]; then
    # Non-referral bootstrap cannot redeem admission before it returns, so keep
    # the existing post-success publication boundary.
    publish_bootstrap_identity_for_rollback
  fi
}

ensure_replacement_referral_preflight_before_cutover() {
  [ "${REFERRAL_REPLACE_INCUMBENT:-0}" = "1" ] || return 0
  [ "${FRESH_REFERRAL_BOOTSTRAP:-0}" -eq 1 ] || return 0
  persist_replacement_candidate_provider_id
  [ "${REFERRAL_BOOTSTRAP_COMPLETED:-0}" -eq 0 ] || return 0
  log "Validating the fresh-provider invite before stopping the incumbent provider."
  ensure_provider_credentials
}

ensure_headless_acceptance_credentials_before_cutover() {
  headless_acceptance_repair_mode || return 0
  ensure_provider_credentials
}

submit_required_hardware_evidence() {
  log "Submitting the exact stored autotune evidence before provider service start."
  run_macprovider_cli_with_amfi_retry autotune --recommend --freshness-check \
    --submit-hardware-evidence --require-hardware-evidence --config "$CONFIG_PATH" >/dev/null \
    || die 6 "authenticated hardware evidence admission failed before service start"
}

select_autotune_benchmark_port() {
  requested="${MACPROVIDER_AUTOTUNE_PORT:-}"
  if [ -n "$requested" ]; then
    validate_port_value "$requested"
    [ "$requested" != "$PORT" ] || die 7 "autotune benchmark port must differ from live provider port $PORT"
    if lsof -nP -iTCP:"$requested" -sTCP:LISTEN -t 2>/dev/null | grep -q .; then
      die 7 "autotune benchmark port $requested is already in use"
    fi
    AUTOTUNE_BENCHMARK_PORT="$requested"
    return
  fi

  candidate=19080
  while [ "$candidate" -le 19179 ]; do
    if [ "$candidate" != "$PORT" ] && ! lsof -nP -iTCP:"$candidate" -sTCP:LISTEN -t 2>/dev/null | grep -q .; then
      AUTOTUNE_BENCHMARK_PORT="$candidate"
      return
    fi
    candidate=$((candidate + 1))
  done
  die 7 "no free autotune benchmark port is available in 19080-19179"
}

run_autotune_recommend_apply() {
  if [ "$DRY_RUN" -eq 1 ]; then
    log "Would run paid-yield recommendation before service start."
    return 0
  fi
  if [ ! -x "${MACPROVIDER_CLI_EXECUTABLE:-$INSTALL_DIR/macprovider-cli}" ]; then
    die 5 "staged macprovider-cli missing before autotune recommendation"
  fi
  autotune_candidate_args=()
  upgrade_candidate_model_id="${AUTOTUNE_UPGRADE_CANDIDATE_MODEL_ID:-}"
  if [ -n "$upgrade_candidate_model_id" ]; then
    [ -n "${AUTOTUNE_PREFETCH_RECEIPT_PATH:-}" ] \
      && [ -f "$AUTOTUNE_PREFETCH_RECEIPT_PATH" ] \
      && [ ! -L "$AUTOTUNE_PREFETCH_RECEIPT_PATH" ] \
      || die 6 "upgrade benchmark lacks its private prefetch receipt; the staged release will not acquire artifacts after cutover"
    autotune_candidate_args=(
      --candidate-models "$upgrade_candidate_model_id"
      --prefetch-receipt "$AUTOTUNE_PREFETCH_RECEIPT_PATH"
    )
  fi
  # A fresh Mac's very first benchmark can run cold or under thermal throttling
  # and transiently under-report sustained TPS, sinking an otherwise-eligible
  # paid model (#1269). Concluding "no paid model" from a single such sample
  # strands a capable Mac in donor mode. Re-benchmark a bounded number of times,
  # with a short cooldown, before falling back to donor. Overridable for tests.
  recommend_max_attempts="${MACPROVIDER_RECOMMEND_MAX_ATTEMPTS:-3}"
  recommend_retry_sleep="${MACPROVIDER_RECOMMEND_RETRY_SLEEP_SECONDS:-8}"
  # Sanitize the overrides: a non-integer value must not break the numeric
  # comparison or turn `sleep` into a set -e abort that skips the donor path.
  # Fall back to defaults on anything non-integer, and clamp to sane bounds so
  # a huge attempt count cannot pin the installer in the recommendation phase.
  case "$recommend_max_attempts" in ''|*[!0-9]*) recommend_max_attempts=3 ;; esac
  if [ "$recommend_max_attempts" -lt 1 ]; then recommend_max_attempts=3; fi
  if [ "$recommend_max_attempts" -gt 10 ]; then recommend_max_attempts=10; fi
  case "$recommend_retry_sleep" in ''|*[!0-9]*) recommend_retry_sleep=8 ;; esac
  if [ "$recommend_retry_sleep" -gt 60 ]; then recommend_retry_sleep=60; fi
  recommend_attempt=1
  while : ; do
    if [ "$recommend_attempt" -eq 1 ]; then
      log "Running paid-yield recommendation before service start."
    else
      log "Re-running paid-yield recommendation (attempt $recommend_attempt of $recommend_max_attempts)."
    fi
    if ! run_macprovider_cli_with_amfi_retry autotune --recommend --apply \
      ${autotune_candidate_args[@]+"${autotune_candidate_args[@]}"} \
      --port "${AUTOTUNE_BENCHMARK_PORT:-19080}" --config "$CONFIG_PATH" --no-submit-hardware-evidence; then
      die 6 "autotune recommendation failed before service start"
    fi
    recommended_model="$(read_config_model || true)"
    artifact_path="$(read_config_artifact_path || true)"
    artifact_sha="$(read_config_artifact_sha || true)"
    if [ -n "$recommended_model" ] && [ -n "$artifact_path" ] && [ -n "$artifact_sha" ]; then
      case "$artifact_path" in
        /*)
          log "Configuration applied. Start the provider with: macprovider-cli serve"
          if prompt_yes_no "Start provider now with $recommended_model? [Y/n]" "Y"; then
            model="$recommended_model"
            log "Recommendation selected verified model: $model (artifact: $artifact_path)"
            ensure_provider_credentials
            submit_required_hardware_evidence
            return 0
          fi
          SKIP_PROVIDER_START=1
          log "Provider start declined. macprovider-cli is installed, but the provider service will not be started."
          return 0
          ;;
      esac
    fi
    if [ "$recommend_attempt" -lt "$recommend_max_attempts" ]; then
      log "No paid model cleared on attempt $recommend_attempt of $recommend_max_attempts; re-benchmarking after a short cooldown in case the first benchmark was cold or thermally throttled."
      recommend_attempt=$((recommend_attempt + 1))
      sleep "$recommend_retry_sleep"
      continue
    fi
    break
  done
  log "No paid model currently clears rate-card or hardware requirements on this Mac."
  # #1289: the app / non-interactive install path must NOT silently commit a
  # provider that will not start — that strands the app on a half-install it
  # cannot recover (the "install_committed_without_start" wedge). Fail loudly
  # here instead: the EXIT trap rolls the transaction back cleanly (nothing is
  # committed), and the caller (Malibu) surfaces a real choice — retry, or
  # explicitly opt into donor mode with MACPROVIDER_DONOR_MODE=1. Interactive
  # installs keep the explicit donor prompt; every non-interactive install (app
  # and headless) fails loudly unless donor mode was explicitly requested, so a
  # fleet install can never silently idle as a false success either.
  donor_requested=0
  if [ "${MACPROVIDER_DONOR_MODE:-0}" = "1" ]; then
    log "Donor mode explicitly requested (MACPROVIDER_DONOR_MODE=1)."
    donor_requested=1
  elif [ "${NO_PROMPT:-0}" = "1" ]; then
    die 30 "no paid model recommendation cleared after ${recommend_max_attempts} attempts; provider not started and nothing committed (retry, or set MACPROVIDER_DONOR_MODE=1 to run as donor)"
  elif prompt_yes_no "Enable donor mode? [y/N]" "N"; then
    donor_requested=1
  fi
  if [ "$donor_requested" = "1" ]; then
    log "Applying donor-mode configuration."
    run_macprovider_cli_with_amfi_retry autotune --recommend --apply --donor-mode \
      ${autotune_candidate_args[@]+"${autotune_candidate_args[@]}"} \
      --port "${AUTOTUNE_BENCHMARK_PORT:-19080}" --config "$CONFIG_PATH" --no-submit-hardware-evidence \
      || die 6 "donor-mode recommendation failed before service start"
    recommended_model="$(read_config_model || true)"
    artifact_path="$(read_config_artifact_path || true)"
    artifact_sha="$(read_config_artifact_sha || true)"
    if [ -n "$recommended_model" ] && [ -n "$artifact_path" ] && [ -n "$artifact_sha" ]; then
      case "$artifact_path" in
        /*)
          model="$recommended_model"
          log "Donor mode selected verified model: $model (artifact: $artifact_path)"
          SKIP_PROVIDER_START=1
          log "Donor-mode configuration applied. Provider service will not be started automatically."
          return 0
          ;;
      esac
    fi
    die 6 "donor mode did not apply a verified local model artifact before service start"
  fi
  SKIP_PROVIDER_START=1
  log "Donor mode declined. macprovider-cli is installed, but the provider service will not be started."
  return 0
}

# Returns 0 when an owned macprovider-cli process is currently LISTENing on
# $PORT. INSTALL_TX_SERVICE_WAS_ACTIVE only reflects the launchd snapshot, so a
# manually started provider (macprovider-cli serve) is invisible to it; this
# mirrors the executable-ownership check in ensure_port_free so the empty
# signed-catalog-id fall-through stays fail-closed for manual live providers.
own_macprovider_cli_holds_live_port() {
  local holding_pids holding_pid holding_executable
  holding_pids="$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null || true)"
  [ -n "$holding_pids" ] || return 1
  for holding_pid in $holding_pids; do
    holding_executable="$(lsof -a -p "$holding_pid" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1)"
    if provider_executable_owned_for_current_mode "$holding_executable"; then
      return 0
    fi
  done
  return 1
}

prefetch_upgrade_autotune_model() {
  upgrade_candidate_model_id="${AUTOTUNE_UPGRADE_CANDIDATE_MODEL_ID:-}"
  if [ "${REFERRAL_REPLACE_INCUMBENT:-0}" = "1" ] && [ "${FRESH_REFERRAL_BOOTSTRAP:-0}" -eq 1 ]; then
    log "Fresh provider replacement requested; skipping incumbent-model prefetch and running full fresh recommendation."
    return 0
  fi
  [ "$EXISTING_INSTALL_WAS_PRESENT" -eq 1 ] || return 0
  if [ -z "$upgrade_candidate_model_id" ]; then
    # The prior install carries no signed-catalog model identity, so it was
    # never a verified paid provider: donor-mode, never-started, or a
    # minimally-seeded config left by an interrupted first run (e.g. a Malibu
    # "Retry" after the first attempt installed files but did not start a
    # provider). If a provider is actually running -- either a launchd service
    # (INSTALL_TX_SERVICE_WAS_ACTIVE) or a manually started macprovider-cli
    # holding the live port -- we still fail closed rather than stop a live
    # earner for a blind re-tune. Otherwise there is no live provider to
    # protect, so fall through to a full fresh recommendation instead of
    # dead-ending the retry loop (die 6).
    # A stale repair label may still be loaded after its executable was
    # removed. In that narrow, evidence-gated repair mode the label is not
    # proof that a provider is serving; the live-port ownership check is the
    # stronger guard against stopping an actual earner. Normal upgrades keep
    # the historical fail-closed behavior for any loaded provider label.
    if { [ "${INSTALL_TX_SERVICE_WAS_ACTIVE:-0}" -eq 1 ] && [ "${REPAIR_EXISTING_INSTALL:-0}" -ne 1 ]; } \
      || own_macprovider_cli_holds_live_port; then
      die 6 "active provider lacks an exact signed-catalog model identity; the active provider was not stopped"
    fi
    log "Existing install has no verified signed-catalog model and no live provider; running a full fresh recommendation."
    return 0
  fi
  AUTOTUNE_PREFETCH_RECEIPT_PATH="$staging_dir/autotune-prefetch-receipt.json"
  log "Prefetching and verifying the installed model's exact signed artifact while the current provider remains available."
  run_macprovider_cli_with_amfi_retry autotune --recommend --prefetch \
    --candidate-models "$upgrade_candidate_model_id" \
    --prefetch-receipt "$AUTOTUNE_PREFETCH_RECEIPT_PATH" \
    --config "$CONFIG_PATH" --no-submit-hardware-evidence >/dev/null \
    || die 6 "installed model artifact prefetch failed; the active provider was not stopped"
  [ -f "$AUTOTUNE_PREFETCH_RECEIPT_PATH" ] && [ ! -L "$AUTOTUNE_PREFETCH_RECEIPT_PATH" ] \
    || die 6 "installed model artifact prefetch did not produce a private receipt; the active provider was not stopped"
  log "Installed model artifact is locally verified; upgrade benchmarking is limited to $upgrade_candidate_model_id."
}

use_fresh_recommendation_if_available() {
  if [ "$DRY_RUN" -eq 1 ]; then
    return 1
  fi
  if [ ! -x "$MACPROVIDER_CLI_EXECUTABLE" ] || [ ! -f "$CONFIG_PATH" ]; then
    return 1
  fi

  if run_macprovider_cli_with_amfi_retry autotune --recommend --freshness-check --no-submit-hardware-evidence --config "$CONFIG_PATH" >/dev/null; then
    enforce_headless_config_overrides
    ensure_provider_credentials
    submit_required_hardware_evidence
    recommended_model="$(read_config_model || true)"
    artifact_path="$(read_config_artifact_path || true)"
    artifact_sha="$(read_config_artifact_sha || true)"
    donor_mode="$(read_config_donor_mode || true)"
    if [ "$donor_mode" = "true" ]; then
      SKIP_PROVIDER_START=1
      log "Stored donor-mode recommendation is fresh; provider service will not be started automatically."
      return 0
    fi
    if [ -n "$recommended_model" ] && [ -n "$artifact_path" ] && [ -n "$artifact_sha" ]; then
      case "$artifact_path" in
        /*)
          model="$recommended_model"
          log "Stored paid-yield recommendation is fresh; skipping re-tune."
          log "Using verified model from existing config: $model (artifact: $artifact_path)"
          return 0
          ;;
      esac
    fi
    log "Stored recommendation is fresh but config lacks a verified local model; re-running recommendation."
    return 1
  else
    rc=$?
    if [ "$rc" -eq 10 ]; then
      log "Stored recommendation is stale or missing; running recommendation."
      return 1
    fi
    die 6 "recommendation freshness check failed before service start"
  fi
}

install_binary() {
  if [ "${INSTALL_TX_ACTIVE:-0}" -eq 1 ] && [ -n "${INSTALL_TX_BACKUP:-}" ]; then
    assert_install_lock_ownership
  fi
  run mkdir -p "$BIN_DIR" "$INSTALL_DIR"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "Would install macprovider-cli to $BINARY_PATH"
    log "Would keep release support files in $INSTALL_DIR"
    return
  fi
  if [ -z "$staging_dir" ] || [ ! -x "$staging_dir/macprovider-cli" ]; then
    stage_release_payload
  fi

  # CRITICAL: mlx-swift loads Metal kernels from mlx.metallib and/or
  # .bundle directories adjacent to the binary. We install the REAL binary
  # into $INSTALL_DIR alongside those resources, then place a symlink at
  # $BINARY_PATH so PATH users + the launchd plist still find it via the canonical
  # SPEC-003 FR-C2 location (~/.local/bin/macprovider-cli).
  # Prior v1.2.1 install separated them and Metal failed with
  # "library not found" at runtime.
  real_binary="$INSTALL_DIR/macprovider-cli"
  atomic_replace_provider_binary "$staging_dir/macprovider-cli" "$real_binary" \
    || die 5 "could not atomically activate the verified provider binary"

  # Metal resources live alongside the real binary (where mlx-swift looks).
  rm -f "$INSTALL_DIR/mlx.metallib"
  if [ -f "$staging_dir/mlx.metallib" ]; then
    cp "$staging_dir/mlx.metallib" "$INSTALL_DIR/mlx.metallib"
  fi
  rm -f "$INSTALL_DIR/THIRD-PARTY-NOTICES.txt"
  if [ -f "$staging_dir/THIRD-PARTY-NOTICES.txt" ]; then
    cp "$staging_dir/THIRD-PARTY-NOTICES.txt" "$INSTALL_DIR/THIRD-PARTY-NOTICES.txt"
  fi
  rm -f "$INSTALL_DIR/compatibility-set.json"
  if [ -f "$staging_dir/compatibility-set.json" ]; then
    cp "$staging_dir/compatibility-set.json" "$INSTALL_DIR/compatibility-set.json"
  elif [ "${EMERGENCY_ROLLBACK:-0}" != "1" ]; then
    die 5 "staged provider release is missing compatibility-set.json"
  fi
  rm -rf "$INSTALL_DIR/compatibility-set-local"
  if [ -d "$staging_dir/compatibility-set-local" ]; then
    cp -R "$staging_dir/compatibility-set-local" "$INSTALL_DIR/compatibility-set-local"
  elif [ "${EMERGENCY_ROLLBACK:-0}" != "1" ]; then
    die 5 "staged provider release is missing compatibility-set-local"
  fi
  find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 -name '*.bundle' -exec rm -rf {} +
  find "$staging_dir" -mindepth 1 -maxdepth 1 -name '*.bundle' -exec cp -R {} "$INSTALL_DIR"/ \;
  rm -rf "$INSTALL_DIR/catalog-release"
  if [ -d "$staging_dir/catalog-release" ]; then
    cp -R "$staging_dir/catalog-release" "$INSTALL_DIR/catalog-release"
  elif [ "${EMERGENCY_ROLLBACK:-0}" != "1" ]; then
    die 5 "staged provider release is missing catalog-release"
  fi

  # Atomic symlink swap at the canonical path.
  rm -f "$BINARY_PATH"
  ln -s "$real_binary" "$BINARY_PATH"

  [ -x "$real_binary" ] || die 5 "macprovider-cli was not installed at $real_binary"
  [ -L "$BINARY_PATH" ] || die 5 "symlink not created at $BINARY_PATH"

  # Malibu-branded alias (#1261): additive `malibu-cli` symlink so the branded
  # command works from first install -- before the provider ever serves, and
  # even if admission recovery guidance is shown first. Points at the canonical
  # entrypoint ($BINARY_PATH), which install/convergence keep current, so the
  # alias never needs re-pointing. Create-only: only when the path is empty, so
  # an unrelated user file/symlink at that path is never clobbered. Best-effort
  # -- never fail the install on the alias.
  if [ ! -e "$ALIAS_BINARY_PATH" ] && [ ! -L "$ALIAS_BINARY_PATH" ]; then
    ln -s "$BINARY_PATH" "$ALIAS_BINARY_PATH" 2>/dev/null || true
  fi
  MACPROVIDER_CLI_EXECUTABLE="$real_binary"
  if [ "${EMERGENCY_ROLLBACK:-0}" = "1" ]; then
    record_lifecycle_state rollback_in_progress signed_emergency_rollback_activated \
      || die 5 "failed to persist emergency rollback lifecycle state"
  else
    record_lifecycle_state installing signed_compatibility_set_activated \
      || die 5 "failed to persist install lifecycle state"
  fi
}

check_install_dir_clean() {
  if [ ! -d "$INSTALL_DIR" ]; then
    return 0
  fi
  local entries
  # F-603-V7-7: warn on mixed-state directories such as leftover Python
  # virtualenvs, but do not block an otherwise valid partner upgrade.
  entries=$(ls -A "$INSTALL_DIR" 2>/dev/null | grep -vE '^(macprovider-cli(\.v[0-9.]+\.bak)?|mlx\.metallib|THIRD-PARTY-NOTICES\.txt|compatibility-set\.json|compatibility-set-local|catalog-release|.*\.bundle)$' | head -20 || true)
  if [ -n "$entries" ]; then
    log "WARNING: $INSTALL_DIR contains non-macprovider entries:"
    while IFS= read -r entry; do
      log "  - $entry"
    done <<EOF
$entries
EOF
    log "These will not be modified by install.sh, but you may want"
    log "to clean up the directory after the upgrade. Continuing..."
  fi
}

check_path_hint() {
  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) log "$BIN_DIR is not in PATH; use $BINARY_PATH directly or add ~/.local/bin to PATH." ;;
  esac
}

clear_quarantine() {
  quarantine_path="${1:-$INSTALL_DIR}"
  if ! command -v xattr >/dev/null 2>&1; then
    log "xattr not found; skipping quarantine cleanup."
    return
  fi
  if [ "${asset_kind:-}" = "pkg" ]; then
    log "Package release passed Gatekeeper assessment; quarantine cleanup is not required."
    return
  fi
  if [ "${asset_kind:-}" = "bundled" ]; then
    log "Malibu.app bundled provider CLI does not require GitHub quarantine cleanup."
    return
  fi
  log "Tarball release may carry a quarantine attribute. Clearing it lets macOS run the staged CLI."
  if prompt_yes_no "Clear quarantine attribute on the verified staged release? [Y/n]" "Y"; then
    run xattr -dr com.apple.quarantine "$quarantine_path"
  else
    die 7 "user declined quarantine cleanup"
  fi
}

write_atomic_install_file() {
  destination_path="$1"
  destination_mode="${2:-0600}"
  python3 - "$destination_path" "$destination_mode" 3<&0 <<'PY'
import os
import stat
import sys
import ctypes
import errno

destination_path, destination_mode = sys.argv[1:]
payload = bytearray()
while len(payload) <= 1024 * 1024:
    chunk = os.read(3, 65536)
    if not chunk:
        break
    payload.extend(chunk)
if len(payload) > 1024 * 1024:
    raise SystemExit("atomic install file is oversized")
parent_path = os.path.dirname(destination_path)
destination_name = os.path.basename(destination_path)
directory_fd = os.open(
    parent_path,
    os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0),
)
directory_info = os.fstat(directory_fd)


def verify_no_extended_acl(descriptor, label):
    if sys.platform != "darwin":
        return
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        acl_get_fd_np = libc.acl_get_fd_np
        acl_get_fd_np.argtypes = [ctypes.c_int, ctypes.c_int]
        acl_get_fd_np.restype = ctypes.c_void_p
        acl_free = libc.acl_free
        acl_free.argtypes = [ctypes.c_void_p]
        acl_free.restype = ctypes.c_int
    except (AttributeError, OSError):
        raise SystemExit("atomic install file ACL API is unavailable")
    ctypes.set_errno(0)
    acl = acl_get_fd_np(descriptor, 0x00000100)  # ACL_TYPE_EXTENDED
    if acl:
        acl_free(acl)
        raise SystemExit("%s has an extended ACL" % label)
    if ctypes.get_errno() != errno.ENOENT:
        raise SystemExit("%s ACL verification failed" % label)


if (
    not stat.S_ISDIR(directory_info.st_mode)
    or directory_info.st_uid != os.getuid()
    or directory_info.st_nlink < 1
    or directory_info.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
):
    os.close(directory_fd)
    raise SystemExit("atomic install file parent is unsafe")
verify_no_extended_acl(directory_fd, "atomic install file parent")

temporary_name = ".%s.install-%s" % (destination_name, os.urandom(16).hex())
flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
temporary_fd = None

try:
    temporary_fd = os.open(temporary_name, flags, 0o600, dir_fd=directory_fd)
    try:
        os.fchmod(temporary_fd, int(destination_mode, 8) & ~0o022)
        written = 0
        while written < len(payload):
            progress = os.write(temporary_fd, payload[written:])
            if progress <= 0:
                raise SystemExit("atomic install file write made no progress")
            written += progress
        verify_no_extended_acl(temporary_fd, "atomic install file temporary")
        os.fsync(temporary_fd)
    finally:
        os.close(temporary_fd)
        temporary_fd = None
    os.replace(
        temporary_name,
        destination_name,
        src_dir_fd=directory_fd,
        dst_dir_fd=directory_fd,
    )
    temporary_name = None
    os.fsync(directory_fd)
    verify_fd = os.open(
        destination_name,
        os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
        dir_fd=directory_fd,
    )
    try:
        info = os.fstat(verify_fd)
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != os.getuid()
            or info.st_nlink != 1
            or info.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
            or info.st_size != len(payload)
        ):
            raise SystemExit("atomic install file verification failed")
        verify_no_extended_acl(verify_fd, "atomic install file destination")
        if os.read(verify_fd, len(payload) + 1) != payload:
            raise SystemExit("atomic install file contents changed")
    finally:
        os.close(verify_fd)
finally:
    if temporary_fd is not None:
        os.close(temporary_fd)
    if temporary_name is not None:
        try:
            os.unlink(temporary_name, dir_fd=directory_fd)
        except FileNotFoundError:
            pass
    os.close(directory_fd)
PY
}

install_plist() {
  if [ "${INSTALL_TX_ACTIVE:-0}" -eq 1 ]; then
    assert_install_lock_ownership
  fi
  model="$1"
  provider_id="$2"
  coordinator_url="$3"
  if [ "$NO_LAUNCHD" = "1" ]; then
    log "Skipping launchd service install (MACPROVIDER_NO_LAUNCHD=1 expert/debug override)."
    return
  fi
  if [ "$HEADLESS" = "1" ]; then
    log "Installing as a headless LaunchDaemon for fleet user $HEADLESS_USER."
  else
    log "Installing as a background launchd service."
  fi

  run mkdir -p "$(dirname "$PLIST_PATH")" "$LOG_DIR"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "Would render launchd plist to $PLIST_PATH"
    log "Would enable launchd service: launchctl enable $LAUNCHD_DOMAIN/$PROVIDER_LABEL"
    log "Would bootstrap with: launchctl bootstrap $LAUNCHD_DOMAIN $PLIST_BOOTSTRAP_PATH"
    return
  fi

  reclaim_launchd_service "$PROVIDER_LABEL" \
    || die 5 "could not reclaim existing provider launchd service"
  reclaim_legacy_launchd_service "$LEGACY_PROVIDER_LABEL" "$LEGACY_PLIST_BOOTSTRAP_PATH" "$INSTALL_DIR/macprovider-cli" "$BINARY_PATH" \
    || die 5 "could not reclaim legacy provider launchd service"
  render_plist "$model" "$provider_id" "$coordinator_url" \
    | write_atomic_install_file "$PLIST_PATH" \
    || die 5 "could not publish rendered launchd plist safely"

  plutil -lint "$PLIST_PATH" >/dev/null || die 5 "rendered launchd plist is invalid"
  if [ "${INSTALL_TX_ACTIVE:-0}" -eq 1 ] && [ -n "${INSTALL_TX_BACKUP:-}" ]; then
    write_install_tx_marker "$INSTALL_TX_BACKUP/provider-service-created" \
      || die 70 "could not durably record the provider launchd mutation"
  fi
  publish_launchd_plist "$PLIST_PATH" "$PLIST_BOOTSTRAP_PATH" \
    "$PROVIDER_LABEL" "$INSTALL_DIR/macprovider-cli" \
    || die 5 "failed to publish launchd service plist"
  launchctl_service enable "$LAUNCHD_DOMAIN/$PROVIDER_LABEL" || die 5 "failed to enable launchd service"
  launchctl_service bootstrap "$LAUNCHD_DOMAIN" "$PLIST_BOOTSTRAP_PATH" || die 5 "failed to load launchd service"
  LAUNCHD_INSTALLED=1
}

render_plist() {
  user_home="$(xml_escape "$HOME")"
  install_prefix="$(xml_escape "$INSTALL_DIR")"
  config_path="$(xml_escape "$CONFIG_PATH")"
  protected_credential_root="$(xml_escape "$CONFIG_DIR/protected-credentials")"
  # F-603-V7-4: launchd must invoke the real binary path, not the
  # ~/.local/bin symlink, so Swift Bundle resolution finds adjacent bundles.
  binary_path="$(xml_escape "$INSTALL_DIR/macprovider-cli")"
  log_dir="$(xml_escape "$LOG_DIR")"
  credential_store="keychain"
  launchd_user_entry=""
  keepalive_entry="  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>"
  if [ "$HEADLESS" = "1" ]; then
    credential_store="protected_file"
    launchd_user_entry="  <key>UserName</key>
  <string>$(xml_escape "$HEADLESS_USER")</string>"
    keepalive_entry="  <key>KeepAlive</key>
  <true/>"
  fi
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>live.malibu.provider</string>
$launchd_user_entry
  <key>ProgramArguments</key>
  <array>
    <string>$binary_path</string>
    <string>serve</string>
    <string>--config</string>
    <string>$config_path</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
$keepalive_entry
  <key>StandardOutPath</key>
  <string>$log_dir/macprovider.out.log</string>
  <key>StandardErrorPath</key>
  <string>$log_dir/macprovider.err.log</string>
  <key>WorkingDirectory</key>
  <string>$install_prefix</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>$user_home</string>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$user_home/.local/bin</string>
    <key>MACPROVIDER_CONFIG</key>
    <string>$config_path</string>
    <key>MACPROVIDER_CREDENTIAL_STORE</key>
    <string>$credential_store</string>
    <key>MACPROVIDER_PROTECTED_CREDENTIAL_ROOT</key>
    <string>$protected_credential_root</string>
    <key>MACPROVIDER_HEADLESS</key>
    <string>$HEADLESS</string>
    <key>MACPROVIDER_HEADLESS_USER</key>
    <string>$(xml_escape "$HEADLESS_USER")</string>
    <key>MACPROVIDER_LAUNCHD_DOMAIN</key>
    <string>$LAUNCHD_DOMAIN</string>
  </dict>
  <key>ThrottleInterval</key>
  <integer>10</integer>
  <key>ProcessType</key>
  <string>Adaptive</string>
</dict>
</plist>
EOF
}

# Issue #191: write the inlined watchdog.sh to disk.
#
# IMPORTANT: the body below must stay byte-identical (after comment
# / blank-line normalization) with `ops/macprovider-watchdog/watchdog.sh`.
# `scripts/test-watchdog-inline-drift.sh` enforces this in CI.
write_watchdog_script() {
  write_atomic_install_file "$WATCHDOG_PATH" 0755 <<'WATCHDOG_EOF'
#!/usr/bin/env bash
# macprovider-watchdog: local provider liveness monitor.
#
# Health verdict: the exact launchd service PID must own the configured local
# listener and its /v1/health endpoint must answer. /v1/health returns non-2xx
# for degraded/draining/unavailable states, so a provider stuck reporting
# unavailable after the watchdog is armed is restartable. Coordinator TCP
# reachability is advisory logging only; a missing ESTABLISHED coordinator
# connection no longer causes a kick by itself. Update and rollback
# transactions are resolved by their installer/CLI owner, not by this watchdog.

set -euo pipefail

LABEL="${MACPROVIDER_WATCHDOG_LABEL:-live.malibu.provider}"
CONFIG_PATH="${MACPROVIDER_CONFIG_PATH:-$HOME/.config/macprovider/config.yaml}"
BINARY_PATH="${MACPROVIDER_BINARY_PATH:-$HOME/macprovider/macprovider-cli}"
LIFECYCLE_LEASE_PATH="${MACPROVIDER_LIFECYCLE_LEASE_PATH:-$HOME/Library/Application Support/macprovider/lifecycle/lease.json}"
LIFECYCLE_LEASE_OWNER_UID="${MACPROVIDER_LIFECYCLE_LEASE_OWNER_UID:-$(id -u)}"
COORDINATOR_HOST="${MACPROVIDER_COORDINATOR_HOST:-coordinator.malibu.tech}"
COORDINATOR_PORT="${MACPROVIDER_COORDINATOR_PORT:-443}"
LOG_DIR="${MACPROVIDER_LOG_DIR:-$HOME/Library/Logs/macprovider}"
LOG_PATH="$LOG_DIR/watchdog.log"
# Issue #191 R1 architect HIGH: arming + grace state. Without
# these, a first-time install can spin in a restart loop — the
# Swift CLI loads the model BEFORE connecting to the coordinator
# (cold-cache model load is 10-20 minutes), and a watchdog that
# kicks on "no ESTABLISHED connection" would Darwin.exit the
# process every 60s before it ever opens its socket.
#
# Arming rule: the watchdog stays disarmed (no kicks) until it
# observes at least ONE successful local health response IN THE
# CURRENT BOOT. The armed marker stores the boot id so a reboot —
# which restarts the provider into a fresh cold-cache model load —
# re-disarms the watchdog and prevents stale-arming restart loops.
#
# Grace rule: after we observe a restart-worthy failure, we wait at least KICK_GRACE_SECONDS
# before logging another restart request. This covers the post-restart model-reload
# window without re-triggering on the gap between launchd respawn
# and re-establishing the coordinator socket.
STATE_DIR="${MACPROVIDER_WATCHDOG_STATE_DIR:-$HOME/.local/share/macprovider-watchdog/state}"
ARMED_FILE="$STATE_DIR/armed"
LAST_KICK_FILE="$STATE_DIR/last_kick"
KICK_GRACE_SECONDS="${MACPROVIDER_WATCHDOG_KICK_GRACE_SECONDS:-300}"
case "$KICK_GRACE_SECONDS" in
  ''|*[!0-9]*) KICK_GRACE_SECONDS=300 ;;
esac
if [ "$KICK_GRACE_SECONDS" -lt 60 ] || [ "$KICK_GRACE_SECONDS" -gt 3600 ]; then
  KICK_GRACE_SECONDS=300
fi

mkdir -p "$LOG_DIR" "$STATE_DIR"

# Boot id: per-boot identifier sourced from kern.bootsessionuuid.
# Apple-provided UUID is immutable for the lifetime of a single
# boot (verified against XNU sysctl: read-only). Unlike
# kern.boottime, this value is NOT affected by NTP / manual
# wall-clock time correction (R3 architect MEDIUM #1), so a
# clock-set event during a wedge cannot silently re-disarm the
# watchdog and let the wedge persist.
current_boot_id() {
  sysctl -n kern.bootsessionuuid 2>/dev/null
}

# Acceptable formats in config.yaml are: `provider_id: ID` (yaml
# key) or `provider-id: ID` (alternate hyphenated form some operator
# tools have written historically). Either matches and surfaces the
# value with surrounding whitespace stripped.
read_provider_id() {
  if [ ! -f "$CONFIG_PATH" ]; then
    return 1
  fi
  awk '
    /^[[:space:]]*provider[_-]id[[:space:]]*:/ {
      sub(/^[^:]*:[[:space:]]*/, "")
      sub(/[[:space:]]*#.*$/, "")
      sub(/[[:space:]]+$/, "")
      gsub(/^["'\'']|["'\'']$/, "")
      print
      exit
    }
  ' "$CONFIG_PATH"
}

read_config_port() {
  if [ ! -f "$CONFIG_PATH" ]; then
    return 1
  fi
  awk '
    /^[[:space:]]*port[[:space:]]*:/ {
      sub(/^[^:]*:[[:space:]]*/, "")
      sub(/[[:space:]]*#.*$/, "")
      sub(/[[:space:]]+$/, "")
      print
      exit
    }
  ' "$CONFIG_PATH"
}

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() { printf "[%s] %s\n" "$(ts)" "$*" >> "$LOG_PATH"; }
LAUNCHD_DOMAIN="${MACPROVIDER_LAUNCHD_DOMAIN:-gui/$(id -u)}"

launchctl_run() {
  launchctl_bin="${MACPROVIDER_LAUNCHCTL:-launchctl}"
  if [ "$LAUNCHD_DOMAIN" = "system" ]; then
    launchctl_bin="/bin/launchctl"
  fi
  "$launchctl_bin" "$@"
}

launchd_service_target() {
  printf "%s/%s" "$LAUNCHD_DOMAIN" "$LABEL"
}

resolve_coordinator_ip() {
  # First try dscacheutil (no network call if already cached);
  # fall back to host(1) which most macs have via bind-utils.
  ip="$(dscacheutil -q host -a name "$COORDINATOR_HOST" 2>/dev/null \
        | awk '/^ip_address:/ { print $2; exit }')"
  if [ -z "$ip" ] && command -v host >/dev/null 2>&1; then
    ip="$(host -t A "$COORDINATOR_HOST" 2>/dev/null \
          | awk '/has address/ { print $4; exit }')"
  fi
  printf "%s" "${ip:-}"
}

has_established_conn() {
  ip="$1"
  if [ -z "$ip" ]; then
    return 1
  fi
  # BSD netstat on macOS: print ESTABLISHED TCP rows; awk matches
  # the foreign-address column against our coordinator IP:port.
  # Format: Proto Recv-Q Send-Q Local-Address Foreign-Address (state)
  netstat -an -p tcp 2>/dev/null \
    | awk -v target="${ip}.${COORDINATOR_PORT}" '
        $0 ~ /ESTABLISHED/ && $5 == target { found = 1; exit }
        END { exit found ? 0 : 1 }
      '
}

provider_process_pid() {
  service_target="$(launchd_service_target)"
  if ! service_output="$(launchctl_run print "$service_target" 2>/dev/null)"; then
    return 1
  fi
  candidates="$(printf "%s\n" "$service_output" | awk 'NF == 3 && $1 == "pid" && $2 == "=" && $3 ~ /^[0-9]+$/ { print $3 }')"
  [ "$(printf "%s\n" "$candidates" | awk 'NF { count++ } END { print count + 0 }')" -eq 1 ] || return 1
  candidate="$candidates"
  expected="$BINARY_PATH"
  if command -v realpath >/dev/null 2>&1 && [ -e "$expected" ]; then
    expected="$(realpath "$expected" 2>/dev/null || printf "%s" "$expected")"
  fi
  command -v lsof >/dev/null 2>&1 || return 1
  executable_output="$(lsof -a -p "$candidate" -d txt -Fn 2>/dev/null)" || return 1
  command_paths="$(printf "%s\n" "$executable_output" | awk 'substr($0, 1, 1) == "n" && length($0) > 1 { print substr($0, 2) }')"
  found_expected=""
  while IFS= read -r command_path; do
    [ -n "$command_path" ] || continue
    if command -v realpath >/dev/null 2>&1 && [ -e "$command_path" ]; then
      command_path="$(realpath "$command_path" 2>/dev/null || printf "%s" "$command_path")"
    fi
    if [ "$command_path" = "$expected" ]; then
      found_expected=1
      break
    fi
  done <<EOF
$command_paths
EOF
  [ "$found_expected" = 1 ] || return 1
  printf "%s" "$candidate"
}

local_health_listener_owned_by_provider() {
  provider_pid="$1"
  port="$2"
  if ! command -v lsof >/dev/null 2>&1; then
    return 1
  fi
  lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null | awk -v pid="$provider_pid" '$1 == pid { found = 1 } END { exit found ? 0 : 1 }'
}

local_provider_health_ok() {
  provider_pid="$1"
  port="$(read_config_port || true)"
  case "$port" in
    ''|*[!0-9]*) return 1 ;;
  esac
  local_health_listener_owned_by_provider "$provider_pid" "$port" || return 1
  curl_bin="${MACPROVIDER_CURL:-/usr/bin/curl}"
  "$curl_bin" -fsS --max-time 2 "http://127.0.0.1:${port}/v1/health" >/dev/null 2>&1
}

local_status_restart_recommended() {
  provider_pid="$1"
  port="$(read_config_port || true)"
  case "$port" in
    ''|*[!0-9]*) return 1 ;;
  esac
  if ! local_health_listener_owned_by_provider "$provider_pid" "$port"; then
    return 0
  fi
  curl_bin="${MACPROVIDER_CURL:-/usr/bin/curl}"
  status_body="$("$curl_bin" -fsS --max-time 2 "http://127.0.0.1:${port}/v1/status" 2>/dev/null)" || return 1
  STATUS_BODY="$status_body" python3 <<'PY'
import json
import os
import sys

try:
    body = json.loads(os.environ.get("STATUS_BODY", ""))
except Exception:
    sys.exit(1)

lifecycle = body.get("lifecycle")
if not isinstance(lifecycle, dict):
    sys.exit(1)

operator_paused = lifecycle.get("operator_paused")
if not isinstance(operator_paused, bool):
    sys.exit(1)

if operator_paused or lifecycle.get("state") == "paused_by_operator":
    sys.exit(1)

sys.exit(0 if body.get("status") == "unavailable" else 1)
PY
}

valid_lifecycle_lease() {
  provider_pid="$1"
  if valid_lifecycle_lease_record startup "$provider_pid"; then
    return 0
  fi
  valid_lifecycle_lease_record maintenance ""
}

valid_unbound_lifecycle_lease() {
  if valid_lifecycle_lease_record startup ""; then
    return 0
  fi
  valid_lifecycle_lease_record maintenance ""
}

valid_lifecycle_lease_record() {
  expected_kind="$1"
  expected_pid="${2:-}"
  boot_id="$(current_boot_id || true)"
  [ -n "$boot_id" ] || return 1
  /usr/bin/python3 - \
    "$LIFECYCLE_LEASE_PATH" \
    "$LIFECYCLE_LEASE_OWNER_UID" \
    "$boot_id" \
    "$expected_kind" \
    "$expected_pid" \
    "$BINARY_PATH" <<'PY'
import ctypes
import json
import os
import stat
import sys
import time

def current_monotonic_ns():
    if hasattr(time, "clock_gettime_ns") and hasattr(time, "CLOCK_MONOTONIC_RAW"):
        return time.clock_gettime_ns(time.CLOCK_MONOTONIC_RAW)
    sys.exit(1)

class ProcBsdInfo(ctypes.Structure):
    _fields_ = [
        ("pbi_flags", ctypes.c_uint32),
        ("pbi_status", ctypes.c_uint32),
        ("pbi_xstatus", ctypes.c_uint32),
        ("pbi_pid", ctypes.c_uint32),
        ("pbi_ppid", ctypes.c_uint32),
        ("pbi_uid", ctypes.c_uint32),
        ("pbi_gid", ctypes.c_uint32),
        ("pbi_ruid", ctypes.c_uint32),
        ("pbi_rgid", ctypes.c_uint32),
        ("pbi_svuid", ctypes.c_uint32),
        ("pbi_svgid", ctypes.c_uint32),
        ("rfu_1", ctypes.c_uint32),
        ("pbi_comm", ctypes.c_char * 16),
        ("pbi_name", ctypes.c_char * 32),
        ("pbi_nfiles", ctypes.c_uint32),
        ("pbi_pgid", ctypes.c_uint32),
        ("pbi_pjobc", ctypes.c_uint32),
        ("pbi_e_tdev", ctypes.c_uint32),
        ("pbi_e_tpgid", ctypes.c_uint32),
        ("pbi_nice", ctypes.c_int32),
        ("pbi_start_tvsec", ctypes.c_uint64),
        ("pbi_start_tvusec", ctypes.c_uint64),
    ]

def live_process_identity(pid):
    try:
        libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
        proc_pidinfo = libproc.proc_pidinfo
        proc_pidinfo.argtypes = [
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_uint64,
            ctypes.c_void_p,
            ctypes.c_int,
        ]
        proc_pidinfo.restype = ctypes.c_int
        info = ProcBsdInfo()
        count = proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info))
        path_buffer = ctypes.create_string_buffer(4096)
        proc_pidpath = libproc.proc_pidpath
        proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        proc_pidpath.restype = ctypes.c_int
        path_count = proc_pidpath(pid, path_buffer, ctypes.sizeof(path_buffer))
    except Exception:
        return None
    if count != ctypes.sizeof(info) or path_count <= 0:
        return None
    start = int(info.pbi_start_tvsec) * 1_000_000 + int(info.pbi_start_tvusec)
    if start <= 0:
        return None
    executable_path = path_buffer.value.decode("utf-8", "surrogateescape")
    if not executable_path.startswith("/"):
        return None
    return {
        "start_us": start,
        "uid": int(info.pbi_uid),
        "ruid": int(info.pbi_ruid),
        "executable_path": os.path.realpath(executable_path),
    }

path, owner_uid_text, boot_id, expected_kind, expected_pid_text, binary_path = sys.argv[1:]
try:
    owner_uid = int(owner_uid_text)
except ValueError:
    sys.exit(1)
try:
    expected_pid = int(expected_pid_text) if expected_pid_text else None
except ValueError:
    sys.exit(1)

try:
    st = os.lstat(path)
    if (
        not stat.S_ISREG(st.st_mode)
        or stat.S_ISLNK(st.st_mode)
        or st.st_uid != owner_uid
        or st.st_nlink != 1
        or stat.S_IMODE(st.st_mode) != 0o600
        or st.st_size <= 0
        or st.st_size > 16 * 1024
    ):
        sys.exit(1)
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path, flags)
except OSError:
    sys.exit(1)

try:
    opened = os.fstat(fd)
    if (
        not stat.S_ISREG(opened.st_mode)
        or opened.st_uid != owner_uid
        or opened.st_nlink != 1
        or stat.S_IMODE(opened.st_mode) != 0o600
        or (opened.st_dev, opened.st_ino) != (st.st_dev, st.st_ino)
        or opened.st_size != st.st_size
    ):
        sys.exit(1)
    data = os.read(fd, 16 * 1024 + 1)
finally:
    os.close(fd)

if len(data) != st.st_size or len(data) > 16 * 1024:
    sys.exit(1)
try:
    record = json.loads(data.decode("utf-8"))
except Exception:
    sys.exit(1)
if not isinstance(record, dict):
    sys.exit(1)

kind = record.get("kind")
if kind != expected_kind or kind not in {"startup", "maintenance"}:
    sys.exit(1)
owner = record.get("owner")
if not isinstance(owner, dict):
    sys.exit(1)
owner_pid = owner.get("pid")
owner_start = owner.get("process_start_us")
owner_boot = owner.get("boot_session")
if (
    record.get("version") != 1
    or not isinstance(owner_pid, int)
    or isinstance(owner_pid, bool)
    or owner_pid <= 0
    or not isinstance(owner_start, int)
    or isinstance(owner_start, bool)
    or owner_start <= 0
    or not isinstance(owner_boot, str)
    or not owner_boot
    or len(owner_boot.encode("utf-8")) > 256
    or owner_boot != boot_id
):
    sys.exit(1)
if expected_pid is not None and owner_pid != expected_pid:
    sys.exit(1)
try:
    os.kill(owner_pid, 0)
except OSError:
    sys.exit(1)
identity = live_process_identity(owner_pid)
if (
    identity is None
    or identity.get("start_us") != owner_start
    or identity.get("uid") != owner_uid
    or identity.get("ruid") != owner_uid
    or identity.get("executable_path") != os.path.realpath(binary_path)
):
    sys.exit(1)

maximum_ms = 30 * 60 * 1000 if kind == "startup" else 20 * 60 * 1000
fields = (
    "issued_wall_ms",
    "expires_wall_ms",
    "issued_monotonic_ns",
    "expires_monotonic_ns",
)
values = {}
for field in fields:
    value = record.get(field)
    if not isinstance(value, int) or isinstance(value, bool):
        sys.exit(1)
    values[field] = value
wall_duration = values["expires_wall_ms"] - values["issued_wall_ms"]
monotonic_duration = values["expires_monotonic_ns"] - values["issued_monotonic_ns"]
if (
    values["issued_wall_ms"] <= 0
    or values["issued_monotonic_ns"] < 0
    or wall_duration <= 0
    or wall_duration > maximum_ms
    or monotonic_duration != wall_duration * 1_000_000
):
    sys.exit(1)
now_wall_ms = int(time.time() * 1000)
now_monotonic_ns = current_monotonic_ns()
if (
    now_wall_ms < values["issued_wall_ms"]
    or now_monotonic_ns < values["issued_monotonic_ns"]
    or now_wall_ms >= values["expires_wall_ms"]
    or now_monotonic_ns >= values["expires_monotonic_ns"]
):
    sys.exit(1)
sys.exit(0)
PY
}

provider_restart_cooldown_active() {
  if [ ! -f "$LAST_KICK_FILE" ]; then
    return 1
  fi
  last_kick="$(cat "$LAST_KICK_FILE" 2>/dev/null || printf 0)"
  case "$last_kick" in
    ''|*[!0-9]*) return 1 ;;
  esac
  elapsed=$(( $(now_epoch) - last_kick ))
  [ "$elapsed" -lt "$KICK_GRACE_SECONDS" ]
}

kickstart_provider() {
  reason="$1"
  service_target="$(launchd_service_target)"
  if launchctl_run kickstart -k "$service_target" >/dev/null 2>&1; then
    if ! now_epoch > "$LAST_KICK_FILE"; then
      log "provider restart cooldown write failed for $LABEL reason=${reason}"
    fi
    log "provider restart requested for $LABEL via launchctl kickstart -k reason=${reason}"
    return 0
  else
    status="$?"
    log "provider restart request failed for $LABEL via launchctl kickstart -k reason=${reason} exit_status=${status}"
    return 1
  fi
}

now_epoch() { date -u +%s; }

autoupdate_recovery_tick() {
  state_root="${MACPROVIDER_AUTOUPDATE_STATE_ROOT:-$HOME/.local/share/macprovider/autoupdate}"
  pending_path="$state_root/pending.json"
  if [ ! -e "$pending_path" ] && [ ! -L "$pending_path" ]; then
    return 0
  fi
  log "autoupdate recovery deferred: pending marker exists; transaction owner must resolve update/rollback state"
}

autoupdate_recovery_supported() {
  [ "${MACPROVIDER_HEADLESS:-0}" != "1" ] || return 1
  [ "${MACPROVIDER_LAUNCHD_DOMAIN:-}" != "system" ] || return 1
  return 0
}

main() {
  if autoupdate_recovery_supported; then
    autoupdate_recovery_tick
  else
    log "autoupdate recovery skipped: unsupported_install_topology profile=headless_fleet"
  fi
  pid="$(read_provider_id || true)"
  if [ -z "$pid" ]; then
    # Provider not yet installed / configured. Stay silent; if the
    # operator installs later we'll start working on the next tick.
    exit 0
  fi
  provider_pid="$(provider_process_pid || true)"
  if [ -z "$provider_pid" ]; then
    log "provider process unhealthy: launchd service $LABEL has no validated PID at $BINARY_PATH"
    if valid_unbound_lifecycle_lease; then
      log "launchd service $LABEL has no validated PID but is inside a validated startup/maintenance lease; watchdog grants bounded grace"
      exit 0
    fi
    if ! provider_restart_cooldown_active; then
      kickstart_provider "missing_validated_pid" || true
    fi
    exit 0
  fi
  boot_id="$(current_boot_id)"
  if ! local_provider_health_ok "$provider_pid"; then
    if valid_lifecycle_lease "$provider_pid"; then
      log "provider process $provider_pid is inside a validated startup/maintenance lease; watchdog grants bounded grace"
      exit 0
    fi
    armed_boot=""
    if [ -f "$ARMED_FILE" ]; then
      armed_boot="$(cat "$ARMED_FILE" 2>/dev/null || true)"
    fi
    if [ "$armed_boot" != "$boot_id" ]; then
      log "provider process $provider_pid not locally healthy yet; watchdog remains disarmed for boot=${boot_id}"
      exit 0
    fi
    if provider_restart_cooldown_active; then
      exit 0
    fi
    if ! local_status_restart_recommended "$provider_pid"; then
      log "provider process $provider_pid failed local /v1/health after arming, but /v1/status does not recommend watchdog restart; leaving process untouched"
      exit 0
    fi
    log "provider process $provider_pid failed local /v1/health after arming; requesting launchd restart for $LABEL"
    kickstart_provider "local_health_failed_after_arming" || true
    exit 0
  fi
  armed_boot=""
  if [ -f "$ARMED_FILE" ]; then
    armed_boot="$(cat "$ARMED_FILE" 2>/dev/null || true)"
  fi
  if [ "$armed_boot" != "$boot_id" ]; then
    log "arming watchdog (boot=${boot_id}): first observed local provider health"
    printf "%s" "$boot_id" > "$ARMED_FILE"
  fi
  coord_ip="$(resolve_coordinator_ip)"
  if [ -z "$coord_ip" ]; then
    log "warning: DNS resolution for $COORDINATOR_HOST failed; provider process $provider_pid is locally healthy"
    exit 0
  fi
  if has_established_conn "$coord_ip"; then
    # Healthy. Stay silent so the log file does not bloat.
    exit 0
  fi
  log "warning: provider process $provider_pid is locally healthy, but no ESTABLISHED TCP to ${coord_ip}:${COORDINATOR_PORT}"
  # No ESTABLISHED connection. Coordinator TCP state is advisory only:
  # the health verdict is the installed provider process plus local
  # /v1/health. Do not kick solely because another process can or
  # cannot reach the coordinator.
  exit 0
}

main "$@"
WATCHDOG_EOF
}

render_watchdog_plist() {
  watchdog_path="$(xml_escape "${WATCHDOG_BOOTSTRAP_PATH:-$WATCHDOG_PATH}")"
  user_home="$(xml_escape "$HOME")"
  watchdog_log_dir="$LOG_DIR"
  watchdog_state_environment_entry=""
  if [ "$HEADLESS" = "1" ]; then
    watchdog_log_dir="${HEADLESS_WATCHDOG_LOG_DIR:-/Library/Logs/macprovider}"
    watchdog_state_environment_entry="    <key>MACPROVIDER_WATCHDOG_STATE_DIR</key>
    <string>$(xml_escape "${HEADLESS_WATCHDOG_STATE_DIR:-/Library/Application Support/macprovider/watchdog-state}")</string>"
  fi
  log_dir="$(xml_escape "$watchdog_log_dir")"
  config_path="$(xml_escape "$CONFIG_PATH")"
  binary_path="$(xml_escape "$INSTALL_DIR/macprovider-cli")"
  protected_credential_root="$(xml_escape "$CONFIG_DIR/protected-credentials")"
  coord_host="$(xml_escape "$(printf "%s" "$1" | sed -E 's#^wss?://##; s#/.*##')")"
  credential_store="keychain"
  watchdog_search_path="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  launchctl_environment_entry=""
  lifecycle_lease_environment_entry=""
  if [ "$HEADLESS" = "1" ]; then
    credential_store="protected_file"
    watchdog_search_path="/usr/bin:/bin:/usr/sbin:/sbin"
    launchctl_environment_entry="    <key>MACPROVIDER_LAUNCHCTL</key>
    <string>/bin/launchctl</string>"
    lifecycle_lease_environment_entry="    <key>MACPROVIDER_LIFECYCLE_LEASE_PATH</key>
    <string>$(xml_escape "$LIFECYCLE_LEASE_PATH")</string>
    <key>MACPROVIDER_LIFECYCLE_LEASE_OWNER_UID</key>
    <string>$(id -u)</string>"
  fi
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$WATCHDOG_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$watchdog_path</string>
  </array>
  <key>StartInterval</key>
  <integer>60</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$log_dir/watchdog.out.log</string>
  <key>StandardErrorPath</key>
  <string>$log_dir/watchdog.err.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>$user_home</string>
    <key>PATH</key>
    <!-- Issue #191 R4 architect HIGH: include /usr/sbin and /sbin
         so the watchdog finds sysctl + netstat under launchd's
         minimal PATH. -->
    <string>$watchdog_search_path</string>
    <key>MACPROVIDER_WATCHDOG_LABEL</key>
    <string>live.malibu.provider</string>
    <key>MACPROVIDER_CONFIG_PATH</key>
    <string>$config_path</string>
    <key>MACPROVIDER_BINARY_PATH</key>
    <string>$binary_path</string>
    <key>MACPROVIDER_PROVIDER_PLIST_PATH</key>
    <string>$(xml_escape "$PLIST_BOOTSTRAP_PATH")</string>
    <key>MACPROVIDER_CREDENTIAL_STORE</key>
    <string>$credential_store</string>
    <key>MACPROVIDER_PROTECTED_CREDENTIAL_ROOT</key>
    <string>$protected_credential_root</string>
${lifecycle_lease_environment_entry}
    <key>MACPROVIDER_COORDINATOR_HOST</key>
    <string>$coord_host</string>
    <key>MACPROVIDER_LOG_DIR</key>
    <string>$log_dir</string>
$watchdog_state_environment_entry
    <key>MACPROVIDER_HEADLESS</key>
    <string>$HEADLESS</string>
    <key>MACPROVIDER_HEADLESS_USER</key>
    <string>$(xml_escape "$HEADLESS_USER")</string>
    <key>MACPROVIDER_LAUNCHD_DOMAIN</key>
    <string>$LAUNCHD_DOMAIN</string>
$launchctl_environment_entry
  </dict>
  <key>ProcessType</key>
  <string>Background</string>
</dict>
</plist>
EOF
}

# Issue #191: install the LaunchAgent watchdog. Idempotent (same
# bootout-before-bootstrap pattern as install_plist).
install_watchdog() {
  coordinator_url="$1"
  if [ "$NO_WATCHDOG" = "1" ]; then
    log "Skipping watchdog install (MACPROVIDER_NO_WATCHDOG=1)."
    return
  fi
  if [ "$NO_LAUNCHD" = "1" ]; then
    log "Skipping watchdog install (MACPROVIDER_NO_LAUNCHD=1)."
    return
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    log "Would write watchdog to $WATCHDOG_PATH and bootstrap $WATCHDOG_LABEL"
    return
  fi
  if [ "${INSTALL_TX_ACTIVE:-0}" -eq 1 ]; then
    assert_install_lock_ownership
  fi
  if [ "$HEADLESS" = "1" ]; then
    log "Installing watchdog LaunchDaemon for fleet user $HEADLESS_USER."
  else
    log "Installing watchdog LaunchAgent (operator-visibility safety net for iss-189-class wedges)."
  fi
  mkdir -p "$WATCHDOG_DIR" "$(dirname "$WATCHDOG_PLIST_PATH")"
  if [ "$HEADLESS" = "1" ]; then
    "${SUDO_BIN:-/usr/bin/sudo}" -n /bin/mkdir -p \
      "${HEADLESS_WATCHDOG_LOG_DIR:-/Library/Logs/macprovider}" \
      "${HEADLESS_WATCHDOG_STATE_DIR:-/Library/Application Support/macprovider/watchdog-state}" \
      "$(dirname "${WATCHDOG_BOOTSTRAP_PATH:-$WATCHDOG_PATH}")" \
      || die 5 "could not create root watchdog directories"
    "${SUDO_BIN:-/usr/bin/sudo}" -n /bin/chmod 0755 \
      "${HEADLESS_WATCHDOG_LOG_DIR:-/Library/Logs/macprovider}" \
      "${HEADLESS_WATCHDOG_STATE_DIR:-/Library/Application Support/macprovider/watchdog-state}" \
      "$(dirname "${WATCHDOG_BOOTSTRAP_PATH:-$WATCHDOG_PATH}")" \
      || die 5 "could not protect root watchdog directories"
  else
    mkdir -p "$LOG_DIR"
  fi
  reclaim_launchd_service "$WATCHDOG_LABEL" \
    || die 5 "could not reclaim existing watchdog launchd service"
  reclaim_legacy_launchd_service "$LEGACY_WATCHDOG_LABEL" "$LEGACY_WATCHDOG_PLIST_BOOTSTRAP_PATH" "$WATCHDOG_PATH" "$WATCHDOG_DIR/watchdog.sh" \
    || die 5 "could not reclaim legacy watchdog launchd service"
  legacy_watchdog="$WATCHDOG_DIR/watchdog.sh"
  if [ -f "$legacy_watchdog" ] && [ "$legacy_watchdog" != "$WATCHDOG_PATH" ]; then
    rm -f "$legacy_watchdog"
  fi
  write_watchdog_script
  if [ "$HEADLESS" = "1" ]; then
    watchdog_payload_b64="$(python3 - "$WATCHDOG_PATH" <<'PY'
import base64
import sys

with open(sys.argv[1], "rb") as handle:
    sys.stdout.write(base64.b64encode(handle.read()).decode("ascii"))
PY
)" || die 5 "could not snapshot rendered watchdog script"
    publish_root_file_from_base64 "${WATCHDOG_BOOTSTRAP_PATH:-$WATCHDOG_PATH}" 0755 "$watchdog_payload_b64" \
      || die 5 "could not publish root-owned watchdog script"
    verify_published_launchd_payload "${WATCHDOG_BOOTSTRAP_PATH:-$WATCHDOG_PATH}" "$watchdog_payload_b64" \
      || die 5 "published root-owned watchdog script does not match rendered script"
  fi
  render_watchdog_plist "$coordinator_url" \
    | write_atomic_install_file "$WATCHDOG_PLIST_PATH" \
    || die 5 "could not publish rendered watchdog plist safely"
  plutil -lint "$WATCHDOG_PLIST_PATH" >/dev/null \
    || die 5 "rendered watchdog plist is invalid"
  if [ "${INSTALL_TX_ACTIVE:-0}" -eq 1 ] && [ -n "${INSTALL_TX_BACKUP:-}" ]; then
    write_install_tx_marker "$INSTALL_TX_BACKUP/watchdog-service-created" \
      || die 70 "could not durably record the watchdog launchd mutation"
  fi
  publish_launchd_plist "$WATCHDOG_PLIST_PATH" "$WATCHDOG_PLIST_BOOTSTRAP_PATH" \
    "$WATCHDOG_LABEL" "${WATCHDOG_BOOTSTRAP_PATH:-$WATCHDOG_PATH}" \
    || die 5 "failed to publish watchdog launchd plist"
  launchctl_service enable "$LAUNCHD_DOMAIN/$WATCHDOG_LABEL" \
    || die 5 "failed to enable watchdog launchd service"
  launchctl_service bootstrap "$LAUNCHD_DOMAIN" "$WATCHDOG_PLIST_BOOTSTRAP_PATH" \
    || die 5 "failed to load watchdog launchd service"
  WATCHDOG_INSTALLED=1
  log "Watchdog installed. Logs at $LOG_DIR/watchdog.log."
}

write_install_manifest() {
  if [ "${INSTALL_TX_ACTIVE:-0}" -eq 1 ]; then
    assert_install_lock_ownership
  fi
  version="${1:-unknown}"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "Would write install manifest to $MANIFEST_PATH"
    return
  fi
  mkdir -p "$MANIFEST_DIR"
  labels_json="[]"
  if [ "$LAUNCHD_INSTALLED" -eq 1 ] && [ "$WATCHDOG_INSTALLED" -eq 1 ]; then
    labels_json='["live.malibu.provider","live.malibu.provider-watchdog"]'
  elif [ "$LAUNCHD_INSTALLED" -eq 1 ]; then
    labels_json='["live.malibu.provider"]'
  elif [ "$WATCHDOG_INSTALLED" -eq 1 ]; then
    labels_json='["live.malibu.provider-watchdog"]'
  fi
  write_atomic_install_file "$MANIFEST_PATH" 0600 <<EOF
{
  "install_profile": $(json_escape "$([ "$HEADLESS" = "1" ] && printf headless_fleet || printf consumer_user)"),
  "launchd_domain": $(json_escape "$LAUNCHD_DOMAIN"),
  "headless_user": $(json_escape "$HEADLESS_USER"),
  "provider_config_root": $(json_escape "$CONFIG_DIR"),
  "provider_state_root": $(json_escape "$HOME/.local/share/macprovider"),
  "install_prefix": $(json_escape "$INSTALL_DIR"),
  "binary_path": $(json_escape "$INSTALL_DIR/macprovider-cli"),
  "symlink_path": $(json_escape "$BINARY_PATH"),
  "launchd_labels": $labels_json,
  "launchd_plists": [
    $(json_escape "$PLIST_PATH"),
    $(json_escape "$WATCHDOG_PLIST_PATH")
  ],
  "data_dirs": [
    $(json_escape "$INSTALL_DIR"),
    $(json_escape "$LOG_DIR"),
    $(json_escape "$WATCHDOG_DIR")
  ],
  "version": $(json_escape "$version")
}
EOF
}

start_manual_service() {
  [ "$LAUNCHD_INSTALLED" -eq 1 ] && return
  if [ "${INSTALL_TX_ACTIVE:-0}" -eq 1 ]; then
    assert_install_lock_ownership
  fi
  log "Starting macprovider-cli directly for non-launchd self-test."
  mkdir -p "$LOG_DIR"
  (
    cd "$INSTALL_DIR"
    # F-603-V7-4: direct background self-test also invokes the real binary
    # so MLX resolves adjacent Metal resources.
    nohup "$INSTALL_DIR/macprovider-cli" \
      serve \
      --config "$CONFIG_PATH" \
      > "$LOG_DIR/macprovider.out.log" \
      2> "$LOG_DIR/macprovider.err.log" &
    echo "$!"
  ) > "$TMPDIR_PATH/manual.pid"
  MANUAL_PID="$(cat "$TMPDIR_PATH/manual.pid")"
  if [ "$INSTALL_TX_ACTIVE" -eq 1 ]; then
    printf '%s\n' "$MANUAL_PID" | write_atomic_install_file "$INSTALL_TX_BACKUP/new-manual.pid" 0600 \
      || die 70 "could not durably record the manual provider process for rollback"
  fi
}

cache_size_kb() {
  path="$1"
  if [ -d "$path" ]; then
    du -sk "$path" 2>/dev/null | awk '{ print $1 }'
  else
    printf "0"
  fi
}

format_kb_gib() {
  kb="$1"
  awk -v kb="$kb" 'BEGIN { printf "%.1f", kb / 1048576 }'
}

progress_bar() {
  percent="$1"
  width=20
  filled=$(( percent * width / 100 ))
  bar=""
  i=0
  while [ "$i" -lt "$width" ]; do
    if [ "$i" -lt "$filled" ]; then
      bar="${bar}#"
    else
      bar="${bar}."
    fi
    i=$((i + 1))
  done
  printf "[%s]" "$bar"
}

model_download_estimate_gb() {
  model="$1"
  estimate="$(known_weight_gb_for_model "$model")"
  if [ -z "$estimate" ]; then
    estimate="$(estimate_weights_gb_from_name "$model")"
  fi
  printf "%s" "${estimate:-0}"
}

model_cache_is_warm() {
  current_kb="$1"
  estimate_gb="$2"
  if [ "$estimate_gb" -le 0 ]; then
    return 0
  fi
  estimate_kb=$(( estimate_gb * 1048576 ))
  warm_threshold_kb=$(( estimate_kb * 80 / 100 ))
  [ "$current_kb" -ge "$warm_threshold_kb" ]
}

print_model_download_progress() {
  cache_path="$1"
  estimate_gb="$2"
  elapsed="$3"
  previous_kb="$4"
  current_kb="$(cache_size_kb "$cache_path")"
  delta_kb=$(( current_kb - previous_kb ))
  [ "$delta_kb" -lt 0 ] && delta_kb=0

  if [ "$estimate_gb" -gt 0 ] && [ "$current_kb" -gt 0 ]; then
    estimate_kb=$(( estimate_gb * 1048576 ))
    percent=$(( current_kb * 100 / estimate_kb ))
    [ "$percent" -gt 99 ] && percent=99
    bar="$(progress_bar "$percent")"
    current_gib="$(format_kb_gib "$current_kb")"
    delta_gib="$(format_kb_gib "$delta_kb")"
    log "Model download ${bar} ${current_gib}/${estimate_gb} GiB (${percent}%, +${delta_gib} GiB; ${elapsed}s elapsed)."
  elif [ "$current_kb" -gt 0 ]; then
    current_gib="$(format_kb_gib "$current_kb")"
    delta_gib="$(format_kb_gib "$delta_kb")"
    log "Model download cache: ${current_gib} GiB (+${delta_gib} GiB; ${elapsed}s elapsed)."
  else
    log "Waiting for model download to start (${elapsed}s elapsed)."
  fi
  MODEL_PROGRESS_CACHE_KB="$current_kb"
}

wait_for_local_model() {
  model="$1"
  # F-603-V7-5: first install can take much longer if MLX has to download a
  # multi-GB model. Keep warm-cache installs at 5 minutes; allow cold-cache
  # installs 20 minutes with visible progress.
  local cache_check="$HOME/.cache/huggingface/hub/models--${model//\//--}"
  start_ts="$(date +%s)"
  estimate_gb="$(model_download_estimate_gb "$model")"
  previous_cache_kb="$(cache_size_kb "$cache_check")"
  if [ -d "$cache_check" ] && model_cache_is_warm "$previous_cache_kb" "$estimate_gb"; then
    deadline=$(( start_ts + 300 ))
    next_progress=$(( start_ts + 15 ))
    if [ "$estimate_gb" -gt 0 ]; then
      log "Waiting up to 5 min for local /v1/models (model cache detected; expected weights ~${estimate_gb} GiB)."
    else
      log "Waiting up to 5 min for local /v1/models (model cache detected)."
    fi
  elif [ -d "$cache_check" ]; then
    deadline=$(( start_ts + 1200 ))
    next_progress=$(( start_ts + 15 ))
    cache_gib="$(format_kb_gib "$previous_cache_kb")"
    if [ "$estimate_gb" -gt 0 ]; then
      log "Waiting up to 20 min for local /v1/models (partial model cache detected: ${cache_gib}/${estimate_gb} GiB; continuing download for ${model})."
    else
      log "Waiting up to 20 min for local /v1/models (model cache detected but may still be downloading ${model})."
    fi
  else
    deadline=$(( start_ts + 1200 ))
    next_progress=$(( start_ts + 15 ))
    if [ "$estimate_gb" -gt 0 ]; then
      log "Waiting up to 20 min for local /v1/models (first-time install; downloading ${model} ~${estimate_gb} GiB)."
    else
      log "Waiting up to 20 min for local /v1/models (first-time install; downloading ${model})."
    fi
  fi
  port_seen=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    raw_models_json="$(curl -sS --max-time 3 "http://127.0.0.1:${PORT}/v1/models" 2>/dev/null || true)"
    # The Swift JSON encoder emits forward-slashes as \/ (legal per RFC 8259
    # but cosmetically ugly). Normalize so grep -Fq "$model" matches whether
    # the encoder emits / or \/.
    models_json="$(printf "%s" "$raw_models_json" | sed 's|\\/|/|g')"
    if [ -n "$models_json" ] && [ "$port_seen" -eq 0 ]; then
      port_seen=1
      elapsed=$(( $(date +%s) - start_ts ))
      log "Port ${PORT} is listening (after ${elapsed}s). Waiting for model load..."
    fi
    if printf "%s" "$models_json" | grep -q '"owned_by"[[:space:]]*:[[:space:]]*"macprovider"' &&
       printf "%s" "$models_json" | grep -Fq "$model"; then
      return 0
    fi
    now="$(date +%s)"
    if [ "$now" -ge "$next_progress" ]; then
      elapsed=$(( now - start_ts ))
      if [ "$port_seen" -eq 0 ]; then
        log "Still waiting for macprovider-cli to bind port ${PORT} (${elapsed}s elapsed)..."
        print_model_download_progress "$cache_check" "$estimate_gb" "$elapsed" "$previous_cache_kb"
        previous_cache_kb="$MODEL_PROGRESS_CACHE_KB"
      else
        log "Model still loading (${elapsed}s elapsed; first run may still be downloading from Hugging Face)..."
        print_model_download_progress "$cache_check" "$estimate_gb" "$elapsed" "$previous_cache_kb"
        previous_cache_kb="$MODEL_PROGRESS_CACHE_KB"
      fi
      next_progress=$(( now + 15 ))
    fi
    sleep 2
  done
  return 1
}

print_local_self_test_diagnostics() {
  # F-603-V7-6: distinguish a timeout from a proven binary failure and leave
  # the user with concrete checks for process, download, and stderr state.
  log ""
  log "==========================================================="
  log "Self-test timeout reached. THIS DOES NOT NECESSARILY MEAN"
  log "THE BINARY FAILED. macprovider-cli is likely still loading"
  log "the model in the background."
  log ""
  log "To check if the binary is alive:"
  log "  ps aux | grep macprovider-cli | grep -v grep"
  log ""
  log "To check if the model is still downloading:"
  log "  du -sh ~/.cache/huggingface/hub/"
  log "  (run twice 30s apart; growing = downloading)"
  log ""
  log "To check for errors:"
  log "  tail -30 $LOG_DIR/macprovider.err.log"
  log ""
  log "Once the binary fully loads, it joins the pool. You can"
  log "verify from the coordinator side via /v1/pool/check (see docs)."
  log "==========================================================="
  log ""

  raw_response="$(curl -sS --max-time 3 "http://127.0.0.1:${PORT}/v1/models" 2>/dev/null || true)"
  if [ -n "$raw_response" ]; then
    log "Raw /v1/models response (first 200 bytes):"
    printf "  %.200s\n" "$raw_response"
    return
  fi

  log "/v1/models did not respond. Binary may not have bound port ${PORT}."
  log "stderr log path: $LOG_DIR/macprovider.err.log"
  if [ -s "$LOG_DIR/macprovider.err.log" ]; then
    log "Last 200 bytes of macprovider.err.log:"
    tail -c 200 "$LOG_DIR/macprovider.err.log" | sed 's/^/  /'
  fi
}

wait_for_coordinator() {
  provider_id="$1"
  coordinator_base="$2"
  # F5 (#1365): a cold model load on a low-RAM Mac can push first
  # buyer-serving readiness well past 30s (observed 97s/114s/296s on an 8GB
  # Tier C M2). A flat 30s gate rolled back installs that had genuinely reached
  # buyer_serving. Give coordinator admission a generous deadline aligned with
  # the model-load reality (the local /v1/models waits above use 300s/1200s).
  # The exact catalog-identity / legacy_bridge admission proofs below are
  # unchanged; only the timeout widens. Overridable for tests.
  coordinator_ready_timeout="${MACPROVIDER_COORDINATOR_READY_TIMEOUT_SECONDS:-300}"
  deadline=$(( $(date +%s) + coordinator_ready_timeout ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    local_status="$(curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/v1/status" 2>/dev/null || true)"
    assigned_id="$(python3 - "$provider_id" "$local_status" <<'PY' 2>/dev/null || true
import json
import sys

provider_id, local_raw = sys.argv[1:]
local = json.loads(local_raw)
coordinator = local.get("coordinator")
if local.get("provider_id") != provider_id or not isinstance(coordinator, dict):
    raise SystemExit(1)
assigned_id = coordinator.get("session")
if coordinator.get("connected") is not True or not isinstance(assigned_id, str) or not assigned_id:
    raise SystemExit(1)
print(assigned_id)
PY
)"
    if [ -z "$assigned_id" ]; then
      sleep 2
      continue
    fi
    response="$(curl -fsS --max-time 5 "$coordinator_base/v1/pool/check?provider_id=$(urlencode "$provider_id")&assigned_id=$(urlencode "$assigned_id")&details=readiness" 2>/dev/null || true)"
    local_status="$(curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/v1/status" 2>/dev/null || true)"
    if python3 - "$provider_id" "$assigned_id" "$response" "$local_status" \
      "$INSTALL_DIR/catalog-release/release.json" \
      "$INSTALL_DIR/catalog-release/autotune-candidates.json" \
      "${EMERGENCY_ROLLBACK:-0}" <<'PY' 2>/dev/null
import hashlib
import json
import re
import sys

provider_id, assigned_id, response_raw, local_raw, release_path, candidates_path, emergency_raw = sys.argv[1:]
response = json.loads(response_raw)
local = json.loads(local_raw)
coordinator = local.get("coordinator")
if not isinstance(coordinator, dict):
    raise SystemExit(1)
if coordinator.get("connected") is not True or coordinator.get("session") != assigned_id:
    raise SystemExit(1)
if response.get("assigned_id") != assigned_id:
    raise SystemExit(1)
if emergency_raw == "1":
    # Coordinator buyer-serving admission for the exact connected session is
    # the authority for this deliberately legacy-only recovery path. A legacy
    # coordinator exposing only provider/state cannot prove this boundary, so
    # rollback stays armed until a bridge-capable coordinator supplies the
    # session-bound evidence.
    if local.get("provider_id") != provider_id:
        raise SystemExit(1)
    if response.get("provider_id") != provider_id or response.get("buyer_serving") is not True:
        raise SystemExit(1)
    if response.get("catalog_evidence_source") != "provider_reported":
        raise SystemExit(1)
    if response.get("catalog_admission_mode") != "legacy_bridge":
        raise SystemExit(1)
    raise SystemExit(0)
with open(release_path, "rb") as handle:
    release = json.load(handle)
with open(candidates_path, "rb") as handle:
    candidate_bytes = handle.read()
candidates = json.loads(candidate_bytes)

candidate_feed = release["feeds"]["autotune-candidates.json"]
candidate_sha = hashlib.sha256(candidate_bytes).hexdigest()
if candidate_sha != candidate_feed["sha256"]:
    raise SystemExit(1)
if candidates["version"] != release["release_id"] or candidates["policy_version"] != release["policy_version"]:
    raise SystemExit(1)

catalog = local.get("catalog")
if not isinstance(catalog, dict):
    raise SystemExit(1)
model = local.get("model")
key = catalog.get("catalog_key")
catalog_model_id = catalog.get("model_id")
rows = candidates.get("rows")
if not isinstance(rows, dict):
    raise SystemExit(1)
if not isinstance(key, str) or key not in rows:
    raise SystemExit(1)
if not isinstance(model, str) or model != key:
    raise SystemExit(1)
if not isinstance(catalog_model_id, str) or catalog_model_id != rows[key].get("model_id"):
    raise SystemExit(1)
row_identity = catalog.get("row_identity")
if re.fullmatch(r"[0-9a-f]{64}", row_identity or "") is None:
    raise SystemExit(1)
if catalog.get("policy_version") != candidates["policy_version"]:
    raise SystemExit(1)

expected = {
    "catalog_release_id": release["release_id"],
    "catalog_policy_version": release["policy_version"],
    "catalog_candidate_sha256": candidate_sha,
    "catalog_signer_key_id": candidate_feed["signer_key_id"],
    "catalog_row_identity": row_identity,
}
if local.get("provider_id") != provider_id or local.get("network_state") != "buyer_serving":
    raise SystemExit(1)
if catalog.get("release_id") != expected["catalog_release_id"]:
    raise SystemExit(1)
if catalog.get("digest") != expected["catalog_candidate_sha256"]:
    raise SystemExit(1)
if catalog.get("signer_key_id") != expected["catalog_signer_key_id"]:
    raise SystemExit(1)
if response.get("provider_id") != provider_id:
    raise SystemExit(1)
if response.get("buyer_serving") is not True:
    raise SystemExit(1)
if response.get("catalog_evidence_source") != "provider_reported":
    raise SystemExit(1)
if response.get("catalog_admission_mode") not in {"current", "previous"}:
    raise SystemExit(1)
if any(response.get(field) != value for field, value in expected.items()):
    raise SystemExit(1)
PY
    then
      return 0
    fi
    sleep 2
  done
  return 1
}

print_pid() {
  if [ -n "$MANUAL_PID" ]; then
    printf "%s\n" "$MANUAL_PID"
    return
  fi
  launchctl_service print "$LAUNCHD_DOMAIN/$PROVIDER_LABEL" 2>/dev/null \
    | awk 'NF == 3 && $1 == "pid" && $2 == "=" && $3 ~ /^[0-9]+$/ { print $3 }'
}

print_autotune_handoff() {
  printf "To tune throughput / latency parameters for your specific Mac, run:\n"
  printf '  macprovider-cli autotune --config "%s"\n' "$CONFIG_PATH"
  printf "To refresh the paid-model recommendation after install or update, run:\n"
  printf "  macprovider-cli autotune --recommend --apply\n"
}

installed_provider_binary_path() {
  if headless_acceptance_repair_mode \
      && [ -n "${HEADLESS_REPAIR_INCUMBENT_BINARY:-}" ] \
      && [ -x "$HEADLESS_REPAIR_INCUMBENT_BINARY" ]; then
    printf '%s\n' "$HEADLESS_REPAIR_INCUMBENT_BINARY"
  elif [ -x "$INSTALL_DIR/macprovider-cli" ]; then
    printf '%s\n' "$INSTALL_DIR/macprovider-cli"
  elif [ -x "$BINARY_PATH" ]; then
    printf '%s\n' "$BINARY_PATH"
  fi
}

installed_provider_binary_version() {
  local installed_binary="$1"
  local version_file installed_version
  version_file="$(mktemp "${TMPDIR:-/tmp}/macprovider-installed-version.XXXXXX")" \
    || return 1
  if ! "$installed_binary" --version >"$version_file" 2>/dev/null; then
    rm -f "$version_file"
    return 1
  fi
  installed_version="$(python3 - "$version_file" <<'PY'
import re
import sys

data = open(sys.argv[1], "rb").read()
if not re.fullmatch(rb"v?[0-9]+\.[0-9]+\.[0-9]+(?:\r?\n)?", data):
    raise SystemExit(1)
print(data.decode("ascii").rstrip("\r\n"))
PY
  )" || {
    rm -f "$version_file"
    return 1
  }
  rm -f "$version_file"
  printf '%s\n' "$installed_version"
}

validate_acceptance_upgrade_target() {
  target="$1"
  [ -n "${MACPROVIDER_ACCEPTANCE_ASSET_DIR:-}" ] || return 0
  installed_binary="$(installed_provider_binary_path)"
  [ -n "$installed_binary" ] || return 0
  # Downgrades are never an acceptance shortcut. They continue only through
  # the existing emergency path, which supplies coordinator/config/readiness gates.
  [ "${EMERGENCY_ROLLBACK:-0}" = "1" ] && return 0
  installed_manifest="$INSTALL_DIR/compatibility-set.json"
  if [ -f "$installed_manifest" ]; then
    installed_preflight_error_file="$(mktemp "${TMPDIR:-/tmp}/macprovider-installed-preflight.XXXXXX")" \
      || die 7 "could not create installed compatibility preflight error capture"
    if installed_preflight="$("$installed_binary" release-payload-preflight 2>"$installed_preflight_error_file")"; then
      rm -f "$installed_preflight_error_file"
      installed_version="$(python3 - "$installed_preflight" "$GITHUB_REPO" <<'PY'
import json
import re
import sys

def reject_duplicate_keys(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError(f"duplicate key: {key}")
        value[key] = item
    return value

value = json.loads(sys.argv[1], object_pairs_hook=reject_duplicate_keys)
version = value.get("version")
compatibility_set_id = value.get("compatibility_set_id")
identity_match = None
if isinstance(compatibility_set_id, str):
    identity_match = re.fullmatch(
        re.escape(sys.argv[2])
        + r":v([0-9]+\.[0-9]+\.[0-9]+)@[0-9a-f]{40}",
        compatibility_set_id,
    )
if set(value) != {"compatibility_set_id", "status", "version"} \
        or value.get("status") != "valid" \
        or not isinstance(version, str) \
        or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version) \
        or identity_match is None \
        or identity_match.group(1) != version:
    raise SystemExit(1)
print(version)
PY
      )" || die 7 "installed compatibility set returned invalid preflight identity"
      installed_tag="v$installed_version"
    else
      rm -f "$installed_preflight_error_file"
      die 7 "installed compatibility set failed preflight before acceptance upgrade"
    fi
  else
    installed_version="$(installed_provider_binary_version "$installed_binary")" \
      || die 7 "installed provider CLI returned an invalid version"
    case "$installed_version" in
      v*) installed_tag="$installed_version" ;;
      *) installed_tag="v$installed_version" ;;
    esac
  fi
  validate_macprovider_version_tag "$installed_tag"
  if version_at_least "$installed_tag" "$target"; then
    die 7 "acceptance candidate $target must be newer than installed $installed_tag"
  fi
}

validate_acceptance_provider_component_target() {
  local provider_target="$1"
  local installed_binary provider_target_tag installed_version installed_tag
  [ -n "${MACPROVIDER_ACCEPTANCE_ASSET_DIR:-}" ] || return 0
  [ "${EMERGENCY_ROLLBACK:-0}" = "1" ] && return 0
  installed_binary="$(installed_provider_binary_path)"
  [ -n "$installed_binary" ] || return 0

  case "$provider_target" in
    v*) provider_target_tag="$provider_target" ;;
    *) provider_target_tag="v$provider_target" ;;
  esac
  validate_macprovider_version_tag "$provider_target_tag"
  if [ "${HEADLESS:-0}" = "1" ] \
      && ! version_at_least "$provider_target_tag" "$MACPROVIDER_MIN_HEADLESS_VERSION"; then
    die 7 "headless mode requires macprovider-cli $MACPROVIDER_MIN_HEADLESS_VERSION or newer; acceptance provider component $provider_target_tag does not support SSH-only protected-file fleet installation"
  fi
  installed_version="$(installed_provider_binary_version "$installed_binary")" \
    || die 7 "installed provider CLI version preflight failed before acceptance upgrade"
  case "$installed_version" in
    v*) installed_tag="$installed_version" ;;
    *) installed_tag="v$installed_version" ;;
  esac
  validate_macprovider_version_tag "$installed_tag"
  if [ "$installed_tag" != "$provider_target_tag" ] \
      && version_at_least "$installed_tag" "$provider_target_tag"; then
    die 7 "acceptance provider component $provider_target_tag must not downgrade installed $installed_tag"
  fi
}

validate_staged_acceptance_provider_component() {
  local provider_target="$1"
  local staged_provider_version
  staged_provider_version="$(installed_provider_binary_version "$staging_dir/macprovider-cli")" \
    || die 5 "staged acceptance provider CLI version preflight failed"
  case "$staged_provider_version" in
    v*) staged_provider_version="${staged_provider_version#v}" ;;
  esac
  [ "$staged_provider_version" = "$provider_target" ] \
    || die 5 "staged acceptance provider CLI version does not match signed provider component"
}

validate_non_emergency_pinned_target() {
  local target="$1"
  local installed_version installed_tag
  [ -n "${MACPROVIDER_VERSION:-}" ] || return 0
  [ -x "$BINARY_PATH" ] || return 0
  [ "${EMERGENCY_ROLLBACK:-0}" = "1" ] && return 0

  installed_version="$("$BINARY_PATH" --version 2>/dev/null | tr -d '\r\n')"
  case "$installed_version" in
    v*) installed_tag="$installed_version" ;;
    *) installed_tag="v$installed_version" ;;
  esac
  validate_macprovider_version_tag "$installed_tag"
  if [ "$installed_tag" != "$target" ] && version_at_least "$installed_tag" "$target"; then
    die 7 "pinned install target $target must not downgrade installed $installed_tag"
  fi
}

validate_acceptance_staged_identity() {
  [ -n "${MACPROVIDER_ACCEPTANCE_ASSET_DIR:-}" ] || return 0
  manifest="$staging_dir/compatibility-set.json"
  [ -f "$manifest" ] || die 5 "acceptance payload is missing compatibility-set.json"
  signed_payload="$TMPDIR_PATH/acceptance-compatibility-set.signed.json"
  manifest_signature="$TMPDIR_PATH/acceptance-compatibility-set.signature.der"
  provider_component_version_file="$TMPDIR_PATH/acceptance-provider-component-version"
  python3 - "$manifest" "$GITHUB_REPO" "$tag" "$MACPROVIDER_ACCEPTANCE_COMMIT" \
    "$signed_payload" "$manifest_signature" "$provider_component_version_file" <<'PY' \
    || die 5 "acceptance compatibility-set identity is invalid"
import base64
import json
import pathlib
import re
import sys

manifest_path, repository, tag, commit, payload_path, signature_path, provider_version_path = sys.argv[1:]
data = pathlib.Path(manifest_path).read_bytes()

def pairs(values):
    result = {}
    for key, value in values:
        if key in result:
            raise ValueError("duplicate key")
        result[key] = value
    return result

envelope = json.loads(data.decode("utf-8"), object_pairs_hook=pairs)
canonical = (json.dumps(envelope, sort_keys=True, separators=(",", ":")) + "\n").encode()
if canonical != data or set(envelope) != {"schema_version", "signatures", "signed"}:
    raise SystemExit("noncanonical envelope")
if envelope.get("schema_version") != "macprovider.compatibility-set-envelope.v1":
    raise SystemExit("wrong envelope schema")
signatures = envelope.get("signatures")
if not isinstance(signatures, list) or len(signatures) != 1:
    raise SystemExit("wrong signature count")
signature = signatures[0]
if signature.keys() != {"algorithm", "key_id", "signature"}:
    raise SystemExit("wrong signature fields")
if signature.get("algorithm") != "ecdsa-p256-sha256" or signature.get("key_id") != "macprovider-release-p256-v1":
    raise SystemExit("wrong production compatibility trust domain")
signed = envelope.get("signed")
if not isinstance(signed, dict):
    raise SystemExit("missing signed payload")
release = signed.get("release")
set_id = f"{repository}:{tag}@{commit}"
if not isinstance(release, dict) or release != {
    "commit": commit,
    "repository": repository,
    "tag": tag,
    "version": tag.removeprefix("v"),
} or signed.get("compatibility_set_id") != set_id:
    raise SystemExit("wrong acceptance release identity")
components = signed.get("components")
provider = components.get("provider_cli") if isinstance(components, dict) else None
provider_version = provider.get("version") if isinstance(provider, dict) else None
if not isinstance(provider_version, str) or re.fullmatch(
    r"(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})",
    provider_version,
) is None:
    raise SystemExit("invalid provider component version")
signed_bytes = (json.dumps(signed, sort_keys=True, separators=(",", ":")) + "\n").encode()
signature_bytes = base64.b64decode(signature["signature"], validate=True)
if not 64 <= len(signature_bytes) <= 80:
    raise SystemExit("invalid signature encoding")
pathlib.Path(payload_path).write_bytes(signed_bytes)
pathlib.Path(signature_path).write_bytes(signature_bytes)
pathlib.Path(provider_version_path).write_text(provider_version + "\n", encoding="utf-8")
PY
  compatibility_public_key="$TMPDIR_PATH/acceptance-compatibility-public.pem"
  write_checksum_public_key > "$compatibility_public_key"
  openssl dgst -sha256 -verify "$compatibility_public_key" \
    -signature "$manifest_signature" "$signed_payload" >/dev/null \
    || die 5 "acceptance compatibility-set signature verification failed"
  provider_component_version="$(tr -d '\r\n' < "$provider_component_version_file")"
  validate_staged_acceptance_provider_component "$provider_component_version"
  validate_acceptance_provider_component_target "$provider_component_version"
  log "Acceptance compatibility-set signature and exact candidate identity verified."
}

validate_emergency_target() {
  target="$1"
  [ -x "$BINARY_PATH" ] || die 7 "emergency rollback requires an installed provider binary"
  installed_version="$("$BINARY_PATH" --version 2>/dev/null | tr -d '\r\n')"
  case "$installed_version" in
    v*) installed_tag="$installed_version" ;;
    *) installed_tag="v$installed_version" ;;
  esac
  validate_macprovider_version_tag "$installed_tag"
  if version_at_least "$target" "$installed_tag"; then
    die 7 "emergency rollback target $target must be older than installed $installed_tag"
  fi
}

verify_emergency_coordinator_advertisement() {
  coordinator_base="$1"
  target="$2"
  health="$(curl -fsS --max-time 10 "$coordinator_base/healthz" 2>/dev/null || true)"
  python3 - "$target" "$health" <<'PY' \
    || die 7 "coordinator must advertise the exact rollback target before emergency provider downgrade"
import json
import sys

target, raw = sys.argv[1:]
payload = json.loads(raw)
if payload.get("recommended_binary_version") != target.removeprefix("v"):
    raise SystemExit(1)
PY
}

validate_emergency_config_backup() {
  [ -n "$EMERGENCY_CONFIG_BACKUP" ] \
    || die 7 "emergency rollback requires MACPROVIDER_EMERGENCY_CONFIG_BACKUP"
  [ -n "$EMERGENCY_CONFIG_SHA256" ] \
    || die 7 "emergency rollback requires MACPROVIDER_EMERGENCY_CONFIG_SHA256"
  case "$EMERGENCY_CONFIG_BACKUP" in
    /*) ;;
    *) die 7 "emergency config backup path must be absolute" ;;
  esac
  if [[ ! "$EMERGENCY_CONFIG_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
    die 7 "emergency config backup sha256 must be exactly 64 lowercase hex characters"
  fi
  python3 - "$EMERGENCY_CONFIG_BACKUP" "$LIVE_CONFIG_PATH" "$EMERGENCY_CONFIG_SHA256" <<'PY' \
    || die 7 "emergency config backup is not an owned private regular file with the expected sha256"
import hashlib
import os
import stat
import sys

source, live, expected = sys.argv[1:]
source_real = os.path.realpath(source)
live_real = os.path.realpath(live)
if source_real == live_real:
    raise SystemExit(1)
info = os.lstat(source)
if (
    not stat.S_ISREG(info.st_mode)
    or stat.S_ISLNK(info.st_mode)
    or info.st_uid != os.geteuid()
    or info.st_nlink != 1
    or stat.S_IMODE(info.st_mode) != 0o600
    or info.st_size <= 0
    or info.st_size > 1024 * 1024
):
    raise SystemExit(1)
descriptor = os.open(source, os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC | os.O_NOFOLLOW)
try:
    opened = os.fstat(descriptor)
    if (opened.st_dev, opened.st_ino) != (info.st_dev, info.st_ino):
        raise SystemExit(1)
    payload = b""
    while True:
        block = os.read(descriptor, 65536)
        if not block:
            break
        payload += block
        if len(payload) > 1024 * 1024:
            raise SystemExit(1)
finally:
    os.close(descriptor)
if hashlib.sha256(payload).hexdigest() != expected:
    raise SystemExit(1)
PY
}

stage_emergency_config_backup() {
  python3 - "$EMERGENCY_CONFIG_BACKUP" "$EMERGENCY_CONFIG_SHA256" "$STAGED_CONFIG_PATH" <<'PY' \
    || die 7 "failed to stage the verified pre-upgrade emergency config"
import hashlib
import os
import stat
import sys

source, expected, destination = sys.argv[1:]
source_info = os.lstat(source)
source_fd = os.open(source, os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC | os.O_NOFOLLOW)
try:
    opened = os.fstat(source_fd)
    if (
        not stat.S_ISREG(opened.st_mode)
        or opened.st_uid != os.geteuid()
        or opened.st_nlink != 1
        or stat.S_IMODE(opened.st_mode) != 0o600
        or (opened.st_dev, opened.st_ino) != (source_info.st_dev, source_info.st_ino)
    ):
        raise SystemExit(1)
    payload = b""
    while True:
        block = os.read(source_fd, 65536)
        if not block:
            break
        payload += block
        if len(payload) > 1024 * 1024:
            raise SystemExit(1)
finally:
    os.close(source_fd)
if not payload or hashlib.sha256(payload).hexdigest() != expected:
    raise SystemExit(1)
try:
    os.unlink(destination)
except FileNotFoundError:
    pass
destination_fd = os.open(
    destination,
    os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
    0o600,
)
try:
    with os.fdopen(destination_fd, "wb", closefd=False) as output:
        output.write(payload)
        output.flush()
        os.fsync(output.fileno())
finally:
    os.close(destination_fd)
PY
}

disable_staged_autoupdate() {
  python3 - "$STAGED_CONFIG_PATH" <<'PY'
import os
import re
import sys
import tempfile

path = sys.argv[1]
lines = open(path, encoding="utf-8").read().splitlines()
top_level_legacy = re.compile(r"^auto_update_enabled\s*:")
merged = [line for line in lines if not top_level_legacy.match(line)]
if merged and merged[-1].strip():
    merged.append("")
merged.append("auto_update_enabled: false")
directory = os.path.dirname(path)
fd, temporary = tempfile.mkstemp(prefix=".emergency-config-", dir=directory)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write("\n".join(merged) + "\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)
finally:
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
PY
}

verify_emergency_config_activation() {
  [ -n "$EMERGENCY_STAGED_CONFIG_SHA256" ] \
    || die 7 "emergency staged config digest was not recorded"
  [ -n "$EMERGENCY_STAGED_CONFIG_TOKENLESS_SHA256" ] \
    || die 7 "emergency tokenless staged config digest was not recorded"
  actual_config_sha="$(shasum -a 256 "$LIVE_CONFIG_PATH" | awk '{print $1}')"
  if [ "$actual_config_sha" != "$EMERGENCY_STAGED_CONFIG_SHA256" ] \
    && [ "$actual_config_sha" != "$EMERGENCY_STAGED_CONFIG_TOKENLESS_SHA256" ]; then
    die 7 "activated emergency config does not match the verified staged config or its admission-cleaned form"
  fi
  activated_model="$(read_config_model || true)"
  [ -n "$activated_model" ] && [ "$activated_model" = "$EMERGENCY_MODEL" ] \
    || die 7 "activated emergency config does not retain the inventoried model"
  log "Emergency config proof: source_sha256=$EMERGENCY_CONFIG_SHA256 staged_sha256=$EMERGENCY_STAGED_CONFIG_SHA256 tokenless_sha256=$EMERGENCY_STAGED_CONFIG_TOKENLESS_SHA256 activated_sha256=$actual_config_sha model=$activated_model"
}

config_without_provider_token_sha256() {
  python3 - "$1" <<'PY'
import hashlib
import re
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    lines = handle.read().splitlines()
key_pattern = re.compile(r'^(?P<indent>[ \t]*)(?:"provider_token"|'"'"'provider_token'"'"'|provider_token)[ \t]*:(?P<rest>.*)$')
scrubbed = []
index = 0
while index < len(lines):
    line = lines[index]
    match = key_pattern.match(line)
    if not match:
        scrubbed.append(line)
        index += 1
        continue
    key_indent = len(match.group("indent").expandtabs(8))
    rest = match.group("rest").strip()
    index += 1
    if rest.startswith("|") or rest.startswith(">"):
        while index < len(lines):
            candidate = lines[index]
            if candidate.strip() == "":
                index += 1
                continue
            indent = len(candidate[: len(candidate) - len(candidate.lstrip(" \t"))].expandtabs(8))
            if indent <= key_indent:
                break
            index += 1
tokenless = "\n".join(scrubbed) + "\n"
print(hashlib.sha256(tokenless.encode("utf-8")).hexdigest())
PY
}

repair_autoupdate_recovery_preflight() {
  [ "${REPAIR_EXISTING_INSTALL:-0}" -eq 1 ] || return 0
  [ "$DRY_RUN" -eq 0 ] || return 0
  [ -e "$PROVIDER_MUTATION_PENDING_PATH" ] || [ -L "$PROVIDER_MUTATION_PENDING_PATH" ] || return 0
  [ "${HEADLESS:-0}" != "1" ] || return 0
  [ "${LAUNCHD_DOMAIN:-}" != "system" ] || return 0
  recovery_action="${1:-classify}"
  case "$recovery_action" in
    classify|quarantine) ;;
    *) die 70 "invalid repair autoupdate recovery action" ;;
  esac
  mkdir -p "$LOG_DIR" \
    || die 70 "could not create provider log directory for repair autoupdate recovery"
  recovery_status_path="$(mktemp "${TMPDIR:-/tmp}/macprovider-repair-autoupdate.XXXXXX")" \
    || die 70 "could not allocate repair autoupdate recovery status"
  # Malformed or expired pending.json has no trustworthy rollback target to
  # restore. Repair preserves its bytes by atomically renaming it under both the
  # installer and provider-update locks, then proceeds; valid active markers
  # stay authoritative and still block repair through acquire_install_lock.
  python3 - "$HOME" "$CONFIG_DIR" "$INSTALL_LOCK_PATH" "$PROVIDER_MUTATION_ROOT" \
    "$PROVIDER_MUTATION_LOCK_PATH" "$PROVIDER_MUTATION_PENDING_PATH" "$recovery_status_path" "$BINARY_PATH" "$recovery_action" <<'PY' \
    || die 70 "could not inspect repair autoupdate recovery state"
import datetime
import ctypes
import errno
import fcntl
import grp
import hashlib
import json
import os
import pwd
import re
import stat
import subprocess
import sys

home, config_dir, install_lock_path, mutation_root, mutation_lock_path, mutation_pending_path, status_path, binary_path, action = sys.argv[1:]
uid = os.getuid()
provider_user = pwd.getpwuid(uid).pw_name
home = os.path.normpath(home)
config_dir = os.path.normpath(config_dir)
mutation_root = os.path.normpath(mutation_root)
mutation_pending_path = os.path.normpath(mutation_pending_path)
binary_path = os.path.normpath(binary_path)
uuid_pattern = re.compile(
    r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-"
    r"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
)
uuid4_pattern = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
)
semver_pattern = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
sha256_pattern = re.compile(r"^[0-9a-f]{64}$")
compatibility_id_pattern = re.compile(
    r"^[A-Za-z0-9_.-]{1,64}/[A-Za-z0-9_.-]{1,100}:v[0-9]+\.[0-9]+\.[0-9]+@[0-9a-f]{40}$"
)

def write_status(value):
    fd = os.open(status_path, os.O_WRONLY | os.O_TRUNC | getattr(os, "O_NOFOLLOW", 0))
    try:
        os.write(fd, (value + "\n").encode("utf-8"))
        os.fsync(fd)
    finally:
        os.close(fd)

def repair_home_write_acl(fields, path, everyone_gid, allow_home_acl_write=False):
    if not allow_home_acl_write or os.path.normpath(path) != home:
        return False
    if (
        len(fields) != 6
        or fields[0] != "group"
        or not uuid_pattern.fullmatch(fields[1])
        or fields[2] != "everyone"
        or fields[3] != str(everyone_gid)
        or fields[4] != "allow"
    ):
        return False
    permissions = set(filter(None, fields[5].split(",")))
    return permissions == {"write", "append"}

def reject_non_owner_write_acl(path, allow_home_acl_write=False):
    if sys.platform != "darwin":
        return
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        acl_get_fd_np = libc.acl_get_fd_np
        acl_get_fd_np.argtypes = [ctypes.c_int, ctypes.c_int]
        acl_get_fd_np.restype = ctypes.c_void_p
        acl_to_text = libc.acl_to_text
        acl_to_text.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_long)]
        acl_to_text.restype = ctypes.c_void_p
        acl_free = libc.acl_free
        acl_free.argtypes = [ctypes.c_void_p]
        acl_free.restype = ctypes.c_int
    except (AttributeError, OSError) as exc:
        raise RuntimeError("provider mutation ACL inspection unavailable") from exc
    directory_fd = os.open(
        path,
        os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0),
    )
    try:
        ctypes.set_errno(0)
        acl = acl_get_fd_np(directory_fd, 0x00000100)  # ACL_TYPE_EXTENDED
        if not acl:
            if ctypes.get_errno() in (0, errno.ENOENT):
                return
            raise RuntimeError("provider mutation ACL inspection failed")
        try:
            text_length = ctypes.c_long()
            text_pointer = acl_to_text(acl, ctypes.byref(text_length))
            if not text_pointer:
                raise RuntimeError("provider mutation ACL inspection failed")
            try:
                lines = ctypes.string_at(text_pointer, text_length.value).decode(
                    "utf-8", errors="strict"
                ).splitlines()
            finally:
                acl_free(text_pointer)
            everyone_gid = grp.getgrnam("everyone").gr_gid
            if len(lines) < 2 or lines[0] != "!#acl 1":
                raise RuntimeError("provider mutation ACL inspection failed")
            write_permissions = {"write", "append", "add_file", "add_subdirectory", "writeattr", "writeextattr", "delete_child"}
            for line in lines[1:]:
                fields = line.split(":")
                if repair_home_write_acl(fields, path, everyone_gid, allow_home_acl_write=allow_home_acl_write):
                    continue
                if len(fields) != 6:
                    raise RuntimeError("provider mutation ACL inspection failed")
                permissions = set(filter(None, fields[5].split(",")))
                if permissions & write_permissions:
                    if fields[0] == "user" and fields[2] == provider_user:
                        continue
                    raise RuntimeError("provider mutation path has non-owner-write ACL")
        finally:
            acl_free(acl)
    finally:
        os.close(directory_fd)

def validate_private_directory(path, allow_home_acl_write=False):
    info = os.lstat(path)
    if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
        raise RuntimeError("provider mutation path is not a no-follow directory")
    if info.st_uid != uid or info.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        raise RuntimeError("provider mutation path is not private to the installing user")
    reject_non_owner_write_acl(path, allow_home_acl_write=allow_home_acl_write)
    return info

def no_extended_acl(fd):
    if sys.platform != "darwin":
        return True
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        acl_get_fd_np = libc.acl_get_fd_np
        acl_get_fd_np.argtypes = [ctypes.c_int, ctypes.c_int]
        acl_get_fd_np.restype = ctypes.c_void_p
        acl_free = libc.acl_free
        acl_free.argtypes = [ctypes.c_void_p]
        acl_free.restype = ctypes.c_int
    except (AttributeError, OSError):
        return False
    ctypes.set_errno(0)
    acl = acl_get_fd_np(fd, 0x00000100)  # ACL_TYPE_EXTENDED
    if acl:
        acl_free(acl)
        return False
    return ctypes.get_errno() in (0, errno.ENOENT)

def canonical_absolute_path(marker, key):
    value = marker.get(key)
    if not isinstance(value, str) or "\x00" in value:
        raise ValueError(key)
    normalized = os.path.normpath(value)
    if (
        not os.path.isabs(value)
        or value != normalized
        or value.endswith("/")
        or os.path.basename(value) in {"", ".", ".."}
    ):
        raise ValueError(key)
    return value

def int_field(marker, key, minimum, maximum):
    value = marker.get(key)
    if not isinstance(value, int) or isinstance(value, bool):
        raise ValueError(key)
    if value < minimum or value > maximum:
        raise ValueError(key)
    return value

def optional_pair(marker, left, right):
    left_value = marker.get(left)
    right_value = marker.get(right)
    if (left_value is None) != (right_value is None):
        raise ValueError(left)
    return left_value, right_value

def validate_backup_file(path, expected_size, expected_sha256):
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_NOFOLLOW", 0))
    digest = hashlib.sha256()
    try:
        info = os.fstat(fd)
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != uid
            or info.st_nlink != 1
            or info.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
            or info.st_size != expected_size
            or not no_extended_acl(fd)
        ):
            raise ValueError("backup_path")
        while True:
            chunk = os.read(fd, 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    finally:
        os.close(fd)
    if digest.hexdigest() != expected_sha256:
        raise ValueError("backup_path")

def reject_owned_path(path):
    info = os.lstat(path)
    if (
        stat.S_ISLNK(info.st_mode)
        or info.st_uid != uid
        or info.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
        or (not stat.S_ISDIR(info.st_mode) and info.st_nlink != 1)
    ):
        raise ValueError(path)
    flags = os.O_RDONLY | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_NOFOLLOW", 0)
    if stat.S_ISDIR(info.st_mode):
        flags |= getattr(os, "O_DIRECTORY", 0)
    fd = os.open(path, flags)
    try:
        opened = os.fstat(fd)
        if (opened.st_dev, opened.st_ino) != (info.st_dev, info.st_ino) or not no_extended_acl(fd):
            raise ValueError(path)
    finally:
        os.close(fd)
    return info

def sha256_file(path):
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_NOFOLLOW", 0))
    digest = hashlib.sha256()
    try:
        while True:
            chunk = os.read(fd, 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    finally:
        os.close(fd)
    return digest.hexdigest()

def release_tree_sha256(root_path):
    records = []
    for current, directory_names, file_names in os.walk(root_path, topdown=True, followlinks=False):
        directory_names.sort()
        file_names.sort()
        for name in directory_names + file_names:
            path = os.path.join(current, name)
            item_info = reject_owned_path(path)
            relative = os.path.relpath(path, root_path)
            if "\x00" in relative or "\n" in relative or relative == ".." or relative.startswith("../"):
                raise ValueError("release_backup_path")
            mode = stat.S_IMODE(item_info.st_mode)
            if stat.S_ISDIR(item_info.st_mode):
                record = f"d\0{relative}\0{mode}\0"
            elif stat.S_ISREG(item_info.st_mode):
                record = f"f\0{relative}\0{mode}\0{item_info.st_size}\0{sha256_file(path)}\0"
            else:
                raise ValueError("release_backup_path")
            records.append((relative, record.encode("utf-8")))
    digest = hashlib.sha256()
    for _, record in sorted(records, key=lambda item: item[0]):
        digest.update(record)
    return digest.hexdigest()

def validate_release_backup(root_path, expected_sha256):
    reject_owned_path(root_path)
    allowed = lambda name: name in {
        "mlx.metallib",
        "THIRD-PARTY-NOTICES.txt",
        "compatibility-set.json",
        "compatibility-set-local",
        "catalog-release",
        "external-local-members",
        "Malibu.app.zip",
        "malibu-app-state.json",
    } or name.endswith(".bundle")
    if any(not allowed(name) for name in os.listdir(root_path)):
        raise ValueError("release_backup_path")
    if release_tree_sha256(root_path) != expected_sha256:
        raise ValueError("release_backup_sha256")

def validate_active_marker(marker):
    if not isinstance(marker, dict):
        return False
    required = {"update_id", "target_version", "target_path", "backup_path", "size", "mode", "sha256", "marker_deadline"}
    try:
        if not required.issubset(marker.keys()):
            raise ValueError("required")
        update_id = marker["update_id"]
        if not isinstance(update_id, str) or not uuid4_pattern.fullmatch(update_id):
            raise ValueError("update_id")
        target_version = marker["target_version"]
        if not isinstance(target_version, str) or not semver_pattern.fullmatch(target_version):
            raise ValueError("target_version")
        target_path = canonical_absolute_path(marker, "target_path")
        backup_path = canonical_absolute_path(marker, "backup_path")
        if target_path != binary_path:
            raise ValueError("target_path")
        expected_backup = os.path.join(os.path.dirname(target_path), f".macprovider-cli.rollback-{update_id}")
        if backup_path != expected_backup:
            raise ValueError("backup_path")
        size = int_field(marker, "size", 0, 1024 * 1024 * 1024)
        int_field(marker, "mode", 0, 0o7777)
        sha256 = marker["sha256"]
        if not isinstance(sha256, str) or not sha256_pattern.fullmatch(sha256):
            raise ValueError("sha256")
        release_backup, release_sha = optional_pair(marker, "release_backup_path", "release_backup_sha256")
        if release_backup is not None:
            release_backup = canonical_absolute_path(marker, "release_backup_path")
            expected_release_backup = os.path.join(os.path.dirname(target_path), f".macprovider-cli.release-rollback-{update_id}")
            if release_backup != expected_release_backup or not isinstance(release_sha, str) or not sha256_pattern.fullmatch(release_sha):
                raise ValueError("release_backup_path")
            release_info = os.lstat(release_backup)
            if (
                not stat.S_ISDIR(release_info.st_mode)
                or stat.S_ISLNK(release_info.st_mode)
                or release_info.st_uid != uid
                or release_info.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
            ):
                raise ValueError("release_backup_path")
            validate_release_backup(release_backup, release_sha)
        compatibility_id, compatibility_sha = optional_pair(marker, "target_compatibility_set_id", "target_compatibility_set_sha256")
        if compatibility_id is not None:
            if (
                not isinstance(compatibility_id, str)
                or not compatibility_id_pattern.fullmatch(compatibility_id)
                or not isinstance(compatibility_sha, str)
                or not sha256_pattern.fullmatch(compatibility_sha)
            ):
                raise ValueError("target_compatibility_set_id")
        discovery_sequence, discovery_sha = optional_pair(marker, "discovery_head_sequence", "discovery_head_sha256")
        if discovery_sequence is not None:
            if (
                not isinstance(discovery_sequence, int)
                or isinstance(discovery_sequence, bool)
                or discovery_sequence <= 0
                or not isinstance(discovery_sha, str)
                or not sha256_pattern.fullmatch(discovery_sha)
            ):
                raise ValueError("discovery_head_sequence")
        authority = marker.get("update_authority_mode")
        if authority is not None:
            if authority not in {"coordinator_recommendation", "signed_release"}:
                raise ValueError("update_authority_mode")
            if authority == "signed_release" and (compatibility_id is None or discovery_sequence is None):
                raise ValueError("update_authority_mode")
        commit_owner = marker.get("commit_owner")
        if commit_owner is not None and commit_owner not in {"coordinator", "self_update"}:
            raise ValueError("commit_owner")
        previous_fields = (
            marker.get("previous_version"),
            marker.get("previous_compatibility_set_id"),
            marker.get("previous_compatibility_set_sha256"),
            marker.get("transaction_state"),
        )
        if any(value is not None for value in previous_fields):
            if any(value is None for value in previous_fields):
                raise ValueError("previous_compatibility_set_id")
            previous_version, previous_id, previous_sha, transaction_state = previous_fields
            if compatibility_id is None or release_backup is None:
                raise ValueError("previous_compatibility_set_id")
            if not isinstance(previous_version, str) or not semver_pattern.fullmatch(previous_version):
                raise ValueError("previous_version")
            if not isinstance(previous_id, str) or not compatibility_id_pattern.fullmatch(previous_id):
                raise ValueError("previous_compatibility_set_id")
            if not isinstance(previous_sha, str) or not sha256_pattern.fullmatch(previous_sha):
                raise ValueError("previous_compatibility_set_sha256")
            if transaction_state not in {
                "activating_target",
                "restoring_previous",
                "awaiting_previous_readiness",
            }:
                raise ValueError("transaction_state")
        raw_deadline = marker["marker_deadline"]
        if not isinstance(raw_deadline, str) or not raw_deadline.endswith("Z"):
            raise ValueError("marker_deadline")
        deadline = datetime.datetime.strptime(raw_deadline, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
        now = datetime.datetime.now(datetime.timezone.utc)
        if deadline < now or deadline > now + datetime.timedelta(seconds=60 + 30 * 60):
            raise ValueError("marker_deadline")
        validate_backup_file(backup_path, size, sha256)
        return True
    except Exception:
        return False

if os.path.commonpath([home, config_dir]) != home:
    raise RuntimeError("config directory must remain inside HOME")
if os.path.commonpath([home, mutation_root]) != home:
    raise RuntimeError("provider mutation directory must remain inside HOME")
if mutation_pending_path != os.path.join(mutation_root, "pending.json"):
    raise RuntimeError("unexpected provider mutation pending marker path")

home_info = validate_private_directory(home, allow_home_acl_write=True)
current = home
for component in os.path.relpath(config_dir, home).split(os.sep):
    current = os.path.join(current, component)
    if not os.path.exists(current):
        os.mkdir(current, 0o700)
    info = validate_private_directory(current)
    if info.st_dev != home_info.st_dev:
        raise RuntimeError("config path crosses an unexpected device")
current = home
for component in os.path.relpath(mutation_root, home).split(os.sep):
    current = os.path.join(current, component)
    if not os.path.exists(current):
        os.mkdir(current, 0o700)
    info = validate_private_directory(current)
    if info.st_dev != home_info.st_dev:
        raise RuntimeError("provider mutation path crosses an unexpected device")

pending_info = os.lstat(mutation_pending_path)
if (
    not stat.S_ISREG(pending_info.st_mode)
    or stat.S_ISLNK(pending_info.st_mode)
    or pending_info.st_uid != uid
    or pending_info.st_nlink != 1
    or pending_info.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
    or pending_info.st_size < 0
    or pending_info.st_size > 65536
):
    raise RuntimeError("pending provider mutation marker is unsafe")

descriptors = []
try:
    for path in (install_lock_path, mutation_lock_path):
        directory = os.path.dirname(path)
        name = os.path.basename(path)
        dir_fd = os.open(directory, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0))
        descriptors.append(dir_fd)
        fd = os.open(name, os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o600, dir_fd=dir_fd)
        descriptors.append(fd)
        lock_info = os.fstat(fd)
        if not stat.S_ISREG(lock_info.st_mode) or lock_info.st_uid != uid or lock_info.st_nlink != 1:
            raise RuntimeError("provider mutation lock is unsafe")
        os.fchmod(fd, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            write_status("deferred")
            raise SystemExit(0)

    pending_fd = os.open(
        "pending.json",
        os.O_RDONLY | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_NOFOLLOW", 0),
        dir_fd=descriptors[-2],
    )
    try:
        opened = os.fstat(pending_fd)
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_uid != uid
            or opened.st_nlink != 1
            or opened.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
            or (opened.st_dev, opened.st_ino) != (pending_info.st_dev, pending_info.st_ino)
            or opened.st_size != pending_info.st_size
            or not no_extended_acl(pending_fd)
        ):
            raise RuntimeError("pending provider mutation marker is unsafe")
        raw = os.read(pending_fd, opened.st_size + 1)
    finally:
        os.close(pending_fd)
    if len(raw) != pending_info.st_size:
        raise RuntimeError("pending provider mutation marker changed during read")
    try:
        marker = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        marker = None

    if validate_active_marker(marker):
        write_status("active")
        raise SystemExit(0)
    if action == "classify":
        write_status("invalid")
        raise SystemExit(0)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    os.replace("pending.json", f"pending-quarantined-{stamp}.json", src_dir_fd=descriptors[-2], dst_dir_fd=descriptors[-2])
    os.fsync(descriptors[-2])
    write_status("quarantined")
finally:
    for descriptor in reversed(descriptors):
        try:
            os.close(descriptor)
        except OSError:
            pass
PY
  recovery_result="$(cat "$recovery_status_path" 2>/dev/null || true)"
  rm -f "$recovery_status_path"
  case "$recovery_result" in
    invalid)
      quiesce_repair_watchdogs_for_transaction
      repair_autoupdate_recovery_preflight quarantine
      ;;
    quarantined)
      log "Repair preflight: quarantined malformed or expired orphaned autoupdate recovery marker before acquiring installer ownership."
      ;;
    active|deferred|"")
      ;;
    *)
      die 70 "could not resolve repair autoupdate recovery state"
      ;;
  esac
}

main() {
  detect_platform
  validate_provider_token_environment
  validate_launchd_mode
  validate_repair_privilege_domain
  validate_headless_acceptance_source
  validate_port_value "$PORT"
  for tool in curl tar shasum grep sed awk date hostname mktemp openssl find lsof cmp diff readlink ps; do
    require_tool "$tool"
  done
  # python3 is intentionally NOT in the generic require_tool loop: on a stock Mac
  # the only python3 is the CLT stub, which passes command -v but hangs the first
  # real invocation, and a Mac with no python3 at all must surface the same
  # actionable die 8 (not a generic "missing required tool: python3" exit 2).
  # ensure_python3_usable is the sole authority for python3 presence+usability. (#1285)
  ensure_python3_usable
  validate_install_dir
  remediate_repair_home_write_acl
  repair_autoupdate_recovery_preflight
  acquire_install_lock
  validate_headless_install_topology
  recover_orphaned_install_transactions
  prepare_fresh_referral_code

  ram_gb="$(detect_ram_gb)"
  model=""
  provider_id="$(choose_provider_id)"
  coordinator_url="$(choose_coordinator_url)"
  coordinator_base="$(coordinator_http_base "$coordinator_url")"
  validate_inputs "$model" "$provider_id" "$coordinator_url"
  log "Model selection: signed catalog recommendation after release verification"
  log "Provider ID: $provider_id"
  log "Coordinator: $coordinator_url"
  log "Binary path: $BINARY_PATH"
  log "Support dir: $INSTALL_DIR"
  ensure_port_free 0

  if [ "$DRY_RUN" -eq 1 ]; then
    log "Dry run: would query latest release for $GITHUB_REPO, download, verify, install, and self-test."
    write_config "$model" "$provider_id" "$coordinator_url"
    install_binary
    install_plist "$model" "$provider_id" "$coordinator_url"
    install_watchdog "$coordinator_url"
    write_install_manifest "dry-run"
    check_path_hint
    exit 0
  fi

  tag="$(resolve_release_tag)"
  validate_headless_release_tag "$tag"
  # The install lock is already held here, so this check closes the race between
  # Malibu's observed snapshot and the version actually present at mutation time.
  validate_non_emergency_pinned_target "$tag"
  validate_acceptance_upgrade_target "$tag"
  if [ "$EMERGENCY_ROLLBACK" = "1" ]; then
    validate_emergency_target "$tag"
    verify_emergency_coordinator_advertisement "$coordinator_base" "$tag"
    validate_emergency_config_backup
  fi
  if [ -n "${MACPROVIDER_VERSION:-}" ]; then
    log "Using operator-pinned version: $tag (via MACPROVIDER_VERSION)"
  else
    log "Latest release: $tag"
  fi
  if [ -n "${BUNDLED_APP}" ]; then
    [ "${REPAIR_EXISTING_INSTALL:-0}" -eq 1 ] \
      || die 7 "MACPROVIDER_BUNDLED_APP is only allowed for existing-install repair"
    TMPDIR_PATH="$(mktemp -d)"
    asset_kind="bundled"
    log "Repairing from Malibu.app bundled provider CLI (no GitHub download)."
  else
    [ "${REPAIR_EXISTING_INSTALL:-0}" -eq 0 ] || headless_acceptance_repair_mode \
      || die 7 "existing-install repair requires MACPROVIDER_BUNDLED_APP from Malibu.app"
    download_release "$tag"
    verify_sha256
    validate_release_payload
  fi
  check_install_dir_clean
  begin_install_transaction
  stage_release_payload
  validate_acceptance_staged_identity
  clear_quarantine "$staging_dir"
  LIFECYCLE_STAGED_CLI_TRUSTED=1
  prepare_staged_config
  enable_fresh_referral_receipts
  ensure_replacement_referral_preflight_before_cutover
  if [ "$EMERGENCY_ROLLBACK" = "1" ]; then
    [ "$EXISTING_INSTALL_WAS_PRESENT" -eq 1 ] \
      || die 7 "emergency rollback requires an existing provider installation to restore"
    [ "$SKIP_PROVIDER_START" -eq 0 ] \
      || die 7 "emergency rollback must start and prove the restored provider before commit"
    stage_emergency_config_backup
    model="$(read_config_model || true)"
    [ -n "$model" ] \
      || die 7 "emergency rollback backup must retain its prior model"
    EMERGENCY_MODEL="$model"
    disable_staged_autoupdate
    EMERGENCY_STAGED_CONFIG_SHA256="$(shasum -a 256 "$STAGED_CONFIG_PATH" | awk '{print $1}')"
    EMERGENCY_STAGED_CONFIG_TOKENLESS_SHA256="$(config_without_provider_token_sha256 "$STAGED_CONFIG_PATH")"
    log "Emergency rollback: restoring the verified pre-upgrade config and model while disabling provider autoupdate."
    log "The signed prior release will commit only after session-bound legacy_bridge buyer admission."
  else
    log "Validating signed catalog and stored recommendation with the staged release while the current provider remains available."
    if ! use_fresh_recommendation_if_available; then
      if [ "$EXISTING_INSTALL_WAS_PRESENT" -eq 1 ]; then
        if [ "$REFERRAL_REPLACE_INCUMBENT" != "1" ]; then
          AUTOTUNE_UPGRADE_CANDIDATE_MODEL_ID="$(read_config_catalog_model_id || true)"
        fi
      fi
      write_config "$model" "$provider_id" "$coordinator_url"
      AUTOTUNE_RECOMMENDATION_REQUIRED=1
      prefetch_upgrade_autotune_model
    fi
  fi
  ensure_headless_acceptance_credentials_before_cutover
  if [ "$SKIP_PROVIDER_START" -eq 1 ]; then
    if restore_existing_provider_if_start_skipped; then
      log "Re-run macprovider-cli autotune --recommend --apply when you want to change the active provider model."
      exit 0
    fi
    assert_install_lock_ownership
    mark_install_cutover_started
    ensure_port_free 1
    install_binary
    activate_staged_config
    check_path_hint
    write_install_manifest "$tag"
    record_lifecycle_state paused_by_operator install_committed_without_start \
      || die 5 "failed to persist paused lifecycle state"
    # An explicit no-start choice has no new local service to validate, but its
    # manifest mutation is still covered by the recovery transaction.
    commit_install_transaction
    log "Install complete without starting a provider service."
    log "To re-check paid-yield recommendation later, run:"
    log "  macprovider-cli autotune --recommend --apply"
    log "To opt into local donor-mode testing, run:"
    log "  macprovider-cli autotune --recommend --apply --donor-mode"
    exit 0
  fi
  if [ "$AUTOTUNE_RECOMMENDATION_REQUIRED" -eq 1 ]; then
    # Candidate providers load full model weights. Stop the incumbent before
    # benchmarks so unified-memory pressure cannot disrupt buyer traffic or
    # corrupt benchmark results through contention.
    assert_install_lock_ownership
    mark_install_cutover_started
    ensure_port_free 1
    select_autotune_benchmark_port
    run_autotune_recommend_apply
    if [ "$SKIP_PROVIDER_START" -eq 1 ]; then
      if restore_existing_provider_if_start_skipped; then
        log "Re-run macprovider-cli autotune --recommend --apply when you want to change the active provider model."
        exit 0
      fi
      install_binary
      activate_staged_config
      check_path_hint
      write_install_manifest "$tag"
      record_lifecycle_state paused_by_operator install_committed_without_start \
        || die 5 "failed to persist paused lifecycle state"
      commit_install_transaction
      log "Install complete without starting a provider service."
      exit 0
    fi
  fi
  # Cut over only after the staged CLI has completed catalog validation and
  # freshness evaluation; when benchmarks are required the incumbent is
  # deliberately stopped first to avoid double-loading model weights.
  assert_install_lock_ownership
  mark_install_cutover_started
  ensure_port_free 1
  install_binary
  activate_staged_config
  check_path_hint
  install_plist "$model" "$provider_id" "$coordinator_url"
  install_watchdog "$coordinator_url"
  write_install_manifest "$tag"
  start_manual_service "$model" "$provider_id" "$coordinator_url"

  if ! wait_for_local_model "$model"; then
    print_local_self_test_diagnostics
    exit 6
  fi

  # Keep rollback armed until coordinator admission proves the selected mode:
  # exact current/previous catalog identity for normal upgrades, or exact
  # session-bound buyer-serving legacy_bridge proof for an explicit signed
  # emergency downgrade.
  log "Waiting up to $(( ${MACPROVIDER_COORDINATOR_READY_TIMEOUT_SECONDS:-300} / 60 )) min for exact coordinator admission and buyer-serving readiness (cold model load on low-RAM Macs can take minutes)."
  if ! wait_for_coordinator "$provider_id" "$coordinator_base"; then
    if [ "${REPAIR_EXISTING_INSTALL:-0}" -eq 1 ]; then
      log "Coordinator did not admit the repaired provider yet; committing local repair and leaving coordinator rejoin as telemetry."
    elif [ "$EMERGENCY_ROLLBACK" = "1" ]; then
      log "Coordinator did not admit the restored provider through active legacy_bridge; rolling back."
      exit 6
    else
      log "Coordinator did not admit the exact local catalog envelope for buyer traffic; rolling back."
      exit 6
    fi
  fi
  if [ "$EMERGENCY_ROLLBACK" = "1" ]; then
    verify_emergency_config_activation
  fi
  commit_install_transaction

  pid="$(print_pid || true)"
  log "Ready to serve."
  log "PID: ${pid:-unknown}"
  log "Logs: tail -f $LOG_DIR/macprovider.out.log $LOG_DIR/macprovider.err.log"
  log "Coordinator pool check: $coordinator_base/v1/pool/check?provider_id=$(urlencode "$provider_id")"
  print_autotune_handoff
  log "Uninstall: bash <(curl -fsSL https://get.malibu.tech/uninstall.sh)"
}

main "$@"
