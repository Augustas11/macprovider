#!/usr/bin/env bash
# Hermetic checks for scripts/verify-tier2-provider-release.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERIFIER="$REPO_ROOT/scripts/verify-tier2-provider-release.sh"

die() { printf '[tier2-provider-release-test] ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[tier2-provider-release-test] %s\n' "$*" >&2; }

sha256_file() {
  local path="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
    return
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
    return
  fi
  die "missing shasum or sha256sum"
}

assert_contains() {
  local path="$1"
  local needle="$2"
  grep -q -- "$needle" "$path" || {
    printf '%s\n' "--- $path ---" >&2
    cat "$path" >&2 || true
    die "expected $path to contain: $needle"
  }
}

TMP_BASE="${TMPDIR:-/tmp}"
WORKDIR="$(mktemp -d "$TMP_BASE/tier2-provider-release-test.XXXXXX")"
cleanup() {
  case "$WORKDIR" in
    "$TMP_BASE"/tier2-provider-release-test.*) rm -rf "$WORKDIR" ;;
    *) die "refusing to remove unexpected workdir: $WORKDIR" ;;
  esac
}
trap cleanup EXIT

make_fake_binary() {
  local dir="$1"
  local version="$2"
  local include_surfaces="$3"
  mkdir -p "$dir"
  cat >"$dir/macprovider-cli" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "--version" ]; then
  printf '%s\n' "$version"
  exit 0
fi
exit 0
EOF
  if [ "$include_surfaces" = "1" ]; then
    cat >>"$dir/macprovider-cli" <<'EOF'
# provider_ecdh_public_key
# tier2_capabilities
# selected_aead_suite
# attestation_token
# certificate_signing_request
# MACPROVIDER_TIER2_MDA_ARTIFACT_PATH
# A256GCM
# inference_response_chunk
EOF
  fi
  chmod +x "$dir/macprovider-cli"
}

make_release_fixture() {
  local fixture_dir="$1"
  local version="$2"
  local include_surfaces="$3"
  local package_mode="${4:-none}"
  mkdir -p "$fixture_dir"
  local binary_dir="$fixture_dir/bin"
  local asset="$fixture_dir/macprovider-cli-v$version-darwin-arm64.tar.gz"
  local pkg_asset="$fixture_dir/macprovider-cli-v$version-darwin-arm64.pkg"
  make_fake_binary "$binary_dir" "$version" "$include_surfaces"
  tar -czf "$asset" -C "$binary_dir" macprovider-cli
  sha256_file "$asset" | awk -v asset="$(basename "$asset")" '{ print $1 "  " asset }' >"$fixture_dir/checksums.txt"
  case "$package_mode" in
    none)
      ;;
    good|bad-extra)
      local pkg_root="$fixture_dir/pkg-root"
      mkdir -p "$pkg_root/Payload/example.bundle"
      cp "$binary_dir/macprovider-cli" "$pkg_root/Payload/macprovider-cli"
      printf '%s\n' 'fixture notice' >"$pkg_root/Payload/THIRD-PARTY-NOTICES.txt"
      printf '%s\n' 'fixture bundle' >"$pkg_root/Payload/example.bundle/info.txt"
      if [ "$package_mode" = "bad-extra" ]; then
        printf '%s\n' 'unexpected' >"$pkg_root/Payload/unexpected.txt"
      fi
      tar -czf "$pkg_asset" -C "$pkg_root" Payload
      sha256_file "$pkg_asset" | awk -v asset="$(basename "$pkg_asset")" '{ print $1 "  " asset }' >>"$fixture_dir/checksums.txt"
      ;;
    *)
      die "unknown package fixture mode: $package_mode"
      ;;
  esac
  openssl dgst -sha256 -sign "$WORKDIR/private.pem" -out "$fixture_dir/checksums.txt.sig" "$fixture_dir/checksums.txt"
}

cat >"$WORKDIR/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
out=""
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      out="$2"
      shift 2
      ;;
    -*)
      shift
      ;;
    *)
      url="$1"
      shift
      ;;
  esac
done
[ -n "$out" ] || exit 2
[ -n "$url" ] || exit 2
name="${url##*/}"
case "$name" in
  macprovider-cli-*-darwin-arm64.tar.gz|macprovider-cli-*-darwin-arm64.pkg|checksums.txt|checksums.txt.sig)
    cp "$RELEASE_FIXTURE_DIR/$name" "$out"
    ;;
  *)
    exit 22
    ;;
esac
SH
chmod +x "$WORKDIR/curl"

cat >"$WORKDIR/pkgutil" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = "--expand-full" ] || exit 2
pkg_path="$2"
expanded_dir="$3"
mkdir -p "$expanded_dir"
tar -xzf "$pkg_path" -C "$expanded_dir"
SH
chmod +x "$WORKDIR/pkgutil"

cat >"$WORKDIR/spctl" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$WORKDIR/spctl"

cat >"$WORKDIR/xcrun" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "stapler" ] && [ "${2:-}" = "validate" ]; then
  exit 0
fi
exit 2
SH
chmod +x "$WORKDIR/xcrun"

openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$WORKDIR/private.pem" >/dev/null 2>&1
openssl pkey -in "$WORKDIR/private.pem" -pubout -out "$WORKDIR/public.pem" >/dev/null 2>&1
PUBLIC_KEY_PEM="$(cat "$WORKDIR/public.pem")"

good_fixture="$WORKDIR/good-release"
make_release_fixture "$good_fixture" "1.2.6" "1"

