#!/usr/bin/env bash
# Public uninstall script for the user-level Mac Provider install.

set -euo pipefail

INSTALL_DIR="$HOME/macprovider"
BIN_DIR="$HOME/.local/bin"
BINARY_PATH="$BIN_DIR/macprovider-cli"
PLIST_PATH="$HOME/Library/LaunchAgents/live.malibu.provider.plist"
LEGACY_PLIST_PATH="$HOME/Library/LaunchAgents/live.streamvc.macprovider.plist"
LOG_DIR="$HOME/Library/Logs/macprovider"
CACHE_DIR="$HOME/.cache/macprovider"
MANIFEST_DIR="$HOME/Library/Application Support/macprovider"
MANIFEST_PATH="$MANIFEST_DIR/install_manifest.json"
WATCHDOG_DIR="$HOME/.local/share/macprovider-watchdog"
WATCHDOG_PLIST_PATH="$HOME/Library/LaunchAgents/live.malibu.provider-watchdog.plist"
LEGACY_WATCHDOG_PLIST_PATH="$HOME/Library/LaunchAgents/live.streamvc.macprovider-watchdog.plist"
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
watchdog files, and logs recorded in $MANIFEST_PATH.

It will not remove $CACHE_DIR, Hugging Face caches, or other files outside these paths.
EOF
  printf "Uninstall Mac Provider? [y/N] "
  read_line
  answer="$REPLY"
  case "$answer" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

main() {
  if ! confirm; then
    log "Aborted."
    exit 7
  fi

  manifest_missing=0
  if [ ! -f "$MANIFEST_PATH" ]; then
    manifest_missing=1
    log "WARNING: install manifest missing; falling back to known legacy locations."
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

  if [ -f "$MANIFEST_PATH" ]; then
    run rm -f "$MANIFEST_PATH"
  fi
  rmdir "$MANIFEST_DIR" 2>/dev/null || true

  log "macprovider-cli has been uninstalled."
  if [ -d "$CACHE_DIR" ]; then
    log "Left cache directory in place: $CACHE_DIR"
  fi
  log "If you want to fully uninstall MLX-cached models from ~/.cache/huggingface/, do that manually."
}

main "$@"
