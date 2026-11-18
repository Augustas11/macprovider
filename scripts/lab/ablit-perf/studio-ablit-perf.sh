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
#        FORK_DIR=$HOME/mlx-swift-lm-2409 JOB_SCRIPT=job-qwen4-parity.sh studio-ablit-perf.sh
#          #2409 qwen4_exp token parity; FORK_DIR is the clean mlx-swift-lm worktree
#          (campaign/2409-qwen4-exp) with Libraries/MLXLLM/Models/Qwen4Exp.swift committed, rsynced
#          to ~/lab-ablit-perf/mlx-swift-lm-2409 on the Studio (.git, .build*, .swiftpm excluded)
#        REFERENCE_ONLY=<run id> MODELS=glm GLM_REF=omlx GLM_OMLX_DIR=<studio dir> studio-ablit-perf.sh
#          add a reference to an already measured provider grid (job.sh header); the run's
#          provider.jsonl / grid.json / identity / noise / job log are pushed from
#          $POC/scratchpad/ablit-perf/results/<run id> when the Studio no longer has them
#        REUSE_REFERENCE=<run id> MODELS=glm GLM_ROWS=4 GLM_MTP_BENCH=0 studio-ablit-perf.sh
#          a provider-only rerun scored against that run's reference rows (job.sh header); its
#          reference.jsonl is pushed from $POC/scratchpad/ablit-perf/results/<run id> when the
#          Studio no longer has it
# Job settings pass through by name: MODELS OUTPUTS CONTEXTS TRIALS BASE_TRIALS METALLIB
# SKIP_BUILD REFERENCE_ONLY REUSE_REFERENCE and every <KEY>_<FIELD> model variable job.sh reads (see its header).
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
case "$JOB_SCRIPT" in job.sh|job-dsv4-abliterated.sh|job-qwen4-parity.sh) ;; *) echo "BLOCKER: JOB_SCRIPT must be job.sh, job-dsv4-abliterated.sh or job-qwen4-parity.sh" >&2; exit 2 ;; esac
mkdir -p "$SCR" "$RES"
: > "$LOG"
say() { echo "$(date '+%H:%M:%S') $*" | tee -a "$LOG"; }
blocker() { say "BLOCKER: $*"; }

[ -f "$LOCKSH" ] || { blocker "no lock helper at $LOCKSH"; exit 2; }
dirty=$(git -C "$REPO" status --porcelain -- phase3-binary scripts/lab/parity-grid scripts/lab/ablit-perf scripts/lab/minimax \
  scripts/lab/dsv4 scripts/lab/cb-studio/glm53_oracle_json.py \
  scripts/native_mtp_r015_analyze.py scripts/lab/cb-studio/glm53-2198/r015-p32k-window.json)
[ -z "$dirty" ] || { blocker "uncommitted changes in the built or copied paths; commit first: $(echo "$dirty" | head -n 3 | tr '\n' ' ')"; exit 2; }
COMMIT=$(git -C "$REPO" rev-parse HEAD)
FORK_HEAD=""
if [ "$JOB_SCRIPT" = job-qwen4-parity.sh ]; then
  [ -n "${FORK_DIR:-}" ] || { blocker "FORK_DIR is unset; set it to the mlx-swift-lm worktree on campaign/2409-qwen4-exp"; exit 2; }
  git -C "$FORK_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { blocker "FORK_DIR=$FORK_DIR is not a git work tree"; exit 2; }
  [ -z "$(git -C "$FORK_DIR" status --porcelain)" ] || { blocker "FORK_DIR=$FORK_DIR has uncommitted changes; commit first"; exit 2; }
  git -C "$FORK_DIR" cat-file -e HEAD:Libraries/MLXLLM/Models/Qwen4Exp.swift 2>/dev/null \
    || { blocker "FORK_DIR=$FORK_DIR HEAD does not contain Libraries/MLXLLM/Models/Qwen4Exp.swift"; exit 2; }
  FORK_HEAD=$(git -C "$FORK_DIR" rev-parse HEAD)
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
done < <(compgen -e | grep -E "^(MODELS|OUTPUTS|CONTEXTS|TRIALS|BASE_TRIALS|METALLIB|SKIP_BUILD|REFERENCE_ONLY|REUSE_REFERENCE|PARITY_MIN_MATCH|REFUSAL_DATA|KEEP_SOURCE|($KEYS)_(NAME|PATH|ID|SHA256|REF|REF_PY|REF_PATH|REF_ARGS|OMLX_DIR|ROWS|CB_FROM_POLICY|CONFIG_EXTRA|BASE_PATH|BASE_ID|BASE_SHA256|BASE_REFERENCE|STAGE_REPO|STAGE_REVISION|CLONE_FROM|BASE_CLONE_FROM|HF_REPO|HF_REVISION|HF_SUBFOLDER|TRIALS_BY_ROWS|MTP_BENCH|MTP_TEMPLATE))\$")
say "ABLIT_START run=$RUN_ID job=$JOB_SCRIPT commit=$COMMIT${FORK_HEAD:+ fork_head=$FORK_HEAD} env:${ENVS:- (defaults)}"

