#!/bin/bash
# Issue #1906: split the CB depth plateau into decode ceiling and prefill cost.
# Model-level decode only (msb-throughput, no HTTP or prefill), then the serve
# with short prompts so decode dominates. Run under bench.sh.
#   bench.sh /Users/a1/lab-1906/depth-split-1906.sh <out-dir>
set -u
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
LAB=/Users/a1/lab-1906
B=/Users/a1/macprovider-1906-cb-depth/phase3-binary/.build/release/macprovider-cli
M=$(grep '^model_artifact_path:' "$LAB/cfg/config.yaml" | sed 's/^model_artifact_path: *//; s/"//g')
OUT=$1; PORT=18090
mkdir -p "$OUT"
echo "binary_sha256 $(shasum -a 256 $B | cut -d' ' -f1)" | tee "$OUT/header.txt"
for r in 8 16 32; do
  "$B" msb-throughput --model "$M" --engine paged --rows $r --prompt-tokens 1536 --decode-tokens 128 \
    --runs 2 --max-physical-blocks 8192 --output "$OUT/msb-paged-r$r.json" > "$OUT/msb-paged-r$r.log" 2>&1
  grep -h "^msb-throughput: model" "$OUT/msb-paged-r$r.log" | sed "s/^/rows=$r /"
done
"$B" serve --config "$LAB/cfg/config.yaml" --port $PORT --no-join --autotune-candidate --no-idle-prewarm \
  > "$OUT/serve.log" 2>&1 &
SP=$!
trap 'kill $SP 2>/dev/null; sleep 5; kill -9 $SP 2>/dev/null' EXIT
for _ in $(seq 1 180); do curl -sf "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1 && break; sleep 2; done
echo "serve ready $(date -u +%T)"
/usr/bin/python3 "$LAB/depth_sweep.py" --port $PORT --model qwen/qwen3.6-35b-a3b --depths 8,16,32 \
  --prompt-tokens 128 --max-tokens 256 --window 60 --warmup 15 --label short-prompt --out "$OUT/sweep.jsonl"
echo "SPLIT_DONE $(date -u +%T)"
