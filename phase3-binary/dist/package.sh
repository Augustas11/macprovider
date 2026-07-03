#!/usr/bin/env bash
# Operator-side: build Release configuration of phase3-binary
# and package as a relocatable tarball for shipping to M4 partner.
#
# Usage:
#   ./package.sh [VERSION_TAG]
#
# Default VERSION_TAG = current short git rev. Output tarball lands at:
#   phase3-binary/dist/phase3-binary-m4-<TAG>.tar.gz
#
# Tarball size is ~30-40 MB compressed.

set -euo pipefail

PHASE3_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$PHASE3_DIR"

TAG=${1:-$(git rev-parse --short HEAD)}
RELEASE_DIR="./build-release"
OUT_DIR="./dist"
TARBALL="$OUT_DIR/phase3-binary-m4-${TAG}.tar.gz"

mkdir -p "$OUT_DIR"

echo "==> Building Release configuration (this takes ~5-10 min)..."
xcodebuild -scheme macprovider-cli \
           -configuration Release \
           -destination 'platform=macOS,arch=arm64' \
           -derivedDataPath "$RELEASE_DIR" \
           -skipPackagePluginValidation \
           -skipMacroValidation \
           clean build 2>&1 | tail -20

PRODUCTS="$RELEASE_DIR/Build/Products/Release"

# Sanity: binary + Metal kernels present.
if [ ! -x "$PRODUCTS/macprovider-cli" ]; then
  echo "FATAL: macprovider-cli not found at $PRODUCTS"
  exit 1
fi
if [ ! -f "$PRODUCTS/mlx.metallib" ]; then
  if [ -f "$PRODUCTS/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" ]; then
    cp "$PRODUCTS/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" "$PRODUCTS/mlx.metallib"
  else
    echo "==> Building mlx.metallib for CLI artifact..."
    MLX_SWIFT_CHECKOUT="$RELEASE_DIR/SourcePackages/checkouts/mlx-swift" \
      "$PHASE3_DIR/scripts/build-mlx-metallib.sh" "$PRODUCTS"
  fi
fi
[ -f "$PRODUCTS/mlx.metallib" ] || {
  echo "FATAL: mlx.metallib not found — Metal toolchain may be missing"
  exit 1
}

echo "==> Build products:"
ls -la "$PRODUCTS/macprovider-cli"
ls -la "$PRODUCTS/mlx.metallib"

echo "==> Gathering third-party license notices..."
NOTICES_FILE="$OUT_DIR/THIRD-PARTY-NOTICES.txt"
REPO_ROOT=$(cd "$PHASE3_DIR/.." && pwd)
"$REPO_ROOT/scripts/gather-third-party-notices.sh" "$NOTICES_FILE" "$RELEASE_DIR/SourcePackages/checkouts"

echo "==> Staging tarball contents..."
STAGE_DIR=$(mktemp -d)
trap 'rm -rf "$STAGE_DIR"' EXIT
cp "$PRODUCTS/macprovider-cli" "$STAGE_DIR/"
cp "$PRODUCTS/mlx.metallib" "$STAGE_DIR/"
if [ -d "$PRODUCTS/mlx-swift_Cmlx.bundle" ]; then
    cp -r "$PRODUCTS/mlx-swift_Cmlx.bundle" "$STAGE_DIR/"
fi
if [ -d "$PRODUCTS/swift-nio_NIOPosix.bundle" ]; then
    cp -r "$PRODUCTS/swift-nio_NIOPosix.bundle" "$STAGE_DIR/"
fi
cp "$NOTICES_FILE" "$STAGE_DIR/THIRD-PARTY-NOTICES.txt"

echo "==> Packaging tarball: $TARBALL"
# Include the binary, mlx.metallib, any SwiftPM bundle resources, and
# THIRD-PARTY-NOTICES.txt.
tar czf "$TARBALL" -C "$STAGE_DIR" .

echo "==> Tarball stats:"
ls -la "$TARBALL"
echo
echo "==> SHA256:"
shasum -a 256 "$TARBALL"

echo
echo "==> NEXT: test locally before shipping."
echo "  cd /tmp && mkdir m4-test && cd m4-test"
echo "  tar xzf $PHASE3_DIR/$TARBALL"
echo "  ./macprovider-cli --port 18081 --model mlx-community/Qwen2.5-7B-Instruct-4bit &"
echo "  sleep 45 # 7B takes longer to load"
echo "  curl -sS http://127.0.0.1:18081/v1/models | python3 -m json.tool"
echo "  # If model id returns, tarball is shippable. kill %1 to stop."
