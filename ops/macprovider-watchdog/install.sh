#!/usr/bin/env bash
# install.sh — install the macprovider-watchdog LaunchAgent.
# Idempotent: safe to re-run after edits to the plist or script.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
label="live.streamvc.macprovider-watchdog"
plist_src="${here}/${label}.plist"
plist_dst="${HOME}/Library/LaunchAgents/${label}.plist"

# 1. Make the script executable.
chmod +x "${here}/watchdog.sh"

# 2. Copy plist into ~/Library/LaunchAgents.
mkdir -p "${HOME}/Library/LaunchAgents"
cp -f "${plist_src}" "${plist_dst}"
echo "installed plist to ${plist_dst}"

# 3. If already loaded, bootout first so the new plist takes effect.
uid_num="$(id -u)"
if launchctl print "gui/${uid_num}/${label}" >/dev/null 2>&1; then
  echo "watchdog already loaded; bootout to refresh"
  launchctl bootout "gui/${uid_num}" "${plist_dst}" || true
fi

# 4. Bootstrap (load).
launchctl bootstrap "gui/${uid_num}" "${plist_dst}"
echo "bootstrapped: gui/${uid_num}/${label}"

# 5. Kickstart so RunAtLoad fires immediately even if it didn't.
launchctl kickstart "gui/${uid_num}/${label}" || true

# 6. Show that it's loaded.
launchctl list | grep "${label}" || echo "warning: not visible in launchctl list yet"
echo
echo "watchdog will fire every 60s."
echo "log: ${HOME}/Library/Logs/macprovider/watchdog.log"
