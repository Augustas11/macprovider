#!/bin/bash
# Runs ON THE STUDIO, started detached by the #2451 ship window wrapper
# (scratchpad/windows/window-2451-ship.sh on the operator Mac), which has already paused live, the
# runner's Studio target and the FLOP miner and holds the Studio GPU lock. This job never pauses,
# restores or restarts any of them; it refuses to start when anything still runs.
#
# #2451 ship window: the production dense qmm_t tile (mlx fork macprovider/2451-dense-tile: BM 64
# for affine bfloat16 group-64 4/6/8-bit weights from 1024 rows, on by default,
# MLX_METAL_QMM_STOCK_TILE=1 restores stock) against the campaign's own pins (#2462's chain):
#  1. preflight: nothing on :8080/:8000, no live agent, no serve, no com.flop agent, no
#     Virtualization VM / limactl / mlx_service process; free disk >= MIN_FREE_GB; the shipped
#     mlx-swift tree (SRC/mlx-swift: mlx-swift macprovider/2451-dense-tile, make-mlx-swift-tree.sh)
#     carries the fork core FORK_COMMIT with metal::qmm_t_block_rows and Tests/MLXTests/QmmTileTests;
#  2. fork test, as #2462's FORK_TESTS step (no cmake on the Studio): a copy of that tree,
#     `swift build --build-tests --build-system native` with DEVELOPER_DIR=TEST_DEV (full Xcode),
#     the metallib copied into the .xctest bundle, `swift test --filter MLXTests.QmmTileTests`
#     (JIT quantized kernels, as the provider runs them). The case must pass, not skip: it compares
#     the 64-row tile with stock 512-row chunks and requires mlx_qmm_t_block_rows to report 64 for
#     every compared product. A failure ends the job there (T2451_SHIP_VERDICT FAIL, JOB_FAIL);
#  3. release lab-harness builds of phase3-binary: main on the campaign pins, the candidate with
#     mlx-swift replaced by SRC/mlx-swift (swift package edit, its own copy of the tree);
#  4. per model in MODELS, parity-grid TTFT A/B, main-a / candidate / main-b, one row, CONTEXTS x
#     OUTPUTS, TRIALS each, no reference: GLM-5.3-Flash on the batching route with its signed CB tuple
#     (as the tile window), Qwen3.8-27B (4-bit, dense) serial (--cb off, no native MTP);
#  5. gate per model (wide_prefill_gate.py for identity and per-cell TTFT changes): tokens identical,
#     candidate TTFT no worse than +MAX_REGRESS_PCT against both controls in every cell; GLM also
#     beats both controls in every cell (the measured gain holds).
# Lines: T2451_FORK_TEST PASS|FAIL, T2451_SHIP <model> result=PASS|FAIL ..., then
#   T2451_SHIP_VERDICT PASS|FAIL fork_test=.. glm=.. qwen=..
# Knobs: MODELS (glm,qwen) CONTEXTS (4k,16k) OUTPUTS (128,512) TRIALS (3) MAX_REGRESS_PCT (1)
#   MIN_FREE_GB (60) E2E_EXTRA_GB (40) SKIP_BUILD (phase-3 builds) SKIP_FORK_TEST GLM_PATH QWEN_PATH.
#   JOB_CHECK=1: validate the knobs, print the grid argvs and exit 0 before touching anything.
# Every failure prints `BLOCKER:`; the job ends with JOB_PASS (every step ran; the verdict is in
# T2451_SHIP_VERDICT) or JOB_FAIL.
set -u
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin
LAB=${LAB:-$HOME/lab-2451}
RUN_ID=${RUN_ID:?RUN_ID unset}
SRC=${SRC:?SRC unset}
COMMIT=${COMMIT:-unknown}
FORK_COMMIT=${FORK_COMMIT:?FORK_COMMIT unset}
GRID=$SRC/scripts/lab/parity-grid
GATE=$SRC/scripts/lab/ablit-perf/wide_prefill_gate.py
PKG=$SRC/phase3-binary
MLXSWIFT=$SRC/mlx-swift
CORE=$MLXSWIFT/Source/Cmlx/mlx
RES=$LAB/results/$RUN_ID
STORE="$HOME/Library/Application Support/macprovider/models"
METALLIB=${METALLIB:-/Applications/Malibu.app/Contents/MacOS/mlx.metallib}
GLM_ID=zai-org/glm-5.3-flash-uncensored
GLM_SHA256=242f8fcfd34d4ecfd62180c1767f910bda925216948772126dc98c673d1c8919
GLM_NAME=glm53-flash-uncensored
GLM_PATH=${GLM_PATH:-}
QWEN_ID=qwen/qwen3.8-27b
QWEN_SHA256=8a8786e902127e9175f5be0d7c8bcf4dd32323a0521e4d9a20761608a07a6d05
QWEN_NAME=qwen3.8-27b
QWEN_PATH=${QWEN_PATH:-}
MODELS=${MODELS:-glm,qwen}
CONTEXTS=${CONTEXTS:-4k,16k}
OUTPUTS=${OUTPUTS:-128,512}
TRIALS=${TRIALS:-3}
MAX_REGRESS_PCT=${MAX_REGRESS_PCT:-1}
MIN_FREE_GB=${MIN_FREE_GB:-60}
E2E_EXTRA_GB=${E2E_EXTRA_GB:-40}
FORK_TEST_FILTER=MLXTests.QmmTileTests
FORK_COPY=$LAB/fork-mlx-swift
FORK_BUILD=$LAB/fork-mlx-swift-build
# Swift tests need full Xcode (XCTest); the release builds keep the default toolchain.
TEST_DEV=${TEST_DEV:-$HOME/Applications/Xcode.app/Contents/Developer}
xc() { env DEVELOPER_DIR="$TEST_DEV" "$@"; }
MAIN_BIN=$PKG/.build-lab-main/release
CAND_PKG=$LAB/cand-$RUN_ID/phase3-binary
CAND_BIN=$CAND_PKG/.build-lab-tiles/release
log() { echo "$(date '+%H:%M:%S') $*"; }
die() { log "BLOCKER: $*"; log "JOB_FAIL"; exit "${2:-1}"; }
free_gb() { df -g "$HOME" | awk 'NR==2 {print $4}'; }
listening() { lsof -nP -iTCP:"$1" -sTCP:LISTEN -t >/dev/null 2>&1; }

