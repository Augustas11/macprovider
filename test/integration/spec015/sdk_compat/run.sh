#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
: "${MACPROVIDER_SPEC015_GATEWAY_URL:?set MACPROVIDER_SPEC015_GATEWAY_URL to the local gateway origin or /v1 URL}"

TMPDIR="$(mktemp -d -t spec015-sdk-compat.XXXXXX)"
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

python3 -m venv "$TMPDIR/venv"
"$TMPDIR/venv/bin/python" -m pip install --disable-pip-version-check --quiet -r "$HERE/python/requirements.txt"
"$TMPDIR/venv/bin/python" "$HERE/python/smoke_openai_python.py"

mkdir -p "$TMPDIR/js"
cp "$HERE/js/package.json" "$HERE/js/smoke_openai_node.mjs" "$TMPDIR/js/"
npm install --prefix "$TMPDIR/js" --ignore-scripts --no-audit --no-fund --quiet
node "$TMPDIR/js/smoke_openai_node.mjs"
