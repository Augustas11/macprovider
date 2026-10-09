#!/bin/bash
# Issue #1906: runtime comparison on the exact served MLX artifact
# (qwen/qwen3.6-35b-a3b 4-bit, snapshot 3fed776d...). One runtime per call so
# live is paused only for that runtime's cells. Run under bench.sh:
#   bench.sh runtime-compare-1906.sh <out-dir> <ours-w1|ours-w16|mlxlm|omlx|lmstudio>
set -u
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
LAB=/Users/a1/lab-1906; R=$LAB/runtimes
OUT=$1; RT=$2; PORT=18095
A=$(readlink "$R/omlx-models/qwen3.6-35b-a3b")
mkdir -p "$OUT"
SP=
trap 'kill $SP 2>/dev/null; sleep 5; kill -9 $SP 2>/dev/null' EXIT
case $RT in
  ours-w1|ours-w16)
    W=${RT#ours-w}; MODEL=qwen/qwen3.6-35b-a3b
    sed "s/^port: .*/port: $PORT/" "$LAB/cfg/config.yaml" > "$OUT/cfg-$RT.yaml"
    MACPROVIDER_LAB_HYBRID_DECODE_WINDOW=$W /Users/a1/macprovider-1906-cb-depth/phase3-binary/.build-lab/release/macprovider-cli \
      serve --config "$OUT/cfg-$RT.yaml" --port $PORT --no-join --autotune-candidate --no-idle-prewarm > "$OUT/serve-$RT.log" 2>&1 & ;;
  mlxlm)
    MODEL=$A
    "$R/venv-mlxlm/bin/mlx_lm.server" --model "$A" --port $PORT --decode-concurrency 32 --prompt-concurrency 8 \
      > "$OUT/serve-$RT.log" 2>&1 & ;;
  omlx)
    MODEL=qwen3.6-35b-a3b
    "$R/venv-omlx/bin/omlx" serve --model-dir "$R/omlx-models" --port $PORT --max-concurrent-requests 32 --no-cache \
      > "$OUT/serve-$RT.log" 2>&1 & ;;
  lmstudio)
    MODEL=${LMS_MODEL:?set LMS_MODEL}; PORT=${LMS_PORT:-1234} ;;
  *) echo "unknown runtime $RT"; exit 2 ;;
esac
SP=${!:-}; [ "$RT" = lmstudio ] && SP=
for _ in $(seq 1 180); do curl -sf "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1 && break; sleep 2; done
echo "runtime $RT ready $(date -u +%T)"
# Warm the model once so the first cell does not pay load/compile.
curl -s --max-time 300 "http://127.0.0.1:$PORT/v1/chat/completions" -H "Content-Type: application/json" \
  -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"warm up\"}],\"max_tokens\":16}" >/dev/null
for shape in "1536 256 prompt-heavy" "1800 1024 output-heavy"; do
  set -- $shape
  /usr/bin/python3 "$LAB/depth_sweep.py" --port $PORT --model "$MODEL" --depths 1,8,16 \
    --prompt-tokens $1 --max-tokens $2 --window 90 --warmup 30 --label "$RT/$3" --out "$OUT/sweep.jsonl"
done
echo "RT_DONE $RT $(date -u +%T)"
