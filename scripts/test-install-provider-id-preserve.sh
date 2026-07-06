#!/usr/bin/env bash
# Hermetic guard for install.sh preserving provider_id across reinstall.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_SH="$REPO_ROOT/phase3-binary/dist/install.sh"

die() {
  printf '[install-provider-id-test] ERROR: %s\n' "$*" >&2
  exit 1
}

[ -f "$INSTALL_SH" ] || die "missing installer: $INSTALL_SH"

lib="$(mktemp "${TMPDIR:-/tmp}/macprovider-install-provider-id-lib.XXXXXX")"
workdir="$(mktemp -d "${TMPDIR:-/tmp}/macprovider-install-provider-id.XXXXXX")"
trap 'rm -f "$lib"; rm -rf "$workdir"' EXIT

{
  awk '/^sanitize_handle\(\)/, /^}/' "$INSTALL_SH"
  awk '/^read_config_provider_id\(\)/, /^}/' "$INSTALL_SH"
  awk '/^choose_provider_id\(\)/, /^}/' "$INSTALL_SH"
} > "$lib"

# shellcheck source=/dev/null
. "$lib"

CONFIG_DIR="$workdir/config"
CONFIG_PATH="$CONFIG_DIR/config.yaml"
PROVIDER_ID_PATH="$CONFIG_DIR/provider_id"
NO_PROMPT=1

mkdir -p "$CONFIG_DIR"
cat > "$CONFIG_PATH" <<'EOF_CONFIG'
model: "old/model"
coordinator_url: "wss://old.example/ws/provider"
provider_id: "p_upiv4dug6kmmcpavsyqjmt35andgfpbf4ztrrnhlqdjqirhprcxq"
port: 18080
EOF_CONFIG

chosen="$(choose_provider_id)"
[ "$chosen" = "p_upiv4dug6kmmcpavsyqjmt35andgfpbf4ztrrnhlqdjqirhprcxq" ] \
  || die "expected config.yaml provider_id, got: $chosen"

rm -f "$PROVIDER_ID_PATH"
printf "mac\n" > "$PROVIDER_ID_PATH"
chosen="$(choose_provider_id)"
[ "$chosen" = "mac" ] || die "expected provider_id file to win, got: $chosen"

rm -f "$PROVIDER_ID_PATH"
chosen="$(choose_provider_id)"
[ "$chosen" = "p_upiv4dug6kmmcpavsyqjmt35andgfpbf4ztrrnhlqdjqirhprcxq" ] \
  || die "expected config.yaml fallback after empty provider_id file, got: $chosen"

printf '[install-provider-id-test] installer preserves provider_id across reinstall ok\n'
