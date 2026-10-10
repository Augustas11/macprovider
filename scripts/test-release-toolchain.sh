#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
validator="$root/scripts/validate-release-toolchain.py"
work="$(mktemp -d "${TMPDIR:-/tmp}/release-toolchain-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# Build profile: Xcode 26.6 (17F113), Swift 6.3.3, macOS SDK 26.5.
build_dir=/Applications/Xcode_26.6.app/Contents/Developer
# Signer profile: the protected macos-15-intel signer, Xcode 16.4 (16F6).
signer_dir=/Applications/Xcode_16.4.app/Contents/Developer

write_build_fixture() {
  printf '%s\n' 'Xcode 26.6' 'Build version 17F113' >"$work/xcode.txt"
  printf '%s\n' 'swift-driver version: 1.148.6 ' >"$work/swift-driver.txt"
  printf '%s\n' \
    'Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)' \
    'Target: x86_64-apple-macosx26.0' >"$work/swiftc.txt"
  printf '%s\n' '26.5' >"$work/sdk-version.txt"
  printf '%s\n' \
    "$build_dir/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk" \
    >"$work/sdk-path.txt"
}

write_signer_fixture() {
  printf '%s\n' 'Xcode 16.4' 'Build version 16F6' >"$work/xcode.txt"
  printf '%s\n' 'swift-driver version: 1.120.5' >"$work/swift-driver.txt"
  printf '%s\n' \
    'Apple Swift version 6.1.2 (swiftlang-6.1.2.1.2 clang-1700.0.13.5)' \
    'Target: x86_64-apple-macosx15.0' >"$work/swiftc.txt"
  printf '%s\n' '15.5' >"$work/sdk-version.txt"
  printf '%s\n' \
    "$signer_dir/Platforms/MacOSX.platform/Developer/SDKs/MacOSX15.5.sdk" \
    >"$work/sdk-path.txt"
}

validate() {
  # Arguments: [--signer] DEVELOPER_DIR
  python3 "$validator" "$@" \
    "$work/xcode.txt" "$work/swift-driver.txt" "$work/swiftc.txt" \
    "$work/sdk-version.txt" "$work/sdk-path.txt" \
    "$work/toolchain.json"
}

write_build_fixture
validate "$build_dir"
python3 - "$work/toolchain.json" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert value["xcode"] == {
    "build": "17F113",
    "developer_dir": "/Applications/Xcode_26.6.app/Contents/Developer",
    "version": "26.6",
}
assert value["swift"]["driver_version"] == "1.148.6"
assert value["swift"]["version"] == (
    "Apple Swift version 6.3.3 "
    "(swiftlang-6.3.3.1.3 clang-2100.1.1.101)"
)
assert value["macos_sdk"]["version"] == "26.5"
PY

write_signer_fixture
validate --signer "$signer_dir"
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
assert value["swift"]["version"].startswith("Apple Swift version 6.1.2 ")
assert value["macos_sdk"]["version"] == "15.5"
PY

# Profiles must not cross: a Swift 6.1 toolchain cannot pass as the build
# toolchain, and the build toolchain cannot pass as the signer.
write_signer_fixture
if validate "$signer_dir" >"$work/cross-build.out" 2>&1; then
  echo "build profile accepted the signer Xcode 16.4 toolchain" >&2
  exit 1
fi
write_build_fixture
if validate --signer "$build_dir" >"$work/cross-signer.out" 2>&1; then
  echo "signer profile accepted the build Xcode 26.6 toolchain" >&2
  exit 1
fi
write_build_fixture
if validate /Applications/Xcode.app/Contents/Developer >"$work/floating.out" 2>&1; then
  echo "build profile accepted the floating Xcode.app path" >&2
  exit 1
fi

for field in xcode swift-driver swiftc sdk-version sdk-path; do
  write_build_fixture
  case "$field" in
    xcode) sed 's/17F113/17F114/' "$work/xcode.txt" >"$work/x" && mv "$work/x" "$work/xcode.txt" ;;
    swift-driver)
      printf '%s\n' 'swift-driver version: 1.148.7' >"$work/swift-driver.txt"
      ;;
    swiftc) sed 's/6\.3\.3/6.3.4/' "$work/swiftc.txt" >"$work/x" && mv "$work/x" "$work/swiftc.txt" ;;
    sdk-version) printf '%s\n' '26.4' >"$work/sdk-version.txt" ;;
    sdk-path) sed 's/MacOSX26\.5/MacOSX26.4/' "$work/sdk-path.txt" >"$work/x" && mv "$work/x" "$work/sdk-path.txt" ;;
  esac
  if validate "$build_dir" >"$work/$field.out" 2>&1; then
    echo "toolchain validator accepted $field drift" >&2
    exit 1
  fi
done

for field in xcode swift-driver swiftc sdk-version sdk-path; do
  write_signer_fixture
  case "$field" in
    xcode) sed 's/16F6/16F7/' "$work/xcode.txt" >"$work/x" && mv "$work/x" "$work/xcode.txt" ;;
    swift-driver)
      printf '%s\n' 'swift-driver version: 1.120.6' >"$work/swift-driver.txt"
      ;;
    swiftc) sed 's/6\.1\.2/6.1.3/' "$work/swiftc.txt" >"$work/x" && mv "$work/x" "$work/swiftc.txt" ;;
    sdk-version) printf '%s\n' '15.6' >"$work/sdk-version.txt" ;;
    sdk-path) sed 's/MacOSX15\.5/MacOSX15.6/' "$work/sdk-path.txt" >"$work/x" && mv "$work/x" "$work/sdk-path.txt" ;;
  esac
  if validate --signer "$signer_dir" >"$work/signer-$field.out" 2>&1; then
    echo "signer toolchain validator accepted $field drift" >&2
    exit 1
  fi
done

echo "release toolchain drift regression checks passed"
