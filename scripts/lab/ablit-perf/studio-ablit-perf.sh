#!/bin/bash
# Abliterated-perf swarm baseline window launcher, run on the dev Mac (modeled on
# scripts/lab/minimax/studio-2376.sh). Run ONLY inside a Studio window whose owner has
# already paused the live provider and the runner's Studio target: this script never
# pauses, restores or restarts either, and refuses to start if :8080 listens on the
# Studio, live.malibu.provider is loaded or a macprovider-cli serve process runs.
#
# Copies scripts/lab/{parity-grid,ablit-perf}, the two MiniMax helpers and the signed CB
# policy to ~/lab-ablit-perf/job and this checkout's phase3-binary to ~/lab-ablit-perf/src,
# takes the Studio GPU lock, starts job.sh detached in its own process group, watches it
# (stall watcher only, no wall-clock deadline), pulls ~/lab-ablit-perf/results/<run> back
# to $POC/scratchpad/ablit-perf/results/<run>, releases the lock at exit.
#
# Usage: studio-ablit-perf.sh                  both models (MODELS="glm minimax")
#        MODELS=minimax studio-ablit-perf.sh   one model alone
# Job settings pass through by name: MODELS OUTPUTS CONTEXTS TRIALS BASE_TRIALS METALLIB
# SKIP_BUILD and every <KEY>_<FIELD> model variable job.sh reads (see its header).
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
mkdir -p "$SCR" "$RES"
: > "$LOG"
say() { echo "$(date '+%H:%M:%S') $*" | tee -a "$LOG"; }
blocker() { say "BLOCKER: $*"; }

[ -f "$LOCKSH" ] || { blocker "no lock helper at $LOCKSH"; exit 2; }
dirty=$(git -C "$REPO" status --porcelain -- phase3-binary scripts/lab/parity-grid scripts/lab/ablit-perf scripts/lab/minimax)
[ -z "$dirty" ] || { blocker "uncommitted changes in the built or copied paths; commit first: $(echo "$dirty" | head -n 3 | tr '\n' ' ')"; exit 2; }
COMMIT=$(git -C "$REPO" rev-parse HEAD)

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
KEYS=$(echo "glm minimax ${MODELS:-}" | tr 'a-z-' 'A-Z_' | tr -s ' ' '\n' | grep . | sort -u | paste -sd '|' -)
ENVS=""
while IFS= read -r name; do
  ENVS="$ENVS $name=$(printf %q "${!name}")"
done < <(compgen -e | grep -E "^(MODELS|OUTPUTS|CONTEXTS|TRIALS|BASE_TRIALS|METALLIB|SKIP_BUILD|($KEYS)_(NAME|PATH|ID|SHA256|REF|REF_PY|REF_PATH|REF_ARGS|ROWS|CB_FROM_POLICY|CONFIG_EXTRA|BASE_PATH|BASE_ID|BASE_SHA256|STAGE_REPO|STAGE_REVISION))\$")
say "ABLIT_START run=$RUN_ID commit=$COMMIT env:${ENVS:- (defaults)}"

"${SSH[@]}" 'mkdir -p ~/lab-ablit-perf/job/minimax ~/lab-ablit-perf/job/catalog ~/lab-ablit-perf/src ~/lab-ablit-perf/logs ~/lab-ablit-perf/results' \
  || { blocker "mkdir failed"; exit 2; }
rsync -a --delete "$REPO/scripts/lab/parity-grid/" macstudio:lab-ablit-perf/job/parity-grid/ >> "$LOG" 2>&1 \
  && rsync -a --delete "$REPO/scripts/lab/ablit-perf/" macstudio:lab-ablit-perf/job/ablit-perf/ >> "$LOG" 2>&1 \
  && rsync -a "$REPO/scripts/lab/minimax/minimax_ablate.py" "$REPO/scripts/lab/minimax/publish_abliterated.py" \
       macstudio:lab-ablit-perf/job/minimax/ >> "$LOG" 2>&1 \
  && rsync -a "$REPO/phase3-binary/catalog/autotune/continuous-batching-policy.json" macstudio:lab-ablit-perf/job/catalog/ >> "$LOG" 2>&1 \
  && rsync -a --delete --exclude '.build*' --exclude '.swiftpm' "$REPO/phase3-binary/" macstudio:lab-ablit-perf/src/phase3-binary/ >> "$LOG" 2>&1 \
  || { blocker "copy to the Studio failed"; exit 2; }

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
env RUN_ID=$RUN_ID COMMIT=$COMMIT $ENVS nohup bash ./job/ablit-perf/job.sh > ./logs/job-$RUN_ID.log 2>&1 < /dev/null &
echo \$!
REMOTE
)
say "remote job pid=$PID"
[ -n "$PID" ] || { blocker "remote job did not start"; exit 4; }

seen=0; stalled=0
while :; do
  sleep 60
  alive=$("${SSH[@]}" "kill -0 $PID 2>/dev/null && echo yes || echo no") || alive=unknown
  new=$("${SSH[@]}" "grep -E '(BLOCKER|JOB_|BUILD_|STAGE_|GRID_|CB_CHECK|BASE_|NOISE_|BASELINE_MD|REF_VERSION)' ~/lab-ablit-perf/logs/job-$RUN_ID.log 2>/dev/null")
  n=$(printf '%s\n' "$new" | grep -c .)
  [ "$n" -gt "$seen" ] && { printf '%s\n' "$new" | tail -n +$((seen + 1)) | tee -a "$LOG"; seen=$n; }
  [ "$alive" = no ] && break
  [ "$alive" = unknown ] && { say "ssh probe failed, retrying"; continue; }
  fresh=$("${SSH[@]}" "find ~/lab-ablit-perf/results/$RUN_ID ~/lab-ablit-perf/logs ~/lab-ablit-perf/models ~/lab-ablit-perf/venv-vlm ~/lab-ablit-perf/venv-lm ~/lab-ablit-perf/src/phase3-binary/.build-lab-harness -type f -mmin -$STALL_MIN 2>/dev/null | head -n 1")
  if [ -z "$fresh" ]; then
    stalled=$((stalled + 1))
    [ $((stalled % STALL_MIN)) = 1 ] && blocker "no file progress for ${STALL_MIN}+ minutes; last job log lines: $("${SSH[@]}" "tail -n 2 ~/lab-ablit-perf/logs/job-$RUN_ID.log" | tr '\n' ' ')"
  else
    stalled=0
  fi
done
say "remote job exited"
"${SSH[@]}" "tail -n 15 ~/lab-ablit-perf/logs/job-$RUN_ID.log" | tee -a "$LOG"
