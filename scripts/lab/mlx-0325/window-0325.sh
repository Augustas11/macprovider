#!/bin/bash
# Studio slot for the mlx v0.32.5 fork-sync campaign (branch campaign/mlx-0325). Runs on the operator
# Mac and drives the Studio over ssh; queued by the Studio queue owner (scratchpad/windows/queue.txt).
# Modelled on window-2524.sh minus every pause/restore step: the queue line around it pauses the miner
# and restores it afterwards; live stays off and the Studio has no runner target. This script never
# touches live, the runner, the miner or any dextr process.
#
# usage: MODE=build|gpu KEEP_PAUSED=1 window-0325.sh [--dry-run] [LOG]
#   MODE=build  job-build.sh: core build + small-M/route/tile doctests, mlx-swift regenerate + build +
#               route tests (no model loads; ~1.5 h)
#   MODE=gpu    job-gpu.sh: base (origin/main) and new provider release builds, then GLM-5.3-Flash cb +
#               native-MTP passes at 4/8/16 rows, base1/new/base2 (~3-4 h)
#   --dry-run   prints every Studio command instead of running it and runs the job's JOB_CHECK locally.
#               Nothing on the Studio runs.
# Knobs passed to the job: ROWS OUTPUTS CONTEXTS TRIALS QUEUE_LIMIT PASSES GLM_DIR GLM_KEY MIN_FREE_GB;
#   MEMGUARD_FLOOR_PCT (default 10) for the free-memory guard beside the job.
# Fork revisions come from revs.env in the shipped commit; each must be its pushed fork branch tip.
# Lock: takes the GPU lock (~/lab-heavy.lock.d) at the start and RELEASES it in the EXIT trap.
# Prints WINDOW_END rc=N and HANDOVER_READY last; a failure prints a BLOCKER: line before them.
set -u
DRY=0
[ "${KEEP_PAUSED:-0}" = 1 ] || { echo "BLOCKER: window-0325 runs only with KEEP_PAUSED=1 (Studio dedicated to dextr.space)" >&2; exit 2; }
if [ "${1:-}" = --dry-run ]; then DRY=1; shift; fi
MODE=${MODE:-}
case "$MODE" in build|gpu) ;; *) echo "BLOCKER: MODE must be build or gpu" >&2; exit 2 ;; esac
POC=/Users/augstar/macprovider-poc
WT=${WT:-$(cd "$(dirname "$0")/../../.." && pwd)}
BRANCH=campaign/mlx-0325
RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)-$MODE
LOG=${1:-$POC/scratchpad/windows/window-0325-$RUN_ID.log}
RES_LOCAL=$POC/scratchpad/mlx-0325/results/$RUN_ID
LOCKSH=$POC/scratchpad/studio-lock.sh
OWNER=claude-upstream-mlx0325
STALL_MIN=30
SHIP_PATHS=(phase3-binary scripts/lab/mlx-0325 scripts/lab/parity-grid scripts/lab/engine-333)
PROGRESS='^[0-9:]+ (BLOCKER|JOB_|STEP|BUILD_|GRID_|MODEL|MEMORY)|^(SUMMARY|GRID_LINE|MLX0325_)'
SSH=(ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=6 macstudio)
mkdir -p "$(dirname "$LOG")"
exec 3>&2
say() { echo "$(date '+%H:%M:%S') $*" | tee -a "$LOG"; }
st() {
  if [ "$DRY" = 1 ]; then printf 'DRY studio$ %s\n' "$*" | tee -a "$LOG" >&3; return 0; fi
  "${SSH[@]}" "$@"
}
st_script() {
  if [ "$DRY" = 1 ]; then
    printf 'DRY studio$ bash -s -- %s <<SCRIPT\n' "$*" | tee -a "$LOG" >&3
    sed 's/^/DRY   | /' | tee -a "$LOG" >&3
    printf 'DRY   SCRIPT\n' | tee -a "$LOG" >&3
    return 0
  fi
  "${SSH[@]}" "bash -s -- $*"
}
lc() {
  if [ "$DRY" = 1 ]; then printf 'DRY local$ %s\n' "$*" | tee -a "$LOG" >&3; return 0; fi
  "$@"
}

say "WINDOW_0325 mode=$MODE run=$RUN_ID dry_run=$DRY log=$LOG"

