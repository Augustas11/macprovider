#!/bin/bash
# #2467 uncensored Inkling-2-Mini window launcher, run on the dev Mac (modeled on
# scripts/lab/ablit-perf/studio-ablit-perf.sh). Run ONLY inside a Studio window whose owner has
# already paused the live provider, the runner's Studio target and the FLOP miner: this script
# never pauses, restores or restarts any of them (a queued window keeps them paused with the
# owner's KEEP_PAUSED=1), and refuses to start if :8080 listens on the Studio,
# live.malibu.provider is loaded or a macprovider-cli serve process runs.
#
# Ships the pushed mlx-swift-lm fork commit (git archive of FORK_DIR HEAD, which must equal
# origin/$FORK_BRANCH, clean) to ~/lab-2467/src-<sha12>/fork and this checkout's
# scripts/lab/2467, dsv4_refusal_check.py, the MiniMax publish helper (snapshot manifest,
# upload/verify) and the committed source manifest to ~/lab-2467/src-<sha12>/job, takes the
# Studio GPU lock, starts job/2467/job-inkling2-uncensored.sh detached in its own process group
# with job/2467/memguard.sh beside it, watches it (stall watcher only, no wall-clock deadline;
# three failed ssh probes raise STUDIO_SSH_LOST), pulls ~/lab-2467/results/<run> back to
# $POC/scratchpad/2467/results/<run>, releases the lock at exit.
#
# Usage: studio-2467-uncensored.sh [--dry-run]
#   --dry-run  local checks, the job's own --dry-run (API plan, no download), then prints every
#              Studio command instead of running it; no ssh, no lock.
# Job settings pass through by name: MIN_FREE_GB EXPECT_CHANGED ERROR_RATIO MAX_ERROR_RATIO
#   REFUSAL_N REFUSAL_MAX_TOKENS REFUSAL_DATA SKIP_BUILD KEEP_SOURCE PUBLISH PUBLISH_ARGS METALLIB
#   (job header). MEMGUARD_FLOOR_PCT (10), FORK_DIR (~/mlx-swift-lm-2467), FORK_BRANCH
#   (macprovider/2467-inkling2).
# Estimated length (an estimate, not measured): about 50 min cold. ~19.5 GB source download
# overlapped with the fork release test build (~20 min), diff + splice ~5 min, oracle ~3 min,
# parity ~2 min, refusal probe 2 x 16 prompts ~10 min; about 35 min with SKIP_BUILD=1.
# Exit 0 only when the job printed JOB_PASS (and PUBLISH_PASS with PUBLISH=1); every failure
# prints a `BLOCKER:` line.
set -u
DRY=0
[ "${1:-}" = --dry-run ] && DRY=1
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
POC=${POC:-$HOME/macprovider-poc}  # the checkout that holds scratchpad/ and the lock helper
SCR=$POC/scratchpad/2467
RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)
LOG=$SCR/studio-2467-uncensored-$RUN_ID.log
RES=$SCR/results
LOCKSH=$POC/scratchpad/studio-lock.sh
OWNER=t2467-uncensored
STALL_MIN=30
FORK_DIR=${FORK_DIR:-$HOME/mlx-swift-lm-2467}
FORK_BRANCH=${FORK_BRANCH:-macprovider/2467-inkling2}
EVIDENCE=docs/evidence/inkling-2-mini-intake-2026-11-24/openuncensored-source-050f1cec.manifest
SSH=(ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=6 macstudio)
mkdir -p "$SCR" "$RES"
: > "$LOG"
say() { echo "$(date '+%H:%M:%S') $*" | tee -a "$LOG"; }
blocker() { say "BLOCKER: $*"; }
# st CMD: one remote command; printed to stderr (and not run) in a dry run, so callers capture nothing.
st() {
  if [ "$DRY" = 1 ]; then printf 'DRY studio$ %s\n' "$*" | tee -a "$LOG" >&2; return 0; fi
  "${SSH[@]}" "$@"
}

