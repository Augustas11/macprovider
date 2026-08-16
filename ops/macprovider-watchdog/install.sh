#!/usr/bin/env bash
# Standalone installer for the macprovider-watchdog LaunchAgent.
#
# This script is also invoked by the main installer
# (phase3-binary/dist/install.sh) — it MUST be idempotent so a
# re-install does not double-load the LaunchAgent or leak the
# previous plist.

set -euo pipefail

WATCHDOG_DIR_DEFAULT="$HOME/.local/share/macprovider-watchdog"
WATCHDOG_DIR="${MACPROVIDER_WATCHDOG_DIR:-$WATCHDOG_DIR_DEFAULT}"
WATCHDOG_PATH="$WATCHDOG_DIR/macprovider-health-monitor"
PLIST_TEMPLATE_PATH="${MACPROVIDER_WATCHDOG_TEMPLATE:-$(cd "$(dirname "$0")" && pwd)/live.malibu.provider-watchdog.template.plist}"
SOURCE_WATCHDOG="$(cd "$(dirname "$0")" && pwd)/watchdog.sh"
PLIST_PATH="$HOME/Library/LaunchAgents/live.malibu.provider-watchdog.plist"
LEGACY_PLIST_PATH="$HOME/Library/LaunchAgents/live.streamvc.macprovider-watchdog.plist"
LOG_DIR="${MACPROVIDER_LOG_DIR:-$HOME/Library/Logs/macprovider}"
CONFIG_PATH="${MACPROVIDER_CONFIG_PATH:-$HOME/.config/macprovider/config.yaml}"
BINARY_PATH="${MACPROVIDER_BINARY_PATH:-$HOME/macprovider/macprovider-cli}"
COORDINATOR_HOST="${MACPROVIDER_COORDINATOR_HOST:-coordinator.malibu.tech}"
SERVICE_LABEL="${MACPROVIDER_SERVICE_LABEL:-live.malibu.provider}"
WATCHDOG_LABEL="live.malibu.provider-watchdog"
LEGACY_WATCHDOG_LABEL="live.streamvc.macprovider-watchdog"
DRY_RUN=0

log() { printf "[macprovider-watchdog-install] %s\n" "$*"; }
die() {
  printf "[macprovider-watchdog-install] ERROR: %s\n" "$*" >&2
  exit 1
}

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      printf "Usage: bash install.sh [--dry-run]\n"
      exit 0
      ;;
    *) die "unknown argument: $arg" ;;
  esac
done

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf "[dry-run] "; printf "%q " "$@"; printf "\n"
  else
    "$@"
  fi
}

# Best-effort XML escape. Same approach as the main installer's
# render_plist; keeps the substituted values safe inside the
# generated plist.
xml_escape() {
  printf "%s" "$1" | LC_ALL=C sed \
    -e 's/&/\&amp;/g' \
    -e 's/</\&lt;/g' \
    -e 's/>/\&gt;/g' \
    -e 's/"/\&quot;/g' \
    -e "s/'/\&apos;/g"
}

[ -r "$SOURCE_WATCHDOG" ] || die "missing source $SOURCE_WATCHDOG"
[ -r "$PLIST_TEMPLATE_PATH" ] || die "missing template $PLIST_TEMPLATE_PATH"

log "Installing watchdog to $WATCHDOG_DIR"
run mkdir -p "$WATCHDOG_DIR" "$LOG_DIR" "$(dirname "$PLIST_PATH")"

if [ "$DRY_RUN" -eq 0 ]; then
  legacy_watchdog="$WATCHDOG_DIR/watchdog.sh"
  if [ -f "$legacy_watchdog" ] && [ "$legacy_watchdog" != "$WATCHDOG_PATH" ]; then
    rm -f "$legacy_watchdog"
  fi
  install -m 0755 "$SOURCE_WATCHDOG" "$WATCHDOG_PATH"
else
  log "[dry-run] install -m 0755 $SOURCE_WATCHDOG $WATCHDOG_PATH"
fi

# Render the plist with the operator's actual paths substituted.
rendered="$(sed \
  -e "s|__WATCHDOG_PATH__|$(xml_escape "$WATCHDOG_PATH")|g" \
  -e "s|__LOG_DIR__|$(xml_escape "$LOG_DIR")|g" \
  -e "s|__USER_HOME__|$(xml_escape "$HOME")|g" \
  -e "s|__SERVICE_LABEL__|$(xml_escape "$SERVICE_LABEL")|g" \
  -e "s|__CONFIG_PATH__|$(xml_escape "$CONFIG_PATH")|g" \
  -e "s|__BINARY_PATH__|$(xml_escape "$BINARY_PATH")|g" \
  -e "s|__COORDINATOR_HOST__|$(xml_escape "$COORDINATOR_HOST")|g" \
  "$PLIST_TEMPLATE_PATH")"

if [ "$DRY_RUN" -eq 1 ]; then
  log "[dry-run] would write rendered plist to $PLIST_PATH:"
  printf "%s\n" "$rendered"
  log "[dry-run] would: launchctl bootout gui/$UID $PLIST_PATH (ignore if absent)"
  log "[dry-run] would: launchctl bootstrap gui/$UID $PLIST_PATH"
  exit 0
fi

printf "%s\n" "$rendered" > "$PLIST_PATH"
plutil -lint "$PLIST_PATH" >/dev/null || die "rendered watchdog plist is invalid"

# Idempotent re-install: bootout the old plist (silently if absent)
# before bootstrapping the new one. This is the same pattern the
# main installer uses for the provider LaunchAgent.
launchctl bootout "gui/$UID" "$PLIST_PATH" >/dev/null 2>&1 || true
launchctl bootout "gui/$UID/$LEGACY_WATCHDOG_LABEL" >/dev/null 2>&1 || true
rm -f "$LEGACY_PLIST_PATH"
launchctl disable "gui/$UID/$LEGACY_WATCHDOG_LABEL" >/dev/null 2>&1 || true
launchctl enable "gui/$UID/$WATCHDOG_LABEL" || die "failed to enable watchdog"
launchctl bootstrap "gui/$UID" "$PLIST_PATH" || die "failed to bootstrap watchdog"

log "Watchdog installed. Inspect logs at $LOG_DIR/watchdog.log"