case "$MODELS" in glm|qwen|glm,qwen|qwen,glm) ;; *) die "MODELS=$MODELS must be glm and/or qwen" 64 ;; esac
case "$CONTEXTS" in ""|*[!A-Za-z0-9,]*) die "CONTEXTS=$CONTEXTS must be a comma list" 64 ;; esac
case "$OUTPUTS" in ""|*[!0-9,]*) die "OUTPUTS=$OUTPUTS must be a comma list of token counts" 64 ;; esac
case ",$OUTPUTS," in *,512,*) ;; *) die "OUTPUTS=$OUTPUTS must include 512 (the gate's cells)" 64 ;; esac
case "$TRIALS" in [1-9]) ;; *) die "TRIALS=$TRIALS must be 1..9" 64 ;; esac
case "$MAX_REGRESS_PCT" in ""|*[!0-9.]*) die "MAX_REGRESS_PCT=$MAX_REGRESS_PCT must be a number" 64 ;; esac
case "$MIN_FREE_GB" in ""|*[!0-9]*) die "MIN_FREE_GB=$MIN_FREE_GB must be a number" 64 ;; esac
case "$E2E_EXTRA_GB" in ""|*[!0-9]*) die "E2E_EXTRA_GB=$E2E_EXTRA_GB must be a number" 64 ;; esac
case "$FORK_COMMIT" in *[!0-9a-f]*|"") die "FORK_COMMIT=$FORK_COMMIT must be a commit id" 64 ;; esac

