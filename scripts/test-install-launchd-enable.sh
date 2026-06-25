#!/usr/bin/env bash
# Hermetic guard for install.sh launchd recovery sequencing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_SH="$REPO_ROOT/phase3-binary/dist/install.sh"

die() {
  printf '[install-launchd-test] ERROR: %s\n' "$*" >&2
  exit 1
}

require_line() {
  local pattern="$1"
  local description="$2"
  if ! grep -Fq "$pattern" "$INSTALL_SH"; then
    die "missing $description: $pattern"
  fi
}

line_number() {
  local pattern="$1"
  awk -v pattern="$pattern" 'index($0, pattern) { print NR; exit }' "$INSTALL_SH"
}

require_line 'launchctl bootout "gui/$UID" "$PLIST_PATH"' "launchd bootout before replacement"
require_line 'launchctl enable "gui/$UID/live.streamvc.macprovider"' "launchd enable before bootstrap"
require_line 'launchctl bootstrap "gui/$UID" "$PLIST_PATH"' "launchd bootstrap"
require_line 'Would enable launchd service: launchctl enable gui/$UID/live.streamvc.macprovider' "dry-run enable hint"

bootout_line="$(line_number 'launchctl bootout "gui/$UID" "$PLIST_PATH"')"
enable_line="$(line_number 'launchctl enable "gui/$UID/live.streamvc.macprovider"')"
bootstrap_line="$(line_number 'launchctl bootstrap "gui/$UID" "$PLIST_PATH"')"

[ -n "$bootout_line" ] || die "could not locate bootout line"
[ -n "$enable_line" ] || die "could not locate enable line"
[ -n "$bootstrap_line" ] || die "could not locate bootstrap line"

if [ "$bootout_line" -ge "$enable_line" ] || [ "$enable_line" -ge "$bootstrap_line" ]; then
  die "launchd sequence must be bootout -> enable -> bootstrap; got $bootout_line -> $enable_line -> $bootstrap_line"
fi

printf '[install-launchd-test] install.sh launchd enable sequencing ok\n'
