#!/bin/zsh
# Issue #2198 step 1: GLM-5.3-Flash native TTFT and single-row decode at
# 1K/8K/32K/64K, 4-row CB aggregate at 1K, and a kernel-time profile of the
# native engine against oMLX 0.7.1rc1 at 1K/8K, on the M3 Ultra Studio.
# With CAMP_BENCH set it then runs the campaign build on the same cells and
# checks its greedy tokens and top logits against the baseline run.
#
# Run only inside a Studio window the operator granted: the live provider is
# stopped (no :8080 listener, no live.malibu.provider job) and
# ~/lab-window.lock holds "owner-2198". The script never touches the live
# provider; it refuses to start, and stops between phases, if it is present.
#
# Phases (default: all, in order): tests base msb omlx camp
#   tests the campaign fork's GLM5Next unit tests (seconds; built beforehand
#         with `swift build --build-tests`); camp runs only if they pass
#   base  GLMBench (provider pin) at 1K/8K/32K/64K with the provider's 512-token
#         prefill chunk, 32K with the earlier evidence's 2048 chunk, decode
#         kernel profiles at 1K/8K, prefill kernel profiles at 8K/32K
#   msb   msb-throughput paged rows 4 at 1K (T4 / abliterated record shapes)
#   omlx  oMLX serve on loopback: TTFT and decode at 1K/8K/32K, Metal System
#         Traces of 1K and 8K decode
#   camp  the campaign GLMBench on the base cells, prefill profile at 32K,
#         decode profile at 1K; tokens/top logits compared with base
#
# Env: LAB (default ~/macprovider-lab-2198), MODEL, BASE_BENCH, CAMP_BENCH, CLI,
#      OMLX (venv python dir), OUT.
set -uo pipefail
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
export DEVELOPER_DIR=${DEVELOPER_DIR:-$HOME/Applications/Xcode.app/Contents/Developer}
LAB=${LAB:-$HOME/macprovider-lab-2198}
MODEL=${MODEL:-"$HOME/Library/Application Support/macprovider/models/Jundot--GLM-5.3-Flash-oQ4e-mtp/36defc5042d92a992a7948e83d6f110b8df69329/7299b6a71a38490e378e9eb6524c426392aa96e3fd561007e0540134bbef48f9"}
BASE_BENCH=${BASE_BENCH:-$LAB/bench-base/.build/release/GLMBench}
CAMP_BENCH=${CAMP_BENCH:-$LAB/bench-camp/.build/release/GLMBench}
CLI=${CLI:-/Users/a1/macprovider/macprovider-cli}
OMLX=${OMLX:-$LAB/venv-omlx/bin}
SWEEP=${SWEEP:-$LAB/poc/scripts/lab/cb-studio/depth_sweep.py}
OUT=${OUT:-$LAB/window-$(date -u +%Y%m%dT%H%M%SZ)}
PORT=18095
mkdir -p $OUT
log() { echo "$(date -u +%FT%TZ) $*" | tee -a $OUT/summary.txt; }

live_absent() {
  [[ -z $(lsof -nP -t -iTCP:8080 -sTCP:LISTEN 2>/dev/null) ]] &&
  ! launchctl print gui/$(id -u)/live.malibu.provider >/dev/null 2>&1
}
live_absent || { log "refusing: live provider present"; exit 3; }
[[ $(cat ~/lab-window.lock 2>/dev/null) == owner-2198 ]] || { log "refusing: ~/lab-window.lock is not owner-2198"; exit 3; }
[[ -d $MODEL ]] || { log "missing model $MODEL"; exit 3; }

{
  shasum -a 256 $BASE_BENCH ${BASE_BENCH:h}/mlx.metallib $CLI ${CLI:h}/mlx.metallib
  [[ -x $CAMP_BENCH ]] && shasum -a 256 $CAMP_BENCH ${CAMP_BENCH:h}/mlx.metallib
  $CLI --version 2>&1
  print -r -- "model=$MODEL"
} > $OUT/identity.txt 2>&1
sysctl iogpu.wired_limit_mb hw.memsize >> $OUT/identity.txt

