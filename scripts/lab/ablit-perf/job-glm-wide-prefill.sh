#!/bin/bash
# Runs ON THE STUDIO from ~/lab-ablit-perf/job/ablit-perf/. Campaign #2451: GLM-5.3-Flash (abliterated
# build) wide prefill on the batching route. Goal metric: one-row TTFT at 4k and 16k context against
# oMLX; gate: greedy tokens identical to unmodified main (issue #2451 "The check" and "Gate").
#
# Steps:
#  1. fork proof (Metal): in FORK (the mlx-swift-lm worktree on campaign/2451-glm-wide-prefill,
#     rsynced by the launcher), `swift build --build-tests` then the GLM5NextTests wide-prefill tests
#     (bit identity of the sliced forward to separate forwards: logits, caches, following decode);
#     a failure stops the job before any model load (SKIP_FORK_TESTS=1 skips);
#  2. two lab-harness release builds, each in its own build path, the release metallib beside each:
#     main = MAIN_SRC (the launcher's `git archive` of the campaign's merge-base with origin/main) on
#     its pinned mlx-swift-lm; wide = SRC (the campaign tree) with mlx-swift-lm replaced by FORK
#     (`swift package edit`, this build path only);
#  3. the CB tuple of the signed policy entry for zai-org/glm-5.3-flash-uncensored (job.sh cb_extra);
#  4. three scripts/lab/parity-grid/run-grid.sh passes in one session, control/candidate/control
#     (AGENTS.md swarm rule 3), each its own serve on the production route (`--no-autotune-candidate
#     --model-id --model-sha256 --config-extra cb-tuple.yaml --cb auto --expect-route batched
#     --rows 1`), grid CONTEXTS (4k,16k) x OUTPUTS (128,512) x TRIALS (3): main-a (main build,
#     --skip-reference), wide (wide build, then the oMLX reference from GLM_OMLX_DIR and compare;
#     SKIP_REFERENCE=1 drops the reference), main-b (main build, --skip-reference);
#  5. wide_prefill_gate.py: tokens of wide and main-b identical to main-a per cell, trial and row
#     (text, reasoning, completion and prompt token counts), TTFT per run, change against each
#     control, oMLX ratio, KEEP/REVERT verdict (gate.md / gate.json).
#
# Results: ~/lab-ablit-perf/results/<run>/glm-wide-prefill/{main-a,wide,main-b}/ (run-grid outputs),
# gate.md, gate.json, identity-main.sha256, identity-wide.sha256, build-*.log, fork-tests.log.
# Env: GLM_PATH (snapshot dir; default the lab clone, else the provider-store snapshot, read only),
# GLM_OMLX_DIR (oMLX install dir with omlx-venv/ and omlx-src/; required unless SKIP_REFERENCE=1),
# CONTEXTS OUTPUTS TRIALS FORK MAIN_SRC METALLIB SKIP_BUILD SKIP_FORK_TESTS SKIP_REFERENCE SERVE_ENV
# SEED_SELF_CHECK_RUN (a run id whose glm-wide-prefill/main-a/serve/cb-self-check.json seeds every
# serve; a verdict whose key does not match a build is ignored and its self-check runs).
# WIDE_JOB_CHECK=1: validate the knobs, print the three run-grid argvs and exit 0 before touching
# anything (the unit test). Every failure prints `BLOCKER:`; the job ends with JOB_PASS (exit 0, the
# token gate passed; the speed verdict is a finding) or JOB_FAIL.
set -u
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
LAB=$HOME/lab-ablit-perf
JOB=$LAB/job
GRID=$JOB/parity-grid
SRC=$LAB/src/phase3-binary
MAIN_SRC=${MAIN_SRC:-$LAB/src-main/phase3-binary}
FORK=${FORK:-$LAB/mlx-swift-lm-2409}
STORE="$HOME/Library/Application Support/macprovider/models"
RUN_ID=${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}
NAME=glm53-flash-uncensored
RES=$LAB/results/$RUN_ID/glm-wide-prefill
GLM_ID=zai-org/glm-5.3-flash-uncensored
GLM_SHA256=242f8fcfd34d4ecfd62180c1767f910bda925216948772126dc98c673d1c8919
GLM_PATH=${GLM_PATH:-$LAB/models/GLM-5.3-Flash-UNCENSORED-mlx-oQ4e-DFlash2}
GLM_OMLX_DIR=${GLM_OMLX_DIR:-}
CONTEXTS=${CONTEXTS:-4k,16k}
OUTPUTS=${OUTPUTS:-128,512}
TRIALS=${TRIALS:-3}
SKIP_REFERENCE=${SKIP_REFERENCE:-0}
SKIP_FORK_TESTS=${SKIP_FORK_TESTS:-0}
SEED_SELF_CHECK_RUN=${SEED_SELF_CHECK_RUN:-}
SERVE_ENV=${SERVE_ENV:-}
METALLIB=${METALLIB:-/Applications/Malibu.app/Contents/MacOS/mlx.metallib}
MAIN_BIN=$MAIN_SRC/.build-lab-main/release
WIDE_BIN=$SRC/.build-lab-wide/release
log() { echo "$(date '+%H:%M:%S') $*"; }
die() { log "BLOCKER: $*"; log "JOB_FAIL"; exit "${2:-1}"; }

