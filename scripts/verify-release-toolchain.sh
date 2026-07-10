#!/usr/bin/env bash
set -euo pipefail

die() {
  printf '[verify-release-toolchain] ERROR: %s\n' "$*" >&2
  exit 1
}

[[ "$#" == 1 ]] || die "usage: $0 OUTPUT_JSON"
output="$1"
readonly expected_developer_dir="/Applications/Xcode_16.4.app/Contents/Developer"
script_dir="$(cd "$(dirname "$0")" && pwd)"
readonly script_dir

[[ -d "$expected_developer_dir" ]] || die "reviewed Xcode app is unavailable: $expected_developer_dir"
developer_dir="$(xcode-select -p)"
[[ "$developer_dir" == "$expected_developer_dir" ]] ||
  die "selected Xcode differs from the reviewed app: $developer_dir"

work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/release-toolchain.XXXXXX")"
trap 'rm -rf "$work"' EXIT
xcodebuild -version >"$work/xcode-version.txt"
swiftc --version >"$work/swiftc-version.txt"
xcrun --sdk macosx --show-sdk-version >"$work/sdk-version.txt"
xcrun --sdk macosx --show-sdk-path >"$work/sdk-path.txt"

python3 "$script_dir/validate-release-toolchain.py" \
  "$developer_dir" \
  "$work/xcode-version.txt" \
  "$work/swiftc-version.txt" \
  "$work/sdk-version.txt" \
  "$work/sdk-path.txt" \
  "$output"

printf '[verify-release-toolchain] ok: Xcode 16.4 (16F6), Swift 6.1.2, macOS SDK 15.5\n'
