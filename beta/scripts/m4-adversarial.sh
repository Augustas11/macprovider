#!/usr/bin/env bash
# M4 adversarial-cron entry. Off-peak only; don't schedule on the same
# day/hour as m1-adversarial.sh.
set -euo pipefail
BETA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$BETA_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/.venv/bin/activate"
cd "$BETA_DIR"

echo "===== $(date -u +%Y-%m-%dT%H:%M:%SZ) m4 adversarial start ====="
python harness.py --config config-m4.yaml --batch adversarial --verbose || echo "m4 adversarial exited non-zero"
python report.py
echo "===== $(date -u +%Y-%m-%dT%H:%M:%SZ) m4 adversarial end ====="
