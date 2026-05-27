#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

build_binary
set +e
OUTPUT="$(provider_env "$BINARY" --model /nonexistent/path 2>&1)"
STATUS="$?"
set -e

if [[ "$STATUS" -eq 0 ]]; then
  echo "expected nonzero exit for nonexistent model" >&2
  exit 1
fi
if ! grep -qi "error\|failed\|no such\|cannot" <<<"$OUTPUT"; then
  echo "expected diagnostic output for nonexistent model" >&2
  echo "$OUTPUT" >&2
  exit 1
fi
echo "startup failure exits $STATUS with diagnostic"
