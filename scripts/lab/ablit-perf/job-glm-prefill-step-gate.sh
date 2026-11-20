#!/bin/bash
# Runs ON THE STUDIO from ~/lab-ablit-perf/job/ablit-perf/. Campaign #2409 gate for the GLM serial
# prefill step candidate (glm5_next serial prefill in steps of 2048 instead of 512). The candidate
# FAILED this gate (greedy tokens diverge, results/20261119T131711Z) and was reverted in 4e04553b6,
# so on this tree the default-step check fails by design; rerun only against a tree that sets 2048:
# one lab-harness build of this tree against the pinned mlx-swift-lm (no fork), one model load, then
#  - gate: one row, keyless serial path, prompts PROMPT_TOKENS (default 3673,14126), each run greedy-
#    decodes GENERATE_TOKENS (default 512) tokens at step 512 and at step 2048; every token of every
#    run must agree within a step and across steps, and serve's step for the model with
#    prefill_step_size unset must be 2048;
#  - measure: time to first token of the same runs, PROFILE_RUNS (default 3) per step and prompt,
#    and the MLX peak per step.
# The batching path is unchanged (its glm5_next ceiling is already 2048), so no multi-row cell.
#
# Steps: build (job.sh's .build-lab-harness path, -DMACPROVIDER_LAB_HARNESS); `macprovider-cli
# prefill-profile --served-only --generate-tokens GENERATE_TOKENS` (PrefillProfileCommand.swift);
# prefill_step_gate.py -> gate.md / gate.json. The prompt is this tree's ModelRuntime.swift,
# tokenized and repeated to length, as in job-glm-prefill-profile.sh.
#
# Results: ~/lab-ablit-perf/results/<run>/glm-prefill-step-gate/{prefill-profile.json,
# prefill-profile.stderr,gate.md,gate.json,identity.sha256,build.log}.
# Env: GLM_PATH (snapshot dir; default the lab clone, else the provider-store snapshot, read only),
# PROMPT_TOKENS, PROFILE_RUNS, GENERATE_TOKENS, METALLIB, SKIP_BUILD.
# PREFILL_JOB_CHECK=1: validate the knobs, print the profile and gate argv and exit 0 before touching
# anything (the unit test). Every failure prints `BLOCKER:`; the job ends with JOB_PASS or JOB_FAIL.
set -u
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
LAB=$HOME/lab-ablit-perf
JOB=$LAB/job
SRC=$LAB/src/phase3-binary
STORE="$HOME/Library/Application Support/macprovider/models"
RUN_ID=${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}
RES=$LAB/results/$RUN_ID/glm-prefill-step-gate
GLM_SHA256=242f8fcfd34d4ecfd62180c1767f910bda925216948772126dc98c673d1c8919
GLM_PATH=${GLM_PATH:-$LAB/models/GLM-5.3-Flash-UNCENSORED-mlx-oQ4e-DFlash2}
PROMPT_TOKENS=${PROMPT_TOKENS:-3673,14126}
PROFILE_RUNS=${PROFILE_RUNS:-3}
GENERATE_TOKENS=${GENERATE_TOKENS:-512}
STEP_SIZES=512,2048
EXPECT_DEFAULT_STEP=2048
METALLIB=${METALLIB:-/Applications/Malibu.app/Contents/MacOS/mlx.metallib}
BUILD=.build-lab-harness
BIN=$SRC/$BUILD/release
log() { echo "$(date '+%H:%M:%S') $*"; }
die() { log "BLOCKER: $*"; log "JOB_FAIL"; exit "${2:-1}"; }

case "$PROMPT_TOKENS" in ""|*[!0-9,]*|,*|*,|*,,*) die "PROMPT_TOKENS=$PROMPT_TOKENS must be a comma list of token counts" 64 ;; esac
case "$PROFILE_RUNS" in [1-9]) ;; *) die "PROFILE_RUNS=$PROFILE_RUNS must be 1..9" 64 ;; esac
case "$GENERATE_TOKENS" in ""|*[!0-9]*) die "GENERATE_TOKENS=$GENERATE_TOKENS must be 2..4096" 64 ;; esac
[ "$GENERATE_TOKENS" -ge 2 ] && [ "$GENERATE_TOKENS" -le 4096 ] || die "GENERATE_TOKENS=$GENERATE_TOKENS must be 2..4096" 64
IFS=, read -r -a _p <<< "$PROMPT_TOKENS"
for n in "${_p[@]}"; do [ "$n" -ge 16 ] && [ "$n" -le 65536 ] || die "PROMPT_TOKENS: $n is not 16..65536" 64; done

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
              --generate-tokens "$GENERATE_TOKENS" --served-only --output "$RES/prefill-profile.json")
