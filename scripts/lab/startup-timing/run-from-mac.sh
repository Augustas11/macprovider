#!/bin/bash
# Issue 2431 driver, run on the dev Mac. Run ONLY inside a Studio window whose owner already paused the
# live provider and the runner's Studio target; this script never pauses, restores or restarts either.
#
# 1. Refuses when :8080 listens on host macstudio, live.malibu.provider is loaded, a macprovider-cli serve
#    runs, or ~/lab-heavy.lock.d exists.
# 2. Exports phase3-binary of origin/main (fetched now) and of this branch's HEAD (git archive: committed
#    bytes only) and rsyncs them to ~/lab-2431/{main,branch} (.git and .build* excluded).
# 3. On the Studio, detached in its own process group: builds each with the lab-harness release flags of
#    scripts/lab/ablit-perf/job.sh (`swift build -c release --product macprovider-cli --build-path
#    .build-lab-2431 -Xswiftc -DMACPROVIDER_LAB_HARNESS`, nice 10) copies
#    mlx.metallib beside each binary, then runs measure.sh (it takes ~/lab-heavy.lock.d itself) with the
#    GLM-5.3-Flash uncensored snapshot and --runs 2.
# 4. Pulls ~/lab-2431/out/<stamp> to $POC/scratchpad/ablit-perf/startup-timing/<stamp>/ and prints table.md.
#
# No wall-clock deadline: a stall watcher only (no file progress for 30 minutes prints a BLOCKER line).
# Usage: scripts/lab/startup-timing/run-from-mac.sh        (env: RUNS=2, METALLIB, MODEL_DIR, POC)
# Exit 0 only when measure.sh printed STARTUP_TIMING_END status=0; every failure prints `BLOCKER:`.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
POC=${POC:-$HOME/macprovider-poc}
LOCKSH=$POC/scratchpad/studio-lock.sh
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUTDIR=$POC/scratchpad/ablit-perf/startup-timing/$STAMP
RUNS=${RUNS:-2}
STALL_MIN=30
SSH=(ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=6 macstudio)
# GLM defaults of scripts/lab/ablit-perf/job.sh
MODEL_ID=zai-org/glm-5.3-flash-uncensored
MODEL_SHA=242f8fcfd34d4ecfd62180c1767f910bda925216948772126dc98c673d1c8919
METALLIB=${METALLIB:-/Applications/Malibu.app/Contents/MacOS/mlx.metallib}
# Snapshot dir on the Studio: MODEL_DIR, else the ablit-perf lab clone, else the provider store snapshot.
MODEL_DIR=${MODEL_DIR:-}
mkdir -p "$OUTDIR"
LOG=$OUTDIR/driver.log
say() { echo "$(date '+%H:%M:%S') $*" | tee -a "$LOG"; }
blocker() { say "BLOCKER: $*"; }
case "$RUNS" in ""|*[!0-9]*|0) blocker "RUNS must be a positive number"; exit 64 ;; esac

[ -f "$LOCKSH" ] || { blocker "no lock helper at $LOCKSH"; exit 2; }
[ -z "$(git -C "$REPO" status --porcelain --untracked-files=no)" ] || { blocker "uncommitted tracked changes in $REPO; commit first"; exit 2; }
git -C "$REPO" fetch origin main -q || { blocker "git fetch origin main failed"; exit 2; }
MAIN_COMMIT=$(git -C "$REPO" rev-parse origin/main)
BRANCH_COMMIT=$(git -C "$REPO" rev-parse HEAD)
BRANCH_NAME=$(git -C "$REPO" rev-parse --abbrev-ref HEAD)
[ "$MAIN_COMMIT" != "$BRANCH_COMMIT" ] || { blocker "branch HEAD equals origin/main; nothing to compare"; exit 2; }

