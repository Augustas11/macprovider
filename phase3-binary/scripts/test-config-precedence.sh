#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

build_binary

CONFIG="/private/tmp/macprovider-config-precedence.yaml"
cat >"$CONFIG" <<'YAML'
port: 18110
model: mlx-community/Llama-3.2-3B-Instruct-4bit
YAML

check_port() {
  local expected="$1"
  shift
  local output
  output="$({ provider_env "$BINARY" "$@" --model /nonexistent/path 2>&1 || true; } | sed -n 's/^  port: //p' | head -1)"
  if [[ "$output" != "$expected" ]]; then
    echo "expected port $expected, got ${output:-<none>}" >&2
    exit 1
  fi
}

check_port 8080
check_port 18110 --config "$CONFIG"
OUTPUT="$({ MACPROVIDER_PORT=18111 provider_env "$BINARY" --model /nonexistent/path 2>&1 || true; } | sed -n 's/^  port: //p' | head -1)"
if [[ "$OUTPUT" != "18111" ]]; then
  echo "expected env port 18111, got ${OUTPUT:-<none>}" >&2
  exit 1
fi

OUTPUT="$({ MACPROVIDER_PORT=18111 provider_env "$BINARY" --config "$CONFIG" --port 18112 --model /nonexistent/path 2>&1 || true; } | sed -n 's/^  port: //p' | head -1)"
if [[ "$OUTPUT" != "18112" ]]; then
  echo "expected CLI port 18112, got ${OUTPUT:-<none>}" >&2
  exit 1
fi
echo "config precedence verified"