GATE_ARGS=(--profile "$RES/prefill-profile.json" --expect-default-step "$EXPECT_DEFAULT_STEP"
           --out-md "$RES/gate.md" --out-json "$RES/gate.json")
if [ "${PREFILL_JOB_CHECK:-0}" = 1 ]; then
  printf 'PROFILE_ARGS'; printf ' %s' "${PROFILE_ARGS[@]}"; echo
  printf 'GATE_ARGS'; printf ' %s' "${GATE_ARGS[@]}"; echo
  printf 'BUILD_FLAGS -DMACPROVIDER_LAB_HARNESS build_path=%s\n' "$BUILD"
  exit 0
fi

rm -rf "$RES" && mkdir -p "$RES"
log "JOB_START glm-prefill-step-gate run=$RUN_ID commit=${COMMIT:-unknown} model=$MODEL prompts=$PROMPT_TOKENS steps=$STEP_SIZES runs=$PROFILE_RUNS generate=$GENERATE_TOKENS"
if lsof -nP -iTCP:8080 -sTCP:LISTEN -t >/dev/null 2>&1; then die "a server listens on :8080; the Studio is not paused" 3; fi
launchctl print "gui/$(id -u)/live.malibu.provider" >/dev/null 2>&1 && die "live.malibu.provider is loaded" 3
pgrep -f "[m]acprovider-cli serve" >/dev/null 2>&1 && die "a macprovider-cli serve process runs" 3
[ -f "$MODEL/config.json" ] || die "no GLM snapshot at $GLM_PATH or in the provider store" 11

# 1. Build against the pinned mlx-swift-lm (job.sh's lab-harness build path).
if [ "${SKIP_BUILD:-0}" != 1 ]; then
  log "BUILD start"
  (cd "$SRC" && nice -n 10 swift build -c release --product macprovider-cli --build-path "$BUILD" \
    -Xswiftc -DMACPROVIDER_LAB_HARNESS) > "$RES/build.log" 2>&1 \
    || die "swift build failed: $(tail -n 3 "$RES/build.log" | tr '\n' ' ')" 14
fi
[ -x "$BIN/macprovider-cli" ] || die "no lab-harness binary at $BIN" 14
[ -f "$METALLIB" ] || die "no metallib at $METALLIB" 14
cp "$METALLIB" "$BIN/mlx.metallib" || die "metallib copy failed" 14
shasum -a 256 "$BIN/macprovider-cli" "$BIN/mlx.metallib" > "$RES/identity.sha256"
log "BUILD done $("$BIN/macprovider-cli" --version 2>&1 | head -n 1) cli_sha256=$(cut -c1-16 "$RES/identity.sha256" | head -n 1)"

# 2. Served runs at both steps, greedy tokens recorded.
log "PROFILE_START"
"$BIN/macprovider-cli" "${PROFILE_ARGS[@]}" > "$RES/prefill-profile.stdout" 2> "$RES/prefill-profile.stderr"
rc=$?
grep '^prefill-profile: ' "$RES/prefill-profile.stderr" | sed 's/^/PROFILE_ /'
[ "$rc" = 0 ] && [ -s "$RES/prefill-profile.json" ] || die "prefill-profile exit $rc: $(tail -n 3 "$RES/prefill-profile.stderr" | tr '\n' ' ')" 15

# 3. Gate and table.
/usr/bin/python3 -I "$JOB/ablit-perf/prefill_step_gate.py" "${GATE_ARGS[@]}" > "$RES/gate.stdout" 2> "$RES/gate.stderr"
rc=$?
cat "$RES/gate.md" 2>/dev/null
sed 's/^/PARITY_ /' "$RES/gate.stdout"
[ "$rc" = 2 ] && die "gate: $(tail -n 2 "$RES/gate.stderr" "$RES/gate.stdout" | tr '\n' ' ')" 16
[ "$rc" = 0 ] || die "the 2048-step serial path does not decode the 512-step tokens (gate.md)" 17
log "JOB_PASS"
