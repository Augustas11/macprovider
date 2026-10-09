#!/bin/bash
# SPEC-038 FR-CB2 hybrid decode-window proof (#1906) on the served
# A3B artifact. `msb-throughput --scenario hybrid-window` decodes one fixed
# greedy batch (ragged prompts, all past the 512-token prefill chunk) at
# window 16 and at window 1 through the production backend path, --runs times
# each. PASS (exit 0) needs window 1 to repeat itself exactly and every row's
# window-16 tokens to equal its window-1 tokens. Both arms' aggregate decode
# tok/s are in the JSON.
#
# Exactness only (live provider keeps serving; tok/s not comparable):
#   hybrid-window-proof.sh <out-dir>
# Exactness plus throughput (live paused and resumed by bench.sh):
#   bench.sh /Users/a1/lab-1906/hybrid-window-proof.sh <out-dir>
#
# Optional: <rows> <prompt-tokens> <decode-tokens> (defaults 16 1536 256);
# env B (binary), M (model artifact path), LAB (config dir).
set -u
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
LAB=${LAB:-/Users/a1/lab-1906}
B=${B:-/Users/a1/macprovider-hybrid-window/phase3-binary/.build/release/macprovider-cli}
M=${M:-$(grep '^model_artifact_path:' "$LAB/cfg/config.yaml" | sed 's/^model_artifact_path: *//; s/"//g')}
OUT=${1:?usage: hybrid-window-proof.sh <out-dir> [rows] [prompt-tokens] [decode-tokens]}
ROWS=${2:-16}; PROMPT=${3:-1536}; DECODE=${4:-256}
mkdir -p "$OUT"
{
  echo "binary_sha256 $(shasum -a 256 "$B" | cut -d' ' -f1)"
  echo "model $M"
  echo "MLX_LM_QWEN35_FUSED_MOE=${MLX_LM_QWEN35_FUSED_MOE:-unset}"
  echo "rows=$ROWS prompt_tokens=$PROMPT decode_tokens=$DECODE window=16 runs=3"
} | tee "$OUT/header.txt"
"$B" msb-throughput --model "$M" --scenario hybrid-window --rows "$ROWS" --prompt-tokens "$PROMPT" \
  --decode-tokens "$DECODE" --decode-window 16 --runs 3 --max-physical-blocks 8192 \
  --output "$OUT/hybrid-window.json" > "$OUT/hybrid-window.log" 2>&1
rc=$?
grep -h "^msb-throughput: hybrid-window" "$OUT/hybrid-window.log"
if [ $rc -eq 0 ]; then echo "HYBRID_WINDOW_PASS"; else echo "HYBRID_WINDOW_FAIL rc=$rc"; fi
exit $rc
