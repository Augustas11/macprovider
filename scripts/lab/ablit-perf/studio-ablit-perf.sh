#!/bin/bash
# Abliterated-perf swarm baseline window launcher, run on the dev Mac (modeled on
# scripts/lab/minimax/studio-2376.sh). Run ONLY inside a Studio window whose owner has
# already paused the live provider and the runner's Studio target: this script never
# pauses, restores or restarts either, and refuses to start if :8080 listens on the
# Studio, live.malibu.provider is loaded or a macprovider-cli serve process runs.
#
# Copies scripts/lab/{parity-grid,ablit-perf}, the two MiniMax helpers, the signed CB
# policy, the R015 analyzer and the exploratory native-mtp-bench policy template to
# ~/lab-ablit-perf/job and this checkout's phase3-binary to ~/lab-ablit-perf/src,
# takes the Studio GPU lock, starts job.sh detached in its own process group, watches it
# (stall watcher only, no wall-clock deadline), pulls ~/lab-ablit-perf/results/<run> back
# to $POC/scratchpad/ablit-perf/results/<run>, releases the lock at exit.
#
# Usage: studio-ablit-perf.sh                  all models (MODELS="qwen27 glm minimax")
#        MODELS=minimax studio-ablit-perf.sh   one model alone
#        JOB_SCRIPT=job-dsv4-abliterated.sh studio-ablit-perf.sh   the abliterated DeepSeek V4-Flash
#          splice and its checks (also copies scripts/lab/dsv4 and glm53_oracle_json.py)
#          (DSV4_PUBLISH=1 adds the upload after JOB_PASS; DSV4_PUBLISH_ARGS=--dry-run stages only)
#        FORK_DIR=$HOME/mlx-swift-lm-2409 JOB_SCRIPT=job-qwen4-parity.sh studio-ablit-perf.sh
#          #2409 qwen4_exp token parity; FORK_DIR is the clean mlx-swift-lm worktree
#          (campaign/2409-qwen4-exp) with Libraries/MLXLLM/Models/Qwen4Exp.swift committed, rsynced
#          to ~/lab-ablit-perf/mlx-swift-lm-2409 on the Studio (.git, .build*, .swiftpm excluded)
#        FORK_DIR=$HOME/mlx-swift-lm-2409 JOB_SCRIPT=job-glm-prefill-profile.sh studio-ablit-perf.sh
#          #2409 GLM one-row prefill profile (job header); FORK_DIR must hold
#          Libraries/MLXLMCommon/LabSectionTimer.swift at HEAD. Knobs: PROMPT_TOKENS STEP_SIZES
#          PROFILE_RUNS GLM_PATH GLM_OMLX_DIR (oMLX install dir, to record its prefill chunk)
#        FORK_DIR=$HOME/mlx-swift-lm-2451-profile JOB_SCRIPT=job-glm-prefill-profile.sh PROFILE_MODEL=minimax studio-ablit-perf.sh
#          #2458 the same profile on the abliterated MiniMax M3.1-Flash (3,179 and 12,128 tokens, mlx-vlm
#          reference TTFTs); FORK_DIR HEAD must time MiniMaxM3.swift with LabSectionTimer. Knobs as above,
#          MINIMAX_PATH for GLM_PATH
#        JOB_SCRIPT=job-glm-prefill-step-gate.sh studio-ablit-perf.sh
#          #2409 gate for the glm5_next 2048 serial prefill step (job header): every greedy token
#          at step 512 vs 2048, TTFT per step. Knobs: PROMPT_TOKENS PROFILE_RUNS GENERATE_TOKENS GLM_PATH
#        FORK_DIR=$HOME/mlx-swift-lm-2409 JOB_SCRIPT=job-qwen4-cb.sh studio-ablit-perf.sh
#          #2409 Qwen3.8-Flash-Next (qwen4_exp) continuous batching at rows 1,4,8,16, ours vs mlx-lm
#          batched generation (BatchGenerator, the qwen4_oracle loader shim), contexts 200 and 4000,
#          output 512, 3 trials, served slots owner-pinned to 16, `--expect-route batched`; FORK_DIR is
#          the clean mlx-swift-lm worktree on campaign/2409-qwen4-exp-batch (batched Qwen4Exp
#          committed), rsynced like the parity job's. Knobs by name: CB_ROWS (1,4,8,16) CB_SLOTS (16)
#          CONTEXTS (200,4000) OUTPUTS (512) TRIALS (3) REF_PREFILL_BATCH_SIZE QWEN4_PATH QWEN4_REPO
#          QWEN4_REVISION QWEN4_ID QWEN4_SHA256 SEED_SELF_CHECK_RUN (job-qwen4-cb.sh header). Estimated duration: about 1 h 30
#          cold (build ~20 min, idle CB self-check up to ~15 min at 16 slots, provider grid ~15 min,
#          mlx-lm reference ~25 min, model load ~3 min each side), about 1 h when the build and the
#          self-check verdict are reused (SKIP_BUILD=1, SEED_SELF_CHECK_RUN=<run>); plus the 106 GB
#          snapshot download if ~/lab-ablit-perf/models lacks it. Estimates, not measured.
#          Decode profile (#2409 per-row cost by section, provider only): CB_ROWS=1,4,8,11 CONTEXTS=200
#          OUTPUTS=256 TRIALS=1 SKIP_REFERENCE=1 SERVE_ENV='MLX_LM_SECTION_TIMING=1'; FORK_DIR HEAD must
#          then hold Libraries/MLXLMCommon/LabSectionTimer.swift (fork branch
#          campaign/2409-qwen4-exp-batch-labtimer; the pinned engine has no timer).
#        JOB_SCRIPT=job-qwen4-listing.sh studio-ablit-perf.sh
#          #2452 step 3: Qwen3.8-Flash-Next pre-listing checks on a lab build of this tree (pinned engine,
#          no FORK_DIR): serve under the catalog id qwen/qwen3.8-flash-next-abliterated with the snapshot
#          hash, identity, peak memory at one row at 4k and 32k context with a proposed min_ram_gb, and the
#          buyer-UX suite (scripts/buyer_ux_conformance.py, copied to job/bux) over loopback (job header).
#          Knobs: QWEN4_PATH QWEN4_REPO QWEN4_REVISION QWEN4_ID QWEN4_SHA256 MEM_CONTEXTS MEM_OUTPUT
#          BUX_SAMPLES SKIP_BUILD METALLIB. BUX_EXTRA_MODELS='qwen38-27b' also serves the live row
#          qwen/qwen3.8-27b (sha 8a8786e9; qwen36-27b likewise) with --no-join after the Flash-Next checks and
#          runs the same buyer-UX suite on it (job header; no memory measurement; about +20-25 min, estimate).
#          Estimated duration (an estimate, not measured): about 50 min cold
#          (build ~20 min, two model loads ~3 min each, 4k and 32k cells ~5 min, buyer-UX 34 requests
#          ~10-15 min, prefill-profile ~5 min), about 30 min with SKIP_BUILD=1; plus the 106 GB snapshot
#          download if ~/lab-ablit-perf/models lacks it.
#        FORK_DIR=$HOME/mlx-swift-lm-2448 JOB_SCRIPT=job-qwen4-exactness.sh studio-ablit-perf.sh
#          #2448 + #2449 Flash-Next exactness, one window (job header): the fork's Qwen4ExpTests on
#          Metal first (row join/leave included; any failure ends the job), then two fenced passes of
#          job-qwen4-cb.sh (rows 1,4,8,11, context 200, 512 tokens, 3 trials, each its own serve) gated
#          on identical per-row text and token counts (DETERMINISM PASS|FAIL), one 1-row pass at 4000,
#          then job-qwen4-parity.sh with the two served chat prompts (DIVERGENCE_VERDICT per prompt,
#          PARITY_GATES with close-call prompts). FORK_DIR is the campaign/2448-qwen4-join-test
#          worktree: the job-qwen4-cb.sh engine (tag 3.32.3-macprovider.84) plus the join/leave tests,
#          which the job requires. Knobs: DET_ROWS
#          DET_CONTEXTS OUTPUTS TRIALS CB_SLOTS SERVED_CONTEXTS SERVED_STEPS CONTEXTS STEPS
#          SEED_SELF_CHECK_RUN SKIP_BUILD RUN_DETERMINISM RUN_PARITY and the QWEN4_* pins. Estimated
#          duration: about 1 h 25 cold (build ~20 min, fresh self-check up to ~15 min, two fenced grids
#          ~7 min each, three serve loads ~3 min each, the 4000 pass ~1 min, parity ~25 min: three model
#          loads, four oracles, glm-parity at 2048 and 512), about 55 min with SKIP_BUILD=1 and
#          SEED_SELF_CHECK_RUN=<run>. Estimates, not measured.
#        FORK_DIR=$HOME/mlx-swift-lm-2451 JOB_SCRIPT=job-glm-wide-prefill.sh GLM_OMLX_DIR=<studio dir> studio-ablit-perf.sh
#          #2451 GLM wide row-local prefill on the batching route (job header): fork bit-identity tests
#          (Metal), main vs wide builds, control/candidate/control grids at 4k,16k x 128,512 x 3 trials,
#          the oMLX reference on the wide pass, token gate + TTFT verdict (wide_prefill_gate.py). FORK_DIR
#          is the mlx-swift-lm worktree on campaign/2451-glm-wide-prefill (rsynced like the parity job's);
#          the main build is phase3-binary at this checkout's merge-base with origin/main, copied to
#          ~/lab-ablit-perf/src-main. Knobs: CONTEXTS OUTPUTS TRIALS GLM_PATH GLM_OMLX_DIR SKIP_REFERENCE
#          SKIP_FORK_TESTS SKIP_BUILD SEED_SELF_CHECK_RUN SERVE_ENV. Estimated duration: about 1 h 45 cold
#          (fork tests ~15 min, two release builds ~20 min each, three serves with self-check, grids
#          ~7 min each, oMLX ~10 min). Estimate, not measured.
#        JOB_SCRIPT=job-glm-gather-qmm-bitwise.sh studio-ablit-perf.sh
#          #2451: mx.gather_qmm sorted-indices route, row bits vs tile composition at GLM-5.3-Flash expert
#          shapes (random 4-bit weights, no model, no build), on the mlx wheel of the pinned MLX core
#          (scripts/read_swiftpm_pins.py copied to job/pins). Knobs: GQMM_SEED GQMM_TARGETS. Estimated
#          duration (an estimate, not measured): about 5 min (venv ~1-2 min on first use, weights and
#          13 cases a few minutes).
#        JOB_SCRIPT=job-qwen-mtp-cap.sh studio-ablit-perf.sh
#          #2429 Qwen native MTP depth 1 vs off, one row, prompts above the 4096 cap (job header).
#          Knobs: QMTP_MODELS QMTP_PROMPTS QMTP_OUTPUTS QMTP_BLOCKS QMTP_SHAPE QMTP_FORMAL QMTP_CAP QMTP_FORMAL_BLOCKS
#          QMTP_EXCLUSION QMTP_PROBE=1 (one-cell preflight probe)
#        REFERENCE_ONLY=<run id> MODELS=glm GLM_REF=omlx GLM_OMLX_DIR=<studio dir> studio-ablit-perf.sh
#          add a reference to an already measured provider grid (job.sh header); the run's
#          provider.jsonl / grid.json / identity / noise / job log are pushed from
#          $POC/scratchpad/ablit-perf/results/<run id> when the Studio no longer has them
#        REUSE_REFERENCE=<run id> MODELS=glm GLM_ROWS=4 GLM_MTP_BENCH=0 studio-ablit-perf.sh
#          a provider-only rerun scored against that run's reference rows (job.sh header); its
#          reference.jsonl is pushed from $POC/scratchpad/ablit-perf/results/<run id> when the
#          Studio no longer has it
#        MODELS=glm GLM_MTP_BENCH=0 REUSE_REFERENCE=20261117T195837Z SEED_SELF_CHECK_RUN=20261118T004127Z \
#          CONTEXTS=200,4000,16000 OUTPUTS=512,2048 TRIALS=3 \
#          GLM_PASSES='mtp rows=1 native_mtp=auto; slots4 rows=4 slots=4' studio-ablit-perf.sh
#          #2409 abliterated GLM, provider side only, one job: pass `mtp` (1 row, native MTP auto at the
#          signed admission set, run-grid.sh fails it with exit 11 when native MTP is off; per-cell
#          proposed/accepted tokens in provider.jsonl and PASS_MTP lines) then pass `slots4` (4 rows, the
#          served slots owner-pinned to 4; BLOCKER when the ROUTE shows other slots), each its own serve,
#          scored against that run's oMLX reference rows, no noise pass, no baseline.md. Both seed the
#          stored self-check verdict of SEED_SELF_CHECK_RUN (its cb-self-check.json is pushed from
#          $POC/scratchpad/ablit-perf/results/<run id> when the Studio no longer has it); one serve
#          cannot do both (native MTP admits one active row, the 4-slot pass needs the pin), so two loads.
#          Per-pass knobs are documented in the job.sh header (<K>_PASSES, <K>_NATIVE_MTP, <K>_SERVED_SLOTS).
# Job settings pass through by name: MODELS OUTPUTS CONTEXTS TRIALS BASE_TRIALS METALLIB DET_ROWS DET_CONTEXTS
# SERVED_CONTEXTS SERVED_STEPS STEPS RUN_DETERMINISM RUN_PARITY LAB_FENCE
# QMTP_* SKIP_BUILD REFERENCE_ONLY REUSE_REFERENCE SEED_SELF_CHECK_RUN SERVE_ENV PROMPT_TOKENS STEP_SIZES PROFILE_RUNS PROFILE_MODEL GENERATE_TOKENS and every <KEY>_<FIELD> model variable job.sh reads (see its header).
# Exit 0 only when the job printed JOB_PASS; every failure prints a `BLOCKER:` line.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
POC=${POC:-$HOME/macprovider-poc}  # the checkout that holds scratchpad/ and the lock helper
SCR=$POC/scratchpad/ablit-perf
RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)
LOG=$SCR/studio-ablit-perf-$RUN_ID.log
RES=$SCR/results
LOCKSH=$POC/scratchpad/studio-lock.sh
OWNER=ablit-perf
STALL_MIN=30
SSH=(ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=6 macstudio)
JOB_SCRIPT=${JOB_SCRIPT:-job.sh}
case "$JOB_SCRIPT" in job.sh|job-dsv4-abliterated.sh|job-qwen4-parity.sh|job-qwen4-cb.sh|job-qwen4-listing.sh|job-qwen4-exactness.sh|job-glm-prefill-profile.sh|job-glm-prefill-step-gate.sh|job-qwen-mtp-cap.sh|job-glm-gather-qmm-bitwise.sh|job-glm-wide-prefill.sh) ;; *) echo "BLOCKER: JOB_SCRIPT must be job.sh, job-dsv4-abliterated.sh, job-qwen4-parity.sh, job-qwen4-cb.sh, job-qwen4-listing.sh, job-qwen4-exactness.sh, job-glm-prefill-profile.sh, job-glm-prefill-step-gate.sh, job-qwen-mtp-cap.sh, job-glm-gather-qmm-bitwise.sh or job-glm-wide-prefill.sh" >&2; exit 2 ;; esac
mkdir -p "$SCR" "$RES"
: > "$LOG"
say() { echo "$(date '+%H:%M:%S') $*" | tee -a "$LOG"; }
blocker() { say "BLOCKER: $*"; }

