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

log "step 1/6: snapshot of pre-swap tmux state"
tmux ls 2>/dev/null || log "  (no tmux sessions running)"
echo

log "step 2/6: stopping current mlx_lm.server tmux session 'mlx'"
if tmux has-session -t mlx 2>/dev/null; then
  tmux kill-session -t mlx
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
tmux new-session -d -s mlx \
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
  log "  BINARY READY"
  echo
  curl -sS "http://127.0.0.1:$PORT/v1/models" | python3 -m json.tool 2>&1 || true
  echo
  log "Done. m4.streamvc.live now serves via phase3-binary."
  log "View binary logs: tmux attach -t mlx     (Ctrl-B then D to detach)"
  log "  OR:             tail -f /tmp/phase3-binary-m4.log"
  log "To rollback if something feels off: ./rollback-m4.sh"
  exit 0
else
  log "  TIMEOUT — binary did not respond within ${TIMEOUT_S}s"
  log "  Check: tmux attach -t mlx"
  log "  OR run: ./rollback-m4.sh"
  exit 1
fi
