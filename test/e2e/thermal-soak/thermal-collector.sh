#!/usr/bin/env bash
# thermal-collector.sh — provider-side thermal sampler for the RESEARCH_235
# thermal/sustained-load soak (scenario 15, issue #584).
#
# Runs ON THE LAB PROVIDER MAC (not the coordinator, not prod) for the full
# soak window. Samples on-device thermal state and writes a timestamped
# NDJSON log that the analysis joins to the harness `per_request.jsonl` by
# UTC timestamp, so a streaming-TPS decay curve (B10) can be overlaid on the
# thermal-pressure / clock-speed signal to answer #584's open question:
# is the sustained-load collapse thermal throttling, memory pressure, or
# something else?
#
# ############################################################################
# ## LAB MAC ONLY. This deliberately pushes a machine toward thermal        ##
# ## throttle and runs `powermetrics`/`pmset`. Run it only on a Mac you     ##
# ## fully control that is serving as the SOLE lab pool member. Never on the ##
# ## single prod provider — a soak degrades and disconnects it (that IS     ##
# ## #584). See scenario 15 header and test/e2e/thermal-soak/README.md.     ##
# ############################################################################
#
# Two sample sources, each emitted as its own NDJSON record:
#   - powermetrics --samplers smc,cpu_power,gpu_power : SMC temps, CPU/GPU
#     power (W), package/GPU/CPU frequency residencies. Needs sudo.
#   - pmset -g therm : thermal pressure + CPU speed-limit % (the OS's own
#     "I am throttling" signal). No sudo needed on most macOS builds.
#
# Each line is one JSON object with a top-level "ts" (UTC RFC3339, ms) and a
# "source" tag ("powermetrics" | "pmset"), plus the parsed fields. The raw
# tool text is preserved under "raw" so nothing is lost if parsing drifts
# across macOS versions.
#
# Run this UNPRIVILEGED — do NOT `sudo` the whole script. It escalates only the
# single `powermetrics` call internally (via `sudo powermetrics`), so `pmset`,
# `mkdir`, and the log writes stay as your user. For an unattended run, grant
# passwordless powermetrics once (e.g. a sudoers line:
# `<you> ALL=(root) NOPASSWD: /usr/bin/powermetrics`) so the loop doesn't stall
# on a password prompt.
#
# Usage:
#   ./thermal-collector.sh --out ./thermal-<runid>.ndjson --interval 5
#   ./thermal-collector.sh --out ./thermal.ndjson --duration 3600
#   # Start this JUST BEFORE launching the harness soak; stop with the soak
#   # (Ctrl-C, SIGTERM, or --duration). Then join (from this directory):
#   #   ./join-thermal.py /path/to/per_request.jsonl ./thermal.ndjson > overlay.ndjson
#
# Env overrides: THERMAL_INTERVAL_S (default 5), THERMAL_DURATION_S (0 = until
# signalled), THERMAL_OUT.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${THERMAL_INTERVAL_S:=5}"
: "${THERMAL_DURATION_S:=0}"
: "${THERMAL_OUT:=}"

usage() {
  sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)       THERMAL_OUT="$2"; shift 2 ;;
    --interval)  THERMAL_INTERVAL_S="$2"; shift 2 ;;
    --duration)  THERMAL_DURATION_S="$2"; shift 2 ;;
    -h|--help)   usage 0 ;;
    *) echo "thermal-collector: unknown arg: $1" >&2; usage 2 ;;
  esac
done

if [[ -z "$THERMAL_OUT" ]]; then
  echo "thermal-collector: --out <path.ndjson> is required" >&2
  exit 2
fi

# Strictly validate the numeric inputs BEFORE they are ever used in Bash
# arithmetic ($((...))). Unvalidated arithmetic operands can smuggle command
# substitution via array subscripts, so accept only plain base-10 digits with
# sane bounds. (interval: 1..3600s, duration: 0..604800s / 7 days.)
if ! [[ "$THERMAL_INTERVAL_S" =~ ^[1-9][0-9]{0,3}$ ]] || (( THERMAL_INTERVAL_S > 3600 )); then
  echo "thermal-collector: --interval must be an integer 1..3600 (got '$THERMAL_INTERVAL_S')" >&2
  exit 2