[ -f "$LOCKSH" ] || { blocker "no lock helper at $LOCKSH"; exit 2; }
dirty=$(git -C "$REPO" status --porcelain -- phase3-binary scripts/lab/parity-grid scripts/lab/ablit-perf scripts/lab/minimax \
  scripts/lab/dsv4 scripts/lab/cb-studio/glm53_oracle_json.py \
  scripts/native_mtp_r015_analyze.py scripts/lab/cb-studio/glm53-2198/r015-p32k-window.json scripts/read_swiftpm_pins.py scripts/buyer_ux_conformance.py)
[ -z "$dirty" ] || { blocker "uncommitted changes in the built or copied paths; commit first: $(echo "$dirty" | head -n 3 | tr '\n' ' ')"; exit 2; }
COMMIT=$(git -C "$REPO" rev-parse HEAD)
FORK_HEAD=""
FORK_FILE=""
case "$JOB_SCRIPT" in
  job-qwen4-parity.sh|job-qwen4-cb.sh|job-qwen4-exactness.sh) FORK_FILE=Libraries/MLXLLM/Models/Qwen4Exp.swift ;;
  job-glm-prefill-profile.sh) FORK_FILE=Libraries/MLXLMCommon/LabSectionTimer.swift ;;
  job-glm-wide-prefill.sh) FORK_FILE=Libraries/MLXLLM/Models/GLM5Next.swift ;;
