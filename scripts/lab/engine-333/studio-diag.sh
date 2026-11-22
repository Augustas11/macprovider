#!/usr/bin/env bash
# Engine-333 Studio diagnostics (studio-run.sh runs this when DIAG=1, after the release build).
# 1. Qwen35RealVerifyParityLab on real Qwen3.6-27B: native-MTP-shaped verify columns vs 1-token
#    decode, bitwise, for three fork builds: new (LM_REV), old (3.32.3-macprovider.85) and
#    new with upstream #633 (q/k eps) reverted. old and new-minus-#633 must print the same
#    greedy tokens; that proves #633 is the only change to these models' text.
# 2. Provider tests at this branch (tiny random Qwen3.5 on Metal): packed native-MTP rows vs
#    serial ordinary greedy, shared decode/verify attention bits, the self-test.
#
# usage: studio-diag.sh LAB_DIR NEW_BIN_DIR BASE_BIN_DIR LM_REV
set -uo pipefail
L="$1" NEW="$2" BASE="$3" LM_REV="$4"
HERE="$(cd "$(dirname "$0")" && pwd)"
D="$L/window-${WINDOW:-4}/diag"; mkdir -p "$D"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$HOME/Applications/Xcode.app/Contents/Developer}"
export QWEN35_VERIFY_MODEL_DIR="$(ls -d "$HOME/Library/Application Support/macprovider/models/mlx-community--Qwen3.6-27B-4bit"/*/* | head -1)"
FILTER=Qwen35RealVerifyParityLab/testVerifyColumnsMatchSequentialDecode
failed=0

fork_probe() { # tag checkout_dir metallib
  local tag="$1" dir="$2" lib="$3"
  echo "#### fork probe $tag $(date +%T) $(git -C "$dir" rev-parse --short HEAD)"
  cp "$HERE/Qwen35RealVerifyParityLab.swift" "$dir/Tests/MLXLMTests/"
  ( cd "$dir" && swift build --build-tests ) > "$D/fork-$tag-build.log" 2>&1 || { echo "FORK_BUILD_FAILED $tag"; tail -5 "$D/fork-$tag-build.log"; failed=1; return; }
  cp "$lib" "$dir/.build/arm64-apple-macosx/debug/mlx-swift-lmPackageTests.xctest/Contents/MacOS/mlx.metallib"
  for v in "3 1" "2 1"; do
    local w=${v% *} c=${v#* } log="$D/fork-$tag-w${v% *}.log"
    ( cd "$dir" && QWEN35_VERIFY_WIDTH=$w QWEN35_VERIFY_CHECKPOINT=$c swift test --skip-build --filter "$FILTER" ) > "$log" 2>&1
    echo "probe $tag width=$w rc=$?"; grep -E "VERIFY (summary|prefill)|Failed to load" "$log" | head -3
  done
  rm -f "$dir/Tests/MLXLMTests/Qwen35RealVerifyParityLab.swift"
}

git -C "$L/mlx-swift-lm" checkout -q "$LM_REV" || exit 4
fork_probe new "$L/mlx-swift-lm" "$NEW/mlx.metallib"
[ -d "$L/mlx-swift-lm-85" ] || git -C "$L/mlx-swift-lm" worktree add -q "$L/mlx-swift-lm-85" 3.32.3-macprovider.85
fork_probe old "$L/mlx-swift-lm-85" "$BASE/mlx.metallib"
if [ ! -d "$L/mlx-swift-lm-no633" ]; then
  git -C "$L/mlx-swift-lm" worktree add -q --detach "$L/mlx-swift-lm-no633" "$LM_REV" \
    && git -C "$L/mlx-swift-lm-no633" revert --no-commit c408452839dd5f42d59b1c5c7e8c2d100b9e0b97 \
    || { echo "NO633_REVERT_FAILED"; failed=1; }
fi
[ -d "$L/mlx-swift-lm-no633" ] && fork_probe no633 "$L/mlx-swift-lm-no633" "$NEW/mlx.metallib"
tok() { grep -h "VERIFY tokens=" "$D/fork-$1-w3.log" 2>/dev/null | head -1; }
if [ -n "$(tok old)" ] && [ "$(tok old)" = "$(tok no633)" ]; then echo "TOKENS old == new-minus-#633"
else echo "TOKENS_DIFFER old vs new-minus-#633"; failed=1; fi
[ "$(tok new)" = "$(tok old)" ] && echo "TOKENS new == old" || echo "TOKENS new != old (expected from #633)"

echo "#### provider tests $(date +%T)"
P="$L/macprovider/phase3-binary"
( cd "$P" && swift build --build-tests ) > "$D/provider-build.log" 2>&1 || { echo "PROVIDER_BUILD_FAILED"; tail -5 "$D/provider-build.log"; exit 1; }
for x in "$P"/.build/arm64-apple-macosx/debug/*.xctest/Contents/MacOS; do cp "$NEW/mlx.metallib" "$x/mlx.metallib"; done
for f in 'PagedKVRuntimeBridgeTests/testRealQwen35' 'PagedKVRuntimeBridgeTests/testSharedDecodeAndVerifyAttentionMatchLoneBitsAtServedHeadDims' 'NativeMTPSelfTestTests'; do
  log="$D/provider-$(echo "$f" | tr '/' '_').log"
  ( cd "$P" && swift test --skip-build --filter "$f" ) > "$log" 2>&1
  rc=$?; echo "provider $f rc=$rc"; [ $rc -eq 0 ] || failed=1
  grep -E "Executed [0-9]+ tests|error:|failed \(" "$log" | head -8
done
echo "== diag done $(date +%T) failed=$failed"
exit $failed
