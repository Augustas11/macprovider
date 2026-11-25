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
# Usage: studio-2487-compile.sh [--bench] [--dry-run]   env: FORK_REF (default below), FILTER;
#   --bench: job-fork-dspark-bench.sh instead (release build, loads the oQ4e model, memguard 10%;
#   env PROMPT_COUNT TOKENS BLOCK PREFILL_STEP pass through).
# Estimated length (estimate, not measured): 20-30 min, mostly the cold package build; --bench
# adds a cold release build (~15 min) and 8 prompts x 512 tokens x 2 paths (~5 min).
set -u
DRY=0; BENCH=0
for a in "$@"; do
  case "$a" in --dry-run) DRY=1 ;; --bench) BENCH=1 ;; *) echo "unknown argument $a"; exit 2 ;; esac
done
FORK_REF=${FORK_REF:-7e7ab72}
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
[ "$BENCH" = 1 ] && JOB=scripts/lab/2487/job-fork-dspark-bench.sh
ENVS=""; for n in PROMPT_COUNT TOKENS BLOCK PREFILL_STEP; do [ -n "${!n:-}" ] && ENVS="$ENVS $n=$(printf %q "${!n}")"; done
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
say "COMPILE_START run=$RUN_ID macprovider=$(git -C "$REPO" rev-parse --short HEAD) fork_ref=$FORK_REF job=$(basename "$JOB") filter=$FILTER env:${ENVS:- (defaults)} dry_run=$DRY log=$LOG"
if [ "$DRY" = 1 ]; then
  say "DRY studio$ df -g ~ (>= 20 GB); mkdir -p lab-2487/job lab-2487/logs; scp $JOB $METAL"
  say "DRY studio$ RUN_ID=$RUN_ID FORK_REF=$FORK_REF$ENVS nohup bash lab-2487/job/$(basename "$JOB") (own pgid)$([ "$BENCH" = 1 ] && echo ' + memguard 10%')"
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
    grep -hE 'BLOCKER:|error:|failed|passed|✘|✔|DSPARK_' "$jl" | tail -40 | tee -a "$LOG"
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
scp -q "$REPO/$JOB" "macstudio:lab-2487/job/$(basename "$JOB")" || { blocker "scp job failed"; exit 5; }
scp -q "$REPO/scripts/lab/2487/memguard.sh" macstudio:lab-2487/job/memguard.sh || { blocker "scp memguard failed"; exit 5; }
scp -q "$REPO/$METAL" macstudio:lab-2487/job/build-mlx-metallib.sh || { blocker "scp metallib script failed"; exit 5; }
GUARD=""
[ "$BENCH" = 1 ] && GUARD="nohup bash job/memguard.sh \$jp 10 logs/memguard-$RUN_ID.log > /dev/null 2>&1 < /dev/null &"
PID=$("${SSH[@]}" "cd lab-2487 && RUN_ID=$RUN_ID FORK_REF=$FORK_REF FILTER='$FILTER'$ENVS nohup /usr/bin/perl -e 'setpgrp(0,0); exec @ARGV' bash job/$(basename "$JOB") > logs/compile-$RUN_ID.log 2>&1 < /dev/null & jp=\$!; $GUARD echo \$jp") \
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