case "$CONTEXTS" in ""|*[!A-Za-z0-9,]*) die "CONTEXTS=$CONTEXTS must be a comma list of context names or token counts" 64 ;; esac
case "$OUTPUTS" in ""|*[!0-9,]*) die "OUTPUTS=$OUTPUTS must be a comma list of token counts" 64 ;; esac
case ",$OUTPUTS," in *,512,*) ;; *) die "OUTPUTS=$OUTPUTS must include 512 (the gate's cells)" 64 ;; esac
case "$TRIALS" in [1-9]) ;; *) die "TRIALS=$TRIALS must be 1..9" 64 ;; esac
case "$SKIP_REFERENCE" in 0|1) ;; *) die "SKIP_REFERENCE=$SKIP_REFERENCE must be 0 or 1" 64 ;; esac
case "$SKIP_FORK_TESTS" in 0|1) ;; *) die "SKIP_FORK_TESTS=$SKIP_FORK_TESTS must be 0 or 1" 64 ;; esac
[ "$SKIP_REFERENCE" = 1 ] || [ -n "$GLM_OMLX_DIR" ] || die "GLM_OMLX_DIR is unset (the oMLX install dir); or SKIP_REFERENCE=1" 64
[ -z "$SEED_SELF_CHECK_RUN" ] || echo "$SEED_SELF_CHECK_RUN" | grep -Eq '^[0-9]{8}T[0-9]{6}Z$' || die "SEED_SELF_CHECK_RUN=$SEED_SELF_CHECK_RUN is not a run id" 64
echo "$SERVE_ENV" | grep -Eq '^([A-Za-z_][A-Za-z0-9_]*=[A-Za-z0-9_.,:/=-]*( |$))*$' || die "SERVE_ENV=$SERVE_ENV must be space-separated K=V pairs" 64

