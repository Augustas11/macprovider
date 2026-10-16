#!/bin/bash
# #1986 real-chip threshold validation, Studio part (docs/runbooks/compute-integrity-threshold-validation.md).
#
# Lab-only measurement in its own process with its own model copy. It never
# touches the live provider, its install dir or its config, and it pauses
# nothing: run it only inside an operator window with live paused and drained
# to 0 in flight and the buyer runner stopped.
#
# LAB_DIR (default ~/lab-1986) must hold:
#   bin/macprovider-cli          lab build of the PR head
#   bin/mlx.metallib             identical to the live install's (same MLX pin)
#   bin/corpus.json bin/summarize.py bin/warmband.py
#   m3b/                         the catalog Llama-3.2-3B-Instruct-4bit artifact used on the other chips
#   honest-M5.json honest-Air.json subst-3bit-M5.json subst-2bit-M5.json
#   M5-scores-honest-M5.json Air-scores-honest-Air.json
set -euo pipefail
LAB_DIR=${LAB_DIR:-$HOME/lab-1986}
cd "$LAB_DIR"
CLI=bin/macprovider-cli
M=${MODEL_DIR:-m3b}
METALLIB_SHA16=${METALLIB_SHA16:-}
WEIGHTS_SHA16=${WEIGHTS_SHA16:-}
log() { echo "[$(date -u +%TZ)] $*"; }
[ -z "$METALLIB_SHA16" ] || [ "$(shasum -a 256 bin/mlx.metallib | cut -c1-16)" = "$METALLIB_SHA16" ] || { log "metallib mismatch"; exit 2; }
[ -z "$WEIGHTS_SHA16" ] || [ "$(shasum -a 256 "$M/model.safetensors" | cut -c1-16)" = "$WEIGHTS_SHA16" ] || { log "weights mismatch"; exit 2; }
for f in bin/corpus.json honest-M5.json honest-Air.json subst-3bit-M5.json subst-2bit-M5.json M5-scores-honest-M5.json Air-scores-honest-Air.json; do
  [ -s "$f" ] || { log "missing $f"; exit 2; }
done
! pgrep -f "msb-compute-score" >/dev/null || { log "another lab run is active"; exit 2; }
# Watchdog: the lab run never outlives 40 minutes.
( sleep 2400; pkill -f "bin/macprovider-cli msb-compute-score" ) & WD=$!
trap 'kill $WD 2>/dev/null || true' EXIT
log "1/5 honest outputs + same-chip score"
$CLI msb-compute-score --model "$M" --corpus bin/corpus.json --emit-outputs honest-Studio.json --report Studio-scores-honest-Studio.json >/dev/null 2>s1.err
log "2/5 cross-chip scores of M5 and Air outputs"
$CLI msb-compute-score --model "$M" --score-outputs honest-M5.json  --report Studio-scores-honest-M5.json  >/dev/null 2>s2.err
$CLI msb-compute-score --model "$M" --score-outputs honest-Air.json --report Studio-scores-honest-Air.json >/dev/null 2>s3.err
log "3/5 substituted outputs (3-bit, 2-bit) under the claimed model"
$CLI msb-compute-score --model "$M" --score-outputs subst-3bit-M5.json --report Studio-scores-subst-3bit-M5.json >/dev/null 2>s4a.err
$CLI msb-compute-score --model "$M" --score-outputs subst-2bit-M5.json --report Studio-scores-subst-2bit-M5.json >/dev/null 2>s4b.err
log "4/5 scoring under 4 concurrent generations"
$CLI msb-compute-score --model "$M" --score-outputs honest-Studio.json --concurrent-load 4 --report Studio-under-load.json >/dev/null 2>s5.err
log "5/5 summary and three-chip warm band"
python3 -I bin/summarize.py Studio-*.json
python3 -I bin/warmband.py M5-scores-honest-M5.json,Air-scores-honest-Air.json,Studio-scores-honest-Studio.json \
  Studio-scores-honest-M5.json Studio-scores-honest-Air.json Studio-scores-subst-3bit-M5.json Studio-scores-subst-2bit-M5.json
log "done"
