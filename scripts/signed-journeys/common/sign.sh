#!/usr/bin/env bash
set -euo pipefail
python3 scripts/sign-journey-result.py \
  --input "$PAYLOAD" \
  --output "$ENVELOPE" \
  --verifier ".github/workflows/signed-journey.yml:${GITHUB_RUN_ID}:${GITHUB_RUN_ATTEMPT}"
