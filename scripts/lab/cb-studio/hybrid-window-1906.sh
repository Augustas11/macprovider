#!/bin/bash
# Issue #1906: 16-row throughput with hybrid decode window 1 vs 16 (lab-only
# override). Run under bench.sh.
set -u
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
LAB=/Users/a1/lab-1906
B=/Users/a1/macprovider-1906-cb-depth/phase3-binary/.build-lab/release/macprovider-cli
OUT=$1; ROWS=${2:-16}; PORT=18090
mkdir -p "$OUT"
echo "binary_sha256 $(shasum -a 256 $B | cut -d' ' -f1)" | tee "$OUT/header.txt"
SP=
trap 'kill $SP 2>/dev/null; sleep 5; kill -9 $SP 2>/dev/null' EXIT
for w in 1 16; do
  MACPROVIDER_CB_TRACE=1 MACPROVIDER_LAB_HYBRID_DECODE_WINDOW=$w "$B" serve --config "$LAB/cfg/config.yaml" \
    --port $PORT --no-join --autotune-candidate --no-idle-prewarm > "$OUT/serve-w$w.log" 2>&1 &
  SP=$!
  for _ in $(seq 1 180); do curl -sf "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1 && break; sleep 2; done
  echo "serve w=$w ready $(date -u +%T)"
  /usr/bin/python3 "$LAB/depth_sweep.py" --port $PORT --model qwen/qwen3.6-35b-a3b --depths $ROWS \
    --prompt-tokens 1800 --max-tokens 1024 --window 120 --warmup 45 --label window-$w --out "$OUT/sweep.jsonl"
  python3 "$LAB/analyze_hops.py" "$OUT/serve-w$w.log" 45 | sed "s/^/w=$w /"
  kill $SP; for _ in $(seq 1 30); do kill -0 $SP 2>/dev/null || break; sleep 1; done; kill -9 $SP 2>/dev/null; SP=
done
echo "HW_DONE $(date -u +%T)"
