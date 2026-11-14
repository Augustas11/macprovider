#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/registry.sh"
"${builder[@]}" \
  --source-sha "$SOURCE_SHA" \
  --evidence-sha "$EVIDENCE_SHA" \
  --requirement-ids "$REQUIREMENT_IDS" \
  --output "$PAYLOAD" \
  "$REDACTED"
