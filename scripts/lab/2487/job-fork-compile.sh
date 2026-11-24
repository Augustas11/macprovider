#!/bin/bash
# #2487 compile + unit tests of the mlx-swift-lm fork branch, run ON THE STUDIO by
# studio-2487-compile.sh (detached, own process group). No model weights, no server.
#
# Clones/fetches Augustas11/mlx-swift-lm into ~/lab-2487/src/mlx-swift-lm, checks out FORK_REF
# (detached), runs `swift build --build-tests`, builds mlx.metallib from the resolved mlx-swift
# checkout with build-mlx-metallib.sh (copied beside this script) and copies it into every
# .xctest bundle, then `swift test --skip-build --filter "$FILTER"`.
# Writes only under ~/lab-2487. Prints BLOCKER: on setup failures, T2487_COMPILE rc=<n> PASS|FAIL last.
set -u
RUN_ID=${RUN_ID:?RUN_ID}
FORK_REF=${FORK_REF:?FORK_REF}
FILTER=${FILTER:-Inkling2|ConvolutionTail|KVCacheRound}
L=$HOME/lab-2487
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT=$L/results/compile-$RUN_ID; mkdir -p "$OUT" "$L/src"
say() { echo "$(date '+%H:%M:%S') $*"; }
done_rc() { say "T2487_COMPILE rc=$1 $([ "$1" = 0 ] && echo PASS || echo FAIL)"; exit "$1"; }
blocker() { say "BLOCKER: $*"; done_rc "${2:-90}"; }

free_gb=$(df -g "$HOME" | awk 'NR==2{print $4}')
[ "${free_gb:-0}" -ge 20 ] || blocker "only ${free_gb:-?} GB free on the Studio (need 20)" 91
export DEVELOPER_DIR=$HOME/Applications/Xcode.app/Contents/Developer
[ -d "$DEVELOPER_DIR" ] || blocker "no DEVELOPER_DIR at $DEVELOPER_DIR" 92
say "start run=$RUN_ID ref=$FORK_REF free=${free_gb}GB swift=$(swift --version 2>&1 | head -1)"

R=$L/src/mlx-swift-lm
if [ ! -d "$R/.git" ]; then
  git clone -q https://github.com/Augustas11/mlx-swift-lm.git "$R" || blocker "clone failed" 93
fi
cd "$R" || blocker "no checkout at $R" 93
git fetch -q origin macprovider/2487-inkling2-dspark || blocker "fetch failed" 93
git checkout -q --detach "$FORK_REF" || blocker "cannot check out $FORK_REF" 93
say "checked out $(git rev-parse --short HEAD): $(git log -1 --format=%s)"

say "swift build --build-tests"
swift build --build-tests > "$OUT/build.log" 2>&1; rc=$?
if [ $rc -ne 0 ]; then
  say "build failed rc=$rc; first errors:"
  grep -E "error:" "$OUT/build.log" | sort -u | head -40
  done_rc $rc
fi

mkdir -p "$OUT/metallib"
MLX_SWIFT_CHECKOUT="$R/.build/checkouts/mlx-swift" bash "$HERE/build-mlx-metallib.sh" "$OUT/metallib" \
  > "$OUT/metallib.log" 2>&1 || { tail -5 "$OUT/metallib.log"; blocker "metallib build failed" 94; }
[ -f "$OUT/metallib/mlx.metallib" ] || blocker "no mlx.metallib produced" 94
n=0
for x in .build/arm64-apple-macosx/debug/*.xctest/Contents/MacOS; do
  cp "$OUT/metallib/mlx.metallib" "$x/mlx.metallib" && n=$((n + 1))
done
[ "$n" -gt 0 ] || blocker "no .xctest bundle to receive mlx.metallib" 94
say "metallib copied into $n xctest bundle(s)"

say "swift test --filter \"$FILTER\""
swift test --skip-build --filter "$FILTER" > "$OUT/test.log" 2>&1; rc=$?
grep -E "Test Case .*(passed|failed)|✔|✘|recorded an issue|error:|Executed" "$OUT/test.log" | tail -60
done_rc $rc