# 0. Local: the shipped commit is the pushed branch tip with no local edits; fork revisions are pushed tips.
git -C "$WT" fetch -q origin "$BRANCH" || { say "BLOCKER: git fetch origin $BRANCH failed"; exit 2; }
COMMIT=$(git -C "$WT" rev-parse HEAD)
REMOTE=$(git -C "$WT" rev-parse "origin/$BRANCH")
[ "$COMMIT" = "$REMOTE" ] || { say "BLOCKER: $WT HEAD $COMMIT is not origin/$BRANCH $REMOTE; push or reset first"; exit 2; }
dirty=$(git -C "$WT" status --porcelain -- "${SHIP_PATHS[@]}")
[ -z "$dirty" ] || { say "BLOCKER: uncommitted changes in the shipped paths: $(echo "$dirty" | head -n 3 | tr '\n' ' ')"; exit 2; }
for f in job-build.sh job-gpu.sh window.sh memguard.sh summary.py revs.env; do
  git -C "$WT" cat-file -e "HEAD:scripts/lab/mlx-0325/$f" 2>/dev/null || { say "BLOCKER: HEAD has no scripts/lab/mlx-0325/$f"; exit 2; }
done
git -C "$WT" fetch -q origin main || { say "BLOCKER: git fetch origin main failed"; exit 2; }
MAIN=$(git -C "$WT" rev-parse origin/main)
eval "$(git -C "$WT" show "$COMMIT:scripts/lab/mlx-0325/revs.env" | grep -E '^(MLX|MLXC|SWIFT)_(REV|BRANCH)=[A-Za-z0-9._/-]+$')"
for r in MLX:mlx MLXC:mlx-c SWIFT:mlx-swift; do
  v=${r%%:*}; repo=${r#*:}; rev_var=${v}_REV; br_var=${v}_BRANCH
  [ -n "${!rev_var:-}" ] && [ -n "${!br_var:-}" ] || { say "BLOCKER: revs.env lacks ${rev_var}/${br_var}"; exit 2; }
  tip=$(git ls-remote "https://github.com/Augustas11/$repo.git" "refs/heads/${!br_var}" | cut -f1)
  [ "$tip" = "${!rev_var}" ] || { say "BLOCKER: $repo ${!br_var} tip '$tip' is not revs.env ${!rev_var}; push first"; exit 2; }
done
SHORT=${COMMIT:0:12}
SRC_REMOTE="\$HOME/lab-mlx-0325/src-$SHORT"
say "COMMIT $COMMIT ($BRANCH) main $MAIN mlx $MLX_REV mlx-c $MLXC_REV mlx-swift $SWIFT_REV"

JOB_ENV=() LOCAL_ENV=()
for n in ROWS OUTPUTS CONTEXTS TRIALS QUEUE_LIMIT PASSES GLM_DIR GLM_KEY MIN_FREE_GB; do
  [ -z "${!n:-}" ] || { JOB_ENV+=("$(printf '%q' "$n=${!n}")"); LOCAL_ENV+=("$n=${!n}"); }
done
JOB_ENV+=("MLX_REV=$MLX_REV" "MLXC_REV=$MLXC_REV" "SWIFT_REV=$SWIFT_REV")
LOCAL_ENV+=("MLX_REV=$MLX_REV" "MLXC_REV=$MLXC_REV" "SWIFT_REV=$SWIFT_REV")
JOB=job-$MODE.sh
say "JOB $JOB ENV ${JOB_ENV[*]}"

if [ "$DRY" = 1 ]; then
  CHECK_SRC=$POC/scratchpad/mlx-0325/check-$RUN_ID
  mkdir -p "$CHECK_SRC"
  git -C "$WT" archive --format=tar "$COMMIT" scripts/lab/mlx-0325 | tar -x -C "$CHECK_SRC"
  env -i HOME="$HOME" PATH=/usr/bin:/bin JOB_CHECK=1 LAB="$CHECK_SRC/lab" RUN_ID="$RUN_ID" SRC="$CHECK_SRC" BASE_SRC="$CHECK_SRC" \
    "${LOCAL_ENV[@]}" bash "$CHECK_SRC/scripts/lab/mlx-0325/$JOB" 2>&1 | sed 's/^/JOB_CHECK | /' | tee -a "$LOG"
  [ "${PIPESTATUS[0]}" = 0 ] || { say "BLOCKER: the job's JOB_CHECK failed"; exit 2; }
  rm -rf "$CHECK_SRC"
fi

# 1. Studio preflight: no other window, build or lock holder; live off, no miner VM (refuse, never act).
# shellcheck disable=SC2016  # expands on the Studio
pre=$(st 'for L in ~/lab-heavy.lock.d; do [ -d $L ] && echo "LOCK_HELD $(cat $L/owner 2>/dev/null)"; done
  pgrep -fl "swift-build|swift-frontend|xcodebuild|lab-[a-z0-9-]*/.*macprovider-cli|mlx_lm|mlx_vlm|omlx|lab-[a-z0-9-]*/job" 2>/dev/null | grep -v pgrep | cut -c1-160 | sed "s/^/BUSY /"
  lsof -nP -iTCP:8080 -sTCP:LISTEN -t >/dev/null 2>&1 && echo "LIVE_LISTENING 8080"
  pgrep -f "[c]om.apple.Virtualization.VirtualMachine" >/dev/null && echo "MINER_VM running"
  echo "FREE_DISK_GB $(df -g /System/Volumes/Data | awk "NR==2 {print \$4}")"
  echo done') || { say "BLOCKER: ssh macstudio failed"; exit 2; }
disk=$(echo "$pre" | awk '/^FREE_DISK_GB/ {print $2}')
pre=$(echo "$pre" | grep -v '^FREE_DISK_GB')
case "$pre" in
  done|"") say "STUDIO_PREFLIGHT ok (free disk ${disk:-?} GB)" ;;
  *) say "BLOCKER: Studio not ready for window-0325: $(echo "$pre" | grep -v '^done$' | tr '\n' ' ' | cut -c1-400)"; exit 3 ;;
