#!/usr/bin/env bash
# Standalone uninstaller for the macprovider-watchdog LaunchAgent.

set -euo pipefail

WATCHDOG_DIR="${MACPROVIDER_WATCHDOG_DIR:-$HOME/.local/share/macprovider-watchdog}"
PLIST_PATH="$HOME/Library/LaunchAgents/live.streamvc.macprovider-watchdog.plist"
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

# Refuse to operate outside the expected install prefix so a
# misconfigured env var cannot rm -rf an arbitrary directory.
expected_prefix="$HOME/.local/share/macprovider-watchdog"
case "$WATCHDOG_DIR" in
  "$expected_prefix"|"$expected_prefix"/*) ;;
  *)
    printf "[macprovider-watchdog-uninstall] ERROR: refusing non-standard watchdog dir: %s\n" "$WATCHDOG_DIR" >&2
    exit 1
    ;;
esac

if [ -f "$PLIST_PATH" ]; then
  run launchctl bootout "gui/$UID" "$PLIST_PATH" >/dev/null 2>&1 || true
  run rm -f "$PLIST_PATH"
else
  log "No watchdog plist found at $PLIST_PATH"
fi

if [ -d "$WATCHDOG_DIR" ]; then
  run rm -rf "$WATCHDOG_DIR"
fi

log "Watchdog uninstalled."
