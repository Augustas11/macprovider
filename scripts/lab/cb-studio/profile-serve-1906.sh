#!/bin/bash
# Issue #1906: CPU profile of the CB serve under 16-row output-heavy load,
# to find where serving loses time against model-level decode. Run under bench.sh.
set -u
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
LAB=/Users/a1/lab-1906
B=/Users/a1/macprovider-1906-cb-depth/phase3-binary/.build/release/macprovider-cli
OUT=$1; ROWS=${2:-16}; PORT=18090
mkdir -p "$OUT"
"$B" serve --config "$LAB/cfg/config.yaml" --port $PORT --no-join --autotune-candidate --no-idle-prewarm \
  > "$OUT/serve.log" 2>&1 &
SP=$!
trap 'kill $LP 2>/dev/null; kill $SP 2>/dev/null; sleep 5; kill -9 $SP 2>/dev/null' EXIT
for _ in $(seq 1 180); do curl -sf "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1 && break; sleep 2; done
echo "serve ready pid $SP $(date -u +%T)"
/usr/bin/python3 "$LAB/depth_sweep.py" --port $PORT --model qwen/qwen3.6-35b-a3b --depths $ROWS \
  --prompt-tokens 1800 --max-tokens 2300 --window 60 --warmup 60 --label profile --out "$OUT/sweep.jsonl" &
LP=$!
sleep 75
curl -s --max-time 3 "http://127.0.0.1:$PORT/v1/status" > "$OUT/status.json"
sample $SP 20 -file "$OUT/sample.txt" >/dev/null 2>&1
ps -o pid,%cpu,rss -p $SP > "$OUT/ps.txt"
top -l 2 -pid $SP -stats pid,cpu,threads | tail -2 >> "$OUT/ps.txt"
wait $LP
echo "PROFILE_DONE $(date -u +%T)"
