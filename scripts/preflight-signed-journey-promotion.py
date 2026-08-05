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
    ValidationResult,
    _commit_mapping_selector_matches_current,
    _load_json,
    _mapping_file,
    _mapping_selector,
)


COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
REQUIREMENT_RE = re.compile(r"^SPEC-[0-9]{3}-R[0-9]{3}$")


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


def require_reachable_commit(root: Path, commit: str) -> None:
    completed = subprocess.run(
        ["git", "cat-file", "-e", f"{commit}^{{commit}}"],
        cwd=root,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if completed.returncode != 0:
        die(f"--source-sha is not reachable: {commit}")


def assert_commit_matches_current_selectors(
    root: Path,
    requirement: dict[str, Any],
    source_sha: str,
    *,
    location: str,
) -> list[str]:
    errors: list[str] = []
    mappings: list[str] = []
    for key in ("implementation", "tests"):
        values = requirement.get(key)
        if isinstance(values, list):
            mappings.extend(item for item in values if isinstance(item, str))
    if not mappings:
        errors.append(f"{location}: no implementation/test mappings to prove against {source_sha}")
        return errors
    for mapping in mappings:
        if not _commit_mapping_selector_matches_current(root, source_sha, mapping):
            errors.append(
                f"{location}: commit evidence {source_sha} does not match current mapped selector "
                f"fragment {_mapping_selector(mapping)!r} in {_mapping_file(mapping)!r}"
            )
    return errors


def preflight(root: Path, source_sha: str, requirement_ids: list[str], journey_id: str | None) -> None:
    if not COMMIT_RE.fullmatch(source_sha):
        die("--source-sha must be a 40-character lowercase hex commit")
    require_reachable_commit(root, source_sha)
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
        errors.extend(assert_commit_matches_current_selectors(root, requirement, source_sha, location=location))

    if errors:
        for error in errors:
            print(f"error: {error}", file=sys.stderr)
        die("promotion preflight rejected")
    print(f"preflight-signed-journey-promotion: {len(requirement_ids)} requirement(s) match current selectors at {source_sha}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=".", help="repository root")
    parser.add_argument("--source-sha", required=True, help="commit captured by the journey evidence")
    parser.add_argument("--requirement-ids", required=True, help="comma-separated requirement IDs to promote")
    parser.add_argument("--journey-id", default=None, help="required mapped journey id")
    args = parser.parse_args(argv)
    preflight(Path(args.root).resolve(), args.source_sha, parse_requirement_ids(args.requirement_ids), args.journey_id)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
