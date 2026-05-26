#!/usr/bin/env bash
# Cron-friendly batch entrypoint. Fires the config.yaml `batch` list, then
# regenerates today's HTML report. Logs to logs/cron.log next to runs.sqlite.
#
# Example crontab (M1, operator side):
#   # Hourly batch between 09:00 and 22:00 local time
#   0 9-22 * * * /Users/augstar/macprovider-poc/beta/scripts/run-scheduled.sh >>/Users/augstar/macprovider-poc/beta/cron.log 2>&1
set -euo pipefail
BETA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$BETA_DIR/.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/.venv/bin/activate"
cd "$BETA_DIR"

echo "===== $(date -u +%Y-%m-%dT%H:%M:%SZ) batch start ====="
python harness.py --batch --verbose || echo "batch exited non-zero (continuing to report)"
python report.py
echo "===== $(date -u +%Y-%m-%dT%H:%M:%SZ) batch end ====="
