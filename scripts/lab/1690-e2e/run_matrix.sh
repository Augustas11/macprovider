#!/usr/bin/env bash
# #1690 e2e matrix for one engine: (re)start the rig on ENGINE, then for each
# gateway pin setting send the request-shape x buyer-behaviour matrix on the
# engine's Trusted Pool route and the global route, the engine-selection
# matrix, and settle every request against the invariants (matrix.py).
#
#   run_matrix.sh RUN ENGINE [PINS]      e.g. run_matrix.sh r1 llamacpp "0 1"
#
# ENGINE: native (pool A + global), llamacpp (pool A), mlxlm (pool M),
# ollama (pool O). External engines are also sent to the global route (with
# and without selecting them), which must refuse them before dispatch and
# never credit them. Output: LAB/e2e/results/<label>.json and
# LAB/e2e/logs/<RUN>-<ENGINE>.log. Lab only (rig.sh/pidguard safety).
set -euo pipefail
export LAB="${LAB:-/Users/a1/lab-1690-m6/e2e}"
HERE="$(cd "$(dirname "$0")" && pwd)"
RIG="$HERE/../1690-m6/rig.sh"
# shellcheck source=env.sh
. "$HERE/env.sh"
export E2E_PENDING_DEADLINE_S="${E2E_PENDING_DEADLINE_S:-90}"
export E2E_REOFFER=1 E2E_NATIVE_CLEAR_ADMISSION=1
RUN=$1 ENGINE=$2 PINS=${3:-"0 1"}
case "$ENGINE" in native|llamacpp) POOL=A ;; mlxlm) POOL=M ;; ollama) POOL=O ;; *) echo "bad engine" >&2; exit 2 ;; esac
POOL="${E2E_POOL:-$POOL}"
M() { python3 "$HERE/matrix.py" "$@"; }
mkdir -p "$LAB/e2e/logs"
OUT="$LAB/e2e/logs/$RUN-$ENGINE.log"
exec > >(tee -a "$OUT") 2>&1
echo "=== $(date -u +%FT%TZ) run=$RUN engine=$ENGINE pins=[$PINS] HEAD=$(git -C "$HERE" rev-parse --short HEAD)"
first_pin=${PINS%% *}
if [[ "${E2E_KEEP_RIG:-0}" != 1 ]]; then
  "$RIG" down >/dev/null 2>&1 || true
  ENGINE=$ENGINE E2E_GATEWAY_PIN=$first_pin "$RIG" up
  sleep "${E2E_SETTLE_JOIN_S:-15}"
fi
for pin in $PINS; do
  E2E_GATEWAY_PIN=$pin "$RIG" configs
  "$RIG" gateway-restart
  label="$RUN-$ENGINE-pin$pin"
  glines=$(wc -l <"$LAB/logs/gateway.log")
  echo "--- $label"
  # E2E_SHAPES / E2E_BEHAVIOURS narrow the matrix (mixed-version subset).
  SUB=()
  [[ -n "${E2E_SHAPES:-}" ]] && SUB+=(--shapes "$E2E_SHAPES")
  [[ -n "${E2E_BEHAVIOURS:-}" ]] && SUB+=(--behaviours "$E2E_BEHAVIOURS")
  if [[ "${E2E_SKIP_POOL:-0}" != 1 ]]; then
  M send --label "$label" --engine "$ENGINE" --route "pool:$POOL" ${SUB[@]+"${SUB[@]}"}
  sel=$ENGINE
  M send --label "$label" --engine "$ENGINE" --route "pool:$POOL" --select "$sel" --behaviours normal --shapes plain,tool
  fi
  if [[ "$ENGINE" == native ]]; then
    M send --label "$label" --engine native --route global ${SUB[@]+"${SUB[@]}"}
    M send --label "$label" --engine native --route global --select native --behaviours normal --shapes plain
  else
    M send --label "$label" --engine "$ENGINE" --route global --behaviours normal --shapes plain
    M send --label "$label" --engine "$ENGINE" --route global --select "$sel" --behaviours normal --shapes plain
  fi
  if [[ "${E2E_SKIP_SELECTION:-0}" != 1 ]]; then M selection --label "$label-sel" --engine "$ENGINE" || true; fi
  M settle --label "$label" || true
  if [[ "${E2E_SKIP_SELECTION:-0}" != 1 ]]; then M settle --label "$label-sel" --timeout 120 || true; fi
  held=$(tail -n +"$((glines + 1))" "$LAB/logs/gateway.log" | grep -c "coordinator finality missing or not authenticated" || true)
  pend=$(tail -n +"$((glines + 1))" "$LAB/logs/gateway.log" | grep "settlement hold" | grep -o "request_id=[0-9a-f-]*" | sort -u | wc -l | tr -d ' ')
  echo "HOLDS [$label] missing_settlement_finality_trailer=$held requests_with_any_settlement_hold_log=$pend"
done
echo "=== done $(date -u +%FT%TZ)"
