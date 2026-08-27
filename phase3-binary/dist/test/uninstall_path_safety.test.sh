#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
UNINSTALL_SH="$REPO_ROOT/phase3-binary/dist/uninstall.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
export MACPROVIDER_NO_PROMPT=1
mkdir -p "$HOME/Library/Application Support/macprovider" "$HOME/safe"
# The traversal fixture must EXIST on the test host: remove_tree_if_allowed
# skips nonexistent paths before the safety check, so a macOS-only prefix
# (e.g. /Users/..) silently passes on Linux CI runners. /tmp/../etc exists on
# both platforms and canonicalizes outside the allowlist.
cat > "$HOME/Library/Application Support/macprovider/install_manifest.json" <<EOF
{
  "install_prefix": "$HOME/safe",
  "launchd_labels": [],
  "launchd_plists": [],
  "data_dirs": ["/tmp/../etc"],
  "version": "test"
}
EOF

if bash "$UNINSTALL_SH" --dry-run >"$TMP/out" 2>"$TMP/err"; then
  echo "expected traversal data_dir to be rejected" >&2
  exit 1
fi
grep -F 'refusing unsafe data directory path' "$TMP/err" >/dev/null
echo "uninstall path safety ok"
