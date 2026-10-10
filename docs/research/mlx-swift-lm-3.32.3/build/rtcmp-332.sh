#!/bin/bash
# Our-runtime rows of the #1906 runtime comparison on the 3.32.3 lab build (main config:
# max_batch 8, hybrid decode window 1). Same load generator, shapes, depths, warmup and
# window as runtime-compare-1906.sh. Run under bench.sh:
#   bench.sh rtcmp-332.sh <out-dir> <label> [VAR=value ...]
set -u
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
L=<studio-home>/lab-332; OUT=$1; RT=$2; shift 2; PORT=18199; MODEL=qwen/qwen3.6-35b-a3b
mkdir -p "$OUT"
SP=$($L/lab-serve.sh "$OUT/serve-$RT" $PORT "$@")
trap 'kill $SP 2>/dev/null; sleep 5; kill -9 $SP 2>/dev/null' EXIT
for _ in $(seq 1 180); do curl -sf "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1 && break; sleep 2; done
curl -s http://127.0.0.1:$PORT/v1/status | /usr/bin/python3 -c "import sys,json;d=json.load(sys.stdin)['continuous_batching'];print('cb active=%s paged=%s slots=%s'%(d['active'],d['paged_kv_decision'],d['scheduler']['slots_total']))"
echo "runtime $RT ready $(date -u +%T)"
curl -s --max-time 300 "http://127.0.0.1:$PORT/v1/chat/completions" -H "Content-Type: application/json" \
  -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"warm up\"}],\"max_tokens\":16}" >/dev/null
for shape in "1536 256 prompt-heavy" "1800 1024 output-heavy"; do
  set -- $shape
  /usr/bin/python3 <studio-home>/lab-1906/depth_sweep.py --port $PORT --model "$MODEL" --depths 1,8,16 \
    --prompt-tokens $1 --max-tokens $2 --window 90 --warmup 30 --label "$RT/$3" --out "$OUT/sweep.jsonl"
done
grep -c scheduler_admitted "$OUT/serve-$RT/serve-$PORT.log" | sed "s/^/scheduler_admitted=/"
echo "RT_DONE $RT $(date -u +%T)"
