#!/usr/bin/env bash
set -euo pipefail
python3 -m json.tool "$REDACTED" >/dev/null
python3 -m json.tool "$ENVELOPE" >/dev/null
python3 -m json.tool specs/CONFORMANCE.json >/dev/null
python3 scripts/check_spec_governance.py --base-ref origin/main
git diff --check
python3 - "$ENVELOPE" "$REQUIREMENT_IDS" <<'PY'
import json
import pathlib
import sys

envelope = pathlib.Path(sys.argv[1]).as_posix()
requirement_ids = [item for item in sys.argv[2].split(",") if item]
conformance = json.loads(pathlib.Path("specs/CONFORMANCE.json").read_text(encoding="utf-8"))
rows = {
    item.get("requirement_id"): item
    for item in conformance.get("requirements", [])
    if isinstance(item, dict)
}
for requirement_id in requirement_ids:
    requirement = rows.get(requirement_id)
    if requirement is None:
        raise SystemExit(f"{requirement_id} missing from conformance ledger")
    if requirement.get("state") != "conformant" or requirement.get("gap") is not None:
        raise SystemExit(f"{requirement_id} was not promoted to conformant")
    evidence = requirement.get("evidence")
    if not isinstance(evidence, list) or not any(item.get("source") == envelope for item in evidence if isinstance(item, dict)):
        raise SystemExit(f"{requirement_id} evidence does not reference the signed envelope")
prefix = pathlib.Path(envelope).name.removesuffix(".journey-result.signed.json")
for path in pathlib.Path("journeys/evidence").glob(f"{prefix}*"):
    name = path.name
    if name.endswith(".candidate.json") or name.endswith(".journey-result.unsigned.json"):
        raise SystemExit(f"non-promotable intermediate remains: {path}")
PY
