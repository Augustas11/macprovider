#!/usr/bin/env bash
# M4 cooperative-cron entry. Fires the cooperative batch list against
# https://m4.malibu.tech and regenerates today's report.
set -euo pipefail
BETA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$BETA_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/.venv/bin/activate"
cd "$BETA_DIR"

echo "===== $(date -u +%Y-%m-%dT%H:%M:%SZ) m4 cooperative start ====="
python harness.py --config config-m4.yaml --batch cooperative --verbose || echo "m4 cooperative exited non-zero"
python report.py
echo "===== $(date -u +%Y-%m-%dT%H:%M:%SZ) m4 cooperative end ====="
