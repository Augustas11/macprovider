#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LOCAL_SERVER_PID=""
SERVER_LOG=""
if [ -z "${MACPROVIDER_SPEC015_GATEWAY_URL:-}" ]; then
  SERVER_LOG="$(mktemp -t spec015-sdk-server.XXXXXX)"
  python3 "$HERE/local_compat_server.py" >"$SERVER_LOG" &
  LOCAL_SERVER_PID="$!"
  for _ in $(seq 1 50); do
    if [ -s "$SERVER_LOG" ]; then
      MACPROVIDER_SPEC015_GATEWAY_URL="$(head -n 1 "$SERVER_LOG")"
      export MACPROVIDER_SPEC015_GATEWAY_URL
      break
    fi
    sleep 0.1
  done
  if [ -z "${MACPROVIDER_SPEC015_GATEWAY_URL:-}" ]; then
    echo "local SPEC-015 SDK server did not start" >&2
    exit 1
  fi
fi

TMPDIR="$(mktemp -d -t spec015-sdk-compat.XXXXXX)"
cleanup() {
  if [ -n "${LOCAL_SERVER_PID:-}" ]; then
    kill "$LOCAL_SERVER_PID" 2>/dev/null || true
  fi
  if [ -n "${SERVER_LOG:-}" ]; then
    rm -f "$SERVER_LOG"
  fi
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

python3 -m venv "$TMPDIR/venv"
"$TMPDIR/venv/bin/python" -m pip install --disable-pip-version-check --quiet --require-hashes -r "$HERE/python/requirements.lock"
"$TMPDIR/venv/bin/python" "$HERE/python/smoke_openai_python.py"

mkdir -p "$TMPDIR/js"
cp "$HERE/js/package.json" "$HERE/js/package-lock.json" "$HERE/js/smoke_openai_node.mjs" "$TMPDIR/js/"
npm ci --prefix "$TMPDIR/js" --ignore-scripts --no-audit --no-fund --quiet
node "$TMPDIR/js/smoke_openai_node.mjs"
