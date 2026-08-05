#!/usr/bin/env python3
"""Validate redacted provider-prebeta evidence before commit and signing."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import sys
from datetime import date
from pathlib import Path
from types import ModuleType
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
BUILDER = SCRIPT_DIR / "build-provider-prebeta-journey-result.py"
PREFLIGHT = SCRIPT_DIR / "preflight-signed-journey-promotion.py"


def die(message: str) -> None:
    print(f"validate-provider-prebeta-evidence: {message}", file=sys.stderr)
    raise SystemExit(1)


def load_builder() -> ModuleType:
    spec = importlib.util.spec_from_file_location("build_provider_prebeta_journey_result", BUILDER)
    if spec is None or spec.loader is None:
        die("could not load provider-prebeta journey-result builder")
    module = importlib.util.module_from_spec(spec)
    sys.path.insert(0, str(SCRIPT_DIR))
    try:
        spec.loader.exec_module(module)
    finally:
        sys.path.pop(0)
    return module


def load_preflight() -> ModuleType:
    spec = importlib.util.spec_from_file_location("preflight_signed_journey_promotion", PREFLIGHT)
    if spec is None or spec.loader is None:
        die("could not load signed journey-result promotion preflight")
    module = importlib.util.module_from_spec(spec)
    sys.path.insert(0, str(SCRIPT_DIR))
    try:
        spec.loader.exec_module(module)
    finally:
        sys.path.pop(0)
    return module


def assert_current_selectors(builder: ModuleType, preflight: ModuleType, root: Path, source_sha: str, requirement_ids: list[str]) -> None:
    conformance = builder.load_object(root / "specs" / "CONFORMANCE.json", "spec conformance")
    requirements = conformance.get("requirements")
    if not isinstance(requirements, list):
        die("specs/CONFORMANCE.json requirements must be an array")
    errors: list[str] = []
    for requirement_id in requirement_ids:
        matches = [
            item
            for item in requirements
            if isinstance(item, dict) and item.get("requirement_id") == requirement_id
        ]
        if len(matches) != 1:
            errors.append(f"{requirement_id}: requirement must exist exactly once")
            continue
        errors.extend(
            preflight.assert_commit_matches_current_selectors(
                root,
                matches[0],
                source_sha,
                location=requirement_id,
            )
        )
    if errors:
        for error in errors:
            print(f"error: {error}", file=sys.stderr)
        die("current selector validation rejected")


def validate_redacted_evidence(
    builder: ModuleType,
    preflight: ModuleType,
    root: Path,
    source: str,
    *,
    source_sha: str | None,
    requirement_ids: str | None,
) -> dict[str, Any]:
    source, path = builder.require_evidence_source(root, source)
    evidence, evidence_bytes = builder.load_object_bytes(path, "provider-prebeta redacted evidence")
    builder.reject_forbidden_secret_keys(evidence)
    if evidence.get("schema_version") != builder.EVIDENCE_SCHEMA:
        die(f"schema_version must equal {builder.EVIDENCE_SCHEMA!r}")
    if evidence.get("journey_id") != builder.JOURNEY_ID:
        die(f"journey_id must equal {builder.JOURNEY_ID!r}")

    repository = builder.require_object(evidence.get("repository"), "repository")
    if repository.get("name") != builder.REPOSITORY:
        die(f"repository.name must equal {builder.REPOSITORY!r}")
    evidence_source_sha = builder.require_string(repository.get("commit"), builder.COMMIT_RE, "repository.commit")
    builder.require_reachable_commit(root, evidence_source_sha, "repository.commit")
    if source_sha is not None:
        builder.require_string(source_sha, builder.COMMIT_RE, "--source-sha")
        builder.require_reachable_commit(root, source_sha, "--source-sha")
        if evidence_source_sha != source_sha:
            die("repository.commit must exactly match --source-sha")

    selected_requirements = builder.parse_requirement_ids(requirement_ids, evidence)
    mapped = builder.load_mapped_provider_requirements(root)
    not_mapped = [item for item in selected_requirements if item not in mapped]
    if not_mapped:
        die(f"requirement_ids must be pending and mapped to {builder.JOURNEY_ID}: {', '.join(not_mapped)}")
    assert_current_selectors(builder, preflight, root, evidence_source_sha, selected_requirements)

    captured_at = builder.require_string(evidence.get("captured_at"), builder.DATETIME_Z_RE, "captured_at")
    expires_at = builder.require_string(evidence.get("expires_at"), builder.DATE_RE, "expires_at")
    if date.fromisoformat(expires_at) < date.today():
        die("expires_at must not be in the past")
    operator = builder.require_object(evidence.get("operator"), "operator")
    builder.require_string(operator.get("role"), None, "operator.role")
    builder.require_string(operator.get("identity_fingerprint"), builder.FINGERPRINT_RE, "operator.identity_fingerprint")
    environment = builder.require_object(evidence.get("environment"), "environment")
    for field in ("class", "hardware_profile", "candidate"):
        builder.require_string(environment.get(field), None, f"environment.{field}")
    result = builder.require_object(evidence.get("result"), "result")
    if result.get("status") != "pass":
        die("result.status must equal 'pass'")
    if "summary" in result:
        builder.require_string(result.get("summary"), None, "result.summary")
    builder.require_steps(evidence.get("steps"))
    builder.require_redaction(evidence.get("redaction"))
    run_id = builder.require_string(evidence.get("run_id"), None, "run_id")

    return {
        "source": source,
        "path": path,
        "artifact_sha256": hashlib.sha256(evidence_bytes).hexdigest(),
        "repository_commit": evidence_source_sha,
        "captured_at": captured_at,
        "expires_at": expires_at,
        "requirement_ids": selected_requirements,
        "run_id": run_id,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("redacted_evidence_source", help="journeys/evidence/provider-prebeta-admission-*.redacted.json")
    parser.add_argument("--root", default=".", help="repository root")
    parser.add_argument("--source-sha", default=None, help="expected source/build commit captured by the evidence")
    parser.add_argument("--requirement-ids", default=None, help="comma-separated pending requirement IDs to validate")
    args = parser.parse_args(argv)

    root = Path(args.root).resolve()
    builder = load_builder()
    preflight = load_preflight()
    summary = validate_redacted_evidence(
        builder,
        preflight,
        root,
        args.redacted_evidence_source,
        source_sha=args.source_sha,
        requirement_ids=args.requirement_ids,
    )
    print(
        "validate-provider-prebeta-evidence: ok: "
        f"{len(summary['requirement_ids'])} requirement(s), "
        f"source={summary['source']}, "
        f"commit={summary['repository_commit']}, "
        f"sha256={summary['artifact_sha256']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
