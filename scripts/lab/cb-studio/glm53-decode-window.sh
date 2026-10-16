#!/bin/zsh
# GLM-5.3-Flash decode window (epic #2029): parity + decode tok/s through
# ModelRuntime, then the one-load bench (step times, oracle bisect, profile),
# then the fork's GLM5Next GPU tests. Run only inside an announced Studio
# window (buyer runner stopped, 0 in flight, :8080 paused). Each step loads
# the 186 GB artifact; they run one after another, never together.
#
# Env overrides: POC, BENCH, LM, MODEL, ORACLE, OUT.
set -euo pipefail
POC=${POC:-$HOME/lab-glm53/t3/poc}
BENCH=${BENCH:-$POC/scripts/lab/cb-studio/glm53-bench/.build/release/GLMBench}
LM=${LM:-$HOME/lab-glm53/t3/lm}
MODEL=${MODEL:-$HOME/lab-glm53/models/GLM-5.3-Flash-oQ4e-mtp}
ORACLE=${ORACLE:-$HOME/lab-glm53/t3/oracle/oracle_1024.json}
OUT=${OUT:-$HOME/lab-glm53/t3/window-$(date -u +%Y%m%dT%H%M%SZ)}
mkdir -p $OUT
[[ -f ${BENCH:h}/mlx.metallib ]] || { echo "missing ${BENCH:h}/mlx.metallib" >&2; exit 1; }
shasum -a 256 $BENCH ${BENCH:h}/mlx.metallib | tee $OUT/bench.sha256

POC=$POC OUT=$OUT/parity zsh $POC/scripts/lab/cb-studio/glm53-parity.sh 2>&1 | tee $OUT/parity.log
$BENCH $MODEL --prompt 1024 --wired --oracle $ORACLE --studio --profile 2>&1 | tee $OUT/bench.log
(cd $LM && swift test --build-system native --skip-build --filter GLM5NextTests) 2>&1 \
  | grep -E "Test Case.*(passed|failed)|Executed|error" | tee $OUT/lm-tests.log
echo "wrote $OUT"
