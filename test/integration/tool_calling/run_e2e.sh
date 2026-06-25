#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

if [ -z "${MACPROVIDER_TOOL_E2E_BASE_URL:-}" ]; then
  echo "MACPROVIDER_TOOL_E2E_BASE_URL is required" >&2
  exit 2
fi

TMPDIR="$(mktemp -d -t macprovider-tool-e2e.XXXXXX)"
cleanup() {
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

python3 -m venv "$TMPDIR/venv"
"$TMPDIR/venv/bin/python" -m pip install \
  --disable-pip-version-check \
  --quiet \
  --require-hashes \
  -r "$ROOT/test/integration/spec015/sdk_compat/python/requirements.lock"
"$TMPDIR/venv/bin/python" "$HERE/openai_tool_call_e2e.py" "$@"

echo "tool-calling e2e passed"
