#!/usr/bin/env bash
# Non-mutating SPEC-008 Phase 1 activation bundle preflight.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PROVIDER_ARTIFACT="${PROVIDER_ARTIFACT:-$REPO_ROOT/phase3-binary/dist/phase3-binary-m4-v1.2.5.tar.gz}"
PROVIDER_SHA256="${PROVIDER_SHA256:-}"
PROVIDER_VERSION="${PROVIDER_VERSION:-1.2.5}"

COORDINATOR_BINARY="${COORDINATOR_BINARY:-$REPO_ROOT/phase4-coordinator/dist/coordinator-linux-amd64}"
COORDINATOR_SHA256="${COORDINATOR_SHA256:-8b8bbb58f1062e504d414aaec3712660bf4c98b53a8d49a7554a2288687b1a91}"

CATALOG="${CATALOG:-$REPO_ROOT/.omc/tier2/tier2-catalog.json}"
PUBLIC_KEY_FILE="${PUBLIC_KEY_FILE:-$REPO_ROOT/.omc/tier2/catalog-signing-key.pub}"
PUBLIC_KEY="${PUBLIC_KEY:-IVH2aAlTudARJSK3e7XGmcGjxAqwm6lReGiS-0U9aFQ}"
AUTOTUNE_CANDIDATES="${AUTOTUNE_CANDIDATES:-$REPO_ROOT/phase3-binary/catalog/autotune/autotune-candidates.json}"

log() { printf '[tier2-artifacts] %s\n' "$*" >&2; }
die() { printf '[tier2-artifacts] ERROR: %s\n' "$*" >&2; exit 1; }

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

check_sha256() {
  local label="$1"
  local path="$2"
  local expected="$3"
  local actual
  actual="$(sha256_file "$path")"
  if [ -z "$expected" ]; then
    log "$label sha256 observed: $actual"
    return
  fi
  if [ "$actual" != "$expected" ]; then
    die "$label sha256 mismatch: got $actual want $expected"
  fi
  log "$label sha256 ok: $actual"
}

tmpdir=""
temp_parent=""
cleanup() {
  if [ -n "$tmpdir" ]; then
    case "$tmpdir" in
      "$temp_parent"/tier2-artifacts.*) rm -rf "$tmpdir" ;;
      *) die "refusing to remove unexpected temporary directory: $tmpdir" ;;
    esac
  fi
}
trap cleanup EXIT

require_file "$PROVIDER_ARTIFACT"
require_file "$COORDINATOR_BINARY"
require_file "$CATALOG"
require_file "$PUBLIC_KEY_FILE"

check_sha256 "provider artifact" "$PROVIDER_ARTIFACT" "$PROVIDER_SHA256"
temp_parent="${TMPDIR:-/tmp}"
[ -d "$temp_parent" ] || die "temporary directory parent does not exist: $temp_parent"
temp_parent="$(cd "$temp_parent" && pwd -P)"
tmpdir="$(mktemp -d "$temp_parent/tier2-artifacts.XXXXXX")"
tar -xzf "$PROVIDER_ARTIFACT" -C "$tmpdir" macprovider-cli
provider_version="$("$tmpdir/macprovider-cli" --version)"
if [ "$provider_version" != "$PROVIDER_VERSION" ]; then
  die "provider version mismatch: got $provider_version want $PROVIDER_VERSION"
fi
log "provider version ok: $provider_version"

check_sha256 "coordinator binary" "$COORDINATOR_BINARY" "$COORDINATOR_SHA256"
[ -x "$COORDINATOR_BINARY" ] || die "coordinator binary is not executable: $COORDINATOR_BINARY"
grep -a -q 'tier2 catalog loaded' "$COORDINATOR_BINARY" || die "coordinator binary lacks tier2 catalog-loaded log string"
log "coordinator binary contains tier2 catalog-loaded log string"

actual_public_key="$(tr -d '\n' < "$PUBLIC_KEY_FILE")"
if [ "$actual_public_key" != "$PUBLIC_KEY" ]; then
  die "catalog public key mismatch: got $actual_public_key want $PUBLIC_KEY"
fi
log "catalog public key ok: $actual_public_key"

go run "$REPO_ROOT/scripts/sign-catalog.go" verify \
  -public-key "$PUBLIC_KEY_FILE" \
  "$CATALOG"

if [ -f "$AUTOTUNE_CANDIDATES" ]; then
  python3 "$REPO_ROOT/scripts/catalog-release.py" check-tier2-binding \
    --candidate "$AUTOTUNE_CANDIDATES" \
    --tier2 "$CATALOG" || die "autotune/tier2 identity conflict (#608); refuse Tier-2 artifacts that drift from AUTOTUNE_CANDIDATES"
  log "autotune/tier2 identity binding ok"
else
  log "warning: AUTOTUNE_CANDIDATES missing ($AUTOTUNE_CANDIDATES); skipped check-tier2-binding"
fi

log "SPEC-008 Phase 1 activation bundle preflight passed"
