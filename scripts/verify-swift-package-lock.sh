#!/usr/bin/env bash
# Fail closed if phase3-binary/Package.resolved is incomplete under the
# pinned release toolchain (Xcode 16.4). This is the same lock flag the
# candidate/release path uses (`-onlyUsePackageVersionsFromResolvedFile`).
# Newer local toolchains (Xcode 26.x) resolve a different graph and cannot
# reproduce this check — refuse to run unless 16.4 is selected.
#
# See issue #1360 (async-http-client unpinned after #1336).
set -euo pipefail

readonly expected_developer_dir="/Applications/Xcode_16.4.app/Contents/Developer"

die() {
  printf '[verify-swift-package-lock] ERROR: %s\n' "$*" >&2
  exit 1
}

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
package_dir="$repo_root/phase3-binary"
[[ -f "$package_dir/Package.resolved" ]] || die "phase3-binary/Package.resolved is missing"
[[ -d "$expected_developer_dir" ]] || die "reviewed Xcode app is unavailable: $expected_developer_dir"

developer_dir="$(xcode-select -p)"
[[ "$developer_dir" == "$expected_developer_dir" ]] ||
  die "selected Xcode differs from the reviewed app: $developer_dir (need $expected_developer_dir)"

cd "$package_dir"
work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/swift-package-lock.XXXXXX")"
trap 'rm -rf "$work"' EXIT
cp Package.resolved "$work/Package.resolved.before"

xcodebuild -version
xcodebuild \
  -resolvePackageDependencies \
  -scheme macprovider-cli \
  -configuration Release \
  -onlyUsePackageVersionsFromResolvedFile

cmp -s "$work/Package.resolved.before" Package.resolved ||
  die "locked resolve mutated Package.resolved; regenerate it under Xcode 16.4"

printf '[verify-swift-package-lock] ok: locked SwiftPM resolve succeeded under Xcode 16.4\n'
