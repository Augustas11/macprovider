#!/usr/bin/env bash
# rollback-m4-notmux.sh — revert to mlx_lm.server without using tmux.
# Companion to install-m4-notmux.sh.
#
# Usage:
#   bash rollback-m4-notmux.sh

set -uo pipefail

MODEL="${MODEL:-mlx-community/Qwen2.5-7B-Instruct-4bit}"
PORT="${PORT:-8080}"
TIMEOUT_S=60
PIDFILE=/tmp/phase3-binary-m4.pid
LOGFILE_BINARY=/tmp/phase3-binary-m4.log
LOGFILE_MLX=/tmp/mlx_lm.server.log

log() { printf "[rollback] %s\n" "$*"; }

log "step 1/4: stopping phase3-binary"
if [ -f "$PIDFILE" ]; then
  BINARY_PID=$(cat "$PIDFILE")
  if kill -0 "$BINARY_PID" 2>/dev/null; then
    kill "$BINARY_PID"
    log "  killed phase3-binary PID $BINARY_PID"
    sleep 2
    kill -9 "$BINARY_PID" 2>/dev/null && log "  force-killed straggler" || true
  else
    log "  PID $BINARY_PID no longer alive"
  fi
  rm -f "$PIDFILE"
else
  log "  no PID file at $PIDFILE; falling back to pkill"
fi
pkill -f "malibu-cli --port $PORT" 2>/dev/null && log "  killed lingering malibu-cli" || true

# Confirm port is free
sleep 1
LISTENERS=$(lsof -nP -iTCP:$PORT -sTCP:LISTEN -t 2>/dev/null || true)
if [ -n "$LISTENERS" ]; then
  log "  WARN: port $PORT still held by PIDs: $LISTENERS"
  for pid in $LISTENERS; do kill -9 "$pid" 2>/dev/null || true; done
fi

log "step 2/4: starting mlx_lm.server via nohup on port $PORT"
nohup bash -c "source ~/macprovider/bin/activate && mlx_lm.server --model '$MODEL' --port $PORT" \
      > "$LOGFILE_MLX" 2>&1 &
MLX_PID=$!
disown "$MLX_PID" 2>/dev/null || true
log "  PID: $MLX_PID"
log "  log: $LOGFILE_MLX"

log "step 3/4: waiting for mlx_lm.server to bind + load model (up to ${TIMEOUT_S}s)"
deadline=$(( $(date +%s) + TIMEOUT_S ))
ok=0
while [ $(date +%s) -lt $deadline ]; do
  if ! kill -0 "$MLX_PID" 2>/dev/null; then
    log "  mlx_lm.server process $MLX_PID died during startup"
    log "  last 30 lines of $LOGFILE_MLX:"
    tail -30 "$LOGFILE_MLX" 2>/dev/null | sed 's/^/    /'
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

log "step 4/4: verification"
if [ $ok -eq 1 ]; then
  curl -sS "http://127.0.0.1:$PORT/v1/models" | python3 -m json.tool 2>&1 || true
  echo
  log "ROLLBACK COMPLETE — mlx_lm.server restored."
  log "  PID: $MLX_PID"
  log "  log: $LOGFILE_MLX"
  log "  phase3-binary install at ~/phase3-binary-m4 is preserved."
  exit 0
else
  log "TIMEOUT — mlx_lm.server did not respond within ${TIMEOUT_S}s"
  log "Check log: tail -50 $LOGFILE_MLX"
  log "Check venv: source ~/macprovider/bin/activate && which mlx_lm.server"
  exit 1
fi
