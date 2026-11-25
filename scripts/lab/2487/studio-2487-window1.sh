#!/bin/bash
# #2487 window 1 launcher, run on the dev Mac. Run ONLY inside a Studio window whose owner has
# already paused the live provider, the runner's Studio target and the FLOP miner; this script
# never pauses or restores any of them and refuses to start if the Studio is not paused.
#
# Copies job-omlx-dspark-baseline.sh (committed) to ~/lab-2487/job on the Studio, takes the
# Studio GPU lock, starts the job detached in its own process group with a free-memory guard
# beside it, watches it (stall watcher only, no wall-clock deadline; three failed ssh probes
# print STUDIO_SSH_LOST), pulls ~/lab-2487/results/<run> to $POC/scratchpad/2487/results/<run>,
# releases the lock at exit. Exit 0 only when the job printed JOB_PASS.
#
# Usage: studio-2487-window1.sh [--dry-run]   (settings pass through: ROUNDS REPEATS CHAT_PAUSE WORKLOADS)
# Estimated length (estimate, not measured): ~45 min. Venv + clones ~5 min; per server start
# model load ~1 min, synth + natural 4 x 1,024 tokens each, chat 4 x 48 GSM8K answers; 4 starts.
set -u
DRY=0; [ "${1:-}" = --dry-run ] && DRY=1
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
POC=${POC:-$HOME/macprovider-poc}
SCR=$POC/scratchpad/2487; RES=$SCR/results
RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)
LOG=$SCR/studio-2487-window1-$RUN_ID.log
LOCKSH=$POC/scratchpad/studio-lock.sh
OWNER=t2487-window1
STALL_MIN=20
SSH=(ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=6 macstudio)
JOB=scripts/lab/2487/job-omlx-dspark-baseline.sh
mkdir -p "$SCR" "$RES"; : > "$LOG"
say() { echo "$(date '+%H:%M:%S') $*" | tee -a "$LOG"; }
blocker() { say "BLOCKER: $*"; }

[ -z "$(git -C "$REPO" status --porcelain -- scripts/lab/2487)" ] || { blocker "uncommitted changes in scripts/lab/2487; commit first"; exit 2; }
for f in "$HERE"/*.sh; do bash -n "$f" || { blocker "$f does not parse"; exit 2; }; done
COMMIT=$(git -C "$REPO" rev-parse HEAD)
ENVS=""; for n in ROUNDS REPEATS CHAT_PAUSE WORKLOADS; do [ -n "${!n:-}" ] && ENVS="$ENVS $n=$(printf %q "${!n}")"; done
say "WINDOW1_START run=$RUN_ID commit=$COMMIT dry_run=$DRY env:${ENVS:- (defaults)}"
if [ "$DRY" = 1 ]; then
  bash "$REPO/$JOB" --dry-run 2>&1 | tee -a "$LOG"
  say "DRY studio$ mkdir -p lab-2487/job lab-2487/logs; scp $JOB; RUN_ID=$RUN_ID$ENVS nohup bash lab-2487/job/job.sh (own pgid) + memguard 10%"
  exit 0
fi

pre=$("${SSH[@]}" 'u=$(id -u)
  lsof -nP -iTCP:8080 -sTCP:LISTEN -t >/dev/null 2>&1 && echo LISTEN_8080
  launchctl print gui/$u/live.malibu.provider >/dev/null 2>&1 && echo LIVE_LOADED
  pgrep -f "[m]acprovider-cli serve" >/dev/null 2>&1 && echo SERVE_RUNNING
  launchctl list | grep -q com.flop && echo FLOP_AGENT
  echo done') || { blocker "ssh macstudio failed"; exit 2; }
[ "$pre" = done ] || { blocker "refusing to start, the Studio is not paused: $(echo "$pre" | grep -v '^done$' | tr '\n' ' ')"; exit 3; }
say "preflight ok: Studio paused"

STUDIO_LANE=gpu bash "$LOCKSH" acquire "$OWNER" >> "$LOG" 2>&1 || { blocker "Studio GPU lock busy"; exit 4; }
PID=""
finish() {
  if [ -n "$PID" ] && "${SSH[@]}" "kill -0 $PID 2>/dev/null"; then
    say "remote job still running at exit; stopping its process group $PID"
    "${SSH[@]}" "kill -TERM -- -$PID 2>/dev/null; sleep 10; kill -KILL -- -$PID 2>/dev/null; lsof -t -nP -iTCP:18600 -sTCP:LISTEN | xargs kill 2>/dev/null; true"
  fi
  mkdir -p "$RES/$RUN_ID"
  rsync -a "macstudio:lab-2487/results/$RUN_ID/" "$RES/$RUN_ID/" >> "$LOG" 2>&1 || blocker "results pull failed"
  rsync -a "macstudio:lab-2487/logs/job-$RUN_ID.log" "$RES/$RUN_ID/" >> "$LOG" 2>&1
  STUDIO_LANE=gpu bash "$LOCKSH" release "$OWNER" >> "$LOG" 2>&1; say "LOCK_RELEASED $OWNER"
  local jl=$RES/$RUN_ID/job-$RUN_ID.log
  if grep -q JOB_PASS "$jl" 2>/dev/null; then
    grep -h GOAL_CELL "$jl" | tee -a "$LOG"; say "WINDOW1_END pass. Results: $RES/$RUN_ID"
  else
    blocker "the job did not pass; see $jl"; say "WINDOW1_END fail"
  fi
}
trap finish EXIT

"${SSH[@]}" 'mkdir -p lab-2487/job lab-2487/logs' || { blocker "remote mkdir failed"; exit 5; }
scp -q "$REPO/$JOB" macstudio:lab-2487/job/job.sh || { blocker "scp job failed"; exit 5; }
scp -q "$REPO/scripts/lab/2487/memguard.sh" macstudio:lab-2487/job/memguard.sh || { blocker "scp memguard failed"; exit 5; }
PID=$("${SSH[@]}" "cd lab-2487 && RUN_ID=$RUN_ID$ENVS nohup /usr/bin/perl -e 'setpgrp(0,0); exec @ARGV' bash job/job.sh > logs/job-$RUN_ID.log 2>&1 < /dev/null & jp=\$!; nohup bash job/memguard.sh \$jp 10 logs/memguard-$RUN_ID.log > /dev/null 2>&1 < /dev/null & echo \$jp") \
  || { blocker "remote start failed"; exit 5; }
say "JOB_STARTED pid=$PID log=~/lab-2487/logs/job-$RUN_ID.log"

fails=0; last=""; still=0
while :; do
  sleep 60
  if out=$("${SSH[@]}" "kill -0 $PID 2>/dev/null && echo RUNNING; tail -n 1 lab-2487/logs/job-$RUN_ID.log; stat -f %m lab-2487/results/$RUN_ID/bench.out 2>/dev/null"); then
    fails=0
  else
    fails=$((fails + 1)); [ "$fails" -ge 3 ] && { blocker "STUDIO_SSH_LOST: 3 failed ssh probes"; exit 6; }; continue
  fi
  line=$(echo "$out" | sed -n 2p); case "$line" in *BLOCKER*) say "$line" ;; esac
  echo "$out" | grep -q '^RUNNING$' || break
  [ "$out" = "$last" ] && still=$((still + 1)) || still=0; last=$out
  [ "$still" -ge "$STALL_MIN" ] && { blocker "no progress for $STALL_MIN min"; exit 7; }
done
PID=""
