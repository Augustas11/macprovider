#!/usr/bin/env bash
# Manual single-workload smoke test. Usage: scripts/run-once.sh [workload_name]
# Default workload is short_chat — the cheapest signal that the tunnel works.
set -euo pipefail
BETA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$BETA_DIR/.." && pwd)"
WORKLOAD="${1:-short_chat}"

# shellcheck disable=SC1091
source "$REPO_ROOT/.venv/bin/activate"
cd "$BETA_DIR"
python harness.py --once "$WORKLOAD" --verbose
