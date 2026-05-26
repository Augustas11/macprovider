#!/usr/bin/env bash
# M1 cooperative-cron entry.
set -euo pipefail
BETA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$BETA_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/.venv/bin/activate"
cd "$BETA_DIR"

echo "===== $(date -u +%Y-%m-%dT%H:%M:%SZ) m1 cooperative start ====="
python harness.py --config config-m1.yaml --batch cooperative --verbose || echo "m1 cooperative exited non-zero"
python report.py
echo "===== $(date -u +%Y-%m-%dT%H:%M:%SZ) m1 cooperative end ====="
