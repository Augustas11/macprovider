#!/usr/bin/env bash
set -euo pipefail
python3 - "$REQUIREMENT_IDS" "$ENVELOPE" <<'PY'
import subprocess
import sys

requirement_ids = [item for item in sys.argv[1].split(",") if item]
envelope = sys.argv[2]
for requirement_id in requirement_ids:
    subprocess.run(
        [
            "python3",
            "scripts/promote-signed-journey-result.py",
            "--base-ref",
            "origin/main",
            requirement_id,
            envelope,
        ],
        check=True,
    )
PY
