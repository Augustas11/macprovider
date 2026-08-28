#!/usr/bin/env bash
# relaunch-m4.sh — restart M4's phase3-binary to recover from a stuck
# coordinator WebSocket reconnect (known v1.1.3/v1.1.4 quirk).
# Does NOT reinstall the binary — just kills the old process and
# restarts with the same arguments. ~30 seconds.
#
# Usage:
#   bash ~/Downloads/relaunch-m4.sh

set -uo pipefail

INSTALL_DIR="$HOME/phase3-binary-m4"
PIDFILE=/tmp/phase3-binary-m4.pid
LOGFILE=/tmp/phase3-binary-m4.log
PORT=8080
MODEL="mlx-community/Qwen2.5-7B-Instruct-4bit"
PROVIDER_ID="m4-anon"
COORDINATOR_URL="wss://coordinator.malibu.tech/ws/provider"

log() { printf "[relaunch] %s\n" "$*"; }

log "step 1/4: stopping current process"
if [ -f "$PIDFILE" ]; then
  OLD_PID=$(cat "$PIDFILE")
  if kill -0 "$OLD_PID" 2>/dev/null; then
    kill "$OLD_PID" 2>/dev/null || true
    log "  killed PID $OLD_PID"
    sleep 2
    kill -9 "$OLD_PID" 2>/dev/null && log "  force-killed straggler" || true
  fi
  rm -f "$PIDFILE"
fi
pkill -f "malibu-cli --port $PORT" 2>/dev/null || true
sleep 1

log "step 2/4: verifying install dir exists"
if [ ! -x "$INSTALL_DIR/malibu-cli" ]; then
  log "  FATAL: $INSTALL_DIR/malibu-cli not found"
  log "  This script only RELAUNCHES the existing install."
  log "  If the binary is missing, contact the operator for a fresh install."
  exit 1
fi

log "step 3/4: launching malibu-cli"
cd "$INSTALL_DIR"
nohup ./malibu-cli \
  --port "$PORT" \
  --model "$MODEL" \
  --provider-id "$PROVIDER_ID" \
  --coordinator "$COORDINATOR_URL" \
  > "$LOGFILE" 2>&1 &
NEW_PID=$!
echo "$NEW_PID" > "$PIDFILE"
disown "$NEW_PID" 2>/dev/null || true
log "  PID: $NEW_PID  (saved to $PIDFILE)"
log "  log: $LOGFILE"

log "step 4/4: waiting for local /v1/models (up to 60s)"
deadline=$(( $(date +%s) + 60 ))
while [ $(date +%s) -lt $deadline ]; do
  if ! kill -0 "$NEW_PID" 2>/dev/null; then
    log "  FATAL: PID $NEW_PID died"
    tail -20 "$LOGFILE" 2>/dev/null | sed 's/^/    /'
    exit 1
  fi
  if curl -sSf --max-time 3 "http://127.0.0.1:$PORT/v1/models" > /dev/null 2>&1; then
    log "  serving locally on port $PORT"
    break
  fi
  printf "."
  sleep 2
done
echo

log "done. operator will verify coord pool registration on their side."
log "  log:  tail -f $LOGFILE"
