#!/usr/bin/env bash
# M4 partner-side: install + start the phase3-binary tarball, swap from
# mlx_lm.server. The cloudflared service is untouched.
#
# Run on the M4 user's Mac.
#
# Usage:
#   ./install-m4.sh /path/to/phase3-binary-m4-<TAG>.tar.gz
#
# To revert, run rollback-m4.sh.

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
TIMEOUT_S=120  # 7B model can take 60-90s to load

log() { printf "[install] %s\n" "$*"; }

# Locate tmux explicitly — macOS admin shells often lack /opt/homebrew/bin on PATH
TMUX_BIN=$(command -v tmux || true)
if [ -z "$TMUX_BIN" ]; then
  for candidate in /opt/homebrew/bin/tmux /usr/local/bin/tmux; do
    if [ -x "$candidate" ]; then TMUX_BIN=$candidate; break; fi
  done
fi
if [ -z "$TMUX_BIN" ]; then
  log "FATAL: tmux not found on PATH or in /opt/homebrew/bin or /usr/local/bin"
  log "Install with: brew install tmux"
  log "Or pass tmux on PATH: export PATH=/opt/homebrew/bin:\$PATH"
  exit 1
fi
log "step 0/6: using tmux at $TMUX_BIN"

log "step 1/6: snapshot of pre-swap tmux state"
"$TMUX_BIN" ls 2>/dev/null || log "  (no tmux sessions running)"
echo

log "step 2/6: stopping current mlx_lm.server tmux session 'mlx'"
if "$TMUX_BIN" has-session -t mlx 2>/dev/null; then
  "$TMUX_BIN" kill-session -t mlx
  log "  killed"
else
  log "  no 'mlx' session found (already stopped?)"
fi

log "step 3/6: installing phase3-binary to $INSTALL_DIR"
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
tar xzf "$TARBALL" -C "$INSTALL_DIR"
log "  contents extracted:"
ls -la "$INSTALL_DIR"/macprovider-cli "$INSTALL_DIR"/mlx-swift_Cmlx.bundle 2>&1 | head -4 | sed 's/^/    /'

log "step 4/6: clearing macOS quarantine attributes (so Gatekeeper allows execution)"
xattr -dr com.apple.quarantine "$INSTALL_DIR" 2>/dev/null || true
log "  done"

log "step 5/6: starting binary in tmux session 'mlx' on port $PORT"
"$TMUX_BIN" new-session -d -s mlx \
    "cd '$INSTALL_DIR' && ./macprovider-cli --port $PORT --model '$MODEL' 2>&1 | tee /tmp/phase3-binary-m4.log"

log "step 6/6: waiting for binary to bind + load model (up to ${TIMEOUT_S}s)"
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

if [ $ok -eq 1 ]; then
  log "  /v1/models responded"
  # CRITICAL: verify it's phase3-binary, not the old mlx_lm.server
  models_json=$(curl -sS "http://127.0.0.1:$PORT/v1/models")
  if echo "$models_json" | grep -q '"owned_by"[[:space:]]*:[[:space:]]*"macprovider"'; then
    log "  VERIFIED phase3-binary is serving (owned_by: macprovider)"
    echo
    echo "$models_json" | python3 -m json.tool 2>&1 || true
    echo
    log "Done. m4.streamvc.live now serves via phase3-binary."
    log "View binary logs: $TMUX_BIN attach -t mlx     (Ctrl-B then D to detach)"
    log "  OR:             tail -f /tmp/phase3-binary-m4.log"
    log "To rollback if something feels off: bash rollback-m4.sh"
    exit 0
  else
    log "  WARNING: /v1/models responded but lacks owned_by:macprovider"
    log "  This likely means the OLD mlx_lm.server is still running and our"
    log "  binary never started. Symptoms include 'tmux: command not found'"
    log "  silently swallowed earlier in the run."
    echo
    echo "  Response received:"
    echo "$models_json" | head -20
    echo
    log "  Recommended:"
    log "    1. pkill -f mlx_lm.server"
    log "    2. Verify tmux at $TMUX_BIN works: $TMUX_BIN ls"
    log "    3. Re-run install"
    exit 2
  fi
else
  log "  TIMEOUT — nothing responded on port $PORT within ${TIMEOUT_S}s"
  log "  Check: $TMUX_BIN attach -t mlx"
  log "  OR run: bash rollback-m4.sh"
  exit 1
fi
