#!/usr/bin/env bash
# Hermetic checks for scripts/check-tier2-provider-artifact.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHECKER="$REPO_ROOT/scripts/check-tier2-provider-artifact.sh"

log() { printf '[tier2-provider-artifact-test] %s\n' "$*" >&2; }
die() { printf '[tier2-provider-artifact-test] ERROR: %s\n' "$*" >&2; exit 1; }

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
  grep -q "$needle" "$path" || die "expected $path to contain: $needle"
}

TMP_BASE="${TMPDIR:-/tmp}"
WORKDIR="$(mktemp -d "$TMP_BASE/tier2-provider-artifact-test.XXXXXX")"
cleanup() {
  case "$WORKDIR" in
    "$TMP_BASE"/tier2-provider-artifact-test.*) rm -rf "$WORKDIR" ;;
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
  else
    cat >>"$dir/macprovider-cli" <<'EOF'
# provider_ecdh_public_key
# tier2_capabilities
# selected_aead_suite
# attestation_token
# certificate_signing_request
# MACPROVIDER_TIER2_MDA_ARTIFACT_PATH
# A256GCM
EOF
  fi
  chmod +x "$dir/macprovider-cli"
}

make_tarball() {
  local src_dir="$1"
  local out="$2"
  tar -czf "$out" -C "$src_dir" macprovider-cli
}

good_dir="$WORKDIR/good"
good_tar="$WORKDIR/good.tar.gz"
make_fake_binary "$good_dir" "1.2.6" "1"
make_tarball "$good_dir" "$good_tar"
good_sha="$(sha256_file "$good_tar")"

PROVIDER_ARTIFACT="$good_tar" \
  PROVIDER_VERSION="1.2.6" \
  PROVIDER_SHA256="$good_sha" \
  "$CHECKER" >"$WORKDIR/good.out" 2>"$WORKDIR/good.err"
assert_contains "$WORKDIR/good.err" "SPEC-008 Phase 2 B6 provider artifact preflight passed"

PROVIDER_ARTIFACT="$good_tar" \
  PROVIDER_VERSION="1.2.6" \
  PROVIDER_SHA256="" \
  "$CHECKER" >"$WORKDIR/dynamic.out" 2>"$WORKDIR/dynamic.err"
assert_contains "$WORKDIR/dynamic.err" "provider artifact sha256 observed"

if PROVIDER_ARTIFACT="$good_tar" \
  PROVIDER_VERSION="9.9.9" \
  PROVIDER_SHA256="$good_sha" \
  "$CHECKER" >"$WORKDIR/version.out" 2>"$WORKDIR/version.err"; then
  die "version mismatch unexpectedly passed"
fi
assert_contains "$WORKDIR/version.err" "provider version mismatch"

if PROVIDER_ARTIFACT="$good_tar" \
  PROVIDER_VERSION="1.2.6" \
  PROVIDER_SHA256="deadbeef" \
  "$CHECKER" >"$WORKDIR/sha.out" 2>"$WORKDIR/sha.err"; then
  die "sha mismatch unexpectedly passed"
fi
assert_contains "$WORKDIR/sha.err" "provider artifact sha256 mismatch"

missing_surface_dir="$WORKDIR/missing-surface"
missing_surface_tar="$WORKDIR/missing-surface.tar.gz"
make_fake_binary "$missing_surface_dir" "1.2.6" "0"
make_tarball "$missing_surface_dir" "$missing_surface_tar"
missing_surface_sha="$(sha256_file "$missing_surface_tar")"

if PROVIDER_ARTIFACT="$missing_surface_tar" \
  PROVIDER_VERSION="1.2.6" \
  PROVIDER_SHA256="$missing_surface_sha" \
  "$CHECKER" >"$WORKDIR/surface.out" 2>"$WORKDIR/surface.err"; then
  die "missing Tier-2 surface unexpectedly passed"
fi
assert_contains "$WORKDIR/surface.err" "provider binary lacks Tier-2 surface string"

PROVIDER_ARTIFACT="$missing_surface_tar" \
  PROVIDER_VERSION="1.2.6" \
  PROVIDER_SHA256="$missing_surface_sha" \
  REQUIRE_TIER2_STRINGS=0 \
  "$CHECKER" >"$WORKDIR/skip-surface.out" 2>"$WORKDIR/skip-surface.err"
assert_contains "$WORKDIR/skip-surface.err" "SPEC-008 Phase 2 B6 provider artifact preflight passed"

forbidden_dir="$WORKDIR/forbidden"
forbidden_tar="$WORKDIR/forbidden.tar.gz"
make_fake_binary "$forbidden_dir" "1.2.6" "1"
printf '# DeviceCheck\n' >>"$forbidden_dir/macprovider-cli"
make_tarball "$forbidden_dir" "$forbidden_tar"
forbidden_sha="$(sha256_file "$forbidden_tar")"

if PROVIDER_ARTIFACT="$forbidden_tar" \
  PROVIDER_VERSION="1.2.6" \
  PROVIDER_SHA256="$forbidden_sha" \
  "$CHECKER" >"$WORKDIR/forbidden.out" 2>"$WORKDIR/forbidden.err"; then
  die "forbidden Tier-2 attestation string unexpectedly passed"
fi
assert_contains "$WORKDIR/forbidden.err" "provider binary contains forbidden Tier-2 attestation string"

PROVIDER_ARTIFACT="$forbidden_tar" \
  PROVIDER_VERSION="1.2.6" \
  PROVIDER_SHA256="$forbidden_sha" \
  FORBID_TIER2_STRINGS="" \
  "$CHECKER" >"$WORKDIR/forbidden-disabled.out" 2>"$WORKDIR/forbidden-disabled.err"
assert_contains "$WORKDIR/forbidden-disabled.err" "SPEC-008 Phase 2 B6 provider artifact preflight passed"

log "ok"
