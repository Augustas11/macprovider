#!/usr/bin/env bash
set -euo pipefail
python3 scripts/validate-signed-journey-result.py \
  --requirement-ids "$REQUIREMENT_IDS" \
  "$ENVELOPE"
