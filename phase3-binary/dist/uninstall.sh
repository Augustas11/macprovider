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

# True while an installer is live: it holds install.lock, or (as install.sh
# itself fences) the lock's owner record names a process that is still
# running in this boot session even though its flock helper has died.
# Uninstalling underneath it would pull launchd jobs, transaction and
# staging state from a live install.
installer_active() {
  [ -f "$INSTALL_LOCK_PATH" ] || return 1
  python3 - "$INSTALL_LOCK_PATH" <<'LOCKCHECK'
import fcntl, json, os, subprocess, sys
try:
    fd = os.open(sys.argv[1], os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
except OSError:
    sys.exit(1)
try:
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    sys.exit(0)
try:
    record = json.loads(os.read(fd, 4097).decode("utf-8") or "{}")
except (ValueError, UnicodeDecodeError, OSError):
    sys.exit(1)
if not isinstance(record, dict):
    sys.exit(1)
pid, started, boot = record.get("pid"), record.get("process_start"), record.get("boot_session")
if not (isinstance(pid, int) and isinstance(started, str) and started and isinstance(boot, str) and boot):
    sys.exit(1)
def run(argv):
    result = subprocess.run(argv, check=False, capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else ""
if run(["/usr/sbin/sysctl", "-n", "kern.bootsessionuuid"]) == boot and run(["ps", "-p", str(pid), "-o", "lstart="]) == started:
    sys.exit(0)
sys.exit(1)
LOCKCHECK
}

# The installed CLI's typed uninstall proves launchd absence (including the
# system domain) and purges the KV tier. If it refuses, services may still be
# running, so stop instead of deleting files underneath them.
delegate_to_cli() {
  [ -x "$BINARY_PATH" ] || return 0
  log "Running the installed CLI uninstaller: $BINARY_PATH uninstall --yes"
  if ! run "$BINARY_PATH" uninstall --yes; then
    die "the CLI uninstaller did not complete; resolve the message above and re-run. Only if $BINARY_PATH fails to start at all (not when it refused because services are still running) remove it and re-run this script."
  fi
  CLI_DELEGATED=1
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
  keep_tombstone=0
  if [ -f "$MANIFEST_DIR/lifecycle/state-v1.json" ]; then
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
  if installer_active; then
    die "an installer is still running (it holds $INSTALL_LOCK_PATH); let it finish or stop it, then re-run."
  fi
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
    run launchctl bootout "gui/$UID/$label" >/dev/null 2>&1 || true
  done <<EOF
$labels
EOF
  run launchctl bootout "gui/$UID/$INSTALL_RECOVERY_LABEL" >/dev/null 2>&1 || true
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
