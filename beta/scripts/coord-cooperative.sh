#!/usr/bin/env bash
# coord-cooperative.sh — cron entry that fires the cooperative batch
# against https://coordinator.malibu.tech and regenerates today's report.
# Runs alongside m4-cooperative.sh and m1-cooperative.sh; tunnel_url in the
# runs.sqlite row distinguishes coordinator-routed traffic from direct.
set -euo pipefail
BETA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$BETA_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/.venv/bin/activate"
cd "$BETA_DIR"

echo "===== $(date -u +%Y-%m-%dT%H:%M:%SZ) coord cooperative start ====="
python harness.py --config config-coord.yaml --batch cooperative --verbose || echo "coord cooperative exited non-zero"
python report.py
echo "===== $(date -u +%Y-%m-%dT%H:%M:%SZ) coord cooperative end ====="
