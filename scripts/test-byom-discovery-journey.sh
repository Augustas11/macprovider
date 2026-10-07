#!/usr/bin/env bash
# Hermetic JOURNEY-PROVIDER-BYOM-DISCOVERY gate (#1453 slice 1).
#
# Runs the ten-step driver, then capture. While SPEC-046-R001..R008 are
# pending, it also builds and preflights an unsigned payload. After those
# rows are signed-promoted, build/preflight would fail closed on purpose
# (they refuse a second promotion), so the gate validates the landed
# signed envelope instead. Capture still rejects a manifest that the
# step/requirement/observation tables or fail-closed redaction scan reject.
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

# Build + preflight are the unsigned promotion path: they require the eight
# SPEC-046 rows to still be pending. After signed promotion those rows are
# conformant, so the same commands fail closed on purpose. A selector change
# may temporarily leave R001 and/or R008 pending while the other rows retain
# their independently signed evidence. In that state the gate still runs
# driver + capture, then validates each row against its own retained envelope
# instead of incorrectly requiring one envelope to cover the whole ledger.
DISCOVERY_LEDGER_STATE="$(python3 - "$REQUIREMENT_IDS" <<'PY'
import json
import sys
from pathlib import Path

ids = [item.strip() for item in sys.argv[1].split(",") if item.strip()]
refresh_pending_ids = {
    "SPEC-046-R001",
    # These version-lock selectors are intentionally restored by a fresh
    # independently trusted discovery promotion, potentially one at a time.
    "SPEC-046-R008",
}
legacy_stale_selector_ids = {
    "SPEC-046-R001",
    # #1816 pool-scoped model changes moved these mapped selectors.
    "SPEC-046-R003",
    "SPEC-046-R004",
    "SPEC-046-R005",
    "SPEC-046-R006",
    "SPEC-046-R007",
    "SPEC-046-R008",
}
conformance = json.loads(Path("specs/CONFORMANCE.json").read_text(encoding="utf-8"))
rows = {
    row["requirement_id"]: row
    for row in conformance.get("requirements", [])
    if isinstance(row, dict) and isinstance(row.get("requirement_id"), str)
}
states = []
pending_ids = []
sources_by_requirement = {}
for requirement_id in ids:
    row = rows.get(requirement_id)
    if not isinstance(row, dict):
        raise SystemExit(f"missing requirement {requirement_id}")
    state = row.get("state")
    states.append(state)
    if state == "pending":
        pending_ids.append(requirement_id)
    sources = set()
    for item in row.get("evidence") or []:
        if isinstance(item, dict) and str(item.get("artifact", "")).startswith("sha256:"):
            source = item.get("source")
            if isinstance(source, str) and source:
                sources.add(source)
    sources_by_requirement[requirement_id] = sources

if all(state == "pending" for state in states):
    print("pending")
elif (
    (
        set(pending_ids).issubset(refresh_pending_ids)
        or set(pending_ids) == legacy_stale_selector_ids
    )
    and all(state in {"pending", "conformant"} for state in states)
):
    missing_or_ambiguous = {
        requirement_id: sorted(sources)
        for requirement_id, sources in sources_by_requirement.items()
        if len(sources) != 1
    }
    if missing_or_ambiguous:
        raise SystemExit(
            "SPEC-046 retained rows must each have exactly one signed source, "
            f"not {missing_or_ambiguous!r}"
        )
    print("conformant" if not pending_ids else "retained")
    for requirement_id in ids:
        print(f"{requirement_id}\t{next(iter(sources_by_requirement[requirement_id]))}")
else:
    raise SystemExit(
        "SPEC-046 discovery rows must be uniformly pending, uniformly "
        "conformant, or only refresh-selector rows pending, "
        f"not {states!r} / {sorted(pending_ids)!r}"
    )
PY
)"
LEDGER_STATE=""
RETAINED_SIGNED_ROWS=()
while IFS= read -r ledger_line; do
  if [[ -z "$LEDGER_STATE" ]]; then
    LEDGER_STATE="$ledger_line"
  else
    RETAINED_SIGNED_ROWS+=("$ledger_line")
  fi
done <<<"$DISCOVERY_LEDGER_STATE"

validate_retained_rows() {
  local signed_row requirement_id signed_source
  for signed_row in "${RETAINED_SIGNED_ROWS[@]}"; do
    IFS=$'\t' read -r requirement_id signed_source <<<"$signed_row"
    [[ -n "$requirement_id" && -n "$signed_source" ]] || {
      echo "test-byom-discovery-journey: malformed retained signed-source row" >&2
      return 1
    }
    python3 scripts/validate-signed-journey-result.py \
      "$signed_source" \
      --requirement-ids "$requirement_id"
  done
}

if [[ "$LEDGER_STATE" == "pending" ]]; then
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
elif [[ "$LEDGER_STATE" == "conformant" ]]; then
  validate_retained_rows
  echo "test-byom-discovery-journey: driver, capture, and signed envelope validation passed"
elif [[ "$LEDGER_STATE" == "retained" ]]; then
  validate_retained_rows
  echo "test-byom-discovery-journey: driver, capture, and retained signed envelope validation passed"
else
  echo "test-byom-discovery-journey: unexpected SPEC-046 ledger state" >&2
  exit 1
fi
