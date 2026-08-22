#!/usr/bin/env python3
"""Validate a signed journey-result envelope without promoting conformance."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any

from check_spec_governance import (
    JOURNEY_RESULT_PUBLIC_KEY_SHA256,
    ValidationResult,
    _load_json,
    _source_under_journey_evidence,
    _validate_signed_journey_result,
    resolve_trusted_openssl,
)


REQUIREMENT_RE = re.compile(r"^SPEC-[0-9]{3}-R[0-9]{3}$")


def die(message: str) -> None:
    print(f"validate-signed-journey-result: {message}", file=sys.stderr)
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


def require_relative_evidence_source(source: str) -> str:
    candidate = Path(source)
    if candidate.is_absolute():
        die("signed evidence source must be repository-relative")
    normalized = candidate.as_posix()
    if normalized.startswith("../") or "/../" in normalized or normalized == "..":
        die("signed evidence source must not contain parent traversal")
    return normalized


def parse_requirement_ids(raw: str) -> list[str]:
    values = [item.strip() for item in raw.split(",") if item.strip()]
    if not values:
        die("--requirement-ids must not be empty")
    if len(set(values)) != len(values):
        die("--requirement-ids must be unique")
    invalid = [item for item in values if not REQUIREMENT_RE.fullmatch(item)]
    if invalid:
        die(f"invalid requirement id(s): {', '.join(invalid)}")
    return values


def load_requirement_rows(root: Path, requirement_ids: list[str]) -> list[dict[str, Any]]:
    result = ValidationResult()
    conformance = _load_json(root / "specs" / "CONFORMANCE.json", result)
    if result.errors:
        for error in result.errors:
            print(f"error: {error}", file=sys.stderr)
        die("spec conformance rejected")
    if not isinstance(conformance, dict) or not isinstance(conformance.get("requirements"), list):
        die("specs/CONFORMANCE.json requirements must be an array")
    output: list[dict[str, Any]] = []
    for requirement_id in requirement_ids:
        matches = [
            item
            for item in conformance["requirements"]
            if isinstance(item, dict) and item.get("requirement_id") == requirement_id
        ]
        if len(matches) != 1:
            die(f"requirement must exist exactly once: {requirement_id}")
        output.append(matches[0])
    return output


def validate(
    root: Path,
    evidence_source: str,
    requirement_ids: list[str],
    *,
    trusted_public_key_sha256: str,
    openssl_bin: str | None,
) -> None:
    try:
        trusted_openssl = resolve_trusted_openssl(openssl_bin)
    except ValueError as exc:
        die(str(exc))
    evidence_source = require_relative_evidence_source(evidence_source)
    if not _source_under_journey_evidence(root, evidence_source):
        die("signed evidence source must be under journeys/evidence/")
    envelope = load_json_object(root / evidence_source, "signed journey-result")
    signed = envelope.get("signed")
    if not isinstance(signed, dict):
        die("signed evidence must contain a signed object")
    repository = signed.get("repository")
    if not isinstance(repository, dict) or not isinstance(repository.get("commit"), str):
        die("signed evidence must bind repository.commit")
    commit = repository["commit"]
    rows = load_requirement_rows(root, requirement_ids)
    errors: list[str] = []
    for requirement in rows:
        requirement_id = requirement.get("requirement_id")
        journeys = requirement.get("journeys")
        if not isinstance(requirement_id, str) or not isinstance(journeys, list):
            errors.append("target requirement must contain requirement_id and journeys")
            continue
        result = ValidationResult()
        if not _validate_signed_journey_result(
            root,
            evidence_source,
            requirement_id,
            [item for item in journeys if isinstance(item, str)],
            {commit},
            trusted_public_key_sha256,
            trusted_openssl,
            f"{requirement_id}.signed_journey_result",
            result,
        ):
            errors.extend(result.errors)
    if errors:
        for error in errors:
            print(f"error: {error}", file=sys.stderr)
        die("signed journey-result rejected")
    print(f"validate-signed-journey-result: validated {len(rows)} requirement(s) without promotion")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("signed_evidence_source", help="signed envelope under journeys/evidence/")
    parser.add_argument("--root", default=".", help="repository root")
    parser.add_argument("--requirement-ids", required=True, help="comma-separated requirement IDs to validate")
    parser.add_argument("--trusted-public-key-sha256", default=JOURNEY_RESULT_PUBLIC_KEY_SHA256)
    parser.add_argument("--openssl-bin", default=None, help="absolute path to trusted OpenSSL")
    args = parser.parse_args(argv)
    validate(
        Path(args.root).resolve(),
        args.signed_evidence_source,
        parse_requirement_ids(args.requirement_ids),
        trusted_public_key_sha256=args.trusted_public_key_sha256,
        openssl_bin=args.openssl_bin,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
