#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CONFIG="${1:-$ROOT/beta/config-coord-test.yaml}"

if [[ ! -f "$CONFIG" ]]; then
  echo "missing harness config: $CONFIG" >&2
  echo "create beta/config-coord-test.yaml with tunnel_url pointing at the coordinator buyer endpoint" >&2
  exit 2
fi

cd "$ROOT/beta"
python3 harness.py --config "$CONFIG" --batch cooperative --verbose
python3 harness.py --config "$CONFIG" --batch adversarial --verbose
