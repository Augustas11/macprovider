#!/usr/bin/env bash
set -euo pipefail
python3 -m json.tool "$REDACTED" >/dev/null
python3 -m json.tool "$ENVELOPE" >/dev/null
python3 -m json.tool specs/CONFORMANCE.json >/dev/null
python3 scripts/check_spec_governance.py --base-ref origin/main
git diff --check
python3 - "$ENVELOPE" <<'PY'
import pathlib
import sys

envelope = pathlib.Path(sys.argv[1]).as_posix()
prefix = pathlib.Path(envelope).name.removesuffix(".journey-result.signed.json")
for path in pathlib.Path("journeys/evidence").glob(f"{prefix}*"):
    name = path.name
    if name.endswith(".candidate.json") or name.endswith(".journey-result.unsigned.json"):
        raise SystemExit(f"non-committed intermediate remains: {path}")
PY
