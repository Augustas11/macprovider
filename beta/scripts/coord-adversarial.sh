#!/usr/bin/env bash
# coord-adversarial.sh — daily adversarial batch through the coordinator.
# Pressure-tests the full nginx -> coordinator -> provider chain rather
# than the direct-tunnel path.
set -euo pipefail
BETA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$BETA_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/.venv/bin/activate"
cd "$BETA_DIR"

echo "===== $(date -u +%Y-%m-%dT%H:%M:%SZ) coord adversarial start ====="
python harness.py --config config-coord.yaml --batch adversarial --verbose || echo "coord adversarial exited non-zero"
echo "===== $(date -u +%Y-%m-%dT%H:%M:%SZ) coord adversarial end ====="
