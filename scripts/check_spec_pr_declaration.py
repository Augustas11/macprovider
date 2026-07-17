#!/usr/bin/env python3
"""Require an explicit SPEC-governance declaration on every pull request."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

try:
    from scripts.check_spec_governance import (
        DOMAIN_RE,
        JOURNEY_RE,
        REQUIREMENT_ID_RE,
        SENSITIVE_PHYSICAL_DOMAINS,
        SPEC_ID_RE,
        VERDICTS,
        _contract_markdown,
    )
except ModuleNotFoundError:  # Direct execution sets sys.path[0] to scripts/.
    from check_spec_governance import (
        DOMAIN_RE,
        JOURNEY_RE,
        REQUIREMENT_ID_RE,
        SENSITIVE_PHYSICAL_DOMAINS,
        SPEC_ID_RE,
        VERDICTS,
        _contract_markdown,
    )


FIELD_RE = re.compile(
    r"^ {0,3}(behavior-change|contract-change|specs|requirements|"
    r"authority-domains|arbitration|tests|journeys)\s*:\s*(.*?)\s*$",
    re.IGNORECASE,
)
INLINE_DETAILS_OPEN_RE = re.compile(r"<details(?:\s|>|$)", re.IGNORECASE)
CANONICAL_SPEC_PATH_RE = re.compile(r"^specs/SPEC-\d{3}-[^/]+\.md$")
CONTRACT_PATHS = {"specs/AUTHORITY.json", "specs/CONFORMANCE.json"}
GOVERNANCE_ONLY_PATHS = (
    ".github/CODEOWNERS",
    ".github/workflows/spec-index.yml",
    "beta/DECISION_CRITERIA.md",
    "docs/spec-history/",
    "schemas/spec-",
    "scripts/check_spec_governance.py",
    "scripts/check_spec_pr_declaration.py",
    "scripts/gen_spec_index.py",
    "scripts/tests/__init__.py",
    "scripts/tests/fixtures/spec_governance/",
    "scripts/tests/test_spec_governance.py",
    "scripts/tests/test_spec_pr_declaration.py",
    "specs/",
)


def _values(raw: str) -> list[str]:
    return [item for item in re.split(r"[\s,]+", raw.strip()) if item]


def _declaration_marker(lines: list[str]) -> int | None:
    for index, line in enumerate(lines):
        if re.fullmatch(r" {0,3}spec-governance:", line, re.IGNORECASE):
            return index
    return None


def _inside_inline_details(lines: list[str], marker: int) -> bool:
    return any(INLINE_DETAILS_OPEN_RE.search(line) for line in lines[:marker])


def _manifest_ids(root: Path) -> tuple[set[str], set[str], set[str]]:
    try:
        conformance = json.loads((root / "specs" / "CONFORMANCE.json").read_text(encoding="utf-8"))
        authority = json.loads((root / "specs" / "AUTHORITY.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError, TypeError):
        return set(), set(), set()
    specs = {item.get("spec_id") for item in conformance.get("specs", []) if isinstance(item, dict)}
    requirements = {item.get("requirement_id") for item in conformance.get("requirements", []) if isinstance(item, dict)}
    domains = {item.get("id") for item in authority.get("domains", []) if isinstance(item, dict)}
    return ({item for item in specs if isinstance(item, str)},
            {item for item in requirements if isinstance(item, str)},
            {item for item in domains if isinstance(item, str)})


def _governance_only(path: str) -> bool:
    return any(path == allowed or (allowed.endswith("/") and path.startswith(allowed)) or
               (allowed.endswith("-") and path.startswith(allowed)) for allowed in GOVERNANCE_ONLY_PATHS)


def _contract_path(path: str) -> bool:
    return path in CONTRACT_PATHS or bool(CANONICAL_SPEC_PATH_RE.fullmatch(path))


def validate_body(body: str, root: Path | None = None, changed_paths: list[str] | None = None) -> list[str]:
    errors: list[str] = []
    raw_lines = body.splitlines()
    if not any(
        re.fullmatch(r"spec-governance:", line, re.IGNORECASE)
        for line in raw_lines
    ):
        return ["missing top-level 'spec-governance:' declaration block"]
    raw_marker = _declaration_marker(raw_lines)
    if raw_marker is None or _inside_inline_details(raw_lines, raw_marker):
        return ["missing top-level 'spec-governance:' declaration block"]
    lines = _contract_markdown(body).splitlines()
    marker = _declaration_marker(lines)
    if marker is None:
        return ["missing 'spec-governance:' declaration block"]
    fields: dict[str, str] = {}
    for line in lines[marker + 1:]:
        if line.strip().startswith("#") or (not line.strip() and fields):
            break
        match = FIELD_RE.match(line)
        if match:
            field_name = match.group(1).lower()
            if field_name in fields:
                errors.append(
                    f"duplicate spec-governance field {field_name!r}",
                )
            else:
                fields[field_name] = match.group(2)
        elif line.strip():
            break
    behavior = fields.get("behavior-change")
    if behavior not in {"none", "yes"}:
        errors.append("behavior-change must be exactly 'none' or 'yes'")
        return errors
    contract_change = fields.get("contract-change")
    if contract_change is not None and contract_change not in {"none", "yes"}:
        errors.append("contract-change must be exactly 'none' or 'yes'")
    changed_contract_paths = [path for path in changed_paths or [] if _contract_path(path)]
    if changed_contract_paths and contract_change != "yes":
        errors.append(
            "contract-change must be 'yes' when canonical SPEC bodies, AUTHORITY.json, "
            "or CONFORMANCE.json change"
        )
    if behavior == "none":
        for path in changed_paths or []:
            if not _governance_only(path):
                errors.append(f"behavior-change none is invalid for non-governance path {path!r}")
        return errors
    required = {"specs", "requirements", "authority-domains", "arbitration", "tests", "journeys"}
    for field in sorted(required - fields.keys()):
        errors.append(f"behavior-change yes requires '{field}:'")
    specs = _values(fields.get("specs", ""))
    requirements = _values(fields.get("requirements", ""))
    domains = _values(fields.get("authority-domains", ""))
    verdicts = _values(fields.get("arbitration", ""))
    tests = _values(fields.get("tests", ""))
    journeys = _values(fields.get("journeys", ""))
    if not specs:
        errors.append("specs must list at least one SPEC-NNN")
    if not requirements:
        errors.append("requirements must list at least one SPEC-NNN-RNNN")
    if not domains:
        errors.append("authority-domains must list at least one domain")
    if not verdicts:
        errors.append("arbitration must list at least one verdict")
    if not tests:
        errors.append("tests must list at least one test mapping")
    if not journeys:
        errors.append("journeys must list journey IDs or 'not-required'")
    known_specs, known_requirements, known_domains = _manifest_ids(root) if root else (set(), set(), set())
    for value in specs:
        if not SPEC_ID_RE.fullmatch(value):
            errors.append(f"invalid spec ID {value!r}")
        elif root and value not in known_specs:
            errors.append(f"unknown spec ID {value!r}")
    for value in requirements:
        if not REQUIREMENT_ID_RE.fullmatch(value):
            errors.append(f"invalid requirement ID {value!r}")
        elif root and value not in known_requirements:
            errors.append(f"unknown requirement ID {value!r}")
    for value in domains:
        if not DOMAIN_RE.fullmatch(value):
            errors.append(f"invalid authority domain {value!r}")
        elif root and value not in known_domains:
            errors.append(f"unknown authority domain {value!r}")
    for value in verdicts:
        if value not in VERDICTS:
            errors.append(f"invalid arbitration verdict {value!r}")
    for value in journeys:
        if value != "not-required" and not JOURNEY_RE.fullmatch(value):
            errors.append(f"invalid journey declaration {value!r}")
        elif root and value != "not-required":
            journey_root = (root / "journeys").resolve()
            journey_path = (journey_root / f"{value}.md").resolve()
            if journey_path.parent != journey_root or not journey_path.is_file():
                errors.append(f"unknown journey ID {value!r}")
    if "not-required" in journeys and any(domain in SENSITIVE_PHYSICAL_DOMAINS for domain in domains):
        errors.append("journeys: not-required is forbidden for sensitive authority domains")
    if root:
        for value in tests:
            if "::" not in value:
                errors.append(f"test mapping requires path::selector: {value!r}")
                continue
            relative, selector = value.split("::", 1)
            path = (root / relative).resolve()
            try:
                normalized = path.relative_to(root).as_posix()
            except ValueError:
                errors.append(f"test mapping escapes repository: {value!r}")
                continue
            if not path.is_file() or "test" not in Path(normalized).name.lower():
                errors.append(f"test mapping does not resolve to a test file: {value!r}")
            elif not selector or selector not in path.read_text(encoding="utf-8"):
                errors.append(f"test mapping selector does not resolve: {value!r}")
    return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--event", type=Path, required=True, help="GitHub event JSON")
    parser.add_argument("--base", required=True, help="base commit SHA")
    parser.add_argument("--head", default="HEAD", help="head commit SHA")
    args = parser.parse_args(argv)
    try:
        event = json.loads(args.event.read_text(encoding="utf-8"))
        body = event["pull_request"].get("body") or ""
    except (OSError, json.JSONDecodeError, KeyError, TypeError) as exc:
        print(f"invalid pull-request event: {exc}", file=sys.stderr)
        return 1
    changed = subprocess.run(
        ["git", "diff", "--name-only", f"{args.base}...{args.head}"],
        cwd=Path(__file__).resolve().parents[1], capture_output=True, text=True,
    )
    if changed.returncode:
        print(f"cannot inspect pull-request diff: {changed.stderr.strip()}", file=sys.stderr)
        return 1
    root = Path(__file__).resolve().parents[1]
    errors = validate_body(body, root=root, changed_paths=changed.stdout.splitlines())
    if errors:
        print("SPEC governance PR declaration failed:", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        return 1
    print("ok: pull request contains an explicit SPEC governance declaration")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
