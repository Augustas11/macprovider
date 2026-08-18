#!/usr/bin/env python3
"""Build a promotable enforce journey-result payload from redacted evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
import tempfile
from copy import deepcopy
from datetime import date
from pathlib import Path
from typing import Any

from check_spec_governance import (
    BUYER_ENFORCE_EXECUTION_MODE,
    BUYER_ENFORCE_JOURNEY_ID,
    BUYER_ENFORCE_PROMOTABLE_REQUIREMENT_IDS,
    BUYER_ENFORCE_STEP_ID_ORDER,
    DuplicateJSONKeyError,
    JOURNEY_RESULT_PAYLOAD_SCHEMA,
    ValidationResult,
    _load_json,
    _unique_json_object,
)


EVIDENCE_SCHEMA = "macprovider.buyer-enforce-evidence.v1"
JOURNEY_ID = "JOURNEY-BUYER-ENFORCE"
REPOSITORY = "Augustas11/macprovider"
ARTIFACT_ID = "redacted-buyer-enforce"
REQUIREMENT_RE = re.compile(r"^SPEC-[0-9]{3}-R[0-9]{3}$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
DATETIME_Z_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
DATE_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
FINGERPRINT_RE = re.compile(r"^[0-9a-f]{64}$")
FORBIDDEN_KEY_FRAGMENTS = (
    "authorization_header",
    "bearer_token",
    "private_key",
    "raw_secret",
    "raw_signature",
    "raw_token",
    "secret_key",
    "wallet_private",
)
FORBIDDEN_SECRET_VALUE_PATTERNS = (
    re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----"),
    re.compile(r"(?i)\bauthorization\s*:\s*bearer\s+(?!redacted\b)[A-Za-z0-9._~+/=-]{8,}"),
    re.compile(r"(?i)\bbearer\s+(?!redacted\b)[A-Za-z0-9._~+/=-]{20,}"),
    re.compile(r"\bghp_[A-Za-z0-9_]{20,}\b"),
    re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}\b"),
    re.compile(r"\bsk-[A-Za-z0-9]{20,}\b"),
    re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{20,}\b"),
    re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    re.compile(r"\bmp_[A-Za-z0-9_-]{16,}\b"),
)


def die(message: str) -> None:
    print(f"build-buyer-enforce-journey-result: {message}", file=sys.stderr)
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


def load_object_bytes(path: Path, label: str) -> tuple[dict[str, Any], bytes]:
    try:
        payload = path.read_bytes()
        value = json.loads(payload.decode("utf-8"), object_pairs_hook=_unique_json_object)
    except DuplicateJSONKeyError as exc:
        print(f"error: {path}: duplicate JSON object key {exc.args[0]!r}", file=sys.stderr)
        die(f"{label} rejected")
    except (UnicodeDecodeError, json.JSONDecodeError, OSError) as exc:
        print(f"error: {path}: {exc}", file=sys.stderr)
        die(f"{label} rejected")
    if not isinstance(value, dict):
        die(f"{label} must be a JSON object")
    return value, payload


def write_json_atomically(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(value, indent=2, sort_keys=False) + "\n"
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent, prefix=f".{path.name}.", delete=False) as handle:
        temporary = Path(handle.name)
        handle.write(payload)
    try:
        if path.exists() and path.is_symlink():
            die(f"output must not be a symlink: {path}")
        temporary.replace(path)
    finally:
        if temporary.exists():
            temporary.unlink()


def repository_relative(root: Path, value: str, label: str) -> str:
    candidate = Path(value)
    if candidate.is_absolute():
        die(f"{label} must be repository-relative")
    normalized = candidate.as_posix()
    if normalized.startswith("../") or "/../" in normalized or normalized == "..":
        die(f"{label} must not contain parent traversal")
    resolved = (root / normalized).resolve(strict=False)
    try:
        resolved.relative_to(root)
    except ValueError:
        die(f"{label} must stay inside the repository")
    return normalized


def require_evidence_source(root: Path, source: str) -> tuple[str, Path]:
    normalized = repository_relative(root, source, "redacted evidence source")
    name = Path(normalized).name
    if not normalized.startswith("journeys/evidence/buyer-enforce-") or not name.endswith(".redacted.json"):
        die("redacted evidence source must be journeys/evidence/buyer-enforce-*.redacted.json")
    path = root / normalized
    candidate = root
    for component in Path(normalized).parts:
        candidate = candidate / component
        if candidate.is_symlink():
            die(f"redacted evidence source is absent or unsafe: {normalized}")
    if not path.is_file() or path.is_symlink():
        die(f"redacted evidence source is absent or unsafe: {normalized}")
    return normalized, path


def require_string(value: Any, pattern: re.Pattern[str] | None, location: str) -> str:
    if not isinstance(value, str) or not value:
        die(f"{location} must be a non-empty string")
    if pattern is not None and not pattern.fullmatch(value):
        die(f"{location} has invalid format")
    return value


def require_object(value: Any, location: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        die(f"{location} must be an object")
    return value


def parse_requirement_ids(raw: str | None, evidence: dict[str, Any]) -> list[str]:
    covered = evidence.get("requirement_ids")
    if not isinstance(covered, list) or not all(isinstance(item, str) for item in covered):
        die("evidence.requirement_ids must be an array of strings")
    if raw is None:
        input_ids = list(covered)
    else:
        input_ids = [item.strip() for item in raw.split(",") if item.strip()]
    if not input_ids:
        die("requirement_ids must not be empty")
    if len(set(input_ids)) != len(input_ids):
        die("requirement_ids must be unique")
    invalid = [item for item in input_ids if not REQUIREMENT_RE.fullmatch(item)]
    if invalid:
        die(f"invalid requirement id(s): {', '.join(invalid)}")
    overclaimed = [item for item in input_ids if item not in covered]
    if overclaimed:
        die(f"--requirement-ids must be covered by evidence.requirement_ids: {', '.join(overclaimed)}")
    allowed = set(BUYER_ENFORCE_PROMOTABLE_REQUIREMENT_IDS)
    forbidden = [item for item in input_ids if item not in allowed]
    if forbidden:
        die(f"enforce journey-result cannot promote {', '.join(forbidden)}")
    return input_ids


def load_mapped_enforce_requirements(root: Path) -> set[str]:
    conformance = load_object(root / "specs" / "CONFORMANCE.json", "spec conformance")
    requirements = conformance.get("requirements")
    if not isinstance(requirements, list):
        die("specs/CONFORMANCE.json requirements must be an array")
    mapped: set[str] = set()
    for row in requirements:
        if not isinstance(row, dict):
            continue
        journeys = row.get("journeys")
        if isinstance(journeys, list) and BUYER_ENFORCE_JOURNEY_ID in journeys and row.get("state") == "pending":
            requirement_id = row.get("requirement_id")
            if isinstance(requirement_id, str):
                mapped.add(requirement_id)
    return mapped


def require_reachable_commit(root: Path, commit: str, label: str) -> None:
    completed = subprocess.run(["git", "cat-file", "-e", f"{commit}^{{commit}}"], cwd=root, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    if completed.returncode != 0:
        die(f"{label} is not a reachable commit")


def require_ancestor_commit(root: Path, ancestor: str, descendant: str) -> None:
    completed = subprocess.run(["git", "merge-base", "--is-ancestor", ancestor, descendant], cwd=root, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    if completed.returncode != 0:
        die("--source-sha must be an ancestor of --evidence-sha")


def require_git_file_matches(root: Path, commit: str, source: str, expected: bytes) -> None:
    completed = subprocess.run(["git", "show", f"{commit}:{source}"], cwd=root, capture_output=True, check=False)
    if completed.returncode != 0:
        die("redacted evidence source must exist at --evidence-sha")
    if completed.stdout != expected:
        die("redacted evidence source bytes must match --evidence-sha")


def require_steps(value: Any) -> list[dict[str, Any]]:
    if not isinstance(value, list):
        die("steps must be an array")
    by_id: dict[str, dict[str, Any]] = {}
    for index, item in enumerate(value):
        step = require_object(item, f"steps[{index}]")
        step_id = require_string(step.get("id"), None, f"steps[{index}].id")
        if step_id in by_id:
            die(f"duplicate step id: {step_id}")
        if step.get("status") != "pass":
            die(f"{step_id}.status must equal 'pass'")
        assertion = require_string(step.get("assertion"), None, f"{step_id}.assertion")
        artifacts = step.get("artifacts")
        if artifacts is None:
            artifacts = [ARTIFACT_ID]
        if not isinstance(artifacts, list) or not artifacts or any(item != ARTIFACT_ID for item in artifacts):
            die(f"{step_id}.artifacts must reference {ARTIFACT_ID}")
        by_id[step_id] = {"id": step_id, "status": "pass", "assertion": assertion, "artifacts": [ARTIFACT_ID]}
    missing = [step_id for step_id in BUYER_ENFORCE_STEP_ID_ORDER if step_id not in by_id]
    extra = [step_id for step_id in by_id if step_id not in BUYER_ENFORCE_STEP_ID_ORDER]
    if missing:
        die(f"missing enforce step(s): {', '.join(missing)}")
    if extra:
        die(f"unknown enforce step(s): {', '.join(extra)}")
    return [by_id[step_id] for step_id in BUYER_ENFORCE_STEP_ID_ORDER]


def reject_forbidden_secret_keys(value: Any, location: str = "$") -> None:
    if isinstance(value, dict):
        for key, item in value.items():
            lowered = key.lower()
            if any(fragment in lowered for fragment in FORBIDDEN_KEY_FRAGMENTS):
                if not (lowered.endswith("_redacted") and item is True):
                    die(f"{location}.{key} uses a forbidden secret-bearing field name")
            reject_forbidden_secret_keys(item, f"{location}.{key}")
    elif isinstance(value, list):
        for index, item in enumerate(value):
            reject_forbidden_secret_keys(item, f"{location}[{index}]")
    elif isinstance(value, str):
        if any(pattern.search(value) for pattern in FORBIDDEN_SECRET_VALUE_PATTERNS):
            die(f"{location} contains a forbidden secret-like value")


def require_observations(value: Any) -> dict[str, Any]:
    observations = require_object(value, "observations")
    required = {
        "settlement_mode_start",
        "enforce_activated",
        "job_enabled",
        "payout_ready_mutated",
        "production_side_effects",
        "production_pearl",
        "isolated_environment",
        "raw_prompt_output_redacted",
    }
    missing = required - set(observations)
    if missing:
        die(f"observations missing keys: {sorted(missing)}")
    if observations.get("settlement_mode_start") != "enforce":
        die("observations.settlement_mode_start must equal 'enforce'")
    if observations.get("enforce_activated") is not True:
        die("observations.enforce_activated must be true")
    if observations.get("job_enabled") is not False:
        die("observations.job_enabled must be false")
    for field in ("payout_ready_mutated", "production_side_effects", "production_pearl"):
        if observations.get(field) is not False:
            die(f"observations.{field} must be false")
    for field in ("isolated_environment", "raw_prompt_output_redacted"):
        if observations.get(field) is not True:
            die(f"observations.{field} must be true")
    return deepcopy(observations)


def build_payload(root: Path, source: str, *, source_sha: str, evidence_sha: str, requirement_ids: str | None) -> dict[str, Any]:
    require_string(source_sha, COMMIT_RE, "--source-sha")
    require_string(evidence_sha, COMMIT_RE, "--evidence-sha")
    source, path = require_evidence_source(root, source)
    evidence, evidence_bytes = load_object_bytes(path, "enforce redacted evidence")
    reject_forbidden_secret_keys(evidence)
    if evidence.get("schema_version") != EVIDENCE_SCHEMA:
        die(f"schema_version must equal {EVIDENCE_SCHEMA!r}")
    if evidence.get("journey_id") != JOURNEY_ID:
        die(f"journey_id must equal {JOURNEY_ID!r}")
    if JOURNEY_ID != BUYER_ENFORCE_JOURNEY_ID:
        die("JOURNEY_ID drifted from BUYER_ENFORCE_JOURNEY_ID")
    require_reachable_commit(root, source_sha, "--source-sha")
    require_reachable_commit(root, evidence_sha, "--evidence-sha")
    require_ancestor_commit(root, source_sha, evidence_sha)
    repository = require_object(evidence.get("repository"), "repository")
    if repository.get("name") != REPOSITORY:
        die(f"repository.name must equal {REPOSITORY!r}")
    evidence_source_sha = require_string(repository.get("commit"), COMMIT_RE, "repository.commit")
    if evidence_source_sha != source_sha:
        die("repository.commit must exactly match --source-sha")
    require_git_file_matches(root, evidence_sha, source, evidence_bytes)

    selected_requirements = parse_requirement_ids(requirement_ids, evidence)
    mapped = load_mapped_enforce_requirements(root)
    not_mapped = [item for item in selected_requirements if item not in mapped]
    if not_mapped:
        die(f"requirement_ids must be pending and mapped to {BUYER_ENFORCE_JOURNEY_ID}: {', '.join(not_mapped)}")

    captured_at = require_string(evidence.get("captured_at"), DATETIME_Z_RE, "captured_at")
    expires_at = require_string(evidence.get("expires_at"), DATE_RE, "expires_at")
    if date.fromisoformat(expires_at) < date.today():
        die("expires_at must not be in the past")
    operator = deepcopy(require_object(evidence.get("operator"), "operator"))
    require_string(operator.get("role"), None, "operator.role")
    require_string(operator.get("identity_fingerprint"), FINGERPRINT_RE, "operator.identity_fingerprint")
    environment = deepcopy(require_object(evidence.get("environment"), "environment"))
    for field in ("class", "hardware_profile", "candidate"):
        require_string(environment.get(field), None, f"environment.{field}")
    if environment.get("class") != BUYER_ENFORCE_EXECUTION_MODE:
        die(f"environment.class must equal {BUYER_ENFORCE_EXECUTION_MODE!r}")
    result = deepcopy(require_object(evidence.get("result"), "result"))
    if result.get("status") != "pass":
        die("result.status must equal 'pass'")
    if "summary" in result:
        require_string(result.get("summary"), None, "result.summary")
    steps = require_steps(evidence.get("steps"))
    redaction = deepcopy(require_object(evidence.get("redaction"), "redaction"))
    for field in ("secrets_redacted", "operator_identity_redacted", "local_account_names_redacted"):
        if redaction.get(field) is not True:
            die(f"redaction.{field} must be true")
    observations = require_observations(evidence.get("observations"))
    artifact_sha = hashlib.sha256(evidence_bytes).hexdigest()
    run_id = require_string(evidence.get("run_id"), None, "run_id")

    return {
        "schema_version": JOURNEY_RESULT_PAYLOAD_SCHEMA,
        "journey_id": JOURNEY_ID,
        "requirement_ids": selected_requirements,
        "repository": {"name": REPOSITORY, "commit": source_sha},
        "captured_at": captured_at,
        "expires_at": expires_at,
        "operator": operator,
        "environment": environment,
        "artifacts": [{"id": ARTIFACT_ID, "sha256": artifact_sha, "source": source}],
        "result": result,
        "steps": steps,
        "redaction": redaction,
        "run_id": run_id,
        "execution_mode": BUYER_ENFORCE_EXECUTION_MODE,
        "observations": observations,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("redacted_evidence_source", help="journeys/evidence/buyer-enforce-*.redacted.json")
    parser.add_argument("--root", default=".", help="repository root")
    parser.add_argument("--output", required=True, help="unsigned journey-result payload output path")
    parser.add_argument("--source-sha", required=True, help="expected source/build commit captured by the evidence")
    parser.add_argument("--evidence-sha", required=True, help="expected repository commit containing the redacted evidence")
    parser.add_argument("--requirement-ids", default=None, help="comma-separated requirement IDs to cover")
    args = parser.parse_args(argv)

    root = Path(args.root).resolve()
    output = Path(args.output)
    if not output.is_absolute():
        output = root / output
    payload = build_payload(
        root,
        args.redacted_evidence_source,
        source_sha=args.source_sha,
        evidence_sha=args.evidence_sha,
        requirement_ids=args.requirement_ids,
    )
    write_json_atomically(output, payload)
    print(f"build-buyer-enforce-journey-result: wrote {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