# Local: the shipped files are committed, the fork commit is the pushed branch tip.
SHIPPED=(scripts/lab/2467 scripts/lab/dsv4/dsv4_refusal_check.py scripts/lab/minimax/publish_abliterated.py "$EVIDENCE")
dirty=$(git -C "$REPO" status --porcelain -- "${SHIPPED[@]}")
[ -z "$dirty" ] || { blocker "uncommitted changes in the shipped paths; commit first: $(echo "$dirty" | head -n 3 | tr '\n' ' ')"; exit 2; }
COMMIT=$(git -C "$REPO" rev-parse HEAD)
for f in "$HERE"/*.sh; do bash -n "$f" || { blocker "$f does not parse"; exit 2; }; done
git -C "$FORK_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { blocker "FORK_DIR=$FORK_DIR is not a git work tree"; exit 2; }
[ -z "$(git -C "$FORK_DIR" status --porcelain)" ] || { blocker "FORK_DIR=$FORK_DIR has uncommitted changes"; exit 2; }
if [ "$DRY" = 0 ]; then
  git -C "$FORK_DIR" fetch -q origin "$FORK_BRANCH" || { blocker "git fetch origin $FORK_BRANCH failed in $FORK_DIR"; exit 2; }
fi
FORK_COMMIT=$(git -C "$FORK_DIR" rev-parse HEAD)
REMOTE=$(git -C "$FORK_DIR" rev-parse "origin/$FORK_BRANCH" 2>/dev/null)
[ "$FORK_COMMIT" = "$REMOTE" ] || { blocker "$FORK_DIR HEAD $FORK_COMMIT is not origin/$FORK_BRANCH $REMOTE; push or reset first"; exit 2; }
for f in tools/inkling2_parity/dump_real_oracle.py tools/inkling2_parity/oq_adapter.py Tests/MLXLMTests/Inkling2ParityTests.swift; do
  git -C "$FORK_DIR" cat-file -e "HEAD:$f" 2>/dev/null || { blocker "fork HEAD lacks $f"; exit 2; }
done
SHORT=${FORK_COMMIT:0:12}
SRC_REMOTE="\$HOME/lab-2467/src-$SHORT"

ENVS=""
while IFS= read -r name; do
  ENVS="$ENVS $name=$(printf %q "${!name}")"
done < <(compgen -e | grep -E '^(MIN_FREE_GB|EXPECT_CHANGED|ERROR_RATIO|MAX_ERROR_RATIO|REFUSAL_N|REFUSAL_MAX_TOKENS|REFUSAL_DATA|SKIP_BUILD|KEEP_SOURCE|PUBLISH|PUBLISH_ARGS|METALLIB)$')
say "UNCENSORED_START run=$RUN_ID commit=$COMMIT fork=$FORK_COMMIT dry_run=$DRY env:${ENVS:- (defaults)}"

if [ "$DRY" = 1 ]; then
  bash "$HERE/job-inkling2-uncensored.sh" --dry-run 2>&1 | tee -a "$LOG" | grep -E 'BLOCKER|FETCH_PLAN|DRY_RUN_PASS'
  [ "${PIPESTATUS[0]}" = 0 ] || { blocker "the job's dry run failed"; exit 2; }
fi

pre=$(st 'u=$(id -u)
  if lsof -nP -iTCP:8080 -sTCP:LISTEN -t >/dev/null 2>&1; then echo LISTEN_8080; fi
  launchctl print gui/$u/live.malibu.provider >/dev/null 2>&1 && echo LIVE_LOADED
  pgrep -f "[m]acprovider-cli serve" >/dev/null 2>&1 && echo SERVE_RUNNING
  launchctl list | grep -q com.flop && echo FLOP_AGENT
  echo done') || { blocker "ssh macstudio failed"; exit 2; }
case "$pre" in
  "") say "preflight: dry run, the paused-Studio check was printed, not run" ;;
  done) say "preflight ok: :8080 free, live.malibu.provider absent, no serve process, no FLOP agent" ;;
  *) blocker "refusing to start, the Studio is not paused: $(echo "$pre" | grep -v '^done$' | tr '\n' ' ')"; exit 3 ;;
esac

HAVE_GPU=0; PID=""
finish() {
  local rc=$?
  if [ "$DRY" = 1 ]; then say "UNCENSORED_END dry run (rc=$rc)"; return; fi
  if [ -n "$PID" ] && "${SSH[@]}" "kill -0 $PID 2>/dev/null"; then
    say "remote job still running at exit; stopping its process group $PID"
    "${SSH[@]}" "kill -TERM -- -$PID 2>/dev/null; sleep 15; kill -KILL -- -$PID 2>/dev/null; pkill -KILL -f '/lab-2467/venv-vlm-' 2>/dev/null; true"
  fi
  mkdir -p "$RES/$RUN_ID"
  rsync -a "macstudio:lab-2467/results/$RUN_ID/" "$RES/$RUN_ID/" >> "$LOG" 2>&1 || blocker "results pull failed"
  rsync -a "macstudio:lab-2467/logs/job-$RUN_ID.log" "$RES/$RUN_ID/" >> "$LOG" 2>&1
  [ "$HAVE_GPU" = 1 ] && STUDIO_LANE=gpu bash "$LOCKSH" release "$OWNER" >> "$LOG" 2>&1
  say "LOCK_RELEASED $OWNER"
  local jl=$RES/$RUN_ID/job-$RUN_ID.log published=1
  [ "${PUBLISH:-0}" = 1 ] && ! grep -q 'PUBLISH_PASS' "$jl" 2>/dev/null && published=0
  if [ "$published" = 1 ] && grep -q 'JOB_PASS' "$jl" 2>/dev/null && ! grep -q 'PUBLISH_FAIL' "$jl"; then
    grep -hE 'SPLICE_ARTIFACT|NUMERIC_GATE|PARITY_GATE|REFUSAL_GATE|PROVENANCE|PUBLISH_DONE' "$jl" | tee -a "$LOG"
    say "UNCENSORED_END pass. Results: $RES/$RUN_ID"
  else
    blocker "the job did not pass; see $jl"
    say "UNCENSORED_END fail. Results: $RES/$RUN_ID"
    exit 1
  fi
}
trap finish EXIT
trap 'exit 130' INT TERM HUP

if [ "$DRY" = 0 ]; then
  [ -f "$LOCKSH" ] || { blocker "no lock helper at $LOCKSH"; exit 2; }
  STUDIO_LANE=gpu bash "$LOCKSH" acquire "$OWNER" >> "$LOG" 2>&1 || { blocker "gpu lock acquire failed"; exit 3; }
  HAVE_GPU=1
  say "LOCK_ACQUIRED $OWNER"
fi

# Ship: the fork (kept, with its build, when this commit is already there) and the job files.
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/studio-2467-uncensored.XXXXXX")
mkdir -p "$STAGE/job/2467" "$STAGE/job/dsv4" "$STAGE/job/minimax" "$STAGE/job/evidence"
git -C "$REPO" archive "$COMMIT" scripts/lab/2467 | tar -x -C "$STAGE" && cp "$STAGE"/scripts/lab/2467/* "$STAGE/job/2467/" \
  && git -C "$REPO" show "$COMMIT:scripts/lab/dsv4/dsv4_refusal_check.py" > "$STAGE/job/dsv4/dsv4_refusal_check.py" \
  && git -C "$REPO" show "$COMMIT:scripts/lab/minimax/publish_abliterated.py" > "$STAGE/job/minimax/publish_abliterated.py" \
  && git -C "$REPO" show "$COMMIT:$EVIDENCE" > "$STAGE/job/evidence/$(basename "$EVIDENCE")" \
  && rm -rf "$STAGE/scripts" || { blocker "staging the job files failed"; rm -rf "$STAGE"; exit 2; }
( cd "$STAGE/job" && find . -type f | sort | xargs shasum -a 256 ) > "$STAGE/SHA256SUMS" && mv "$STAGE/SHA256SUMS" "$STAGE/job/"
say "JOB_FILES $(awk '{print $2 "=" substr($1,1,12)}' "$STAGE/job/SHA256SUMS" | tr '\n' ' ')"
st "mkdir -p ~/lab-2467/logs ~/lab-2467/results ~/lab-2467/models $SRC_REMOTE/fork && rm -rf $SRC_REMOTE/job" \
  || { blocker "Studio lab dir setup failed"; rm -rf "$STAGE"; exit 2; }
if [ "$DRY" = 1 ]; then
  st "[ \"\$(cat $SRC_REMOTE/fork/.fork-commit 2>/dev/null)\" = $FORK_COMMIT ] || (git -C $FORK_DIR archive $FORK_COMMIT | tar -x -C $SRC_REMOTE/fork)"
  st "tar -x -C $SRC_REMOTE < (job files from $STAGE/job)"
else
  if [ "$("${SSH[@]}" "cat $SRC_REMOTE/fork/.fork-commit 2>/dev/null")" != "$FORK_COMMIT" ]; then
    git -C "$FORK_DIR" archive --format=tar "$FORK_COMMIT" | "${SSH[@]}" "tar -x -C $SRC_REMOTE/fork && echo $FORK_COMMIT > $SRC_REMOTE/fork/.fork-commit" \
      || { blocker "fork copy to the Studio failed"; rm -rf "$STAGE"; exit 2; }
  fi
  tar -C "$STAGE" -cf - job | "${SSH[@]}" "tar -x -C $SRC_REMOTE" || { blocker "job file copy to the Studio failed"; rm -rf "$STAGE"; exit 2; }
fi
rm -rf "$STAGE"
say "SHIPPED fork $FORK_COMMIT + job files -> macstudio:~/lab-2467/src-$SHORT"

# set -m: the job leads its own process group, so finish() and the memory guard stop all of it.
if [ "$DRY" = 1 ]; then
  st "set -m; env RUN_ID=$RUN_ID SRC=$SRC_REMOTE FORK_COMMIT=$FORK_COMMIT COMMIT=$COMMIT$ENVS nohup bash $SRC_REMOTE/job/2467/job-inkling2-uncensored.sh > ~/lab-2467/logs/job-$RUN_ID.log 2>&1 &; nohup bash $SRC_REMOTE/job/2467/memguard.sh <pid> ${MEMGUARD_FLOOR_PCT:-10} ~/lab-2467/results/$RUN_ID/memguard.log &"
  st "watch: grep progress lines in ~/lab-2467/logs/job-$RUN_ID.log every 60 s; stall probe find -mmin -$STALL_MIN; MEMGUARD_KILL probe"
  say "DRY_RUN_PASS (no ssh, no lock, nothing shipped or started)"
  exit 0
fi
PID=$("${SSH[@]}" "bash -s -- $RUN_ID $SRC_REMOTE $FORK_COMMIT $COMMIT ${MEMGUARD_FLOOR_PCT:-10}$ENVS" <<'REMOTE'
set -m
run=$1 src=$2 fork=$3 commit=$4 floor=$5
shift 5
lab=$HOME/lab-2467
mkdir -p "$lab/logs" "$lab/results/$run/uncensored"
env RUN_ID="$run" SRC="$src" FORK_COMMIT="$fork" COMMIT="$commit" "$@" nohup bash "$src/job/2467/job-inkling2-uncensored.sh" \
  > "$lab/logs/job-$run.log" 2>&1 < /dev/null &
jp=$!
nohup bash "$src/job/2467/memguard.sh" "$jp" "$floor" "$lab/results/$run/memguard.log" > /dev/null 2>&1 < /dev/null &
echo "$jp"
REMOTE
)
case "$PID" in ''|*[!0-9]*) blocker "remote job did not start (pid='$PID')"; PID=""; exit 4 ;; esac
say "JOB_STARTED pid=$PID log=macstudio:~/lab-2467/logs/job-$RUN_ID.log"

PROGRESS='^[0-9:]+ (BLOCKER|JOB_|BUILD_|VENV_|DISK|CLONE_|DOWNLOAD_|FETCH_|DIFF_|NUMERIC|SPLICE_|ORACLE_|PARITY_|BASE_|REFUSAL_|PROVENANCE|SOURCE_|ARTIFACT_|PUBLISH_)|^(PARITY_ROW|PARITY_LEVERS|BASE_PARITY|REFUSAL_|PUBLISH_)'
seen=0 stalled=0 sshfail=0
while :; do
  sleep 60
  alive=$("${SSH[@]}" "kill -0 $PID 2>/dev/null && echo yes || echo no") || alive=unknown
  if [ "$alive" = unknown ]; then
    sshfail=$((sshfail + 1)); say "ssh probe failed ($sshfail), retrying"
    if [ "$sshfail" = 3 ]; then
      blocker "STUDIO_SSH_LOST no ssh to the Studio for 3 probes"
      osascript -e 'display notification "No ssh to the Studio" with title "Studio window" sound name "Basso"' >/dev/null 2>&1
    fi
    continue
  fi
  sshfail=0
  new=$("${SSH[@]}" "grep -E '$PROGRESS' ~/lab-2467/logs/job-$RUN_ID.log 2>/dev/null")
  n=$(printf '%s\n' "$new" | grep -c .)
  [ "$n" -gt "$seen" ] && { printf '%s\n' "$new" | tail -n +$((seen + 1)) | tee -a "$LOG"; seen=$n; }
  [ "$alive" = no ] && break
  "${SSH[@]}" "grep -q MEMGUARD_KILL ~/lab-2467/results/$RUN_ID/memguard.log 2>/dev/null" \
    && blocker "the memory guard stopped the job: $("${SSH[@]}" "grep MEMGUARD_KILL ~/lab-2467/results/$RUN_ID/memguard.log")"
  fresh=$("${SSH[@]}" "find ~/lab-2467/results/$RUN_ID ~/lab-2467/logs ~/lab-2467/models ~/lab-2467/venv-vlm-f1618d6 $SRC_REMOTE/fork/.build-tests-release -type f -mmin -$STALL_MIN 2>/dev/null | head -n 1")
  if [ -z "$fresh" ]; then
    stalled=$((stalled + 1))
    [ $((stalled % STALL_MIN)) = 1 ] && blocker "no file progress for ${STALL_MIN}+ minutes; last job log lines: $("${SSH[@]}" "tail -n 2 ~/lab-2467/logs/job-$RUN_ID.log" | tr '\n' ' ')"
  else
    stalled=0
  fi
done
say "remote job exited"
PID=""
"${SSH[@]}" "tail -n 20 ~/lab-2467/logs/job-$RUN_ID.log" | tee -a "$LOG"