"${SSH[@]}" 'mkdir -p ~/lab-ablit-perf/job/minimax ~/lab-ablit-perf/job/dsv4 ~/lab-ablit-perf/job/cb-studio ~/lab-ablit-perf/job/catalog ~/lab-ablit-perf/job/mtp ~/lab-ablit-perf/src ~/lab-ablit-perf/logs ~/lab-ablit-perf/results' \
  || { blocker "mkdir failed"; exit 2; }
rsync -a --delete "$REPO/scripts/lab/parity-grid/" macstudio:lab-ablit-perf/job/parity-grid/ >> "$LOG" 2>&1 \
  && rsync -a --delete "$REPO/scripts/lab/ablit-perf/" macstudio:lab-ablit-perf/job/ablit-perf/ >> "$LOG" 2>&1 \
  && rsync -a --delete "$REPO/scripts/lab/dsv4/" macstudio:lab-ablit-perf/job/dsv4/ >> "$LOG" 2>&1 \
  && rsync -a "$REPO/scripts/lab/cb-studio/glm53_oracle_json.py" macstudio:lab-ablit-perf/job/cb-studio/ >> "$LOG" 2>&1 \
  && rsync -a "$REPO/scripts/lab/minimax/minimax_ablate.py" "$REPO/scripts/lab/minimax/publish_abliterated.py" \
       macstudio:lab-ablit-perf/job/minimax/ >> "$LOG" 2>&1 \
  && rsync -a "$REPO/phase3-binary/catalog/autotune/continuous-batching-policy.json" macstudio:lab-ablit-perf/job/catalog/ >> "$LOG" 2>&1 \
  && rsync -a "$REPO/scripts/native_mtp_r015_analyze.py" "$REPO/scripts/lab/cb-studio/glm53-2198/r015-p32k-window.json" \
       macstudio:lab-ablit-perf/job/mtp/ >> "$LOG" 2>&1 \
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
if [ -n "$FORK_HEAD" ]; then
  rsync -a --delete --exclude '.build*' --exclude '.swiftpm' --exclude '.git' "$FORK_DIR/" macstudio:lab-ablit-perf/mlx-swift-lm-2409/ >> "$LOG" 2>&1 \
    || { blocker "fork copy to the Studio failed"; exit 2; }
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
  if grep -q 'JOB_PASS' "$RES/$RUN_ID/job-$RUN_ID.log" 2>/dev/null; then
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
  new=$("${SSH[@]}" "grep -E '(BLOCKER|JOB_|BUILD_|BUILD |FORK |DOWNLOAD |ORACLE|STAGE|CLONE_|REFERENCE_|DOWNLOAD_|MTP_|GRID_|BASE_|NOISE_|BASELINE_MD|REF_VERSION|FETCH_|SPLICE_|NUMERIC|ORACLE_|PARITY_|REFUSAL_|PROVENANCE|HANDOFF|SOURCE_)' ~/lab-ablit-perf/logs/job-$RUN_ID.log 2>/dev/null")
  n=$(printf '%s\n' "$new" | grep -c .)
  [ "$n" -gt "$seen" ] && { printf '%s\n' "$new" | tail -n +$((seen + 1)) | tee -a "$LOG"; seen=$n; }
  [ "$alive" = no ] && break
  [ "$alive" = unknown ] && { say "ssh probe failed, retrying"; continue; }
  fresh=$("${SSH[@]}" "find ~/lab-ablit-perf/results/$RUN_ID ~/lab-ablit-perf/logs ~/lab-ablit-perf/models ~/lab-ablit-perf/venv-vlm ~/lab-ablit-perf/venv-lm ~/lab-ablit-perf/venv-dsv4 ~/lab-ablit-perf/omlx-state ~/lab-ablit-perf/src/phase3-binary/.build-lab-harness -type f -mmin -$STALL_MIN 2>/dev/null | head -n 1")
  if [ -z "$fresh" ]; then
    stalled=$((stalled + 1))
    [ $((stalled % STALL_MIN)) = 1 ] && blocker "no file progress for ${STALL_MIN}+ minutes; last job log lines: $("${SSH[@]}" "tail -n 2 ~/lab-ablit-perf/logs/job-$RUN_ID.log" | tr '\n' ' ')"
  else
    stalled=0
  fi
done
say "remote job exited"
"${SSH[@]}" "tail -n 15 ~/lab-ablit-perf/logs/job-$RUN_ID.log" | tee -a "$LOG"
