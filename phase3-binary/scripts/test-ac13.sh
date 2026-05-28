#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

HTTP_PORT="${MACPROVIDER_TEST_PORT:-18113}"
COORD_PORT="${MACPROVIDER_MOCK_COORD_PORT:-19113}"
MOCK_PID=""

cleanup() {
  stop_provider
  if [[ -n "$MOCK_PID" ]] && kill -0 "$MOCK_PID" 2>/dev/null; then
    kill "$MOCK_PID" 2>/dev/null || true
    wait "$MOCK_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

python3 -c 'import websockets' >/dev/null 2>&1 || { echo "SKIP: Python package websockets is required" >&2; exit 77; }

python3 "$PHASE3_DIR/tools/mock-coordinator/mock_coordinator.py" --scenario cancel --port "$COORD_PORT" --model "$MODEL" &
MOCK_PID="$!"
sleep 1
start_provider "$HTTP_PORT" "ws://127.0.0.1:$COORD_PORT/ws/provider" "/private/tmp/macprovider-ac13.log"
wait "$MOCK_PID"
MOCK_PID=""
echo "AC-13 PASS"
