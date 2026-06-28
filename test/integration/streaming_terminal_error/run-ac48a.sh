#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
python3 -m venv .venv-ac48a
. .venv-ac48a/bin/activate
python -m pip install --quiet --upgrade pip
python -m pip install --quiet -r ../../../tools/version-pins/openai-python-spec-018-v0_1_3-baseline.txt
python ac48a_openai_python_terminal_error.py
