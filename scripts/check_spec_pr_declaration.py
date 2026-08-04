#!/usr/bin/env python3
"""Require a structured SPEC governance declaration on pull requests."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

try:
    from scripts.check_spec_governance import (
        DOMAIN_RE,
        ISSUE_RE,
        REQUIREMENT_ID_RE,
        SPEC_ID_RE,
        VERDICTS,
        DuplicateJSONKeyError,
        _load_json,
        _unique_json_object,
        ValidationResult,
    )
except ModuleNotFoundError:
    from check_spec_governance import (
        DOMAIN_RE,
        ISSUE_RE,
        REQUIREMENT_ID_RE,
        SPEC_ID_RE,
        VERDICTS,
        DuplicateJSONKeyError,
        _load_json,
        _unique_json_object,
        ValidationResult,
    )


BEGIN = "SPEC-GOVERNANCE-DECLARATION-BEGIN"
END = "SPEC-GOVERNANCE-DECLARATION-END"
SCHEMA_VERSION = "spec-pr-governance-v1"
CANONICAL_SPEC_PATH_RE = re.compile(r"^specs/SPEC-\d{3}-[^/]+\.md$")
CONTRACT_PATHS = {"specs/AUTHORITY.json", "specs/CONFORMANCE.json"}
GOVERNANCE_ONLY_PATHS = (
    ".github/CODEOWNERS",
    ".github/workflows/spec-index.yml",
    "beta/DECISION_CRITERIA.md",
    "docs/spec-governance-foundation.md",
    "docs/spec-history/",
    "schemas/journey-",
    "schemas/spec-",
    "scripts/check_spec_governance.py",
    "scripts/check_spec_pr_declaration.py",
    "scripts/gen_spec_index.py",
    "scripts/tests/",
    "specs/",
)


def _governance_only(path: str) -> bool:
    return any(
        path == allowed
        or (allowed.endswith("/") and path.startswith(allowed))
        or (allowed.endswith("-") and path.startswith(allowed))
        for allowed in GOVERNANCE_ONLY_PATHS
    )


def _contract_path(path: str) -> bool:
    return path in CONTRACT_PATHS or bool(CANONICAL_SPEC_PATH_RE.fullmatch(path))


def _extract_declaration(body: str) -> tuple[dict[str, Any] | None, list[str]]:
    errors: list[str] = []
    begin_count = body.count(BEGIN)
    end_count = body.count(END)
    if begin_count != 1 or end_count != 1:
        return None, [f"PR body must contain exactly one {BEGIN}/{END} declaration"]
    start = body.index(BEGIN) + len(BEGIN)
    stop = body.index(END)
    if stop <= start:
        return None, ["declaration end marker must follow begin marker"]
    payload = body[start:stop].strip()
    try:
        value = json.loads(payload, object_pairs_hook=_unique_json_object)
    except DuplicateJSONKeyError as exc:
        return None, [f"declaration JSON has duplicate object key {exc.args[0]!r}"]
    except json.JSONDecodeError as exc:
        return None, [f"declaration JSON is invalid: {exc}"]
    if not isinstance(value, dict):
        return None, ["declaration JSON must be an object"]
    return value, errors


def _string_array(value: Any, field: str, errors: list[str], pattern: re.Pattern[str] | None = None) -> list[str]:
    if not isinstance(value, list):
        errors.append(f"{field} must be an array")
        return []
    output: list[str] = []
    seen: set[str] = set()
    for index, item in enumerate(value):
        if not isinstance(item, str) or not item:
            errors.append(f"{field}[{index}] must be a non-empty string")
            continue
        if pattern is not None and not pattern.fullmatch(item):
            errors.append(f"{field}[{index}] has invalid value {item!r}")
            continue
        if item in seen:
            errors.append(f"{field}[{index}] duplicates {item!r}")
        seen.add(item)
        output.append(item)
    return output


def _manifest_ids(root: Path) -> tuple[set[str], set[str], set[str]]:
    result = ValidationResult()
    conformance = _load_json(root / "specs" / "CONFORMANCE.json", result)
    authority = _load_json(root / "specs" / "AUTHORITY.json", result)
    if result.errors or not isinstance(conformance, dict) or not isinstance(authority, dict):
        return set(), set(), set()
    specs = {
        item.get("spec_id")
        for item in conformance.get("specs", [])
        if isinstance(item, dict) and isinstance(item.get("spec_id"), str)
    }
    requirements = {
        item.get("requirement_id")
        for item in conformance.get("requirements", [])
        if isinstance(item, dict) and isinstance(item.get("requirement_id"), str)
    }
    domains = {
        item.get("id")
        for item in authority.get("domains", [])
        if isinstance(item, dict) and isinstance(item.get("id"), str)
    }
    return specs, requirements, domains


def validate_body(
    body: str,
    root: Path | None = None,
    changed_paths: list[str] | None = None,
) -> list[str]:
    declaration, errors = _extract_declaration(body)
    if declaration is None:
        return errors
    required = {
        "schema_version",
        "behavior_change",
        "contract_change",
        "specs",
        "requirements",
        "authority_domains",
        "arbitration",
        "tests",
        "journeys",
    }
    allowed = required | {"issue"}
    for field in sorted(required - declaration.keys()):
        errors.append(f"declaration missing required field {field!r}")
    for field in sorted(declaration.keys() - allowed):
        errors.append(f"declaration has unexpected field {field!r}")
    if declaration.get("schema_version") != SCHEMA_VERSION:
        errors.append(f"schema_version must be {SCHEMA_VERSION!r}")

    behavior = declaration.get("behavior_change")
    contract = declaration.get("contract_change")
    if behavior not in {"none", "yes"}:
        errors.append("behavior_change must be exactly 'none' or 'yes'")
    if contract not in {"none", "yes"}:
        errors.append("contract_change must be exactly 'none' or 'yes'")
    if "issue" in declaration and (
        not isinstance(declaration["issue"], str)
        or not ISSUE_RE.fullmatch(declaration["issue"])
    ):
        errors.append("issue must be an Augustas11/macprovider issue URL")

    specs = _string_array(declaration.get("specs"), "specs", errors, SPEC_ID_RE)
    requirements = _string_array(
        declaration.get("requirements"),
        "requirements",
        errors,
        REQUIREMENT_ID_RE,
    )
    domains = _string_array(
        declaration.get("authority_domains"),
        "authority_domains",
        errors,
        DOMAIN_RE,
    )
    arbitration = _string_array(declaration.get("arbitration"), "arbitration", errors)
    tests = _string_array(declaration.get("tests"), "tests", errors)
    journeys = _string_array(declaration.get("journeys"), "journeys", errors)

    changed = changed_paths or []
    if any(_contract_path(path) for path in changed) and contract != "yes":
        errors.append("contract_change must be 'yes' when canonical SPECs or governance manifests change")
    if behavior == "none":
        for path in changed:
            if not _governance_only(path):
                errors.append(f"behavior_change none is invalid for non-governance path {path!r}")
    if behavior == "yes":
        if not specs:
            errors.append("behavior_change yes requires at least one spec")
        if not requirements:
            errors.append("behavior_change yes requires at least one requirement")
        if not domains:
            errors.append("behavior_change yes requires at least one authority domain")
        if not arbitration:
            errors.append("behavior_change yes requires at least one arbitration verdict")
        if not tests:
            errors.append("behavior_change yes requires tests")
        if not journeys:
            errors.append("behavior_change yes requires journeys or 'not-required'")
    for verdict in arbitration:
        if verdict not in VERDICTS:
            errors.append(f"unknown arbitration verdict {verdict!r}")

    if root is not None:
        known_specs, known_requirements, known_domains = _manifest_ids(root)
        for spec in specs:
            if spec not in known_specs:
                errors.append(f"unknown spec {spec!r}")
        for requirement in requirements:
            if requirement not in known_requirements:
                errors.append(f"unknown requirement {requirement!r}")
        for domain in domains:
            if domain not in known_domains:
                errors.append(f"unknown authority domain {domain!r}")
    return errors


def _changed_paths(root: Path, base: str | None, head: str | None) -> list[str]:
    if not base or not head:
        return []
    completed = subprocess.run(
        ["git", "diff", "--name-only", f"{base}...{head}"],
        cwd=root,
        capture_output=True,
        text=True,
        check=False,
    )
    if completed.returncode != 0:
        raise RuntimeError(completed.stderr.strip() or "git diff failed")
    return [line for line in completed.stdout.splitlines() if line]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--event", required=True, help="GitHub pull_request event JSON")
    parser.add_argument("--base", default=None, help="base commit SHA")
    parser.add_argument("--head", default=None, help="head commit SHA")
    parser.add_argument("--root", default=".", help="repository root")
    args = parser.parse_args(argv)

    event = json.loads(Path(args.event).read_text(encoding="utf-8"))
    body = ((event.get("pull_request") or {}).get("body") or "")
    root = Path(args.root)
    try:
        changed = _changed_paths(root, args.base, args.head)
    except RuntimeError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    errors = validate_body(body, root, changed)
    if errors:
        for error in errors:
            print(f"error: {error}", file=sys.stderr)
        return 1
    print("SPEC governance PR declaration passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
