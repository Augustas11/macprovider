#!/usr/bin/env python3
"""Promote a requirement only when its signed journey-result validates.

JOURNEY-TRUSTED-POOL-CREATOR-MVP stays evidence-only until a sibling
PoolPromotionTransitionV1 is consumed into the SPEC-043 promotion ledger.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import tempfile
from copy import deepcopy
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from check_spec_governance import (
    JOURNEY_RESULT_ENVELOPE_SCHEMA,
    JOURNEY_RESULT_PUBLIC_KEY_SHA256,
    TRUSTED_POOL_CREATOR_MVP_JOURNEY_ID,
    TRUSTED_POOL_LAYER2_JOURNEY_ID,
    ValidationResult,
    _load_json,
    _source_under_journey_evidence,
    _validate_signed_journey_result,
    resolve_trusted_openssl,
    validate_repository,
)
from pool_promotion_transition import (
    consume_pool_promotion_transition,
    load_json_object as load_promotion_json_object,
    validate_pool_promotion_transition,
)


def die(message: str) -> None:
    print(f"promote-signed-journey-result: {message}", file=sys.stderr)
    raise SystemExit(1)


def load_json_object(path: Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        die(f"cannot read {label}: {exc}")
    except json.JSONDecodeError as exc:
        die(f"{label} is not valid JSON: {exc}")
    if not isinstance(value, dict):
        die(f"{label} must be a JSON object")
    return value


def write_json_atomically(path: Path, value: dict[str, Any]) -> None:
    payload = json.dumps(value, indent=2, sort_keys=False) + "\n"
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent, prefix=f".{path.name}.", delete=False) as handle:
        temporary = Path(handle.name)
        handle.write(payload)
    try:
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def require_relative_evidence_source(source: str) -> str:
    candidate = Path(source)
    if candidate.is_absolute():
        die("signed evidence source must be repository-relative")
    normalized = candidate.as_posix()
    if normalized.startswith("../") or "/../" in normalized or normalized == "..":
        die("signed evidence source must not contain parent traversal")
    return normalized


def require_signed_metadata(root: Path, source: str) -> tuple[str, str, str, str]:
    if not _source_under_journey_evidence(root, source):
        die("signed evidence source must be under journeys/evidence/")
    envelope = load_json_object(root / source, "signed journey-result")
    if envelope.get("schema_version") != JOURNEY_RESULT_ENVELOPE_SCHEMA:
        die(f"signed evidence must use schema_version {JOURNEY_RESULT_ENVELOPE_SCHEMA!r}")
    signed = envelope.get("signed")
    if not isinstance(signed, dict):
        die("signed evidence must contain a signed object")
    repository = signed.get("repository")
    if not isinstance(repository, dict) or not isinstance(repository.get("commit"), str):
        die("signed evidence must bind repository.commit")
    journey_id = signed.get("journey_id")
    if not isinstance(journey_id, str):
        die("signed evidence must bind journey_id")
    captured_at = signed.get("captured_at")
    expires_at = signed.get("expires_at")
    if not isinstance(captured_at, str) or len(captured_at) < 10:
        die("signed evidence must bind captured_at")
    if not isinstance(expires_at, str):
        die("signed evidence must bind expires_at")
    return repository["commit"], captured_at[:10], expires_at, journey_id


def require_valid_signed_result(
    root: Path,
    requirement: dict[str, Any],
    evidence_source: str,
    commit: str,
    trusted_public_key_sha256: str,
    openssl_bin: str,
) -> None:
    requirement_id = requirement.get("requirement_id")
    journeys = requirement.get("journeys")
    if not isinstance(requirement_id, str) or not isinstance(journeys, list):
        die("target requirement must contain requirement_id and journeys")
    result = ValidationResult()
    if not _validate_signed_journey_result(
        root,
        evidence_source,
        requirement_id,
        [item for item in journeys if isinstance(item, str)],
        {commit},
        trusted_public_key_sha256,
        openssl_bin,
        f"{requirement_id}.signed_journey_result",
        result,
    ):
        for error in result.errors:
            print(f"error: {error}", file=sys.stderr)
        die("signed journey-result rejected")


def upsert_evidence(existing: list[Any], record: dict[str, Any]) -> list[Any]:
    artifact = record["artifact"]
    source = record["source"]
    return [
        item
        for item in existing
        if not (
            isinstance(item, dict)
            and (item.get("artifact") == artifact or (source is not None and item.get("source") == source))
        )
    ] + [record]


def load_conformance(root: Path) -> dict[str, Any]:
    conformance_path = root / "specs" / "CONFORMANCE.json"
    load_result = ValidationResult()
    conformance = _load_json(conformance_path, load_result)
    if load_result.errors:
        for error in load_result.errors:
            print(f"error: {error}", file=sys.stderr)
        die("ledger promotion rejected")
    if not isinstance(conformance, dict):
        die("specs/CONFORMANCE.json must be a JSON object")
    requirements = conformance.get("requirements")
    if not isinstance(requirements, list):
        die("specs/CONFORMANCE.json requirements must be an array")
    return conformance


def promote_requirement_in_memory(
    root: Path,
    conformance: dict[str, Any],
    requirement_id: str,
    evidence_source: str,
    *,
    commit: str,
    captured_at: str,
    expires_at: str,
    journey_id: str,
    trusted_public_key_sha256: str,
    trusted_openssl: str,
) -> str:
    requirements = conformance.get("requirements")
    matches = [item for item in requirements if isinstance(item, dict) and item.get("requirement_id") == requirement_id]
    if len(matches) != 1:
        die(f"requirement must exist exactly once: {requirement_id}")
    requirement = matches[0]
    if journey_id == TRUSTED_POOL_LAYER2_JOURNEY_ID:
        die(f"{TRUSTED_POOL_LAYER2_JOURNEY_ID} is evidence-only and cannot promote full SPEC-042 requirement rows")
    require_valid_signed_result(root, requirement, evidence_source, commit, trusted_public_key_sha256, trusted_openssl)
    evidence_path = root / evidence_source
    digest = hashlib.sha256(evidence_path.read_bytes()).hexdigest()

    updated = deepcopy(requirement)
    evidence = updated.get("evidence")
    if not isinstance(evidence, list):
        evidence = []
    evidence = upsert_evidence(
        evidence,
        {
            "artifact": f"commit:{commit}",
            "source": None,
            "captured_at": captured_at,
            "expires_at": expires_at,
        },
    )
    evidence = upsert_evidence(
        evidence,
        {
            "artifact": f"sha256:{digest}",
            "source": evidence_source,
            "captured_at": captured_at,
            "expires_at": expires_at,
        },
    )
    updated["state"] = "conformant"
    updated["evidence"] = evidence
    updated["gap"] = None

    requirement.clear()
    requirement.update(updated)
    return digest


def consume_creator_mvp_transition(
    root: Path,
    evidence_source: str,
    promotion_transition: str,
    *,
    trusted_public_key_sha256: str,
    trusted_openssl: str,
    now: datetime | None,
    consume: bool = True,
) -> None:
    transition_source = require_relative_evidence_source(promotion_transition)
    if not transition_source.startswith("journeys/evidence/") or not transition_source.endswith(".json"):
        die("promotion transition source must be under journeys/evidence/")
    load_result = ValidationResult()
    envelope = load_promotion_json_object(root / transition_source, "PoolPromotionTransitionV1", load_result)
    candidate = load_promotion_json_object(root / evidence_source, "signed candidate journey-result", load_result)
    if load_result.errors or envelope is None or candidate is None:
        for error in load_result.errors:
            print(f"error: {error}", file=sys.stderr)
        die("PoolPromotionTransitionV1 rejected")
    if consume:
        outcome = consume_pool_promotion_transition(
            root,
            envelope,
            candidate,
            now=now,
            openssl_bin=trusted_openssl,
            trusted_journey_result_public_key_sha256=trusted_public_key_sha256,
            transition_source=transition_source,
        )
        fail_message = "PoolPromotionTransitionV1 must be consumed before SPEC-043 promotion"
    else:
        outcome = validate_pool_promotion_transition(
            root,
            envelope,
            candidate,
            now=now,
            openssl_bin=trusted_openssl,
            trusted_journey_result_public_key_sha256=trusted_public_key_sha256,
        )
        fail_message = "PoolPromotionTransitionV1 rejected"
    if outcome.errors:
        for error in outcome.errors:
            print(f"error: {error}", file=sys.stderr)
        die(fail_message)


def promote_many(
    root: Path,
    requirement_ids: list[str],
    evidence_source: str,
    *,
    base_ref: str,
    trusted_public_key_sha256: str = JOURNEY_RESULT_PUBLIC_KEY_SHA256,
    openssl_bin: str | None = None,
    promotion_transition: str | None = None,
    now: datetime | None = None,
) -> None:
    if not requirement_ids:
        die("at least one requirement ID is required")
    try:
        trusted_openssl = resolve_trusted_openssl(openssl_bin)
    except ValueError as exc:
        die(str(exc))
    evidence_source = require_relative_evidence_source(evidence_source)
    conformance_path = root / "specs" / "CONFORMANCE.json"
    conformance = load_conformance(root)
    commit, captured_at, expires_at, journey_id = require_signed_metadata(root, evidence_source)
    if journey_id == TRUSTED_POOL_CREATOR_MVP_JOURNEY_ID and not promotion_transition:
        die(f"{TRUSTED_POOL_CREATOR_MVP_JOURNEY_ID} is evidence-only and cannot promote full SPEC-043 requirement rows")
    if journey_id != TRUSTED_POOL_CREATOR_MVP_JOURNEY_ID and promotion_transition:
        die("--promotion-transition is only valid for JOURNEY-TRUSTED-POOL-CREATOR-MVP")
    if journey_id == TRUSTED_POOL_CREATOR_MVP_JOURNEY_ID:
        consume_creator_mvp_transition(
            root,
            evidence_source,
            promotion_transition or "",
            trusted_public_key_sha256=trusted_public_key_sha256,
            trusted_openssl=trusted_openssl,
            now=now,
            consume=False,
        )
    promoted: list[tuple[str, str]] = []
    for requirement_id in requirement_ids:
        digest = promote_requirement_in_memory(
            root,
            conformance,
            requirement_id,
            evidence_source,
            commit=commit,
            captured_at=captured_at,
            expires_at=expires_at,
            journey_id=journey_id,
            trusted_public_key_sha256=trusted_public_key_sha256,
            trusted_openssl=trusted_openssl,
        )
        promoted.append((requirement_id, digest))
    if journey_id == TRUSTED_POOL_CREATOR_MVP_JOURNEY_ID:
        consume_creator_mvp_transition(
            root,
            evidence_source,
            promotion_transition or "",
            trusted_public_key_sha256=trusted_public_key_sha256,
            trusted_openssl=trusted_openssl,
            now=now,
            consume=True,
        )
    result = validate_repository(root, base_ref, trusted_public_key_sha256, conformance_override=conformance, openssl_bin=trusted_openssl)
    if result.errors:
        for error in result.errors:
            print(f"error: {error}", file=sys.stderr)
        die("ledger promotion rejected")
    write_json_atomically(conformance_path, conformance)
    for requirement_id, digest in promoted:
        print(f"promote-signed-journey-result: promoted {requirement_id} with sha256:{digest}")


def promote(
    root: Path,
    requirement_id: str,
    evidence_source: str,
    *,
    base_ref: str,
    trusted_public_key_sha256: str = JOURNEY_RESULT_PUBLIC_KEY_SHA256,
    openssl_bin: str | None = None,
    promotion_transition: str | None = None,
    now: datetime | None = None,
) -> None:
    promote_many(
        root,
        [requirement_id],
        evidence_source,
        base_ref=base_ref,
        trusted_public_key_sha256=trusted_public_key_sha256,
        openssl_bin=openssl_bin,
        promotion_transition=promotion_transition,
        now=now,
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--requirement-ids", default=None, help="comma-separated requirement IDs to promote in one validation pass")
    parser.add_argument("requirement_id_or_evidence_source")
    parser.add_argument("evidence_source", nargs="?", help="signed journey-result path under journeys/evidence/")
    parser.add_argument("--root", default=".", help="repository root")
    parser.add_argument("--base-ref", required=True, help="trusted base ref for governance validation")
    parser.add_argument("--openssl-bin", default=None, help="absolute path to trusted OpenSSL")
    parser.add_argument(
        "--promotion-transition",
        default=None,
        help="sibling PoolPromotionTransitionV1 path under journeys/evidence/; required for JOURNEY-TRUSTED-POOL-CREATOR-MVP",
    )
    parser.add_argument("--now", default=None, help="UTC now override for promotion-authorization expiry, like 2026-08-25T12:00:00Z")
    args = parser.parse_args(argv)

    if args.requirement_ids is None:
        if args.evidence_source is None:
            parser.error("evidence_source is required")
        requirement_ids = [args.requirement_id_or_evidence_source]
        evidence_source = args.evidence_source
    else:
        if args.evidence_source is not None:
            parser.error("--requirement-ids expects a single evidence_source positional")
        requirement_ids = [item for item in args.requirement_ids.split(",") if item]
        evidence_source = args.requirement_id_or_evidence_source
    now = None
    if args.now:
        try:
            now = datetime.strptime(args.now, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        except ValueError:
            die("--now must be UTC like 2026-08-25T12:00:00Z")
    promote_many(
        Path(args.root).resolve(),
        requirement_ids,
        evidence_source,
        base_ref=args.base_ref,
        openssl_bin=args.openssl_bin,
        promotion_transition=args.promotion_transition,
        now=now,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
