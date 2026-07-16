#!/usr/bin/env bash
# Post-release Gatekeeper checks for signed Malibu artifacts (SPEC-025 P2).
#
# Usage:
#   bash scripts/verify-malibu-release-artifacts.sh Malibu-v1.8.11.dmg
#   bash scripts/verify-malibu-release-artifacts.sh /Applications/Malibu.app
#
# Validates codesign, stapler, and spctl on a locally downloaded release asset.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
trust_anchor_helper="$repo_root/scripts/prepare-malibu-bootstrap-trust-anchor.py"
legacy_sparkle_key="$repo_root/scripts/dist/malibu-v1.8.32-sparkle-public-key"

die() {
  printf '[verify-malibu-release] ERROR: %s\n' "$*" >&2
  exit 1
}

[ $# -eq 1 ] || die "usage: $0 <Malibu.app path or Malibu-*.dmg>"

target="$1"
[ -e "$target" ] || die "missing: $target"

verify_update_posture() {
  local app_path="$1"
  local malibu_links

  python3 "$trust_anchor_helper" verify "$app_path" "$legacy_sparkle_key"
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
