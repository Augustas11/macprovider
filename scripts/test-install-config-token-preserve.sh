#!/usr/bin/env bash
# Hermetic guard for install.sh preserving provider auth across upgrades.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_SH="$REPO_ROOT/phase3-binary/dist/install.sh"

die() {
  printf '[install-config-token-test] ERROR: %s\n' "$*" >&2
  exit 1
}

[ -f "$INSTALL_SH" ] || die "missing installer: $INSTALL_SH"

lib="$(mktemp "${TMPDIR:-/tmp}/macprovider-install-config-lib.XXXXXX")"
workdir="$(mktemp -d "${TMPDIR:-/tmp}/macprovider-install-config.XXXXXX")"
trap 'rm -f "$lib"; rm -rf "$workdir"' EXIT

awk '
  /^semantic_merge_config\(\)/ { emit = 1 }
  /^read_config_model\(\)/ { emit = 0 }
  emit { print }
' "$INSTALL_SH" > "$lib"

# shellcheck source=/dev/null
. "$lib"

CONFIG_DIR="$workdir/config"
CONFIG_PATH="$CONFIG_DIR/config.yaml"
PROVIDER_ID_PATH="$CONFIG_DIR/provider_id"
PORT=18080
DRY_RUN=0

run() {
  "$@"
}

yaml_escape() {
  printf "%s" "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

mkdir -p "$CONFIG_DIR"
cat > "$CONFIG_PATH" <<'EOF_CONFIG'
model: "old/model"
coordinator_url: "wss://old.example/ws/provider"
provider_id: "mac"
port: 18080
# provider_token: historical note
  provider_token: nested-value
provider_token: 1666f693c3fa-redacted-token-body
EOF_CONFIG

write_config "new/model" "mac" "wss://coordinator.example/ws/provider"

grep -Fq 'model: "new/model"' "$CONFIG_PATH" || die "model was not rewritten"
grep -Fq 'coordinator_url: "wss://coordinator.example/ws/provider"' "$CONFIG_PATH" || die "coordinator URL was not rewritten"
grep -Fq 'provider_id: "mac"' "$CONFIG_PATH" || die "provider_id was not rewritten"
grep -Fq 'provider_token: 1666f693c3fa-redacted-token-body' "$CONFIG_PATH" || die "top-level provider_token was not preserved"

top_level_count="$(grep -Ec '^provider_token[[:space:]]*:' "$CONFIG_PATH")"
[ "$top_level_count" -eq 1 ] || die "expected one top-level provider_token, got $top_level_count"

grep -Fq '  provider_token: nested-value' "$CONFIG_PATH" \
  || die "semantic merge did not preserve unrelated nested config"
grep -Fq '# provider_token: historical note' "$CONFIG_PATH" \
  || die "semantic merge did not preserve config comments"

case "$(uname -s)" in
  Darwin*) mode="$(stat -f '%Lp' "$CONFIG_PATH")" ;;
  *) mode="$(stat -c '%a' "$CONFIG_PATH")" ;;
esac
[ "$mode" = "600" ] || die "config mode = $mode, want 600"

printf '[install-config-token-test] installer preserves provider_token across config rewrite ok\n'
