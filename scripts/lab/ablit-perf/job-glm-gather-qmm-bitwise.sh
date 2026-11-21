#!/bin/bash
# Runs ON THE STUDIO from ~/lab-ablit-perf/job/ablit-perf/. #2451: does mx.gather_qmm on the sorted-indices
# route (gather_qmm_rhs, as SwitchGLU runs the GLM-5.3-Flash experts at prefill) give a row the same bits
# whatever the other rows sharing its 16-row tiles are? glm_gather_qmm_bitwise.py (header: shapes, cases,
# why the upstream wheel runs the provider's gather_qmm code). No model, no build, no serve: random 4-bit
# expert weights at GLM shapes from a fixed seed, about 4 GB of GPU memory.
# Steps: `pin` reads the MLX core the provider pins (Package.resolved of the rsynced tree through
# scripts/read_swiftpm_pins.py, copied to job/pins) and prints its upstream release; a python3.12 venv
# (~/lab-ablit-perf/venv-gqmm) gets mlx==<that release> and nothing else; `run` prints BITWISE_EQUAL /
# BITWISE_DIFF per case and stage and GQMM_VERDICT.
# Results: ~/lab-ablit-perf/results/<run>/glm-gather-qmm-bitwise/{bitwise.json,bitwise.txt,plan.txt,pin.txt,venv.log}.
# Env: GQMM_SEED (default 2451) GQMM_TARGETS (target tokens, default 32). GQMM_JOB_CHECK=1: validate the
# knobs, print the pin/plan/run argv and exit 0 before touching anything (the unit test).
# A BITWISE_DIFF is the finding, not a failure: the job ends JOB_PASS when the run completed with a
# deterministic reference, else `BLOCKER:` and JOB_FAIL.
set -u
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
LAB=$HOME/lab-ablit-perf
JOB=$LAB/job
SRC=$LAB/src/phase3-binary
RUN_ID=${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}
RES=$LAB/results/$RUN_ID/glm-gather-qmm-bitwise
VENV=$LAB/venv-gqmm
GQMM_SEED=${GQMM_SEED:-2451}
GQMM_TARGETS=${GQMM_TARGETS:-32}
SCRIPT=$JOB/ablit-perf/glm_gather_qmm_bitwise.py
log() { echo "$(date '+%H:%M:%S') $*"; }
die() { log "BLOCKER: $*"; log "JOB_FAIL"; exit "${2:-1}"; }

case "$GQMM_SEED" in ""|*[!0-9]*) die "GQMM_SEED=$GQMM_SEED must be a number" 64 ;; esac
case "$GQMM_TARGETS" in ""|*[!0-9]*) die "GQMM_TARGETS=$GQMM_TARGETS must be 1..256" 64 ;; esac
[ "$GQMM_TARGETS" -ge 1 ] && [ "$GQMM_TARGETS" -le 256 ] || die "GQMM_TARGETS=$GQMM_TARGETS must be 1..256" 64
PIN_ARGS=(pin --pins-dir "$JOB/pins" --resolved "$SRC/Package.resolved")
CASE_ARGS=(--seed "$GQMM_SEED" --targets "$GQMM_TARGETS")
if [ "${GQMM_JOB_CHECK:-0}" = 1 ]; then
  printf 'PIN_ARGS'; printf ' %s' "${PIN_ARGS[@]}"; echo
  printf 'PLAN_ARGS plan'; printf ' %s' "${CASE_ARGS[@]}"; echo
  printf 'RUN_ARGS run'; printf ' %s' "${CASE_ARGS[@]}"; echo " --expect-mlx <pin wheel> --out-json $RES/bitwise.json"
  echo "VENV $VENV mlx==<pin wheel>"
  exit 0
fi

rm -rf "$RES" && mkdir -p "$RES"
log "JOB_START glm-gather-qmm-bitwise run=$RUN_ID commit=${COMMIT:-unknown} seed=$GQMM_SEED targets=$GQMM_TARGETS"
if lsof -nP -iTCP:8080 -sTCP:LISTEN -t >/dev/null 2>&1; then die "a server listens on :8080; the Studio is not paused" 3; fi
launchctl print "gui/$(id -u)/live.malibu.provider" >/dev/null 2>&1 && die "live.malibu.provider is loaded" 3
pgrep -f "[m]acprovider-cli serve" >/dev/null 2>&1 && die "a macprovider-cli serve process runs" 3
[ -f "$SCRIPT" ] || die "no $SCRIPT" 11
[ -f "$JOB/pins/read_swiftpm_pins.py" ] || die "no read_swiftpm_pins.py in $JOB/pins (the launcher copies it)" 11

/usr/bin/python3 -I "$SCRIPT" "${PIN_ARGS[@]}" | tee "$RES/pin.txt"
WHEEL=$(sed -n 's/^GQMM_PIN .* wheel=\([0-9.]*\)$/\1/p' "$RES/pin.txt")
[ -n "$WHEEL" ] || die "no pinned MLX core: $(cat "$RES/pin.txt")" 11
/usr/bin/python3 -I "$SCRIPT" plan "${CASE_ARGS[@]}" | tee "$RES/plan.txt"
[ "${PIPESTATUS[0]}" = 0 ] || die "plan failed" 11

if [ "$("$VENV/bin/python" -I -c 'import importlib.metadata as m; print(m.version("mlx"))' 2>/dev/null)" != "$WHEEL" ]; then
  rm -rf "$VENV"
  PY312=$(command -v python3.12 || echo /opt/homebrew/bin/python3.12)
  [ -x "$PY312" ] || die "python3.12 not found (the mlx wheels need it)" 11
  "$PY312" -m venv "$VENV" && "$VENV/bin/pip" install -q "mlx==$WHEEL" > "$RES/venv.log" 2>&1 \
    || die "venv: $(tail -n 2 "$RES/venv.log" | tr '\n' ' ')" 11
fi
log "GQMM_VENV mlx $("$VENV/bin/python" -I -c 'import importlib.metadata as m; print(m.version("mlx"))')"

PYTHONDONTWRITEBYTECODE=1 "$VENV/bin/python" -I "$SCRIPT" run "${CASE_ARGS[@]}" --expect-mlx "$WHEEL" \
  --out-json "$RES/bitwise.json" > "$RES/bitwise.txt" 2> "$RES/bitwise.stderr"
rc=$?
cat "$RES/bitwise.txt"
case $rc in
  0) [ -s "$RES/bitwise.json" ] || die "no bitwise.json" 15 ;;
  1) die "the reference case is not deterministic across two runs (GQMM_DETERMINISM above): no verdict" 16 ;;
  *) die "bitwise run exit $rc: $(tail -n 3 "$RES/bitwise.stderr" "$RES/bitwise.txt" | tr '\n' ' ')" 15 ;;
esac
log "JOB_PASS"
