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

# Every artifact this gate writes lives under a directory `mktemp -d` created
# for this invocation, so two runs -- even in the same second -- can never name
# the same path, and cleanup can never delete another run's artifact. A
# timestamped filename plus a "refuse to overwrite" check could not promise
# either: the trap that ran on the refusal deleted the file it had just refused
# to touch (R3 MEDIUM). The evidence directory has to stay inside
# `journeys/evidence/` and keep the journey's prefix, because the capture
# contract only accepts `journeys/evidence/provider-byom-discovery-*.redacted.json`
# and the builder verifies the bytes against a commit that contains them.
EVIDENCE_DIR=""
OUT_DIR=""

cleanup() {
  # Only ever remove what this invocation created. Both variables are set from
  # a successful `mktemp -d`, so an empty one means the directory is not ours.
  [ -n "$EVIDENCE_DIR" ] && rm -rf "$EVIDENCE_DIR"
  [ -n "$OUT_DIR" ] && rm -rf "$OUT_DIR"
  return 0
}
trap cleanup EXIT

EVIDENCE_DIR="$(mktemp -d "journeys/evidence/provider-byom-discovery-ci-XXXXXX")"
OUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/byom-discovery-journey-XXXXXX")"
EVIDENCE="${EVIDENCE_DIR}/run.redacted.json"
UNSIGNED="${OUT_DIR}/journey-result.unsigned.json"
INDEX="${OUT_DIR}/git-index"

REQUIREMENT_IDS="SPEC-046-R001,SPEC-046-R002,SPEC-046-R003,SPEC-046-R004,SPEC-046-R005,SPEC-046-R006,SPEC-046-R007,SPEC-046-R008"
# The evidence artifact records an operator identity as a SHA-256 fingerprint.
# This gate is not an operator run, so it uses a fixed, non-identifying label.
OPERATOR_FINGERPRINT="$(printf 'ci-hermetic-discovery-journey' | shasum -a 256 | cut -d' ' -f1)"

# The lockfile rule is the driver's, and only the driver's: unconditionally
# restoring phase3-binary/Package.resolved from HEAD here destroyed local
# uncommitted lockfile work with no way to get it back (R3 MEDIUM). In
# `--evidence` mode the driver restores HEAD's lockfile only in an ephemeral CI
# checkout, where the drift is the earlier `swift test` step's resolution and
# HEAD's lockfile is separately proven by the `phase3-binary (locked SwiftPM
# resolve)` job; on a developer machine it refuses to run instead, and says to
# commit or restore the file.

# `--evidence` binds the run to the commit: the driver refuses a
# MACPROVIDER_CLI_BINARY override, requires a clean tree -- tracked AND
# untracked -- across the CLI source, the scripts, and the harness, builds the
# CLI with locked resolution so the build cannot rewrite the lockfile, and
# re-checks cleanliness after the build before publishing the manifest. Without
# --evidence the driver publishes no manifest at all.
test/e2e/byom/run-discovery-journey.py --evidence --out "$OUT_DIR"

# Recorded only now: the driver's post-build cleanliness check has passed, so
# this commit is what produced the manifest above. Reading it earlier would
# name a commit before knowing whether the run stayed bound to it.
SOURCE_SHA="$(git rev-parse HEAD)"

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
