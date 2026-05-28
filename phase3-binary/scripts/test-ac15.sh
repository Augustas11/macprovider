#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

HTTP_PORT="${MACPROVIDER_TEST_PORT:-18115}"
COORD_PORT="${MACPROVIDER_MOCK_COORD_PORT:-19115}"
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

build_binary
python3 "$PHASE3_DIR/tools/mock-coordinator/mock_coordinator.py" --scenario nak --port "$COORD_PORT" --model "$MODEL" &
MOCK_PID="$!"
sleep 1
provider_env "$BINARY" --port "$HTTP_PORT" --model "$MODEL" --coordinator "ws://127.0.0.1:$COORD_PORT/ws/provider" --endpoint-url "https://example.invalid" >"/private/tmp/macprovider-ac15.log" 2>&1 &
PROVIDER_PID="$!"
wait "$MOCK_PID"
MOCK_PID=""
echo "AC-15 PASS"
