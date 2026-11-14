#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/registry.sh"
python3 scripts/preflight-signed-journey-promotion.py \
  --source-sha "$SOURCE_SHA" \
  --requirement-ids "$REQUIREMENT_IDS" \
  --journey-id "$journey_id"