esac
if [ -n "$FORK_FILE" ]; then
  [ -n "${FORK_DIR:-}" ] || { blocker "FORK_DIR is unset; set it to the mlx-swift-lm worktree on campaign/2409-qwen4-exp (parity) or campaign/2409-qwen4-exp-batch (CB)"; exit 2; }
  git -C "$FORK_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { blocker "FORK_DIR=$FORK_DIR is not a git work tree"; exit 2; }
  [ -z "$(git -C "$FORK_DIR" status --porcelain)" ] || { blocker "FORK_DIR=$FORK_DIR has uncommitted changes; commit first"; exit 2; }
  git -C "$FORK_DIR" cat-file -e "HEAD:$FORK_FILE" 2>/dev/null \
    || { blocker "FORK_DIR=$FORK_DIR HEAD does not contain $FORK_FILE"; exit 2; }
  case " ${SERVE_ENV:-} " in *" MLX_LM_SECTION_TIMING=1 "*)
    git -C "$FORK_DIR" cat-file -e HEAD:Libraries/MLXLMCommon/LabSectionTimer.swift 2>/dev/null \
      || { blocker "SERVE_ENV sets MLX_LM_SECTION_TIMING=1 but FORK_DIR=$FORK_DIR HEAD has no Libraries/MLXLMCommon/LabSectionTimer.swift"; exit 2; } ;;
  esac
  if [ "$JOB_SCRIPT" = job-glm-prefill-profile.sh ] && [ "${PROFILE_MODEL:-glm}" = minimax ]; then
    git -C "$FORK_DIR" grep -q LabSectionTimer HEAD -- Libraries/MLXLLM/Models/MiniMaxM3.swift \
      || { blocker "FORK_DIR=$FORK_DIR HEAD has no LabSectionTimer sections in Libraries/MLXLLM/Models/MiniMaxM3.swift (campaign/2451-profile)"; exit 2; }
  fi
  if [ "$JOB_SCRIPT" = job-glm-wide-prefill.sh ]; then
    git -C "$FORK_DIR" grep -q glm5NextPrefillSlicesKey HEAD -- "$FORK_FILE" \
      || { blocker "FORK_DIR=$FORK_DIR HEAD has no glm5NextPrefillSlicesKey in $FORK_FILE (campaign/2451-glm-wide-prefill)"; exit 2; }
  fi
  FORK_HEAD=$(git -C "$FORK_DIR" rev-parse HEAD)
