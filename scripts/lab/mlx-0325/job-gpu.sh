#!/usr/bin/env bash
# mlx v0.32.5 fork-sync GPU window, ON the Studio. Started by scratchpad/windows/window-0325.sh
# MODE=gpu with RUN_ID, SRC (the shipped campaign tree: phase3-binary + scripts/lab) and BASE_SRC (the
# same paths at origin/main, the current pin). Builds both provider release binaries with their
# mlx.metallib, then runs window.sh (GLM-5.3-Flash, cb + native-MTP passes, rows 4/8/16,
# base1/new/base2). Knobs passed through: ROWS OUTPUTS CONTEXTS TRIALS QUEUE_LIMIT PASSES GLM_DIR.
# A free-memory floor check runs before each model load (MIN_FREE_GB, default 200) so a dextr job
# that started mid-window aborts the window with a BLOCKER instead of racing it for memory.
# Ends with JOB_PASS or JOB_FAIL.
set -uo pipefail
: "${RUN_ID:?}" "${SRC:?}" "${BASE_SRC:?}"
L=${LAB:-$HOME/lab-mlx-0325}; R="$L/results/$RUN_ID"; mkdir -p "$R"
MODELS_ROOT="$HOME/Library/Application Support/macprovider/models"
GLM_DIR=${GLM_DIR:-Solstice-AI--GLM-5.3-Flash-UNCENSORED-mlx-oQ4e-DFlash2}
GLM_KEY=${GLM_KEY:-zai-org/glm-5.3-flash-uncensored}
if [ "${JOB_CHECK:-0}" = 1 ]; then
  echo "JOB_CHECK ok ROWS=${ROWS:-4,8,16} OUTPUTS=${OUTPUTS:-256} CONTEXTS=${CONTEXTS:-short,4k} TRIALS=${TRIALS:-6} QUEUE_LIMIT=${QUEUE_LIMIT:-16} PASSES=${PASSES:-cb mtp} GLM=$GLM_DIR@$GLM_KEY"
  exit 0
fi
export DEVELOPER_DIR="${DEVELOPER_DIR:-$HOME/Applications/Xcode.app/Contents/Developer}"
free_gb() { echo $(( ( $(vm_stat | awk '/Pages free/ {gsub("\\.","",$3); f=$3} /Pages inactive/ {gsub("\\.","",$3); i=$3} /Pages purgeable/ {gsub("\\.","",$3); p=$3} END {print f+i+p}') * 16384 ) / 1073741824 )); }
build() {  # TREE NAME
  echo "$(date +%T) BUILD_START $2"
  ( cd "$1/phase3-binary" && swift build -c release --product macprovider-cli ) > "$R/build-$2.log" 2>&1 \
    && bash "$1/phase3-binary/scripts/build-mlx-metallib.sh" "$1/phase3-binary/.build/release" > "$R/metallib-$2.log" 2>&1 \
    || { echo "$(date +%T) BUILD_FAIL $2"; tail -25 "$R/build-$2.log" "$R/metallib-$2.log"; return 1; }
  echo "$(date +%T) BUILD_OK $2 $(shasum -a 256 "$1/phase3-binary/.build/release/mlx.metallib" | cut -c1-16)"
}
build "$BASE_SRC" base || { echo "$(date +%T) BLOCKER: base build failed"; echo "$(date +%T) JOB_FAIL"; exit 1; }
build "$SRC" new || { echo "$(date +%T) BLOCKER: new build failed"; echo "$(date +%T) JOB_FAIL"; exit 1; }
# The required-kernel manifest names the core and mlx-swift revisions: re-derive it from the new build's
# mlx-swift checkout and check the built metallib carries every kernel (copied into phase3-binary at merge).
/usr/bin/python3 -I "$SRC/scripts/mlx-metallib-kernels.py" derive --mlx-swift-checkout "$SRC/phase3-binary/.build/checkouts/mlx-swift" \
    --output "$R/mlx-metallib-required-kernels.json" > "$R/metallib-kernels.log" 2>&1 \
  && /usr/bin/python3 -I "$SRC/scripts/mlx-metallib-kernels.py" check --manifest "$R/mlx-metallib-required-kernels.json" \
    "$SRC/phase3-binary/.build/release/mlx.metallib" >> "$R/metallib-kernels.log" 2>&1
echo "$(date +%T) METALLIB_KERNELS rc=$?"
p=$(ls -d "$MODELS_ROOT/$GLM_DIR"/*/* 2>/dev/null | head -1)
[ -n "$p" ] || { echo "$(date +%T) BLOCKER: MODEL_MISSING $GLM_DIR"; echo "$(date +%T) JOB_FAIL"; exit 1; }
f=$(free_gb); echo "$(date +%T) MEMORY free_gb=$f floor=${MIN_FREE_GB:-200}"
[ "$f" -ge "${MIN_FREE_GB:-200}" ] || { echo "$(date +%T) BLOCKER: only ${f} GB free before the GLM load (dextr job running?)"; echo "$(date +%T) JOB_FAIL"; exit 1; }
echo "$(date +%T) GRID_START glm53 $p"
bash "$SRC/scripts/lab/mlx-0325/window.sh" --base-bin "$BASE_SRC/phase3-binary/.build/release" \
  --new-bin "$SRC/phase3-binary/.build/release" --out "$R/window" --trials "${TRIALS:-6}" "glm53=$p@$GLM_KEY" \
  > "$R/window.log" 2>&1
rc=$?
grep -hE "^GATE|^compare|grid rc=|^ROUTE|NATIVE_MTP" "$R/window.log" | sed 's/^/GRID_LINE /'
python3 -I "$SRC/scripts/lab/mlx-0325/summary.py" "$R/window" > "$R/verdict.md" 2>&1; cat "$R/verdict.md"
[ $rc = 0 ] && echo "$(date +%T) JOB_PASS" || echo "$(date +%T) JOB_FAIL"
exit $rc
