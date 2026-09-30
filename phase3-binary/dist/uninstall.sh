#!/usr/bin/env bash
# Public uninstall script for the user-level Mac Provider install.

set -euo pipefail

INSTALL_DIR="$HOME/macprovider"
BIN_DIR="$HOME/.local/bin"
BINARY_PATH="$BIN_DIR/macprovider-cli"
# Malibu-branded PATH alias (#1261). Materialized by entrypoint convergence and
# not recorded in older manifests, so it is removed by its fixed path.
ALIAS_BINARY_PATH="$BIN_DIR/malibu-cli"
PLIST_PATH="$HOME/Library/LaunchAgents/live.malibu.provider.plist"
LEGACY_PLIST_PATH="$HOME/Library/LaunchAgents/live.streamvc.macprovider.plist"
LOG_DIR="$HOME/Library/Logs/macprovider"
CACHE_DIR="$HOME/.cache/macprovider"
MANIFEST_DIR="$HOME/Library/Application Support/macprovider"
MANIFEST_PATH="$MANIFEST_DIR/install_manifest.json"
WATCHDOG_DIR="$HOME/.local/share/macprovider-watchdog"
WATCHDOG_PLIST_PATH="$HOME/Library/LaunchAgents/live.malibu.provider-watchdog.plist"
LEGACY_WATCHDOG_PLIST_PATH="$HOME/Library/LaunchAgents/live.streamvc.macprovider-watchdog.plist"
# Registered by install.sh for crash recovery and never recorded in the
# manifest, so it is booted out and removed by its fixed label.
INSTALL_RECOVERY_LABEL="live.malibu.provider-install-recovery"
INSTALL_RECOVERY_PLIST_PATH="$HOME/Library/LaunchAgents/$INSTALL_RECOVERY_LABEL.plist"
INSTALL_LOCK_PATH="$HOME/.config/macprovider/install.lock"
# Same autoupdate residue the CLI uninstaller removes (#1420): a stale
# pending.json makes the next install.sh refuse to run.
AUTOUPDATE_RESIDUE_DIR="$HOME/.local/share/macprovider/autoupdate"
CLI_URL_CACHE_DIR="$HOME/Library/Caches/macprovider-cli"
CLI_HTTP_STORAGE_DIR="$HOME/Library/HTTPStorages/macprovider-cli"
# The Malibu app runs install.sh with TMPDIR=/tmp, so installer leftovers can
# sit there as well as in the user's TMPDIR. Overridable for tests.
SYSTEM_TMP_DIR="${MACPROVIDER_UNINSTALL_SYSTEM_TMPDIR:-/tmp}"
CLI_DELEGATED=0
UNINSTALL_LOCK_HELPER_PID=""
UNINSTALL_LOCK_STATUS_PATH=""
DRY_RUN=0
NO_PROMPT="${MACPROVIDER_NO_PROMPT:-0}"

log() { printf "[macprovider-uninstall] %s\n" "$*"; }
die() {
  printf "[macprovider-uninstall] ERROR: %s\n" "$*" >&2
  exit 7
}

read_line() {
  REPLY=""
  if [ -r /dev/tty ]; then
    IFS= read -r REPLY < /dev/tty || REPLY=""
  else
    IFS= read -r REPLY || REPLY=""
  fi
}

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      printf "Usage: bash uninstall.sh [--dry-run]\n"
      exit 0
      ;;
    *) die "unknown argument: $arg" ;;
  esac
done

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf "[dry-run] "
    printf "%q " "$@"
    printf "\n"
  else
    "$@"
  fi
}

canonicalize_path() {
  python3 - "$1" <<'PY'
import os, sys
print(os.path.realpath(os.path.expanduser(sys.argv[1])))
PY
}

manifest_json_value() {
  key="$1"
  [ -f "$MANIFEST_PATH" ] || return 1
  python3 - "$MANIFEST_PATH" "$key" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
value = data.get(sys.argv[2])
if isinstance(value, str):
    print(value)
elif isinstance(value, list):
    for item in value:
        if isinstance(item, str):
            print(item)
PY
}

allowed_remove_path() {
  candidate="$(canonicalize_path "$1")"
  shift
  for allowed in "$@"; do
    [ -n "$allowed" ] || continue
    allowed_canon="$(canonicalize_path "$allowed")"
    [ "$candidate" = "$allowed_canon" ] && return 0
  done
  return 1
}

