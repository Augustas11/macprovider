#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

PORT="${MACPROVIDER_PORT:-18090}"
LOG_FILE="/private/tmp/macprovider-cooperative-$PORT.log"

if [[ "${MACPROVIDER_SKIP_START:-0}" != "1" ]]; then
  trap stop_provider EXIT
  start_provider "$PORT" "" "$LOG_FILE"
  wait_http "$PORT" /v1/health
fi

CONFIG="$(write_harness_config "$PORT" cooperative)"
run_harness "$CONFIG" --batch cooperative --verbose
