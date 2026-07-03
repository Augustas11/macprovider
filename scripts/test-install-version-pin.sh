#!/usr/bin/env bash
# Hermetic regression guard for install.sh's MACPROVIDER_VERSION pinning
# and prerelease-aware latest-release selection.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_SH="$REPO_ROOT/phase3-binary/dist/install.sh"

fatal() {
  printf '[install-version-pin-test] ERROR: %s\n' "$*" >&2
  exit 1
}

[ -f "$INSTALL_SH" ] || fatal "missing installer: $INSTALL_SH"

lib="$(mktemp "${TMPDIR:-/tmp}/macprovider-install-version-lib.XXXXXX")"
workdir="$(mktemp -d "${TMPDIR:-/tmp}/macprovider-install-version.XXXXXX")"
trap 'rm -f "$lib"; rm -rf "$workdir"' EXIT

awk '
  /^latest_release_tag\(\)/ { emit = 1 }
  /^download_release\(\)/ { emit = 0 }
  emit { print }
' "$INSTALL_SH" > "$lib"

awk '
  /^download_release\(\)/ { emit = 1 }
  emit { print }
  emit && /^\}$/ { exit }
' "$INSTALL_SH" >> "$lib"

awk '
  /^checksum_for_asset\(\)/ { emit = 1 }
  emit { print }
  emit && /^\}$/ { exit }
' "$INSTALL_SH" >> "$lib"

awk '
  /^verify_sha256\(\)/ { emit = 1 }
  emit { print }
  emit && /^\}$/ { exit }
' "$INSTALL_SH" >> "$lib"

for symbol in latest_release_tag validate_macprovider_version_tag resolve_release_tag download_release verify_sha256; do
  grep -q "^${symbol}()" "$lib" || fatal "could not extract $symbol from $INSTALL_SH"
done

MACPROVIDER_MIN_SUPPORTED_VERSION="v1.7.11"
GITHUB_REPO="Augustas11/macprovider"
TMPDIR_PATH=""
asset_path=""
asset_kind=""
checksums_path=""
checksums_sig_path=""
DOWNLOAD_LOG="$workdir/downloads.log"
LOG_FILE="$workdir/log.out"

log() { printf '%s\n' "$*" >> "$LOG_FILE"; }
die() {
  code="$1"
  shift
  printf 'die[%s] %s\n' "$code" "$*" >> "$LOG_FILE"
  exit "$code"
}
verify_checksum_signature() {
  if [ "${MOCK_SIGNATURE_FAIL:-0}" = "1" ]; then
    die 4 "checksum signature verification failed"
  fi
  log "signature checked"
}
validate_release_payload() {
  VALIDATE_CALLED=$((VALIDATE_CALLED + 1))
  log "payload validated"
}
shasum() {
  printf '%s  %s\n' "${MOCK_SHA:-goodhash}" "$2"
}
curl() {
  local out="" url="" arg
  while [ "$#" -gt 0 ]; do
    arg="$1"
    shift
    case "$arg" in
      -o)
        out="$1"
        shift
        ;;
      http*)
        url="$arg"
        ;;
    esac
  done

  case "$url" in
    *"/releases?per_page=30")
      printf '%s' "$MOCK_RELEASES_JSON"
      ;;
    *"/v99.0.0/"*)
      return 22
      ;;
    *"/checksums.txt.sig")
      printf 'sig' > "$out"
      ;;
    *"/checksums.txt")
      printf '%s\n' "$MOCK_CHECKSUMS" > "$out"
      ;;
    *".pkg")
      printf '%s\n' "$url" >> "$DOWNLOAD_LOG"
      printf 'pkg' > "$out"
      ;;
    *".tar.gz")
      printf '%s\n' "$url" >> "$DOWNLOAD_LOG"
      printf 'tar' > "$out"
      ;;
    *)
      printf 'unexpected curl URL: %s\n' "$url" >&2
      return 2
      ;;
  esac
}

# shellcheck source=/dev/null
. "$lib"

pass=0
fail=0
report() {
  local name="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    pass=$((pass + 1))
    printf 'PASS %s\n' "$name"
  else
    fail=$((fail + 1))
    printf 'FAIL %s: want=%q got=%q\n' "$name" "$want" "$got" >&2
  fi
}

reset_mocks() {
  : > "$DOWNLOAD_LOG"
  : > "$LOG_FILE"
  VALIDATE_CALLED=0
  MOCK_SHA="goodhash"
  MOCK_SIGNATURE_FAIL=0
  MOCK_CHECKSUMS="goodhash macprovider-cli-v1.7.11-darwin-arm64.pkg"
  MOCK_RELEASES_JSON='[{"tag_name":"v1.8.0","prerelease":true},{"tag_name":"verify-v1.0.0","prerelease":false},{"tag_name":"v1.7.11","prerelease":false}]'
  unset MACPROVIDER_VERSION
}

