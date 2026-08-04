#!/usr/bin/env python3
"""Promote a requirement only when its signed journey-result validates."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import tempfile
from copy import deepcopy
from pathlib import Path
from typing import Any

from check_spec_governance import (
    JOURNEY_RESULT_ENVELOPE_SCHEMA,
    JOURNEY_RESULT_PUBLIC_KEY_SHA256,
    ValidationResult,
    _load_json,
    _source_under_journey_evidence,
    _validate_signed_journey_result,
    resolve_trusted_openssl,
    validate_repository,
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


def require_signed_metadata(root: Path, source: str) -> tuple[str, str, str]:
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
    captured_at = signed.get("captured_at")
    expires_at = signed.get("expires_at")
    if not isinstance(captured_at, str) or len(captured_at) < 10:
        die("signed evidence must bind captured_at")
    if not isinstance(expires_at, str):
        die("signed evidence must bind expires_at")
    return repository["commit"], captured_at[:10], expires_at


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


def promote(
    root: Path,
    requirement_id: str,
    evidence_source: str,
    *,
    base_ref: str,
    trusted_public_key_sha256: str = JOURNEY_RESULT_PUBLIC_KEY_SHA256,
    openssl_bin: str | None = None,
) -> None:
    try:
        trusted_openssl = resolve_trusted_openssl(openssl_bin)
    except ValueError as exc:
        die(str(exc))
    evidence_source = require_relative_evidence_source(evidence_source)
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

    matches = [item for item in requirements if isinstance(item, dict) and item.get("requirement_id") == requirement_id]
    if len(matches) != 1:
        die(f"requirement must exist exactly once: {requirement_id}")
    requirement = matches[0]
    commit, captured_at, expires_at = require_signed_metadata(root, evidence_source)
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
    result = validate_repository(root, base_ref, trusted_public_key_sha256, conformance_override=conformance, openssl_bin=trusted_openssl)
    if result.errors:
        for error in result.errors:
            print(f"error: {error}", file=sys.stderr)
        die("ledger promotion rejected")

    write_json_atomically(conformance_path, conformance)
    print(f"promote-signed-journey-result: promoted {requirement_id} with sha256:{digest}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("requirement_id")
    parser.add_argument("evidence_source", help="signed journey-result path under journeys/evidence/")
    parser.add_argument("--root", default=".", help="repository root")
    parser.add_argument("--base-ref", required=True, help="trusted base ref for governance validation")
    parser.add_argument("--openssl-bin", default=None, help="absolute path to trusted OpenSSL")
    args = parser.parse_args(argv)

    promote(Path(args.root).resolve(), args.requirement_id, args.evidence_source, base_ref=args.base_ref, openssl_bin=args.openssl_bin)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
