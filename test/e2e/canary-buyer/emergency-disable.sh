#!/usr/bin/env bash
# Immediately prevents new canary load. The sentinel is checked before any
# credential resolution or network call; scheduler shutdown is defense in depth.
set -euo pipefail

if [[ "$(uname -s)" == "Darwin" ]]; then
  : "${CANARY_DISABLE_FILE:=${HOME:-/nonexistent}/.local/state/canary-buyer/DISABLED}"
  : "${CANARY_ENABLE_FILE:=${HOME:-/nonexistent}/.config/macprovider/canary-buyer.enabled}"
else
  : "${CANARY_DISABLE_FILE:=/var/lib/macprovider-canary-buyer/DISABLED}"
  : "${CANARY_ENABLE_FILE:=/etc/macprovider/canary-buyer.enabled}"
fi

mkdir -p "$(dirname "$CANARY_DISABLE_FILE")"
: >"$CANARY_DISABLE_FILE"
chmod 0644 "$CANARY_DISABLE_FILE"
rm -f "$CANARY_ENABLE_FILE"

SYSTEMCTL_BIN="${CANARY_SYSTEMCTL_BIN:-$(command -v systemctl || true)}"
if [[ -n "$SYSTEMCTL_BIN" && ( -n "${CANARY_SYSTEMCTL_BIN:-}" || -d /run/systemd/system ) ]]; then
  "$SYSTEMCTL_BIN" disable --now canary-buyer.timer
fi

LAUNCHCTL_BIN="${CANARY_LAUNCHCTL_BIN:-$(command -v launchctl || true)}"
if [[ -n "$LAUNCHCTL_BIN" && "$(uname -s)" == "Darwin" ]]; then
  "$LAUNCHCTL_BIN" bootout "gui/$(id -u)/com.streamvc.canary-buyer" 2>/dev/null || true
fi

echo "canary: class=emergency_disabled sentinel=$CANARY_DISABLE_FILE scheduler_stopped=true"