fi
# The wide-prefill job's control build: phase3-binary at the campaign's merge-base with origin/main.
MAIN_BASE=""
if [ "$JOB_SCRIPT" = job-glm-wide-prefill.sh ]; then
  MAIN_BASE=$(git -C "$REPO" merge-base HEAD origin/main 2>/dev/null) || { blocker "no merge-base of HEAD and origin/main in $REPO"; exit 2; }
fi

pre=$("${SSH[@]}" 'u=$(id -u)
  if lsof -nP -iTCP:8080 -sTCP:LISTEN -t >/dev/null 2>&1; then echo LISTEN_8080; fi
  launchctl print gui/$u/live.malibu.provider >/dev/null 2>&1 && echo LIVE_LOADED
  pgrep -f "[m]acprovider-cli serve" >/dev/null 2>&1 && echo SERVE_RUNNING
  echo done') || { blocker "ssh macstudio failed"; exit 2; }
case "$pre" in
  done) say "preflight ok: :8080 free, live.malibu.provider absent, no serve process" ;;
  *) blocker "refusing to start, the Studio is not paused: $(echo "$pre" | grep -v '^done$' | tr '\n' ' ')"; exit 3 ;;
esac

# Job environment: only the names job.sh reads, each value shell-quoted for the remote side.
KEYS=$(echo "qwen27 glm minimax ${MODELS:-}" | tr 'a-z-' 'A-Z_' | tr -s ' ' '\n' | grep . | sort -u | paste -sd '|' -)
ENVS=""
while IFS= read -r name; do
  ENVS="$ENVS $name=$(printf %q "${!name}")"
