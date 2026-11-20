#!/bin/bash
# Runs ON THE STUDIO from ~/lab-ablit-perf/job/ablit-perf/. Campaign #2409 profile: where the
# one-row serial TTFT of the abliterated GLM-5.3-Flash goes on long prompts (baseline: 30-38%
# behind the oMLX reference at ~3.7k and ~14k tokens), as shares of the goal metric, before any fix.
#
# Steps:
#  1. matmul peak (matmul_peak.py, an MLX venv, before the model loads): best bf16 GEMM and 4-bit
#     quantized matmul TFLOP/s, for the prefill ceiling;
#  2. the reference's prefill chunk: mlx-lm generate_step's prefill_step_size default from the venv,
#     and, when GLM_OMLX_DIR holds omlx-src/, every prefill step/chunk setting oMLX's source names
#     (reference-chunk.txt); the reference TTFT itself is the baseline's (no rerun, AGENTS.md rule 2);
#  3. lab-harness release build of src/phase3-binary in the qwen4 jobs' build path with the
#     mlx-swift-lm dependency replaced by FORK (the #2409 fork with LabSectionTimer) and
#     -DMACPROVIDER_SECTION_TIMING;
#  4. `macprovider-cli prefill-profile` (PrefillProfileCommand.swift: served TTFT per chunk size,
#     the synchronized per-chunk split with and without buffer-cache clears, section times) on
#     PROMPT_TOKENS (default 3673,14126: the baseline's 4k and 16k cells) at STEP_SIZES (default
#     512 = serve's default, 2048), PROFILE_RUNS runs each; the prompt is this tree's
#     ModelRuntime.swift, tokenized and repeated to length;
#  5. prefill_profile_report.py: profile.md / profile-summary.json (tables in its header).
#
# Results: ~/lab-ablit-perf/results/<run>/glm-prefill-profile/{peak.json,reference-chunk.txt,
# prefill-profile.json,prefill-profile.stderr,profile.md,profile-summary.json,identity.sha256,build.log}.
# Env: GLM_PATH (snapshot dir; default the lab clone, else the provider-store snapshot, read only),
# FORK, PROMPT_TOKENS, STEP_SIZES, PROFILE_RUNS, GLM_OMLX_DIR, METALLIB, SKIP_BUILD,
# REFERENCE_TTFT / GRID_TTFT (seconds per prompt length, default the baseline's).
# PREFILL_JOB_CHECK=1: validate the knobs, print the profile and report argv and exit 0 before touching
# anything (the unit test). Every failure prints `BLOCKER:`; the job ends with JOB_PASS or JOB_FAIL.
set -u
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
LAB=$HOME/lab-ablit-perf
JOB=$LAB/job
SRC=$LAB/src/phase3-binary
STORE="$HOME/Library/Application Support/macprovider/models"
RUN_ID=${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}
RES=$LAB/results/$RUN_ID/glm-prefill-profile
GLM_SHA256=242f8fcfd34d4ecfd62180c1767f910bda925216948772126dc98c673d1c8919
GLM_PATH=${GLM_PATH:-$LAB/models/GLM-5.3-Flash-UNCENSORED-mlx-oQ4e-DFlash2}
FORK=${FORK:-$LAB/mlx-swift-lm-2409}
PROMPT_TOKENS=${PROMPT_TOKENS:-3673,14126}
STEP_SIZES=${STEP_SIZES:-512,2048}
PROFILE_RUNS=${PROFILE_RUNS:-3}
GLM_OMLX_DIR=${GLM_OMLX_DIR:-}
REFERENCE_TTFT=${REFERENCE_TTFT:-3673=8.00,14126=32.76}
GRID_TTFT=${GRID_TTFT:-3673=11.02,14126=42.49}
METALLIB=${METALLIB:-/Applications/Malibu.app/Contents/MacOS/mlx.metallib}
BUILD=.build-lab-qwen4
BIN=$SRC/$BUILD/release
log() { echo "$(date '+%H:%M:%S') $*"; }
die() { log "BLOCKER: $*"; log "JOB_FAIL"; exit "${2:-1}"; }

