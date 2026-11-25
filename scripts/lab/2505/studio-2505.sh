#!/bin/bash
# #2505 Inkling 2 continuous batching on the Studio, launched from the dev Mac inside a Studio
# window whose owner already paused live, the runner's Studio target and the FLOP miner. This
# script never pauses or restores anything and refuses to start if the Studio is not paused.
#
# Ships the committed campaign HEAD (git archive of phase3-binary and scripts/lab/2505) to
# ~/lab-2505/src-<sha12>, takes the Studio GPU lock, starts job.sh detached in its own process
# group with memguard.sh (10% free floor), watches it (stall watcher only, no wall-clock cut;
# three failed ssh probes print STUDIO_SSH_LOST), stops that process group if it still runs at
# exit, pulls ~/lab-2505/results/<run> to $POC/scratchpad/2505/results/<run>, releases the lock.
# Last line: T2505 rc=<n> PASS|FAIL.
#
# Usage: studio-2505.sh [--dry-run]   env: STEPS (job default "fork provider parity throughput"),
#   BIN (Studio path of an earlier lab-harness release directory, for steps without a rebuild),
#   FORK_REF (default: the head of the fork branch macprovider/2505-inkling2-cb-rebase).
# Estimated length (estimate, not measured): cold fork build ~15 min, provider debug + release
# builds ~30 min, parity 2 cells and throughput 4 cells ~20 min.
set -u
DRY=0
for a in "$@"; do case "$a" in --dry-run) DRY=1 ;; *) echo "unknown argument $a"; exit 2 ;; esac; done
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
POC=${POC:-$HOME/macprovider-poc}
SCR=$POC/scratchpad/2505; RES=$SCR/results
RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)
LOG=$SCR/studio-2505-$RUN_ID.log
LOCKSH=$POC/scratchpad/studio-lock.sh
OWNER=t2505
STALL_MIN=30
SSH=(ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=6 macstudio)
SHIP=(phase3-binary scripts/lab/2505)
RC=99
mkdir -p "$SCR" "$RES"; : > "$LOG"
say() { echo "$(date '+%H:%M:%S') $*" | tee -a "$LOG"; }
blocker() { say "BLOCKER: $*"; }
final() { say "T2505 rc=$RC $([ "$RC" = 0 ] && echo PASS || echo FAIL)"; }

for f in "$HERE/job.sh" "$HERE/memguard.sh" "$0"; do
  bash -n "$f" || { blocker "$f does not parse"; final; exit 2; }
