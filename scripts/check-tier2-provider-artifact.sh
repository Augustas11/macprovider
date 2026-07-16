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

provider_version_at_least() {
  local required_major="$1"
  local required_minor="$2"
  local required_patch="$3"
  local major minor patch
  if [[ ! "$PROVIDER_VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    die "PROVIDER_VERSION must be a stable semantic version: $PROVIDER_VERSION"
  fi
  major="${BASH_REMATCH[1]}"
  minor="${BASH_REMATCH[2]}"
  patch="${BASH_REMATCH[3]}"
  [ "$major" -gt "$required_major" ] || \
    { [ "$major" -eq "$required_major" ] && [ "$minor" -gt "$required_minor" ]; } || \
    { [ "$major" -eq "$required_major" ] && [ "$minor" -eq "$required_minor" ] && [ "$patch" -ge "$required_patch" ]; }
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

validate_artifact_entries() {
  local entries="$1"
  local has_binary=0
  local has_metal=0
  local has_catalog_manifest=0
  local has_catalog_keyring=0
  local has_catalog_candidates=0
  local has_catalog_candidates_signature=0
  local has_catalog_demand=0
  local has_catalog_demand_signature=0
  local has_compatibility_set=0
  local has_local_install_contract=0 has_local_provider_plist=0 has_local_updater_metadata=0
  local has_local_watchdog_plist=0 has_local_watchdog_script=0
  local version_major version_minor version_patch
  local entry normalized_entry
  while IFS= read -r entry; do
    normalized_entry="$entry"
    while :; do
      case "$normalized_entry" in
        ./*) normalized_entry="${normalized_entry#./}" ;;
        *) break ;;
      esac
    done
    case "$normalized_entry" in
      ""|.) continue ;;
    esac
    case "$normalized_entry" in
      /*|*"/../"*|../*|*/..|..)
        die "unsafe provider artifact path: $entry"
        ;;
      macprovider-cli)
        has_binary=1
        ;;
      mlx.metallib|mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib)
        has_metal=1
        ;;
      THIRD-PARTY-NOTICES.txt)
        ;;
      compatibility-set.json)
        has_compatibility_set=$((has_compatibility_set + 1))
        ;;
      compatibility-set-local|compatibility-set-local/)
        ;;
      compatibility-set-local/install.sh)
        has_local_install_contract=$((has_local_install_contract + 1))
        ;;
      compatibility-set-local/provider-launch-agent.plist.template)
        has_local_provider_plist=$((has_local_provider_plist + 1))
        ;;
      compatibility-set-local/updater-rollback.json)
        has_local_updater_metadata=$((has_local_updater_metadata + 1))
        ;;
      compatibility-set-local/watchdog-launch-agent.plist.template)
        has_local_watchdog_plist=$((has_local_watchdog_plist + 1))
        ;;
      compatibility-set-local/watchdog.sh)
        has_local_watchdog_script=$((has_local_watchdog_script + 1))
        ;;
      catalog-release|catalog-release/)
        ;;
      catalog-release/release.json)
        has_catalog_manifest=$((has_catalog_manifest + 1))
        ;;
      catalog-release/trusted-keys.json)
        has_catalog_keyring=$((has_catalog_keyring + 1))
        ;;
      catalog-release/autotune-candidates.json)
        has_catalog_candidates=$((has_catalog_candidates + 1))
        ;;
      catalog-release/autotune-candidates.json.sig)
        has_catalog_candidates_signature=$((has_catalog_candidates_signature + 1))
        ;;
      catalog-release/demand-rank.json)
        has_catalog_demand=$((has_catalog_demand + 1))
        ;;
      catalog-release/demand-rank.json.sig)
        has_catalog_demand_signature=$((has_catalog_demand_signature + 1))
        ;;
      *.bundle|*.bundle/*)
        ;;
      *)
        die "unexpected provider artifact member: $entry"
        ;;
    esac
  done <<EOF
$entries
EOF

  [ "$has_binary" -eq 1 ] || die "provider artifact does not contain macprovider-cli"
  [ "$has_metal" -eq 1 ] || die "provider artifact lacks MLX Metal kernels (mlx.metallib or mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib)"
  if [[ ! "$PROVIDER_VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    die "PROVIDER_VERSION must be a stable semantic version: $PROVIDER_VERSION"
  fi
  version_major="${BASH_REMATCH[1]}"
  version_minor="${BASH_REMATCH[2]}"
  version_patch="${BASH_REMATCH[3]}"
  if [ "$version_major" -gt 1 ] || \
     { [ "$version_major" -eq 1 ] && [ "$version_minor" -gt 8 ]; } || \
     { [ "$version_major" -eq 1 ] && [ "$version_minor" -eq 8 ] && [ "$version_patch" -ge 31 ]; }; then
    [ "$has_catalog_manifest" -eq 1 ] || die "provider artifact must contain exactly one catalog-release/release.json"
    [ "$has_catalog_keyring" -eq 1 ] || die "provider artifact must contain exactly one catalog-release/trusted-keys.json"
    [ "$has_catalog_candidates" -eq 1 ] || die "provider artifact must contain exactly one catalog-release/autotune-candidates.json"
    [ "$has_catalog_candidates_signature" -eq 1 ] || die "provider artifact must contain exactly one catalog-release/autotune-candidates.json.sig"
    [ "$has_catalog_demand" -eq 1 ] || die "provider artifact must contain exactly one catalog-release/demand-rank.json"
    [ "$has_catalog_demand_signature" -eq 1 ] || die "provider artifact must contain exactly one catalog-release/demand-rank.json.sig"
  fi
  if [ "$version_major" -gt 1 ] || \
     { [ "$version_major" -eq 1 ] && [ "$version_minor" -gt 8 ]; } || \
     { [ "$version_major" -eq 1 ] && [ "$version_minor" -eq 8 ] && [ "$version_patch" -ge 33 ]; }; then
    [ "$has_compatibility_set" -eq 1 ] || die "provider artifact must contain exactly one compatibility-set.json"
    [ "$has_local_install_contract" -eq 1 ] || die "provider artifact must contain exactly one local install contract"
    [ "$has_local_provider_plist" -eq 1 ] || die "provider artifact must contain exactly one provider launchd template"
    [ "$has_local_updater_metadata" -eq 1 ] || die "provider artifact must contain exactly one updater rollback metadata file"
    [ "$has_local_watchdog_plist" -eq 1 ] || die "provider artifact must contain exactly one watchdog launchd template"
    [ "$has_local_watchdog_script" -eq 1 ] || die "provider artifact must contain exactly one watchdog script"
  fi
}

validate_artifact_member_types() {
  if tar tvzf "$PROVIDER_ARTIFACT" | awk '{print substr($1,1,1), $0}' | grep -E '^[lhbcp]' >/dev/null; then
    die "provider artifact contains unsafe link or device members"
  fi
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
artifact_entries="$(tar tzf "$PROVIDER_ARTIFACT")" || die "failed to list provider artifact"
[ -n "$artifact_entries" ] || die "provider artifact is empty"
validate_artifact_member_types
validate_artifact_entries "$artifact_entries"

temp_parent="${TMPDIR:-/tmp}"
[ -d "$temp_parent" ] || die "temporary directory parent does not exist: $temp_parent"
temp_parent="$(cd "$temp_parent" && pwd -P)"
tmpdir="$(mktemp -d "$temp_parent/tier2-provider-artifact.XXXXXX")"

tar -xzf "$PROVIDER_ARTIFACT" -C "$tmpdir"
provider_binary="$tmpdir/macprovider-cli"
[ -x "$provider_binary" ] || die "extracted provider binary is not executable: $provider_binary"

log "provider artifact includes MLX Metal kernels"

provider_version="$("$provider_binary" --version)"
if [ "$provider_version" != "$PROVIDER_VERSION" ]; then
  die "provider version mismatch: got $provider_version want $PROVIDER_VERSION"
fi
log "provider version ok: $provider_version"

if [ -f "$tmpdir/compatibility-set.json" ]; then
  require_file "$REPO_ROOT/ops/pearl-updater/release-signing-public.pem"
  python3 "$REPO_ROOT/scripts/compatibility-set-manifest.py" validate \
    --input "$tmpdir/compatibility-set.json" \
    --payload-directory "$tmpdir" \
    --require-signature \
    --public-key "$REPO_ROOT/ops/pearl-updater/release-signing-public.pem" \
    --expected-tag "v$PROVIDER_VERSION"
  log "compatibility-set manifest signature and provider version verified"
  if provider_version_at_least 1 8 39; then
    "$provider_binary" release-payload-preflight >/dev/null
    log "staged provider validated its signed compatibility release payload"
  fi
fi

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
