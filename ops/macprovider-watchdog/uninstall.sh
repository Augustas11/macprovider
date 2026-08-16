#!/usr/bin/env bash
# Standalone uninstaller for the macprovider-watchdog LaunchAgent.

set -euo pipefail

WATCHDOG_DIR="${MACPROVIDER_WATCHDOG_DIR:-$HOME/.local/share/macprovider-watchdog}"
PLIST_PATH="$HOME/Library/LaunchAgents/live.malibu.provider-watchdog.plist"
LEGACY_PLIST_PATH="$HOME/Library/LaunchAgents/live.streamvc.macprovider-watchdog.plist"
DRY_RUN=0

log() { printf "[macprovider-watchdog-uninstall] %s\n" "$*"; }

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      printf "Usage: bash uninstall.sh [--dry-run]\n"
      exit 0
      ;;
    *)
      printf "[macprovider-watchdog-uninstall] ERROR: unknown argument: %s\n" "$arg" >&2
      exit 1
      ;;
  esac
done

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf "[dry-run] "; printf "%q " "$@"; printf "\n"
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

expected_prefix="$(canonicalize_path "$HOME/.local/share/macprovider-watchdog")"
candidate="$(canonicalize_path "$WATCHDOG_DIR")"
if [ "$candidate" != "$expected_prefix" ]; then
  printf "[macprovider-watchdog-uninstall] ERROR: refusing non-standard watchdog dir: %s\n" "$WATCHDOG_DIR" >&2
  exit 1
fi

removed_plist=0
for plist in "$PLIST_PATH" "$LEGACY_PLIST_PATH"; do
  if [ -f "$plist" ]; then
    run launchctl bootout "gui/$UID" "$plist" >/dev/null 2>&1 || true
    run rm -f "$plist"
    removed_plist=1
  fi
done
if [ "$removed_plist" -eq 0 ]; then
  log "No watchdog plist found at $PLIST_PATH or $LEGACY_PLIST_PATH"
else
  run launchctl disable "gui/$UID/live.streamvc.macprovider-watchdog" >/dev/null 2>&1 || true
fi

if [ -d "$WATCHDOG_DIR" ]; then
  run rm -rf "$WATCHDOG_DIR"
fi

log "Watchdog uninstalled."
