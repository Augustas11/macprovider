#!/bin/bash
# Runs ON THE STUDIO from ~/lab-ablit-perf/job/ablit-perf/. One window, two Flash-Next (qwen4_exp)
# exactness checks back to back, on the snapshot and pins of job-qwen4-cb.sh (QWEN4_*, FORK, the
# .build-lab-qwen4 lab-harness build), after the engine tests:
#
# 0. #2448 engine tests, before any model load. `swift test --filter Qwen4ExpTests` in FORK on Metal
#    (debug build in ~/lab-ablit-perf/.build-fork-tests, METALLIB copied into the test bundle,
#    Xcode's XCTest via DEVELOPER_DIR, default ~/Applications/Xcode.app): batched decode equals each
#    row alone bit for bit at 2/8/16 rows and mixed offsets, and with a row joining a batch that is
#    already decoding and rows leaving it (float and 4-bit). Any failed test, or a FORK without the
#    join/leave tests, ends the job (JOB_FAIL) before pass fence-a. FORK is the launcher's rsync of
#    FORK_DIR, which must be the mlx-swift-lm worktree on campaign/2448-qwen4-join-test
#    (FORK_DIR=$HOME/mlx-swift-lm-2448): tag 3.32.3-macprovider.84 (the campaign/2409-qwen4-exp-batch
#    engine job-qwen4-cb.sh builds) plus the join/leave tests, so every other step is unchanged.
#
# A. #2448, batched token identity at a fixed admission. Two passes of job-qwen4-cb.sh, each its own
#    serve process, provider side only (SKIP_REFERENCE=1), LAB_FENCE=1: every trial's rows go out as
#    one request-named admission fence, which this lab-harness build holds until every row is queued
#    and then admits in row order (LabRequestFence.swift). Pass fence-a builds and runs the FR-CB10
#    self-check fresh (unless SEED_SELF_CHECK_RUN seeds it); pass fence-b reuses the build and seeds
#    fence-a's verdict, so both serve the same slots. cb_determinism.py check then requires, for every
#    row of every cell at DET_ROWS, identical text and completion token count on every trial of both
#    passes, and one installed fence per trial (DETERMINISM PASS|FAIL). Its header says what a PASS
#    does and does not prove: identity of the batched path across trials and processes given the same
#    admission, not equality with a lone row (the stock_order batch kernel may differ in low bits).
#    SPEC_EVIDENCE lines carry what the SPEC-039 qwen4_exp entry gates on from pass fence-a: the route
#    is batched only when the attach-time parity and isolation probes passed (else the attach falls
#    back and --expect-route batched fails the pass), and the FR-CB10 self-check verdict per width
#    (`event=cb_self_check action=measured|applied` serve lines; `seeded` when SEED_SELF_CHECK_RUN
#    reused an earlier verdict, which is then not fresh evidence).
# B. #2449, served-prompt parity. Pass fence-a's 1-row cells hold the served text of the 200-token
#    context; each other SERVED_CONTEXTS entry gets one more 1-row, 1-trial pass (served-<ctx>, seeded,
#    no rebuild). job-qwen4-parity.sh (SKIP_BUILD=1, SERVED_JSONL = those provider.jsonl files) then
#    runs the code-prompt oracles, the served-prompt oracles, glm-parity at prefill 2048 (all) and 512
#    (served), the DIVERGENCE_VERDICT report per served prompt (CLOSE_CALL / REAL_DIVERGENCE and a
#    cause) and the parity gate with the served (low-margin) prompts in its set.
#
# Knobs: DET_ROWS (1,4,8,11) DET_CONTEXTS (200) OUTPUTS (512) TRIALS (3) CB_SLOTS (16)
# SERVED_CONTEXTS (200,4000) SERVED_STEPS (512) CONTEXTS/STEPS (the code-prompt gate cells, parity job
# defaults 1024,8192 / 256) SEED_SELF_CHECK_RUN SKIP_BUILD (1: also reuse the build for fence-a)
# RUN_DETERMINISM (1) RUN_PARITY (1) and the QWEN4_* pins, FORK, METALLIB (also the engine tests'),
# SERVE_ENV of job-qwen4-cb.sh. EXACT_JOB_CHECK=1 validates the knobs, prints the plan and exits 0
# (the unit test).
# Sub-job lines pass through with JOB_START/JOB_PASS/JOB_FAIL renamed STEP_START/STEP_PASS/STEP_FAIL;
# every failure prints `BLOCKER:`; the job ends with JOB_PASS (exit 0: every step passed, DETERMINISM
# PASS, PARITY_GATES PASS) or JOB_FAIL (nonzero). A DIVERGENCE_VERDICT is a finding, not a failure.
# No wall-clock deadline: the launcher's stall watcher is the only bound.
# Results: <run>/qwen4-flash-next-cb/{fence-a,fence-b,served-<ctx>}/, <run>/qwen4-parity/ and
# <run>/qwen4-exactness/{engine-tests.log,engine-tests-build.log,determinism.json,determinism.md,
# summary.txt}.
set -u
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
HERE="$(cd "$(dirname "$0")" && pwd)"
LAB=$HOME/lab-ablit-perf
RUN_ID=${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}
export RUN_ID
RES=$LAB/results/$RUN_ID
CBRES=$RES/qwen4-flash-next-cb
OUT=$RES/qwen4-exactness
DET_ROWS=${DET_ROWS:-1,4,8,11}
DET_CONTEXTS=${DET_CONTEXTS:-200}
OUTPUTS=${OUTPUTS:-512}
TRIALS=${TRIALS:-3}
CB_SLOTS=${CB_SLOTS:-16}
SERVED_CONTEXTS=${SERVED_CONTEXTS-200,4000}
SERVED_STEPS=${SERVED_STEPS:-512}
SEED_SELF_CHECK_RUN=${SEED_SELF_CHECK_RUN:-}
RUN_DETERMINISM=${RUN_DETERMINISM:-1}
RUN_PARITY=${RUN_PARITY:-1}
FORK=${FORK:-$LAB/mlx-swift-lm-2409}
METALLIB=${METALLIB:-/Applications/Malibu.app/Contents/MacOS/mlx.metallib}
ENGINE_TESTS_BUILD=$LAB/.build-fork-tests
ENGINE_TESTS_FILE=$FORK/Tests/MLXLMTests/Qwen4ExpTests.swift
ENGINE_REQUIRED_TESTS="testRowJoiningADecodingBatchMatchesSerial testRowLeavingADecodingBatchMatchesSerial"
log() { echo "$(date '+%H:%M:%S') $*"; }
die() { log "BLOCKER: $*"; log "JOB_FAIL"; exit "${2:-1}"; }

