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
           clean build 2>&1 | tail -20

PRODUCTS="$RELEASE_DIR/Build/Products/Release"

# Sanity: binary + metallib present?
if [ ! -x "$PRODUCTS/macprovider-cli" ]; then
  echo "FATAL: macprovider-cli not found at $PRODUCTS"
  exit 1
fi
if [ ! -f "$PRODUCTS/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" ]; then
  echo "FATAL: default.metallib not found — Metal toolchain may be missing"
  exit 1
fi

echo "==> Build products:"
ls -la "$PRODUCTS/macprovider-cli"
ls -la "$PRODUCTS/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"

echo "==> Packaging tarball: $TARBALL"
# Include the binary + all *.bundle resources that SwiftPM produced
# (mlx-swift_Cmlx.bundle is the critical one; others contain privacy
# manifests etc. and are small)
tar czf "$TARBALL" \
    -C "$PRODUCTS" \
    macprovider-cli \
    mlx-swift_Cmlx.bundle \
    swift-nio_NIOPosix.bundle 2>/dev/null || \
tar czf "$TARBALL" \
    -C "$PRODUCTS" \
    macprovider-cli \
    mlx-swift_Cmlx.bundle

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
