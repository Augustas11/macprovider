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
CONFIG_DIR="$HOME/.config/macprovider"
CONFIG_PATH="$CONFIG_DIR/config.yaml"
LOG_DIR="$HOME/Library/Logs/macprovider"
PORT=18080
# render_plist branches on the headless-fleet install mode; this test covers
# the default GUI (keychain credential-store) rendering.
HEADLESS=0
HEADLESS_USER=""
LAUNCHD_DOMAIN="gui/$UID"
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
# SPEC-003 v0.11.4: launchd pins `Adaptive`/`Background` jobs at background
# priority, which costs about 40% of decode throughput. The provider must be
# `Standard` in the rendered plist and in both shipped templates.
COMPAT_TEMPLATE="$REPO_ROOT/phase3-binary/dist/compatibility-set-assets/provider-launch-agent.plist.template"
printf "%s\n" "$plist" | grep -A1 '<key>ProcessType</key>' | grep -F '<string>Standard</string>' >/dev/null
for template in "$PLIST_TEMPLATE" "$COMPAT_TEMPLATE"; do
  if ! grep -A1 '<key>ProcessType</key>' "$template" | grep -F '<string>Standard</string>' >/dev/null; then
    echo "provider launchd template must use ProcessType Standard: $template" >&2
    exit 1
  fi
done
echo "install prefix rendering ok"
