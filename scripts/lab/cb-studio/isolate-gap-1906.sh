#!/bin/bash
# Issue #1906: isolate why mlx-lm out-serves our runtime at depth. Same served
# artifact and cells; one variable per run. Run under bench.sh.
#   A: mlx-lm 0.31.3 on MLX 0.31.2 (our MLX generation)  -> MLX version effect
#   B: ours window 16 with stock MoE (fused off)         -> fused kernel effect
#   C: model-level paged vs contiguous KV, 8/16 rows     -> paged cache effect
set -u
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
LAB=/Users/a1/lab-1906; R=$LAB/runtimes; OUT=$1; PORT=18097
A=$(readlink "$R/omlx-models/qwen3.6-35b-a3b")
B=/Users/a1/macprovider-1906-cb-depth/phase3-binary/.build-lab/release/macprovider-cli
mkdir -p "$OUT"; SP=
trap 'kill $SP 2>/dev/null; sleep 5; kill -9 $SP 2>/dev/null' EXIT
cells() { # label model
  for shape in "1536 256 prompt-heavy" "1800 1024 output-heavy"; do
    set -- $shape "$1" "$2"
    /usr/bin/python3 "$LAB/depth_sweep.py" --port $PORT --model "$5" --depths 8,16 \
      --prompt-tokens $1 --max-tokens $2 --window 90 --warmup 30 --label "$4/$3" --out "$OUT/sweep.jsonl"
  done
}
wait_up() { for _ in $(seq 1 180); do curl -sf "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1 && break; sleep 2; done
  curl -s --max-time 300 "http://127.0.0.1:$PORT/v1/chat/completions" -H "Content-Type: application/json" \
    -d "{\"model\":\"$1\",\"messages\":[{\"role\":\"user\",\"content\":\"warm up\"}],\"max_tokens\":16}" >/dev/null; }
stop() { kill $SP; for _ in $(seq 1 30); do kill -0 $SP 2>/dev/null || break; sleep 1; done; kill -9 $SP 2>/dev/null; SP=; }

"$R/venv-mlxlm031/bin/mlx_lm.server" --model "$A" --port $PORT --decode-concurrency 32 --prompt-concurrency 8 \
  > "$OUT/serve-mlxlm031.log" 2>&1 & SP=$!
wait_up "$A"; echo "A mlxlm031 ready $(date -u +%T)"; cells mlxlm-0.31 "$A"; stop

sed "s/^port: .*/port: $PORT/" "$LAB/cfg/config.yaml" > "$OUT/cfg.yaml"
MLX_LM_QWEN35_FUSED_MOE=0 MACPROVIDER_LAB_HYBRID_DECODE_WINDOW=16 "$B" serve --config "$OUT/cfg.yaml" --port $PORT \
  --no-join --autotune-candidate --no-idle-prewarm > "$OUT/serve-ours-stock.log" 2>&1 & SP=$!
wait_up qwen/qwen3.6-35b-a3b; echo "B ours-w16-stock ready $(date -u +%T)"; cells ours-w16-stock qwen/qwen3.6-35b-a3b; stop

for eng in paged contiguous; do for r in 8 16; do
  "$B" msb-throughput --model "$A" --engine $eng --rows $r --prompt-tokens 1536 --decode-tokens 128 --runs 2 \
    --max-physical-blocks 8192 --output "$OUT/msb-$eng-r$r.json" > "$OUT/msb-$eng-r$r.log" 2>&1
  grep -h "^msb-throughput: model" "$OUT/msb-$eng-r$r.log" | sed "s/^/C $eng rows=$r /"
done; done
echo "ISOLATE_DONE $(date -u +%T)"
