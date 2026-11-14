#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../common/registry.sh"
[[ "$copy_conformance" == yes ]] || { echo "::error::promotion export is conformance-bearing" >&2; exit 1; }
export_dir="$RUNNER_TEMP/$export_dir_name"
mkdir -p "$export_dir/journeys/evidence" "$export_dir/specs"
cp "$REDACTED" "$export_dir/$REDACTED"
cp "$ENVELOPE" "$export_dir/$ENVELOPE"
cp specs/CONFORMANCE.json "$export_dir/specs/CONFORMANCE.json"
python3 - "$export_dir/promotion-manifest.json" "$SOURCE_SHA" "$EVIDENCE_SHA" "$REDACTED" "$ENVELOPE" "$REQUIREMENT_IDS" <<'PY'
import hashlib
import json
import os
import pathlib
import sys

output, source_sha, evidence_sha, redacted, envelope, requirement_ids = sys.argv[1:]
root = pathlib.Path(".")
manifest = {
    "schema_version": os.environ["schema"],
    "source_sha": source_sha,
    "evidence_sha": evidence_sha,
    "requirement_ids": [item for item in requirement_ids.split(",") if item],
    "requirement_slug": os.environ["REQUIREMENT_SLUG"],
    "journey_id": os.environ["journey_id"],
    "redacted_artifact": redacted,
    "redacted_sha256": hashlib.sha256((root / redacted).read_bytes()).hexdigest(),
    "signed_envelope": envelope,
    "signed_envelope_sha256": hashlib.sha256((root / envelope).read_bytes()).hexdigest(),
    "conformance_sha256": hashlib.sha256((root / "specs/CONFORMANCE.json").read_bytes()).hexdigest(),
    "workflow_run_id": os.environ["GITHUB_RUN_ID"],
    "workflow_run_attempt": os.environ["GITHUB_RUN_ATTEMPT"],
}
pathlib.Path(output).write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
PY
