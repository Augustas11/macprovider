#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
INSTALL_SH="$REPO_ROOT/phase3-binary/dist/install.sh"
PLIST_TEMPLATE="$REPO_ROOT/phase3-binary/dist/launchd-plist-template.plist"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

awk '/^xml_escape\(\)/ { inside=1 } inside { print } inside && /^}/ { inside=0 }' "$INSTALL_SH" > "$TMP/render.sh"
awk '/^render_plist\(\)/ { inside=1 } inside { print } inside && /^}/ { exit }' "$INSTALL_SH" >> "$TMP/render.sh"

HOME="$TMP/home"
INSTALL_DIR="/opt/mp"
CONFIG_PATH="$HOME/.config/macprovider/config.yaml"
LOG_DIR="$HOME/Library/Logs/macprovider"
PORT=18080
mkdir -p "$HOME"

# shellcheck source=/dev/null
source "$TMP/render.sh"
plist="$(render_plist 'mlx-community/Qwen2.5-7B-Instruct-4bit' 'provider-1' 'wss://coordinator.malibu.tech/ws/provider')"

printf "%s\n" "$plist" | grep -A1 '<key>WorkingDirectory</key>' | grep -F '<string>/opt/mp</string>' >/dev/null
printf "%s\n" "$plist" | grep -A8 '<key>ProgramArguments</key>' | grep -F '<string>serve</string>' >/dev/null
printf "%s\n" "$plist" | grep -A8 '<key>ProgramArguments</key>' | grep -F '<string>--config</string>' >/dev/null
printf "%s\n" "$plist" | grep -A8 '<key>ProgramArguments</key>' | grep -F "<string>$CONFIG_PATH</string>" >/dev/null
if printf "%s\n" "$plist" | grep -Eq '<string>--(model|provider-id|coordinator|port)</string>'; then
  echo "mutable provider settings leaked into launchd ProgramArguments" >&2
  exit 1
fi
grep -F '<string>__CONFIG_PATH__</string>' "$PLIST_TEMPLATE" >/dev/null
if grep -Eq '<string>--(model|provider-id|coordinator|port)</string>' "$PLIST_TEMPLATE"; then
  echo "mutable provider settings leaked into launchd template ProgramArguments" >&2
  exit 1
fi
echo "install prefix rendering ok"