esac
[ "$DRY" = 1 ] || [ "${disk:-0}" -ge 60 ] || { say "BLOCKER: only ${disk} GB free disk on the Studio (need 60)"; exit 3; }

# 2. GPU lock, released in the trap.
HAVE_LOCK=0
lc env STUDIO_LANE=gpu bash "$LOCKSH" acquire "$OWNER" >> "$LOG" 2>&1 || { say "BLOCKER: gpu lock acquire failed"; exit 3; }
HAVE_LOCK=1
say "LOCK_ACQUIRED $OWNER"
PID=""
# shellcheck disable=SC2329  # the EXIT trap
finish() {
  local rc=$?
  if [ -n "$PID" ] && [ "$DRY" = 0 ] && "${SSH[@]}" "kill -0 $PID 2>/dev/null"; then
    say "remote job still running at exit; stopping its process group $PID"
    "${SSH[@]}" "kill -TERM -- -$PID 2>/dev/null; sleep 15; kill -KILL -- -$PID 2>/dev/null; pkill -KILL -f 'macprovider-cli[ ]serve --config '\$HOME'/lab-mlx-0325/' 2>/dev/null; true"
  fi
  say "KEEP_PAUSED=1: live, runner and miner untouched by this window"
  [ "$HAVE_LOCK" = 1 ] && lc env STUDIO_LANE=gpu bash "$LOCKSH" release "$OWNER" >> "$LOG" 2>&1
  say "LOCK_RELEASED $OWNER"
  say "WINDOW_END rc=$rc"
  say "HANDOVER_READY (live, runner, miner as the queue line left them; GPU lock released)"
}
trap finish EXIT
trap 'exit 130' INT TERM HUP

# 3. Ship the pushed commit (and origin/main's phase3-binary for the gpu base build), then start the job.
st "mkdir -p ~/lab-mlx-0325/logs ~/lab-mlx-0325/results $SRC_REMOTE && for d in ~/lab-mlx-0325/src-*; do [ \"\$d\" != \"$SRC_REMOTE\" ] && rm -rf \"\$d\"; done; true" \
  || { say "BLOCKER: Studio lab dir setup failed"; exit 2; }
if [ "$DRY" = 1 ]; then
  lc "git -C $WT archive --format=tar --prefix=macprovider/ $COMMIT ${SHIP_PATHS[*]} | ssh macstudio tar -x -C $SRC_REMOTE"
  [ "$MODE" = gpu ] && lc "git -C $WT archive --format=tar --prefix=base/ $MAIN phase3-binary | ssh macstudio tar -x -C $SRC_REMOTE"
else
  git -C "$WT" archive --format=tar --prefix=macprovider/ "$COMMIT" "${SHIP_PATHS[@]}" \
    | "${SSH[@]}" "tar -x -C $SRC_REMOTE" || { say "BLOCKER: source copy to the Studio failed"; exit 2; }
  if [ "$MODE" = gpu ]; then
    git -C "$WT" archive --format=tar --prefix=base/ "$MAIN" phase3-binary \
      | "${SSH[@]}" "tar -x -C $SRC_REMOTE" || { say "BLOCKER: base source copy to the Studio failed"; exit 2; }
  fi
