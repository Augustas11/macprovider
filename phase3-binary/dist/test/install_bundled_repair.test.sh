#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
INSTALL_SH="$REPO_ROOT/phase3-binary/dist/install.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 - "$INSTALL_SH" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
main = source[source.rindex("\nmain() {"):]
if "Repairing from Malibu.app bundled provider CLI (no GitHub download)." not in main:
    raise SystemExit("main() does not stage a Malibu.app bundled CLI for repair")
if "existing-install repair requires MACPROVIDER_BUNDLED_CLI from Malibu.app" not in main:
    raise SystemExit("repair without a bundled CLI must fail closed")
download = main.index('download_release "$tag"')
bundled = main.index("Repairing from Malibu.app bundled provider CLI (no GitHub download).")
if not bundled < download:
    raise SystemExit("bundled repair must be chosen before GitHub download_release")
if "stage_bundled_repair_payload" not in source:
    raise SystemExit("missing stage_bundled_repair_payload")
PY

extract_function() {
  name="$1"
  awk -v start="${name}() {" '
    $0 == start { inside=1 }
    inside { print }
    inside && /^}$/ { exit }
  ' "$INSTALL_SH"
}

for function_name in validated_bundled_cli stage_bundled_repair_payload; do
  extract_function "$function_name" >> "$TMP/helpers.sh"
done

die() {
  printf '%s\n' "$2" > "$TMP/die-message"
  exit "$1"
}
log() { printf '%s\n' "$*"; }

# shellcheck source=/dev/null
source "$TMP/helpers.sh"

HOME="$TMP/home"
mkdir -m 700 "$HOME"
INSTALL_DIR="$HOME/macprovider"
mkdir -m 700 "$INSTALL_DIR"
printf 'compat\n' > "$INSTALL_DIR/compatibility-set.json"
mkdir "$INSTALL_DIR/compatibility-set-local" "$INSTALL_DIR/catalog-release"
printf 'mlx\n' > "$INSTALL_DIR/mlx.metallib"

bundled="$TMP/Malibu.app/Contents/MacOS/macprovider-cli"
mkdir -p "$(dirname "$bundled")"
cat > "$bundled" <<'EOF'
#!/bin/bash
echo "1.8.104"
EOF
chmod 0755 "$bundled"

BUNDLED_CLI="$bundled"
REPAIR_EXISTING_INSTALL=1
EMERGENCY_ROLLBACK=0
MACPROVIDER_ACCEPTANCE_ASSET_DIR=""
TMPDIR_PATH="$TMP/work"
mkdir -p "$TMPDIR_PATH"
tag="v1.8.104"

stage_bundled_repair_payload
[ -x "$TMPDIR_PATH/staging/macprovider-cli" ]
[ -f "$TMPDIR_PATH/staging/compatibility-set.json" ]
[ -d "$TMPDIR_PATH/staging/compatibility-set-local" ]
[ -d "$TMPDIR_PATH/staging/catalog-release" ]
[ -f "$TMPDIR_PATH/staging/mlx.metallib" ]
[ "$asset_kind" = "bundled" ]

if (
  REPAIR_EXISTING_INSTALL=0
  BUNDLED_CLI="$bundled"
  tag="v1.8.104"
  TMPDIR_PATH="$TMP/work2"
  mkdir -p "$TMPDIR_PATH"
  stage_bundled_repair_payload
); then
  echo "bundled staging must refuse non-repair installs" >&2
  exit 1
fi

echo "install_bundled_repair: PASS"
