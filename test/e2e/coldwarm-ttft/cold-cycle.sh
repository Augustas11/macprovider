#!/usr/bin/env bash
# Drive ONE cold cycle against a LAB provider and capture the first-after-cold
# TTFT sample. This is the operator-run piece: it induces cold out of band, then
# invokes the probe with the appropriate --state.
#
# SAFETY (hard-won 2026-07-09 lesson — an hour-long prod outage):
#   - Run this ONLY against a LAB provider you own. NEVER the prod `mac` provider.
#   - Do NOT stack coordinator restarts (wedges the CLI v2 proof-auth, issue #519).
#     This script restarts the PROVIDER CLI at most once per cycle; it never
#     touches the coordinator.
#
# Cold-induction levers (least invasive first), selected by --lever:
#   idle    wait past the provider's model-unload threshold (no restart at all)
#   restart restart just the provider CLI process (a full cold model load)
#   reboot  you reboot the provider host yourself, then run with --state post_reboot
#
# Usage:
#   LAB_MODEL=qwen3-coder-30b-a3b-instruct \
#   COLDWARM_BASE=https://<lab-gateway> \
#   ./cold-cycle.sh --lever idle --idle-min 12 --state cold
#
#   # provider-CLI restart lever (you supply the restart command):
#   PROVIDER_RESTART_CMD='ssh lab-mac launchctl kickstart -k gui/501/tech.malibu.provider' \
#   ./cold-cycle.sh --lever restart --state post_reboot
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LEVER="idle"
STATE="cold"
IDLE_MIN="12"          # default idle wait; size to exceed the model-unload threshold
REGIME=""              # empty → probe balances regimes across cycles
MODEL="${LAB_MODEL:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --lever) LEVER="$2"; shift 2;;
    --state) STATE="$2"; shift 2;;
    --idle-min) IDLE_MIN="$2"; shift 2;;
    --regime) REGIME="$2"; shift 2;;
    --model) MODEL="$2"; shift 2;;
    *) echo "cold-cycle: unknown arg $1" >&2; exit 2;;
  esac
done

# Guardrail: refuse to run against the production coordinator unless the operator
# explicitly overrides. Cold-cycling churns the provider; prod is off-limits.
: "${COLDWARM_BASE:=}"
if [[ "$COLDWARM_BASE" == *"api.malibu.tech"* || "$COLDWARM_BASE" == *"coordinator.malibu.tech"* ]]; then
  if [[ "${COLD_CYCLE_ALLOW_PROD:-}" != "1" ]]; then
    echo "cold-cycle: REFUSING to cold-cycle against prod ($COLDWARM_BASE)." >&2
    echo "            Cold-cycling churns the provider and caused an hour-long outage on 2026-07-09." >&2
    echo "            Point COLDWARM_BASE at a LAB gateway. (COLD_CYCLE_ALLOW_PROD=1 overrides — do not.)" >&2
    exit 3
  fi
  echo "cold-cycle: WARNING — running against prod because COLD_CYCLE_ALLOW_PROD=1. This is dangerous." >&2
fi

echo "cold-cycle: lever=$LEVER state=$STATE model=${MODEL:-<auto>} base=${COLDWARM_BASE:-<default>}" >&2

case "$LEVER" in
  idle)
    echo "cold-cycle: idling ${IDLE_MIN} min to let the provider unload the model..." >&2
    sleep "$(( IDLE_MIN * 60 ))"
    ;;
  restart)
    if [[ -z "${PROVIDER_RESTART_CMD:-}" ]]; then
      echo "cold-cycle: --lever restart needs \$PROVIDER_RESTART_CMD (the provider-CLI restart command)." >&2
      exit 2
    fi
    echo "cold-cycle: restarting the provider CLI (single restart; coordinator untouched)..." >&2
    eval "$PROVIDER_RESTART_CMD"
    # Give the provider a moment to reconnect to the coordinator before probing.
    sleep "${PROVIDER_RECONNECT_WAIT_S:-20}"
    ;;
  reboot)
    echo "cold-cycle: --lever reboot assumes YOU already rebooted the provider host." >&2
    echo "            Run with --state post_reboot once it has reconnected." >&2
    ;;
  *)
    echo "cold-cycle: unknown --lever $LEVER (idle|restart|reboot)" >&2
    exit 2
    ;;
esac

ARGS=(--scenario cold --state "$STATE")
[[ -n "$MODEL" ]] && ARGS+=(--model "$MODEL")
[[ -n "$REGIME" ]] && ARGS+=(--regime "$REGIME")

echo "cold-cycle: capturing first-after-cold sample..." >&2
exec "$HERE/run-coldwarm.sh" "${ARGS[@]}"
