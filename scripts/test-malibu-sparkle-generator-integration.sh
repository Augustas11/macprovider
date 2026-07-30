#!/usr/bin/env bash
# Prove pinned Sparkle 2.6.4 signs an anchored v1.8.39 target DMG end to end.

set -euo pipefail

[[ "$(uname -s)" == Darwin ]] || {
  echo "SKIP: Sparkle generator integration requires macOS"
  exit 0
}

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/malibu-sparkle-integration.XXXXXX")"
cleanup() {
  rm -rf "$work"
}
trap cleanup EXIT

private_key="$work/private-key"
public_key="$work/public-key"
xcrun swift - "$private_key" "$public_key" <<'SWIFT'
import CryptoKit
import Foundation

guard CommandLine.arguments.count == 3 else {
    exit(2)
}
let key = Curve25519.Signing.PrivateKey()
try key.rawRepresentation.base64EncodedString().write(
    toFile: CommandLine.arguments[1], atomically: true, encoding: .ascii)
try key.publicKey.rawRepresentation.base64EncodedString().write(
    toFile: CommandLine.arguments[2], atomically: true, encoding: .ascii)
SWIFT
chmod 600 "$private_key"

stage="$work/dmg-stage"
app="$stage/Malibu.app"
mkdir -p "$app/Contents/MacOS"
cp /usr/bin/true "$app/Contents/MacOS/Malibu"
chmod 755 "$app/Contents/MacOS/Malibu"
python3 - "$app/Contents/Info.plist" "$public_key" <<'PY'
import pathlib
import plistlib
import sys

public_key = pathlib.Path(sys.argv[2]).read_text(encoding="ascii")
document = {
    "CFBundleExecutable": "Malibu",
    "CFBundleIdentifier": "tech.malibu.app",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": "1.8.39",
    "CFBundleVersion": "39",
    "SUPublicEDKey": public_key,
}
with pathlib.Path(sys.argv[1]).open("wb") as output:
    plistlib.dump(document, output)
PY
codesign --force --deep --sign - "$app"
codesign --verify --strict --deep "$app"

dmg="$work/Malibu-v1.8.39.dmg"
hdiutil create -quiet -volname Malibu -srcfolder "$stage" -ov -format UDZO "$dmg"

# Run the checked-in generator from a disposable repo-shaped root so its fixed
# production output path cannot mutate the working tree.
fixture_root="$work/repo"
mkdir -p "$fixture_root/scripts" "$fixture_root/phase3-binary/app/dist"
cp "$root/scripts/generate-malibu-appcast.sh" "$fixture_root/scripts/"
DMG="$dmg" SPARKLE_PRIVATE_KEY_FILE="$private_key" \
  bash "$fixture_root/scripts/generate-malibu-appcast.sh" v1.8.39 >/dev/null

appcast="$fixture_root/phase3-binary/app/dist/appcast.xml"
signature="$(python3 - "$appcast" "$dmg" <<'PY'
import base64
import pathlib
import sys
import xml.etree.ElementTree as ET

appcast = pathlib.Path(sys.argv[1])
dmg = pathlib.Path(sys.argv[2])
namespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"
root = ET.parse(appcast).getroot()
items = root.findall("./channel/item")
assert len(items) == 1
assert items[0].findtext(f"{{{namespace}}}shortVersionString") == "1.8.39"
assert items[0].findtext(f"{{{namespace}}}version") == "39"
enclosures = items[0].findall("enclosure")
assert len(enclosures) == 1
enclosure = enclosures[0]
assert enclosure.get("url") == "https://download.malibu.tech/Malibu-v1.8.39.dmg"
assert enclosure.get("length") == str(dmg.stat().st_size)
signature = enclosure.get(f"{{{namespace}}}edSignature")
assert signature is not None
assert len(base64.b64decode(signature, validate=True)) == 64
print(signature)
PY
)"

xcrun swift "$root/scripts/verify-ed25519-signature.swift" \
  "$(cat "$public_key")" "$signature" "$dmg"

echo "Malibu Sparkle generator integration passed"