run_release_chain() {
  local tag
  tag="$(resolve_release_tag)"
  download_release "$tag"
  verify_sha256
  validate_release_payload
}

################################################################
# Case 1 — pinned supported version uses the signed release path.
################################################################
reset_mocks
MACPROVIDER_VERSION="v1.7.11"
run_release_chain
report "case1-pinned-url" \
  "https://github.com/Augustas11/macprovider/releases/download/v1.7.11/macprovider-cli-v1.7.11-darwin-arm64.pkg" \
  "$(cat "$DOWNLOAD_LOG")"
report "case1-validation-chain-called" 1 "$VALIDATE_CALLED"

################################################################
# Case 2 — unset pin skips prerelease v1.8.0 and chooses latest stable.
################################################################
reset_mocks
tag="$(resolve_release_tag)"
report "case2-latest-skips-prerelease" "v1.7.11" "$tag"

reset_mocks
MOCK_RELEASES_JSON='[{"prerelease":true,"tag_name":"v1.8.0"},{"prerelease":false,"tag_name":"v1.7.11"}]'
tag="$(resolve_release_tag)"
report "case2-prerelease-before-tag-skips-prerelease" "v1.7.11" "$tag"

################################################################
# Case 3 — nonexistent but valid-shape tag fails clearly, no latest fallback.
################################################################
reset_mocks
MACPROVIDER_VERSION="v99.0.0"
rc=0
( run_release_chain ) >/dev/null 2>&1 || rc=$?
report "case3-nonexistent-tag-fails" 3 "$rc"
report "case3-no-latest-fallback" "" "$(cat "$DOWNLOAD_LOG")"

################################################################
# Case 4 — invalid tag shapes fail before download.
################################################################
for invalid in main verify-v1.0.0 ../v1.7.11 $'v1.7.11\nbad' $'v2.0.0\nbad'; do
  reset_mocks
  MACPROVIDER_VERSION="$invalid"
  rc=0
  ( resolve_release_tag ) >/dev/null 2>&1 || rc=$?
  report "case4-invalid-${invalid//$'\n'/newline}" 7 "$rc"
done

################################################################
# Case 5 — below rollback floor fails closed.
################################################################
reset_mocks
MACPROVIDER_VERSION="v1.7.10"
rc=0
( resolve_release_tag ) >/dev/null 2>&1 || rc=$?
report "case5-below-floor-fails" 7 "$rc"

################################################################
# Case 6 — pinned checksum mismatch aborts without latest fallback.
################################################################
reset_mocks
MACPROVIDER_VERSION="v1.7.11"
MOCK_SHA="badhash"
rc=0
( run_release_chain ) >/dev/null 2>&1 || rc=$?
report "case6-checksum-mismatch-fails" 4 "$rc"
report "case6-pinned-only-download" \
  "https://github.com/Augustas11/macprovider/releases/download/v1.7.11/macprovider-cli-v1.7.11-darwin-arm64.pkg" \
  "$(cat "$DOWNLOAD_LOG")"

################################################################
# Case 7 — pinned signature mismatch aborts without latest fallback.
################################################################
reset_mocks
MACPROVIDER_VERSION="v1.7.11"
MOCK_SIGNATURE_FAIL=1
rc=0
( run_release_chain ) >/dev/null 2>&1 || rc=$?
report "case7-signature-mismatch-fails" 4 "$rc"
report "case7-no-asset-download-after-signature-fail" "" "$(cat "$DOWNLOAD_LOG")"

################################################################
# Case 8 — documented curl-pipe-bash env placement reaches bash.
################################################################
if printf 'test "$MACPROVIDER_VERSION" = "v1.7.11"\n' | MACPROVIDER_VERSION=v1.7.11 bash; then
  report "case8-pipe-side-env" ok ok
else
  report "case8-pipe-side-env" ok fail
fi

################################################################
# Case 9 — explicit pin can opt into prerelease tag.
################################################################
reset_mocks
MACPROVIDER_VERSION="v1.8.0"
tag="$(resolve_release_tag)"
report "case9-explicit-prerelease-pin" "v1.8.0" "$tag"

if [ "$fail" -ne 0 ]; then
  printf '[install-version-pin-test] %d failed, %d passed\n' "$fail" "$pass" >&2
  exit 1
fi

printf '[install-version-pin-test] all %d checks passed\n' "$pass"
