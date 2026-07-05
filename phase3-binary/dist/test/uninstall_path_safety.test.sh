#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
UNINSTALL_SH="$REPO_ROOT/phase3-binary/dist/uninstall.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
export MACPROVIDER_NO_PROMPT=1
mkdir -p "$HOME/Library/Application Support/macprovider" "$HOME/safe"
cat > "$HOME/Library/Application Support/macprovider/install_manifest.json" <<EOF
{
  "install_prefix": "$HOME/safe",
  "launchd_labels": [],
  "launchd_plists": [],
  "data_dirs": ["/Users/../etc"],
  "version": "test"
}
EOF

if bash "$UNINSTALL_SH" --dry-run >"$TMP/out" 2>"$TMP/err"; then
  echo "expected traversal data_dir to be rejected" >&2
  exit 1
fi
grep -F 'refusing unsafe data directory path' "$TMP/err" >/dev/null
echo "uninstall path safety ok"
