#!/usr/bin/env python3
"""Build native-MTP journey evidence and unsigned journey-result payloads.

  build-native-mtp-journey-result.py compose-evidence serving BUNDLE_DIR --captured-at TS --output EVIDENCE
  build-native-mtp-journey-result.py compose-evidence release BUNDLE_DIR --captured-at TS \\
      --release-id ID --base-commit SHA --head-commit SHA --target-commit SHA --build-sha256 HEX --output EVIDENCE
      Recompute the closed evidence object from a reviewed redacted bundle
      (`journeys/evidence/native-mtp-<serving|release>-<ts>/`).

  build-native-mtp-journey-result.py payload serving|release EVIDENCE --source-sha SHA --evidence-sha SHA --output PAYLOAD
      Validate committed evidence against its bundle at --evidence-sha and write
      the unsigned journey-result payload `sign-journey-result.py` signs. This
      script never touches signing material.

The contract lives in `scripts/native_mtp_journey_evidence.py`.
"""

from __future__ import annotations

import argparse
import json
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import native_mtp_journey_evidence as contract  # noqa: E402

PROG = "build-native-mtp-journey-result"


def write_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_symlink():
        raise contract.NativeMTPEvidenceError(f"output must not be a symlink: {path}")
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent, prefix=f".{path.name}.", delete=False) as handle:
        handle.write(json.dumps(value, indent=2) + "\n")
        temporary = Path(handle.name)
    temporary.replace(path)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog=PROG, description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", default=".", help="repository root")
    sub = parser.add_subparsers(dest="command", required=True)
    compose = sub.add_parser("compose-evidence")
    compose.add_argument("kind", choices=[contract.SERVING, contract.RELEASE])
    compose.add_argument("bundle_dir")
    compose.add_argument("--captured-at", required=True)
    compose.add_argument("--expires-at")
    compose.add_argument("--release-id")
    compose.add_argument("--base-commit")
    compose.add_argument("--head-commit")
    compose.add_argument("--target-commit")
    compose.add_argument("--build-sha256")
    compose.add_argument("--output", required=True)
    payload = sub.add_parser("payload")
    payload.add_argument("kind", choices=[contract.SERVING, contract.RELEASE])
    payload.add_argument("evidence")
    payload.add_argument("--source-sha", required=True)
    payload.add_argument("--evidence-sha", required=True)
    payload.add_argument("--output", required=True)
    args = parser.parse_args(argv)
    root = Path(args.root).resolve()
    try:
        if args.command == "compose-evidence":
            bundle_dir = args.bundle_dir.rstrip("/")
            contract.bundle_dir_for_source(args.kind, bundle_dir + contract.EVIDENCE_SUFFIX)
            bundle = contract.load_bundle(root, bundle_dir)
            if args.kind == contract.SERVING:
                value = contract.compose_serving(bundle, captured_at=args.captured_at, expires_at=args.expires_at)
            else:
                missing = [flag for flag in ("release_id", "base_commit", "head_commit", "target_commit", "build_sha256") if not getattr(args, flag)]
                if missing:
                    raise contract.NativeMTPEvidenceError(f"release evidence needs --{', --'.join(m.replace('_', '-') for m in missing)}")
                value = contract.compose_release(
                    root, bundle, captured_at=args.captured_at, expires_at=args.expires_at,
                    release_id=args.release_id, base_commit=args.base_commit, head_commit=args.head_commit,
                    target_commit=args.target_commit, build_sha256=args.build_sha256,
                )
                contract.validate_release_git(root, value)
            target = Path(args.output) if Path(args.output).is_absolute() else root / args.output
        else:
            value = contract.build_payload(root, args.kind, args.evidence, source_sha=args.source_sha, evidence_sha=args.evidence_sha)
            target = Path(args.output) if Path(args.output).is_absolute() else root / args.output
    except contract.NativeMTPEvidenceError as exc:
        print(f"{PROG}: {exc}", file=sys.stderr)
        return 1
    write_json(target, value)
    print(f"{PROG}: wrote {target}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
