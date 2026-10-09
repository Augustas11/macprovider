#!/bin/bash
# Issue #1906 CB depth sweep on the Studio: fused and stock MoE decode on an
# isolated loopback serve. Run under bench.sh so live is paused and resumed.
#   bench.sh /Users/a1/lab-1906/depth-sweep-1906.sh <out-dir> [depths] [window]
set -u
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
LAB=/Users/a1/lab-1906
B=/Users/a1/macprovider-1906-cb-depth/phase3-binary/.build/release/macprovider-cli
OUT=$1; DEPTHS=${2:-4,8,12,16,24,32}; WINDOW=${3:-90}
PORT=18090; MODEL=qwen/qwen3.6-35b-a3b
mkdir -p "$OUT"
echo "binary_sha256 $(shasum -a 256 $B | cut -d' ' -f1)" | tee "$OUT/header.txt"
echo "depths $DEPTHS window ${WINDOW}s started $(date -u +%FT%TZ)" | tee -a "$OUT/header.txt"

SERVE_PID=
stop_serve() {
  [ -n "$SERVE_PID" ] || return 0
  kill "$SERVE_PID" 2>/dev/null
  for _ in $(seq 1 60); do kill -0 "$SERVE_PID" 2>/dev/null || break; sleep 1; done
  kill -9 "$SERVE_PID" 2>/dev/null
  SERVE_PID=
}
trap stop_serve EXIT

for variant in fused stock; do
  if [ "$variant" = stock ]; then FUSED=0; else FUSED=1; fi
  MLX_LM_QWEN35_FUSED_MOE=$FUSED "$B" serve --config "$LAB/cfg/config.yaml" --port $PORT \
    --no-join --autotune-candidate --no-idle-prewarm > "$OUT/serve-$variant.log" 2>&1 &
  SERVE_PID=$!
  ready=
  for _ in $(seq 1 180); do
    curl -sf "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1 && { ready=1; break; }
    kill -0 "$SERVE_PID" 2>/dev/null || break
    sleep 2
  done
  if [ -z "$ready" ]; then echo "SERVE_NOT_READY $variant"; tail -20 "$OUT/serve-$variant.log"; exit 3; fi
  echo "serve $variant ready pid $SERVE_PID $(date -u +%T)"
  /usr/bin/python3 "$LAB/depth_sweep.py" --port $PORT --model $MODEL --depths "$DEPTHS" \
    --prompt-tokens 1536 --max-tokens 256 --window "$WINDOW" --warmup 20 \
    --label "$variant" --out "$OUT/sweep.jsonl"
  grep -E "continuous_batching|batching_|paged_kv_attach|capability" "$OUT/serve-$variant.log" | head -20 > "$OUT/cb-gates-$variant.txt"
  stop_serve
done
echo "SWEEP_DONE $(date -u +%T)"