done < <(compgen -e | grep -E "^(MODELS|OUTPUTS|CONTEXTS|TRIALS|BASE_TRIALS|METALLIB|SKIP_BUILD|REFERENCE_ONLY|REUSE_REFERENCE|SEED_SELF_CHECK_RUN|SERVE_ENV|SKIP_REFERENCE|SKIP_FORK_TESTS|PARITY_MIN_MATCH|REFUSAL_DATA|KEEP_SOURCE|DSV4_PUBLISH|DSV4_PUBLISH_ARGS|CB_ROWS|CB_SLOTS|LAB_FENCE|DET_ROWS|DET_CONTEXTS|SERVED_CONTEXTS|SERVED_STEPS|STEPS|RUN_DETERMINISM|RUN_PARITY|REF_PREFILL_BATCH_SIZE|QWEN4_PATH|QWEN4_REPO|QWEN4_REVISION|QWEN4_ID|QWEN4_SHA256|PROMPT_TOKENS|STEP_SIZES|PROFILE_RUNS|GENERATE_TOKENS|PROFILE_MODEL|GQMM_SEED|GQMM_TARGETS|MEM_CONTEXTS|MEM_OUTPUT|BUX_SAMPLES|BUX_EXTRA_MODELS|QMTP_MODELS|QMTP_PROMPTS|QMTP_OUTPUTS|QMTP_BLOCKS|QMTP_PROBE|QMTP_SHAPE|QMTP_FORMAL|QMTP_CAP|QMTP_FORMAL_BLOCKS|QMTP_EXCLUSION|($KEYS)_(NAME|PATH|ID|SHA256|REF|REF_PY|REF_PATH|REF_ARGS|OMLX_DIR|ROWS|CB_FROM_POLICY|CONFIG_EXTRA|BASE_PATH|BASE_ID|BASE_SHA256|BASE_REFERENCE|NATIVE_MTP|SERVED_SLOTS|PASSES|STAGE_REPO|STAGE_REVISION|CLONE_FROM|BASE_CLONE_FROM|HF_REPO|HF_REVISION|HF_SUBFOLDER|TRIALS_BY_ROWS|MTP_BENCH|MTP_TEMPLATE))\$")
say "ABLIT_START run=$RUN_ID job=$JOB_SCRIPT commit=$COMMIT${FORK_HEAD:+ fork_head=$FORK_HEAD}${MAIN_BASE:+ main_base=$MAIN_BASE} env:${ENVS:- (defaults)}"

