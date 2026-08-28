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
HDIUTIL_BIN="${HDIUTIL_BIN:-hdiutil}"
PROVIDER_VERSION_OVERRIDE="${PROVIDER_VERSION:-}"
KEEP_DOWNLOADS="${KEEP_DOWNLOADS:-0}"
DOWNLOAD_ATTEMPTS="${DOWNLOAD_ATTEMPTS:-1}"
DOWNLOAD_RETRY_SLEEP="${DOWNLOAD_RETRY_SLEEP:-5}"
PROVIDER_RUNTIME_MODE="${PROVIDER_RUNTIME_MODE:-execute}"
PROVIDER_EXPECTED_ARCHES="${PROVIDER_EXPECTED_ARCHES:-}"
PROVIDER_LIPO_BIN="${PROVIDER_LIPO_BIN:-}"

log() { printf '[tier2-provider-release] %s\n' "$*" >&2; }
die() { printf '[tier2-provider-release] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
usage: scripts/verify-tier2-provider-release.sh [--tag v1.2.6]

Downloads a malibu-cli GitHub Release asset set, verifies the signed
checksum manifest using the installer public key, verifies the release tarball
checksum, then runs scripts/check-tier2-provider-artifact.sh against the
downloaded tarball. When the release also contains Malibu.app, this verifies
the app DMG checksum, code signature, stapled ticket, Gatekeeper, and bundled
CLI byte identity against the standalone provider tarball.
assessment. This script is read-only against GitHub and does not mutate local
release state unless KEEP_DOWNLOADS=1 is set.

Environment:
  GITHUB_REPO                         default: Augustas11/macprovider
  RELEASE_TAG                         default: v1.2.6
  INSTALL_SH                          default: phase3-binary/dist/install.sh
  CHECKER                             default: scripts/check-tier2-provider-artifact.sh
  HDIUTIL_BIN                         default: hdiutil
  MACPROVIDER_CHECKSUM_PUBLIC_KEY_PEM optional public key override
  PROVIDER_VERSION                    default: RELEASE_TAG without leading v
  KEEP_DOWNLOADS=1                    keep downloaded artifacts and print path
  DOWNLOAD_ATTEMPTS                    default: 1
  DOWNLOAD_RETRY_SLEEP                 seconds between attempts; default: 5
  PROVIDER_RUNTIME_MODE                execute (default) or structural
  PROVIDER_EXPECTED_ARCHES             required in structural mode
  PROVIDER_LIPO_BIN                    absolute lipo path when validating arches
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

if [[ ! "$RELEASE_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  die "RELEASE_TAG must look like v1.2.6: $RELEASE_TAG"
fi

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

provider_version_requires_catalog() {
  local major minor patch
  if [[ ! "$PROVIDER_VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    die "PROVIDER_VERSION must be a stable semantic version: $PROVIDER_VERSION"
  fi
  major="${BASH_REMATCH[1]}"
  minor="${BASH_REMATCH[2]}"
  patch="${BASH_REMATCH[3]}"
  [ "$major" -gt 1 ] || \
    { [ "$major" -eq 1 ] && [ "$minor" -gt 8 ]; } || \
    { [ "$major" -eq 1 ] && [ "$minor" -eq 8 ] && [ "$patch" -ge 31 ]; }
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

validate_payload_entries() {
  local payload_dir="$1"
  local label="$2"
  local entries
  local entry normalized_entry has_binary=0
  local has_catalog_manifest=0
  local has_catalog_keyring=0
  local has_catalog_tier2=0
  local has_catalog_candidates=0
  local has_catalog_candidates_signature=0
  local has_catalog_demand=0
  local has_catalog_demand_signature=0
  local has_catalog_rate_card=0
  local has_catalog_rate_card_signature=0
  local has_compatibility_set=0
  local has_local_install_contract=0 has_local_provider_plist=0 has_local_updater_metadata=0
  local has_local_watchdog_plist=0 has_local_watchdog_script=0

  entries="$(cd "$payload_dir" && find . -mindepth 1 -print)" || die "failed to list $label"
  [ -n "$entries" ] || die "$label is empty"
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
        die "unsafe $label path: $entry"
        ;;
      malibu-cli)
        has_binary=1
        ;;
      mlx.metallib)
        ;;
      THIRD-PARTY-NOTICES.txt)
        ;;
      compatibility-set.json)
        has_compatibility_set=$((has_compatibility_set + 1))
        ;;
      compatibility-set-local)
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
      catalog-release)
        ;;
      catalog-release/release.json)
        has_catalog_manifest=$((has_catalog_manifest + 1))
        ;;
      catalog-release/trusted-keys.json)
        has_catalog_keyring=$((has_catalog_keyring + 1))
        ;;
      catalog-release/tier2-catalog.json)
        has_catalog_tier2=$((has_catalog_tier2 + 1))
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
      catalog-release/rate-card.json)
        has_catalog_rate_card=$((has_catalog_rate_card + 1))
        ;;
      catalog-release/rate-card.json.sig)
        has_catalog_rate_card_signature=$((has_catalog_rate_card_signature + 1))
        ;;
      *.bundle|*.bundle/*)
        ;;
      *)
        die "unexpected $label member: $entry"
        ;;
    esac
  done <<EOF
$entries
EOF

  [ "$has_binary" -eq 1 ] || die "$label does not contain malibu-cli"
  if provider_version_requires_catalog; then
    [ "$has_catalog_manifest" -eq 1 ] || die "$label must contain exactly one catalog-release/release.json"
    [ "$has_catalog_keyring" -eq 1 ] || die "$label must contain exactly one catalog-release/trusted-keys.json"
    [ "$has_catalog_tier2" -eq 1 ] || die "$label must contain exactly one catalog-release/tier2-catalog.json"
    [ "$has_catalog_candidates" -eq 1 ] || die "$label must contain exactly one catalog-release/autotune-candidates.json"
    [ "$has_catalog_candidates_signature" -eq 1 ] || die "$label must contain exactly one catalog-release/autotune-candidates.json.sig"
    [ "$has_catalog_demand" -eq 1 ] || die "$label must contain exactly one catalog-release/demand-rank.json"
    [ "$has_catalog_demand_signature" -eq 1 ] || die "$label must contain exactly one catalog-release/demand-rank.json.sig"
    [ "$has_catalog_rate_card" -eq 1 ] || die "$label must contain exactly one catalog-release/rate-card.json"
    [ "$has_catalog_rate_card_signature" -eq 1 ] || die "$label must contain exactly one catalog-release/rate-card.json.sig"
  fi
  if [[ "$PROVIDER_VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] && \
     { [ "${BASH_REMATCH[1]}" -gt 1 ] || \
       { [ "${BASH_REMATCH[1]}" -eq 1 ] && [ "${BASH_REMATCH[2]}" -gt 8 ]; } || \
       { [ "${BASH_REMATCH[1]}" -eq 1 ] && [ "${BASH_REMATCH[2]}" -eq 8 ] && [ "${BASH_REMATCH[3]}" -ge 33 ]; }; }; then
    [ "$has_compatibility_set" -eq 1 ] || die "$label must contain exactly one compatibility-set.json"
    [ "$has_local_install_contract" -eq 1 ] || die "$label must contain exactly one local install contract"
    [ "$has_local_provider_plist" -eq 1 ] || die "$label must contain exactly one provider launchd template"
    [ "$has_local_updater_metadata" -eq 1 ] || die "$label must contain exactly one updater rollback metadata file"
    [ "$has_local_watchdog_plist" -eq 1 ] || die "$label must contain exactly one watchdog launchd template"
    [ "$has_local_watchdog_script" -eq 1 ] || die "$label must contain exactly one watchdog script"
  fi
  if find "$payload_dir" \( -type l -o -type b -o -type c -o -type p \) -print -quit | grep -q .; then
    die "$label contains unsafe link or device members"
  fi
}

validate_malibu_app_zip() {
  local zip_path="$1"
  python3 - "$zip_path" <<'PY'
import stat
import sys
import zipfile

zip_path = sys.argv[1]
required = {
    "Malibu.app/Contents/MacOS/Malibu",
    "Malibu.app/Contents/MacOS/malibu-cli",
}
has_metal = False
seen = set()

try:
    with zipfile.ZipFile(zip_path) as archive:
        infos = archive.infolist()
        if not infos:
            raise SystemExit("Malibu.app zip is empty")
        for info in infos:
            name = info.filename
            if name.startswith("/") or "/../" in name or name.startswith("../") or name.endswith("/..") or name == "..":
                raise SystemExit(f"unsafe Malibu.app zip path: {name}")
            if name != "Malibu.app/" and not name.startswith("Malibu.app/"):
                raise SystemExit(f"unexpected Malibu.app zip member: {name}")
            mode = (info.external_attr >> 16) & 0o170000
            if mode in (stat.S_IFLNK, stat.S_IFBLK, stat.S_IFCHR, stat.S_IFIFO):
                raise SystemExit(f"unsafe Malibu.app zip member type: {name}")
            seen.add(name.rstrip("/"))
            if name.rstrip("/") == "Malibu.app/Contents/MacOS/mlx.metallib":
                has_metal = True
            if name.rstrip("/") == "Malibu.app/Contents/MacOS/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib":
                has_metal = True
except zipfile.BadZipFile:
    raise SystemExit("Malibu.app asset is not a valid zip archive")

missing = sorted(required - seen)
if missing:
    raise SystemExit("Malibu.app zip missing required member: " + ", ".join(missing))
if not has_metal:
    raise SystemExit("Malibu.app zip lacks adjacent MLX Metal resources")
PY
}

tmpdir=""
temp_parent=""
app_mount_dir=""
cleanup() {
  if [ -n "$app_mount_dir" ] && [ -d "$app_mount_dir" ]; then
    "$HDIUTIL_BIN" detach "$app_mount_dir" -quiet >/dev/null 2>&1 || true
  fi
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
require_command find
require_command tar
require_file "$INSTALL_SH"
require_file "$CHECKER"

case "$DOWNLOAD_ATTEMPTS" in
  ''|*[!0-9]*) die "DOWNLOAD_ATTEMPTS must be a positive integer" ;;
esac
[ "$DOWNLOAD_ATTEMPTS" -ge 1 ] || die "DOWNLOAD_ATTEMPTS must be >= 1"
case "$DOWNLOAD_RETRY_SLEEP" in
  ''|*[!0-9]*) die "DOWNLOAD_RETRY_SLEEP must be a non-negative integer" ;;
esac
case "$PROVIDER_RUNTIME_MODE" in
  execute) ;;
  structural)
    [ -n "$PROVIDER_EXPECTED_ARCHES" ] || {
      die "structural mode requires PROVIDER_EXPECTED_ARCHES"
    }
    ;;
  *) die "PROVIDER_RUNTIME_MODE must be execute or structural" ;;
esac
if [ -n "$PROVIDER_EXPECTED_ARCHES" ]; then
  case "$PROVIDER_LIPO_BIN" in
    /*) ;;
    *) die "PROVIDER_LIPO_BIN must be an absolute path when architecture validation is required" ;;
  esac
  [ -f "$PROVIDER_LIPO_BIN" ] && [ -x "$PROVIDER_LIPO_BIN" ] && [ ! -L "$PROVIDER_LIPO_BIN" ] || {
    die "PROVIDER_LIPO_BIN must be a regular executable and not a symlink"
  }
fi

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

asset="malibu-cli-${RELEASE_TAG}-darwin-arm64.tar.gz"
legacy_asset="macprovider-cli-${RELEASE_TAG}-darwin-arm64.tar.gz"
pkg_asset="malibu-cli-${RELEASE_TAG}-darwin-arm64.pkg"
app_asset="Malibu-${RELEASE_TAG}.dmg"
base="https://github.com/${GITHUB_REPO}/releases/download/${RELEASE_TAG}"

temp_parent="${TMPDIR:-/tmp}"
[ -d "$temp_parent" ] || die "temporary directory parent does not exist: $temp_parent"
temp_parent="$(cd "$temp_parent" && pwd -P)"
tmpdir="$(mktemp -d "$temp_parent/tier2-provider-release.XXXXXX")"

tarball_path="$tmpdir/$asset"
legacy_tarball_path="$tmpdir/$legacy_asset"
pkg_path="$tmpdir/$pkg_asset"
app_dmg_path="$tmpdir/$app_asset"
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

canonical_payload_dir="$tmpdir/canonical-provider-payload"
mkdir -p "$canonical_payload_dir"
tar -xzf "$tarball_path" -C "$canonical_payload_dir" malibu-cli || die "provider tarball lacks malibu-cli"
canonical_binary_sha="$(sha256_file "$canonical_payload_dir/malibu-cli")"

legacy_expected_sha="$(checksum_for_asset "$checksums_path" "$legacy_asset")"
if [ -n "$legacy_expected_sha" ]; then
  legacy_payload_dir="$tmpdir/legacy-provider-payload"
  mkdir -p "$legacy_payload_dir"
  download_file "$base/$legacy_asset" "$legacy_tarball_path" "$legacy_asset"
  legacy_actual_sha="$(sha256_file "$legacy_tarball_path")"
  [ "$legacy_actual_sha" = "$legacy_expected_sha" ] || die "legacy provider bridge sha256 mismatch: got $legacy_actual_sha want $legacy_expected_sha"
  log "legacy provider bridge sha256 verified: $legacy_actual_sha"
  tar -xzf "$legacy_tarball_path" -C "$legacy_payload_dir" macprovider-cli || die "legacy provider bridge lacks macprovider-cli"
  [ -x "$legacy_payload_dir/macprovider-cli" ] || die "legacy provider bridge macprovider-cli is not executable"
  legacy_binary_sha="$(sha256_file "$legacy_payload_dir/macprovider-cli")"
  [ "$legacy_binary_sha" = "$canonical_binary_sha" ] ||
    die "legacy provider bridge binary sha256 differs from canonical tarball binary"
  log "legacy provider bridge binary matches canonical tarball binary: $legacy_binary_sha"
else
  log "no legacy macprovider-cli bridge entry in checksums.txt"
fi

pkg_expected_sha="$(checksum_for_asset "$checksums_path" "$pkg_asset")"
if [ -n "$pkg_expected_sha" ]; then
  download_file "$base/$pkg_asset" "$pkg_path" "$pkg_asset"
  pkg_actual_sha="$(sha256_file "$pkg_path")"
  [ "$pkg_actual_sha" = "$pkg_expected_sha" ] || die "provider package sha256 mismatch: got $pkg_actual_sha want $pkg_expected_sha"
  log "provider package sha256 verified: $pkg_actual_sha"
  if command -v spctl >/dev/null 2>&1; then
    spctl -a -vv -t install "$pkg_path" || die "provider package failed Gatekeeper assessment"
    log "provider package Gatekeeper assessment passed"
  fi
  if command -v xcrun >/dev/null 2>&1; then
    xcrun stapler validate "$pkg_path" || die "provider package stapler validation failed"
    log "provider package stapler validation passed"
  fi

  require_command pkgutil
  tar_payload_dir="$tmpdir/tar-payload"
  pkg_expand_dir="$tmpdir/pkg-expanded"
  pkg_payload_tar="$tmpdir/pkg-payload.tar.gz"
  mkdir -p "$tar_payload_dir"
  cp "$canonical_payload_dir/malibu-cli" "$tar_payload_dir/malibu-cli"
  pkgutil --expand-full "$pkg_path" "$pkg_expand_dir" || die "failed to expand provider package"
  [ -x "$pkg_expand_dir/Payload/malibu-cli" ] || die "provider package payload lacks executable malibu-cli"
  validate_payload_entries "$pkg_expand_dir/Payload" "provider package payload"

  tar_binary_sha="$(sha256_file "$tar_payload_dir/malibu-cli")"
  pkg_binary_sha="$(sha256_file "$pkg_expand_dir/Payload/malibu-cli")"
  [ "$pkg_binary_sha" = "$tar_binary_sha" ] || die "package binary sha256 differs from tarball binary"
  log "provider package binary matches tarball binary: $pkg_binary_sha"

  if [ "$PROVIDER_RUNTIME_MODE" = execute ]; then
    pkg_version="$("$pkg_expand_dir/Payload/malibu-cli" --version)"
    [ "$pkg_version" = "$PROVIDER_VERSION" ] || die "provider package version mismatch: got $pkg_version want $PROVIDER_VERSION"
    log "provider package version ok: $pkg_version"
  else
    pkg_arches="$("$PROVIDER_LIPO_BIN" -archs "$pkg_expand_dir/Payload/malibu-cli")"
    [ "$pkg_arches" = "$PROVIDER_EXPECTED_ARCHES" ] || {
      die "provider package architecture mismatch: got $pkg_arches want $PROVIDER_EXPECTED_ARCHES"
    }
    log "provider package architecture ok: $pkg_arches"
    log "provider package runtime execution deferred to an architecture-compatible verifier"
  fi

  tar czf "$pkg_payload_tar" -C "$pkg_expand_dir/Payload" .
  PROVIDER_ARTIFACT="$pkg_payload_tar" \
    PROVIDER_VERSION="$PROVIDER_VERSION" \
    PROVIDER_SHA256="" \
    PROVIDER_RUNTIME_MODE="$PROVIDER_RUNTIME_MODE" \
    PROVIDER_EXPECTED_ARCHES="$PROVIDER_EXPECTED_ARCHES" \
    PROVIDER_LIPO_BIN="$PROVIDER_LIPO_BIN" \
    "$CHECKER"
else
  log "no package entry in checksums.txt; tarball-only compatibility release"
fi

app_expected_sha="$(checksum_for_asset "$checksums_path" "$app_asset")"
if [ -n "$app_expected_sha" ]; then
  download_file "$base/$app_asset" "$app_dmg_path" "$app_asset"
  app_actual_sha="$(sha256_file "$app_dmg_path")"
  [ "$app_actual_sha" = "$app_expected_sha" ] || die "Malibu.app DMG sha256 mismatch: got $app_actual_sha want $app_expected_sha"
  log "Malibu.app DMG sha256 verified: $app_actual_sha"

  require_command "$HDIUTIL_BIN"
  require_command codesign
  require_command spctl
  require_command xcrun
  app_mount_dir="$tmpdir/malibu-dmg"
  mkdir -p "$app_mount_dir"
  "$HDIUTIL_BIN" attach -nobrowse -mountpoint "$app_mount_dir" "$app_dmg_path" >/dev/null ||
    die "failed to mount $app_asset"
  app_path="$app_mount_dir/Malibu.app"
  [ -d "$app_path" ] || die "$app_asset does not contain Malibu.app"
  [ -x "$app_path/Contents/MacOS/malibu-cli" ] || die "Malibu.app lacks executable bundled malibu-cli"
  app_tar_payload_dir="$tmpdir/app-tar-payload"
  mkdir -p "$app_tar_payload_dir"
  cp "$canonical_payload_dir/malibu-cli" "$app_tar_payload_dir/malibu-cli"
  app_tar_binary_sha="$(sha256_file "$app_tar_payload_dir/malibu-cli")"
  app_binary_sha="$(sha256_file "$app_path/Contents/MacOS/malibu-cli")"
  [ "$app_binary_sha" = "$app_tar_binary_sha" ] ||
    die "Malibu.app bundled binary sha256 differs from tarball binary"
  log "Malibu.app bundled binary matches tarball binary: $app_binary_sha"
  if [ ! -f "$app_path/Contents/MacOS/mlx.metallib" ] && \
     [ ! -f "$app_path/Contents/MacOS/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" ]; then
    die "Malibu.app lacks adjacent MLX Metal resources for bundled malibu-cli"
  fi
  codesign --verify --strict --deep --verbose=2 "$app_path" || die "Malibu.app code signature verification failed"
  log "Malibu.app code signature verified"
  xcrun stapler validate "$app_dmg_path" || die "Malibu.app DMG stapler validation failed"
  log "Malibu.app DMG stapler validation passed"
  spctl -a -vvv -t open "$app_dmg_path" || spctl -a -vvv -t exec "$app_path" || die "Malibu.app failed Gatekeeper assessment"
  log "Malibu.app Gatekeeper assessment passed"
  "$HDIUTIL_BIN" detach "$app_mount_dir" -quiet >/dev/null 2>&1 || true
  app_mount_dir=""
else
  log "no Malibu.app DMG entry in checksums.txt; app-track release absent"
fi

PROVIDER_ARTIFACT="$tarball_path" \
  PROVIDER_VERSION="$PROVIDER_VERSION" \
  PROVIDER_SHA256="$expected_sha" \
  PROVIDER_RUNTIME_MODE="$PROVIDER_RUNTIME_MODE" \
  PROVIDER_EXPECTED_ARCHES="$PROVIDER_EXPECTED_ARCHES" \
  PROVIDER_LIPO_BIN="$PROVIDER_LIPO_BIN" \
  "$CHECKER"

if [ "$KEEP_DOWNLOADS" = "1" ]; then
  log "kept downloaded release assets at $tmpdir"
fi
log "SPEC-008 B6 provider GitHub Release verifier passed for $RELEASE_TAG"
