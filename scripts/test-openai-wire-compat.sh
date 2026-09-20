#!/usr/bin/env bash
# Client-oracle harness for OpenAI chat.completions streaming + tool_calls.
# Pins openai==2.44.0 (Pi's SDK) against a local stub. Live Pearl/OpenRouter
# checks run only when MALIBU_API_KEY / OPENROUTER_API_KEY are set.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

venv="$(mktemp -d "${TMPDIR:-/tmp}/openai-wire-venv.XXXXXX")"
cleanup() { rm -rf "$venv"; }
trap cleanup EXIT

python3 -m venv "$venv"
"$venv/bin/pip" install --quiet --disable-pip-version-check "openai==2.44.0"
PYTHONDONTWRITEBYTECODE=1 "$venv/bin/python" -m unittest discover \
  -s test/compat/openai_wire \
  -p 'test_*.py' \
  -v
