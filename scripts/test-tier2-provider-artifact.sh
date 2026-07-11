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
  printf 'fake metallib\n' >"$dir/mlx.metallib"
}

make_tarball() {
  local src_dir="$1"
  local out="$2"
  tar -czf "$out" -C "$src_dir" .
}

make_malicious_tarball() {
  local out="$1"
  local kind="$2"
  python3 - "$out" "$kind" <<'PY'
import io
import stat
import sys
import tarfile

out, kind = sys.argv[1], sys.argv[2]

def add_file(tar, name, data, mode=0o644):
    payload = data.encode()
    info = tarfile.TarInfo(name)
    info.size = len(payload)
    info.mode = mode
    tar.addfile(info, io.BytesIO(payload))

with tarfile.open(out, "w:gz") as tar:
    add_file(tar, "macprovider-cli", "#!/usr/bin/env bash\nprintf '1.2.6\\n'\n", 0o755)
    if kind != "symlink-metallib":
        add_file(tar, "mlx.metallib", "fake metallib\n")

    if kind == "traversal":
        add_file(tar, "../evil", "evil\n")
    elif kind == "absolute":
        add_file(tar, "/tmp/evil", "evil\n")
    elif kind == "symlink-metallib":
        info = tarfile.TarInfo("mlx.metallib")
        info.type = tarfile.SYMTYPE
        info.linkname = "/etc/passwd"
        tar.addfile(info)
    elif kind == "hardlink":
        info = tarfile.TarInfo("hardlink")
        info.type = tarfile.LNKTYPE
        info.linkname = "macprovider-cli"
        tar.addfile(info)
    elif kind == "fifo":
        info = tarfile.TarInfo("fifo")
        info.type = tarfile.FIFOTYPE
        info.mode = stat.S_IFIFO | 0o644
        tar.addfile(info)
    else:
        raise SystemExit(f"unknown malicious tar kind: {kind}")
PY
}

good_dir="$WORKDIR/good"
good_tar="$WORKDIR/good.tar.gz"
make_fake_binary "$good_dir" "1.2.6" "1"
mkdir -p "$good_dir/catalog-release"
for catalog_member in release.json trusted-keys.json autotune-candidates.json \
  autotune-candidates.json.sig demand-rank.json demand-rank.json.sig; do
  printf '{}\n' > "$good_dir/catalog-release/$catalog_member"
done
make_tarball "$good_dir" "$good_tar"
good_sha="$(sha256_file "$good_tar")"

PROVIDER_ARTIFACT="$good_tar" \
  PROVIDER_VERSION="1.2.6" \
  PROVIDER_SHA256="$good_sha" \
  "$CHECKER" >"$WORKDIR/good.out" 2>"$WORKDIR/good.err"
assert_contains "$WORKDIR/good.err" "SPEC-008 Phase 2 B6 provider artifact preflight passed"

missing_catalog_dir="$WORKDIR/missing-catalog"
missing_catalog_tar="$WORKDIR/missing-catalog.tar.gz"
make_fake_binary "$missing_catalog_dir" "1.8.31" "1"
mkdir -p "$missing_catalog_dir/catalog-release"
for catalog_member in release.json trusted-keys.json autotune-candidates.json \
  autotune-candidates.json.sig demand-rank.json; do
  printf '{}\n' > "$missing_catalog_dir/catalog-release/$catalog_member"
done
make_tarball "$missing_catalog_dir" "$missing_catalog_tar"
missing_catalog_sha="$(sha256_file "$missing_catalog_tar")"
if PROVIDER_ARTIFACT="$missing_catalog_tar" \
  PROVIDER_VERSION="1.8.31" \
  PROVIDER_SHA256="$missing_catalog_sha" \
  "$CHECKER" >"$WORKDIR/missing-catalog.out" 2>"$WORKDIR/missing-catalog.err"; then
  die "catalog-incomplete v1.8.31 artifact unexpectedly passed"
fi
assert_contains "$WORKDIR/missing-catalog.err" \
  "exactly one catalog-release/demand-rank.json.sig"

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

missing_metallib_dir="$WORKDIR/missing-metallib"
missing_metallib_tar="$WORKDIR/missing-metallib.tar.gz"
make_fake_binary "$missing_metallib_dir" "1.2.6" "1"
rm -f "$missing_metallib_dir/mlx.metallib"
make_tarball "$missing_metallib_dir" "$missing_metallib_tar"
missing_metallib_sha="$(sha256_file "$missing_metallib_tar")"

if PROVIDER_ARTIFACT="$missing_metallib_tar" \
  PROVIDER_VERSION="1.2.6" \
  PROVIDER_SHA256="$missing_metallib_sha" \
  "$CHECKER" >"$WORKDIR/metallib.out" 2>"$WORKDIR/metallib.err"; then
  die "missing MLX Metal kernels unexpectedly passed"
fi
assert_contains "$WORKDIR/metallib.err" "provider artifact lacks MLX Metal kernels"

for kind in traversal absolute; do
  bad_tar="$WORKDIR/${kind}.tar.gz"
  make_malicious_tarball "$bad_tar" "$kind"
  bad_sha="$(sha256_file "$bad_tar")"
  if PROVIDER_ARTIFACT="$bad_tar" \
    PROVIDER_VERSION="1.2.6" \
    PROVIDER_SHA256="$bad_sha" \
    "$CHECKER" >"$WORKDIR/${kind}.out" 2>"$WORKDIR/${kind}.err"; then
    die "$kind artifact unexpectedly passed"
  fi
  assert_contains "$WORKDIR/${kind}.err" "unsafe provider artifact path"
done

for kind in symlink-metallib hardlink fifo; do
  bad_tar="$WORKDIR/${kind}.tar.gz"
  make_malicious_tarball "$bad_tar" "$kind"
  bad_sha="$(sha256_file "$bad_tar")"
  if PROVIDER_ARTIFACT="$bad_tar" \
    PROVIDER_VERSION="1.2.6" \
    PROVIDER_SHA256="$bad_sha" \
    "$CHECKER" >"$WORKDIR/${kind}.out" 2>"$WORKDIR/${kind}.err"; then
    die "$kind artifact unexpectedly passed"
  fi
  assert_contains "$WORKDIR/${kind}.err" "provider artifact contains unsafe link or device members"
done

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