"${SSH[@]}" 'mkdir -p ~/lab-ablit-perf/job/minimax ~/lab-ablit-perf/job/dsv4 ~/lab-ablit-perf/job/cb-studio ~/lab-ablit-perf/job/catalog ~/lab-ablit-perf/job/mtp ~/lab-ablit-perf/job/bux ~/lab-ablit-perf/job/pins ~/lab-ablit-perf/src ~/lab-ablit-perf/logs ~/lab-ablit-perf/results' \
  && rsync -a "$REPO/scripts/read_swiftpm_pins.py" macstudio:lab-ablit-perf/job/pins/ >> "$LOG" 2>&1 \
  || { blocker "mkdir failed"; exit 2; }
rsync -a --delete "$REPO/scripts/lab/parity-grid/" macstudio:lab-ablit-perf/job/parity-grid/ >> "$LOG" 2>&1 \
  && rsync -a --delete "$REPO/scripts/lab/ablit-perf/" macstudio:lab-ablit-perf/job/ablit-perf/ >> "$LOG" 2>&1 \
  && rsync -a --delete "$REPO/scripts/lab/dsv4/" macstudio:lab-ablit-perf/job/dsv4/ >> "$LOG" 2>&1 \
  && rsync -a "$REPO/scripts/lab/cb-studio/glm53_oracle_json.py" macstudio:lab-ablit-perf/job/cb-studio/ >> "$LOG" 2>&1 \
  && rsync -a "$REPO/scripts/lab/minimax/minimax_ablate.py" "$REPO/scripts/lab/minimax/publish_abliterated.py" \
       macstudio:lab-ablit-perf/job/minimax/ >> "$LOG" 2>&1 \
  && rsync -a "$REPO/phase3-binary/catalog/autotune/continuous-batching-policy.json" \
       "$REPO/phase3-binary/catalog/autotune/autotune-candidates.json" macstudio:lab-ablit-perf/job/catalog/ >> "$LOG" 2>&1 \
  && rsync -a "$REPO/scripts/native_mtp_r015_analyze.py" "$REPO/scripts/lab/cb-studio/glm53-2198/r015-p32k-window.json" \
       macstudio:lab-ablit-perf/job/mtp/ >> "$LOG" 2>&1 \
  && rsync -a "$REPO/scripts/buyer_ux_conformance.py" macstudio:lab-ablit-perf/job/bux/ >> "$LOG" 2>&1 \
  && rsync -a --delete --exclude '.build*' --exclude '.swiftpm' "$REPO/phase3-binary/" macstudio:lab-ablit-perf/src/phase3-binary/ >> "$LOG" 2>&1 \
  || { blocker "copy to the Studio failed"; exit 2; }
if [ -n "${REFERENCE_ONLY:-}" ]; then
  [ "$JOB_SCRIPT" = job.sh ] || { blocker "REFERENCE_ONLY needs JOB_SCRIPT=job.sh"; exit 2; }
  [ -d "$RES/$REFERENCE_ONLY" ] || { blocker "no local results at $RES/$REFERENCE_ONLY"; exit 2; }
  # Only what the reference-only pass reads; files the Studio still has are never overwritten.
  rsync -a --ignore-existing --prune-empty-dirs --include='*/' --include='provider.jsonl' --include='grid.json' \
      --include='status.json' --include='identity.sha256' --include='vs-main.json' --include='vs-main.md' \
      --include="job-$REFERENCE_ONLY.log" --exclude='*' \
      "$RES/$REFERENCE_ONLY/" "macstudio:lab-ablit-perf/results/$REFERENCE_ONLY/" >> "$LOG" 2>&1 \
    || { blocker "push of the provider run $REFERENCE_ONLY to the Studio failed"; exit 2; }