# One GLMBench process per cell (one 186 GB load each, page-cached after the first).
bench() {  # bench [ops0] <binary> <name> [args...]; ops0: one kernel per command buffer
  local ops=default
  [[ $1 == ops0 ]] && { ops=0; shift; }
  local b=$1 name=$2; shift 2
  live_absent || { log "live appeared; abort"; exit 4; }
  log "$name start"
  if [[ $ops == 0 ]]; then
    env MLX_MAX_OPS_PER_BUFFER=0 $b $MODEL "$@" > $OUT/$name.log 2>&1
  else
    $b $MODEL "$@" > $OUT/$name.log 2>&1
  fi
  log "$name rc=$? $(grep -E '^(prefill_tps|decode_tps|gpu-profile|prefill-profile)' $OUT/$name.log | tr '\n' ' ' | cut -c1-300)"
}

cells() {  # cells <binary> <prefix>
  local b=$1 p=$2
  for ctx in 1024 8192 32768 65536; do
    bench $b $p-ctx$ctx --prompt $ctx --prefill-chunk 512 --wired --steps 128 --dump-logits --all-tokens
  done
}

TESTS_OK=0
phase_tests() {
  local lm=$LAB/camp/mlx-swift-lm
  [[ -d $lm ]] || { log "no campaign fork checkout; skip tests"; return 0; }
  log "fork tests start $(git -C $lm rev-parse HEAD)"
  (cd $lm && swift test --build-system native --skip-build --filter GLM5NextTests \
    -Xswiftc -Xfrontend -Xswiftc -solver-expression-time-threshold=600) > $OUT/fork-tests.log 2>&1
  local rc=$?
  (( rc == 0 )) && TESTS_OK=1
  log "fork tests rc=$rc $(grep -E 'Executed .* tests' $OUT/fork-tests.log | tail -1)"
}

phase_base() {
  cells $BASE_BENCH base
  bench $BASE_BENCH base-ctx32768-chunk2048 --prompt 32768 --prefill-chunk 2048 --wired --steps 128 --dump-logits
  bench $BASE_BENCH base-busy-1k --prompt 1024 --wired --gpu-profile --profile-steps 30
  bench ops0 $BASE_BENCH base-kernels-1k --prompt 1024 --wired --gpu-profile --profile-steps 20
  bench ops0 $BASE_BENCH base-kernels-8k --prompt 8192 --wired --gpu-profile --profile-steps 20
  bench ops0 $BASE_BENCH base-prefill-8k --prompt 8192 --prefill-chunk 512 --wired --prefill-profile
  bench ops0 $BASE_BENCH base-prefill-32k --prompt 32768 --prefill-chunk 512 --wired --prefill-profile
  xcrun xctrace record --template 'Metal System Trace' --output $OUT/base-decode-1k.trace \
    --launch -- $BASE_BENCH $MODEL --prompt 1024 --wired --steps 200 > $OUT/base-trace-1k.log 2>&1
  log "base trace-1k rc=$?"
}

phase_msb() {
  live_absent || { log "live appeared; abort"; exit 4; }
  log "msb rows=4 start"
  $CLI msb-throughput --model "$MODEL" --engine paged --rows 4 --prompt-tokens 1024 --decode-tokens 128 --runs 3 \
    --block-size-tokens 256 --mlx-cache-limit-mb 2048 --output $OUT/msb-rows4.json > $OUT/msb-rows4.out 2> $OUT/msb-rows4.err < /dev/null
  log "msb rows=4 rc=$? $(tail -2 $OUT/msb-rows4.err | tr '\n' ' ' | cut -c1-300)"
}

