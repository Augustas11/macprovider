#!/usr/bin/env python3
"""Reject stale journey-result promotions before signing."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

from check_spec_governance import (
    LOCAL_CONSUMER_ENDPOINT_EVIDENCE_CONTROL_IMPLEMENTATION_MAPPINGS,
    LOCAL_CONSUMER_ENDPOINT_JOURNEY_ID,
    ValidationResult,
    _commit_mapping_selector_matches_current,
    _load_json,
    _mapping_file,
    _mapping_selector,
)


COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
REQUIREMENT_RE = re.compile(r"^SPEC-[0-9]{3}-R[0-9]{3}$")
JOURNEY_EVIDENCE_CONTROL_MAPPINGS = {
    LOCAL_CONSUMER_ENDPOINT_JOURNEY_ID: LOCAL_CONSUMER_ENDPOINT_EVIDENCE_CONTROL_IMPLEMENTATION_MAPPINGS,
}


def die(message: str) -> None:
    print(f"preflight-signed-journey-promotion: {message}", file=sys.stderr)
    raise SystemExit(1)


def load_object(path: Path, label: str) -> dict[str, Any]:
    result = ValidationResult()
    value = _load_json(path, result)
    if result.errors:
        for error in result.errors:
            print(f"error: {error}", file=sys.stderr)
        die(f"{label} rejected")
    if not isinstance(value, dict):
        die(f"{label} must be a JSON object")
    return value


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


def require_reachable_commit(root: Path, commit: str, label: str = "--source-sha") -> None:
    completed = subprocess.run(
        ["git", "cat-file", "-e", f"{commit}^{{commit}}"],
        cwd=root,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if completed.returncode != 0:
        die(f"{label} is not reachable: {commit}")


def require_ancestor_commit(root: Path, ancestor: str, descendant: str) -> None:
    completed = subprocess.run(
        ["git", "merge-base", "--is-ancestor", ancestor, descendant],
        cwd=root,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if completed.returncode != 0:
        die("--source-sha must be an ancestor of --evidence-sha")


def assert_commit_matches_current_selectors(
    root: Path,
    requirement: dict[str, Any],
    source_sha: str,
    *,
    location: str,
    evidence_sha: str | None = None,
    evidence_control_mappings: frozenset[str] = frozenset(),
) -> list[str]:
    errors: list[str] = []
    for key in ("implementation", "tests"):
        values = requirement.get(key)
        if not isinstance(values, list):
            continue
        for mapping in (item for item in values if isinstance(item, str)):
            selector_commit = (
                evidence_sha
                if key == "implementation" and mapping in evidence_control_mappings and evidence_sha is not None
                else source_sha
            )
            if not _commit_mapping_selector_matches_current(root, selector_commit, mapping):
                errors.append(
                    f"{location}: commit evidence {selector_commit} does not match current mapped selector "
                    f"fragment {_mapping_selector(mapping)!r} in {_mapping_file(mapping)!r}"
                )
    if not any(isinstance(requirement.get(key), list) and requirement[key] for key in ("implementation", "tests")):
        errors.append(f"{location}: no implementation/test mappings to prove against {source_sha}")
    return errors


def preflight(
    root: Path,
    source_sha: str,
    requirement_ids: list[str],
    journey_id: str | None,
    *,
    evidence_sha: str | None = None,
) -> None:
    if not COMMIT_RE.fullmatch(source_sha):
        die("--source-sha must be a 40-character lowercase hex commit")
    require_reachable_commit(root, source_sha)
    evidence_control_mappings = JOURNEY_EVIDENCE_CONTROL_MAPPINGS.get(journey_id, frozenset())
    if evidence_control_mappings and evidence_sha is None:
        die(f"--evidence-sha is required for {journey_id} evidence-control selectors")
    if evidence_sha is not None:
        if not COMMIT_RE.fullmatch(evidence_sha):
            die("--evidence-sha must be a 40-character lowercase hex commit")
        require_reachable_commit(root, evidence_sha, "--evidence-sha")
        require_ancestor_commit(root, source_sha, evidence_sha)
    conformance = load_object(root / "specs" / "CONFORMANCE.json", "spec conformance")
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
        location = requirement_id
        if len(matches) != 1:
            errors.append(f"{location}: requirement must exist exactly once")
            continue
        requirement = matches[0]
        if requirement.get("state") != "pending":
            errors.append(f"{location}: requirement must still be pending before promotion")
        journeys = requirement.get("journeys")
        if journey_id is not None:
            if not isinstance(journeys, list) or journey_id not in journeys:
                errors.append(f"{location}: requirement is not mapped to {journey_id}")
        errors.extend(
            assert_commit_matches_current_selectors(
                root,
                requirement,
                source_sha,
                location=location,
                evidence_sha=evidence_sha,
                evidence_control_mappings=evidence_control_mappings,
            )
        )

    if errors:
        for error in errors:
            print(f"error: {error}", file=sys.stderr)
        die("promotion preflight rejected")
    if evidence_control_mappings:
        print(
            "preflight-signed-journey-promotion: "
            f"{len(requirement_ids)} requirement(s) match source selectors at {source_sha} "
            f"and evidence controls at {evidence_sha}"
        )
    else:
        print(
            "preflight-signed-journey-promotion: "
            f"{len(requirement_ids)} requirement(s) match current selectors at {source_sha}"
        )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=".", help="repository root")
    parser.add_argument("--source-sha", required=True, help="commit captured by the journey evidence")
    parser.add_argument(
        "--evidence-sha",
        default=None,
        help="reviewed commit containing evidence and promotion controls",
    )
    parser.add_argument("--requirement-ids", required=True, help="comma-separated requirement IDs to promote")
    parser.add_argument("--journey-id", default=None, help="required mapped journey id")
    args = parser.parse_args(argv)
    preflight(
        Path(args.root).resolve(),
        args.source_sha,
        parse_requirement_ids(args.requirement_ids),
        args.journey_id,
        evidence_sha=args.evidence_sha,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