glm_dir() {  # GLM_PATH, else the provider-store snapshot of the catalog artifact (read only)
  [ -n "$GLM_PATH" ] && [ -f "$GLM_PATH/config.json" ] && { echo "$GLM_PATH"; return; }
  local d
  for d in "$STORE/Solstice-AI--GLM-5.3-Flash-UNCENSORED-mlx-oQ4e-DFlash2"/*/"$GLM_SHA256"; do
    [ -f "$d/config.json" ] && { echo "$d"; return; }
  done
  echo ""
}
qwen_dir() {  # QWEN_PATH, else the durable store snapshot of the catalog row (read only)
  [ -n "$QWEN_PATH" ] && [ -f "$QWEN_PATH/config.json" ] && { echo "$QWEN_PATH"; return; }
  /usr/bin/python3 -I - "$PKG/catalog/autotune/autotune-candidates.json" "$QWEN_ID" "$QWEN_SHA256" "$STORE" <<'PY' 2>/dev/null
import json, os, sys
cand, key, sha, store = sys.argv[1:5]
row = json.load(open(cand))["rows"].get(key)
if row and row["model_sha256"] == sha:
    path = os.path.join(store, row["model_id"].replace("/", "--"), row["model_revision"], sha)
    if os.path.isfile(os.path.join(path, "config.json")):
        print(path)
PY
}

# grid_args MODEL PASS BIN: the run-grid argv of one pass (GARGS). The candidate runs with no serve
# env: the tile is the fork's default.
grid_args() {
  local out=$RES/e2e/$1/$2
  if [ "$1" = glm ]; then
    GARGS=(--model-path "$GLM_MODEL" --model-id "$GLM_ID" --model-sha256 "$GLM_SHA256" --model-name "$GLM_NAME"
           --cb auto --config-extra "$RES/e2e/glm/cb-tuple.yaml" --expect-route batched)
  else
    GARGS=(--model-path "$QWEN_MODEL" --model-id "$QWEN_ID" --model-sha256 "$QWEN_SHA256" --model-name "$QWEN_NAME"
           --cb off --expect-route any)
  fi
  GARGS+=(--bin-dir "$3" --out-dir "$out" --no-autotune-candidate --rows 1 --contexts "$CONTEXTS"
          --outputs "$OUTPUTS" --trials "$TRIALS" --skip-reference --skip-compare)
}

IFS=, read -r -a MODEL_LIST <<< "$MODELS"
if [ "${JOB_CHECK:-0}" = 1 ]; then
  GLM_MODEL='<glm-dir>' QWEN_MODEL='<qwen-dir>'
  printf 'FORK_TEST_ARGV DEVELOPER_DIR=%s swift test --build-system native --skip-build --scratch-path %s --filter %s\n' \
    "$TEST_DEV" "$FORK_BUILD" "$FORK_TEST_FILTER"
  for m in "${MODEL_LIST[@]}"; do
    for p in main-a cand main-b; do
      case $p in cand) grid_args "$m" "$p" "$CAND_BIN" ;; *) grid_args "$m" "$p" "$MAIN_BIN" ;; esac
      printf 'GRID_ARGS_%s_%s' "$m" "$p"; printf ' %s' "${GARGS[@]}"; echo
    done
  done
  log "JOB_CHECK ok"
  exit 0
fi

mkdir -p "$RES"
log "JOB_START run=$RUN_ID commit=$COMMIT fork_core=$FORK_COMMIT models=$MODELS contexts=$CONTEXTS outputs=$OUTPUTS trials=$TRIALS max_regress=$MAX_REGRESS_PCT%"

# 1. Preflight.
listening 8080 && die "a server listens on :8080; the Studio is not paused" 3
listening 8000 && die "a server listens on :8000; the FLOP miner backend is not paused" 3
launchctl print "gui/$(id -u)/live.malibu.provider" >/dev/null 2>&1 && die "live.malibu.provider is loaded" 3
pgrep -f "[m]acprovider-cli serve" >/dev/null 2>&1 && die "a macprovider-cli serve process runs" 3
launchctl list 2>/dev/null | grep -q 'com\.flop\.' && die "a com.flop LaunchAgent is loaded (miner not paused)" 3
pgrep -f "[c]om.apple.Virtualization.VirtualMachine|[l]imactl|[m]lx_service" >/dev/null 2>&1 && die "a miner VM or backend process runs" 3
fg=$(free_gb)
log "DISK free_gb=$fg min=$MIN_FREE_GB"
[ "${fg:-0}" -ge "$MIN_FREE_GB" ] || die "only ${fg} GB free on the data volume; need $MIN_FREE_GB" 13
[ -f "$GATE" ] && [ -f "$GRID/run-grid.sh" ] && [ -f "$PKG/Package.swift" ] || die "source tree incomplete at $SRC" 11
grep -q "^core=$FORK_COMMIT$" "$MLXSWIFT/Source/Cmlx/LAB_2451_CORE" 2>/dev/null \
  || die "the shipped mlx-swift tree is not on core $FORK_COMMIT: $(tr '\n' ' ' < "$MLXSWIFT/Source/Cmlx/LAB_2451_CORE" 2>/dev/null)" 11
grep -q qmm_t_block_rows "$CORE/mlx/backend/metal/quantized.cpp" || die "the shipped core has no production dense tile" 11
{ [ -f "$MLXSWIFT/Tests/MLXTests/QmmTileTests.swift" ] && grep -q mlx_qmm_t_block_rows "$MLXSWIFT/Source/Cmlx/macprovider/qmm_tile.cpp"; } \
  || die "the shipped mlx-swift tree has no QmmTileTests / mlx_qmm_t_block_rows (not mlx-swift macprovider/2451-dense-tile)" 11
grep -q MLX_LAB_2451 "$CORE/mlx/backend/metal/quantized.cpp" && die "the shipped core still carries the lab tile hook" 11
log "MLX_SWIFT_TREE $(tr '\n' ' ' < "$MLXSWIFT/Source/Cmlx/LAB_2451_CORE")"
[ -n "${MLX_METAL_QMM_STOCK_TILE:-}" ] && die "MLX_METAL_QMM_STOCK_TILE is set in the job environment" 11
[ -f "$METALLIB" ] || die "no metallib at $METALLIB" 14
METALLIB_SHA=$(shasum -a 256 "$METALLIB" | cut -d' ' -f1)
log "METALLIB sha256=$METALLIB_SHA"
GLM_MODEL="" QWEN_MODEL=""
for m in "${MODEL_LIST[@]}"; do
  if [ "$m" = glm ]; then
    GLM_MODEL=$(glm_dir)
    [ -n "$GLM_MODEL" ] || die "no GLM-5.3-Flash snapshot $GLM_SHA256 in the provider store (or GLM_PATH)" 11
    log "MODEL $GLM_ID path=$GLM_MODEL"
  else
    QWEN_MODEL=$(qwen_dir)
    [ -n "$QWEN_MODEL" ] || die "no Qwen3.8-27B snapshot $QWEN_SHA256 in the provider store (or QWEN_PATH)" 11
    log "MODEL $QWEN_ID path=$QWEN_MODEL"
  fi
done
if [ "${SKIP_FORK_TEST:-0}" != 1 ]; then
  [ -d "$TEST_DEV" ] || die "no Xcode developer dir at $TEST_DEV (TEST_DEV): the fork test cannot build" 14
fi

# 2. Fork test: mlx-swift QmmTileTests on the Studio GPU (#2462's FORK_TESTS recipe).
FORK_TEST=skipped
if [ "${SKIP_FORK_TEST:-0}" != 1 ]; then
  rm -rf "$FORK_BUILD"
  rsync -a --delete --exclude '.build' --exclude '.swiftpm' "$MLXSWIFT/" "$FORK_COPY/" > "$RES/fork-copy.log" 2>&1 \
    || die "mlx-swift tree copy failed" 14
  log "BUILD_START fork-tests"
  (cd "$FORK_COPY" && xc nice -n 10 swift build --build-tests --build-system native --scratch-path "$FORK_BUILD") \
    > "$RES/fork-tests-build.log" 2>&1 \
    || die "fork test build failed: $(grep -m3 'error:' "$RES/fork-tests-build.log" | tr '\n' ' ' | cut -c1-400)" 14
  fbundle=""
  for b in "$FORK_BUILD"/debug/*PackageTests.xctest "$FORK_BUILD"/debug/MLXTests.xctest; do
    [ -d "$b" ] && { fbundle=$b; break; }
  done
  [ -n "$fbundle" ] || die "no test bundle under $FORK_BUILD/debug" 14
  # MLX loads mlx.metallib from beside the test binary; without it no Metal test runs.
  { cp "$METALLIB" "$fbundle/Contents/MacOS/mlx.metallib" && cp "$METALLIB" "$FORK_BUILD/debug/mlx.metallib"; } \
    || die "metallib copy into the test bundle failed" 14
  log "BUILD_DONE fork-tests"
  log "FORK_TEST_START $FORK_TEST_FILTER"
  (cd "$FORK_COPY" && env -u MLX_METAL_QMM_STOCK_TILE DEVELOPER_DIR="$TEST_DEV" swift test --build-system native \
     --skip-build --scratch-path "$FORK_BUILD" --filter "$FORK_TEST_FILTER") > "$RES/fork-test.log" 2>&1
  rc=$?
  grep -q "Failed to load the default metallib" "$RES/fork-test.log" \
    && die "QmmTileTests could not load the metallib (no test ran): $RES/fork-test.log" 15
  p=$(grep -cE "Test Case '-\[MLXTests\.QmmTileTests test[A-Za-z0-9_]+\]' passed" "$RES/fork-test.log")
  f=$(grep -cE "Test Case '-\[MLXTests\.QmmTileTests test[A-Za-z0-9_]+\]' failed" "$RES/fork-test.log")
  sk=$(grep -cE "Test Case '-\[MLXTests\.QmmTileTests test[A-Za-z0-9_]+\]' skipped" "$RES/fork-test.log")
  log "FORK_TEST_DONE rc=$rc passed=$p failed=$f skipped=$sk"
  grep -E "XCTAssert|error:" "$RES/fork-test.log" | head -n 10 | sed 's/^/FORK_TEST_FAILURE /'
  if [ "$rc" = 0 ] && [ "$p" = 1 ] && [ "$f" = 0 ] && [ "$sk" = 0 ]; then
    FORK_TEST=PASS
  else
    FORK_TEST=FAIL
  fi
  rm -rf "$FORK_BUILD" "$FORK_COPY"
fi
echo "T2451_FORK_TEST $FORK_TEST" | tee "$RES/verdict.md"
if [ "$FORK_TEST" = FAIL ]; then
  # A tile that changes a bit does not ship; the TTFT A/B would not change that.
  echo "T2451_SHIP_VERDICT FAIL fork_test=FAIL (no TTFT A/B run)" | tee -a "$RES/verdict.md"
  die "the fork bit-identity test did not pass (rc=$rc, $RES/fork-test.log)" 15
fi

# 3. Builds: main on the campaign pins, the candidate on the shipped mlx-swift tree.
mkdir -p "$RES/e2e"
if [ "${SKIP_BUILD:-0}" != 1 ]; then
  log "BUILD_START main"
  (cd "$PKG" && nice -n 10 swift build -c release --product macprovider-cli --build-path .build-lab-main \
    -Xswiftc -DMACPROVIDER_LAB_HARNESS) > "$RES/e2e/build-main.log" 2>&1 \
    || die "main build failed: $(tail -n 3 "$RES/e2e/build-main.log" | tr '\n' ' ')" 14
  log "BUILD_START cand"
  rm -rf "$LAB"/cand-*
  if ! { mkdir -p "$CAND_PKG" && rsync -a --exclude '.build*' --exclude '.swiftpm' --exclude 'Packages' "$PKG/" "$CAND_PKG/"; }; then
    die "candidate tree copy failed" 14
  fi
  (cd "$CAND_PKG" && swift package --build-path .build-lab-tiles edit mlx-swift --path "$MLXSWIFT" \
     && nice -n 10 swift build -c release --product macprovider-cli --build-path .build-lab-tiles \
       -Xswiftc -DMACPROVIDER_LAB_HARNESS) > "$RES/e2e/build-cand.log" 2>&1 \
    || die "candidate build failed: $(tail -n 3 "$RES/e2e/build-cand.log" | tr '\n' ' ')" 14
fi
for side in main cand; do
  bin=$MAIN_BIN; [ $side = cand ] && bin=$CAND_BIN
  [ -x "$bin/macprovider-cli" ] || die "no $side lab-harness binary at $bin" 14
  cp "$METALLIB" "$bin/mlx.metallib" || die "metallib copy failed" 14
  shasum -a 256 "$bin/macprovider-cli" "$bin/mlx.metallib" > "$RES/e2e/identity-$side.sha256"
  log "BUILD_DONE $side $("$bin/macprovider-cli" --version 2>&1 | head -n 1) cli_sha256=$(cut -c1-16 "$RES/e2e/identity-$side.sha256" | head -n 1)"
done
cmp -s "$MAIN_BIN/macprovider-cli" "$CAND_BIN/macprovider-cli" && die "the main and candidate binaries are identical: the fork core did not reach the candidate build" 14
# 3b. Metallib kernel manifests for the two pins this window builds (PR 2472's mlx-swift on the
# campaign pins, PR 2473's tree): `derive` compiles each kernel unit with the Metal toolchain, so
# it runs here, not on the operator Mac. Informational: a failure is logged, never a verdict input.
mkdir -p "$RES/metallib"
for side in main cand; do
  ck="$PKG/.build-lab-main/checkouts/mlx-swift"; [ $side = cand ] && ck="$MLXSWIFT"
  if (xc python3 "$SRC/scripts/mlx-metallib-kernels.py" derive --mlx-swift-checkout "$ck" \
        --output "$RES/metallib/required-kernels-$side.json") > "$RES/metallib/derive-$side.log" 2>&1; then
    log "METALLIB_DERIVE $side ok rev=$(git -C "$ck" rev-parse HEAD 2>/dev/null) out=$RES/metallib/required-kernels-$side.json"
  else
    log "METALLIB_DERIVE $side failed: $(tail -n 2 "$RES/metallib/derive-$side.log" | tr '\n' ' ' | cut -c1-200)"
  fi
done

# 4./5. Per model: CB tuple (GLM), control / candidate / control, gate.
# Per-model results in RESULT_glm / RESULT_qwen (the Studio's /bin/bash 3.2 has no associative arrays).
for m in "${MODEL_LIST[@]}"; do
  printf -v "RESULT_$m" FAIL
  mkdir -p "$RES/e2e/$m"
  if [ "$m" = glm ]; then
    # Each GLM serve start with native MTP admitted may capture the model (#2468): room first.
    MODEL_GB=$(du -sg "$GLM_MODEL" | cut -f1)
    need=$((MODEL_GB + E2E_EXTRA_GB)) fg=$(free_gb)
    [ "${fg:-0}" -ge "$need" ] || die "glm needs ${need} GB free (model ${MODEL_GB} GB plus ${E2E_EXTRA_GB} GB); ${fg} GB free" 13
    /usr/bin/python3 -I - "$PKG/catalog/autotune/continuous-batching-policy.json" "$GLM_ID" "$METALLIB_SHA" \
      > "$RES/e2e/glm/cb-tuple.yaml" 2> "$RES/e2e/glm/cb-tuple.err" <<'PY' || die "CB tuple: $(cat "$RES/e2e/glm/cb-tuple.err")" 11
import json, sys
policy, model_id, metallib = sys.argv[1:4]
entries = [e for e in json.load(open(policy))["entries"] if e["model_id"] == model_id]
if len(entries) != 1:
    sys.exit(f"{len(entries)} signed CB entries for {model_id}")
e = entries[0]
if e["metallib_sha256"] != metallib:
    sys.exit(f"metallib {metallib} is not the tuple's {e['metallib_sha256']}: the CB tuple cannot match")
keys = ("model_id", "model_sha256", "tokenizer_sha256", "chat_template_sha256", "cache_class", "kv_dtype",
        "requires_moe", "hardware_class", "metallib_sha256", "kernel_identifier", "cached_turns_accepted")
print("continuous_batching: canary")
print("continuous_batching_cached_turns: true")
print(f"continuous_batch_queue_limit: {e.get('max_served_slots', 4)}")
print("continuous_batching_accepted_tuples:")
print("  - {" + ", ".join(f"{k}: {json.dumps(e[k])}" for k in keys) + "}")
PY
  fi
  grid_ok=1
  for p in main-a cand main-b; do
    case $p in cand) grid_args "$m" "$p" "$CAND_BIN" ;; *) grid_args "$m" "$p" "$MAIN_BIN" ;; esac
    out=$RES/e2e/$m/$p
    mkdir -p "$out"
    log "GRID_START $m $p"
    bash "$GRID/run-grid.sh" "${GARGS[@]}" > "$out/run.log" 2>&1
    rc=$?
    grep -E '^(CB_WARMUP_DONE|CB_WARMUP_STALL|CB_WARMUP_FAIL|ROUTE|ROUTE_FAIL) ' "$out/run.log" \
      | sed "s/^/GRID_$(echo "${m}_$p" | tr 'a-z-' 'A-Z_') /"
    log "GRID_DONE $m $p rc=$rc"
    if grep -q '^ROUTE_FAIL ' "$out/run.log"; then
      log "BLOCKER: $m $p: ROUTE_FAIL, the serve was serial: not the batching route"; grid_ok=0; break
    fi
    if [ ! -s "$out/provider.jsonl" ] || [ "$rc" != 0 ]; then
      log "BLOCKER: $m $p: grid rc=$rc: $(tail -n 3 "$out/run.log" | tr '\n' ' ')"; grid_ok=0; break
    fi
  done
  if [ "$grid_ok" != 1 ]; then
    echo "T2451_SHIP $m result=FAIL (grid did not complete)" | tee -a "$RES/verdict.md"
    continue
  fi
  d=$RES/e2e/$m
  /usr/bin/python3 -I "$GATE" --control-a "$d/main-a/provider.jsonl" --candidate "$d/cand/provider.jsonl" \
    --control-b "$d/main-b/provider.jsonl" --out-md "$d/gate.md" --out-json "$d/gate.json" \
    > "$d/gate.stdout" 2> "$d/gate.stderr"
  rc=$?
  cat "$d/gate.md" "$d/gate.stdout" 2>/dev/null
  if [ "$rc" = 2 ]; then
    log "BLOCKER: $m gate input: $(cat "$d/gate.stderr")"
    echo "T2451_SHIP $m result=FAIL (gate input unreadable)" | tee -a "$RES/verdict.md"
    continue
  fi
  line=$(/usr/bin/python3 -I - "$d/gate.json" "$m" "$MAX_REGRESS_PCT" <<'PY'
import json, sys
g, model, cap = json.load(open(sys.argv[1])), sys.argv[2], float(sys.argv[3]) / 100
fmt = lambda v: "n/a" if v is None else f"{v * 100:+.2f}%"
bad = []
if not g["pass"]:
    bad.append("tokens")
for r in g["cells"]:
    for side in ("change_vs_a", "change_vs_b"):
        v = r[side]
        if v is None or v > cap:
            bad.append(f"{r['ctx']}/{r['out']}:{side}={fmt(v)}")
if model == "glm" and g["verdict"] != "KEEP":
    bad.append("glm_gain_not_held")
cells = " ".join(f"{r['ctx']}/{r['out']}:{fmt(r['change_vs_a'])},{fmt(r['change_vs_b'])}" for r in g["cells"])
print(f"T2451_SHIP {model} result={'FAIL' if bad else 'PASS'} tokens={'identical' if g['pass'] else 'differ'} "
      f"keep={g['verdict']} ttft_change_vs_a,vs_b {cells}" + (f" failed={','.join(bad)}" if bad else ""))
PY
  ) || { log "BLOCKER: $m gate summary failed"; echo "T2451_SHIP $m result=FAIL (summary)" | tee -a "$RES/verdict.md"; continue; }
  echo "$line" | tee -a "$RES/verdict.md"
  case "$line" in *" result=PASS "*) printf -v "RESULT_$m" PASS ;; esac
done

overall=PASS
[ "${SKIP_FORK_TEST:-0}" = 1 ] || [ "$FORK_TEST" = PASS ] || overall=FAIL
summary="fork_test=$FORK_TEST"
for m in "${MODEL_LIST[@]}"; do
  v=RESULT_$m
  [ "${!v}" = PASS ] || overall=FAIL
  summary="$summary $m=${!v}"
done
echo "T2451_SHIP_VERDICT $overall $summary" | tee -a "$RES/verdict.md"
log "JOB_PASS"
