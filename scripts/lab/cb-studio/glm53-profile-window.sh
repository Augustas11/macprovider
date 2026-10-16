#!/bin/zsh
# GLM-5.3-Flash decode GPU profile window (epic #2029). Run only inside an
# announced Studio window (buyer runner stopped, 0 in flight, :8080 paused).
# Each step loads the 186 GB artifact; they run one after another.
#   1. wired decode, MLX's default command buffers: GPU busy vs wall per step;
#   2. one kernel per command buffer (MLX_MAX_OPS_PER_BUFFER=0): GPU time,
#      bound bytes and GB/s per kernel and family at 1k and 8k context;
#   3. a Metal System Trace of 20 wired decode steps (timeline, idle gaps);
#   4. the fork's GLM5Next GPU tests.
# Env overrides: POC, BENCH, LM, MODEL, OUT.
set -euo pipefail
export DEVELOPER_DIR=${DEVELOPER_DIR:-$HOME/Applications/Xcode.app/Contents/Developer}
POC=${POC:-$HOME/lab-glm53/t3/poc}
BENCH=${BENCH:-$POC/scripts/lab/cb-studio/glm53-bench/.build/release/GLMBench}
LM=${LM:-$HOME/lab-glm53/t3/lm}
MODEL=${MODEL:-$HOME/lab-glm53/models/GLM-5.3-Flash-oQ4e-mtp}
OUT=${OUT:-$HOME/lab-glm53/t3/profile-$(date -u +%Y%m%dT%H%M%SZ)}
mkdir -p $OUT
[[ -f ${BENCH:h}/mlx.metallib ]] || { echo "missing ${BENCH:h}/mlx.metallib" >&2; exit 1; }
shasum -a 256 $BENCH ${BENCH:h}/mlx.metallib | tee $OUT/bench.sha256

$BENCH $MODEL --prompt 1024 --wired --gpu-profile --profile-steps 30 2>&1 | tee $OUT/busy-1k.log
MLX_MAX_OPS_PER_BUFFER=0 $BENCH $MODEL --prompt 1024 --wired --gpu-profile --profile-steps 20 2>&1 \
  | tee $OUT/kernels-1k.log
MLX_MAX_OPS_PER_BUFFER=0 $BENCH $MODEL --prompt 8192 --wired --gpu-profile --profile-steps 20 2>&1 \
  | tee $OUT/kernels-8k.log
xcrun xctrace record --template 'Metal System Trace' --output $OUT/decode-1k.trace \
  --launch -- $BENCH $MODEL --prompt 1024 --wired --steps 20 2>&1 | tee $OUT/trace.log
(cd $LM && swift test --build-system native --skip-build --filter GLM5NextTests) 2>&1 \
  | grep -E "Test Case.*(passed|failed)|Executed|error" | tee $OUT/lm-tests.log
echo "wrote $OUT"
