#!/usr/bin/env python3
"""Validate structured SPEC authority and conformance manifests.

This checker deliberately treats Markdown as human-readable documentation only.
It validates exact files, IDs, structured references, mappings, lifecycle
states, and evidence records from JSON manifests. It does not infer normative
meaning from rendered prose.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from dataclasses import dataclass, field
from datetime import date
from pathlib import Path
from typing import Any


AUTHORITY_SCHEMA_PATH = "../schemas/spec-authority-v1.schema.json"
CONFORMANCE_SCHEMA_PATH = "../schemas/spec-conformance-v1.schema.json"
SPEC_ID_RE = re.compile(r"^SPEC-\d{3}$")
SPEC_PATH_RE = re.compile(r"^specs/SPEC-\d{3}-[a-z0-9-]+\.md$")
REQUIREMENT_ID_RE = re.compile(r"^(SPEC-\d{3})-R\d{3}$")
DOMAIN_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
OWNER_RE = re.compile(r"^@[A-Za-z0-9-]+$")
ISSUE_RE = re.compile(r"^https://github\.com/Augustas11/macprovider/issues/\d+$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
ARTIFACT_RE = re.compile(r"^(?:commit:[0-9a-f]{40}|sha256:[0-9a-f]{64})$")
SHA256_RE = re.compile(r"^sha256:([0-9a-f]{64})$")
JOURNEY_RE = re.compile(r"^JOURNEY-[A-Z0-9]+(?:-[A-Z0-9]+)*$")
TITLE_RE = re.compile(r"^#\s+(SPEC-\d{3})\s*[—–:-]\s*(.+)$")
VERSION_RE = re.compile(r"^Version\s*:\s*(\S+)", re.IGNORECASE)
STATUS_VERSION_RE = re.compile(r"^Status\b.*?\b(v?\d+\.\d+(?:\.\d+)?)", re.IGNORECASE)

LIFECYCLE_STATES = {
    "draft",
    "normative",
    "implemented-unverified",
    "physically-verified",
    "deprecated",
}
IMPLEMENTATION_STATES = {
    "pending-reconciliation",
    "partial",
    "implemented",
    "not-applicable",
}
PRODUCTION_STATES = {
    "pending-verification",
    "not-deployed",
    "partially-deployed",
    "physically-verified",
    "not-applicable",
}
AUTHORITY_STATES = {"declared", "pending-reconciliation", "deprecated"}
CONFORMANCE_STATES = {
    "pending",
    "blocked",
    "conformant",
    "nonconformant",
    "not-applicable",
}
VERDICTS = {
    "CODE_BUG",
    "SPEC_BUG",
    "DECISION_REQUIRED",
    "DUPLICATE_AUTHORITY",
    "UNKNOWN",
}
REQUIREMENT_MIGRATION_STATES = {"pending", "complete"}
SENSITIVE_PHYSICAL_DOMAINS = {
    "provider-wire-protocol",
    "provider-onboarding-identity",
    "tier2-trust-evidence",
    "model-catalog-identity",
    "operator-pushed-warm-swap",
    "coordinator-demand-pull-model-swap",
    "provider-autoupdate",
    "installer-autotune-policy",
    "native-app-lifecycle",
    "browserless-onboarding",
    "provider-wallet-proof",
    "hardware-evidence-admission",
    "hardware-evidence-verifier",
}


@dataclass
class ValidationResult:
    errors: list[str] = field(default_factory=list)

    def error(self, location: str, message: str) -> None:
        self.errors.append(f"{location}: {message}")


class DuplicateJSONKeyError(ValueError):
    pass


def _unique_json_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise DuplicateJSONKeyError(key)
        value[key] = item
    return value


def _load_json(path: Path, result: ValidationResult) -> Any | None:
    try:
        return json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=_unique_json_object,
        )
    except DuplicateJSONKeyError as exc:
        result.error(str(path), f"duplicate JSON object key {exc.args[0]!r}")
    except UnicodeDecodeError as exc:
        result.error(str(path), f"invalid UTF-8: {exc}")
    except json.JSONDecodeError as exc:
        result.error(str(path), f"invalid JSON: {exc}")
    except OSError as exc:
        result.error(str(path), f"cannot read: {exc}")
    return None


def _expect_object(value: Any, location: str, result: ValidationResult) -> bool:
    if isinstance(value, dict):
        return True
    result.error(location, f"expected object, got {type(value).__name__}")
    return False


def _expect_keys(
    value: dict[str, Any],
    required: set[str],
    allowed: set[str],
    location: str,
    result: ValidationResult,
) -> None:
    for key in sorted(required - value.keys()):
        result.error(location, f"missing required field {key!r}")
    for key in sorted(value.keys() - allowed):
        result.error(location, f"unexpected field {key!r}")


def _string(value: Any, pattern: re.Pattern[str] | None, location: str, result: ValidationResult) -> str | None:
    if not isinstance(value, str) or not value:
        result.error(location, "must be a non-empty string")
        return None
    if pattern is not None and not pattern.fullmatch(value):
        result.error(location, f"invalid value {value!r}")
        return None
    return value


def _nullable_string(value: Any, pattern: re.Pattern[str], location: str, result: ValidationResult) -> str | None:
    if value is None:
        return None
    return _string(value, pattern, location, result)


def _string_list(value: Any, location: str, result: ValidationResult, pattern: re.Pattern[str] | None = None) -> list[str]:
    if not isinstance(value, list):
        result.error(location, f"field {location.rsplit('.', 1)[-1]!r} must be an array")
        return []
    output: list[str] = []
    seen: set[str] = set()
    for index, item in enumerate(value):
        text = _string(item, pattern, f"{location}[{index}]", result)
        if text is None:
            continue
        if text in seen:
            result.error(f"{location}[{index}]", f"duplicate value {text!r}")
        seen.add(text)
        output.append(text)
    return output


def _date(value: Any, location: str, result: ValidationResult) -> date | None:
    if not isinstance(value, str):
        result.error(location, "must be an ISO date string")
        return None
    try:
        return date.fromisoformat(value)
    except ValueError:
        result.error(location, f"invalid ISO date {value!r}")
        return None


def _validate_baseline(value: Any, location: str, result: ValidationResult) -> None:
    if not _expect_object(value, location, result):
        return
    _expect_keys(value, {"commit", "captured_at"}, {"commit", "captured_at"}, location, result)
    _string(value.get("commit"), COMMIT_RE, f"{location}.commit", result)
    _date(value.get("captured_at"), f"{location}.captured_at", result)


def _validate_gap(value: Any, location: str, result: ValidationResult) -> None:
    if not _expect_object(value, location, result):
        return
    allowed = {"verdict", "owner", "issue", "rationale"}
    _expect_keys(value, {"verdict", "owner", "issue"}, allowed, location, result)
    verdict = value.get("verdict")
    if verdict not in VERDICTS:
        result.error(f"{location}.verdict", f"invalid verdict {verdict!r}")
    _string(value.get("owner"), OWNER_RE, f"{location}.owner", result)
    _string(value.get("issue"), ISSUE_RE, f"{location}.issue", result)
    if "rationale" in value:
        _string(value.get("rationale"), None, f"{location}.rationale", result)


def _repository_path(root: Path, relative: str, location: str, result: ValidationResult) -> Path | None:
    try:
        candidate = (root / relative).resolve()
        candidate.relative_to(root.resolve())
    except (OSError, ValueError) as exc:
        result.error(location, f"invalid repository path {relative!r}: {exc}")
        return None
    return candidate


def _mapping_file(value: str) -> str:
    if "::" in value:
        return value.split("::", 1)[0]
    if ":" in value:
        return value.split(":", 1)[0]
    return value


def _validate_mapping_paths(root: Path, mappings: list[str], location: str, result: ValidationResult) -> None:
    for index, mapping in enumerate(mappings):
        file_part = _mapping_file(mapping)
        path = _repository_path(root, file_part, f"{location}[{index}]", result)
        if path is None:
            continue
        if not path.exists():
            result.error(f"{location}[{index}]", f"mapping path does not exist: {file_part!r}")
        elif path.is_dir():
            result.error(f"{location}[{index}]", f"mapping path must be a file: {file_part!r}")


def _validate_evidence(root: Path, value: Any, location: str, result: ValidationResult) -> None:
    if not _expect_object(value, location, result):
        return
    required = {"artifact", "source", "captured_at", "expires_at"}
    _expect_keys(value, required, required, location, result)
    artifact = _string(value.get("artifact"), ARTIFACT_RE, f"{location}.artifact", result)
    source = value.get("source")
    if source is not None:
        _string(source, None, f"{location}.source", result)
    captured_at = _date(value.get("captured_at"), f"{location}.captured_at", result)
    expires_at = _date(value.get("expires_at"), f"{location}.expires_at", result)
    if captured_at and expires_at and expires_at < captured_at:
        result.error(location, "evidence expires before it is captured")
    if captured_at and captured_at > date.today():
        result.error(location, f"evidence captured_at is in the future: {captured_at.isoformat()}")
    if expires_at and expires_at < date.today():
        result.error(location, f"evidence expired on {expires_at.isoformat()}")
    if artifact and artifact.startswith("commit:"):
        commit = artifact.split(":", 1)[1]
        if subprocess.run(
            ["git", "cat-file", "-e", f"{commit}^{{commit}}"],
            cwd=root,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        ).returncode != 0:
            result.error(f"{location}.artifact", f"commit evidence is not reachable: {commit}")
    match = SHA256_RE.fullmatch(artifact or "")
    if match and not isinstance(source, str):
        result.error(f"{location}.source", "sha256 evidence requires a non-empty source path")
    if match and isinstance(source, str):
        path = _repository_path(root, source, f"{location}.source", result)
        if path is not None:
            try:
                digest = hashlib.sha256(path.read_bytes()).hexdigest()
            except OSError as exc:
                result.error(f"{location}.source", f"cannot read evidence source: {exc}")
            else:
                if digest != match.group(1):
                    result.error(f"{location}.artifact", "sha256 artifact does not match source bytes")


def _source_under_journey_evidence(root: Path, source: str) -> bool:
    try:
        resolved = (root / source).resolve()
        resolved.relative_to((root / "journeys" / "evidence").resolve())
    except (OSError, ValueError):
        return False
    return True


def _commit_file_matches_current(root: Path, commit: str, relative: str) -> bool:
    completed = subprocess.run(
        ["git", "show", f"{commit}:{relative}"],
        cwd=root,
        capture_output=True,
        check=False,
    )
    if completed.returncode != 0:
        return False
    try:
        current = (root / relative).read_bytes()
    except OSError:
        return False
    return completed.stdout == current


def _validate_evidence_list(root: Path, value: Any, location: str, result: ValidationResult) -> None:
    if not isinstance(value, list):
        result.error(location, "field 'evidence' must be an array")
        return
    for index, item in enumerate(value):
        _validate_evidence(root, item, f"{location}[{index}]", result)


def _parse_spec_header(path: Path, result: ValidationResult) -> tuple[str, str, str] | None:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except UnicodeDecodeError as exc:
        result.error(str(path), f"invalid UTF-8: {exc}")
        return None
    except OSError as exc:
        result.error(str(path), f"cannot read: {exc}")
        return None
    if not lines:
        result.error(str(path), "empty SPEC file")
        return None
    title_match = TITLE_RE.match(lines[0].strip())
    if title_match is None:
        result.error(str(path), "first line must be '# SPEC-NNN - Title'")
        return None
    version: str | None = None
    for line in lines[:15]:
        clean = line.replace("*", "").strip()
        match = VERSION_RE.match(clean) or STATUS_VERSION_RE.match(clean)
        if match:
            version = match.group(1).rstrip(".,;")
            break
    if version is None:
        result.error(str(path), "missing version header in first 15 lines")
        return None
    return title_match.group(1), title_match.group(2).strip(), version


def _git_show_json(root: Path, commit: str, relative: str) -> Any | None:
    completed = subprocess.run(
        ["git", "show", f"{commit}:{relative}"],
        cwd=root,
        capture_output=True,
        text=True,
        check=False,
    )
    if completed.returncode != 0:
        return None
    try:
        return json.loads(completed.stdout, object_pairs_hook=_unique_json_object)
    except (DuplicateJSONKeyError, json.JSONDecodeError):
        return None


def _validate_base_manifest_immutability(
    root: Path,
    base_ref: str | None,
    authority: dict[str, Any],
    conformance: dict[str, Any],
    result: ValidationResult,
) -> None:
    if not base_ref:
        return
    base_authority = _git_show_json(root, base_ref, "specs/AUTHORITY.json")
    base_conformance = _git_show_json(root, base_ref, "specs/CONFORMANCE.json")
    if not isinstance(base_authority, dict) or not isinstance(base_conformance, dict):
        return

    head_domains = {
        item.get("id"): item
        for item in authority.get("domains", [])
        if isinstance(item, dict) and isinstance(item.get("id"), str)
    }
    for item in base_authority.get("domains", []):
        if not isinstance(item, dict) or not isinstance(item.get("id"), str):
            continue
        domain_id = item["id"]
        head = head_domains.get(domain_id)
        if head is None:
            result.error("specs/AUTHORITY.json", f"authority domain {domain_id!r} removed from structured tombstone ledger")
            continue
        if head.get("owner_spec") != item.get("owner_spec"):
            result.error("specs/AUTHORITY.json", f"authority domain {domain_id!r} owner changed from {item.get('owner_spec')} to {head.get('owner_spec')}")

    head_specs = {
        item.get("spec_id"): item
        for item in conformance.get("specs", [])
        if isinstance(item, dict) and isinstance(item.get("spec_id"), str)
    }
    for item in base_conformance.get("specs", []):
        if not isinstance(item, dict) or not isinstance(item.get("spec_id"), str):
            continue
        spec_id = item["spec_id"]
        head = head_specs.get(spec_id)
        if head is None:
            result.error("specs/CONFORMANCE.json", f"SPEC record {spec_id} removed from structured tombstone ledger")
            continue
        if head.get("owner") != item.get("owner"):
            result.error("specs/CONFORMANCE.json", f"SPEC record {spec_id} owner changed from {item.get('owner')} to {head.get('owner')}")

    head_requirements = {
        item.get("requirement_id"): item
        for item in conformance.get("requirements", [])
        if isinstance(item, dict) and isinstance(item.get("requirement_id"), str)
    }
    for item in base_conformance.get("requirements", []):
        if not isinstance(item, dict) or not isinstance(item.get("requirement_id"), str):
            continue
        requirement_id = item["requirement_id"]
        head = head_requirements.get(requirement_id)
        if head is None:
            result.error("specs/CONFORMANCE.json", f"requirement ID {requirement_id} removed from structured tombstone ledger")
            continue
        if head.get("spec_id") != item.get("spec_id"):
            result.error("specs/CONFORMANCE.json", f"requirement ID {requirement_id} moved from {item.get('spec_id')} to {head.get('spec_id')}")


def _canonical_spec_files(root: Path, result: ValidationResult) -> dict[str, Path]:
    specs: dict[str, Path] = {}
    for path in sorted((root / "specs").glob("SPEC-*.md")):
        header = _parse_spec_header(path, result)
        if header is None:
            continue
        match = re.match(r"SPEC-(\d{3})-", path.name)
        if match is None:
            result.error(str(path), "canonical SPEC filename must start with SPEC-NNN-")
            continue
        spec_id = f"SPEC-{match.group(1)}"
        header_spec_id = header[0]
        if header_spec_id != spec_id:
            result.error(str(path.relative_to(root)), f"header spec ID {header_spec_id} does not match filename {spec_id}")
        if spec_id in specs:
            result.error("specs", f"duplicate canonical SPEC file for {spec_id}")
        specs[spec_id] = path
    return specs


def _validate_authority_schema(authority: Any, result: ValidationResult) -> list[dict[str, Any]]:
    if not _expect_object(authority, "specs/AUTHORITY.json", result):
        return []
    _expect_keys(
        authority,
        {"$schema", "schema_version", "baseline", "domains"},
        {"$schema", "schema_version", "baseline", "domains"},
        "specs/AUTHORITY.json",
        result,
    )
    if authority.get("$schema") != AUTHORITY_SCHEMA_PATH:
        result.error("specs/AUTHORITY.json.$schema", f"must equal {AUTHORITY_SCHEMA_PATH!r}")
    if authority.get("schema_version") != "spec-authority-v1":
        result.error("specs/AUTHORITY.json.schema_version", "must equal 'spec-authority-v1'")
    _validate_baseline(authority.get("baseline"), "specs/AUTHORITY.json.baseline", result)
    domains = authority.get("domains")
    if not isinstance(domains, list):
        result.error("specs/AUTHORITY.json.domains", "field 'domains' must be an array")
        return []
    for index, domain in enumerate(domains):
        loc = f"specs/AUTHORITY.json.domains[{index}]"
        if not _expect_object(domain, loc, result):
            continue
        _expect_keys(
            domain,
            {"id", "owner_spec", "consumers", "status", "owner", "issue"},
            {"id", "owner_spec", "consumers", "status", "owner", "issue"},
            loc,
            result,
        )
        _string(domain.get("id"), DOMAIN_RE, f"{loc}.id", result)
        _string(domain.get("owner_spec"), SPEC_ID_RE, f"{loc}.owner_spec", result)
        _string_list(domain.get("consumers"), f"{loc}.consumers", result, SPEC_ID_RE)
        if domain.get("status") not in AUTHORITY_STATES:
            result.error(f"{loc}.status", f"invalid authority status {domain.get('status')!r}")
        _string(domain.get("owner"), OWNER_RE, f"{loc}.owner", result)
        _string(domain.get("issue"), ISSUE_RE, f"{loc}.issue", result)
    return [item for item in domains if isinstance(item, dict)]


def _validate_conformance_schema(root: Path, conformance: Any, result: ValidationResult) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    if not _expect_object(conformance, "specs/CONFORMANCE.json", result):
        return [], []
    _expect_keys(
        conformance,
        {"$schema", "schema_version", "baseline", "specs", "requirements"},
        {"$schema", "schema_version", "baseline", "specs", "requirements"},
        "specs/CONFORMANCE.json",
        result,
    )
    if conformance.get("$schema") != CONFORMANCE_SCHEMA_PATH:
        result.error("specs/CONFORMANCE.json.$schema", f"must equal {CONFORMANCE_SCHEMA_PATH!r}")
    if conformance.get("schema_version") != "spec-conformance-v1":
        result.error("specs/CONFORMANCE.json.schema_version", "must equal 'spec-conformance-v1'")
    _validate_baseline(conformance.get("baseline"), "specs/CONFORMANCE.json.baseline", result)

    specs = conformance.get("specs")
    if not isinstance(specs, list):
        result.error("specs/CONFORMANCE.json.specs", "field 'specs' must be an array")
        specs = []
    for index, spec in enumerate(specs):
        loc = f"specs/CONFORMANCE.json.specs[{index}]"
        if not _expect_object(spec, loc, result):
            continue
        _expect_keys(
            spec,
            {
                "spec_id",
                "title",
                "version",
                "path",
                "status",
                "owner",
                "authority_domains",
                "supersedes",
                "depends_on",
                "implementation_status",
                "production_status",
                "last_reconciled_commit",
                "last_reconciled_at",
                "evidence",
                "requirement_id_migration",
                "gap",
            },
            {
                "spec_id",
                "title",
                "version",
                "path",
                "status",
                "owner",
                "authority_domains",
                "supersedes",
                "depends_on",
                "superseded_by",
                "deprecation_rationale",
                "implementation_status",
                "production_status",
                "last_reconciled_commit",
                "last_reconciled_at",
                "evidence",
                "requirement_id_migration",
                "gap",
            },
            loc,
            result,
        )
        _string(spec.get("spec_id"), SPEC_ID_RE, f"{loc}.spec_id", result)
        _string(spec.get("title"), None, f"{loc}.title", result)
        _string(spec.get("version"), None, f"{loc}.version", result)
        _string(spec.get("path"), SPEC_PATH_RE, f"{loc}.path", result)
        if spec.get("status") not in LIFECYCLE_STATES:
            result.error(f"{loc}.status", f"invalid lifecycle state {spec.get('status')!r}")
        _string(spec.get("owner"), OWNER_RE, f"{loc}.owner", result)
        _string_list(spec.get("authority_domains"), f"{loc}.authority_domains", result, DOMAIN_RE)
        _string_list(spec.get("supersedes"), f"{loc}.supersedes", result, SPEC_ID_RE)
        _string_list(spec.get("depends_on"), f"{loc}.depends_on", result, SPEC_ID_RE)
        if "superseded_by" in spec:
            _string_list(spec.get("superseded_by"), f"{loc}.superseded_by", result, SPEC_ID_RE)
        if "deprecation_rationale" in spec:
            _string(spec.get("deprecation_rationale"), None, f"{loc}.deprecation_rationale", result)
        if spec.get("implementation_status") not in IMPLEMENTATION_STATES:
            result.error(f"{loc}.implementation_status", f"invalid implementation status {spec.get('implementation_status')!r}")
        if spec.get("production_status") not in PRODUCTION_STATES:
            result.error(f"{loc}.production_status", f"invalid production status {spec.get('production_status')!r}")
        _nullable_string(spec.get("last_reconciled_commit"), COMMIT_RE, f"{loc}.last_reconciled_commit", result)
        if spec.get("last_reconciled_at") is not None:
            _date(spec.get("last_reconciled_at"), f"{loc}.last_reconciled_at", result)
        _validate_evidence_list(root, spec.get("evidence"), f"{loc}.evidence", result)
        if spec.get("requirement_id_migration") not in REQUIREMENT_MIGRATION_STATES:
            result.error(f"{loc}.requirement_id_migration", f"invalid migration state {spec.get('requirement_id_migration')!r}")
        if spec.get("requirement_id_migration") == "pending":
            if spec.get("gap") is None:
                result.error(loc, "pending requirement migration requires an owned, issue-linked gap")
            else:
                _validate_gap(spec.get("gap"), f"{loc}.gap", result)
        elif spec.get("gap") is not None:
            _validate_gap(spec.get("gap"), f"{loc}.gap", result)

    requirements = conformance.get("requirements")
    if not isinstance(requirements, list):
        result.error("specs/CONFORMANCE.json.requirements", "field 'requirements' must be an array")
        requirements = []
    for index, requirement in enumerate(requirements):
        loc = f"specs/CONFORMANCE.json.requirements[{index}]"
        if not _expect_object(requirement, loc, result):
            continue
        _expect_keys(
            requirement,
            {"requirement_id", "spec_id", "state", "implementation", "tests", "journeys", "evidence", "gap"},
            {"requirement_id", "spec_id", "state", "implementation", "tests", "journeys", "evidence", "gap"},
            loc,
            result,
        )
        requirement_id = _string(requirement.get("requirement_id"), REQUIREMENT_ID_RE, f"{loc}.requirement_id", result)
        spec_id = _string(requirement.get("spec_id"), SPEC_ID_RE, f"{loc}.spec_id", result)
        if requirement_id and spec_id and not requirement_id.startswith(spec_id + "-"):
            result.error(loc, f"requirement_id {requirement_id!r} does not belong to {spec_id}")
        if requirement.get("state") not in CONFORMANCE_STATES:
            result.error(f"{loc}.state", f"invalid conformance state {requirement.get('state')!r}")
        implementation = _string_list(requirement.get("implementation"), f"{loc}.implementation", result)
        tests = _string_list(requirement.get("tests"), f"{loc}.tests", result)
        journeys = _string_list(requirement.get("journeys"), f"{loc}.journeys", result, JOURNEY_RE)
        _validate_mapping_paths(root, implementation, f"{loc}.implementation", result)
        _validate_mapping_paths(root, tests, f"{loc}.tests", result)
        for journey_index, journey in enumerate(journeys):
            journey_path = root / "journeys" / f"{journey}.md"
            if not journey_path.exists():
                result.error(f"{loc}.journeys[{journey_index}]", f"journey mapping has no tracked record: {journey_path.relative_to(root)}")
        _validate_evidence_list(root, requirement.get("evidence"), f"{loc}.evidence", result)
        state = requirement.get("state")
        if state in {"pending", "blocked", "nonconformant"}:
            if requirement.get("gap") is None:
                result.error(loc, f"state {state!r} requires an owned, issue-linked gap")
            else:
                _validate_gap(requirement.get("gap"), f"{loc}.gap", result)
        elif requirement.get("gap") is not None:
            _validate_gap(requirement.get("gap"), f"{loc}.gap", result)
        if state == "conformant" and not (implementation and (tests or journeys) and requirement.get("evidence")):
            result.error(loc, "conformant requirement requires implementation, test or journey, and evidence")
        if state == "conformant":
            commits = [
                evidence.get("artifact", "").split(":", 1)[1]
                for evidence in requirement.get("evidence", [])
                if isinstance(evidence, dict)
                and isinstance(evidence.get("artifact"), str)
                and evidence["artifact"].startswith("commit:")
            ]
            if not commits:
                result.error(loc, "conformant requirement requires commit evidence for mapped implementation and test files")
            for commit in commits:
                for mapping in implementation + tests:
                    mapped_file = _mapping_file(mapping)
                    if not _commit_file_matches_current(root, commit, mapped_file):
                        result.error(loc, f"commit evidence {commit} does not match current mapped file {mapped_file!r}")
    return [item for item in specs if isinstance(item, dict)], [item for item in requirements if isinstance(item, dict)]


def validate_repository(root: Path, base_ref: str | None = None) -> ValidationResult:
    root = root.resolve()
    result = ValidationResult()
    authority = _load_json(root / "specs" / "AUTHORITY.json", result)
    conformance = _load_json(root / "specs" / "CONFORMANCE.json", result)
    if authority is None or conformance is None:
        return result

    domains = _validate_authority_schema(authority, result)
    specs, requirements = _validate_conformance_schema(root, conformance, result)
    schema_authority = _load_json(root / "schemas" / "spec-authority-v1.schema.json", result)
    schema_conformance = _load_json(root / "schemas" / "spec-conformance-v1.schema.json", result)
    schema_pr = _load_json(root / "schemas" / "spec-pr-governance-v1.schema.json", result)
    if isinstance(schema_authority, dict) and schema_authority.get("$id") != "https://github.com/Augustas11/macprovider/schemas/spec-authority-v1.schema.json":
        result.error("schemas/spec-authority-v1.schema.json.$id", "unexpected schema id")
    if isinstance(schema_conformance, dict) and schema_conformance.get("$id") != "https://github.com/Augustas11/macprovider/schemas/spec-conformance-v1.schema.json":
        result.error("schemas/spec-conformance-v1.schema.json.$id", "unexpected schema id")
    if isinstance(schema_pr, dict) and schema_pr.get("$id") != "https://github.com/Augustas11/macprovider/schemas/spec-pr-governance-v1.schema.json":
        result.error("schemas/spec-pr-governance-v1.schema.json.$id", "unexpected schema id")

    if isinstance(authority.get("baseline"), dict) and isinstance(conformance.get("baseline"), dict):
        if authority["baseline"] != conformance["baseline"]:
            result.error("specs", "baselines must match exactly")
    _validate_base_manifest_immutability(root, base_ref, authority, conformance, result)

    canonical_specs = _canonical_spec_files(root, result)
    spec_records: dict[str, dict[str, Any]] = {}
    for spec in specs:
        spec_id = spec.get("spec_id")
        if not isinstance(spec_id, str):
            continue
        if spec_id in spec_records:
            result.error("specs/CONFORMANCE.json", f"duplicate spec_id {spec_id}")
        spec_records[spec_id] = spec
        path_value = spec.get("path")
        if isinstance(path_value, str):
            path = _repository_path(root, path_value, f"{spec_id}.path", result)
            if path is not None:
                if not path.exists():
                    result.error(f"{spec_id}.path", f"referenced SPEC file does not exist: {path_value}")
                else:
                    header = _parse_spec_header(path, result)
                    if header is not None:
                        header_spec_id, title, version = header
                        if spec_id != header_spec_id:
                            result.error(f"{spec_id}.path", f"header spec ID {header_spec_id} does not match manifest spec_id {spec_id}")
                        if spec.get("title") != title:
                            result.error(f"{spec_id}.title", f"does not match SPEC header title {title!r}")
                        if spec.get("version") != version:
                            result.error(f"{spec_id}.version", f"does not match SPEC header version {version!r}")
        if spec.get("status") == "deprecated":
            if spec.get("authority_domains"):
                result.error(spec_id, "deprecated spec must not retain authority domains")
            if not spec.get("superseded_by") and not spec.get("deprecation_rationale"):
                result.error(spec_id, "deprecated spec requires superseded_by or deprecation_rationale")

    for spec_id, path in canonical_specs.items():
        if spec_id not in spec_records:
            result.error("specs/CONFORMANCE.json", f"missing conformance reference for {spec_id} at {path.relative_to(root)}")
    for spec_id in spec_records:
        if spec_id not in canonical_specs:
            result.error("specs/CONFORMANCE.json", f"conformance record {spec_id} has no canonical SPEC file")

    domain_records: dict[str, dict[str, Any]] = {}
    for domain in domains:
        domain_id = domain.get("id")
        owner_spec = domain.get("owner_spec")
        if not isinstance(domain_id, str):
            continue
        if domain_id in domain_records:
            result.error("specs/AUTHORITY.json", f"duplicate authority ownership for {domain_id!r}")
        domain_records[domain_id] = domain
        if isinstance(owner_spec, str) and owner_spec not in spec_records:
            result.error(f"authority domain {domain_id}", f"broken cross-spec reference {owner_spec}")
        for consumer in domain.get("consumers", []) if isinstance(domain.get("consumers"), list) else []:
            if isinstance(consumer, str) and consumer not in spec_records:
                result.error(f"authority domain {domain_id}", f"broken cross-spec reference {consumer}")

    for spec_id, spec in spec_records.items():
        structured_refs: list[str] = []
        for key in ("depends_on", "supersedes", "superseded_by"):
            values = spec.get(key, [])
            if isinstance(values, list):
                structured_refs.extend(item for item in values if isinstance(item, str))
        for reference in sorted(set(structured_refs)):
            if reference not in spec_records:
                result.error(spec_id, f"broken cross-spec reference {reference}")
        for domain_id in spec.get("authority_domains", []) if isinstance(spec.get("authority_domains"), list) else []:
            domain = domain_records.get(domain_id)
            if domain is None:
                result.error(spec_id, f"unknown authority domain {domain_id!r}")
            elif domain.get("status") != "deprecated" and domain.get("owner_spec") != spec_id:
                result.error(spec_id, f"authority domain {domain_id!r} is owned by {domain.get('owner_spec')}")

    requirements_by_id: dict[str, dict[str, Any]] = {}
    requirements_by_spec: dict[str, list[dict[str, Any]]] = {}
    for requirement in requirements:
        requirement_id = requirement.get("requirement_id")
        spec_id = requirement.get("spec_id")
        if isinstance(requirement_id, str):
            if requirement_id in requirements_by_id:
                result.error("specs/CONFORMANCE.json", f"duplicate requirement ID {requirement_id}")
            requirements_by_id[requirement_id] = requirement
        if isinstance(spec_id, str):
            requirements_by_spec.setdefault(spec_id, []).append(requirement)
            if spec_id not in spec_records:
                result.error(str(requirement_id), f"broken cross-spec reference {spec_id}")

    for spec_id, spec in spec_records.items():
        owned_requirements = requirements_by_spec.get(spec_id, [])
        if spec.get("requirement_id_migration") == "complete" and not owned_requirements:
            result.error(spec_id, "complete requirement migration requires at least one structured requirement")
        if spec.get("status") in {"implemented-unverified", "physically-verified"} and not owned_requirements:
            result.error(spec_id, f"{spec.get('status')} requires at least one owned requirement")
        if spec.get("production_status") == "physically-verified":
            result.error(spec_id, "production_status physically-verified requires signed journey-result contract before promotion")
        if spec.get("status") == "physically-verified":
            result.error(spec_id, "physically-verified requires signed journey-result contract before promotion")
            nonconformant = [
                item.get("requirement_id")
                for item in owned_requirements
                if item.get("state") != "conformant"
            ]
            if nonconformant:
                result.error(spec_id, "physically-verified requires every owned requirement to be conformant")

    for requirement_id, requirement in requirements_by_id.items():
        for mapping_key in ("implementation", "tests"):
            for mapping in requirement.get(mapping_key, []) if isinstance(requirement.get(mapping_key), list) else []:
                if isinstance(mapping, str) and mapping.startswith("specs/") and not mapping.startswith(f"specs/{requirement.get('spec_id')}-"):
                    result.error(requirement_id, f"{mapping_key} mapping must not point at another SPEC as implementation")
        for domain_id in spec_records.get(requirement.get("spec_id"), {}).get("authority_domains", []):
            if (
                domain_id in SENSITIVE_PHYSICAL_DOMAINS
                and requirement.get("state") == "conformant"
            ):
                result.error(requirement_id, "sensitive conformant requirement requires signed journey-result contract before promotion")
                if not requirement.get("journeys"):
                    result.error(requirement_id, "sensitive conformant requirement requires a physical journey mapping")
                has_physical_artifact = False
                for evidence in requirement.get("evidence", []):
                    if not isinstance(evidence, dict):
                        continue
                    source = evidence.get("source")
                    artifact = evidence.get("artifact")
                    if (
                        isinstance(source, str)
                        and _source_under_journey_evidence(root, source)
                        and isinstance(artifact, str)
                        and artifact.startswith("sha256:")
                    ):
                        has_physical_artifact = True
                if not has_physical_artifact:
                    result.error(requirement_id, "sensitive conformant requirement requires sha256 journey evidence under journeys/evidence/")

    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=".", help="repository root")
    parser.add_argument("--base-ref", default=None, help="trusted base ref for structured identity immutability checks")
    args = parser.parse_args(argv)
    result = validate_repository(Path(args.root), args.base_ref)
    if result.errors:
        for error in result.errors:
            print(f"error: {error}", file=sys.stderr)
        return 1
    print("SPEC governance validation passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