remove_tree_if_allowed() {
  label="$1"
  path="$2"
  shift 2
  [ -n "$path" ] || return 0
  [ -e "$path" ] || [ -L "$path" ] || return 0
  if ! allowed_remove_path "$path" "$@"; then
    die "refusing unsafe $label path: $path"
  fi
  run rm -rf "$path"
}

confirm() {
  if [ "$NO_PROMPT" = "1" ]; then
    log "Proceeding without prompt because MACPROVIDER_NO_PROMPT=1."
    return 0
  fi

  cat <<EOF
This will remove the macprovider launchd services, installed binary, install prefix,
watchdog files, and logs recorded in $MANIFEST_PATH, plus leftover installer files.

It keeps the provider identity (~/.config/macprovider and its credential) so a
reinstall recovers the same provider, and does not remove $CACHE_DIR or
Hugging Face model caches.
EOF
  printf "Uninstall Mac Provider? [y/N] "
  read_line
  answer="$REPLY"
  case "$answer" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

release_uninstall_lock() {
  if [ -n "$UNINSTALL_LOCK_HELPER_PID" ]; then
    kill "$UNINSTALL_LOCK_HELPER_PID" 2>/dev/null || true
    wait "$UNINSTALL_LOCK_HELPER_PID" 2>/dev/null || true
    UNINSTALL_LOCK_HELPER_PID=""
  fi
  if [ -n "$UNINSTALL_LOCK_STATUS_PATH" ]; then
    rm -f "$UNINSTALL_LOCK_STATUS_PATH"
    UNINSTALL_LOCK_STATUS_PATH=""
  fi
}

# Hold the installer's kernel lock for the whole destructive transaction.
# A live owner record remains authoritative even if its flock helper died,
# matching install.sh recovery fencing. Unsafe lock paths/records fail closed.
acquire_uninstall_lock() {
  [ "$DRY_RUN" -eq 0 ] || return 0
  UNINSTALL_LOCK_STATUS_PATH="$(mktemp "${TMPDIR:-/tmp}/macprovider-uninstall-lock.XXXXXX")" \
    || die "could not allocate uninstall lock handshake"
  python3 - "$HOME" "$INSTALL_LOCK_PATH" "$$" "$UNINSTALL_LOCK_STATUS_PATH" <<'LOCKHOLDER' &
import fcntl, json, os, signal, stat, subprocess, sys, time

home, lock_path, owner_pid_text, status_path = sys.argv[1:]
owner_pid = int(owner_pid_text)
uid = os.getuid()

def status(value):
    fd = os.open(status_path, os.O_WRONLY | os.O_TRUNC | getattr(os, "O_NOFOLLOW", 0))
    try:
        os.write(fd, (value + "\n").encode())
        os.fsync(fd)
    finally:
        os.close(fd)

def command(argv):
    result = subprocess.run(argv, check=False, capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else ""

try:
    home = os.path.realpath(home)
    config_dir = os.path.realpath(os.path.dirname(lock_path))
    if os.path.commonpath((home, config_dir)) != home:
        raise RuntimeError("lock directory escapes HOME")
    current = home
    for component in os.path.relpath(config_dir, home).split(os.sep):
        current = os.path.join(current, component)
        if not os.path.lexists(current):
            os.mkdir(current, 0o700)
        info = os.lstat(current)
        if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode) or info.st_uid != uid or info.st_mode & 0o022:
            raise RuntimeError("unsafe lock directory")
    fd = os.open(lock_path, os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o600)
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != uid or info.st_nlink != 1 or info.st_mode & 0o077:
        raise RuntimeError("install lock is not an owned private regular file")
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        status("busy")
        sys.exit(0)
    payload = os.read(fd, 4097)
    if len(payload) > 4096:
        raise RuntimeError("install lock record is oversized")
    if payload.strip():
        try:
            record = json.loads(payload.decode("utf-8"))
        except (UnicodeDecodeError, ValueError) as exc:
            raise RuntimeError("install lock record is malformed") from exc
        if not isinstance(record, dict):
            raise RuntimeError("install lock record is malformed")
        pid, started, boot = record.get("pid"), record.get("process_start"), record.get("boot_session")
        if not (isinstance(pid, int) and isinstance(started, str) and started and isinstance(boot, str) and boot):
            raise RuntimeError("install lock record is malformed")
        if command(["/usr/sbin/sysctl", "-n", "kern.bootsessionuuid"]) == boot \
                and command(["ps", "-p", str(pid), "-o", "lstart="]) == started:
            status("busy")
            sys.exit(0)
    record = {
        "pid": owner_pid,
        "process_start": command(["ps", "-p", str(owner_pid), "-o", "lstart="]),
        "boot_session": command(["/usr/sbin/sysctl", "-n", "kern.bootsessionuuid"]),
        "operation": "uninstall",
        "holder_pid": os.getpid(),
    }
    if not record["process_start"] or not record["boot_session"]:
        raise RuntimeError("could not establish uninstall lock identity")
    os.lseek(fd, 0, os.SEEK_SET)
    os.ftruncate(fd, 0)
    os.write(fd, json.dumps(record, sort_keys=True).encode())
    os.fsync(fd)
    status("acquired")
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    signal.signal(signal.SIGINT, lambda *_: sys.exit(0))
    while True:
        try:
            os.kill(owner_pid, 0)
        except OSError:
            break
        time.sleep(0.2)
except Exception as exc:
    try:
        status("unsafe:" + str(exc))
    except Exception:
        pass
    sys.exit(1)
LOCKHOLDER
  UNINSTALL_LOCK_HELPER_PID=$!
  for _ in $(seq 1 400); do
    [ -s "$UNINSTALL_LOCK_STATUS_PATH" ] && break
    kill -0 "$UNINSTALL_LOCK_HELPER_PID" 2>/dev/null || break
    sleep 0.05
  done
  lock_status="$(cat "$UNINSTALL_LOCK_STATUS_PATH" 2>/dev/null || true)"
  case "$lock_status" in
    acquired)
      trap release_uninstall_lock EXIT
      trap 'release_uninstall_lock; exit 130' HUP INT TERM
      ;;
    busy) release_uninstall_lock; die "an installer is still running; let it finish or stop it, then re-run." ;;
    unsafe:*) release_uninstall_lock; die "refusing unsafe install lock state: ${lock_status#unsafe:}" ;;
    *) release_uninstall_lock; die "could not acquire the install lock safely" ;;
  esac
}

