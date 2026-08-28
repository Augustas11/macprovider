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
REPO_ROOT=$(cd "$PHASE3_DIR/.." && pwd)
cd "$PHASE3_DIR"

TAG=${1:-$(git rev-parse --short HEAD)}
PROVIDER_CLI_VERSION=$(sed -n 's/^[[:space:]]*static let binaryVersion = "\([0-9][0-9.]*\)"$/\1/p' \
  "$PHASE3_DIR/Sources/malibu-cli/CoordinatorClient.swift" | head -1)
MALIBU_APP_VERSION=$(sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"\([0-9][0-9.]*\)"$/\1/p' \
  "$PHASE3_DIR/app/project.yml" | head -1)
[ -n "$PROVIDER_CLI_VERSION" ] || {
  echo "FATAL: could not resolve provider CLI component version" >&2
  exit 1
}
[ -n "$MALIBU_APP_VERSION" ] || {
  echo "FATAL: could not resolve Malibu app component version" >&2
  exit 1
}
case "$TAG" in
  v[0-9]*.[0-9]*.[0-9]*) MANIFEST_TAG="$TAG" ;;
  *) MANIFEST_TAG="v$PROVIDER_CLI_VERSION" ;;
esac
RELEASE_DIR="./build-release"
OUT_DIR="./dist"
TARBALL="$OUT_DIR/phase3-binary-m4-${TAG}.tar.gz"
PACKAGE_WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macprovider-package.XXXXXX")"
COMPATIBILITY_SET_MANIFEST="$PACKAGE_WORK_DIR/compatibility-set.json"
LOCAL_COMPATIBILITY_SET_DIR="$PACKAGE_WORK_DIR/compatibility-set-local"
PROVIDER_ADMISSION_POLICY="${MACPROVIDER_PROVIDER_ADMISSION_POLICY:-bridge_required}"

cleanup() {
  if [ -n "${PRODUCT_REPLACEMENT:-}" ]; then
    rm -f "$PRODUCT_REPLACEMENT"
  fi
  rm -rf "$PACKAGE_WORK_DIR"
}
trap cleanup EXIT

mkdir -p "$OUT_DIR"

rm -rf "$LOCAL_COMPATIBILITY_SET_DIR"
mkdir -p "$LOCAL_COMPATIBILITY_SET_DIR"
cp "$PHASE3_DIR/dist/install.sh" "$LOCAL_COMPATIBILITY_SET_DIR/install.sh"
cp "$REPO_ROOT/ops/macprovider-watchdog/watchdog.sh" "$LOCAL_COMPATIBILITY_SET_DIR/watchdog.sh"
cp "$PHASE3_DIR/dist/compatibility-set-assets/provider-launch-agent.plist.template" \
  "$LOCAL_COMPATIBILITY_SET_DIR/provider-launch-agent.plist.template"
cp "$PHASE3_DIR/dist/compatibility-set-assets/watchdog-launch-agent.plist.template" \
  "$LOCAL_COMPATIBILITY_SET_DIR/watchdog-launch-agent.plist.template"
cp "$PHASE3_DIR/dist/compatibility-set-assets/updater-rollback.json" \
  "$LOCAL_COMPATIBILITY_SET_DIR/updater-rollback.json"