done
# The job ships `git archive` of the committed HEAD; nothing needs to be pushed.
COMMIT=$(git -C "$REPO" rev-parse HEAD)
[ -z "$(git -C "$REPO" status --porcelain -- "${SHIP[@]}")" ] || { blocker "uncommitted changes under ${SHIP[*]}; commit and push first"; final; exit 2; }
FORK_REF=${FORK_REF:-$(git ls-remote https://github.com/Augustas11/mlx-swift-lm.git refs/heads/macprovider/2505-inkling2-cb-rebase | cut -f1)}
echo "$FORK_REF" | grep -Eq '^[0-9a-f]{7,40}$' || { blocker "no fork ref"; final; exit 2; }
STEPS=${STEPS:-fork provider parity throughput}
# BIN: an earlier run's lab-harness release directory on the Studio (steps without a rebuild).
BIN_ENV=""; [ -n "${BIN:-}" ] && BIN_ENV=" BIN=$BIN"
SRC_REMOTE=lab-2505/src-${COMMIT:0:12}
say "T2505_START run=$RUN_ID commit=${COMMIT:0:12} fork=${FORK_REF:0:12} steps=\"$STEPS\" dry_run=$DRY log=$LOG"
if [ "$DRY" = 1 ]; then
  say "DRY git archive $COMMIT ${SHIP[*]} | ssh macstudio tar -x -C $SRC_REMOTE"
  say "DRY studio$ RUN_ID=$RUN_ID SRC=~/$SRC_REMOTE COMMIT=$COMMIT FORK_REF=$FORK_REF STEPS=\"$STEPS\" nohup bash job.sh (own pgid) + memguard 10%"
  RC=0; final; exit 0
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
[ "${free_gb:-0}" -ge 40 ] || { blocker "only ${free_gb:-?} GB free on the Studio (need 40)"; final; exit 3; }
say "preflight ok: Studio paused, ${free_gb} GB free"

STUDIO_LANE=gpu bash "$LOCKSH" acquire "$OWNER" >> "$LOG" 2>&1 || { blocker "Studio GPU lock busy"; final; exit 4; }
PID=""
finish() {
  if [ -n "$PID" ] && "${SSH[@]}" "kill -0 $PID 2>/dev/null"; then
    say "remote job still running at exit; stopping its process group $PID"
    "${SSH[@]}" "kill -TERM -- -$PID 2>/dev/null; sleep 10; kill -KILL -- -$PID 2>/dev/null; true"
  fi
  mkdir -p "$RES/$RUN_ID"
  rsync -a --exclude '*metallib' "macstudio:lab-2505/results/$RUN_ID/" "$RES/$RUN_ID/" >> "$LOG" 2>&1 || blocker "results pull failed"
  rsync -a "macstudio:lab-2505/logs/job-$RUN_ID.log" "macstudio:lab-2505/logs/memguard-$RUN_ID.log" "$RES/$RUN_ID/" >> "$LOG" 2>&1
  STUDIO_LANE=gpu bash "$LOCKSH" release "$OWNER" >> "$LOG" 2>&1; say "LOCK_RELEASED $OWNER"
  local jl=$RES/$RUN_ID/job-$RUN_ID.log line
  line=$(grep -h ' T2505 rc=' "$jl" 2>/dev/null | tail -1)
  if [ -n "$line" ]; then
    grep -hE 'BLOCKER:|CELL_DONE|FORK |BUILD_DONE|Executed|failed|inkling2 batch rows' "$jl" | tail -40 | tee -a "$LOG"
    RC=$(echo "$line" | sed -E 's/.*rc=([0-9]+).*/\1/')
  else
    blocker "the job printed no T2505 line; see $jl"
  fi
  say "Results: $RES/$RUN_ID"
  final
  exit "$RC"
}
trap finish EXIT

"${SSH[@]}" "mkdir -p lab-2505/logs $SRC_REMOTE" || { blocker "remote mkdir failed"; exit 5; }
git -C "$REPO" archive --format=tar "$COMMIT" "${SHIP[@]}" | "${SSH[@]}" "tar -x -C $SRC_REMOTE" \
  || { blocker "shipping $COMMIT failed"; exit 5; }
PID=$("${SSH[@]}" "cd lab-2505 && RUN_ID=$RUN_ID SRC=\$HOME/$SRC_REMOTE COMMIT=$COMMIT FORK_REF=$FORK_REF STEPS='$STEPS'$BIN_ENV nohup /usr/bin/perl -e 'setpgrp(0,0); exec @ARGV' bash \$HOME/$SRC_REMOTE/scripts/lab/2505/job.sh > logs/job-$RUN_ID.log 2>&1 < /dev/null & jp=\$!; nohup bash \$HOME/$SRC_REMOTE/scripts/lab/2505/memguard.sh \$jp 10 logs/memguard-$RUN_ID.log > /dev/null 2>&1 < /dev/null & echo \$jp") \
  || { blocker "remote start failed"; exit 5; }
say "JOB_STARTED pid=$PID log=~/lab-2505/logs/job-$RUN_ID.log"

fails=0; last=""; still=0
while :; do
  sleep 60
  if out=$("${SSH[@]}" "kill -0 $PID 2>/dev/null && echo RUNNING; tail -n 1 lab-2505/logs/job-$RUN_ID.log; ls -l lab-2505/results/$RUN_ID 2>/dev/null | md5; ls -l $SRC_REMOTE/phase3-binary/.build-lab-2505 2>/dev/null | md5"); then
    fails=0
  else
    fails=$((fails + 1)); [ "$fails" -ge 3 ] && { blocker "STUDIO_SSH_LOST: 3 failed ssh probes"; exit 6; }; continue
  fi
  line=$(echo "$out" | sed -n 2p); case "$line" in *BLOCKER*|*CELL_DONE*|*FORK_TEST*|*BUILD_DONE*) say "$line" ;; esac
  echo "$out" | grep -q '^RUNNING$' || break
  [ "$out" = "$last" ] && still=$((still + 1)) || still=0; last=$out
  [ "$still" -ge "$STALL_MIN" ] && { blocker "no progress for $STALL_MIN min"; exit 7; }
done
PID=""
exit 0
