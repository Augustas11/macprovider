#!/bin/zsh
# GLM-5.3-Flash final decode-tuning window (epic #2029): glm-parity at
# 1k/8k/64k through ModelRuntime (256/256 must hold; it now sets glm5_next's
# command-buffer budget itself), then pipelined busy vs wall at 1k with the
# same budget. Run only inside an announced Studio window (buyer runner
# stopped, 0 in flight, :8080 paused); the two loads run one after another.
# Env overrides: POC, BENCH, MODEL, OUT.
set -euo pipefail
export DEVELOPER_DIR=${DEVELOPER_DIR:-$HOME/Applications/Xcode.app/Contents/Developer}
POC=${POC:-$HOME/lab-glm53/t3/poc}
LAB=$POC/scripts/lab/cb-studio
BENCH=${BENCH:-$LAB/glm53-bench/.build/release/GLMBench}
MODEL=${MODEL:-$HOME/lab-glm53/models/GLM-5.3-Flash-oQ4e-mtp}
OUT=${OUT:-$HOME/lab-glm53/t3/final-$(date -u +%Y%m%dT%H%M%SZ)}
mkdir -p $OUT
POC=$POC OUT=$OUT/parity zsh $LAB/glm53-parity.sh 2>&1 | tee $OUT/parity.log
grep -q "mlx_max_mb_per_buffer=65536" $OUT/parity/parity.stderr || echo "WARNING: glm-parity did not apply the command-buffer budget" | tee -a $OUT/parity.log
# The bench sets no budget itself; give it the provider's value.
MLX_MAX_MB_PER_BUFFER=65536 $BENCH $MODEL --prompt 1024 --wired --gpu-profile --profile-steps 30 2>&1 | tee $OUT/busy-1k.log
echo "wrote $OUT"
