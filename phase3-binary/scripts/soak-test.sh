#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

PORT="${MACPROVIDER_PORT:-18096}"
SOAK_SECONDS="${SOAK_SECONDS:-86400}"
SAMPLE_SECONDS="${SOAK_SAMPLE_SECONDS:-60}"
LOG_FILE="/private/tmp/macprovider-soak-$PORT.log"

trap stop_provider EXIT
start_provider "$PORT" "" "$LOG_FILE"
wait_http "$PORT" /v1/health
CONFIG="$(write_harness_config "$PORT" soak)"

baseline_rss="$(ps -o rss= -p "$PROVIDER_PID" | tr -d ' ')"
start_epoch="$(date +%s)"
next_sample="$start_epoch"
max_rss="$baseline_rss"

while (( "$(date +%s)" - start_epoch < SOAK_SECONDS )); do
  run_harness "$CONFIG" --once short_chat --verbose
  now="$(date +%s)"
  if (( now >= next_sample )); then
    rss="$(ps -o rss= -p "$PROVIDER_PID" | tr -d ' ')"
    if [[ -n "$rss" && "$rss" -gt "$max_rss" ]]; then
      max_rss="$rss"
    fi
    next_sample=$((now + SAMPLE_SECONDS))
  fi
  sleep 5
done

allowed=$((baseline_rss + baseline_rss / 20))
if (( max_rss > allowed )); then
  echo "RSS growth exceeded 5%: baseline=$baseline_rss max=$max_rss" >&2
  exit 1
fi
echo "soak passed: baseline_rss_kb=$baseline_rss max_rss_kb=$max_rss seconds=$SOAK_SECONDS"