case "$DET_ROWS" in ""|*[!0-9,]*|,*|*,|*,,*) die "DET_ROWS=$DET_ROWS must be a comma list of row counts" 64 ;; esac
case "$DET_CONTEXTS" in ""|*[!0-9,]*) die "DET_CONTEXTS=$DET_CONTEXTS must be a comma list of token counts" 64 ;; esac
case "$SERVED_CONTEXTS" in *[!0-9,]*) die "SERVED_CONTEXTS=$SERVED_CONTEXTS must be a comma list of token counts" 64 ;; esac
case "$TRIALS" in ""|*[!0-9]*|0|1) die "TRIALS=$TRIALS must be at least 2 (identity across trials is part of the gate)" 64 ;; esac
case "$RUN_DETERMINISM$RUN_PARITY" in 00) die "RUN_DETERMINISM=0 and RUN_PARITY=0 leave nothing to run" 64 ;; 01|10|11) ;;
  *) die "RUN_DETERMINISM and RUN_PARITY must be 0 or 1" 64 ;; esac
[ -z "$SEED_SELF_CHECK_RUN" ] || echo "$SEED_SELF_CHECK_RUN" | grep -Eq '^[0-9]{8}T[0-9]{6}Z$' \
  || die "SEED_SELF_CHECK_RUN=$SEED_SELF_CHECK_RUN is not a run id" 64
IFS=, read -r -a DET_ROW_LIST <<< "$DET_ROWS"

