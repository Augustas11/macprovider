#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
INSTALL_SH="$REPO_ROOT/phase3-binary/dist/install.sh"
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
plist="$(render_plist 'mlx-community/Qwen2.5-7B-Instruct-4bit' 'provider-1' 'wss://coordinator.streamvc.live/ws/provider')"

printf "%s\n" "$plist" | grep -A1 '<key>WorkingDirectory</key>' | grep -F '<string>/opt/mp</string>' >/dev/null
echo "install prefix rendering ok"
