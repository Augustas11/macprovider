#!/usr/bin/env python3
"""Build JOURNEY-PRIVACY-CLASS-BETA evidence and unsigned journey-result payloads.

  build-privacy-class-beta-journey-result.py compose-evidence BUNDLE_DIR --output EVIDENCE
      Recompute the closed privacy-class beta evidence object selected by
      --profile (default v1; v2 must be requested explicitly)
      from a reviewed redacted bundle (`journeys/evidence/privacy-class-beta-<ts>/`).

  build-privacy-class-beta-journey-result.py --source-sha SHA --evidence-sha SHA \\
      --output PAYLOAD journeys/evidence/privacy-class-beta-<ts>.redacted.json
      Validate the committed evidence against its bundle at --evidence-sha and
      write the unsigned journey-result payload that `sign-journey-result.py`
      signs. This script never touches signing material.

The contract lives in `scripts/privacy_class_beta_journey_evidence.py`.
"""

from __future__ import annotations

import argparse
import json
import sys
import tempfile
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

import privacy_class_beta_journey_evidence as contract  # noqa: E402


PROG = "build-privacy-class-beta-journey-result"


def die(message: str) -> None:
    print(f"{PROG}: {message}", file=sys.stderr)
    raise SystemExit(1)


def write_json_atomically(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and path.is_symlink():
        die(f"output must not be a symlink: {path}")
    payload = json.dumps(value, indent=2, sort_keys=False) + "\n"
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent, prefix=f".{path.name}.", delete=False) as handle:
        temporary = Path(handle.name)
        handle.write(payload)
    try:
        temporary.replace(path)
    finally:
        if temporary.exists():
            temporary.unlink()


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv[:1] == ["compose-evidence"]:
        parser = argparse.ArgumentParser(prog=f"{PROG} compose-evidence")
        parser.add_argument("bundle_dir", help="journeys/evidence/privacy-class-beta-<YYYYMMDDTHHMMSSZ>")
        parser.add_argument("--root", default=".", help="repository root")
        parser.add_argument("--output", required=True, help="redacted evidence output path")
        parser.add_argument("--expires-at", default=None, help="RFC3339 UTC expiry, default captured_at + 90 days")
        parser.add_argument("--profile", choices=("v1", "v2"), default="v1", help="evidence profile; v2 is never inferred from bundle contents")
        args = parser.parse_args(argv[1:])
        root = Path(args.root).resolve()
        bundle_dir = args.bundle_dir.rstrip("/")
        try:
            evidence = contract.compose_evidence(root, bundle_dir, expires_at=args.expires_at, profile=args.profile)
            output = f"{bundle_dir}{contract.EVIDENCE_SUFFIX}"
            contract.bundle_dir_for_source(output)
        except contract.PrivacyEvidenceError as exc:
            die(str(exc))
        target = Path(args.output)
        if not target.is_absolute():
            target = root / target
        write_json_atomically(target, evidence)
        print(f"{PROG}: wrote {target}")
        return 0

    parser = argparse.ArgumentParser(prog=PROG, description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("redacted_evidence_source", help="journeys/evidence/privacy-class-beta-*.redacted.json")
    parser.add_argument("--root", default=".", help="repository root")
    parser.add_argument("--output", required=True, help="unsigned journey-result payload output path")
    parser.add_argument("--source-sha", required=True, help="coordinator/gateway source commit bound by step-01")
    parser.add_argument("--evidence-sha", required=True, help="reviewed commit containing the evidence and bundle")
    args = parser.parse_args(argv)
    root = Path(args.root).resolve()
    try:
        payload = contract.build_payload(root, args.redacted_evidence_source, source_sha=args.source_sha, evidence_sha=args.evidence_sha)
    except contract.PrivacyEvidenceError as exc:
        die(str(exc))
    output = Path(args.output)
    if not output.is_absolute():
        output = root / output
    write_json_atomically(output, payload)
    print(f"{PROG}: wrote {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
