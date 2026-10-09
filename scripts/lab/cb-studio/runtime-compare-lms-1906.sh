#!/bin/bash
# Issue #1906: LM Studio (MLX engine) on the exact served artifact, same cells
# as runtime-compare-1906.sh. Run under bench.sh: bench.sh <this> <out-dir>
set -u
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
LAB=/Users/a1/lab-1906; OUT=$1; PORT=18096; L=$HOME/.lmstudio/bin/lms; ID=qwen36-lab
mkdir -p "$OUT"
trap '$L unload $ID >/dev/null 2>&1; $L server stop >/dev/null 2>&1' EXIT
$L server start -p $PORT > "$OUT/serve-lmstudio.log" 2>&1
$L load "qwen3.6-35b-a3b" --identifier $ID --parallel 16 -c 8192 --gpu max -y >> "$OUT/serve-lmstudio.log" 2>&1
ok=
for _ in $(seq 1 90); do curl -sf "http://127.0.0.1:$PORT/v1/models" | grep -q $ID && { ok=1; break; }; sleep 2; done
[ -n "$ok" ] || { echo "LMSTUDIO_MODEL_NOT_LOADED"; tail -5 "$OUT/serve-lmstudio.log"; exit 3; }
echo "runtime lmstudio ready $(date -u +%T)"; $L ps 2>&1 | tail -3
curl -s --max-time 300 "http://127.0.0.1:$PORT/v1/chat/completions" -H "Content-Type: application/json" \
  -d "{\"model\":\"$ID\",\"messages\":[{\"role\":\"user\",\"content\":\"warm up\"}],\"max_tokens\":16}" >/dev/null
for shape in "1536 256 prompt-heavy" "1800 1024 output-heavy"; do
  set -- $shape
  /usr/bin/python3 "$LAB/depth_sweep.py" --port $PORT --model $ID --depths 1,8,16 \
    --prompt-tokens $1 --max-tokens $2 --window 90 --warmup 30 --label "lmstudio/$3" --out "$OUT/sweep.jsonl"
done
echo "RT_DONE lmstudio $(date -u +%T)"
