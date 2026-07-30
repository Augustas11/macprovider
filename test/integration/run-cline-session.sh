#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
python3 "$HERE/cline_session/run_fixture.py"
echo "cline session fixture passed"