assert_safe_application_support() {
  python3 - "$HOME" "$MANIFEST_DIR" <<'PY'
import os, stat, sys
home, support = map(os.path.abspath, sys.argv[1:])
uid = os.getuid()
if os.path.commonpath((home, support)) != home:
    raise SystemExit("Application Support path escapes HOME")
current = home
for component in os.path.relpath(support, home).split(os.sep):
    current = os.path.join(current, component)
    if not os.path.lexists(current):
        break
    info = os.lstat(current)
    if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode) or info.st_uid != uid or info.st_mode & 0o022:
        raise SystemExit("unsafe Application Support directory: " + current)
lifecycle = os.path.join(support, "lifecycle")
if os.path.lexists(lifecycle):
    info = os.lstat(lifecycle)
    if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode) or info.st_uid != uid or info.st_mode & 0o022:
        raise SystemExit("unsafe lifecycle directory: " + lifecycle)
PY
}

manifest_cli_path() {
  [ -e "$MANIFEST_PATH" ] || [ -L "$MANIFEST_PATH" ] || return 1
  python3 - "$MANIFEST_PATH" <<'PY'
import json, os, stat, sys
path = sys.argv[1]
uid = os.getuid()
flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
try:
    fd = os.open(path, flags)
except OSError as exc:
    raise SystemExit("unsafe install manifest: " + str(exc))
try:
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != uid or info.st_nlink != 1 or info.st_mode & 0o022:
        raise SystemExit("install manifest is not a trusted regular file")
    payload = os.read(fd, 65537)
    if len(payload) > 65536:
        raise SystemExit("install manifest is oversized")
finally:
    os.close(fd)
try:
    manifest = json.loads(payload.decode("utf-8"))
except (UnicodeDecodeError, ValueError) as exc:
    raise SystemExit("install manifest is malformed: " + str(exc))
prefix = manifest.get("install_prefix")
binary = manifest.get("binary_path")
if not isinstance(prefix, str) or not isinstance(binary, str) or not prefix or not binary:
    raise SystemExit("install manifest lacks install_prefix/binary_path")
prefix = os.path.normpath(prefix)
binary = os.path.normpath(binary)
if not os.path.isabs(prefix) or binary != os.path.join(prefix, "macprovider-cli"):
    raise SystemExit("install manifest binary_path is not the installed CLI")
try:
    info = os.stat(binary, follow_symlinks=False)
except OSError as exc:
    raise SystemExit("manifest-installed CLI is unavailable: " + str(exc))
if not stat.S_ISREG(info.st_mode) or info.st_uid != uid or info.st_mode & 0o022 or not os.access(binary, os.X_OK):
    raise SystemExit("manifest-installed CLI is not a trusted executable")
print(binary)
PY
}

