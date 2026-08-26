#!/usr/bin/env python3
"""Build an unsigned PoolPromotionTransitionV1 payload from a signed candidate envelope.

The builder copies candidate identity fields and requires operator-supplied
production activation fields. It never signs, never consumes the ledger, and
never mutates CONFORMANCE.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

from pool_promotion_transition import (
    MAX_AUTHORIZATION_TTL,
    build_pool_promotion_transition_payload,
    load_json_object,
)
from check_spec_governance import ValidationResult


def die(message: str) -> None:
    print(f"build-pool-promotion-transition: {message}", file=sys.stderr)
    raise SystemExit(1)


def utc_now() -> datetime:
    return datetime.now(timezone.utc).replace(microsecond=0)


def format_utc(value: datetime) -> str:
    return value.strftime("%Y-%m-%dT%H:%M:%SZ")


def _is_under(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
        return True
    except ValueError:
        return False


def resolve_unsigned_output_path(root: Path, output: str) -> Path:
    output_path = Path(output)
    if not output_path.is_absolute():
        output_path = root / output_path
    resolved = output_path.resolve(strict=False)
    forbidden_outputs = {
        (root / "specs" / "CONFORMANCE.json").resolve(strict=False),
        (root / "journeys" / "ledgers" / "spec-043-promotion-auth.jsonl").resolve(strict=False),
        (root / "security" / "spec-043-production-release-keyring.json").resolve(strict=False),
    }
    if resolved in forbidden_outputs:
        die("output must not target CONFORMANCE, the promotion ledger, or the production-release keyring")
    if _is_under(resolved, root):
        return output_path
    runner_temp = os.environ.get("RUNNER_TEMP")
    if runner_temp:
        temp_root = Path(runner_temp).resolve(strict=False)
        if len(temp_root.parts) > 1 and _is_under(resolved, temp_root):
            return output_path
    die("output must be inside the repository root or RUNNER_TEMP")
    raise AssertionError("unreachable")


def write_json_atomically(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.parent.is_symlink():
        die(f"output parent must not be a symlink: {path.parent}")
    payload = json.dumps(value, indent=2, sort_keys=False) + "\n"
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent, prefix=f".{path.name}.", delete=False) as handle:
        temporary = Path(handle.name)
        handle.write(payload)
    try:
        if path.exists() and path.is_symlink():
            die(f"output must not be a symlink: {path}")
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=".", help="repository root")
    parser.add_argument("--candidate", required=True, help="signed JOURNEY-TRUSTED-POOL-CREATOR-MVP envelope")
    parser.add_argument("--output", required=True, help="unsigned payload output path")
    parser.add_argument("--live-activation-target", required=True)
    parser.add_argument("--schema-migration-hash", required=True)
    parser.add_argument("--approval-record-version", required=True, type=int)
    parser.add_argument("--creator-agreement-version", required=True, type=int)
    parser.add_argument("--pricing-schedule-version", required=True, type=int)
    parser.add_argument("--authorization-id", required=True)
    parser.add_argument("--authorized-actor", required=True)
    parser.add_argument("--credential-id", required=True)
    parser.add_argument("--authorized-at", default=None)
    parser.add_argument("--expiry", default=None)
    parser.add_argument("--transition-epoch", default=None, type=int)
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args(argv)

    root = Path(args.root).resolve()
    candidate_path = Path(args.candidate)
    if not candidate_path.is_absolute():
        candidate_path = root / candidate_path
    output_path = resolve_unsigned_output_path(root, args.output)
    if output_path.exists() and not args.force:
        die(f"output already exists: {output_path}")

    load_result = ValidationResult()
    candidate = load_json_object(candidate_path, "candidate", load_result)
    if candidate is None:
        for error in load_result.errors:
            print(f"error: {error}", file=sys.stderr)
        return 1

    now = utc_now()
    authorized_at = args.authorized_at or format_utc(now)
    expiry = args.expiry or format_utc(now + timedelta(hours=23))
    if MAX_AUTHORIZATION_TTL < timedelta(hours=23):
        die("authorization TTL constant drifted below the builder default")

    payload, outcome = build_pool_promotion_transition_payload(
        root,
        candidate,
        live_activation_target=args.live_activation_target,
        schema_migration_hash=args.schema_migration_hash,
        approval_record_version=args.approval_record_version,
        creator_agreement_version=args.creator_agreement_version,
        pricing_schedule_version=args.pricing_schedule_version,
        authorization_id=args.authorization_id,
        authorized_actor=args.authorized_actor,
        credential_id=args.credential_id,
        authorized_at=authorized_at,
        expiry=expiry,
        transition_epoch=args.transition_epoch,
    )
    errors = list(load_result.errors) + list(outcome.errors)
    if payload is None or errors:
        for error in errors:
            print(f"error: {error}", file=sys.stderr)
        return 1
    write_json_atomically(output_path, payload)
    try:
        printed = output_path.relative_to(root)
    except ValueError:
        printed = output_path
    print(f"build-pool-promotion-transition: wrote {printed}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