case "$PROMPT_TOKENS" in ""|*[!0-9,]*|,*|*,|*,,*) die "PROMPT_TOKENS=$PROMPT_TOKENS must be a comma list of token counts" 64 ;; esac
case "$STEP_SIZES" in ""|*[!0-9,]*|,*|*,|*,,*) die "STEP_SIZES=$STEP_SIZES must be a comma list of step sizes" 64 ;; esac
case "$PROFILE_RUNS" in [1-9]) ;; *) die "PROFILE_RUNS=$PROFILE_RUNS must be 1..9" 64 ;; esac
IFS=, read -r -a _p <<< "$PROMPT_TOKENS"
for n in "${_p[@]}"; do [ "$n" -ge 16 ] && [ "$n" -le 65536 ] || die "PROMPT_TOKENS: $n is not 16..65536" 64; done
IFS=, read -r -a _s <<< "$STEP_SIZES"
for n in "${_s[@]}"; do [ "$n" -ge 16 ] && [ "$n" -le 16384 ] || die "STEP_SIZES: $n is not 16..16384" 64; done
for pairs in "$REFERENCE_TTFT" "$GRID_TTFT"; do
  echo "$pairs" | grep -Eq '^([0-9]+=[0-9.]+)(,[0-9]+=[0-9.]+)*$|^$' || die "REFERENCE_TTFT/GRID_TTFT=$pairs must be tokens=seconds pairs" 64
done

