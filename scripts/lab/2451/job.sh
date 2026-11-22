#!/bin/bash
# Runs ON THE STUDIO, started detached by the #2451 tile window wrapper
# (scratchpad/windows/window-2451-tiles.sh on the operator Mac), which has already paused live, the
# runner's Studio target and the FLOP miner and holds the Studio GPU lock. This job never pauses,
# restores or restarts any of them; it refuses to start when anything still runs.
#
# #2451: GLM-5.3-Flash prefill is 14-20% behind oMLX. Phase 1 times two tile candidates with a
# standalone microbench on GLM's real matmul shapes (tiles.py header: shapes, cells, verdict):
#   c3  gather_qmm_rhs (routed experts), c5  affine_qmm_t (dense projections).
# Phase 2 (only when a candidate gains >= THRESHOLD_PCT and PHASE2=auto): one-row TTFT A/B on the
# production batching route at the grid's 4k/16k contexts (3,673 / 14,126 prompt tokens), main /
# candidate / main, gated on greedy tokens identical to main (wide_prefill_gate.py from PR 2457).
#
# Steps:
#  1. preflight: nothing on :8080/:8000, no live agent, no serve, no com.flop agent, no
#     Virtualization VM / limactl / mlx_service process; free disk >= MIN_FREE_GB; the shipped
#     mlx-swift tree (SRC/mlx-swift, from make-mlx-swift-tree.sh) carries the fork core FORK_COMMIT;
#  2. tiles.py shapes from the served snapshot's headers (read only), then tiles.py plan;
#  3. swift build -c release of bench/ against SRC/mlx-swift (default toolchain, own scratch path),
#     the production metallib beside the binary;
#  4. hook check: an invalid tile must make each hooked call throw (proves the fork's dispatch is in
#     the binary), then the microbench (bench.json, one BENCH_CELL line per cell);
#  5. tiles.py verdict: T2451_TILES c3|c5 gain=.. bits=.. and T2451_PHASE2 run|skip (verdict.md);
#  6. phase 2: release lab-harness builds of phase3-binary, main on its pins and the candidate with
#     mlx-swift replaced by SRC/mlx-swift (swift package edit, its own copy of the tree); the signed
#     CB tuple of zai-org/glm-5.3-flash-uncensored (same metallib on both sides: MLX JIT-compiles the
#     quantized kernels, so the hook needs no metallib change); run-grid main-a, candidate
#     (--serve-env with the winning tile env), main-b; wide_prefill_gate.py; T2451_E2E line.
# Knobs: ROWS (2048,4096) ROUTINGS (uniform,skewed) SAMPLES (8) TARGET_MS (25) THRESHOLD_PCT (3)
#   PHASE2 (auto|0) CONTEXTS (4k,16k) OUTPUTS (128,512) TRIALS (3) MIN_FREE_GB (40) E2E_EXTRA_GB (40:
#   phase 2 needs the model size plus this free, #2468) SKIP_BUILD (phase-2 builds) GLM_PATH. JOB_CHECK=1: validate the knobs, write and print the plan from the embedded
#   shapes, print the phase-2 grid argvs, exit 0 before touching anything (the dry run).
# Every failure prints `BLOCKER:`; the job ends with JOB_PASS (every step that ran completed; the
# verdicts are findings) or JOB_FAIL.
set -u
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
LAB=${LAB:-$HOME/lab-2451}
RUN_ID=${RUN_ID:?RUN_ID unset}
SRC=${SRC:?SRC unset}
COMMIT=${COMMIT:-unknown}
FORK_COMMIT=${FORK_COMMIT:?FORK_COMMIT unset}
HERE=$SRC/scripts/lab/2451
GRID=$SRC/scripts/lab/parity-grid
GATE=$SRC/scripts/lab/ablit-perf/wide_prefill_gate.py
PKG=$SRC/phase3-binary
MLXSWIFT=$SRC/mlx-swift
RES=$LAB/results/$RUN_ID
STORE="$HOME/Library/Application Support/macprovider/models"
METALLIB=${METALLIB:-/Applications/Malibu.app/Contents/MacOS/mlx.metallib}
GLM_ID=zai-org/glm-5.3-flash-uncensored
GLM_SHA256=242f8fcfd34d4ecfd62180c1767f910bda925216948772126dc98c673d1c8919
GLM_PATH=${GLM_PATH:-}
NAME=glm53-flash-uncensored
ROWS=${ROWS:-2048,4096}
ROUTINGS=${ROUTINGS:-uniform,skewed}
SAMPLES=${SAMPLES:-8}
TARGET_MS=${TARGET_MS:-25}
THRESHOLD_PCT=${THRESHOLD_PCT:-3}
PHASE2=${PHASE2:-auto}
CONTEXTS=${CONTEXTS:-4k,16k}
OUTPUTS=${OUTPUTS:-128,512}
TRIALS=${TRIALS:-3}
MIN_FREE_GB=${MIN_FREE_GB:-40}
E2E_EXTRA_GB=${E2E_EXTRA_GB:-40}
BENCH_BUILD=$LAB/bench-build
MAIN_BIN=$PKG/.build-lab-main/release
CAND_PKG=$LAB/cand-$RUN_ID/phase3-binary
CAND_BIN=$CAND_PKG/.build-lab-tiles/release
log() { echo "$(date '+%H:%M:%S') $*"; }
die() { log "BLOCKER: $*"; log "JOB_FAIL"; exit "${2:-1}"; }
free_gb() { df -g "$HOME" | awk 'NR==2 {print $4}'; }
listening() { lsof -nP -iTCP:"$1" -sTCP:LISTEN -t >/dev/null 2>&1; }

