#!/usr/bin/env bash
# Post-release Gatekeeper checks for signed Malibu artifacts (SPEC-025 P2).
#
# Usage:
#   bash scripts/verify-malibu-release-artifacts.sh Malibu-v1.8.11.dmg --provider-tarball malibu-cli-v1.8.11-darwin-arm64.tar.gz
#   bash scripts/verify-malibu-release-artifacts.sh /Applications/Malibu.app --expected-cli-sha256 <sha256>
#   bash scripts/verify-malibu-release-artifacts.sh Malibu-v1.8.39.dmg --legacy-app-only-no-provider-tarball
#
# Validates codesign, stapler, spctl, and an explicit embedded CLI identity
# proof against either the standalone provider tarball or an expected digest.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
trust_anchor_helper="$repo_root/scripts/prepare-malibu-bootstrap-trust-anchor.py"
legacy_sparkle_key="$repo_root/scripts/dist/malibu-v1.8.32-sparkle-public-key"

die() {
  printf '[verify-malibu-release] ERROR: %s\n' "$*" >&2
  exit 1
}

[ $# -ge 2 ] || die "usage: $0 <Malibu.app path or Malibu-*.dmg> (--provider-tarball <tar.gz> | --expected-cli-sha256 <sha256> | --legacy-app-only-no-provider-tarball)"

target="$1"
shift
provider_tarball=""
expected_cli_sha256=""
legacy_app_only=0
[ -e "$target" ] || die "missing: $target"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --provider-tarball)
      [ -z "$provider_tarball" ] || die "--provider-tarball specified more than once"
      [ "$#" -ge 2 ] || die "--provider-tarball requires a path"
      provider_tarball="$2"
      shift 2
      ;;
    --expected-cli-sha256)
      [ -z "$expected_cli_sha256" ] || die "--expected-cli-sha256 specified more than once"
      [ "$#" -ge 2 ] || die "--expected-cli-sha256 requires a digest"
      expected_cli_sha256="$2"
      shift 2
      ;;
    --legacy-app-only-no-provider-tarball)
      [ "$legacy_app_only" -eq 0 ] || die "--legacy-app-only-no-provider-tarball specified more than once"
      legacy_app_only=1
      shift
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

identity_mode_count=0
[ -n "$provider_tarball" ] && identity_mode_count=$((identity_mode_count + 1))
[ -n "$expected_cli_sha256" ] && identity_mode_count=$((identity_mode_count + 1))
[ "$legacy_app_only" -eq 1 ] && identity_mode_count=$((identity_mode_count + 1))
[ "$identity_mode_count" -eq 1 ] ||
  die "choose exactly one CLI identity mode: --provider-tarball, --expected-cli-sha256, or --legacy-app-only-no-provider-tarball"
[ -z "$provider_tarball" ] || [ -f "$provider_tarball" ] || die "missing provider tarball: $provider_tarball"
if [ -n "$expected_cli_sha256" ] && ! printf '%s\n' "$expected_cli_sha256" | grep -Eq '^[0-9a-fA-F]{64}$'; then
  die "--expected-cli-sha256 must be a 64-character hex digest"
fi

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

verify_embedded_cli_identity() {
  local app_path="$1"
  local expected_sha="$expected_cli_sha256"
  local extract_dir
  local embedded_cli_sha

  [ -x "$app_path/Contents/MacOS/malibu-cli" ] ||
    die "Malibu.app lacks executable bundled malibu-cli"
  embedded_cli_sha="$(sha256_file "$app_path/Contents/MacOS/malibu-cli")"

  if [ "$legacy_app_only" -eq 1 ]; then
    printf '[verify-malibu-release] warning: legacy app-only verification skipped standalone CLI byte identity\n' >&2
    return 0
  fi

  bash "$repo_root/scripts/require-cli-se-entitlements.sh" \
    "$app_path/Contents/MacOS/malibu-cli"

  if [ -n "$provider_tarball" ]; then
    extract_dir="$(mktemp -d "${TMPDIR:-/tmp}/malibu-provider-cli.XXXXXX")"
    tar -xzf "$provider_tarball" -C "$extract_dir" malibu-cli ||
      die "provider tarball does not contain malibu-cli"
    [ -x "$extract_dir/malibu-cli" ] ||
      die "provider tarball malibu-cli is not executable"
    bash "$repo_root/scripts/require-cli-se-entitlements.sh" "$extract_dir/malibu-cli"
    expected_sha="$(sha256_file "$extract_dir/malibu-cli")"
    rm -rf "$extract_dir"
  fi

  [ -n "$expected_sha" ] || die "missing expected CLI sha256"

  [ "$embedded_cli_sha" = "$expected_sha" ] ||
    die "Malibu embedded CLI sha256 differs from expected CLI: embedded=$embedded_cli_sha expected=$expected_sha"
}

verify_update_posture() {
  local app_path="$1"
  local malibu_links

  python3 "$trust_anchor_helper" verify "$app_path" "$legacy_sparkle_key"
  verify_embedded_cli_identity "$app_path"
  malibu_links="$(/usr/bin/otool -L "$app_path/Contents/MacOS/Malibu")" ||
    die "could not inspect Malibu runtime linkage"
  if printf '%s\n' "$malibu_links" | /usr/bin/grep -F Sparkle >/dev/null; then
    die "Malibu must not link a Sparkle runtime"
  fi
}

case "$target" in
  *.dmg)
    mount_dir="$(mktemp -d "${TMPDIR:-/tmp}/malibu-dmg.XXXXXX")"
    cleanup() {
      hdiutil detach "$mount_dir" -quiet >/dev/null 2>&1 || true
      rm -rf "$mount_dir"
    }
    trap cleanup EXIT
    hdiutil attach -nobrowse -mountpoint "$mount_dir" "$target" >/dev/null
    app_path="$mount_dir/Malibu.app"
    [ -d "$app_path" ] || die "Malibu.app not found inside $target"
    codesign --verify --strict --deep --verbose=2 "$app_path"
    verify_update_posture "$app_path"
    xcrun stapler validate "$target"
    spctl -a -vvv -t open "$target" || spctl -a -vvv -t exec "$app_path"
    ;;
  *.app)
    codesign --verify --strict --deep --verbose=2 "$target"
    verify_update_posture "$target"
    xcrun stapler validate "$target"
    spctl -a -vvv -t exec "$target"
    ;;
  *)
    die "expected .app bundle or .dmg, got: $target"
    ;;
esac

printf '[verify-malibu-release] ok: %s\n' "$target"