# Served contexts whose 1-row text pass fence-a does not produce get a served-<ctx> pass.
HAS_ONE_ROW=0
for r in "${DET_ROW_LIST[@]}"; do [ "$r" = 1 ] && HAS_ONE_ROW=1; done
[ "$RUN_DETERMINISM" = 1 ] || HAS_ONE_ROW=0
EXTRA_SERVED=()
IFS=, read -r -a SERVED_LIST <<< "$SERVED_CONTEXTS"
for c in ${SERVED_LIST[@]+"${SERVED_LIST[@]}"}; do
  covered=0
  if [ "$HAS_ONE_ROW" = 1 ]; then
    case ",$DET_CONTEXTS," in *",$c,"*) covered=1 ;; esac
  fi
  [ "$covered" = 1 ] || EXTRA_SERVED+=("$c")
done

if [ "${EXACT_JOB_CHECK:-0}" = 1 ]; then
  echo "PLAN engine-tests FORK=$FORK filter=Qwen4ExpTests required=${ENGINE_REQUIRED_TESTS// /,} metallib=$METALLIB build=$ENGINE_TESTS_BUILD"
  [ "$RUN_DETERMINISM" = 0 ] || echo "PLAN fence-a CB_ROWS=$DET_ROWS CONTEXTS=$DET_CONTEXTS OUTPUTS=$OUTPUTS TRIALS=$TRIALS LAB_FENCE=1 SKIP_REFERENCE=1 seed=${SEED_SELF_CHECK_RUN:-fresh}"
  [ "$RUN_DETERMINISM" = 0 ] || echo "PLAN fence-b CB_ROWS=$DET_ROWS CONTEXTS=$DET_CONTEXTS OUTPUTS=$OUTPUTS TRIALS=$TRIALS LAB_FENCE=1 SKIP_REFERENCE=1 SKIP_BUILD=1 seed=fence-a"
  [ "$RUN_DETERMINISM" = 0 ] || echo "PLAN determinism rows=$DET_ROWS passes=fence-a,fence-b"
  if [ "$RUN_PARITY" = 1 ]; then
    for c in ${EXTRA_SERVED[@]+"${EXTRA_SERVED[@]}"}; do echo "PLAN served-$c CB_ROWS=1 CONTEXTS=$c OUTPUTS=$SERVED_STEPS TRIALS=1 SKIP_REFERENCE=1"; done
    echo "PLAN parity SERVED_CONTEXTS=${SERVED_CONTEXTS:-none} SERVED_STEPS=$SERVED_STEPS SKIP_BUILD=1"
  fi
  exit 0
fi

mkdir -p "$OUT"
log "JOB_START qwen4-exactness run=$RUN_ID commit=${COMMIT:-unknown} det_rows=$DET_ROWS det_contexts=$DET_CONTEXTS outputs=$OUTPUTS trials=$TRIALS served_contexts=${SERVED_CONTEXTS:-none} served_steps=$SERVED_STEPS seed=${SEED_SELF_CHECK_RUN:-fresh} determinism=$RUN_DETERMINISM parity=$RUN_PARITY"
FAILED=0
blocker() { log "BLOCKER: $*"; FAILED=1; }