PATH="$WORKDIR:$PATH" \
  CURL_BIN="$WORKDIR/curl" \
  RELEASE_FIXTURE_DIR="$good_fixture" \
  MACPROVIDER_CHECKSUM_PUBLIC_KEY_PEM="$PUBLIC_KEY_PEM" \
  RELEASE_TAG=v1.2.6 \
  "$VERIFIER" >"$WORKDIR/good.out" 2>"$WORKDIR/good.err"
assert_contains "$WORKDIR/good.err" "SPEC-008 B6 provider GitHub Release verifier passed"

bad_sig_fixture="$WORKDIR/bad-signature"
cp -R "$good_fixture" "$bad_sig_fixture"
printf 'bad-signature' >"$bad_sig_fixture/checksums.txt.sig"
if PATH="$WORKDIR:$PATH" \
  CURL_BIN="$WORKDIR/curl" \
  RELEASE_FIXTURE_DIR="$bad_sig_fixture" \
  MACPROVIDER_CHECKSUM_PUBLIC_KEY_PEM="$PUBLIC_KEY_PEM" \
  RELEASE_TAG=v1.2.6 \
  "$VERIFIER" >"$WORKDIR/bad-sig.out" 2>"$WORKDIR/bad-sig.err"; then
  die "bad signature unexpectedly passed"
fi
assert_contains "$WORKDIR/bad-sig.err" "checksums.txt signature verification failed"

bad_sha_fixture="$WORKDIR/bad-sha"
cp -R "$good_fixture" "$bad_sha_fixture"
bad_asset="$bad_sha_fixture/macprovider-cli-v1.2.6-darwin-arm64.tar.gz"
printf 'tampered' >>"$bad_asset"
if PATH="$WORKDIR:$PATH" \
  CURL_BIN="$WORKDIR/curl" \
  RELEASE_FIXTURE_DIR="$bad_sha_fixture" \
  MACPROVIDER_CHECKSUM_PUBLIC_KEY_PEM="$PUBLIC_KEY_PEM" \
  RELEASE_TAG=v1.2.6 \
  "$VERIFIER" >"$WORKDIR/bad-sha.out" 2>"$WORKDIR/bad-sha.err"; then
  die "bad sha unexpectedly passed"
fi
assert_contains "$WORKDIR/bad-sha.err" "provider artifact sha256 mismatch"

missing_surface_fixture="$WORKDIR/missing-surface"
make_release_fixture "$missing_surface_fixture" "1.2.6" "0"
if PATH="$WORKDIR:$PATH" \
  CURL_BIN="$WORKDIR/curl" \
  RELEASE_FIXTURE_DIR="$missing_surface_fixture" \
  MACPROVIDER_CHECKSUM_PUBLIC_KEY_PEM="$PUBLIC_KEY_PEM" \
  RELEASE_TAG=v1.2.6 \
  "$VERIFIER" >"$WORKDIR/missing-surface.out" 2>"$WORKDIR/missing-surface.err"; then
  die "missing Tier-2 surface unexpectedly passed"
fi
assert_contains "$WORKDIR/missing-surface.err" "provider binary lacks Tier-2 surface string"

package_fixture="$WORKDIR/package-release"
make_release_fixture "$package_fixture" "1.2.6" "1" "good"
PATH="$WORKDIR:$PATH" \
  CURL_BIN="$WORKDIR/curl" \
  RELEASE_FIXTURE_DIR="$package_fixture" \
  MACPROVIDER_CHECKSUM_PUBLIC_KEY_PEM="$PUBLIC_KEY_PEM" \
  RELEASE_TAG=v1.2.6 \
  "$VERIFIER" >"$WORKDIR/package.out" 2>"$WORKDIR/package.err"
assert_contains "$WORKDIR/package.err" "provider package sha256 verified"
assert_contains "$WORKDIR/package.err" "provider package binary matches tarball binary"
assert_contains "$WORKDIR/package.err" "provider package version ok"

bad_package_fixture="$WORKDIR/bad-package-release"
make_release_fixture "$bad_package_fixture" "1.2.6" "1" "bad-extra"
if PATH="$WORKDIR:$PATH" \
  CURL_BIN="$WORKDIR/curl" \
  RELEASE_FIXTURE_DIR="$bad_package_fixture" \
  MACPROVIDER_CHECKSUM_PUBLIC_KEY_PEM="$PUBLIC_KEY_PEM" \
  RELEASE_TAG=v1.2.6 \
  "$VERIFIER" >"$WORKDIR/bad-package.out" 2>"$WORKDIR/bad-package.err"; then
  die "unexpected package payload member unexpectedly passed"
fi
assert_contains "$WORKDIR/bad-package.err" "unexpected provider package payload member"

if PATH="$WORKDIR:$PATH" \
  CURL_BIN="$WORKDIR/curl" \
  RELEASE_FIXTURE_DIR="$good_fixture" \
  MACPROVIDER_CHECKSUM_PUBLIC_KEY_PEM="$PUBLIC_KEY_PEM" \
  RELEASE_TAG=v1.2.6 \
  DOWNLOAD_ATTEMPTS=abc \
  "$VERIFIER" >"$WORKDIR/bad-attempts.out" 2>"$WORKDIR/bad-attempts.err"; then
  die "invalid DOWNLOAD_ATTEMPTS unexpectedly passed"
fi
assert_contains "$WORKDIR/bad-attempts.err" "DOWNLOAD_ATTEMPTS must be a positive integer"

log "ok"