model_dir() {  # the lab clone, else the provider-store snapshot of the catalog artifact (read only)
  [ -f "$GLM_PATH/config.json" ] && { echo "$GLM_PATH"; return; }
  local d
  for d in "$STORE/Solstice-AI--GLM-5.3-Flash-UNCENSORED-mlx-oQ4e-DFlash2"/*/"$GLM_SHA256"; do
    [ -f "$d/config.json" ] && { echo "$d"; return; }
  done
  echo "$GLM_PATH"
}
MODEL=$(model_dir)

# pass_args PASS BIN: the run-grid argv of one pass (GARGS).
pass_args() {
  GARGS=(--model-path "$MODEL" --model-id "$GLM_ID" --model-sha256 "$GLM_SHA256" --model-name "$NAME"
         --bin-dir "$2" --out-dir "$RES/$1" --cb auto --no-autotune-candidate --rows 1
         --contexts "$CONTEXTS" --outputs "$OUTPUTS" --trials "$TRIALS"
         --config-extra "$RES/cb-tuple.yaml" --expect-route batched)
  if [ "$1" = wide ] && [ "$SKIP_REFERENCE" = 0 ]; then
    GARGS+=(--python /usr/bin/python3 --reference omlx --ref-arg --omlx-dir --ref-arg "$GLM_OMLX_DIR"
            --ref-arg --state-root --ref-arg "$LAB/omlx-state")
  else
    GARGS+=(--skip-reference --skip-compare)
  fi
  [ -z "$SERVE_ENV" ] || GARGS+=(--serve-env "$SERVE_ENV")
  [ -z "$SEED_SELF_CHECK_RUN" ] || GARGS+=(--seed-self-check "$LAB/results/$SEED_SELF_CHECK_RUN/glm-wide-prefill/main-a/serve/cb-self-check.json")
}
if [ "${WIDE_JOB_CHECK:-0}" = 1 ]; then
  for p in main-a wide main-b; do
    case $p in wide) pass_args "$p" "$WIDE_BIN" ;; *) pass_args "$p" "$MAIN_BIN" ;; esac
    printf 'GRID_ARGS_%s' "$p"; printf ' %s' "${GARGS[@]}"; echo
  done
  printf 'FORK_TEST_FILTER GLM5NextTests/testWidePrefill\n'
  exit 0
fi

mkdir -p "$RES"
log "JOB_START glm-wide-prefill run=$RUN_ID commit=${COMMIT:-unknown} model=$MODEL fork=$FORK main_src=$MAIN_SRC contexts=$CONTEXTS outputs=$OUTPUTS trials=$TRIALS skip_reference=$SKIP_REFERENCE${SEED_SELF_CHECK_RUN:+ seed=$SEED_SELF_CHECK_RUN}${SERVE_ENV:+ serve_env=$SERVE_ENV}"
if lsof -nP -iTCP:8080 -sTCP:LISTEN -t >/dev/null 2>&1; then die "a server listens on :8080; the Studio is not paused" 3; fi
launchctl print "gui/$(id -u)/live.malibu.provider" >/dev/null 2>&1 && die "live.malibu.provider is loaded" 3
pgrep -f "[m]acprovider-cli serve" >/dev/null 2>&1 && die "a macprovider-cli serve process runs" 3
[ -f "$MODEL/config.json" ] || die "no GLM snapshot at $GLM_PATH or in the provider store" 11
grep -q glm5NextPrefillSlicesKey "$FORK/Libraries/MLXLLM/Models/GLM5Next.swift" 2>/dev/null \
  || die "no fork with glm5NextPrefillSlicesKey at FORK=$FORK (rsync the campaign/2451-glm-wide-prefill worktree there)" 11
[ -f "$MAIN_SRC/Package.swift" ] || die "no main tree at MAIN_SRC=$MAIN_SRC" 11
if [ "$SKIP_REFERENCE" = 0 ]; then
  [ -x "$GLM_OMLX_DIR/omlx-venv/bin/python" ] || die "no oMLX venv at $GLM_OMLX_DIR/omlx-venv" 11
  "$GLM_OMLX_DIR/omlx-venv/bin/python" -c 'import importlib.metadata as m
for p in ("omlx", "mlx", "mlx-lm", "mlx-vlm"):
    try: print("REF_VERSION", p, m.version(p))
    except m.PackageNotFoundError: pass'
fi
if [ -n "$SEED_SELF_CHECK_RUN" ]; then
  [ -s "$LAB/results/$SEED_SELF_CHECK_RUN/glm-wide-prefill/main-a/serve/cb-self-check.json" ] \
    || die "SEED_SELF_CHECK_RUN: no cb-self-check.json at $LAB/results/$SEED_SELF_CHECK_RUN/glm-wide-prefill/main-a/serve" 11
fi
[ -f "$METALLIB" ] || die "no metallib at $METALLIB" 14
METALLIB_SHA=$(shasum -a 256 "$METALLIB" | cut -d' ' -f1)

# 1. Fork proof: bit identity of the sliced forward, before any model load.
if [ "$SKIP_FORK_TESTS" = 0 ]; then
  export DEVELOPER_DIR=${DEVELOPER_DIR:-$HOME/Applications/Xcode.app/Contents/Developer}
  log "FORK_TEST build"
  (cd "$FORK" && nice -n 10 swift build --build-tests --build-system native) > "$RES/fork-build.log" 2>&1 \
    || die "fork test build failed: $(grep -m3 'error:' "$RES/fork-build.log" | tr '\n' ' ')" 12
  (cd "$FORK" && swift test --build-system native --skip-build --filter 'GLM5NextTests/testWidePrefill') \
    > "$RES/fork-tests.log" 2>&1
  rc=$?
  grep -E "Test Case .*(passed|failed)|Executed .* tests" "$RES/fork-tests.log" | sed 's/^/FORK_TEST /'
  grep -q "Executed 2 tests, with 0 failures" "$RES/fork-tests.log" && [ "$rc" = 0 ] \
    || die "fork wide-prefill tests did not pass (rc=$rc, fork-tests.log): the sliced forward is not proven exact" 12
  unset DEVELOPER_DIR
fi

# 2. Builds: main on its pin, wide on the fork.
if [ "${SKIP_BUILD:-0}" != 1 ]; then
  log "BUILD_START main"
  (cd "$MAIN_SRC" && nice -n 10 swift build -c release --product macprovider-cli --build-path .build-lab-main \
    -Xswiftc -DMACPROVIDER_LAB_HARNESS) > "$RES/build-main.log" 2>&1 \
    || die "main build failed: $(tail -n 3 "$RES/build-main.log" | tr '\n' ' ')" 14
  log "BUILD_START wide"
  (cd "$SRC" && swift package --build-path .build-lab-wide unedit mlx-swift-lm > /dev/null 2>&1
   swift package --build-path .build-lab-wide edit mlx-swift-lm --path "$FORK" \
     && nice -n 10 swift build -c release --product macprovider-cli --build-path .build-lab-wide \
       -Xswiftc -DMACPROVIDER_LAB_HARNESS) > "$RES/build-wide.log" 2>&1 \
    || die "wide build failed: $(tail -n 3 "$RES/build-wide.log" | tr '\n' ' ')" 14
fi
for side in main wide; do
  bin=$MAIN_BIN; [ $side = wide ] && bin=$WIDE_BIN
  [ -x "$bin/macprovider-cli" ] || die "no $side lab-harness binary at $bin" 14
  cp "$METALLIB" "$bin/mlx.metallib" || die "metallib copy failed" 14
  shasum -a 256 "$bin/macprovider-cli" "$bin/mlx.metallib" > "$RES/identity-$side.sha256"
  log "BUILD_DONE $side $("$bin/macprovider-cli" --version 2>&1 | head -n 1) cli_sha256=$(cut -c1-16 "$RES/identity-$side.sha256" | head -n 1)"
done
cmp -s "$MAIN_BIN/macprovider-cli" "$WIDE_BIN/macprovider-cli" && die "the main and wide binaries are identical: the fork did not reach the wide build" 14

# 3. The signed CB entry's tuple (job.sh cb_extra): the production batching route.
/usr/bin/python3 -I - "$JOB/catalog/continuous-batching-policy.json" "$GLM_ID" "$METALLIB_SHA" > "$RES/cb-tuple.yaml" 2> "$RES/cb-tuple.err" <<'PY' \
  || die "CB tuple: $(cat "$RES/cb-tuple.err")" 11
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

# 4. Control, candidate, control.
for p in main-a wide main-b; do
  bin=$MAIN_BIN; [ $p = wide ] && bin=$WIDE_BIN
  pass_args "$p" "$bin"
  mkdir -p "$RES/$p"
  log "GRID_START $p bin=$bin"
  bash "$GRID/run-grid.sh" "${GARGS[@]}" > "$RES/$p/run.log" 2>&1
  rc=$?
  grep -E '^(CB_WARMUP_DONE|CB_WARMUP_STALL|CB_WARMUP_FAIL|ROUTE|ROUTE_FAIL|REFERENCE_SANE|REFERENCE_SUSPECT|REFERENCE_FAIL) ' \
    "$RES/$p/run.log" | sed "s/^/GRID_$(echo "$p" | tr 'a-z-' 'A-Z_') /"
  log "GRID_DONE $p rc=$rc"
  grep -q '^ROUTE_FAIL ' "$RES/$p/run.log" && die "$p: ROUTE_FAIL, the serve was serial: not the batching route" 10
  [ -s "$RES/$p/provider.jsonl" ] || die "$p: no provider rows (rc=$rc): $(tail -n 3 "$RES/$p/run.log" | tr '\n' ' ')" 15
  case "$p:$rc" in main-a:0|main-b:0|wide:0|wide:1) ;;
    wide:8|wide:9) log "BLOCKER: the oMLX reference failed or is suspect (rc=$rc); the token gate still runs, the oMLX columns are empty" ;;
    *) die "$p: grid rc=$rc: $(tail -n 3 "$RES/$p/run.log" | tr '\n' ' ')" 15 ;;
  esac
  [ $p != wide ] || [ ! -f "$RES/$p/summary.md" ] || sed -n '/^| model/,/^$/p' "$RES/$p/summary.md"
done

# 5. Gate.
REF_ARGS=()
[ ! -s "$RES/wide/reference.jsonl" ] || REF_ARGS=(--reference "$RES/wide/reference.jsonl")
/usr/bin/python3 -I "$JOB/ablit-perf/wide_prefill_gate.py" --control-a "$RES/main-a/provider.jsonl" \
  --candidate "$RES/wide/provider.jsonl" --control-b "$RES/main-b/provider.jsonl" ${REF_ARGS[@]+"${REF_ARGS[@]}"} \
  --out-md "$RES/gate.md" --out-json "$RES/gate.json" > "$RES/gate.stdout" 2> "$RES/gate.stderr"
rc=$?
cat "$RES/gate.md" 2>/dev/null
cat "$RES/gate.stdout"
[ "$rc" = 2 ] && die "gate input: $(cat "$RES/gate.stderr")" 16
[ "$rc" = 0 ] || die "greedy tokens of the wide build differ from main (gate.md)" 17
log "JOB_PASS"