# One sub-job; its end lines are renamed so only this job's JOB_PASS/JOB_FAIL decide the window.
step() {
  local name=$1; shift
  log "STEP $name start"
  env "$@" 2>&1 | while IFS= read -r line; do
    line=${line//JOB_START/STEP_START}; line=${line//JOB_PASS/STEP_PASS}; line=${line//JOB_FAIL/STEP_FAIL}
    printf '%s\n' "$line"
  done
  local rc=${PIPESTATUS[0]}
  log "STEP $name exit=$rc"
  return "$rc"
}

# 0. Engine tests on Metal; a failure ends the job before any model load.
for t in $ENGINE_REQUIRED_TESTS; do
  grep -q "func $t()" "$ENGINE_TESTS_FILE" 2>/dev/null \
    || die "FORK=$FORK has no Qwen4ExpTests.$t; set FORK_DIR=\$HOME/mlx-swift-lm-2448 (campaign/2448-qwen4-join-test)" 11
done
[ -f "$METALLIB" ] || die "no metallib at $METALLIB" 14
log "STEP engine-tests start fork=$FORK"
(
  XCODE_DEV=$HOME/Applications/Xcode.app/Contents/Developer
  [ -n "${DEVELOPER_DIR:-}" ] || [ ! -d "$XCODE_DEV" ] || export DEVELOPER_DIR=$XCODE_DEV
  cd "$FORK" || exit 14
  nice -n 10 swift build --build-tests --scratch-path "$ENGINE_TESTS_BUILD" > "$OUT/engine-tests-build.log" 2>&1 || exit 14
  # Xcode's build system makes one bundle per test target, the native one a single package bundle.
  bundle=$(ls -d "$ENGINE_TESTS_BUILD"/debug/MLXLMTests.xctest "$ENGINE_TESTS_BUILD"/debug/*PackageTests.xctest 2>/dev/null | head -n 1)
  [ -n "$bundle" ] && cp "$METALLIB" "$bundle/Contents/MacOS/mlx.metallib" || exit 15
  swift test --skip-build --scratch-path "$ENGINE_TESTS_BUILD" --filter Qwen4ExpTests > "$OUT/engine-tests.log" 2>&1
)
rc=$?
[ "$rc" != 14 ] || die "engine test build failed: $(tail -n 3 "$OUT/engine-tests-build.log" | tr '\n' ' ' | cut -c1-400)" 14
[ "$rc" != 15 ] || die "no test bundle under $ENGINE_TESTS_BUILD/debug for the metallib" 14
grep -E "Qwen4ExpTests test[A-Za-z0-9]+\]' (passed|failed)" "$OUT/engine-tests.log" | sed 's/^/STEP engine-tests /'
# Xcode's build system runs every test bundle, each with its own XCTest summary: count the cases.
passed=$(grep -cE "Qwen4ExpTests test[A-Za-z0-9]+\]' passed" "$OUT/engine-tests.log")
failed=$(grep -cE "Qwen4ExpTests test[A-Za-z0-9]+\]' failed" "$OUT/engine-tests.log")
log "STEP engine-tests exit=$rc passed=$passed failed=$failed"
missing=""
for t in $ENGINE_REQUIRED_TESTS; do
  grep -q "Qwen4ExpTests $t\]' passed" "$OUT/engine-tests.log" || missing="$missing $t"
done
if [ "$rc" != 0 ] || [ -n "$missing" ] || [ "$failed" != 0 ] \
   || grep -qE 'with [1-9][0-9]* failures?' "$OUT/engine-tests.log"; then
  die "engine tests failed (rc=$rc, not passed:${missing:- none}): $(grep -m1 -E 'error: .*Qwen4ExpTests' "$OUT/engine-tests.log" | cut -c1-400)" 1
fi

CB_COMMON=(CB_SLOTS="$CB_SLOTS" OUTPUTS="$OUTPUTS" SKIP_REFERENCE=1 LAB_FENCE=1)
BUILT=0
[ "${SKIP_BUILD:-0}" = 1 ] && BUILT=1
SEED_A=$CBRES/fence-a/serve/cb-self-check.json
if [ "$RUN_DETERMINISM" = 1 ]; then
  if step fence-a "${CB_COMMON[@]}" CB_PASS=fence-a CB_ROWS="$DET_ROWS" CONTEXTS="$DET_CONTEXTS" TRIALS="$TRIALS" \
       SKIP_BUILD="$BUILT" SEED_SELF_CHECK_RUN="$SEED_SELF_CHECK_RUN" bash "$HERE/job-qwen4-cb.sh"; then :
  else blocker "pass fence-a failed"; fi
  [ -x "$LAB/src/phase3-binary/.build-lab-qwen4/release/macprovider-cli" ] && BUILT=1
  [ "$BUILT" = 1 ] || die "no lab-harness build after pass fence-a" 14
  [ -s "$SEED_A" ] || die "pass fence-a stored no self-check verdict at $SEED_A; fence-b cannot serve the same slots" 11
  if step fence-b "${CB_COMMON[@]}" CB_PASS=fence-b CB_ROWS="$DET_ROWS" CONTEXTS="$DET_CONTEXTS" TRIALS="$TRIALS" \
       SKIP_BUILD=1 SEED_SELF_CHECK_FILE="$SEED_A" bash "$HERE/job-qwen4-cb.sh"; then :
  else blocker "pass fence-b failed"; fi
  /usr/bin/python3 -I "$HERE/cb_determinism.py" check --pass "fence-a=$CBRES/fence-a" --pass "fence-b=$CBRES/fence-b" \
    --rows "$DET_ROWS" --out-json "$OUT/determinism.json" --out-md "$OUT/determinism.md" | tee "$OUT/determinism.txt"
  [ "${PIPESTATUS[0]}" = 0 ] || blocker "$(grep -m1 '^DETERMINISM ' "$OUT/determinism.txt" | cut -c1-400)"
  # SPEC-039 qwen4_exp entry: attach probes (route batched) and the FR-CB10 self-check verdict of pass fence-a.
  grep -hE '^GRID_ROUTE(_FAIL)? |^ROUTE(_FAIL)? ' "$CBRES/fence-a/run.log" 2>/dev/null | sed 's/^/SPEC_EVIDENCE fence-a /'
  grep -hE 'event=paged_kv_attach |event=cb_self_check action=(measured|applied|ladder_ended)' "$CBRES/fence-a/serve/serve.err" 2>/dev/null \
    | cut -c1-400 | sed 's/^/SPEC_EVIDENCE fence-a /'
  log "SPEC_EVIDENCE fence-a self_check=${SEED_SELF_CHECK_RUN:+seeded from $SEED_SELF_CHECK_RUN (not fresh FR-CB10 evidence)}${SEED_SELF_CHECK_RUN:-fresh}"
fi

if [ "$RUN_PARITY" = 1 ]; then
  SERVED_JSONL=""
  [ "$HAS_ONE_ROW" = 1 ] && SERVED_JSONL=$CBRES/fence-a/provider.jsonl
  for c in ${EXTRA_SERVED[@]+"${EXTRA_SERVED[@]}"}; do
    seed=()
    if [ -s "$SEED_A" ]; then seed=(SEED_SELF_CHECK_FILE="$SEED_A")
    elif [ -n "$SEED_SELF_CHECK_RUN" ]; then seed=(SEED_SELF_CHECK_RUN="$SEED_SELF_CHECK_RUN"); fi
    if step "served-$c" "${CB_COMMON[@]}" CB_PASS="served-$c" CB_ROWS=1 CONTEXTS="$c" OUTPUTS="$SERVED_STEPS" TRIALS=1 \
         SKIP_BUILD="$BUILT" ${seed[@]+"${seed[@]}"} bash "$HERE/job-qwen4-cb.sh"; then :
    else blocker "pass served-$c failed"; fi
    BUILT=1
    SERVED_JSONL=${SERVED_JSONL:+$SERVED_JSONL,}$CBRES/served-$c/provider.jsonl
  done
  if step parity SKIP_BUILD="$BUILT" SERVED_CONTEXTS="$SERVED_CONTEXTS" SERVED_STEPS="$SERVED_STEPS" \
       SERVED_JSONL="$SERVED_JSONL" bash "$HERE/job-qwen4-parity.sh"; then :
  else blocker "parity step failed (gate or run): $(tail -n 1 "$RES/qwen4-parity/gates.txt" 2>/dev/null | cut -c1-300)"; fi
fi

{ grep -h '^DETERMINISM' "$OUT/determinism.txt" 2>/dev/null
  grep -h '^DIVERGENCE_VERDICT' "$RES/qwen4-parity/divergence.stdout" 2>/dev/null
  grep -h '^PARITY_' "$RES/qwen4-parity/gates.txt" 2>/dev/null; } > "$OUT/summary.txt"
[ "$FAILED" = 0 ] || { log "JOB_FAIL"; exit 1; }
log "JOB_PASS"
