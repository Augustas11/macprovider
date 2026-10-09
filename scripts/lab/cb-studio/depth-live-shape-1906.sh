#!/bin/bash
# Issue #1906: CB depth at the live request shape (median ~1.8k prompt,
# ~2.3k output tokens, no prefix reuse), production fused decode. Run under
# bench.sh so live is paused and resumed.
#   bench.sh /Users/a1/lab-1906/depth-live-shape-1906.sh <out-dir> [depths]
set -u
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
LAB=/Users/a1/lab-1906
B=/Users/a1/macprovider-1906-cb-depth/phase3-binary/.build/release/macprovider-cli
OUT=$1; DEPTHS=${2:-8,16,24}; PORT=18090
mkdir -p "$OUT"
echo "binary_sha256 $(shasum -a 256 $B | cut -d' ' -f1)" | tee "$OUT/header.txt"
"$B" serve --config "$LAB/cfg/config.yaml" --port $PORT --no-join --autotune-candidate --no-idle-prewarm \
  > "$OUT/serve.log" 2>&1 &
SP=$!
trap 'kill $SP 2>/dev/null; sleep 5; kill -9 $SP 2>/dev/null' EXIT
for _ in $(seq 1 180); do curl -sf "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1 && break; sleep 2; done
echo "serve ready $(date -u +%T)"
/usr/bin/python3 "$LAB/depth_sweep.py" --port $PORT --model qwen/qwen3.6-35b-a3b --depths "$DEPTHS" \
  --prompt-tokens 1800 --max-tokens 2300 --window 180 --warmup 60 --label live-shape --out "$OUT/sweep.jsonl"
echo "LIVE_SHAPE_DONE $(date -u +%T)"
