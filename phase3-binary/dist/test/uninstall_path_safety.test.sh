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

mkdir -p "$HOME/.local/bin" "$HOME/macprovider"
touch "$HOME/macprovider/malibu-cli"
ln -sf "$HOME/macprovider/malibu-cli" "$HOME/.local/bin/macprovider-cli"
cat > "$HOME/Library/Application Support/macprovider/install_manifest.json" <<EOF
{
  "install_prefix": "$HOME/macprovider",
  "launchd_labels": [],
  "launchd_plists": [],
  "symlink_path": "$HOME/.local/bin/macprovider-cli",
  "data_dirs": [],
  "version": "legacy-test"
}
EOF

if ! bash "$UNINSTALL_SH" --dry-run >"$TMP/legacy-out" 2>"$TMP/legacy-err"; then
  cat "$TMP/legacy-err" >&2
  echo "expected legacy manifest symlink_path to be accepted" >&2
  exit 1
fi
grep -F "$HOME/.local/bin/macprovider-cli" "$TMP/legacy-out" >/dev/null

mkdir -p "$HOME/victim-dir"
ln -sfn "$HOME/victim-dir" "$HOME/.local/bin/macprovider-cli"
cat > "$HOME/Library/Application Support/macprovider/install_manifest.json" <<EOF
{
  "install_prefix": "$HOME/macprovider",
  "launchd_labels": [],
  "launchd_plists": [],
  "symlink_path": "$HOME/victim-dir",
  "data_dirs": [],
  "version": "legacy-target-test"
}
EOF

if bash "$UNINSTALL_SH" --dry-run >"$TMP/target-out" 2>"$TMP/target-err"; then
  echo "expected legacy symlink target path to be rejected" >&2
  exit 1
fi
grep -F 'refusing unsafe binary symlink path' "$TMP/target-err" >/dev/null

rm -rf "$HOME/.local/bin" "$HOME/outside"
mkdir -p "$HOME/.local/bin" "$HOME/outside"
touch "$HOME/.local/bin/macprovider-cli"
touch "$HOME/outside/macprovider-cli"
ln -sfn "$HOME/outside" "$HOME/.local/bin/hop"
cat > "$HOME/Library/Application Support/macprovider/install_manifest.json" <<EOF
{
  "install_prefix": "$HOME/macprovider",
  "launchd_labels": [],
  "launchd_plists": [],
  "symlink_path": "$HOME/.local/bin/hop/../macprovider-cli",
  "data_dirs": [],
  "version": "legacy-hop-test"
}
EOF

if ! bash "$UNINSTALL_SH" >"$TMP/hop-out" 2>"$TMP/hop-err"; then
  cat "$TMP/hop-err" >&2
  echo "expected normalized legacy symlink path removal to succeed" >&2
  exit 1
fi
test ! -e "$HOME/.local/bin/macprovider-cli"
test -e "$HOME/outside/macprovider-cli"
echo "uninstall path safety ok"