chmod 0755 "$LOCAL_COMPATIBILITY_SET_DIR/install.sh" "$LOCAL_COMPATIBILITY_SET_DIR/watchdog.sh"
chmod 0644 "$LOCAL_COMPATIBILITY_SET_DIR"/*.template "$LOCAL_COMPATIBILITY_SET_DIR/updater-rollback.json"

echo "==> Verifying immutable signed catalog release..."
python3 "$REPO_ROOT/scripts/catalog-release.py" verify

echo "==> Generating deterministic compatibility-set manifest..."
python3 "$REPO_ROOT/scripts/compatibility-set-manifest.py" generate \
  --tag "$MANIFEST_TAG" \
  --commit "$(git rev-parse HEAD)" \
  --repository "Augustas11/macprovider" \
  --malibu-app-version "$MALIBU_APP_VERSION" \
  --provider-cli-version "$PROVIDER_CLI_VERSION" \
  --provider-admission-policy "$PROVIDER_ADMISSION_POLICY" \
  --catalog-directory "$PHASE3_DIR/catalog/autotune" \
  --catalog-feed-directory "$PHASE3_DIR/dist/static" \
  --local-artifacts-directory "$LOCAL_COMPATIBILITY_SET_DIR" \
  --output "$COMPATIBILITY_SET_MANIFEST"
python3 "$REPO_ROOT/scripts/compatibility-set-manifest.py" validate \
  --input "$COMPATIBILITY_SET_MANIFEST" \
  --expected-tag "$MANIFEST_TAG" \
  --expected-commit "$(git rev-parse HEAD)" \
  --expected-malibu-app-version "$MALIBU_APP_VERSION" \
  --expected-provider-cli-version "$PROVIDER_CLI_VERSION" \
  --expected-provider-admission-policy "$PROVIDER_ADMISSION_POLICY"

echo "==> Building Release configuration (this takes ~5-10 min)..."
BUILD_LOG="$PACKAGE_WORK_DIR/package-build.log"
if ! xcodebuild -scheme malibu-cli \
                -configuration Release \
                -destination 'generic/platform=macOS' \
                -derivedDataPath "$RELEASE_DIR" \
                -onlyUsePackageVersionsFromResolvedFile \
                -skipPackagePluginValidation \
                -skipMacroValidation \
                clean build >"$BUILD_LOG" 2>&1; then
  tail -200 "$BUILD_LOG" >&2
  rm -f "$BUILD_LOG"
  exit 1
fi
tail -20 "$BUILD_LOG"
rm -f "$BUILD_LOG"

PRODUCTS="$RELEASE_DIR/Build/Products/Release"

# Sanity: binary + Metal kernels present.
if [ ! -f "$PRODUCTS/malibu-cli" ] ||
   [ -L "$PRODUCTS/malibu-cli" ] ||
   [ ! -x "$PRODUCTS/malibu-cli" ]; then
  echo "FATAL: malibu-cli not found at $PRODUCTS"
  exit 1
fi
BUILT_PROVIDER_CLI_ARCHES=$(/usr/bin/lipo -archs "$PRODUCTS/malibu-cli")
case " $BUILT_PROVIDER_CLI_ARCHES " in
  *" arm64 "*) ;;
  *)
    echo "FATAL: built provider CLI has no arm64 slice: $BUILT_PROVIDER_CLI_ARCHES" >&2
    exit 1
    ;;
esac
if [ "$BUILT_PROVIDER_CLI_ARCHES" != arm64 ]; then
  THIN_PROVIDER_CLI="$PACKAGE_WORK_DIR/malibu-cli.arm64"
  PRODUCT_REPLACEMENT="$PRODUCTS/.malibu-cli.arm64.$$"
  /usr/bin/lipo "$PRODUCTS/malibu-cli" -thin arm64 -output "$THIN_PROVIDER_CLI"
  THIN_PROVIDER_CLI_ARCHES=$(/usr/bin/lipo -archs "$THIN_PROVIDER_CLI")
  [ "$THIN_PROVIDER_CLI_ARCHES" = arm64 ] || {
    echo "FATAL: thinned provider CLI architecture $THIN_PROVIDER_CLI_ARCHES is not exact arm64" >&2
    exit 1
  }
  cp "$THIN_PROVIDER_CLI" "$PRODUCT_REPLACEMENT"
  chmod 0755 "$PRODUCT_REPLACEMENT"
  mv -f "$PRODUCT_REPLACEMENT" "$PRODUCTS/malibu-cli"
  PRODUCT_REPLACEMENT=
fi
ACTUAL_PROVIDER_CLI_ARCHES=$(/usr/bin/lipo -archs "$PRODUCTS/malibu-cli")
[ "$ACTUAL_PROVIDER_CLI_ARCHES" = arm64 ] || {
  echo "FATAL: packaged provider CLI architecture $ACTUAL_PROVIDER_CLI_ARCHES is not exact arm64" >&2
  exit 1
}
PACKAGE_HOST_ARCH=$(uname -m)
case "$PACKAGE_HOST_ARCH" in
  arm64)
    ACTUAL_PROVIDER_CLI_VERSION=$("$PRODUCTS/malibu-cli" --version | tr -d '\r\n')
    [ "$ACTUAL_PROVIDER_CLI_VERSION" = "$PROVIDER_CLI_VERSION" ] || {
      echo "FATAL: built provider CLI version $ACTUAL_PROVIDER_CLI_VERSION does not match declared component $PROVIDER_CLI_VERSION" >&2
      exit 1
    }
    ;;
  x86_64)
    echo "==> Deferring arm64 provider runtime checks to the release workflow's arm64 verifier."
    ;;
  *)
    echo "FATAL: unsupported package host architecture $PACKAGE_HOST_ARCH" >&2
    exit 1
    ;;
esac
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
ls -la "$PRODUCTS/malibu-cli"
ls -la "$PRODUCTS/mlx.metallib"

echo "==> Gathering third-party license notices..."
NOTICES_FILE="$PACKAGE_WORK_DIR/THIRD-PARTY-NOTICES.txt"
"$REPO_ROOT/scripts/gather-third-party-notices.sh" "$NOTICES_FILE" "$RELEASE_DIR/SourcePackages/checkouts"

echo "==> Staging tarball contents..."
STAGE_DIR="$PACKAGE_WORK_DIR/stage"
mkdir -p "$STAGE_DIR"
cp "$PRODUCTS/malibu-cli" "$STAGE_DIR/"
cp "$PRODUCTS/mlx.metallib" "$STAGE_DIR/"
if [ -d "$PRODUCTS/mlx-swift_Cmlx.bundle" ]; then
    cp -r "$PRODUCTS/mlx-swift_Cmlx.bundle" "$STAGE_DIR/"
fi
if [ -d "$PRODUCTS/swift-nio_NIOPosix.bundle" ]; then
    cp -r "$PRODUCTS/swift-nio_NIOPosix.bundle" "$STAGE_DIR/"
fi
cp "$NOTICES_FILE" "$STAGE_DIR/THIRD-PARTY-NOTICES.txt"
cp "$COMPATIBILITY_SET_MANIFEST" "$STAGE_DIR/compatibility-set.json"
cp -R "$LOCAL_COMPATIBILITY_SET_DIR" "$STAGE_DIR/compatibility-set-local"
mkdir -p "$STAGE_DIR/catalog-release"
cp "$PHASE3_DIR/catalog/autotune/release.json" "$STAGE_DIR/catalog-release/"
cp "$PHASE3_DIR/catalog/autotune/trusted-keys.json" "$STAGE_DIR/catalog-release/"
cp "$PHASE3_DIR/catalog/autotune/tier2-catalog.json" "$STAGE_DIR/catalog-release/"
cp "$PHASE3_DIR/dist/static/autotune-candidates.json" "$STAGE_DIR/catalog-release/"
cp "$PHASE3_DIR/dist/static/autotune-candidates.json.sig" "$STAGE_DIR/catalog-release/"
cp "$PHASE3_DIR/dist/static/demand-rank.json" "$STAGE_DIR/catalog-release/"
cp "$PHASE3_DIR/dist/static/demand-rank.json.sig" "$STAGE_DIR/catalog-release/"
cp "$PHASE3_DIR/dist/static/rate-card.json" "$STAGE_DIR/catalog-release/"
cp "$PHASE3_DIR/dist/static/rate-card.json.sig" "$STAGE_DIR/catalog-release/"

python3 "$REPO_ROOT/scripts/compatibility-set-manifest.py" validate \
  --input "$STAGE_DIR/compatibility-set.json" \
  --payload-directory "$STAGE_DIR" \
  --expected-tag "$MANIFEST_TAG" \
  --expected-commit "$(git rev-parse HEAD)" \
  --expected-malibu-app-version "$MALIBU_APP_VERSION" \
  --expected-provider-cli-version "$PROVIDER_CLI_VERSION" \
  --expected-provider-admission-policy "$PROVIDER_ADMISSION_POLICY"

echo "==> Packaging tarball: $TARBALL"
# Include the binary, mlx.metallib, any SwiftPM bundle resources, and
# THIRD-PARTY-NOTICES.txt, the compatibility-set envelope, the hash-bound local
# launchd/watchdog/install/rollback members, and the verified catalog release
# evidence. Final container hashes intentionally live in the signed release
# checksum set rather than the embedded envelope.
archive_members=(
  malibu-cli
  mlx.metallib
  THIRD-PARTY-NOTICES.txt
  compatibility-set.json
  compatibility-set-local
  catalog-release
)
swiftpm_bundle_count=0
for swiftpm_bundle in mlx-swift_Cmlx.bundle swift-nio_NIOPosix.bundle; do
  if [ -d "$STAGE_DIR/$swiftpm_bundle" ]; then
    archive_members+=("$swiftpm_bundle")
    swiftpm_bundle_count=$((swiftpm_bundle_count + 1))
  fi
done
[ "$swiftpm_bundle_count" -gt 0 ] || {
  echo "FATAL: no SwiftPM resource bundle found in $PRODUCTS" >&2
  exit 1
}
tar czf "$TARBALL" -C "$STAGE_DIR" "${archive_members[@]}"

echo "==> Tarball stats:"
ls -la "$TARBALL"
echo
echo "==> SHA256:"
shasum -a 256 "$TARBALL"

echo
echo "==> NEXT: test locally before shipping."
echo "  cd /tmp && mkdir m4-test && cd m4-test"
echo "  tar xzf $PHASE3_DIR/$TARBALL"
echo "  ./malibu-cli --port 18081 --model mlx-community/Qwen2.5-7B-Instruct-4bit &"
echo "  sleep 45 # 7B takes longer to load"
echo "  curl -sS http://127.0.0.1:18081/v1/models | python3 -m json.tool"
echo "  # If model id returns, tarball is shippable. kill %1 to stop."
