#!/usr/bin/env bash
# M4 partner-side ROLLBACK: stop phase3-binary and restore mlx_lm.server.
#
# Run on the M4 user's Mac, any time, if the binary is misbehaving.
# Cloudflare tunnel stays up across this swap; buyers see brief 502/503
# during the ~30s window.

set -uo pipefail

MODEL="${MODEL:-mlx-community/Qwen2.5-7B-Instruct-4bit}"
PORT="${PORT:-8080}"
TIMEOUT_S=60

log() { printf "[rollback] %s\n" "$*"; }

# Locate tmux explicitly (admin shells may lack /opt/homebrew/bin on PATH)
TMUX_BIN=$(command -v tmux || true)
if [ -z "$TMUX_BIN" ]; then
  for candidate in /opt/homebrew/bin/tmux /usr/local/bin/tmux; do
    if [ -x "$candidate" ]; then TMUX_BIN=$candidate; break; fi
  done
fi
if [ -z "$TMUX_BIN" ]; then
  log "FATAL: tmux not found on PATH or in /opt/homebrew/bin or /usr/local/bin"
  log "  Falling back to direct kill of phase3-binary + nohup launch of mlx_lm.server"
  TMUX_BIN=""
fi

log "step 1/4: stopping phase3-binary"
if [ -n "$TMUX_BIN" ] && "$TMUX_BIN" has-session -t mlx 2>/dev/null; then
  "$TMUX_BIN" kill-session -t mlx
  log "  killed tmux session 'mlx'"
else
  pkill -f "macprovider-cli --port $PORT" 2>/dev/null && log "  killed macprovider-cli directly" || log "  no macprovider-cli running"
fi

log "step 2/4: starting mlx_lm.server on port $PORT"
if [ -n "$TMUX_BIN" ]; then
  "$TMUX_BIN" new-session -d -s mlx \
      "source ~/macprovider/bin/activate && mlx_lm.server --model '$MODEL' --port $PORT 2>&1 | tee /tmp/mlx_lm.server.log"
else
  log "  fallback: launching with nohup (no tmux)"
  nohup bash -c "source ~/macprovider/bin/activate && mlx_lm.server --model '$MODEL' --port $PORT" \
        > /tmp/mlx_lm.server.log 2>&1 &
  log "  PID: $!"
fi

log "step 3/4: waiting for mlx_lm.server to bind + load model (up to ${TIMEOUT_S}s)"
deadline=$(( $(date +%s) + TIMEOUT_S ))
ok=0
while [ $(date +%s) -lt $deadline ]; do
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
  log "phase3-binary install at ~/phase3-binary-m4 is preserved (delete manually if you want)."
  exit 0
else
  log "TIMEOUT — mlx_lm.server did not respond within ${TIMEOUT_S}s"
  if [ -n "$TMUX_BIN" ]; then
    log "Check: $TMUX_BIN attach -t mlx"
  fi
  log "Or check venv: source ~/macprovider/bin/activate && which mlx_lm.server"
  log "Or check log: tail -50 /tmp/mlx_lm.server.log"
  exit 1
fi
