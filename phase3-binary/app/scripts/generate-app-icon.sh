#!/usr/bin/env bash
# Render Malibu.app AppIcon PNGs and the exported SVG from the shared brand
# geometry in Sources/Malibu/MenuBar/BrandMark.swift. Pure macOS (swiftc,
# CoreGraphics), no external deps.
#
# Re-run whenever MalibuConstructionSunburstGeometry changes. The generated
# PNGs (at the pixel sizes listed in AppIcon.appiconset/Contents.json) and
# Resources/Brand/malibu-icon.svg are committed so that xcodebuild does not
# need this script at build time.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GEOMETRY="$HERE/../Sources/Malibu/MenuBar/BrandMark.swift"
DEST="$HERE/../Sources/Malibu/Resources/Assets.xcassets/AppIcon.appiconset"
SVG="$HERE/../Sources/Malibu/Resources/Brand/malibu-icon.svg"

test -f "$GEOMETRY" || { echo "missing $GEOMETRY" >&2; exit 1; }
test -f "$DEST/Contents.json" || { echo "missing $DEST/Contents.json" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

swiftc -O "$GEOMETRY" "$HERE/app-icon/main.swift" -o "$TMP/app-icon"
"$TMP/app-icon" "$DEST" "$SVG"
