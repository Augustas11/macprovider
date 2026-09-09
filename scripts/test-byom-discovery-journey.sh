#!/usr/bin/env bash
# Hermetic JOURNEY-PROVIDER-BYOM-DISCOVERY gate (#1453 slice 1).
#
# Runs the ten-step driver, then feeds its run manifest through the real
# evidence pipeline: capture -> build -> preflight. The pipeline IS the
# acceptance test for the driver -- a manifest that capture's step tables,
# requirement tables, observation tables, or fail-closed redaction scan reject
# fails this gate.
#
# Nothing here signs or promotes anything: signing needs the operator
# acceptance key and stays out of CI (docs/runbooks/byom-journey-evidence.md
# step 6). Nothing is left in the working tree either -- the redacted evidence
# is written under journeys/evidence/ only long enough for the builder to read
# it, and the commit that carries it for the builder's byte check is a dangling
# `git commit-tree` object that moves no ref, index, or branch.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVIDENCE="journeys/evidence/provider-byom-discovery-ci-${STAMP}.redacted.json"
OUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/byom-discovery-journey-XXXXXX")"
UNSIGNED="${OUT_DIR}/journey-result.unsigned.json"
INDEX="${OUT_DIR}/git-index"

cleanup() {
  rm -f "$EVIDENCE"
  rm -rf "$OUT_DIR"
}
trap cleanup EXIT

if [ -e "$EVIDENCE" ]; then
  echo "test-byom-discovery-journey: refusing to overwrite $EVIDENCE" >&2
  exit 1
fi

REQUIREMENT_IDS="SPEC-046-R001,SPEC-046-R002,SPEC-046-R003,SPEC-046-R004,SPEC-046-R005,SPEC-046-R006,SPEC-046-R007,SPEC-046-R008"
SOURCE_SHA="$(git rev-parse HEAD)"
# The evidence artifact records an operator identity as a SHA-256 fingerprint.
# This gate is not an operator run, so it uses a fixed, non-identifying label.
OPERATOR_FINGERPRINT="$(printf 'ci-hermetic-discovery-journey' | shasum -a 256 | cut -d' ' -f1)"

test/e2e/byom/run-discovery-journey.py --out "$OUT_DIR"

python3 scripts/capture-byom-journey-evidence.py \
  --journey discovery \
  --run-manifest "${OUT_DIR}/run-manifest.json" \
  --output "$EVIDENCE" \
  --source-sha "$SOURCE_SHA" \
  --operator-role release-operator \
  --operator-identity-fingerprint "$OPERATOR_FINGERPRINT" \
  --hardware-profile ci-hermetic-runner \
  --candidate "$(git rev-parse --short HEAD)" \
  --summary "hermetic discovery journey"

# The builder verifies the evidence bytes against a commit that contains them,
# so give it one without touching the branch: a temporary index produces the
# tree, and commit-tree produces an unreferenced commit whose parent is HEAD.
GIT_INDEX_FILE="$INDEX" git read-tree HEAD
GIT_INDEX_FILE="$INDEX" git update-index --add "$EVIDENCE"
EVIDENCE_TREE="$(GIT_INDEX_FILE="$INDEX" git write-tree)"
EVIDENCE_SHA="$(git commit-tree "$EVIDENCE_TREE" -p "$SOURCE_SHA" -m "ephemeral discovery-journey evidence")"

python3 scripts/build-byom-discovery-journey-result.py \
  "$EVIDENCE" \
  --output "$UNSIGNED" \
  --source-sha "$SOURCE_SHA" \
  --evidence-sha "$EVIDENCE_SHA" \
  --requirement-ids "$REQUIREMENT_IDS"

python3 scripts/preflight-signed-journey-promotion.py \
  --source-sha "$SOURCE_SHA" \
  --requirement-ids "$REQUIREMENT_IDS" \
  --journey-id JOURNEY-PROVIDER-BYOM-DISCOVERY

echo "test-byom-discovery-journey: driver, capture, build, and preflight passed"
