#!/bin/bash
# Epic #2029 T2: GLM-5.3-Flash reference lanes on the exact artifact
# (Jundot/GLM-5.3-Flash-oQ4e-mtp @ 36defc50). One lane per call so the two
# ~175 GB loads never overlap. Run under bench.sh (live paused + drained):
#   bench.sh glm53-t2.sh <out-dir> <omlx|vlm>
set -u
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
G=/Users/a1/lab-glm53; OUT=$1; LANE=$2; PORT=18095
MODEL_DIR=$G/models; MODEL=GLM-5.3-Flash-oQ4e-mtp
SWEEP=/Users/a1/lab-1906/depth_sweep.py
mkdir -p "$OUT"
SP=
trap 'kill $SP 2>/dev/null; sleep 5; kill -9 $SP 2>/dev/null' EXIT
mem() { vm_stat | awk -v t="$1" '/Pages free/{f=$3}/Pages active/{a=$3}/Pages wired/{w=$4}END{printf "MEM %s free_gb=%.1f active_gb=%.1f wired_gb=%.1f\n",t,f*16384/1e9,a*16384/1e9,w*16384/1e9}'; }
sysctl iogpu.wired_limit_mb hw.memsize > "$OUT/sysctl-$LANE.txt"
mem before
case $LANE in
  omlx)
    "$G/venv-omlx/bin/omlx" serve --model-dir "$MODEL_DIR" --port $PORT --max-concurrent-requests 8 --no-cache \
      > "$OUT/serve-omlx.log" 2>&1 & SP=$!
    for _ in $(seq 1 300); do curl -sf "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1 && break; kill -0 $SP 2>/dev/null || break; sleep 2; done
    curl -sf "http://127.0.0.1:$PORT/v1/models" > "$OUT/models-omlx.json" || { echo "OMLX_NOT_READY"; tail -20 "$OUT/serve-omlx.log"; exit 3; }
    echo "omlx ready $(date -u +%T)"
    curl -s --max-time 900 "http://127.0.0.1:$PORT/v1/chat/completions" -H "Content-Type: application/json" \
      -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"warm up\"}],\"max_tokens\":16}" > "$OUT/warm-omlx.json"
    mem loaded
    /usr/bin/python3 "$SWEEP" --port $PORT --model "$MODEL" --depths 1,4,8 \
      --prompt-tokens 1024 --max-tokens 256 --window 120 --warmup 30 --label "omlx/m0-1024-256" --out "$OUT/sweep.jsonl"
    for ctx in 8192 65536; do
      /usr/bin/python3 "$SWEEP" --port $PORT --model "$MODEL" --depths 1 \
        --prompt-tokens $ctx --max-tokens 256 --window 240 --warmup 0 --label "omlx/ctx-$ctx-256" --out "$OUT/sweep.jsonl"
    done
    mem after ;;
  vlm)
    "$G/venv-omlx/bin/python" "$G/bench_vlm.py" "$MODEL_DIR/$MODEL" "$OUT/vlm" --contexts 1024,8192,65536 --decode 256 --omlx-vendor \
      > "$OUT/vlm.log" 2>&1 & SP=$!
    wait $SP; rc=$?; SP=
    tail -5 "$OUT/vlm.log"; [ $rc -eq 0 ] || { echo "VLM_FAILED rc=$rc"; exit 6; }
    mem after ;;
  *) echo "unknown lane $LANE"; exit 2 ;;
esac
echo "LANE_DONE $LANE $(date -u +%T)"
