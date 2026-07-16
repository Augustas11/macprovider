#!/usr/bin/env bash
# Exercise Sparkle 2.6.4's real SUUpdateValidator with ephemeral Ed25519 DMGs.

set -euo pipefail

[[ "$(uname -s)" == Darwin ]] || {
  echo "SKIP: Sparkle SUUpdateValidator integration requires macOS"
  exit 0
}

sparkle_commit="0ef1ee0220239b3776f433314515fd849025673f"
sparkle_remote="https://github.com/sparkle-project/Sparkle.git"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
patch_file="$root/scripts/fixtures/SUUpdateValidator-2.6.4-ephemeral.patch"
[[ -f "$patch_file" && ! -L "$patch_file" ]] || {
  echo "missing validator test patch: $patch_file" >&2
  exit 1
}

work="$(mktemp -d "${TMPDIR:-/tmp}/sparkle-validator-2.6.4.XXXXXX")"
cleanup() {
  rm -rf "$work"
}
trap cleanup EXIT

source_root="$work/Sparkle"
git -c init.defaultBranch=detached init -q "$source_root"
git -C "$source_root" remote add origin "$sparkle_remote"
GIT_TERMINAL_PROMPT=0 git -C "$source_root" fetch -q --depth 1 \
  origin "$sparkle_commit"
git -C "$source_root" checkout -q --detach FETCH_HEAD
actual_commit="$(git -C "$source_root" rev-parse HEAD)"
[[ "$actual_commit" == "$sparkle_commit" ]] || {
  echo "Sparkle source pin mismatch: $actual_commit" >&2
  exit 1
}

git -C "$source_root" apply --check "$patch_file"
git -C "$source_root" apply "$patch_file"

arch="$(uname -m)"
xcode_log="$work/xcodebuild.log"
if ! xcodebuild test -quiet \
  -project "$source_root/Sparkle.xcodeproj" \
  -scheme Sparkle \
  -configuration Debug \
  -destination "platform=macOS,arch=$arch" \
  -derivedDataPath "$work/DerivedData" \
  -clonedSourcePackagesDirPath "$work/SourcePackages" \
  -only-testing:'Sparkle Unit Tests/SUUpdateValidatorTest/testEphemeralEdDSAKeyContinuityForApplicationUpdate' \
  CODE_SIGNING_ALLOWED=NO >"$xcode_log" 2>&1; then
  tail -n 200 "$xcode_log" >&2
  exit 1
fi

echo "Sparkle 2.6.4 SUUpdateValidator ephemeral key-continuity integration passed"
