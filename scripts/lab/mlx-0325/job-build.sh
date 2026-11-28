#!/usr/bin/env bash
# mlx v0.32.5 fork-sync build slot, ON the Studio (never the M5). No model loads.
# Started by the Mac-side driver (scratchpad/windows/window-0325.sh MODE=build) with:
#   RUN_ID, MLX_REV (Augustas11/mlx), MLXC_REV (Augustas11/mlx-c), SWIFT_REV (Augustas11/mlx-swift)
# Steps (each prints STEP_OK/STEP_FAIL and logs to results/RUN_ID/<step>.log):
#   core        cmake + make tests of the merged core (Release, no python, no JIT)
#   core_small  doctest cases of the fork's small-M route, batch invariance, 64-row tile, user buffers
#   core_all    the full core doctest suite (reported, not gating)
#   regen       mlx-swift tools/update-mlx.sh with the submodules at MLX_REV / MLXC_REV: regenerated
#               files update-mlx.sh changed, tarred to results/RUN_ID/regen.tar.gz (deletions listed)
#               for the Mac to commit (the Studio has no push credentials)
#   swift_build swift build --build-tests of mlx-swift on the regenerated sources
#   swift_tests SmallMRouteTests, QmmTileTests and the quantization/fast suites
# Ends with JOB_PASS or JOB_FAIL. JOB_CHECK=1 only validates the knobs.
set -uo pipefail
: "${RUN_ID:?}" "${SRC:?}" "${MLX_REV:?}" "${MLXC_REV:?}" "${SWIFT_REV:?}"
[ "${JOB_CHECK:-0}" = 1 ] && { echo "JOB_CHECK ok MLX_REV=$MLX_REV MLXC_REV=$MLXC_REV SWIFT_REV=$SWIFT_REV"; exit 0; }
L=${LAB:-$HOME/lab-mlx-0325}; R="$L/results/$RUN_ID"; mkdir -p "$R"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$HOME/Applications/Xcode.app/Contents/Developer}"
export PATH="$HOME/lab-upstream/venv/bin:$PATH"   # pip cmake (no Homebrew cmake on the Studio)
fail=0
step() { local n="$1"; shift; echo "$(date +%T) STEP $n"
  if "$@" > "$R/$n.log" 2>&1; then echo "$(date +%T) STEP_OK $n"; else echo "$(date +%T) STEP_FAIL $n"; tail -30 "$R/$n.log"; return 1; fi; }
fetch() {  # DIR URL REV
  [ -e "$1/.git" ] || git clone -q "$2" "$1" || return 1
  git -C "$1" fetch -q origin "$3" 2>/dev/null || git -C "$1" fetch -q origin || return 1
  git -C "$1" checkout -q -f --detach "$3" && git -C "$1" reset -q --hard && git -C "$1" clean -qfdx -e build -e .build \
    && git -C "$1" rev-parse HEAD
}
core() {
  fetch "$L/mlx" https://github.com/Augustas11/mlx.git "$MLX_REV" || return 1
  mkdir -p "$L/mlx/build" && cd "$L/mlx/build" \
  && cmake .. -DCMAKE_BUILD_TYPE=Release -DMLX_BUILD_TESTS=ON -DMLX_BUILD_EXAMPLES=OFF -DMLX_BUILD_BENCHMARKS=OFF \
       -DMLX_BUILD_PYTHON_BINDINGS=OFF -DMLX_METAL_JIT=OFF \
  && nice -n 5 make -j24 tests
}
core_small() { cd "$L/mlx/build" && ./tests/tests -tc='*small-M*,*64-row tile*,*user buffer*,*zero-sized*'; }
core_all() { cd "$L/mlx/build" && ./tests/tests; }
regen() {
  fetch "$L/mlx-swift" https://github.com/Augustas11/mlx-swift.git "$SWIFT_REV" || return 1
  cd "$L/mlx-swift" && git submodule update --init --recursive -q || return 1
  fetch Source/Cmlx/mlx https://github.com/Augustas11/mlx.git "$MLX_REV" || return 1
  fetch Source/Cmlx/mlx-c https://github.com/Augustas11/mlx-c.git "$MLXC_REV" || return 1
  rm -rf build && zsh ./tools/update-mlx.sh || return 1
  echo "REGEN_DIFF_FILES $(git status --short -- Source | grep -v 'Source/Cmlx/mlx$\|Source/Cmlx/mlx-c$' | wc -l | tr -d ' ')"; git status --short | head -50
  # every file update-mlx.sh changed, added or deleted, for the Mac to commit
  git ls-files -d > "$R/regen-deleted.txt"
  git ls-files -m -o --exclude-standard -- Source | grep -v '^Source/Cmlx/mlx/\|^Source/Cmlx/mlx-c/' > "$R/regen-files.txt"
  tar -czf "$R/regen.tar.gz" -T "$R/regen-files.txt" \
    && echo "regen tar $(du -h "$R/regen.tar.gz" | cut -f1) files=$(wc -l < "$R/regen-files.txt") deleted=$(wc -l < "$R/regen-deleted.txt")"
}
swift_build() { cd "$L/mlx-swift" && swift build --build-tests; }
swift_tests() {
  # swift build ships no mlx.metallib: build it from this checkout next to the test binary (window 1
  # of engine-333 hit the same "Failed to load the default metallib").
  local bundle="$L/mlx-swift/.build/arm64-apple-macosx/debug/mlx-swiftPackageTests.xctest/Contents/MacOS"
  MLX_SWIFT_CHECKOUT="$L/mlx-swift" bash "$SRC/phase3-binary/scripts/build-mlx-metallib.sh" "$bundle" || return 1
  cp -f "$bundle/mlx.metallib" "$L/mlx-swift/.build/arm64-apple-macosx/debug/mlx.metallib"
  cd "$L/mlx-swift" && swift test --skip-build --filter 'SmallMRouteTests|QmmTileTests|QuantizationTests|MLXFastKernelTests|FP8Tests'
}
step core core && step core_small core_small || fail=1
[ -x "$L/mlx/build/tests/tests" ] && { step core_all core_all || echo "$(date +%T) core_all failed: reported, not gating"; }
step regen regen && step swift_build swift_build && step swift_tests swift_tests || fail=1
grep -hE "test cases:|Executed .* tests|Test run with|REGEN_DIFF_FILES" "$R"/core_small.log "$R"/core_all.log "$R"/regen.log "$R"/swift_tests.log 2>/dev/null | sed 's/^/SUMMARY /'
[ $fail = 0 ] && echo "$(date +%T) JOB_PASS" || echo "$(date +%T) JOB_FAIL"
exit $fail
