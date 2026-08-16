#!/usr/bin/env bash
# install-m4-coordinator.sh — upgrade M4 phase3-binary to the v1.1.2 build
# that supports stable provider_id, AND wire it to the production coordinator
# at wss://coordinator.malibu.tech/ws/provider.
#
# Functionally equivalent to install-m4-notmux.sh except it adds:
#   --provider-id m4-anon
#   --coordinator wss://coordinator.malibu.tech/ws/provider
#
# Usage:
#   bash install-m4-coordinator.sh ~/Downloads/phase3-binary-m4-v1.1.2-providerid.tar.gz

set -uo pipefail

TARBALL=${1:-}
if [ -z "$TARBALL" ] || [ ! -f "$TARBALL" ]; then
  echo "usage: $0 <path/to/phase3-binary-m4-*.tar.gz>"
  echo "you passed: '$TARBALL'"
  exit 1
fi

INSTALL_DIR="$HOME/phase3-binary-m4"
MODEL="${MODEL:-mlx-community/Qwen2.5-7B-Instruct-4bit}"
PORT="${PORT:-8080}"
PROVIDER_ID="${PROVIDER_ID:-m4-anon}"
COORDINATOR_URL="${COORDINATOR_URL:-wss://coordinator.malibu.tech/ws/provider}"
TIMEOUT_S=120
PIDFILE=/tmp/phase3-binary-m4.pid
LOGFILE=/tmp/phase3-binary-m4.log

log() { printf "[install] %s\n" "$*"; }

log "step 1/7: stopping any process holding port $PORT"
LISTENERS=$(lsof -nP -iTCP:$PORT -sTCP:LISTEN -t 2>/dev/null || true)
if [ -n "$LISTENERS" ]; then
  log "  killing PIDs: $LISTENERS"
  for pid in $LISTENERS; do kill "$pid" 2>/dev/null || true; done
  sleep 2
  STILL=$(lsof -nP -iTCP:$PORT -sTCP:LISTEN -t 2>/dev/null || true)
  if [ -n "$STILL" ]; then
    log "  force-killing stragglers: $STILL"
    for pid in $STILL; do kill -9 "$pid" 2>/dev/null || true; done
    sleep 1
  fi
else
  log "  port $PORT was already free"
fi
pkill -f mlx_lm.server 2>/dev/null && log "  also killed mlx_lm.server processes" || true

log "step 2/7: installing phase3-binary to $INSTALL_DIR"
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
tar xzf "$TARBALL" -C "$INSTALL_DIR"

log "step 3/7: clearing macOS quarantine attributes"
xattr -dr com.apple.quarantine "$INSTALL_DIR" 2>/dev/null || true

log "step 4/7: launching binary with coordinator + stable provider_id"
log "  provider_id:     $PROVIDER_ID"
log "  coordinator_url: $COORDINATOR_URL"
cd "$INSTALL_DIR"
nohup ./macprovider-cli \
  --port "$PORT" \
  --model "$MODEL" \
  --provider-id "$PROVIDER_ID" \
  --coordinator "$COORDINATOR_URL" \
  > "$LOGFILE" 2>&1 &
BINARY_PID=$!
echo "$BINARY_PID" > "$PIDFILE"
log "  PID: $BINARY_PID  (saved to $PIDFILE)"
log "  log: $LOGFILE"
disown "$BINARY_PID" 2>/dev/null || true

log "step 5/7: waiting for binary to bind + load model (up to ${TIMEOUT_S}s)"
deadline=$(( $(date +%s) + TIMEOUT_S ))
ok=0
while [ $(date +%s) -lt $deadline ]; do
  if ! kill -0 "$BINARY_PID" 2>/dev/null; then
    log "  binary process $BINARY_PID died during startup"
    log "  last 30 lines of $LOGFILE:"
    tail -30 "$LOGFILE" 2>/dev/null | sed 's/^/    /'
    exit 1
  fi
  if curl -sSf --max-time 3 "http://127.0.0.1:$PORT/v1/models" > /dev/null 2>&1; then
    ok=1
    break
  fi
  printf "."
  sleep 3
done
echo

log "step 6/7: verifying it's phase3-binary (not mlx_lm.server)"
if [ $ok -ne 1 ]; then
  log "  TIMEOUT — nothing responded on port $PORT within ${TIMEOUT_S}s"
  log "  Last 30 lines of $LOGFILE:"
  tail -30 "$LOGFILE" 2>/dev/null | sed 's/^/    /'
  exit 1
fi

models_json=$(curl -sS "http://127.0.0.1:$PORT/v1/models")
if echo "$models_json" | grep -q '"owned_by"[[:space:]]*:[[:space:]]*"macprovider"'; then
  log "  VERIFIED phase3-binary is serving (owned_by: macprovider)"
else
  log "  WARNING: /v1/models responded but lacks owned_by:macprovider"
  echo "$models_json" | head -20
  exit 2
fi

log "step 7/7: verifying coordinator link via server-side aggregation"
# The phase3-binary acts on hello_ack silently (no stdout log line), so a
# local-log grep is unreliable. The right signal is server-side: if our
# model appears in the coordinator's aggregated /v1/models, the WebSocket
# link is provably alive — the coordinator only includes models from
# currently-connected providers in that list.
COORD_HOST=$(echo "$COORDINATOR_URL" | sed -E 's|^wss?://([^/]+)/.*|\1|')
COORD_MODELS_URL="https://$COORD_HOST/v1/models"
deadline=$(( $(date +%s) + 30 ))
linked=0
while [ $(date +%s) -lt $deadline ]; do
  coord_models=$(curl -sS --max-time 5 "$COORD_MODELS_URL" 2>/dev/null || true)
  if echo "$coord_models" | grep -q "\"$MODEL\""; then
    linked=1
    break
  fi
  sleep 2
  printf "."
done
echo

if [ $linked -eq 1 ]; then
  log "  COORDINATOR LINK ESTABLISHED"
  log "  $COORD_MODELS_URL shows our model:"
  echo "$coord_models" | python3 -m json.tool 2>/dev/null | head -15 | sed 's/^/    /'
  echo
  log "Done. m4.malibu.tech serves phase3-binary, and the same binary now"
  log "registers with the production coordinator as provider_id=$PROVIDER_ID."
  log "  binary PID: $BINARY_PID  (kept in $PIDFILE)"
  log "  view logs:  tail -f $LOGFILE"
else
  log "  WARNING: coordinator link not confirmed within 30s"
  log "  Binary is serving buyer traffic correctly (step 6 passed),"
  log "  but our model_id did not appear in $COORD_MODELS_URL."
  log "  Possible causes: WS dial failed (firewall/TLS), provider_id"
  log "  '$PROVIDER_ID' not enumerated in coordinator config, or first"
  log "  heartbeat hasn't landed yet."
  log "  Check binary log: tail -50 $LOGFILE"
  log "  Operator can check coordinator side via:"
  log "    curl -H 'Authorization: Bearer \$OP_KEY' https://$COORD_HOST/poolz"
  exit 3
fi
