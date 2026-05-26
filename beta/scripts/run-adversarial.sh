#!/usr/bin/env bash
# Adversarial-cron entrypoint. Fires the config.yaml `batch_adversarial` list
# and regenerates today's HTML report. Each adversarial workload runs its own
# internal HTTP storm and writes one row to the adversarial_runs table.
#
# Example crontab — twice a week, off-peak, on the OPERATOR'S M1:
#   0 14 * * 2,5 /Users/augstar/macprovider-poc/beta/scripts/run-adversarial.sh >>/Users/augstar/macprovider-poc/beta/cron.log 2>&1
#
# Coordinate timing with peer operator: never fire adversarial against both
# providers simultaneously. Stagger or alternate by provider.
set -euo pipefail
BETA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$BETA_DIR/.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/.venv/bin/activate"
cd "$BETA_DIR"

echo "===== $(date -u +%Y-%m-%dT%H:%M:%SZ) adversarial start ====="
python harness.py --batch adversarial --verbose || echo "adversarial exited non-zero (continuing to report)"
python report.py
echo "===== $(date -u +%Y-%m-%dT%H:%M:%SZ) adversarial end ====="
