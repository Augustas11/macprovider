#!/bin/bash
# #2487 goal metric for the Swift path, run ON THE STUDIO by studio-2487-compile.sh --bench
# (detached, own process group, memguard beside it). Loads the oQ4e Inkling-2-Mini (one model,
# ~16 GB) in a release test build of the fork and runs Inkling2DSparkBenchTests: greedy token
# parity of DSpark against ordinary decode, decode tok/s for both, acceptance, prefill time, on
# the megakernel-zoo natural prompts from window 1, at macprovider's 512-token prefill step.
# Writes only under ~/lab-2487. BLOCKER: on setup failures; DSPARK_ROW/DSPARK_SUMMARY lines;
# T2487_COMPILE rc=<n> PASS|FAIL last (same tag as the compile job, so one launcher reads both).
set -u
RUN_ID=${RUN_ID:?RUN_ID}
FORK_REF=${FORK_REF:?FORK_REF}
L=$HOME/lab-2487
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT=$L/results/compile-$RUN_ID; mkdir -p "$OUT" "$L/src"
MODEL=${MODEL:-$HOME/lab-2467/models/Inkling-2-Mini-oQ4e-mtp@3eea0427}
PROMPTS=${PROMPTS:-$L/results/20261124T181934Z/prompts/natural.json}
PROMPT_COUNT=${PROMPT_COUNT:-8}
TOKENS=${TOKENS:-512}
BLOCK=${BLOCK:-8}
PREFILL_STEP=${PREFILL_STEP:-512}
say() { echo "$(date '+%H:%M:%S') $*"; }
done_rc() { say "T2487_COMPILE rc=$1 $([ "$1" = 0 ] && echo PASS || echo FAIL)"; exit "$1"; }
blocker() { say "BLOCKER: $*"; done_rc "${2:-90}"; }

free_gb=$(df -g "$HOME" | awk 'NR==2{print $4}')
[ "${free_gb:-0}" -ge 20 ] || blocker "only ${free_gb:-?} GB free on the Studio (need 20)" 91
export DEVELOPER_DIR=$HOME/Applications/Xcode.app/Contents/Developer
[ -d "$DEVELOPER_DIR" ] || blocker "no DEVELOPER_DIR at $DEVELOPER_DIR" 92
[ -f "$MODEL/config.json" ] && [ -f "$MODEL/mtp.safetensors" ] || blocker "no oQ4e model with mtp.safetensors at $MODEL" 95
[ -f "$PROMPTS" ] || blocker "no prompts at $PROMPTS" 95
say "start run=$RUN_ID ref=$FORK_REF model=$MODEL prompts=$PROMPTS count=$PROMPT_COUNT tokens=$TOKENS block=$BLOCK step=$PREFILL_STEP"

R=$L/src/mlx-swift-lm
[ -d "$R/.git" ] || git clone -q https://github.com/Augustas11/mlx-swift-lm.git "$R" || blocker "clone failed" 93
cd "$R" || blocker "no checkout at $R" 93
git fetch -q origin macprovider/2487-inkling2-dspark || blocker "fetch failed" 93
git checkout -q --detach "$FORK_REF" || blocker "cannot check out $FORK_REF" 93
say "checked out $(git rev-parse --short HEAD): $(git log -1 --format=%s)"

RB=$L/build-release
say "swift build -c release --build-tests"
swift build -c release -Xswiftc -enable-testing --build-tests --scratch-path "$RB" > "$OUT/build.log" 2>&1; rc=$?
if [ $rc -ne 0 ]; then grep -E "error:" "$OUT/build.log" | sort -u | head -40; done_rc $rc; fi

mkdir -p "$OUT/metallib"
MLX_SWIFT_CHECKOUT="$RB/checkouts/mlx-swift" bash "$HERE/build-mlx-metallib.sh" "$OUT/metallib" \
  > "$OUT/metallib.log" 2>&1 || { tail -5 "$OUT/metallib.log"; blocker "metallib build failed" 94; }
[ -f "$OUT/metallib/mlx.metallib" ] || blocker "no mlx.metallib produced" 94
n=0
for x in "$RB"/release/*.xctest/Contents/MacOS; do cp "$OUT/metallib/mlx.metallib" "$x/mlx.metallib" && n=$((n + 1)); done
cp "$OUT/metallib/mlx.metallib" "$RB/release/mlx.metallib"
[ "$n" -gt 0 ] || blocker "no release .xctest bundle to receive mlx.metallib" 94

say "bench"
INKLING2_DSPARK_MODEL="$MODEL" INKLING2_DSPARK_PROMPTS="$PROMPTS" INKLING2_DSPARK_PROMPT_COUNT="$PROMPT_COUNT" \
  INKLING2_DSPARK_TOKENS="$TOKENS" INKLING2_DSPARK_BLOCK="$BLOCK" INKLING2_DSPARK_PREFILL_STEP="$PREFILL_STEP" \
  INKLING2_DSPARK_REPORT="$OUT/dspark-bench.json" \
  swift test -c release -Xswiftc -enable-testing --skip-build --scratch-path "$RB" \
  --filter Inkling2DSparkBenchTests > "$OUT/test.log" 2>&1; rc=$?
grep -hE "DSPARK_ROW|DSPARK_SUMMARY|error:|failed|skipped|Executed" "$OUT/test.log" | tail -40
grep -q DSPARK_SUMMARY "$OUT/test.log" || say "BLOCKER: the bench printed no DSPARK_SUMMARY"
# ~/lab-2487/build-release stays for incremental rebuilds while the campaign is open; delete
# ~/lab-2487 when #2487 closes (AGENTS.md rule 14).
done_rc $rc