fi
say "SHIPPED $COMMIT -> macstudio:~/lab-mlx-0325/src-$SHORT"
PID=$(st_script "$RUN_ID" "$SRC_REMOTE" "$JOB" "${MEMGUARD_FLOOR_PCT:-10}" "${JOB_ENV[@]}" <<'REMOTE'
set -m
run=$1 src=$2 job=$3 floor=$4
shift 4
lab=$HOME/lab-mlx-0325
mkdir -p "$lab/logs" "$lab/results/$run"
env RUN_ID="$run" SRC="$src/macprovider" BASE_SRC="$src/base" "$@" nohup bash "$src/macprovider/scripts/lab/mlx-0325/$job" > "$lab/logs/job-$run.log" 2>&1 < /dev/null &
jp=$!
nohup bash "$src/macprovider/scripts/lab/mlx-0325/memguard.sh" "$jp" "$floor" "$lab/results/$run/memguard.log" > /dev/null 2>&1 < /dev/null &
echo "$jp"
REMOTE
)
if [ "$DRY" = 1 ]; then
  say "DRY job start printed above; the watch loop, results pull and verdict lines are not run"
  lc rsync -a "macstudio:lab-mlx-0325/results/$RUN_ID/" "$RES_LOCAL/"
  exit 0
fi
case "$PID" in ''|*[!0-9]*) say "BLOCKER: remote job did not start (pid='$PID')"; PID=""; exit 4 ;; esac
say "JOB_STARTED pid=$PID log=macstudio:~/lab-mlx-0325/logs/job-$RUN_ID.log"

# 4. Watch: progress lines into this log; stall detector only (no wall-clock cut).
seen=0 stalled=0 sshfail=0
while :; do
  sleep 60
  alive=$("${SSH[@]}" "kill -0 $PID 2>/dev/null && echo yes || echo no") || alive=unknown
  if [ "$alive" = unknown ]; then
    sshfail=$((sshfail + 1)); say "ssh probe failed ($sshfail), retrying"
    [ "$sshfail" = 3 ] && { say "BLOCKER: STUDIO_SSH_LOST no ssh to the Studio for 3 probes"; osascript -e 'display notification "No ssh to the Studio" with title "window-0325" sound name "Basso"' >/dev/null 2>&1; }
    continue
  fi
  sshfail=0
  new=$("${SSH[@]}" "grep -E '$PROGRESS' ~/lab-mlx-0325/logs/job-$RUN_ID.log 2>/dev/null")
  n=$(printf '%s\n' "$new" | grep -c .)
  [ "$n" -gt "$seen" ] && { printf '%s\n' "$new" | tail -n +$((seen + 1)) | tee -a "$LOG"; seen=$n; }
  [ "$alive" = no ] && break
  "${SSH[@]}" "grep -q MEMGUARD_KILL ~/lab-mlx-0325/results/$RUN_ID/memguard.log 2>/dev/null" \
    && say "BLOCKER: the memory guard stopped the job (dextr job using memory?): $("${SSH[@]}" "grep MEMGUARD_KILL ~/lab-mlx-0325/results/$RUN_ID/memguard.log")"
  fresh=$("${SSH[@]}" "find ~/lab-mlx-0325/results/$RUN_ID ~/lab-mlx-0325/logs ~/lab-mlx-0325/mlx/build ~/lab-mlx-0325/mlx-swift/.build $SRC_REMOTE/macprovider/phase3-binary/.build $SRC_REMOTE/base/phase3-binary/.build -type f -mmin -$STALL_MIN 2>/dev/null | head -n 1")
  if [ -z "$fresh" ]; then
    stalled=$((stalled + 1))
    [ $((stalled % STALL_MIN)) = 1 ] && say "BLOCKER: no file progress for ${STALL_MIN}+ minutes; last job log lines: $("${SSH[@]}" "tail -n 2 ~/lab-mlx-0325/logs/job-$RUN_ID.log" | tr '\n' ' ')"
  else
    stalled=0
  fi
done
say "remote job exited"
PID=""
"${SSH[@]}" "tail -n 25 ~/lab-mlx-0325/logs/job-$RUN_ID.log" | tee -a "$LOG"

# 5. Results and verdict.
mkdir -p "$RES_LOCAL"
rsync -a --exclude 'serve/' "macstudio:lab-mlx-0325/results/$RUN_ID/" "$RES_LOCAL/" >> "$LOG" 2>&1 || say "BLOCKER: results pull failed"
rsync -a "macstudio:lab-mlx-0325/logs/job-$RUN_ID.log" "$RES_LOCAL/" >> "$LOG" 2>&1
say "RESULTS $RES_LOCAL"
grep -hE '^MLX0325_' "$RES_LOCAL/verdict.md" 2>/dev/null | tee -a "$LOG"
if grep -q 'JOB_PASS' "$RES_LOCAL/job-$RUN_ID.log" 2>/dev/null; then
  say "JOB_PASS"
else
  say "JOB_FAIL"
  say "BLOCKER: window-0325 $MODE job did not pass; see $RES_LOCAL/job-$RUN_ID.log"; exit 1
fi
exit 0