phase_omlx() {
  local dir=$LAB/omlx-models name=GLM-5.3-Flash-oQ4e-mtp sp=
  mkdir -p $dir
  [[ -e $dir/$name ]] || cp -c -R "$MODEL" $dir/$name
  $OMLX/omlx serve --model-dir $dir --port $PORT --max-concurrent-requests 8 --no-cache > $OUT/omlx-serve.log 2>&1 &
  sp=$!
  local ready=0
  for _ in {1..300}; do
    curl -sf http://127.0.0.1:$PORT/v1/models > $OUT/omlx-models.json 2>/dev/null && { ready=1; break; }
    kill -0 $sp 2>/dev/null || break
    sleep 2
  done
  (( ready )) || { log "omlx not ready: $(tail -5 $OUT/omlx-serve.log | tr '\n' ' ')"; kill $sp 2>/dev/null; return 5; }
  curl -s --max-time 900 http://127.0.0.1:$PORT/v1/chat/completions -H 'Content-Type: application/json' \
    -d "{\"model\":\"$name\",\"messages\":[{\"role\":\"user\",\"content\":\"warm up\"}],\"max_tokens\":16}" > $OUT/omlx-warm.json
  log "omlx ready"
  python3 -I $SWEEP --port $PORT --model $name --depths 1 --prompt-tokens 1024 --max-tokens 256 --window 120 --warmup 20 \
    --label omlx-1k --out $OUT/omlx-sweep.jsonl > $OUT/omlx-1k.log 2>&1
  for ctx in 8192 32768; do
    python3 -I $SWEEP --port $PORT --model $name --depths 1 --prompt-tokens $ctx --max-tokens 256 --window 240 --warmup 0 \
      --label omlx-ctx$ctx --out $OUT/omlx-sweep.jsonl > $OUT/omlx-$ctx.log 2>&1
  done
  log "omlx sweep $(tail -3 $OUT/omlx-sweep.jsonl | cut -c1-400 | tr '\n' ' ')"
  # Metal System Trace of steady decode: start a long request, record after its prefill.
  for ctx in 1024 8192; do
    python3 -I $SWEEP --port $PORT --model $name --depths 1 --prompt-tokens $ctx --max-tokens 1200 --window 60 --warmup 0 \
      --label omlx-trace-$ctx --out $OUT/omlx-trace-sweep.jsonl > $OUT/omlx-trace-$ctx.log 2>&1 &
    local cp=$!
    sleep $(( ctx > 4096 ? 35 : 8 ))
    xcrun xctrace record --template 'Metal System Trace' --attach $sp --time-limit 10s \
      --output $OUT/omlx-decode-$ctx.trace > $OUT/omlx-xctrace-$ctx.log 2>&1
    log "omlx trace-$ctx rc=$?"
    wait $cp
  done
  kill -TERM $sp 2>/dev/null
  for _ in {1..24}; do kill -0 $sp 2>/dev/null || break; sleep 5; done
  kill -KILL $sp 2>/dev/null
}

phase_camp() {
  [[ -x $CAMP_BENCH ]] || { log "no campaign bench; skip"; return 0; }
  (( TESTS_OK )) || { log "fork tests did not pass in this window; skip camp"; return 0; }
  cells $CAMP_BENCH camp
  bench ops0 $CAMP_BENCH camp-prefill-32k --prompt 32768 --prefill-chunk 512 --wired --prefill-profile
  bench ops0 $CAMP_BENCH camp-kernels-1k --prompt 1024 --wired --gpu-profile --profile-steps 20
  # The campaign changes keep every value bitwise: same tokens and top logits.
  for ctx in 1024 8192 32768 65536; do
    if diff <(grep -E '^(tokens|top_logits)=' $OUT/base-ctx$ctx.log) <(grep -E '^(tokens|top_logits)=' $OUT/camp-ctx$ctx.log) > /dev/null; then
      log "parity ctx=$ctx identical"
    else
      log "parity ctx=$ctx DIFFERS"
    fi
  done
}

phases=("$@"); (( ${#phases} )) || phases=(tests base msb omlx camp)
for p in $phases; do
  live_absent || { log "live appeared; abort"; exit 4; }
  phase_$p
done
log "window done: $phases"
touch $OUT/DONE