fi
if [ -n "${REUSE_REFERENCE:-}" ]; then
  [ -d "$RES/$REUSE_REFERENCE" ] || { blocker "no local results at $RES/$REUSE_REFERENCE"; exit 2; }
  # Only the reference rows; files the Studio still has are never overwritten.
  rsync -a --ignore-existing --prune-empty-dirs --include='*/' --include='reference.jsonl' --exclude='*' \
      "$RES/$REUSE_REFERENCE/" "macstudio:lab-ablit-perf/results/$REUSE_REFERENCE/" >> "$LOG" 2>&1 \
    || { blocker "push of the reference rows of $REUSE_REFERENCE to the Studio failed"; exit 2; }
fi
if [ -n "${SEED_SELF_CHECK_RUN:-}" ]; then
  [ -d "$RES/$SEED_SELF_CHECK_RUN" ] || { blocker "no local results at $RES/$SEED_SELF_CHECK_RUN"; exit 2; }
  # Only the stored verdicts of the main passes; files the Studio still has are never overwritten.
  rsync -a --ignore-existing --prune-empty-dirs --include='*/' --include='main/serve/cb-self-check.json' \
      --include='main-a/serve/cb-self-check.json' --exclude='*' \
      "$RES/$SEED_SELF_CHECK_RUN/" "macstudio:lab-ablit-perf/results/$SEED_SELF_CHECK_RUN/" >> "$LOG" 2>&1 \
    || { blocker "push of the self-check verdict of $SEED_SELF_CHECK_RUN to the Studio failed"; exit 2; }
fi
if [ -n "$FORK_HEAD" ]; then
  rsync -a --delete --exclude '.build*' --exclude '.swiftpm' --exclude '.git' "$FORK_DIR/" macstudio:lab-ablit-perf/mlx-swift-lm-2409/ >> "$LOG" 2>&1 \
    || { blocker "fork copy to the Studio failed"; exit 2; }
fi
if [ -n "$MAIN_BASE" ]; then
  MAIN_TMP=$(mktemp -d "$SCR/main-src.XXXXXX")
  git -C "$REPO" archive "$MAIN_BASE" phase3-binary | tar -x -C "$MAIN_TMP" \
    && rsync -a --delete --exclude '.build*' --exclude '.swiftpm' "$MAIN_TMP/phase3-binary/" macstudio:lab-ablit-perf/src-main/phase3-binary/ >> "$LOG" 2>&1
  rc=$?
  rm -rf "$MAIN_TMP"
  [ "$rc" = 0 ] || { blocker "main tree copy to the Studio failed"; exit 2; }
fi

