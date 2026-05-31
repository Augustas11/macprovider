#!/usr/bin/env bash
# Non-mutating SPEC-008 B6 GitHub Release verifier for the provider artifact.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

GITHUB_REPO="${GITHUB_REPO:-Augustas11/macprovider}"
RELEASE_TAG="${RELEASE_TAG:-v1.2.6}"
INSTALL_SH="${INSTALL_SH:-$REPO_ROOT/phase3-binary/dist/install.sh}"
CHECKER="${CHECKER:-$REPO_ROOT/scripts/check-tier2-provider-artifact.sh}"
CURL_BIN="${CURL_BIN:-curl}"
OPENSSL_BIN="${OPENSSL_BIN:-openssl}"
PROVIDER_VERSION_OVERRIDE="${PROVIDER_VERSION:-}"
KEEP_DOWNLOADS="${KEEP_DOWNLOADS:-0}"
DOWNLOAD_ATTEMPTS="${DOWNLOAD_ATTEMPTS:-1}"
DOWNLOAD_RETRY_SLEEP="${DOWNLOAD_RETRY_SLEEP:-5}"

log() { printf '[tier2-provider-release] %s\n' "$*" >&2; }
die() { printf '[tier2-provider-release] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
usage: scripts/verify-tier2-provider-release.sh [--tag v1.2.6]

Downloads a macprovider-cli GitHub Release asset set, verifies the signed
checksum manifest using the installer public key, verifies the release tarball
checksum, then runs scripts/check-tier2-provider-artifact.sh against the
downloaded tarball. This script is read-only against GitHub and does not mutate
local release state unless KEEP_DOWNLOADS=1 is set.

Environment:
  GITHUB_REPO                         default: Augustas11/macprovider
  RELEASE_TAG                         default: v1.2.6
  INSTALL_SH                          default: phase3-binary/dist/install.sh
  CHECKER                             default: scripts/check-tier2-provider-artifact.sh
  MACPROVIDER_CHECKSUM_PUBLIC_KEY_PEM optional public key override
  PROVIDER_VERSION                    default: RELEASE_TAG without leading v
  KEEP_DOWNLOADS=1                    keep downloaded artifacts and print path
  DOWNLOAD_ATTEMPTS                    default: 1
  DOWNLOAD_RETRY_SLEEP                 seconds between attempts; default: 5
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --tag)
      [ "$#" -ge 2 ] || die "--tag requires a value"
      RELEASE_TAG="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

case "$RELEASE_TAG" in
  v[0-9]*.[0-9]*.[0-9]*) ;;
  *) die "RELEASE_TAG must look like v1.2.6: $RELEASE_TAG" ;;
esac

if [ -n "$PROVIDER_VERSION_OVERRIDE" ]; then
  PROVIDER_VERSION="$PROVIDER_VERSION_OVERRIDE"
else
  PROVIDER_VERSION="${RELEASE_TAG#v}"
fi

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

require_file() {
  local path="$1"
  [ -f "$path" ] || die "missing file: $path"
}

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

write_public_key() {
  if [ -n "${MACPROVIDER_CHECKSUM_PUBLIC_KEY_PEM:-}" ]; then
    printf '%s\n' "$MACPROVIDER_CHECKSUM_PUBLIC_KEY_PEM"
    return
  fi
  awk '
    /-----BEGIN PUBLIC KEY-----/ { printing = 1 }
    printing { print }
    /-----END PUBLIC KEY-----/ { exit }
  ' "$INSTALL_SH"
}

checksum_for_asset() {
  local checksums="$1"
  local asset="$2"
  awk -v asset="$asset" '$2 == asset { print $1 }' "$checksums" | head -1
}

tmpdir=""
temp_parent=""
cleanup() {
  if [ -n "$tmpdir" ] && [ "$KEEP_DOWNLOADS" != "1" ]; then
    case "$tmpdir" in
      "$temp_parent"/tier2-provider-release.*) rm -rf "$tmpdir" ;;
      *) die "refusing to remove unexpected temporary directory: $tmpdir" ;;
    esac
  fi
}
trap cleanup EXIT

