#!/usr/bin/env bash
# Engine-333 Studio window driver. Runs ON the Studio after the queue owner has
# paused live, the runner and the FLOP miner. Builds the campaign CLI, copies
# the live install (the .85 engine) to a lab base dir, clones the fork for the
# heavy suites, resolves provider model dirs and runs window.sh.
#
# usage: studio-run.sh LAB_DIR   (LAB_DIR holds macprovider/, the worktree of this branch)
# env: WINDOW (output dir window-N, default 4); DIAG=1 runs studio-diag.sh first; ONLY="name ..."
# limits the models; NO_MTP="name ..." drops their native-MTP pass (the admission capture byte-copies
# the whole model, #2468: GLM-5.3-Flash needs 176 GB free per start); SKIP_HEAVY=1 skips the heavy fork suites (they passed in window 3).
set -uo pipefail
L="${1:?usage: studio-run.sh LAB_DIR}"
LM_REV=748d330d213c673637617f29bd863020f4565fd4
MODELS_ROOT="$HOME/Library/Application Support/macprovider/models"
cd "$L" || exit 64

echo "== release build $(date +%T)"
( cd macprovider/phase3-binary && swift build -c release --product macprovider-cli ) > build.log 2>&1 \
  || { echo "BUILD_FAILED"; tail -20 build.log; exit 2; }
NEW="$L/macprovider/phase3-binary/.build/release"
# swift build ships no metallib: build the 0.33 one from this build's mlx-swift checkout (as
# package.sh does) next to the binary, where the serve and the CB tuple measurement find it.
DEVELOPER_DIR="${DEVELOPER_DIR:-$HOME/Applications/Xcode.app/Contents/Developer}" \
  bash macprovider/phase3-binary/scripts/build-mlx-metallib.sh "$NEW" > metallib.log 2>&1 \
  || { echo "METALLIB_FAILED"; tail -20 metallib.log; exit 2; }

echo "== base copy of the live install $(date +%T)"
rm -rf base && cp -R /Users/a1/macprovider base || exit 3

if [ ! -d mlx-swift-lm ]; then git clone -q https://github.com/Augustas11/mlx-swift-lm.git mlx-swift-lm || exit 4; fi
git -C mlx-swift-lm fetch -q origin && git -C mlx-swift-lm checkout -q "$LM_REV" || exit 4

if [ "${DIAG:-0}" = 1 ]; then
  echo "== diagnostics $(date +%T)"
  WINDOW="${WINDOW:-4}" bash macprovider/scripts/lab/engine-333/studio-diag.sh "$L" "$NEW" "$L/base" "$LM_REV"
  echo "diag rc=$?"
fi

# name|org--model|catalog key|mtp ; GDN Qwen rows first (gatedDeltaUpdate routing changed in 3.33.0).
# mtp = the key has a native-MTP admission entry (native-mtp-admission.json): a 1-row native-MTP pass.
SPECS=(
  "qwen35-27b|mlx-community--Qwen3.5-27B-4bit|qwen/qwen3.5-27b|"
  "qwen36-27b|mlx-community--Qwen3.6-27B-4bit|qwen/qwen3.6-27b|mtp"
  "qwen36-35b-a3b|mlx-community--Qwen3.6-35B-A3B-4bit|qwen/qwen3.6-35b-a3b|mtp"
  "qwen38-27b|mlx-community--Qwen3.8-27B-4bit|qwen/qwen3.8-27b|mtp"
  "qwen35-35b-a3b|mlx-community--Qwen3.5-35B-A3B-4bit|qwen/qwen3.5-35b-a3b|"
  "glm53-flash-live|Solstice-AI--GLM-5.3-Flash-UNCENSORED-mlx-oQ4e-DFlash2|zai-org/glm-5.3-flash-uncensored|mtp"
  "gemma4-26b-a4b|mlx-community--gemma-4-26b-a4b-it-4bit|google-gemma-4-26b-a4b-it|"
  "gpt-oss-20b|mlx-community--gpt-oss-20b-MXFP4-Q8|openai/gpt-oss-20b|"
  "nemotron3-nano|mlx-community--NVIDIA-Nemotron-3-Nano-30B-A3B-4bit|nvidia/nemotron-3-nano-30b-a3b|"
)
ARGS=()
for s in "${SPECS[@]}"; do
  IFS='|' read -r name dir key mtp <<< "$s"
  if [ -n "${ONLY:-}" ] && [[ " $ONLY " != *" $name "* ]]; then continue; fi
  if [[ " ${NO_MTP:-} " == *" $name "* ]]; then mtp=""; fi
  p=$(ls -d "$MODELS_ROOT/$dir"/*/* 2>/dev/null | head -1)
  [ -n "$p" ] || { echo "MODEL_MISSING $dir"; continue; }
  ARGS+=("$name=$p@$key${mtp:+:$mtp}")
  echo "model $name -> $p ($key${mtp:+, native MTP})"
done

# mlx-swift-lm #633 (c408452) fixes the gated delta q/k L2-norm eps to the transformers
# reference: every GDN Qwen key's text changes on purpose (studio-diag.sh proves it is the only change).
export TEXT_CHANGE_KEYS="qwen/qwen3.5-27b=mlx-swift-lm#633 qwen/qwen3.6-27b=mlx-swift-lm#633 qwen/qwen3.6-35b-a3b=mlx-swift-lm#633 qwen/qwen3.8-27b=mlx-swift-lm#633 qwen/qwen3.5-35b-a3b=mlx-swift-lm#633"
echo "== window $(date +%T)"
bash macprovider/scripts/lab/engine-333/window.sh --base-bin "$L/base" --new-bin "$NEW" \
  --out "$L/window-${WINDOW:-4}" --lm-dir "$L/mlx-swift-lm" "${ARGS[@]}"
rc=$?
echo "== studio-run done rc=$rc $(date +%T)"
exit $rc
