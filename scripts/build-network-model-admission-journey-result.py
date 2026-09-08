#!/usr/bin/env python3
"""Build an unsigned JOURNEY-NETWORK-MODEL-ADMISSION journey-result payload.

Input is the redacted evidence artifact written by
`scripts/capture-byom-journey-evidence.py --journey admission`, including the
SPEC-047-R003 money-path zero-row assertions. Output is the unsigned payload that
`scripts/sign-journey-result.py` signs with the operator acceptance key; this
script never touches signing material.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from byom_journey_evidence import ADMISSION_CONTRACT, run_builder_cli  # noqa: E402


def main(argv: list[str] | None = None) -> int:
    return run_builder_cli(ADMISSION_CONTRACT, argv, "build-network-model-admission-journey-result")


if __name__ == "__main__":
    raise SystemExit(main())