validate_manifest_removal_paths() {
  [ -e "$MANIFEST_PATH" ] || [ -L "$MANIFEST_PATH" ] || return 0
  python3 - "$MANIFEST_PATH" "$INSTALL_DIR" "$LOG_DIR" "$WATCHDOG_DIR" <<'PY'
import json, os, stat, sys
path, default_prefix, log_dir, watchdog_dir = sys.argv[1:]
fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
try:
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
        raise SystemExit("unsafe install manifest")
    payload = os.read(fd, 65537)
finally:
    os.close(fd)
if len(payload) > 65536:
    raise SystemExit("unsafe install manifest")
try:
    manifest = json.loads(payload.decode("utf-8"))
except (UnicodeDecodeError, ValueError):
    raise SystemExit("unsafe install manifest")
prefix = manifest.get("install_prefix") or default_prefix
if not isinstance(prefix, str) or not os.path.isabs(prefix):
    raise SystemExit("unsafe install manifest")
allowed = {os.path.realpath(value) for value in (prefix, log_dir, watchdog_dir)}
for candidate in manifest.get("data_dirs") or []:
    if not isinstance(candidate, str) or os.path.realpath(candidate) not in allowed:
        raise SystemExit("refusing unsafe data directory path: " + str(candidate))
PY
}

canonical_cli_path() {
  [ -x "$BINARY_PATH" ] || return 1
  python3 - "$BINARY_PATH" <<'PY'
import os, stat, sys
path = os.path.realpath(sys.argv[1])
try:
    info = os.stat(path, follow_symlinks=False)
except OSError:
    raise SystemExit(1)
if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022 or not os.access(path, os.X_OK):
    raise SystemExit("canonical CLI does not resolve to a trusted executable")
print(path)
PY
}

# The installed CLI's typed uninstall proves launchd absence (including the
# system domain) and purges the KV tier. Resolve the install-manifest binary
# before the canonical PATH symlink so custom-prefix installs cannot be skipped.
delegate_to_cli() {
  cli_path=""
  if [ -e "$MANIFEST_PATH" ] || [ -L "$MANIFEST_PATH" ]; then
    cli_path="$(manifest_cli_path)" || die "could not validate the CLI recorded in $MANIFEST_PATH"
  else
    cli_path="$(canonical_cli_path 2>/dev/null || true)"
  fi
  [ -n "$cli_path" ] || return 0
  log "Running the installed CLI uninstaller: $cli_path uninstall --yes"
  if ! run "$cli_path" uninstall --yes; then
    die "the CLI uninstaller did not complete; resolve the message above and re-run. Only if $cli_path fails to start at all (not when it refused because services are still running) remove it and re-run this script."
  fi
  CLI_DELEGATED=1
}

# Fallback cleanup may run without the typed CLI uninstaller, so it must prove
# every user launchd job is absent before deleting files that a live process
# could still be using. `bootout` alone is not proof: launchctl can fail for
# reasons other than an already-absent job.
stop_user_launchd_job() {
  local label="$1"
  local target="gui/$UID/$label"
  local bootout_status=0 print_output="" print_status=0
  if [ "$DRY_RUN" -eq 1 ]; then
    run launchctl bootout "$target"
    return 0
  fi

  launchctl bootout "$target" >/dev/null 2>&1 || bootout_status=$?
  print_output="$(launchctl print "$target" 2>&1)" && print_status=0 || print_status=$?
  if [ "$print_status" -eq 0 ]; then
    die "launchd job is still loaded after bootout: $label"
  fi
  case "$print_output" in
    *"Could not find service"*|*"could not find service"*|*"No such process"*|*"no such process"*)
      return 0
      ;;
  esac
  die "could not prove launchd job is absent: $label (bootout status $bootout_status, print status $print_status)"
}

