#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

PORT="${MACPROVIDER_PORT:-18091}"
LOG_FILE="/private/tmp/macprovider-adversarial-$PORT.log"

if [[ "${MACPROVIDER_SKIP_START:-0}" != "1" ]]; then
  trap stop_provider EXIT
  start_provider "$PORT" "" "$LOG_FILE"
  wait_http "$PORT" /v1/health
fi

CONFIG="$(write_harness_config "$PORT" adversarial)"
OUTPUT_FILE="$(mktemp /private/tmp/macprovider-adversarial-output.XXXXXX)"
set +e
run_harness "$CONFIG" --batch adversarial --verbose 2>&1 | tee "$OUTPUT_FILE"
HARNESS_STATUS="${PIPESTATUS[0]}"
set -e

if grep -q "HTTP500" "$OUTPUT_FILE"; then
  echo "adversarial harness observed HTTP500, which is disallowed" >&2
  exit 1
fi

if [[ "$HARNESS_STATUS" -ne 0 ]]; then
  if grep -q "long_context_oom_probe: n=1 ok=0 err=1 .*HTTP413" "$OUTPUT_FILE" &&
     grep -q "harness: done, 1 failure(s)" "$OUTPUT_FILE"; then
    echo "accepted long_context_oom_probe HTTP413 protective rejection"
  else
    exit "$HARNESS_STATUS"
  fi
fi

if ! wait_http "$PORT" /v1/health 30; then
  echo "provider did not return healthy /v1/health within 30 seconds" >&2
  exit 1
fi

echo "adversarial harness verified: no HTTP500 and provider health recovered"
