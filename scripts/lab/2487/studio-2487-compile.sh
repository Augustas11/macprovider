#!/bin/bash
# #2487 fork compile + unit tests on the Studio, launched from the dev Mac. Run inside a Studio
# window whose owner already paused live, the runner's Studio target and the FLOP miner; this
# script never pauses or restores anything and refuses to start if the Studio is not paused.
#
# Copies job-fork-compile.sh and phase3-binary/scripts/build-mlx-metallib.sh to ~/lab-2487/job,
# takes the Studio GPU lock, starts the job detached in its own process group, watches it (stall
# watcher only; three failed ssh probes print STUDIO_SSH_LOST), stops that process group if it is
# still running at exit, pulls ~/lab-2487/results/compile-<run> to
# $POC/scratchpad/2487/results/compile-<run>, releases the lock. The job refuses under 20 GB free.
# Last line: T2487_COMPILE rc=<n> PASS|FAIL.
#
# Usage: studio-2487-compile.sh [--dry-run]   env: FORK_REF (default below), FILTER
# Estimated length (estimate, not measured): 20-30 min, mostly the cold package build.
set -u
DRY=0; [ "${1:-}" = --dry-run ] && DRY=1
FORK_REF=${FORK_REF:-08de0ae}
FILTER=${FILTER:-Inkling2|ConvolutionTail|KVCacheRound}
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
POC=${POC:-$HOME/macprovider-poc}
SCR=$POC/scratchpad/2487; RES=$SCR/results
RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)
LOG=$SCR/studio-2487-compile-$RUN_ID.log
LOCKSH=$POC/scratchpad/studio-lock.sh
OWNER=t2487-compile
STALL_MIN=20
SSH=(ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=6 macstudio)
JOB=scripts/lab/2487/job-fork-compile.sh
METAL=phase3-binary/scripts/build-mlx-metallib.sh
RC=99
mkdir -p "$SCR" "$RES"; : > "$LOG"
say() { echo "$(date '+%H:%M:%S') $*" | tee -a "$LOG"; }
blocker() { say "BLOCKER: $*"; }
final() { say "T2487_COMPILE rc=$RC $([ "$RC" = 0 ] && echo PASS || echo FAIL)"; }

for f in "$REPO/$JOB" "$REPO/$METAL" "$0"; do
  bash -n "$f" || { blocker "$f does not parse"; final; exit 2; }
done
[ -z "$(git -C "$REPO" status --porcelain -- scripts/lab/2487 "$METAL")" ] \
  || { blocker "uncommitted changes in scripts/lab/2487 or $METAL; commit first"; final; exit 2; }
say "COMPILE_START run=$RUN_ID macprovider=$(git -C "$REPO" rev-parse --short HEAD) fork_ref=$FORK_REF filter=$FILTER dry_run=$DRY log=$LOG"
if [ "$DRY" = 1 ]; then
  say "DRY studio$ df -g ~ (>= 20 GB); mkdir -p lab-2487/job lab-2487/logs; scp $JOB $METAL"
  say "DRY studio$ RUN_ID=$RUN_ID FORK_REF=$FORK_REF nohup bash lab-2487/job/job-fork-compile.sh (own pgid)"
  RC=0; say "DRY ok"; exit 0
fi

pre=$("${SSH[@]}" 'u=$(id -u)
  lsof -nP -iTCP:8080 -sTCP:LISTEN -t >/dev/null 2>&1 && echo LISTEN_8080
  launchctl print gui/$u/live.malibu.provider >/dev/null 2>&1 && echo LIVE_LOADED
  pgrep -f "[m]acprovider-cli serve" >/dev/null 2>&1 && echo SERVE_RUNNING
  launchctl list | grep -q com.flop && echo FLOP_AGENT
  echo "FREE_GB $(df -g ~ | awk "NR==2{print \$4}")"
  echo done') || { blocker "ssh macstudio failed"; final; exit 2; }
busy=$(echo "$pre" | grep -vE '^(done|FREE_GB .*)$')
[ -z "$busy" ] || { blocker "refusing to start, the Studio is not paused: $(echo "$busy" | tr '\n' ' ')"; final; exit 3; }
free_gb=$(echo "$pre" | awk '/^FREE_GB/{print $2}')
[ "${free_gb:-0}" -ge 20 ] || { blocker "only ${free_gb:-?} GB free on the Studio (need 20)"; final; exit 3; }
say "preflight ok: Studio paused, ${free_gb} GB free"

STUDIO_LANE=gpu bash "$LOCKSH" acquire "$OWNER" >> "$LOG" 2>&1 || { blocker "Studio GPU lock busy"; final; exit 4; }
PID=""
finish() {
  if [ -n "$PID" ] && "${SSH[@]}" "kill -0 $PID 2>/dev/null"; then
    say "remote job still running at exit; stopping its process group $PID"
    "${SSH[@]}" "kill -TERM -- -$PID 2>/dev/null; sleep 10; kill -KILL -- -$PID 2>/dev/null; true"
  fi
  mkdir -p "$RES/compile-$RUN_ID"
  rsync -a "macstudio:lab-2487/results/compile-$RUN_ID/" "$RES/compile-$RUN_ID/" \
    --exclude metallib >> "$LOG" 2>&1 || blocker "results pull failed"
  rsync -a "macstudio:lab-2487/logs/compile-$RUN_ID.log" "$RES/compile-$RUN_ID/" >> "$LOG" 2>&1
  STUDIO_LANE=gpu bash "$LOCKSH" release "$OWNER" >> "$LOG" 2>&1; say "LOCK_RELEASED $OWNER"
  local jl=$RES/compile-$RUN_ID/compile-$RUN_ID.log
  line=$(grep -h '^.* T2487_COMPILE rc=' "$jl" 2>/dev/null | tail -1)
  if [ -n "$line" ]; then
    grep -hE 'BLOCKER:|error:|failed|passed|✘|✔' "$jl" | tail -40 >> "$LOG"
    RC=$(echo "$line" | sed -E 's/.*rc=([0-9]+).*/\1/')
  else
    blocker "the job printed no T2487_COMPILE line; see $jl"
  fi
  say "Results: $RES/compile-$RUN_ID"
  final
  exit "$RC"
}
trap finish EXIT

"${SSH[@]}" 'mkdir -p lab-2487/job lab-2487/logs' || { blocker "remote mkdir failed"; exit 5; }
scp -q "$REPO/$JOB" macstudio:lab-2487/job/job-fork-compile.sh || { blocker "scp job failed"; exit 5; }
scp -q "$REPO/$METAL" macstudio:lab-2487/job/build-mlx-metallib.sh || { blocker "scp metallib script failed"; exit 5; }
PID=$("${SSH[@]}" "cd lab-2487 && RUN_ID=$RUN_ID FORK_REF=$FORK_REF FILTER='$FILTER' nohup /usr/bin/perl -e 'setpgrp(0,0); exec @ARGV' bash job/job-fork-compile.sh > logs/compile-$RUN_ID.log 2>&1 < /dev/null & echo \$!") \
  || { blocker "remote start failed"; exit 5; }
say "JOB_STARTED pid=$PID log=~/lab-2487/logs/compile-$RUN_ID.log"

fails=0; last=""; still=0
while :; do
  sleep 60
  if out=$("${SSH[@]}" "kill -0 $PID 2>/dev/null && echo RUNNING; tail -n 1 lab-2487/logs/compile-$RUN_ID.log; ls -l lab-2487/results/compile-$RUN_ID 2>/dev/null | md5"); then
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
exit 0
