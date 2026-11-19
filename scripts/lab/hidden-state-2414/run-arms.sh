#!/usr/bin/env bash
# Run every #2414 arm on one Mac. Forward passes only, no generation.
#
# The caller owns the machine: run this inside the Mac's lab window with the
# local provider paused (Studio: the lab-window wrapper; M5: the M5 queue
# owner's locked-and-paused wrapper). This script loads models and does not
# pause or resume anything itself.
#
#   run-arms.sh --host m3u --models-root DIR --out DIR --python PY [--fetch]
#   run-arms.sh --host m5  --models-root DIR --out DIR --python PY \
#       --ref-runs <copied m3u out dir> [--fetch]
#
# --models-root holds one directory per variant (4bit, 8bit, bf16); --fetch
# downloads the pinned revisions from inputs.json into it first.
#
# Arms:
#   m3u: default, tf32off (MLX_ENABLE_TF32=0)
#   m5:  default, tf32off, arch-m3u (MLX_METAL_GPU_ARCH = the M3 Ultra's
#        architecture string, read from --ref-runs)
# Base runs: every arm x variant, rep0 and rep1, each in its own process.
# Injection runs:
#   m3u: self-injection of default/4bit at every full layer (plumbing check).
#   m5:  self-injection of default/4bit, then for every arm, every claimed
#        variant c and full layer k, the M3 Ultra default/c layer-k output
#        injected into each M5 variant.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
INPUTS="$HERE/inputs.json"
HOST="" MODELS="" OUT="" PY="" REF="" FETCH=0
VARIANTS=(4bit 8bit bf16)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --models-root) MODELS="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --python) PY="$2"; shift 2 ;;
    --ref-runs) REF="$2"; shift 2 ;;
    --fetch) FETCH=1; shift ;;
    *) echo "run-arms: unknown argument $1" >&2; exit 2 ;;
  esac
done
[[ -n "$HOST" && -n "$MODELS" && -n "$OUT" && -n "$PY" ]] || { sed -n 2,26p "$0" >&2; exit 2; }
case "$HOST" in m3u|m5) ;; *) echo "run-arms: --host must be m3u or m5" >&2; exit 2 ;; esac
if [[ "$HOST" == m5 && -z "$REF" ]]; then echo "run-arms: m5 needs --ref-runs" >&2; exit 2; fi
if [[ -e "$OUT" ]] && [[ -n "$(ls -A "$OUT" 2>/dev/null)" ]]; then
  echo "run-arms: $OUT is not empty; use a fresh directory" >&2; exit 2
fi
mkdir -p "$OUT"
exec > >(tee -a "$OUT/run-arms.log") 2>&1

if [[ "$FETCH" == 1 ]]; then
  for v in "${VARIANTS[@]}"; do
    "$PY" -I - "$INPUTS" "$v" "$MODELS/$v" <<'PYEOF'
import json, sys
from huggingface_hub import snapshot_download
inputs, variant, dest = sys.argv[1:4]
m = json.load(open(inputs))["models"][variant]
snapshot_download(m["repo"], revision=m["revision"], local_dir=dest,
                  allow_patterns=["*.json", "*.safetensors"])
print(f"fetched {m['repo']}@{m['revision'][:12]} -> {dest}")
PYEOF
  done
fi
for v in "${VARIANTS[@]}"; do
  [[ -d "$MODELS/$v" ]] || { echo "run-arms: missing $MODELS/$v" >&2; exit 2; }
done

if [[ "$HOST" == m3u ]]; then
  ARMS=(default tf32off)
else
  for v in "${VARIANTS[@]}"; do
    [[ -f "$REF/base/default/$v/rep0/meta.json" ]] || { echo "run-arms: missing $REF/base/default/$v/rep0" >&2; exit 2; }
  done
  ARCH="$("$PY" -I -c 'import json,sys; a=json.load(open(sys.argv[1])).get("gpu_architecture"); sys.exit(1) if not a else print(a)' \
    "$REF/base/default/4bit/rep0/meta.json")" || { echo "run-arms: no gpu_architecture in --ref-runs" >&2; exit 2; }
  [[ -n "$ARCH" ]] || { echo "run-arms: no gpu_architecture in --ref-runs" >&2; exit 2; }
  echo "run-arms: arch-m3u arm forces MLX_METAL_GPU_ARCH=$ARCH"
  ARMS=(default tf32off arch-m3u)
fi

# Run dump.py with exactly one arm's flags; inherited flags are dropped.
dump() {
  local arm="$1"; shift
  local -a envs=(env -u MLX_ENABLE_TF32 -u MLX_METAL_GPU_ARCH)
  case "$arm" in
    default) ;;
    tf32off) envs+=(MLX_ENABLE_TF32=0) ;;
    arch-m3u) envs+=("MLX_METAL_GPU_ARCH=$ARCH") ;;
    *) echo "run-arms: unknown arm $arm" >&2; exit 2 ;;
  esac
  "${envs[@]}" "$PY" -I "$HERE/dump.py" --inputs "$INPUTS" --host "$HOST" --arm "$arm" "$@"
}

FULL_LAYERS="$("$PY" -I -c 'import json,sys; print(" ".join(map(str, json.load(open(sys.argv[1]))["full_layers"])))' "$INPUTS")"

for arm in "${ARMS[@]}"; do
  for v in "${VARIANTS[@]}"; do
    for rep in 0 1; do
      dump "$arm" --model "$MODELS/$v" --variant "$v" --rep "$rep" --out "$OUT/base/$arm/$v/rep$rep"
    done
  done
done

for k in $FULL_LAYERS; do
  dump default --model "$MODELS/4bit" --variant 4bit \
    --inject "$OUT/base/default/4bit/rep0" --inject-layer "$k" \
    --out "$OUT/inject/self/default/4bit/L$k"
done

if [[ "$HOST" == m5 ]]; then
  for arm in "${ARMS[@]}"; do
    for c in "${VARIANTS[@]}"; do
      for k in $FULL_LAYERS; do
        for v in "${VARIANTS[@]}"; do
          dump "$arm" --model "$MODELS/$v" --variant "$v" \
            --inject "$REF/base/default/$c/rep0" --inject-layer "$k" \
            --out "$OUT/inject/from-m3u-$c/$arm/$v/L$k"
        done
      done
    done
  done
fi

echo "run-arms: $HOST done -> $OUT"
