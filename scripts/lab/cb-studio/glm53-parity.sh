#!/bin/zsh
# T3 parity (epic #2029): native glm5_next vs the T2 mlx-vlm oracle, one model
# load for every context. Run only inside an announced Studio window (buyer
# runner stopped, 0 in flight, :8080 paused). It loads the 186 GB artifact.
#
# Env overrides: POC (lab checkout), BIN, MODEL, ORACLE_DIR, CONTEXTS, OUT, PY.
set -euo pipefail
POC=${POC:-$HOME/lab-glm53/poc}
# glm-parity exists only in a lab-harness build (the lab harness define).
BIN=${BIN:-$POC/phase3-binary/.build-lab-harness/release/macprovider-cli}
MODEL=${MODEL:-$HOME/lab-glm53/models/GLM-5.3-Flash-oQ4e-mtp}
ORACLE_DIR=${ORACLE_DIR:-$HOME/lab-glm53/t2b-20261016T1146/vlm}
CONTEXTS=(${=CONTEXTS:-1024 8192 65536})
OUT=${OUT:-$HOME/lab-glm53/t3-parity-$(date -u +%Y%m%dT%H%M%SZ)}
PY=${PY:-$HOME/lab-glm53/venv-omlx/bin/python}

[[ -x $BIN ]] || { echo "missing $BIN" >&2; exit 1; }
[[ -f ${BIN:h}/mlx.metallib ]] || { echo "missing ${BIN:h}/mlx.metallib (core v0.32.4-macprovider.4)" >&2; exit 1; }
mkdir -p $OUT
shasum -a 256 $BIN ${BIN:h}/mlx.metallib | tee $OUT/identity.sha256
oracles=()
for ctx in $CONTEXTS; do
  $PY -I $POC/scripts/lab/cb-studio/glm53_oracle_json.py $ORACLE_DIR/oracle_$ctx.npz $OUT/oracle_$ctx.json
  oracles+=(--oracle $OUT/oracle_$ctx.json)
done
$BIN glm-parity --model-dir $MODEL $oracles --steps 256 --output $OUT/parity.json \
  > $OUT/parity.stdout 2> >(tee $OUT/parity.stderr >&2)
echo "wrote $OUT/parity.json"