HAVE_GPU=0; PID=""
finish() {
  if [ -n "$PID" ] && "${SSH[@]}" "kill -0 $PID 2>/dev/null"; then
    say "remote job still running at exit; killing its process group $PID"
    "${SSH[@]}" "kill -TERM -- -$PID 2>/dev/null; sleep 15; kill -KILL -- -$PID 2>/dev/null"
  fi
  mkdir -p "$RES/$RUN_ID"
  rsync -a "macstudio:lab-ablit-perf/results/$RUN_ID/" "$RES/$RUN_ID/" >> "$LOG" 2>&1 || blocker "results pull failed"
  rsync -a "macstudio:lab-ablit-perf/logs/job-$RUN_ID.log" "$RES/$RUN_ID/" >> "$LOG" 2>&1
  [ "$HAVE_GPU" = 1 ] && STUDIO_LANE=gpu bash "$LOCKSH" release "$OWNER" >> "$LOG" 2>&1
  say "LOCKS_RELEASED $(bash "$LOCKSH" status 2>&1 | tr '\n' ' ')"
  for f in "$RES/$RUN_ID"/*/baseline.md; do [ -f "$f" ] && say "BASELINE $f"; done
  # A publish runs after JOB_PASS: it passes only on PUBLISH_PASS, so a job killed mid-upload fails.
  local published=1
  [ "${DSV4_PUBLISH:-0}" = 1 ] && ! grep -q 'PUBLISH_PASS' "$RES/$RUN_ID/job-$RUN_ID.log" 2>/dev/null && published=0
  if [ "$published" = 1 ] && grep -q 'JOB_PASS' "$RES/$RUN_ID/job-$RUN_ID.log" 2>/dev/null && ! grep -q 'PUBLISH_FAIL' "$RES/$RUN_ID/job-$RUN_ID.log"; then
    say "ABLIT_END pass. Results: $RES/$RUN_ID"
  else
    blocker "the job did not pass; see $RES/$RUN_ID/job-$RUN_ID.log"
    say "ABLIT_END fail. Results: $RES/$RUN_ID"
    exit 1
  fi
}
trap finish EXIT
trap 'exit 130' INT TERM HUP
STUDIO_LANE=gpu bash "$LOCKSH" acquire "$OWNER" >> "$LOG" 2>&1 || { blocker "gpu lock acquire failed"; exit 3; }
HAVE_GPU=1
say "LOCKS_ACQUIRED"

# set -m: the job leads its own process group, so finish() can stop all of it.
PID=$("${SSH[@]}" "bash -s" <<REMOTE
set -m
cd ~/lab-ablit-perf
env RUN_ID=$RUN_ID COMMIT=$COMMIT $ENVS nohup bash ./job/ablit-perf/$JOB_SCRIPT > ./logs/job-$RUN_ID.log 2>&1 < /dev/null &
echo \$!
REMOTE
)
say "remote job pid=$PID"
[ -n "$PID" ] || { blocker "remote job did not start"; exit 4; }

seen=0; stalled=0
while :; do
  sleep 60
  alive=$("${SSH[@]}" "kill -0 $PID 2>/dev/null && echo yes || echo no") || alive=unknown
  new=$("${SSH[@]}" "grep -E '(BLOCKER|PASS_|JOB_|BUILD_|BUILD |FORK |DOWNLOAD |ORACLE|STAGE|CLONE_|REFERENCE_|DOWNLOAD_|MTP_|GRID_|BASE_|NOISE_|BASELINE_MD|REF_VERSION|FETCH_|SPLICE_|NUMERIC|ORACLE_|PARITY_|REFUSAL_|PROVENANCE|HANDOFF|SOURCE_|MODEL |CB_TUPLE|TUPLE_|INFERENCE_ERROR|DECODE_PROFILE|LISTING_|IDENTITY|MEM_|BUX_|SERVE |PEAK |PROFILE_|STEP |STEP_|DETERMINISM|DIVERGENCE_VERDICT|SPEC_EVIDENCE|SERVED_ORACLE|PUBLISH_|GQMM_|BITWISE_|WIDE_|FORK_TEST)' ~/lab-ablit-perf/logs/job-$RUN_ID.log 2>/dev/null")
  n=$(printf '%s\n' "$new" | grep -c .)
  [ "$n" -gt "$seen" ] && { printf '%s\n' "$new" | tail -n +$((seen + 1)) | tee -a "$LOG"; seen=$n; }
  [ "$alive" = no ] && break
  [ "$alive" = unknown ] && { say "ssh probe failed, retrying"; continue; }
  fresh=$("${SSH[@]}" "find ~/lab-ablit-perf/results/$RUN_ID ~/lab-ablit-perf/logs ~/lab-ablit-perf/models ~/lab-ablit-perf/venv-vlm ~/lab-ablit-perf/venv-lm ~/lab-ablit-perf/venv-dsv4 ~/lab-ablit-perf/venv-gqmm ~/lab-ablit-perf/omlx-state ~/lab-ablit-perf/src/phase3-binary/.build-lab-harness ~/lab-ablit-perf/src/phase3-binary/.build-lab-wide ~/lab-ablit-perf/src-main/phase3-binary/.build-lab-main ~/lab-ablit-perf/mlx-swift-lm-2409/.build -type f -mmin -$STALL_MIN 2>/dev/null | head -n 1")
  if [ -z "$fresh" ]; then
    stalled=$((stalled + 1))
    [ $((stalled % STALL_MIN)) = 1 ] && blocker "no file progress for ${STALL_MIN}+ minutes; last job log lines: $("${SSH[@]}" "tail -n 2 ~/lab-ablit-perf/logs/job-$RUN_ID.log" | tr '\n' ' ')"
  else
    stalled=0
  fi
done
say "remote job exited"
"${SSH[@]}" "tail -n 15 ~/lab-ablit-perf/logs/job-$RUN_ID.log" | tee -a "$LOG"