case "$ROWS" in ""|*[!0-9,]*) die "ROWS=$ROWS must be a comma list of row counts" 64 ;; esac
case "$ROUTINGS" in uniform|skewed|uniform,skewed|skewed,uniform) ;; *) die "ROUTINGS=$ROUTINGS must be uniform and/or skewed" 64 ;; esac
case "$SAMPLES" in [6-9]|[1-9][0-9]) ;; *) die "SAMPLES=$SAMPLES must be 6..99" 64 ;; esac
case "$TARGET_MS" in ""|*[!0-9.]*) die "TARGET_MS=$TARGET_MS must be a number" 64 ;; esac
case "$THRESHOLD_PCT" in ""|*[!0-9.]*) die "THRESHOLD_PCT=$THRESHOLD_PCT must be a number" 64 ;; esac
case "$PHASE2" in auto|0) ;; *) die "PHASE2=$PHASE2 must be auto or 0" 64 ;; esac
case "$CONTEXTS" in ""|*[!A-Za-z0-9,]*) die "CONTEXTS=$CONTEXTS must be a comma list" 64 ;; esac
case "$OUTPUTS" in ""|*[!0-9,]*) die "OUTPUTS=$OUTPUTS must be a comma list of token counts" 64 ;; esac
case ",$OUTPUTS," in *,512,*) ;; *) die "OUTPUTS=$OUTPUTS must include 512 (the gate's cells)" 64 ;; esac
case "$TRIALS" in [1-9]) ;; *) die "TRIALS=$TRIALS must be 1..9" 64 ;; esac
case "$MIN_FREE_GB" in ""|*[!0-9]*) die "MIN_FREE_GB=$MIN_FREE_GB must be a number" 64 ;; esac
case "$E2E_EXTRA_GB" in ""|*[!0-9]*) die "E2E_EXTRA_GB=$E2E_EXTRA_GB must be a number" 64 ;; esac
case "$FORK_COMMIT" in *[!0-9a-f]*|"") die "FORK_COMMIT=$FORK_COMMIT must be a commit id" 64 ;; esac

