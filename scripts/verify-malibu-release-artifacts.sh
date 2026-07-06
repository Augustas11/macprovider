#!/usr/bin/env bash
# Post-release Gatekeeper checks for signed Malibu artifacts (SPEC-025 P2).
#
# Usage:
#   bash scripts/verify-malibu-release-artifacts.sh Malibu-v1.8.11.dmg
#   bash scripts/verify-malibu-release-artifacts.sh /Applications/Malibu.app
#
# Validates codesign, stapler, and spctl on a locally downloaded release asset.

set -euo pipefail

die() {
  printf '[verify-malibu-release] ERROR: %s\n' "$*" >&2
  exit 1
}

[ $# -eq 1 ] || die "usage: $0 <Malibu.app path or Malibu-*.dmg>"

target="$1"
[ -e "$target" ] || die "missing: $target"

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
    xcrun stapler validate "$target"
    spctl -a -vvv -t open "$target" || spctl -a -vvv -t exec "$app_path"
    ;;
  *.app)
    codesign --verify --strict --deep --verbose=2 "$target"
    xcrun stapler validate "$target"
    spctl -a -vvv -t exec "$target"
    ;;
  *)
    die "expected .app bundle or .dmg, got: $target"
    ;;
esac

printf '[verify-malibu-release] ok: %s\n' "$target"
