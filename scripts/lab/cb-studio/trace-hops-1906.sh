#!/bin/bash
# Issue #1906: same 16-row load streamed vs non-streamed, to test whether the
# streaming path's per-token re-detokenization costs throughput. Run under bench.sh.
set -u
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
LAB=/Users/a1/lab-1906
B=/Users/a1/macprovider-1906-cb-depth/phase3-binary/.build/release/macprovider-cli
OUT=$1; ROWS=${2:-16}; PORT=18090
mkdir -p "$OUT"
MACPROVIDER_CB_TRACE=1 "$B" serve --config "$LAB/cfg/config.yaml" --port $PORT --no-join --autotune-candidate --no-idle-prewarm \
  > "$OUT/serve.log" 2>&1 &
SP=$!
trap 'kill $SP 2>/dev/null; sleep 5; kill -9 $SP 2>/dev/null' EXIT
for _ in $(seq 1 180); do curl -sf "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1 && break; sleep 2; done
echo "serve ready $(date -u +%T)"
for mode in stream; do
  flag=; [ "$mode" = nostream ] && flag=--no-stream
  /usr/bin/python3 "$LAB/depth_sweep.py" --port $PORT --model qwen/qwen3.6-35b-a3b --depths $ROWS \
    --prompt-tokens 1800 --max-tokens 1024 --window 150 --warmup 45 --label $mode $flag --out "$OUT/sweep.jsonl"
done
echo "TRACE_DONE $(date -u +%T)"