model_dir() {  # the lab clone, else the provider-store snapshot of the catalog artifact (read only)
  [ -f "$GLM_PATH/config.json" ] && { echo "$GLM_PATH"; return; }
  local d
  for d in "$STORE/Solstice-AI--GLM-5.3-Flash-UNCENSORED-mlx-oQ4e-DFlash2"/*/"$GLM_SHA256"; do
    [ -f "$d/config.json" ] && { echo "$d"; return; }
  done
  echo "$GLM_PATH"
}
MODEL=$(model_dir)
PROFILE_ARGS=(prefill-profile --model-dir "$MODEL" --prompt-text "$SRC/Sources/macprovider-cli/ModelRuntime.swift"
              --prompt-tokens "$PROMPT_TOKENS" --step-sizes "$STEP_SIZES" --runs "$PROFILE_RUNS"
              --output "$RES/prefill-profile.json")
REPORT_ARGS=(--profile "$RES/prefill-profile.json" --peak "$RES/peak.json" --config "$MODEL/config.json"
             --out-md "$RES/profile.md" --out-json "$RES/profile-summary.json"
             --reference-ttft "$REFERENCE_TTFT" --grid-ttft "$GRID_TTFT")
if [ "${PREFILL_JOB_CHECK:-0}" = 1 ]; then
  printf 'PROFILE_ARGS'; printf ' %s' "${PROFILE_ARGS[@]}"; echo
  printf 'REPORT_ARGS'; printf ' %s' "${REPORT_ARGS[@]}"; echo
  printf 'BUILD_FLAGS -DMACPROVIDER_LAB_HARNESS -DMACPROVIDER_SECTION_TIMING build_path=%s fork=%s\n' "$BUILD" "$FORK"
  exit 0
fi

rm -rf "$RES" && mkdir -p "$RES"
log "JOB_START glm-prefill-profile run=$RUN_ID commit=${COMMIT:-unknown} model=$MODEL fork=$FORK prompts=$PROMPT_TOKENS steps=$STEP_SIZES runs=$PROFILE_RUNS"
if lsof -nP -iTCP:8080 -sTCP:LISTEN -t >/dev/null 2>&1; then die "a server listens on :8080; the Studio is not paused" 3; fi
launchctl print "gui/$(id -u)/live.malibu.provider" >/dev/null 2>&1 && die "live.malibu.provider is loaded" 3
pgrep -f "[m]acprovider-cli serve" >/dev/null 2>&1 && die "a macprovider-cli serve process runs" 3
[ -f "$MODEL/config.json" ] || die "no GLM snapshot at $GLM_PATH or in the provider store" 11
[ -f "$FORK/Libraries/MLXLMCommon/LabSectionTimer.swift" ] \
  || die "no fork checkout with LabSectionTimer at FORK=$FORK (rsync the campaign/2409-qwen4-exp-batch worktree there)" 11
log "FORK $(git -C "$FORK" rev-parse HEAD 2>/dev/null || echo no-git)"

# 1. Matmul peak, before the model is in memory. Any lab venv with mlx; else job.sh's mlx-lm venv.
PY=""
for v in "$LAB/venv-lm" "$LAB/venv-vlm" "$LAB/venv-lm-qwen4"; do
  "$v/bin/python" -I -c "import mlx.core" > /dev/null 2>&1 && { PY=$v/bin/python; break; }
done
if [ -z "$PY" ]; then
  PY312=$(command -v python3.12 || echo /opt/homebrew/bin/python3.12)
  [ -x "$PY312" ] || die "python3.12 not found (the mlx wheels need it)" 11
  "$PY312" -m venv "$LAB/venv-lm" && "$LAB/venv-lm/bin/pip" install -q "mlx-lm==0.32.2" "mlx==0.32.4" \
    > "$RES/venv.log" 2>&1 || die "venv: $(tail -n 2 "$RES/venv.log" | tr '\n' ' ')" 11
  PY=$LAB/venv-lm/bin/python
fi
"$PY" -I "$JOB/ablit-perf/matmul_peak.py" --out "$RES/peak.json" > "$RES/peak.stdout" 2> "$RES/peak.stderr" \
  || die "matmul peak: $(tail -n 2 "$RES/peak.stderr" | tr '\n' ' ')" 12
cat "$RES/peak.stdout"
[ -s "$RES/peak.json" ] || die "matmul peak wrote no peak.json: $(tail -n 2 "$RES/peak.stderr" | tr '\n' ' ')" 12

# 2. The reference's prefill chunk (recorded, not rerun).
{
  "$PY" -I -c 'import inspect, importlib.metadata as m
from mlx_lm.generate import generate_step
print("mlx-lm", m.version("mlx-lm"), "generate_step prefill_step_size default",
      inspect.signature(generate_step).parameters["prefill_step_size"].default)' 2>&1
  if [ -n "$GLM_OMLX_DIR" ] && [ -d "$GLM_OMLX_DIR/omlx-src" ]; then
    echo "oMLX source $GLM_OMLX_DIR/omlx-src $(git -C "$GLM_OMLX_DIR/omlx-src" rev-parse HEAD 2>/dev/null)"
    grep -rnE 'prefill_step_size|prefill_chunk|chunked_prefill|prefill_batch_size|max_prefill' --include='*.py' \
      "$GLM_OMLX_DIR/omlx-src" | grep -v '/tests\?/' | head -n 40
  else
    echo "oMLX source not given (GLM_OMLX_DIR); its chunk is not recorded"
  fi
} > "$RES/reference-chunk.txt"
REF_CHUNK=$(head -n 1 "$RES/reference-chunk.txt" | cut -c1-160)
log "REFERENCE_CHUNK $REF_CHUNK; oMLX lines: $(($(wc -l < "$RES/reference-chunk.txt") - 2))"

# 3. Build against the fork with the section timer compiled in.
if [ "${SKIP_BUILD:-0}" != 1 ]; then
  log "BUILD start"
  (cd "$SRC" && swift package --build-path "$BUILD" unedit mlx-swift-lm > /dev/null 2>&1
   swift package --build-path "$BUILD" edit mlx-swift-lm --path "$FORK" \
     && nice -n 10 swift build -c release --product macprovider-cli --build-path "$BUILD" \
          -Xswiftc -DMACPROVIDER_LAB_HARNESS -Xswiftc -DMACPROVIDER_SECTION_TIMING) \
    > "$RES/build.log" 2>&1 || die "swift build failed: $(tail -n 3 "$RES/build.log" | tr '\n' ' ')" 14
fi
[ -x "$BIN/macprovider-cli" ] || die "no lab-harness binary at $BIN" 14
[ -f "$METALLIB" ] || die "no metallib at $METALLIB" 14
cp "$METALLIB" "$BIN/mlx.metallib" || die "metallib copy failed" 14
shasum -a 256 "$BIN/macprovider-cli" "$BIN/mlx.metallib" > "$RES/identity.sha256"
log "BUILD done $("$BIN/macprovider-cli" --version 2>&1 | head -n 1) cli_sha256=$(cut -c1-16 "$RES/identity.sha256" | head -n 1)"

# 4. The profile.
log "PROFILE_START"
"$BIN/macprovider-cli" "${PROFILE_ARGS[@]}" > "$RES/prefill-profile.stdout" 2> "$RES/prefill-profile.stderr"
rc=$?
grep '^prefill-profile: ' "$RES/prefill-profile.stderr" | sed 's/^/PROFILE_ /'
[ "$rc" = 0 ] && [ -s "$RES/prefill-profile.json" ] || die "prefill-profile exit $rc: $(tail -n 3 "$RES/prefill-profile.stderr" | tr '\n' ' ')" 15

# 5. Tables.
/usr/bin/python3 -I "$JOB/ablit-perf/prefill_profile_report.py" "${REPORT_ARGS[@]}" --reference-chunk "$REF_CHUNK" \
  > "$RES/report.stdout" 2> "$RES/report.stderr" || die "report: $(tail -n 2 "$RES/report.stderr" | tr '\n' ' ')" 16
cat "$RES/profile.md"
grep -q 'First tokens agree across passes at .*: NO' "$RES/profile.md" \
  && die "the profile's passes disagree on the first token; its timings are not of the served computation" 17
log "JOB_PASS"