pre=$("${SSH[@]}" 'u=$(id -u)
  if lsof -nP -iTCP:8080 -sTCP:LISTEN -t >/dev/null 2>&1; then echo LISTEN_8080; fi
  launchctl print gui/$u/live.malibu.provider >/dev/null 2>&1 && echo LIVE_LOADED
  pgrep -f "[m]acprovider-cli serve" >/dev/null 2>&1 && echo SERVE_RUNNING
  [ -e ~/lab-heavy.lock.d ] && echo "LOCK_HELD:$(cat ~/lab-heavy.lock.d/owner 2>/dev/null)"
  echo done') || { blocker "ssh macstudio failed"; exit 2; }
[ "$pre" = done ] || { blocker "refusing to start, the Studio is busy or not paused: $(echo "$pre" | grep -v '^done$' | tr '\n' ' ')"; exit 3; }
say "preflight ok: :8080 free, live.malibu.provider absent, no serve process, no heavy lock"

STG=$(mktemp -d "${TMPDIR:-/tmp}/startup-2431.XXXXXX")
trap 'rm -rf "$STG"' EXIT
mkdir -p "$STG/main" "$STG/branch"
git -C "$REPO" archive origin/main phase3-binary | tar -x -C "$STG/main" || { blocker "export of origin/main failed"; exit 2; }
git -C "$REPO" archive HEAD phase3-binary | tar -x -C "$STG/branch" || { blocker "export of $BRANCH_NAME failed"; exit 2; }
say "START_2431 stamp=$STAMP main=$MAIN_COMMIT branch=$BRANCH_NAME@$BRANCH_COMMIT runs=$RUNS"

"${SSH[@]}" 'mkdir -p ~/lab-2431/main ~/lab-2431/branch ~/lab-2431/job ~/lab-2431/out ~/lab-2431/logs' || { blocker "mkdir failed"; exit 2; }
for t in main branch; do
  rsync -a --delete --exclude .git --exclude '.build*' --exclude .swiftpm "$STG/$t/phase3-binary/" macstudio:lab-2431/$t/phase3-binary/ >> "$LOG" 2>&1 \
    || { blocker "copy of the $t tree to the Studio failed"; exit 2; }
done
rsync -a "$HERE/measure.sh" macstudio:lab-2431/job/ >> "$LOG" 2>&1 || { blocker "copy of measure.sh failed"; exit 2; }

# The Studio side: build both, then measure. Written as a file so the detached job needs no quoting.
"${SSH[@]}" 'cat > ~/lab-2431/job/remote.sh' <<'REMOTE' || { blocker "remote script copy failed"; exit 2; }
#!/bin/bash
# usage: remote.sh STAMP RUNS MODEL_ID MODEL_SHA METALLIB MODEL_DIR(optional)
set -u
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
STAMP=$1 RUNS=$2 MODEL_ID=$3 MODEL_SHA=$4 METALLIB=$5 MODEL_DIR=${6:-}
LAB=$HOME/lab-2431
OUT=$LAB/out/$STAMP
mkdir -p "$OUT"
log() { echo "$(date '+%H:%M:%S') $*"; }
die() { log "BLOCKER: $*"; log "JOB_FAIL"; exit "${2:-1}"; }

# Snapshot: explicit, else the ablit-perf lab clone, else the provider store snapshot of this sha.
if [ -z "$MODEL_DIR" ]; then
  for d in "$HOME/lab-ablit-perf/models/GLM-5.3-Flash-UNCENSORED-mlx-oQ4e-DFlash2" \
           "$HOME/Library/Application Support/macprovider/models/Solstice-AI--GLM-5.3-Flash-UNCENSORED-mlx-oQ4e-DFlash2"/*/"$MODEL_SHA"; do
    [ -f "$d/config.json" ] && { MODEL_DIR=$d; break; }
  done
fi
[ -f "$MODEL_DIR/config.json" ] || die "no GLM snapshot found (set MODEL_DIR)" 11
[ -f "$METALLIB" ] || die "no metallib at $METALLIB" 14
log "MODEL_DIR $MODEL_DIR"

built=1
for t in main branch; do
  log "BUILD_START $t"
  (cd "$LAB/$t/phase3-binary" && nice -n 10 swift build -c release --product macprovider-cli --build-path .build-lab-2431 \
    -Xswiftc -DMACPROVIDER_LAB_HARNESS) > "$OUT/build-$t.log" 2>&1 \
    || { log "BLOCKER: swift build ($t) failed: $(tail -n 3 "$OUT/build-$t.log" | tr '\n' ' ')"; built=0; break; }
  bin=$LAB/$t/phase3-binary/.build-lab-2431/release
  cp "$METALLIB" "$bin/mlx.metallib" || { log "BLOCKER: metallib copy ($t) failed"; built=0; break; }
  shasum -a 256 "$bin/macprovider-cli" "$bin/mlx.metallib" > "$OUT/identity-$t.sha256"
  log "BUILD_DONE $t $("$bin/macprovider-cli" --version 2>&1 | head -n 1) cli_sha256=$(cut -c1-16 "$OUT/identity-$t.sha256" | head -n 1)"
done
[ $built = 1 ] || { log "JOB_FAIL"; exit 14; }

# measure.sh takes ~/lab-heavy.lock.d itself and refuses when it is held.
bash "$LAB/job/measure.sh" --main-bin "$LAB/main/phase3-binary/.build-lab-2431/release" \
  --branch-bin "$LAB/branch/phase3-binary/.build-lab-2431/release" \
  --model-path "$MODEL_DIR" --model-id "$MODEL_ID" --model-sha256 "$MODEL_SHA" --runs "$RUNS" --out "$OUT/measure"
rc=$?
log "MEASURE_DONE rc=$rc"
[ $rc = 0 ] && log "JOB_PASS" || log "JOB_FAIL"
exit $rc
REMOTE
PID=""; HAVE_BUILD=0
finish() {
  if [ -n "$PID" ] && "${SSH[@]}" "kill -0 $PID 2>/dev/null"; then
    say "remote job still running at exit; killing its process group $PID"
    "${SSH[@]}" "kill -TERM -- -$PID 2>/dev/null; sleep 15; kill -KILL -- -$PID 2>/dev/null"
  fi
  rsync -a "macstudio:lab-2431/out/$STAMP/" "$OUTDIR/" >> "$LOG" 2>&1 || blocker "results pull failed"
  rsync -a "macstudio:lab-2431/logs/job-$STAMP.log" "$OUTDIR/" >> "$LOG" 2>&1
  [ "$HAVE_BUILD" = 1 ] && STUDIO_LANE=build bash "$LOCKSH" release startup-2431 >> "$LOG" 2>&1
  [ -f "$OUTDIR/measure/table.md" ] && { say "TABLE $OUTDIR/measure/table.md"; cat "$OUTDIR/measure/table.md" | tee -a "$LOG"; }
  if grep -q 'JOB_PASS' "$OUTDIR/job-$STAMP.log" 2>/dev/null; then
    say "STARTUP_2431_END pass. Results: $OUTDIR"
  else
    blocker "the job did not pass; see $OUTDIR/job-$STAMP.log"
    say "STARTUP_2431_END fail. Results: $OUTDIR"
    exit 1
  fi
}
trap 'finish; rm -rf "$STG"' EXIT
trap 'exit 130' INT TERM HUP
# Build-lane lock (compiles) for the whole job; measure.sh takes the heavy lock itself.
STUDIO_LANE=build bash "$LOCKSH" acquire startup-2431 >> "$LOG" 2>&1 || { blocker "build lock acquire failed"; exit 3; }
HAVE_BUILD=1

PID=$("${SSH[@]}" "bash -s" <<REMOTE
set -m
cd ~/lab-2431
nohup bash ./job/remote.sh $STAMP $RUNS $MODEL_ID $MODEL_SHA $(printf %q "$METALLIB") $(printf %q "$MODEL_DIR") > ./logs/job-$STAMP.log 2>&1 < /dev/null &
echo \$!
REMOTE
)
say "remote job pid=$PID"
[ -n "$PID" ] || { blocker "remote job did not start"; exit 4; }

seen=0; stalled=0
while :; do
  sleep 60
  alive=$("${SSH[@]}" "kill -0 $PID 2>/dev/null && echo yes || echo no") || alive=unknown
  new=$("${SSH[@]}" "grep -E '(BLOCKER|BUILD_|MODEL_DIR|MEASURE_DONE|JOB_|STARTUP_TIMING_)' ~/lab-2431/logs/job-$STAMP.log 2>/dev/null")
  n=$(printf '%s\n' "$new" | grep -c .)
  [ "$n" -gt "$seen" ] && { printf '%s\n' "$new" | tail -n +$((seen + 1)) | tee -a "$LOG"; seen=$n; }
  [ "$alive" = no ] && break
  [ "$alive" = unknown ] && { say "ssh probe failed, retrying"; continue; }
  fresh=$("${SSH[@]}" "find ~/lab-2431/out/$STAMP ~/lab-2431/logs ~/lab-2431/main/phase3-binary/.build-lab-2431 ~/lab-2431/branch/phase3-binary/.build-lab-2431 -type f -mmin -$STALL_MIN 2>/dev/null | head -n 1")
  if [ -z "$fresh" ]; then
    stalled=$((stalled + 1))
    [ $((stalled % STALL_MIN)) = 1 ] && blocker "no file progress for ${STALL_MIN}+ minutes; last job log lines: $("${SSH[@]}" "tail -n 2 ~/lab-2431/logs/job-$STAMP.log" | tr '\n' ' ')"
  else
    stalled=0
  fi
done
say "remote job exited"
