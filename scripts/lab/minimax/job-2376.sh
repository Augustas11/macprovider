#!/bin/bash
# Runs ON THE STUDIO, started detached by studio-2376.sh. Epic #2376 job: refusal-direction
# ablation of MiniMax M3.1-Flash on the catalog MLX artifact (minimax_ablate.py), measured
# against the unmodified model in the same process.
set -u
LAB=$HOME/lab-2376
JOB=$LAB/job
RES=$LAB/results
VENV=$LAB/venv-vlm
BASE=${BASE:-$(ls -d "$HOME"/lab-2189/models/*[Mm]ini[Mm]ax*oQ3e* 2>/dev/null | head -n 1)}
log() { echo "$(date -u '+%H:%M:%S') $*"; }
blocker() { log "BLOCKER: $*"; exit "${2:-1}"; }
mkdir -p "$RES"
log "JOB_START base=$BASE"
[ -n "$BASE" ] && [ -f "$BASE/config.json" ] || blocker "no MiniMax oQ3e base row under ~/lab-2189/models" 11
if ! "$VENV/bin/python" -c "import mlx_vlm, mlx_lm" 2>/dev/null; then
  log "creating $VENV (mlx-vlm 0.7.11, mlx-lm 0.32.2)"
  PY=$(command -v python3.12 || echo /opt/homebrew/bin/python3.12)
  [ -x "$PY" ] || blocker "python3.12 not found for the mlx-vlm venv" 12
  "$PY" -m venv "$VENV" && "$VENV/bin/pip" install -q "mlx-vlm==0.7.11" "mlx-lm==0.32.2" \
    || blocker "venv install failed" 12
fi
"$VENV/bin/python" -c "import importlib.metadata as m; print('versions', m.version('mlx-vlm'), m.version('mlx'), m.version('mlx-lm'))"
(cd "$JOB/data" && shasum -a 256 -c ../data.sha256) || blocker "data files differ from data.sha256" 13
"$VENV/bin/python" -I "$JOB/minimax_ablate.py" "$BASE" "$JOB/data" "$RES/ablate" ${ABLATE_ARGS:-} \
  > "$RES/ablate.stdout" 2> "$RES/ablate.stderr"
rc=$?
grep '^ABLATE_' "$RES/ablate.stdout" > "$RES/summary.txt"
cat "$RES/summary.txt"
[ $rc = 0 ] || blocker "minimax_ablate.py exit $rc: $(tail -n 2 "$RES/ablate.stderr" | tr '\n' ' ')" 14
log "JOB_PASS"