fi
if ! [[ "$THERMAL_DURATION_S" =~ ^(0|[1-9][0-9]{0,6})$ ]] || (( THERMAL_DURATION_S > 604800 )); then
  echo "thermal-collector: --duration must be an integer 0..604800 (got '$THERMAL_DURATION_S')" >&2
  exit 2
fi

# Restrict permissions on any file we create — the thermal log preserves raw
# device output and should not be world-readable by default.
umask 077

case "$(uname -s)" in
  Darwin) : ;;
  *) echo "thermal-collector: macOS only (uname=$(uname -s)) — run on the lab Mac" >&2; exit 1 ;;
esac

mkdir -p "$(dirname "$THERMAL_OUT")"

# ts_now: UTC RFC3339 with millis. `date` on macOS lacks %N, so use a portable
# fallback (whole-second precision is enough to join against per_request.jsonl,
# whose records span seconds).
ts_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# json_str: minimal JSON string escaper for the "raw" field (escapes backslash,
# double-quote, and control chars → spaces).
json_str() {
  python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
}

emit_pmset() {
  local ts raw speed_limit
  ts="$(ts_now)"
  raw="$(pmset -g therm 2>/dev/null || true)"
  # "CPU_Speed_Limit = 100" → 100 means no throttle; < 100 means throttling.
  speed_limit="$(printf '%s\n' "$raw" | awk -F'= ' '/CPU_Speed_Limit/{gsub(/[^0-9]/,"",$2); print $2; exit}')"
  [[ -z "$speed_limit" ]] && speed_limit="null"
  printf '{"ts":"%s","source":"pmset","cpu_speed_limit_pct":%s,"raw":%s}\n' \
    "$ts" "$speed_limit" "$(printf '%s' "$raw" | json_str)" >> "$THERMAL_OUT"
}

emit_powermetrics() {
  local ts raw cpu_w gpu_w die_temp
  ts="$(ts_now)"
  # Single-shot sample (-n 1). -i is the sample window in ms.
  raw="$(sudo powermetrics --samplers smc,cpu_power,gpu_power -n 1 -i "$((THERMAL_INTERVAL_S*1000))" 2>/dev/null || true)"
  if [[ -z "$raw" ]]; then
    printf '{"ts":"%s","source":"powermetrics","error":"no sample (needs sudo / unsupported on this Mac)"}\n' "$ts" >> "$THERMAL_OUT"
    return
  fi
  cpu_w="$(printf '%s\n' "$raw"  | awk -F': ' '/CPU Power/{gsub(/[^0-9.]/,"",$2); print $2; exit}')"
  gpu_w="$(printf '%s\n' "$raw"  | awk -F': ' '/GPU Power/{gsub(/[^0-9.]/,"",$2); print $2; exit}')"
  die_temp="$(printf '%s\n' "$raw" | awk -F': ' '/die temperature|CPU die temperature/{gsub(/[^0-9.]/,"",$2); print $2; exit}')"
  [[ -z "$cpu_w" ]] && cpu_w="null"
  [[ -z "$gpu_w" ]] && gpu_w="null"
  [[ -z "$die_temp" ]] && die_temp="null"
  printf '{"ts":"%s","source":"powermetrics","cpu_power_mw":%s,"gpu_power_mw":%s,"cpu_die_temp_c":%s,"raw":%s}\n' \
    "$ts" "$cpu_w" "$gpu_w" "$die_temp" "$(printf '%s' "$raw" | json_str)" >> "$THERMAL_OUT"
}

echo "thermal-collector: sampling every ${THERMAL_INTERVAL_S}s → $THERMAL_OUT (duration=${THERMAL_DURATION_S}s, 0=until signalled)" >&2

start_epoch="$(date -u +%s)"
trap 'echo "thermal-collector: stopping" >&2; exit 0' INT TERM

while :; do
  emit_pmset
  emit_powermetrics   # this call itself consumes ~THERMAL_INTERVAL_S (its -i window)
  if [[ "$THERMAL_DURATION_S" != "0" ]]; then
    now_epoch="$(date -u +%s)"
    if (( now_epoch - start_epoch >= THERMAL_DURATION_S )); then
      echo "thermal-collector: duration reached, exiting" >&2
      break
    fi
  fi
done