model_dir() {  # GLM_PATH, else the provider-store snapshot of the catalog artifact (read only)
  [ -n "$GLM_PATH" ] && [ -f "$GLM_PATH/config.json" ] && { echo "$GLM_PATH"; return; }
  local d
  for d in "$STORE/Solstice-AI--GLM-5.3-Flash-UNCENSORED-mlx-oQ4e-DFlash2"/*/"$GLM_SHA256"; do
    [ -f "$d/config.json" ] && { echo "$d"; return; }
  done
  echo ""
}

# grid_args PASS BIN [SERVE_ENV]: the run-grid argv of one phase-2 pass (GARGS), as PR 2457's job.
grid_args() {
  GARGS=(--model-path "$MODEL" --model-id "$GLM_ID" --model-sha256 "$GLM_SHA256" --model-name "$NAME"
         --bin-dir "$2" --out-dir "$RES/e2e/$1" --cb auto --no-autotune-candidate --rows 1
         --contexts "$CONTEXTS" --outputs "$OUTPUTS" --trials "$TRIALS"
         --config-extra "$RES/e2e/cb-tuple.yaml" --expect-route batched --skip-reference --skip-compare)
  [ -z "${3:-}" ] || GARGS+=(--serve-env "$3")
}

PLAN_ARGS=(--rows "$ROWS" --routings "$ROUTINGS" --samples "$SAMPLES" --target-ms "$TARGET_MS")
if [ "${JOB_CHECK:-0}" = 1 ]; then
  mkdir -p "$RES"
  MODEL='<model-dir>'
  /usr/bin/python3 -I "$HERE/tiles.py" plan "${PLAN_ARGS[@]}" --out "$RES/plan.json" || die "plan failed" 11
  printf 'BENCH_ARGV TileBench run %s %s\n' "$RES/plan.json" "$RES/bench.json"
  printf 'VERDICT_ARGV tiles.py verdict --bench %s --threshold-pct %s\n' "$RES/bench.json" "$THRESHOLD_PCT"
  for p in main-a cand main-b; do
    case $p in cand) grid_args "$p" "$CAND_BIN" "MLX_LAB_2451_...=<winning tile>" ;; *) grid_args "$p" "$MAIN_BIN" ;; esac
    printf 'GRID_ARGS_%s' "$p"; printf ' %s' "${GARGS[@]}"; echo
  done
  log "JOB_CHECK ok"
  exit 0
fi

mkdir -p "$RES"
log "JOB_START run=$RUN_ID commit=$COMMIT fork_core=$FORK_COMMIT rows=$ROWS routings=$ROUTINGS samples=$SAMPLES target_ms=$TARGET_MS threshold=$THRESHOLD_PCT phase2=$PHASE2"

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
[ -f "$HERE/tiles.py" ] && [ -f "$HERE/bench/Package.swift" ] && [ -f "$GATE" ] && [ -f "$GRID/run-grid.sh" ] \
  && [ -f "$PKG/Package.swift" ] || die "source tree incomplete at $SRC" 11
grep -q "^core=$FORK_COMMIT$" "$MLXSWIFT/Source/Cmlx/LAB_2451_CORE" 2>/dev/null \
  || die "the shipped mlx-swift tree is not on core $FORK_COMMIT: $(tr '\n' ' ' < "$MLXSWIFT/Source/Cmlx/LAB_2451_CORE" 2>/dev/null)" 11
grep -q MLX_LAB_2451_GQMM_RHS_TILE "$MLXSWIFT/Source/Cmlx/mlx/mlx/backend/metal/quantized.cpp" \
  || die "the shipped core has no tile hook" 11
log "MLX_SWIFT_TREE $(tr '\n' ' ' < "$MLXSWIFT/Source/Cmlx/LAB_2451_CORE")"
[ -f "$METALLIB" ] || die "no metallib at $METALLIB" 14
METALLIB_SHA=$(shasum -a 256 "$METALLIB" | cut -d' ' -f1)
log "METALLIB sha256=$METALLIB_SHA"
MODEL=$(model_dir)
[ -n "$MODEL" ] || die "no GLM-5.3-Flash snapshot $GLM_SHA256 in the provider store (or GLM_PATH)" 11
log "MODEL $GLM_ID path=$MODEL"

# 2. Shapes and plan.
/usr/bin/python3 -I "$HERE/tiles.py" shapes --model-dir "$MODEL" --out "$RES/shapes.json" | tee "$RES/shapes.txt"
[ -s "$RES/shapes.json" ] || die "shape scan failed" 11
/usr/bin/python3 -I "$HERE/tiles.py" plan --shapes "$RES/shapes.json" "${PLAN_ARGS[@]}" --out "$RES/plan.json" \
  | tee "$RES/plan.txt"
[ -s "$RES/plan.json" ] || die "plan failed" 11

# 3. Bench build: the default toolchain, as the provider release builds.
log "BUILD_START bench"
(cd "$HERE/bench" && env TILE_BENCH_MLX_SWIFT="$MLXSWIFT" nice -n 10 swift build -c release --build-system native \
  --scratch-path "$BENCH_BUILD") > "$RES/build-bench.log" 2>&1 \
  || die "bench build failed: $(grep -m3 'error:' "$RES/build-bench.log" | tr '\n' ' ')" 14
TB=$BENCH_BUILD/release/TileBench
[ -x "$TB" ] || die "no TileBench at $TB" 14
cp "$METALLIB" "$BENCH_BUILD/release/mlx.metallib" || die "metallib copy failed" 14
log "BUILD_DONE bench $(shasum -a 256 "$TB" | cut -c1-16)"

# 4. Hook check, then the bench.
for fam in dense gather; do
  "$TB" hook-check "$fam" > "$RES/hook-$fam.out" 2> "$RES/hook-$fam.err"
  rc=$?
  var=MLX_LAB_2451_QMM_TILE; [ $fam = gather ] && var=MLX_LAB_2451_GQMM_RHS_TILE
  if [ "$rc" != 0 ] && grep -q "$var" "$RES/hook-$fam.err" "$RES/hook-$fam.out"; then
    log "HOOK_CHECK $fam ok (an invalid tile throws: rc=$rc)"
  else
    die "HOOK_CHECK $fam: rc=$rc, the hook did not reject an invalid tile: $(tail -n 2 "$RES/hook-$fam.err" "$RES/hook-$fam.out" | tr '\n' ' ')" 15
  fi
done
log "BENCH_START"
env TILE_BENCH_CORE="$FORK_COMMIT" "$TB" run "$RES/plan.json" "$RES/bench.json" 2> "$RES/bench.stderr" | tee "$RES/bench.txt"
rc=${PIPESTATUS[0]}
[ "$rc" = 0 ] && [ -s "$RES/bench.json" ] || die "bench exit $rc: $(tail -n 3 "$RES/bench.stderr" | tr '\n' ' ')" 15

# 5. Verdict.
/usr/bin/python3 -I "$HERE/tiles.py" verdict --bench "$RES/bench.json" --threshold-pct "$THRESHOLD_PCT" \
  --out-md "$RES/verdict.md" --out-json "$RES/verdict.json" > "$RES/verdict.txt" 2> "$RES/verdict.err" \
  || die "verdict: $(cat "$RES/verdict.err")" 16
cat "$RES/verdict.txt"
P2=$(grep '^T2451_PHASE2 ' "$RES/verdict.txt")
P2_ENV=$(echo "$P2" | sed -n 's/^T2451_PHASE2 run threshold=[^ ]* //p')
if [ "$PHASE2" = 0 ] || [ -z "$P2_ENV" ]; then
  log "PHASE2_SKIPPED ($([ "$PHASE2" = 0 ] && echo "PHASE2=0" || echo "no candidate gained ${THRESHOLD_PCT}%"))"
  echo "T2451_E2E skipped" >> "$RES/verdict.md"
  log "JOB_PASS"
  exit 0
fi
echo "$P2_ENV" | grep -Eq '^(MLX_LAB_2451_(QMM|GQMM_RHS)_TILE=[0-9,]+ ?)+$' || die "phase-2 env '$P2_ENV' is malformed" 16
# Each GLM serve start with native MTP admitted byte-copies the whole model for the admission
# capture (#2468): phase 2 needs the model's size plus build room free, or it does not start.
MODEL_GB=$(du -sg "$MODEL" | cut -f1)
need=$((MODEL_GB + E2E_EXTRA_GB))
fg=$(free_gb)
if [ "${fg:-0}" -lt "$need" ]; then
  log "BLOCKER: phase 2 needs ${need} GB free (model ${MODEL_GB} GB copied per serve start, #2468, plus ${E2E_EXTRA_GB} GB); ${fg} GB free"
  echo "T2451_E2E blocked disk free_gb=$fg need_gb=$need" | tee -a "$RES/verdict.md"
  log "JOB_PASS"
  exit 0
fi
log "PHASE2_START serve_env=$P2_ENV free_gb=$fg need_gb=$need"

# 6. Phase 2: builds, CB tuple, control / candidate / control, gate.
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

/usr/bin/python3 -I - "$PKG/catalog/autotune/continuous-batching-policy.json" "$GLM_ID" "$METALLIB_SHA" \
  > "$RES/e2e/cb-tuple.yaml" 2> "$RES/e2e/cb-tuple.err" <<'PY' || die "CB tuple: $(cat "$RES/e2e/cb-tuple.err")" 11
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

for p in main-a cand main-b; do
  case $p in cand) grid_args "$p" "$CAND_BIN" "$P2_ENV" ;; *) grid_args "$p" "$MAIN_BIN" ;; esac
  mkdir -p "$RES/e2e/$p"
  log "GRID_START $p"
  bash "$GRID/run-grid.sh" "${GARGS[@]}" > "$RES/e2e/$p/run.log" 2>&1
  rc=$?
  grep -E '^(CB_WARMUP_DONE|CB_WARMUP_STALL|CB_WARMUP_FAIL|ROUTE|ROUTE_FAIL) ' "$RES/e2e/$p/run.log" \
    | sed "s/^/GRID_$(echo "$p" | tr 'a-z-' 'A-Z_') /"
  log "GRID_DONE $p rc=$rc"
  grep -q '^ROUTE_FAIL ' "$RES/e2e/$p/run.log" && die "$p: ROUTE_FAIL, the serve was serial: not the batching route" 10
  [ -s "$RES/e2e/$p/provider.jsonl" ] || die "$p: no provider rows (rc=$rc): $(tail -n 3 "$RES/e2e/$p/run.log" | tr '\n' ' ')" 15
  [ "$rc" = 0 ] || die "$p: grid rc=$rc: $(tail -n 3 "$RES/e2e/$p/run.log" | tr '\n' ' ')" 15
done
/usr/bin/python3 -I "$GATE" --control-a "$RES/e2e/main-a/provider.jsonl" --candidate "$RES/e2e/cand/provider.jsonl" \
  --control-b "$RES/e2e/main-b/provider.jsonl" --out-md "$RES/e2e/gate.md" --out-json "$RES/e2e/gate.json" \
  > "$RES/e2e/gate.stdout" 2> "$RES/e2e/gate.stderr"
rc=$?
cat "$RES/e2e/gate.md" "$RES/e2e/gate.stdout" 2>/dev/null
[ "$rc" = 2 ] && die "gate input: $(cat "$RES/e2e/gate.stderr")" 16
e2e=$(/usr/bin/python3 -I - "$RES/e2e/gate.json" "$(echo "$P2_ENV" | tr ' ' ',')" <<'PY'
import json, sys
g = json.load(open(sys.argv[1]))
fmt = lambda v: "n/a" if v is None else f"{v * 100:+.2f}%"
cells = " ".join(f"{r['ctx']}/{r['out']}:{fmt(r['change_vs_a'])},{fmt(r['change_vs_b'])}" for r in g["cells"])
print(f"T2451_E2E tokens={'identical' if g['pass'] else 'differ'} verdict={g['verdict']} env={sys.argv[2]} "
      f"ttft_change_vs_a,vs_b {cells}")
PY
) || die "gate summary failed" 16
echo "$e2e" | tee -a "$RES/verdict.md"
[ "$rc" = 0 ] || log "BLOCKER: greedy tokens of the candidate differ from main (e2e/gate.md): the tile does not ship as is"
log "JOB_PASS"