require_command "$CURL_BIN"
require_command "$OPENSSL_BIN"
require_command awk
require_file "$INSTALL_SH"
require_file "$CHECKER"

case "$DOWNLOAD_ATTEMPTS" in
  ''|*[!0-9]*) die "DOWNLOAD_ATTEMPTS must be a positive integer" ;;
esac
[ "$DOWNLOAD_ATTEMPTS" -ge 1 ] || die "DOWNLOAD_ATTEMPTS must be >= 1"
case "$DOWNLOAD_RETRY_SLEEP" in
  ''|*[!0-9]*) die "DOWNLOAD_RETRY_SLEEP must be a non-negative integer" ;;
esac

download_file() {
  local url="$1"
  local out="$2"
  local label="$3"
  local attempt=1
  while :; do
    if "$CURL_BIN" -fsSL "$url" -o "$out"; then
      return 0
    fi
    if [ "$attempt" -ge "$DOWNLOAD_ATTEMPTS" ]; then
      die "failed to download $label from $url after $attempt attempt(s)"
    fi
    log "download failed for $label, retrying in ${DOWNLOAD_RETRY_SLEEP}s (attempt $attempt/$DOWNLOAD_ATTEMPTS)"
    sleep "$DOWNLOAD_RETRY_SLEEP"
    attempt=$((attempt + 1))
  done
}

asset="macprovider-cli-${RELEASE_TAG}-darwin-arm64.tar.gz"
base="https://github.com/${GITHUB_REPO}/releases/download/${RELEASE_TAG}"

temp_parent="${TMPDIR:-/tmp}"
[ -d "$temp_parent" ] || die "temporary directory parent does not exist: $temp_parent"
temp_parent="$(cd "$temp_parent" && pwd -P)"
tmpdir="$(mktemp -d "$temp_parent/tier2-provider-release.XXXXXX")"

tarball_path="$tmpdir/$asset"
checksums_path="$tmpdir/checksums.txt"
checksums_sig_path="$tmpdir/checksums.txt.sig"
public_key_path="$tmpdir/release-signing-public.pem"

log "downloading release asset set for $GITHUB_REPO $RELEASE_TAG"
download_file "$base/$asset" "$tarball_path" "$asset"
download_file "$base/checksums.txt" "$checksums_path" "checksums.txt"
download_file "$base/checksums.txt.sig" "$checksums_sig_path" "checksums.txt.sig"

write_public_key >"$public_key_path"
if ! grep -q -- "-----BEGIN PUBLIC KEY-----" "$public_key_path"; then
  die "release signing public key was not found in $INSTALL_SH"
fi
if grep -q "REPLACE_WITH_MACPROVIDER" "$public_key_path"; then
  die "release signing public key is not configured in install.sh"
fi

"$OPENSSL_BIN" dgst -sha256 \
  -verify "$public_key_path" \
  -signature "$checksums_sig_path" \
  "$checksums_path" >/dev/null || die "checksums.txt signature verification failed"
log "checksums.txt signature verified"

expected_sha="$(checksum_for_asset "$checksums_path" "$asset")"
[ -n "$expected_sha" ] || die "checksums.txt has no entry for $asset"
actual_sha="$(sha256_file "$tarball_path")"
[ "$actual_sha" = "$expected_sha" ] || die "provider artifact sha256 mismatch: got $actual_sha want $expected_sha"
log "provider artifact sha256 verified: $actual_sha"

PROVIDER_ARTIFACT="$tarball_path" \
  PROVIDER_VERSION="$PROVIDER_VERSION" \
  PROVIDER_SHA256="$expected_sha" \
  "$CHECKER"

if [ "$KEEP_DOWNLOADS" = "1" ]; then
  log "kept downloaded release assets at $tmpdir"
fi
log "SPEC-008 B6 provider GitHub Release verifier passed for $RELEASE_TAG"
