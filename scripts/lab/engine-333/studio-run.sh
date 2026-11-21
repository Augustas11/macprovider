#!/usr/bin/env bash
# Engine-333 Studio window driver. Runs ON the Studio after the queue owner has
# paused live, the runner and the FLOP miner. Builds the campaign CLI, copies
# the live install (the .85 engine) to a lab base dir, clones the fork for the
# heavy suites, resolves provider model dirs and runs window.sh.
#
# usage: studio-run.sh LAB_DIR   (LAB_DIR holds macprovider/, the worktree of this branch)
set -uo pipefail
L="${1:?usage: studio-run.sh LAB_DIR}"
LM_REV=2a89037deb90ee67ee2be950e7a871fe2167f0fb
MODELS_ROOT="$HOME/Library/Application Support/macprovider/models"
cd "$L" || exit 64

echo "== release build $(date +%T)"
( cd macprovider/phase3-binary && swift build -c release --product macprovider-cli ) > build.log 2>&1 \
  || { echo "BUILD_FAILED"; tail -20 build.log; exit 2; }
NEW="$L/macprovider/phase3-binary/.build/release"

echo "== base copy of the live install $(date +%T)"
rm -rf base && cp -R /Users/a1/macprovider base || exit 3

if [ ! -d mlx-swift-lm ]; then git clone -q https://github.com/Augustas11/mlx-swift-lm.git mlx-swift-lm || exit 4; fi
git -C mlx-swift-lm fetch -q origin && git -C mlx-swift-lm checkout -q "$LM_REV" || exit 4

# name|org--model|mtp ; GDN Qwen rows first (gatedDeltaUpdate routing changed in 3.33.0).
SPECS=(
  "qwen35-27b|mlx-community--Qwen3.5-27B-4bit|"
  "qwen36-27b|mlx-community--Qwen3.6-27B-4bit|"
  "qwen36-35b-a3b|mlx-community--Qwen3.6-35B-A3B-4bit|"
  "qwen38-27b|mlx-community--Qwen3.8-27B-4bit|"
  "qwen35-35b-a3b|mlx-community--Qwen3.5-35B-A3B-4bit|"
  "qwen36-35b-a3b-mtp|mlx-community--Qwen3.6-35B-A3B-MTP-4bit|on"
  "qwen38-27b-mtp|mlx-community--Qwen3.8-27B-MTP-4bit|on"
  "glm53-flash-live|Solstice-AI--GLM-5.3-Flash-UNCENSORED-mlx-oQ4e-DFlash2|on"
  "dsv4-flash|TensorFold--DeepSeek-V4-Flash-0731-MXFP4-MLX|"
  "gemma4-26b-a4b|mlx-community--gemma-4-26b-a4b-it-4bit|"
  "gpt-oss-20b|mlx-community--gpt-oss-20b-MXFP4-Q8|"
  "nemotron3-nano|mlx-community--Nemotron-3-Nano-30B-A3B-4bit|"
)
ARGS=()
for s in "${SPECS[@]}"; do
  IFS='|' read -r name dir mtp <<< "$s"
  p=$(ls -d "$MODELS_ROOT/$dir"/*/* 2>/dev/null | head -1)
  [ -n "$p" ] || { echo "MODEL_MISSING $dir"; continue; }
  ARGS+=("$name=$p${mtp:+:$mtp}")
  echo "model $name -> $p"
done

echo "== window $(date +%T)"
bash macprovider/scripts/lab/engine-333/window.sh --base-bin "$L/base" --new-bin "$NEW" \
  --out "$L/window-1" --lm-dir "$L/mlx-swift-lm" "${ARGS[@]}"
rc=$?
echo "== studio-run done rc=$rc $(date +%T)"
exit $rc
