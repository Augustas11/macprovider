#!/usr/bin/env bash
# Render Malibu.app AppIcon PNGs from the SVG source using qlmanage.
# Pure macOS, no external deps (no rsvg-convert, no ImageMagick).
#
# Re-run whenever Resources/Brand/malibu-icon.svg changes. The generated
# PNGs are committed under Resources/Assets.xcassets/AppIcon.appiconset/
# so that xcodebuild does not need this script at build time.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../Sources/Malibu/Resources/Brand/malibu-icon.svg"
DEST="$HERE/../Sources/Malibu/Resources/Assets.xcassets/AppIcon.appiconset"

test -f "$SRC" || { echo "missing $SRC" >&2; exit 1; }
mkdir -p "$DEST"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# macOS AppIcon requires PNGs at these pixel sizes (10 files total).
# qlmanage outputs to <name>.png in the given directory — we rename.
render() {
  local pixels="$1" outname="$2"
  qlmanage -t -s "$pixels" -o "$TMP" "$SRC" >/dev/null 2>&1
  mv "$TMP/malibu-icon.svg.png" "$DEST/$outname"
}

render   16 icon_16x16.png
render   32 icon_16x16@2x.png
render   32 icon_32x32.png
render   64 icon_32x32@2x.png
render  128 icon_128x128.png
render  256 icon_128x128@2x.png
render  256 icon_256x256.png
render  512 icon_256x256@2x.png
render  512 icon_512x512.png
render 1024 icon_512x512@2x.png

echo "wrote 10 icons to $DEST"
