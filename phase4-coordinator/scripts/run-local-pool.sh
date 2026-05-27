#!/usr/bin/env bash
# Bootstrap a local Phase 4 pool with 2 mock providers behind one coordinator.
# Used by the AC-2/3/6 integration tests. Idempotent: cleans prior state first.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
export GOCACHE="${GOCACHE:-/private/tmp/macprovider-go-build-cache}"

# Ports/files. Keep ports above any production port the operator uses.
COORD_BUYER_PORT=18443
COORD_PROV_PORT=18444
MOCK_A_PORT=9001
MOCK_B_PORT=9002
COORD_CFG=/tmp/mp-local-coord.yaml
COORD_DB=/tmp/mp-local-coord.db
COORD_LOG=/tmp/mp-local-coord.log
COORD_PID=/tmp/mp-local-coord.pid
MOCK_A_LOG=/tmp/mp-local-mockA.log
MOCK_A_PID=/tmp/mp-local-mockA.pid
MOCK_B_LOG=/tmp/mp-local-mockB.log
MOCK_B_PID=/tmp/mp-local-mockB.pid

MODEL="${MODEL:-mlx-community/Qwen2.5-7B-Instruct-4bit}"

echo "[bootstrap] cleaning prior state"
for pidfile in "$COORD_PID" "$MOCK_A_PID" "$MOCK_B_PID"; do
  if [ -f "$pidfile" ]; then
    pid="$(cat "$pidfile" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
    rm -f "$pidfile"
  fi
done
# Belt-and-suspenders cleanup by name and port.
pkill -f "mockprovider --coord-url ws://127.0.0.1:${COORD_PROV_PORT}" 2>/dev/null || true
pkill -f "coordinator -config ${COORD_CFG}" 2>/dev/null || true
sleep 0.5
rm -f "$COORD_CFG" "$COORD_DB" "$COORD_LOG" "$MOCK_A_LOG" "$MOCK_B_LOG"

# Confirm binaries exist or build them.
if [ ! -x ./coordinator ]; then
  echo "[bootstrap] building coordinator"
  go build -o coordinator ./cmd/coordinator
fi
if [ ! -x ./mockprovider ]; then
  echo "[bootstrap] building mockprovider"
  go build -o mockprovider ./tools/mockprovider
fi

cat >"$COORD_CFG" <<YAML
listen:
  buyer_port: ${COORD_BUYER_PORT}
  provider_port: ${COORD_PROV_PORT}
  bind_address: "127.0.0.1"

pool:
  heartbeat_interval_s: 5
  disconnect_grace_period_s: 5
  wake_gap_threshold_s: 120
  degraded_backoff_s: 5
  degraded_max_retries: 2
  degraded_probe_after_502: false

routing:
  preflight_threshold_tokens: 4096
  preflight_timeout_s: 5
  request_timeout_s: 30

auth:
  operator_key: "local-test"

storage:
  db_path: "${COORD_DB}"
  snapshot_interval_s: 300

logging:
  level: "info"
  format: "json"

providers:
  - provider_id: "mock-A"
    endpoint_url: "http://127.0.0.1:${MOCK_A_PORT}"
    display_name: "mock-A (local)"
  - provider_id: "mock-B"
    endpoint_url: "http://127.0.0.1:${MOCK_B_PORT}"
    display_name: "mock-B (local)"
YAML

echo "[bootstrap] starting coordinator"
./coordinator -config "$COORD_CFG" >"$COORD_LOG" 2>&1 &
echo $! >"$COORD_PID"

# Wait for coordinator to bind both ports.
for _ in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:${COORD_BUYER_PORT}/v1/models" >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done

echo "[bootstrap] starting mock-A"
./mockprovider \
  --coord-url "ws://127.0.0.1:${COORD_PROV_PORT}/ws/provider" \
  --provider-id mock-A \
  --model "$MODEL" \
  --http-port ${MOCK_A_PORT} \
  --slots 2 \
  --max-concurrency 2 \
  >"$MOCK_A_LOG" 2>&1 &
echo $! >"$MOCK_A_PID"

echo "[bootstrap] starting mock-B"
./mockprovider \
  --coord-url "ws://127.0.0.1:${COORD_PROV_PORT}/ws/provider" \
  --provider-id mock-B \
  --model "$MODEL" \
  --http-port ${MOCK_B_PORT} \
  --slots 2 \
  --max-concurrency 2 \
  >"$MOCK_B_LOG" 2>&1 &
echo $! >"$MOCK_B_PID"

# Wait for /v1/models to advertise the model from BOTH providers.
echo "[bootstrap] waiting for pool to fill"
ready=0
for _ in $(seq 1 60); do
  body="$(curl -fsS "http://127.0.0.1:${COORD_BUYER_PORT}/v1/models" 2>/dev/null || true)"
  count="$(python3 -c "
import json,sys
try:
  data=json.loads(sys.argv[1])
  for m in data.get('data', []):
    if m['id'] == sys.argv[2]:
      print(m.get('provider_count', 0)); sys.exit()
  print(0)
except Exception:
  print(0)
" "$body" "$MODEL")"
  if [ "$count" = "2" ]; then
    ready=1
    break
  fi
  sleep 0.5
done

if [ "$ready" -ne 1 ]; then
  echo "[bootstrap] FAILED to see 2 ready providers in /v1/models"
  echo "  coord log: $COORD_LOG"
  echo "  mockA log: $MOCK_A_LOG"
  echo "  mockB log: $MOCK_B_LOG"
  exit 1
fi

echo "[bootstrap] pool ready"
echo "  coord pid=$(cat "$COORD_PID") log=$COORD_LOG"
echo "  mockA pid=$(cat "$MOCK_A_PID") log=$MOCK_A_LOG http=:${MOCK_A_PORT}"
echo "  mockB pid=$(cat "$MOCK_B_PID") log=$MOCK_B_LOG http=:${MOCK_B_PORT}"
echo "  buyer http=:${COORD_BUYER_PORT} model=${MODEL}"
exit 0
