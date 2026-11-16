#!/bin/bash
# Epic #2376 (MiniMax M3.1-Flash abliterated variant) Studio window launcher, run on the dev Mac.
# Run ONLY after the KPI session sends "2376 GO". The live provider and the runner's Studio
# target are paused by the KPI session: this script never pauses, restores or restarts either,
# and refuses to start if :8080 listens on the Studio or live.malibu.provider is loaded.
#
# Copies scripts/lab/minimax/{minimax_ablate.py,job-2376.sh} and the prompt/KL data to
# ~/lab-2376/job, takes the studio GPU lock, starts job-2376.sh detached, watches it (stall
# watcher, no wall-clock deadline), pulls ~/lab-2376/results back, releases the lock at exit.
#
# Usage: DATA=<dir with the prompt sets and wikitext2_test.txt> studio-2376.sh
#        JOB_SCRIPT=job-2376-publish.sh [PUBLISH_ARGS=--dry-run] studio-2376.sh   (stage + publish)
# Log: scratchpad/2376/studio-2376.log   Results: scratchpad/2376/results/
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
POC=${POC:-$HOME/macprovider-poc}  # the checkout that holds scratchpad/ and the lock helper
SCR=$POC/scratchpad/2376
DATA=${DATA:-$SCR/data}
LOG=$SCR/studio-2376.log
RES=$SCR/results
LOCKSH=$POC/scratchpad/studio-lock.sh
OWNER=minimax-2376
STALL_MIN=30
SSH=(ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=6 macstudio)
say() { echo "$(date '+%H:%M:%S') $*" | tee -a "$LOG"; }
blocker() { say "BLOCKER: $*"; }
case "${JOB_SCRIPT:-job-2376.sh}" in job-2376*.sh) ;; *) echo "BLOCKER: JOB_SCRIPT must be a job-2376*.sh name" >&2; exit 2 ;; esac
case "${JOB_SCRIPT:-}" in */*) echo "BLOCKER: JOB_SCRIPT must be a bare name" >&2; exit 2 ;; esac
mkdir -p "$SCR" "$RES"
: > "$LOG"

pre=$("${SSH[@]}" 'u=$(id -u)
  if lsof -nP -iTCP:8080 -sTCP:LISTEN -t >/dev/null 2>&1; then echo LISTEN_8080; fi
  launchctl print gui/$u/live.malibu.provider >/dev/null 2>&1 && echo LIVE_LOADED
  pgrep -f "[m]acprovider-cli serve" >/dev/null 2>&1 && echo SERVE_RUNNING
  echo done') || { blocker "ssh macstudio failed"; exit 2; }
case "$pre" in
  done) say "preflight ok: :8080 free, live.malibu.provider absent, no serve process" ;;
  *) blocker "refusing to start, the Studio is not paused: $(echo "$pre" | grep -v '^done$' | tr '\n' ' ')"; exit 3 ;;
esac

[ -f "$DATA/wikitext2_test.txt" ] || { blocker "no data under $DATA"; exit 2; }
(cd "$DATA" && shasum -a 256 harmful_train.json harmless_train.json harmful_test.json harmless_test.json wikitext2_test.txt) > "$SCR/data.sha256"
"${SSH[@]}" 'mkdir -p ~/lab-2376/job/data ~/lab-2376/logs ~/lab-2376/results' || { blocker "mkdir failed"; exit 2; }
rsync -a "$HERE/minimax_ablate.py" "$HERE/publish_abliterated.py" "$HERE/minimax_parity_oracle.py" "$HERE/job-2376.sh" \
  "$HERE/job-2376-publish.sh" "$HERE/job-2376-parity.sh" "$HERE/../cb-studio/glm53_bench_vlm.py" "$HERE/../cb-studio/glm53_oracle_json.py" \
  "$SCR/data.sha256" macstudio:lab-2376/job/ >> "$LOG" 2>&1 \
  && rsync -a --delete "$DATA/" macstudio:lab-2376/job/data/ >> "$LOG" 2>&1 || { blocker "copy failed"; exit 2; }
if [ "${JOB_SCRIPT:-}" = job-2376-parity.sh ]; then
  # The lab-harness build compiles this checkout's provider sources on the Studio.
  "${SSH[@]}" 'mkdir -p ~/lab-2376/src' && rsync -a --delete --exclude '.build*' --exclude '.swiftpm' \
    "$HERE/../../../phase3-binary/" macstudio:lab-2376/src/phase3-binary/ >> "$LOG" 2>&1 || { blocker "source copy failed"; exit 2; }
fi
say "2376_START commit=$(git -C "$HERE" rev-parse --short HEAD) args=\"${ABLATE_ARGS:-}\""

HAVE_GPU=0; PID=""
finish() {
  if [ -n "$PID" ] && "${SSH[@]}" "kill -0 $PID 2>/dev/null"; then
    say "remote job still running at exit; killing its process group $PID"
    "${SSH[@]}" "kill -TERM -- -$PID 2>/dev/null; sleep 15; kill -KILL -- -$PID 2>/dev/null"
  fi
  rsync -a "macstudio:lab-2376/results/" "$RES/" >> "$LOG" 2>&1
  rsync -a "macstudio:lab-2376/logs/" "$SCR/logs/" >> "$LOG" 2>&1
  [ "$HAVE_GPU" = 1 ] && STUDIO_LANE=gpu bash "$LOCKSH" release "$OWNER" >> "$LOG" 2>&1
  say "LOCKS_RELEASED $(bash "$LOCKSH" status 2>&1 | tr '\n' ' ')"
  [ -f "$RES/summary.txt" ] && tee -a "$LOG" < "$RES/summary.txt"
  say "2376_END. Send \"2376 DONE\" to the KPI session now."
}
trap finish EXIT
trap 'exit 130' INT TERM HUP
STUDIO_LANE=gpu bash "$LOCKSH" acquire "$OWNER" >> "$LOG" 2>&1 || { blocker "gpu lock acquire failed"; exit 3; }
HAVE_GPU=1
say "LOCKS_ACQUIRED"

PID=$("${SSH[@]}" "bash -s" <<REMOTE
set -m
cd ~/lab-2376
LOCAL_STAGE=$(printf %q "${LOCAL_STAGE:-0}") EXPECT_STAGE=$(printf %q "${EXPECT_STAGE:-}") PUBLISH_ARGS=$(printf %q "${PUBLISH_ARGS:-}") ABLATE_ARGS=$(printf %q "${ABLATE_ARGS:-}") nohup bash ./job/$(printf %q "${JOB_SCRIPT:-job-2376.sh}") > ./logs/job.log 2>&1 < /dev/null &
echo \$!
REMOTE
)
say "remote job pid=$PID"
[ -n "$PID" ] || { blocker "remote job did not start"; exit 4; }

seen=0; stalled=0
while :; do
  sleep 60
  alive=$("${SSH[@]}" "kill -0 $PID 2>/dev/null && echo yes || echo no") || alive=unknown
  new=$("${SSH[@]}" "grep -E '(BLOCKER|JOB_(START|PASS)|ABLATE_|PUBLISH_|PARITY_|ORACLE_)' ~/lab-2376/logs/job.log ~/lab-2376/results/ablate.stdout 2>/dev/null | sed 's/^[^:]*://'")
  n=$(printf '%s\n' "$new" | grep -c .)
  [ "$n" -gt "$seen" ] && { printf '%s\n' "$new" | tail -n +$((seen + 1)) | tee -a "$LOG"; seen=$n; }
  [ "$alive" = no ] && break
  [ "$alive" = unknown ] && { say "ssh probe failed, retrying"; continue; }
  fresh=$("${SSH[@]}" "find ~/lab-2376/results ~/lab-2376/logs ~/lab-2376/venv-vlm ~/lab-2376/publish -type f -mmin -$STALL_MIN 2>/dev/null | head -n 1")
  if [ -z "$fresh" ]; then
    stalled=$((stalled + 1))
    [ $((stalled % STALL_MIN)) = 1 ] && blocker "no file progress for ${STALL_MIN}+ minutes; last job.log lines: $("${SSH[@]}" "tail -n 2 ~/lab-2376/logs/job.log" | tr '\n' ' ')"
  else
    stalled=0
  fi
done
say "remote job exited"
"${SSH[@]}" "tail -n 15 ~/lab-2376/logs/job.log" | tee -a "$LOG"
