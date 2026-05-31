#!/usr/bin/env bash
# Non-mutating SPEC-008 Phase 2 B6 provider artifact preflight.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PROVIDER_ARTIFACT="${PROVIDER_ARTIFACT:-$REPO_ROOT/phase3-binary/dist/phase3-binary-m4-v1.2.6.tar.gz}"
PROVIDER_VERSION="${PROVIDER_VERSION:-1.2.6}"
PROVIDER_SHA256="${PROVIDER_SHA256-d096ecb82863275478e919a4c0741750c272beb4a0ba5e5c3e778cba159184e2}"
REQUIRE_TIER2_STRINGS="${REQUIRE_TIER2_STRINGS:-1}"
FORBID_TIER2_STRINGS="${FORBID_TIER2_STRINGS-DeviceCheck devicecheck}"

log() { printf '[tier2-provider-artifact] %s\n' "$*" >&2; }
die() { printf '[tier2-provider-artifact] ERROR: %s\n' "$*" >&2; exit 1; }

require_file() {
  local path="$1"
  [ -f "$path" ] || die "missing file: $path"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
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

check_sha256() {
  local path="$1"
  local expected="$2"
  local actual
  actual="$(sha256_file "$path")"
  if [ -z "$expected" ]; then
    log "provider artifact sha256 observed: $actual"
    return
  fi
  if [ "$actual" != "$expected" ]; then
    die "provider artifact sha256 mismatch: got $actual want $expected"
  fi
  log "provider artifact sha256 ok: $actual"
}

tmpdir=""
temp_parent=""
cleanup() {
  if [ -n "$tmpdir" ]; then
    case "$tmpdir" in
      "$temp_parent"/tier2-provider-artifact.*) rm -rf "$tmpdir" ;;
      *) die "refusing to remove unexpected temporary directory: $tmpdir" ;;
    esac
  fi
}
trap cleanup EXIT

require_command tar
require_command grep
require_file "$PROVIDER_ARTIFACT"

check_sha256 "$PROVIDER_ARTIFACT" "$PROVIDER_SHA256"

temp_parent="${TMPDIR:-/tmp}"
[ -d "$temp_parent" ] || die "temporary directory parent does not exist: $temp_parent"
temp_parent="$(cd "$temp_parent" && pwd -P)"
tmpdir="$(mktemp -d "$temp_parent/tier2-provider-artifact.XXXXXX")"

tar -xzf "$PROVIDER_ARTIFACT" -C "$tmpdir" macprovider-cli
provider_binary="$tmpdir/macprovider-cli"
[ -x "$provider_binary" ] || die "extracted provider binary is not executable: $provider_binary"

provider_version="$("$provider_binary" --version)"
if [ "$provider_version" != "$PROVIDER_VERSION" ]; then
  die "provider version mismatch: got $provider_version want $PROVIDER_VERSION"
fi
log "provider version ok: $provider_version"

if [ "$REQUIRE_TIER2_STRINGS" = "1" ]; then
  for literal in \
    "provider_ecdh_public_key" \
    "tier2_capabilities" \
    "selected_aead_suite" \
    "attestation_token" \
    "certificate_signing_request" \
    "MACPROVIDER_TIER2_MDA_ARTIFACT_PATH" \
    "A256GCM" \
    "inference_response_chunk"
  do
    grep -a -q "$literal" "$provider_binary" || die "provider binary lacks Tier-2 surface string: $literal"
    log "provider binary contains Tier-2 surface string: $literal"
  done
fi

if [ -n "$FORBID_TIER2_STRINGS" ]; then
  for literal in $FORBID_TIER2_STRINGS; do
    if grep -a -q "$literal" "$provider_binary"; then
      die "provider binary contains forbidden Tier-2 attestation string: $literal"
    fi
    log "provider binary lacks forbidden Tier-2 attestation string: $literal"
  done
fi

log "SPEC-008 Phase 2 B6 provider artifact preflight passed"
