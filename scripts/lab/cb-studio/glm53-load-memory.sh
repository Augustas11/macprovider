#!/bin/zsh
# GLM-5.3-Flash load/prefill memory on truncated artifacts (epic #2029, T3).
# Cuts the artifact to 4 and 8 decoder layers (reused when present), runs
# glm-parity at 1k/8k/64k on each, and prints tensor bytes, MLX active peak
# and lifetime peak phys footprint, with a linear projection to 45 layers.
# Loads at most ~30 GB; no live provider is touched.
#
# Env overrides: POC, BIN, MODEL, ORACLES (dir of oracle_*.json), WORK, CACHE_MB, PY.
set -euo pipefail
POC=${POC:-$HOME/lab-glm53/t3/poc}
BIN=${BIN:-$POC/phase3-binary/.build/release/macprovider-cli}
MODEL=${MODEL:-$HOME/lab-glm53/models/GLM-5.3-Flash-oQ4e-mtp}
ORACLES=${ORACLES:-$HOME/lab-glm53/t3/oracle}
WORK=${WORK:-$HOME/lab-glm53/t3}
CACHE_MB=${CACHE_MB:-4096}
PY=${PY:-python3}
OUT=$WORK/load-memory-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p $OUT
shasum -a 256 $BIN ${BIN:h}/mlx.metallib | tee $OUT/identity.sha256
for n in 4 8; do
  [[ -d $WORK/glm-trunc-$n ]] || $PY -I $POC/scripts/lab/cb-studio/glm53_truncate_artifact.py $MODEL $WORK/glm-trunc-$n $n
  $BIN glm-parity --model-dir $WORK/glm-trunc-$n --mlx-cache-limit-mb $CACHE_MB --steps 4 \
    --oracle $ORACLES/oracle_1024.json --oracle $ORACLES/oracle_8192.json --oracle $ORACLES/oracle_65536.json \
    --output $OUT/trunc-$n.json > /dev/null 2> $OUT/trunc-$n.err
done
$PY -I - $OUT $WORK $MODEL <<'EOF'
import json, sys
from pathlib import Path
out, work, model = map(Path, sys.argv[1:])
def tensor_bytes(d):
    return json.loads((d / "model.safetensors.index.json").read_text())["metadata"]["total_size"]
rows = []
for n in (4, 8):
    r = json.loads((out / f"trunc-{n}.json").read_text())
    w = tensor_bytes(work / f"glm-trunc-{n}") / 1e9
    fp = r["peak_phys_footprint_mb"] * 1048576 / 1e9
    active = max(x["measurement"]["peak_memory_gb"] for x in r["runs"])
    rows.append((n, w, active, fp))
    print(f"layers={n} tensor_gb={w:.2f} mlx_active_peak_gb={active:.2f} peak_footprint_gb={fp:.2f} ratio={fp / w:.3f}")
(n4, w4, a4, f4), (n8, w8, a8, f8) = rows
# Shard sizes include each small JSON header; close enough for a projection.
wfull = sum(p.stat().st_size for p in model.glob("*.safetensors")) / 1e9
slope = (f8 - f4) / (w8 - w4)
proj = f4 + slope * (wfull - w4)
print(f"full tensor_gb={wfull:.2f} projected_peak_footprint_gb={proj:.1f} (slope {slope:.3f} per tensor GB)")
EOF
echo "wrote $OUT"
