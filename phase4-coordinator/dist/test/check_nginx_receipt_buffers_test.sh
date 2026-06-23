#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
FILES=(
  "$REPO_ROOT/phase4-coordinator/dist/nginx-coordinator.streamvc.live.conf"
  "$REPO_ROOT/phase5-gateway/dist/nginx-api.streamvc.live.conf"
)
FAIL=0
require_directive() {
  local file="$1"
  local directive="$2"
  if ! sed 's/[[:space:]]*#.*$//' "$file" | grep -qF "$directive"; then
    echo "FAIL: $file missing active directive: $directive" >&2
    FAIL=1
  fi
}

for file in "${FILES[@]}"; do
  require_directive "$file" "large_client_header_buffers 4 8k;"
  require_directive "$file" "proxy_buffer_size 8k;"
  require_directive "$file" "proxy_buffers 4 8k;"
done
if [ "$FAIL" -eq 0 ]; then
  echo "ok: SPEC-015 nginx receipt header buffers configured"
fi
exit "$FAIL"