remove_owned_temp() {
  path="$1"
  [ -e "$path" ] || return 0
  [ -L "$path" ] && return 0
  [ -O "$path" ] || return 0
  run rm -rf "$path"
}

# Transient installer and onboarding files: the referral-code handoff file,
# the CLI tarball staging directory, the Python and update staging
# directories, and autotune candidate configs. Only user-owned, non-symlink
# entries with these exact prefixes are touched.
remove_temp_residue() {
  user_tmp="${TMPDIR:-/tmp}"
  user_tmp="${user_tmp%/}"
  system_tmp="${SYSTEM_TMP_DIR%/}"
  for tmp_root in "$user_tmp" "$system_tmp"; do
    for path in "$tmp_root"/macprovider-referral-* "$tmp_root"/macprovider-update-* \
        "$tmp_root"/macprovider-python.* "$tmp_root"/macprovider-autotune-config-*; do
      remove_owned_temp "$path"
    done
    for dir in "$tmp_root"/tmp.*; do
      [ -d "$dir" ] || continue
      ls "$dir"/macprovider-cli-*.tar.gz >/dev/null 2>&1 || continue
      remove_owned_temp "$dir"
    done
    [ "$user_tmp" != "$system_tmp" ] || break
  done
}

# Mirrors the CLI uninstaller's application-support cleanup: remove
# everything except the lifecycle tombstone (state-v1.json and its lock),
# which fences stale serve/updater/watchdog writers and lets Malibu.app
# report "uninstalled". A failed install never wrote state-v1.json, so there
# is no tombstone to keep. protected-credentials-v1 is only the credential
# store's unused default root (production custody is under
# ~/.config/macprovider); it is skipped defensively in case it was pointed
# here.
cleanup_application_support() {
  [ -d "$MANIFEST_DIR" ] || return 0
  assert_safe_application_support || die "refusing unsafe Application Support cleanup"
  keep_tombstone=0
  if python3 - "$MANIFEST_DIR/lifecycle/state-v1.json" <<'PY'
import json, os, stat, sys
path = sys.argv[1]
try:
    info = os.lstat(path)
    if not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode) or info.st_uid != os.getuid():
        raise ValueError("unsafe lifecycle state")
    with open(path, encoding="utf-8") as handle:
        state = json.load(handle)
    if not isinstance(state, dict) or state.get("state") != "uninstalled":
        raise ValueError("not an uninstall tombstone")
except (OSError, UnicodeDecodeError, ValueError):
    raise SystemExit(1)
