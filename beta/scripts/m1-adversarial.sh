#!/usr/bin/env bash
# M1 adversarial-cron entry. Off-peak only; don't schedule on the same
# day/hour as m4-adversarial.sh.
set -euo pipefail
BETA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$BETA_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/.venv/bin/activate"
cd "$BETA_DIR"

echo "===== $(date -u +%Y-%m-%dT%H:%M:%SZ) m1 adversarial start ====="
python harness.py --config config-m1.yaml --batch adversarial --verbose || echo "m1 adversarial exited non-zero"
python report.py
echo "===== $(date -u +%Y-%m-%dT%H:%M:%SZ) m1 adversarial end ====="
