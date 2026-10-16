#!/bin/zsh
# GLM-5.3-Flash decode round 4 window (epic #2029). Run only inside an
# announced Studio window (buyer runner stopped, 0 in flight, :8080 paused).
#   1. dependent one-token qmv chains on our core (GLMBench) and on upstream
#      MLX 0.32.4 (the oMLX venv): is the core's qmv slower than upstream?
#   2. projection and MoE kernel bandwidth per thread layout (no model load);
#   3. pipelined decode at 1k: GPU busy vs wall per step, MLX's default
#      command-buffer budget, then a large per-buffer MB budget;
#   4. glm-parity at 1k/8k/64k (256/256 must hold).
# Model loads run one after another. Env overrides: POC, BENCH, MODEL, PY, OUT.
set -euo pipefail
export DEVELOPER_DIR=${DEVELOPER_DIR:-$HOME/Applications/Xcode.app/Contents/Developer}
POC=${POC:-$HOME/lab-glm53/t3/poc}
LAB=$POC/scripts/lab/cb-studio
BENCH=${BENCH:-$LAB/glm53-bench/.build/release/GLMBench}
MODEL=${MODEL:-$HOME/lab-glm53/models/GLM-5.3-Flash-oQ4e-mtp}
PY=${PY:-$HOME/lab-glm53/venv-omlx/bin/python}
OUT=${OUT:-$HOME/lab-glm53/t3/round4-$(date -u +%Y%m%dT%H%M%SZ)}
mkdir -p $OUT
[[ -f ${BENCH:h}/mlx.metallib ]] || { echo "missing ${BENCH:h}/mlx.metallib" >&2; exit 1; }
shasum -a 256 $BENCH ${BENCH:h}/mlx.metallib | tee $OUT/bench.sha256

$BENCH $MODEL --wired --qmv-chain 2>&1 | tee $OUT/qmv-chain-core.log
$PY -I $LAB/glm53_qmv_chain.py 2>&1 | tee $OUT/qmv-chain-upstream.log
MLX_MAX_OPS_PER_BUFFER=0 $BENCH $MODEL --qmv-sweep 2>&1 | tee $OUT/qmv-sweep.log
$BENCH $MODEL --prompt 1024 --wired --gpu-profile --profile-steps 30 2>&1 | tee $OUT/busy-1k.log
MLX_MAX_MB_PER_BUFFER=1000000 $BENCH $MODEL --prompt 1024 --wired --gpu-profile --profile-steps 30 2>&1 \
  | tee $OUT/busy-1k-mb.log
POC=$POC OUT=$OUT/parity zsh $LAB/glm53-parity.sh 2>&1 | tee $OUT/parity.log
echo "wrote $OUT"
