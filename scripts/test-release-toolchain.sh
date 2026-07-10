#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
validator="$root/scripts/validate-release-toolchain.py"
work="$(mktemp -d "${TMPDIR:-/tmp}/release-toolchain-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

write_fixture() {
  printf '%s\n' 'Xcode 16.4' 'Build version 16F6' >"$work/xcode.txt"
  printf '%s\n' \
    'swift-driver version: 1.120.5 Apple Swift version 6.1.2 (swiftlang-6.1.2.1.2 clang-1700.0.13.5)' \
    'Target: arm64-apple-macosx15.0' >"$work/swiftc.txt"
  printf '%s\n' '15.5' >"$work/sdk-version.txt"
  printf '%s\n' \
    '/Applications/Xcode_16.4.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX15.5.sdk' \
    >"$work/sdk-path.txt"
}

validate() {
  python3 "$validator" \
    /Applications/Xcode_16.4.app/Contents/Developer \
    "$work/xcode.txt" "$work/swiftc.txt" "$work/sdk-version.txt" "$work/sdk-path.txt" \
    "$work/toolchain.json"
}

write_fixture
validate
python3 - "$work/toolchain.json" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert value["xcode"] == {
    "build": "16F6",
    "developer_dir": "/Applications/Xcode_16.4.app/Contents/Developer",
    "version": "16.4",
}
assert value["swift"]["driver_version"] == "1.120.5"
assert value["macos_sdk"]["version"] == "15.5"
PY

for field in xcode swift-driver swiftc sdk-version sdk-path; do
  write_fixture
  case "$field" in
    xcode) sed 's/16F6/16F7/' "$work/xcode.txt" >"$work/x" && mv "$work/x" "$work/xcode.txt" ;;
    swift-driver) sed 's/1\.120\.5/1.120.6/' "$work/swiftc.txt" >"$work/x" && mv "$work/x" "$work/swiftc.txt" ;;
    swiftc) sed 's/6\.1\.2/6.1.3/' "$work/swiftc.txt" >"$work/x" && mv "$work/x" "$work/swiftc.txt" ;;
    sdk-version) printf '%s\n' '15.6' >"$work/sdk-version.txt" ;;
    sdk-path) sed 's/MacOSX15\.5/MacOSX15.6/' "$work/sdk-path.txt" >"$work/x" && mv "$work/x" "$work/sdk-path.txt" ;;
  esac
  if validate >"$work/$field.out" 2>&1; then
    echo "toolchain validator accepted $field drift" >&2
    exit 1
  fi
done

echo "release toolchain drift regression checks passed"
