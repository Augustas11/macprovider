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
if "existing-install repair requires MACPROVIDER_BUNDLED_APP from Malibu.app" not in main:
    raise SystemExit("repair without a bundled Malibu.app must fail closed")
download = main.index('download_release "$tag"')
bundled = main.index("Repairing from Malibu.app bundled provider CLI (no GitHub download).")
if not bundled < download:
    raise SystemExit("bundled repair must be chosen before GitHub download_release")
if "stage_bundled_repair_payload" not in source:
    raise SystemExit("missing stage_bundled_repair_payload")
if 'Contents/Resources/compatibility-set.json' not in source:
    raise SystemExit("bundled repair must stage Malibu.app compatibility-set.json")
PY

extract_function() {
  name="$1"
  awk -v start="${name}() {" '
    $0 == start { inside=1 }
    inside { print }
    inside && /^}$/ { exit }
  ' "$INSTALL_SH"
}

for function_name in validated_bundled_cli validated_bundled_app stage_bundled_repair_payload; do
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
printf '{"signed":{"components":{"provider_cli":{"version":"1.8.102"}}}}\n' \
  > "$INSTALL_DIR/compatibility-set.json"
mkdir "$INSTALL_DIR/compatibility-set-local" "$INSTALL_DIR/catalog-release"
printf 'old-mlx\n' > "$INSTALL_DIR/mlx.metallib"

app="$TMP/Malibu.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/compatibility-set-local" \
  "$app/Contents/Resources/catalog-release"
cat > "$app/Contents/MacOS/malibu-cli" <<'EOF'
#!/bin/bash
echo "1.8.104"
EOF
chmod 0755 "$app/Contents/MacOS/malibu-cli"
printf 'new-mlx\n' > "$app/Contents/MacOS/mlx.metallib"
printf '{"signed":{"components":{"provider_cli":{"version":"1.8.104"}}}}\n' \
  > "$app/Contents/Resources/compatibility-set.json"
printf 'local\n' > "$app/Contents/Resources/compatibility-set-local/install.sh"
printf 'catalog\n' > "$app/Contents/Resources/catalog-release/release.json"

BUNDLED_APP="$app"
BUNDLED_CLI=""
REPAIR_EXISTING_INSTALL=1
EMERGENCY_ROLLBACK=0
MACPROVIDER_ACCEPTANCE_ASSET_DIR=""
TMPDIR_PATH="$TMP/work"
mkdir -p "$TMPDIR_PATH"
tag="v1.8.104"

stage_bundled_repair_payload
[ -x "$TMPDIR_PATH/staging/malibu-cli" ]
[ -f "$TMPDIR_PATH/staging/compatibility-set.json" ]
[ -d "$TMPDIR_PATH/staging/compatibility-set-local" ]
[ -d "$TMPDIR_PATH/staging/catalog-release" ]
[ -f "$TMPDIR_PATH/staging/mlx.metallib" ]
[ "$asset_kind" = "bundled" ]
grep -F '1.8.104' "$TMPDIR_PATH/staging/compatibility-set.json" >/dev/null
if grep -F '1.8.102' "$TMPDIR_PATH/staging/compatibility-set.json" >/dev/null; then
  echo "bundled repair staged the incumbent compatibility set" >&2
  exit 1
fi
grep -F 'new-mlx' "$TMPDIR_PATH/staging/mlx.metallib" >/dev/null

if (
  REPAIR_EXISTING_INSTALL=0
  BUNDLED_APP="$app"
  tag="v1.8.104"
  TMPDIR_PATH="$TMP/work2"
  mkdir -p "$TMPDIR_PATH"
  stage_bundled_repair_payload
); then
  echo "bundled staging must refuse non-repair installs" >&2
  exit 1
fi

echo "install_bundled_repair: PASS"
