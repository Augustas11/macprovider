#!/usr/bin/env python3
"""Capture redacted BYOM signed-journey evidence for SPEC-046 / SPEC-047.

The run manifest (`macprovider.byom-journey-run.v1`) records, per normative
journey step, the pass/fail verdict, the requirement ids that step exercises, and
the captured CLI JSON documents. This script digests those documents, enforces the
step and requirement tables from `journeys/JOURNEY-*.md` and the SPECs, refuses any
unredacted URL, path, hostname, IP, or credential, and writes the redacted evidence
artifact that `build-*-journey-result.py` later projects into a journey-result.

The captured CLI documents themselves are never copied into the repository; only
their SHA-256 digests and byte counts are recorded.

This script signs nothing. Promotion still needs the operator acceptance signing
key via `scripts/sign-journey-result.py`.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from byom_journey_evidence import (  # noqa: E402
    ADMISSION_CONTRACT,
    BYOMEvidenceError,
    DISCOVERY_CONTRACT,
    build_evidence,
    contract_for,
    repository_relative,
    write_json_atomically,
)


HARNESS_PATH = "test/e2e/byom/run-cli-onboarding-e2e.py"


def die(message: str) -> None:
    print(f"capture-byom-journey-evidence: {message}", file=sys.stderr)
    raise SystemExit(1)


def run_hermetic_harness(root: Path) -> None:
    harness = root / HARNESS_PATH
    if not harness.is_file() or harness.is_symlink():
        die(f"hermetic harness is absent or unsafe: {HARNESS_PATH}")
    completed = subprocess.run(
        [sys.executable, str(harness)],
        cwd=str(root),
        capture_output=True,
        text=True,
        check=False,
    )
    if completed.returncode != 0:
        # The harness prints loopback origins and temp paths; surface only the
        # verdict so this script's own output stays redaction-safe.
        die(f"hermetic BYOM harness failed with exit code {completed.returncode}")
    print("capture-byom-journey-evidence: hermetic BYOM harness passed")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--journey",
        required=True,
        choices=(DISCOVERY_CONTRACT.selector, ADMISSION_CONTRACT.selector),
        help="which BYOM journey this run covers",
    )
    parser.add_argument("--root", default=".", help="repository root")
    parser.add_argument("--run-manifest", required=True, help="closed JSON run manifest for the executed journey")
    parser.add_argument("--output", required=True, help="redacted evidence output path under journeys/evidence/")
    parser.add_argument("--source-sha", required=True, help="candidate source commit the run exercised")
    parser.add_argument("--operator-role", required=True)
    parser.add_argument("--operator-identity-fingerprint", required=True, help="sha256 hex fingerprint")
    parser.add_argument("--hardware-profile", required=True)
    parser.add_argument("--candidate", required=True, help="candidate build/release label")
    parser.add_argument("--summary", required=True, help="one-line result summary")
    parser.add_argument("--captured-at", default=None, help="UTC capture timestamp, e.g. 2026-09-08T00:00:00Z")
    parser.add_argument("--expires-at", default=None, help="evidence expiry date, defaults to capture date + 30 days")
    parser.add_argument(
        "--run-hermetic-harness",
        action="store_true",
        help=f"run {HARNESS_PATH} first and refuse to capture unless it passes",
    )
    args = parser.parse_args(argv)

    root = Path(args.root).resolve()
    if args.run_hermetic_harness:
        run_hermetic_harness(root)

    try:
        contract = contract_for(args.journey)
        output = repository_relative(root, args.output, "--output")
        if not output.startswith(contract.evidence_prefix) or not output.endswith(".redacted.json"):
            die(f"--output must be {contract.evidence_prefix}*.redacted.json")
        evidence = build_evidence(
            root,
            contract,
            Path(args.run_manifest).resolve(),
            source_sha=args.source_sha,
            operator_role=args.operator_role,
            operator_identity_fingerprint=args.operator_identity_fingerprint,
            hardware_profile=args.hardware_profile,
            candidate=args.candidate,
            captured_at=args.captured_at,
            expires_at=args.expires_at,
            summary=args.summary,
        )
        write_json_atomically(root / output, evidence)
    except BYOMEvidenceError as exc:
        die(str(exc))
    print(f"capture-byom-journey-evidence: wrote {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
