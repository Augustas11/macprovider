#!/usr/bin/env bash
# One complete #1690 e2e matrix pass (run it twice: full_run.sh r1, r2).
#   1. every engine (native, llamacpp, mlxlm, ollama) x gateway pin off/on
#      (run_matrix.sh, enforce coordinator)
#   2. fault cases on the llama.cpp member (faults.sh: proxy, rotate, kill)
#   3. observe mode: coordinator verified_model_settlement_mode=observe;
#      llama.cpp on enforce pool A (must refuse), native on the global route,
#      on NO (native-only observe pool), and on pool A; pin off/on
# Mixed-version pairings run separately (mix_setup.sh + run_matrix.sh).
set -euo pipefail
export LAB="${LAB:-/Users/a1/lab-1690-m6/e2e}"
HERE="$(cd "$(dirname "$0")" && pwd)"
RIG="$HERE/../1690-m6/rig.sh"
. "$HERE/env.sh"
export E2E_PENDING_DEADLINE_S="${E2E_PENDING_DEADLINE_S:-90}" E2E_REOFFER=1
RUN=$1
STEPS="${E2E_STEPS:-engines faults observe}"
lsof -nP -iTCP:8080 -sTCP:LISTEN | tail -1 | sed 's/^/live provider :8080 before: /'
for step in $STEPS; do
  case "$step" in
    engines)
      for e in ${E2E_ENGINES:-native llamacpp mlxlm ollama}; do "$HERE/run_matrix.sh" "$RUN" "$e" "0 1" || echo "run_matrix $e exited $?"; done ;;
    faults)
      "$RIG" down >/dev/null 2>&1 || true
      ENGINE=llamacpp "$RIG" up >/dev/null
      sleep 15
      "$HERE/faults.sh" "$RUN" proxy rotate kill || echo "faults exited $?" ;;
    observe)
      # A v2 core with a runtime_allowlist must be enforce
      # (poolmanifest/manifest.go), so external engines have no observe pool:
      # with the coordinator in observe, llama.cpp on the enforce pool A must
      # refuse; native runs on the global route and on NO, a native-only
      # observe pool.
      export E2E_SETTLEMENT_MODE=observe
      "$RIG" down >/dev/null 2>&1 || true
      ENGINE=llamacpp "$RIG" up >/dev/null || echo "observe llamacpp up exited $?"
      [[ -f "$LAB/pools/NO/pool_id" ]] || { rm -rf "$LAB/pools/NO"; python3 "$HERE/../1690-m6/pool_setup.py" create NO --encoding 2 --settlement-mode observe >/dev/null || echo "pool NO create failed"; }
      sleep 15
      E2E_KEEP_RIG=1 E2E_SKIP_SELECTION=1 E2E_BEHAVIOURS=normal E2E_SHAPES=plain,tool "$HERE/run_matrix.sh" "$RUN-observe" llamacpp "0 1" || true
      E2E_SKIP_SELECTION=1 E2E_POOL=NO "$HERE/run_matrix.sh" "$RUN-observe" native "0 1" || true
      E2E_KEEP_RIG=1 E2E_SKIP_SELECTION=1 E2E_POOL=A E2E_BEHAVIOURS=normal E2E_SHAPES=plain "$HERE/run_matrix.sh" "$RUN-observe-poolA" native "0 1" || true
      unset E2E_SETTLEMENT_MODE
      "$RIG" down >/dev/null 2>&1 || true ;;
  esac
done
"$RIG" down >/dev/null 2>&1 || true
lsof -nP -iTCP:8080 -sTCP:LISTEN | tail -1 | sed 's/^/live provider :8080 after: /'
echo "=== full run $RUN done $(date -u +%FT%TZ)"