PY
  then
    keep_tombstone=1
  fi
  for entry in "$MANIFEST_DIR"/* "$MANIFEST_DIR"/.[!.]*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    case "$(basename "$entry")" in
      protected-credentials-v1) continue ;;
      lifecycle)
        if [ "$keep_tombstone" -eq 1 ]; then
          for item in "$entry"/* "$entry"/.[!.]*; do
            [ -e "$item" ] || [ -L "$item" ] || continue
            case "$(basename "$item")" in
              state-v1.json|.state-v1.json.lock) continue ;;
            esac
            remove_tree_if_allowed "lifecycle entry" "$item" "$item"
          done
          continue
        fi
        ;;
    esac
    remove_tree_if_allowed "application support entry" "$entry" "$entry"
  done
  if [ "$DRY_RUN" -ne 1 ]; then
    rmdir "$MANIFEST_DIR" 2>/dev/null || true
  fi
}

main() {
  if ! confirm; then
    log "Aborted."
    exit 7
  fi
  acquire_uninstall_lock
  assert_safe_application_support || die "refusing unsafe Application Support path"
  validate_manifest_removal_paths
  delegate_to_cli

  manifest_missing=0
  if [ ! -f "$MANIFEST_PATH" ]; then
    manifest_missing=1
    if [ "$CLI_DELEGATED" -ne 1 ]; then
      log "WARNING: install manifest missing; falling back to known legacy locations."
    fi
  fi

  labels="$(manifest_json_value launchd_labels 2>/dev/null || true)"
  if [ -z "$labels" ]; then
    labels="live.malibu.provider
live.malibu.provider-watchdog
live.streamvc.macprovider
live.streamvc.macprovider-watchdog"
  fi
  while IFS= read -r label; do
    [ -n "$label" ] || continue
    stop_user_launchd_job "$label"
  done <<EOF
$labels
EOF
  stop_user_launchd_job "$INSTALL_RECOVERY_LABEL"
  remove_tree_if_allowed "plist" "$INSTALL_RECOVERY_PLIST_PATH" "$INSTALL_RECOVERY_PLIST_PATH"

  plists="$(manifest_json_value launchd_plists 2>/dev/null || true)"
  if [ -z "$plists" ]; then
    plists="$PLIST_PATH
$WATCHDOG_PLIST_PATH
$LEGACY_PLIST_PATH
$LEGACY_WATCHDOG_PLIST_PATH"
  fi
  while IFS= read -r plist; do
    [ -n "$plist" ] || continue
    [ -e "$plist" ] || [ -L "$plist" ] || continue
    remove_tree_if_allowed "plist" "$plist" "$PLIST_PATH" "$WATCHDOG_PLIST_PATH" "$LEGACY_PLIST_PATH" "$LEGACY_WATCHDOG_PLIST_PATH"
  done <<EOF
$plists
EOF

  symlink_path="$(manifest_json_value symlink_path 2>/dev/null | head -1 || true)"
  [ -n "$symlink_path" ] || symlink_path="$BINARY_PATH"
  remove_tree_if_allowed "binary symlink" "$symlink_path" "$BINARY_PATH"
  # Remove the malibu-cli alias only when it is a symlink we own -- one pointing
  # exactly at the canonical entrypoint ($BINARY_PATH) -- never an unrelated user
  # file or a symlink to some other target at that path (#1261). readlink (not
  # -e) so a dangling owned alias is still cleaned up.
  if [ -L "$ALIAS_BINARY_PATH" ]; then
    alias_target="$(readlink "$ALIAS_BINARY_PATH" 2>/dev/null || true)"
    if [ "$alias_target" = "$BINARY_PATH" ]; then
      remove_tree_if_allowed "malibu-cli alias symlink" "$ALIAS_BINARY_PATH" "$ALIAS_BINARY_PATH"
    fi
  fi

  # The CLI uninstaller already removed the manifest's data directories and
  # deleted the manifest itself; falling back to the default $INSTALL_DIR
  # here would delete an unrelated ~/macprovider when the install used a
  # custom MACPROVIDER_INSTALL_DIR.
  if [ "$CLI_DELEGATED" -ne 1 ]; then
    data_dirs="$(manifest_json_value data_dirs 2>/dev/null || true)"
    if [ "$manifest_missing" -eq 1 ] || [ -z "$data_dirs" ]; then
      data_dirs="$INSTALL_DIR
$LOG_DIR
$WATCHDOG_DIR"
    fi
    install_prefix="$(manifest_json_value install_prefix 2>/dev/null | head -1 || true)"
    [ -n "$install_prefix" ] || install_prefix="$INSTALL_DIR"
    while IFS= read -r dir; do
      [ -n "$dir" ] || continue
      remove_tree_if_allowed "data directory" "$dir" "$install_prefix" "$LOG_DIR" "$WATCHDOG_DIR"
    done <<EOF
$data_dirs
EOF
  fi

  if [ -f "$MANIFEST_PATH" ]; then
    run rm -f "$MANIFEST_PATH"
  fi
  cleanup_application_support
  remove_tree_if_allowed "autoupdate residue" "$AUTOUPDATE_RESIDUE_DIR" "$AUTOUPDATE_RESIDUE_DIR"
  for dir in "$CLI_URL_CACHE_DIR" "$CLI_HTTP_STORAGE_DIR"; do
    remove_tree_if_allowed "CLI HTTP cache" "$dir" "$dir"
  done
  remove_temp_residue

  log "macprovider-cli has been uninstalled."
  if [ -d "$CACHE_DIR" ]; then
    log "Left cache directory in place: $CACHE_DIR"
  fi
  log "If you want to fully uninstall MLX-cached models from ~/.cache/huggingface/, do that manually."
}

main "$@"
