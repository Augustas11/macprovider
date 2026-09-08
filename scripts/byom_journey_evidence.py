#!/usr/bin/env python3
"""Shared contract for the two BYOM signed-journey evidence pipelines.

`JOURNEY-PROVIDER-BYOM-DISCOVERY` (SPEC-046) and `JOURNEY-NETWORK-MODEL-ADMISSION`
(SPEC-047) share one capture-then-build shape, so the step tables, redaction
rules, run-manifest contract, and payload projection live here and are consumed by
`capture-byom-journey-evidence.py`, `build-byom-discovery-journey-result.py`, and
`build-network-model-admission-journey-result.py`.

Nothing in this module signs or promotes anything. It only produces the redacted
evidence artifact and the unsigned journey-result payload; the acceptance signing
key stays an operator secret used by `sign-journey-result.py`.
"""

from __future__ import annotations

import hashlib
import json
import re
import subprocess
import sys
import tempfile
from copy import deepcopy
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Any

from check_spec_governance import (
    BYOM_JOURNEY_ENVIRONMENT_CLASSES,
    CREDENTIAL_SHAPE_PATTERN_FRAGMENTS,
    DuplicateJSONKeyError,
    JOURNEY_RESULT_PAYLOAD_SCHEMA,
    NETWORK_MODEL_ADMISSION_ARTIFACT_ID,
    NETWORK_MODEL_ADMISSION_EVIDENCE_PREFIX,
    NETWORK_MODEL_ADMISSION_EVIDENCE_SCHEMA,
    NETWORK_MODEL_ADMISSION_EXECUTION_MODE,
    NETWORK_MODEL_ADMISSION_FALSE_OBSERVATIONS,
    NETWORK_MODEL_ADMISSION_JOURNEY_ID,
    NETWORK_MODEL_ADMISSION_MONEY_PATH_TABLES,
    NETWORK_MODEL_ADMISSION_PROMOTABLE_REQUIREMENT_IDS,
    NETWORK_MODEL_ADMISSION_STEP_ID_ORDER,
    NETWORK_MODEL_ADMISSION_STEP_REQUIREMENT_IDS,
    NETWORK_MODEL_ADMISSION_TRUE_OBSERVATIONS,
    PROVIDER_BYOM_DISCOVERY_ARTIFACT_ID,
    PROVIDER_BYOM_DISCOVERY_EVIDENCE_PREFIX,
    PROVIDER_BYOM_DISCOVERY_EVIDENCE_SCHEMA,
    PROVIDER_BYOM_DISCOVERY_EXECUTION_MODE,
    PROVIDER_BYOM_DISCOVERY_FALSE_OBSERVATIONS,
    PROVIDER_BYOM_DISCOVERY_JOURNEY_ID,
    PROVIDER_BYOM_DISCOVERY_PROMOTABLE_REQUIREMENT_IDS,
    PROVIDER_BYOM_DISCOVERY_STEP_ID_ORDER,
    PROVIDER_BYOM_DISCOVERY_STEP_REQUIREMENT_IDS,
    PROVIDER_BYOM_DISCOVERY_TRUE_OBSERVATIONS,
    ValidationResult,
    _load_json,
    _unique_json_object,
)


RUN_MANIFEST_SCHEMA = "macprovider.byom-journey-run.v1"
REPOSITORY = "Augustas11/macprovider"
DEFAULT_EVIDENCE_LIFETIME_DAYS = 30

REQUIREMENT_RE = re.compile(r"^SPEC-[0-9]{3}-R[0-9]{3}$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
DATETIME_Z_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
DATE_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
SAFE_LABEL_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:@+-]{0,127}$")
DOCUMENT_SCHEMA_RE = re.compile(r"^[a-z][a-z0-9_]*\.v[0-9]+$")
REPO_RELATIVE_FILE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*(?:/[A-Za-z0-9][A-Za-z0-9._-]*)*$")

# Redaction is fail-closed: the emitted evidence must not carry a URL, an
# absolute or home-relative path, a hostname, an IP literal, or anything shaped
# like a credential. Captured CLI documents are digested, never embedded, so the
# operator's raw endpoints and paths never reach the repository.
#
# The hostname rule is shape-based, not a suffix allowlist: anything that looks
# like DNS -- one or more `label.` groups followed by an alphabetic final label --
# is rejected, whatever the TLD. A handful of legitimate evidence values are
# DNS-shaped by coincidence, and they are handled by the explicit
# `HOSTNAME_ALLOWLISTED_VALUE_SHAPES` below rather than by weakening the rule.
DNS_HOSTNAME_RE = re.compile(
    r"(?i)(?<![A-Za-z0-9_.-])"
    r"(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+"
    r"[A-Za-z]{2,63}"
    r"(?![A-Za-z0-9_-])"
)
IPV6_LITERAL_RE = re.compile(
    r"(?<![0-9A-Za-z:])"
    r"(?:"
    r"(?:[0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}"
    r"|(?:[0-9A-Fa-f]{1,4}:){1,7}:"
    r"|(?:[0-9A-Fa-f]{1,4}:){1,6}:[0-9A-Fa-f]{1,4}"
    r"|(?:[0-9A-Fa-f]{1,4}:){1,5}(?::[0-9A-Fa-f]{1,4}){1,2}"
    r"|(?:[0-9A-Fa-f]{1,4}:){1,4}(?::[0-9A-Fa-f]{1,4}){1,3}"
    r"|(?:[0-9A-Fa-f]{1,4}:){1,3}(?::[0-9A-Fa-f]{1,4}){1,4}"
    r"|(?:[0-9A-Fa-f]{1,4}:){1,2}(?::[0-9A-Fa-f]{1,4}){1,5}"
    r"|[0-9A-Fa-f]{1,4}:(?::[0-9A-Fa-f]{1,4}){1,6}"
    r"|:(?::[0-9A-Fa-f]{1,4}){1,7}"
    r")"
    r"(?![0-9A-Za-z:])"
)
# The only DNS-shaped strings this evidence is allowed to carry. A repository
# source file name (`run-cli-onboarding-e2e.py`, `run-manifest.json`) is
# `<name>.<ext>`, which is indistinguishable from a two-label hostname by shape,
# and the evidence records `harness.name` verbatim. Every other value the contract
# emits -- evidence and document schema ids (`...-evidence.v1`, `..._status.v1`),
# step ids, requirement ids, run ids, CLI/semantic versions -- ends in a label
# that is not purely alphabetic, so it never reaches this allowlist at all.
HOSTNAME_ALLOWLISTED_VALUE_SHAPES: tuple[re.Pattern[str], ...] = (
    re.compile(
        r"(?i)^[A-Za-z0-9][A-Za-z0-9._-]*"
        r"\.(?:go|json|jsonl|md|mjs|py|sh|swift|toml|ts|txt|yaml|yml)$"
    ),
)
FORBIDDEN_VALUE_PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("a url", re.compile(r"(?i)[a-z][a-z0-9+.-]*://")),
    ("an absolute path", re.compile(r"(?:^|[\s\"'=,;(\[])(?:/[A-Za-z0-9._~-]+){2,}")),
    ("a home-relative path", re.compile(r"(?:^|[\s\"'=,;(\[])~/")),
    ("an ipv4 literal", re.compile(r"\b[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\b")),
    ("an ipv6 literal", IPV6_LITERAL_RE),
    ("a localhost reference", re.compile(r"(?i)\blocalhost\b")),
)
# Credential shapes come from the governance module so this scanner can never be
# narrower than the sibling signed-journey scanner; the two extras below are
# BYOM-specific and have no counterpart there.
FORBIDDEN_SECRET_VALUE_PATTERNS: tuple[re.Pattern[str], ...] = tuple(
    re.compile(fragment, re.IGNORECASE) for fragment in CREDENTIAL_SHAPE_PATTERN_FRAGMENTS
) + (
    re.compile(r"(?i)\bauthorization\s*:\s*bearer\s+(?!redacted\b)[A-Za-z0-9._~+/=-]{8,}"),
    re.compile(r"(?i)\bprovider-token-[A-Za-z0-9_-]{8,}\b"),
)
FORBIDDEN_KEY_FRAGMENTS: tuple[str, ...] = (
    "absolute_path",
    "authorization_header",
    "base_url",
    "bearer_token",
    "endpoint_origin",
    "endpoint_url",
    "hostname",
    "ip_address",
    "private_key",
    "provider_token",
    "raw_secret",
    "raw_token",
    "secret_key",
    "socket_path",
)


class BYOMEvidenceError(Exception):
    """Raised when captured input fails the closed evidence contract."""


class JourneyContract:
    """Everything one BYOM journey needs, sourced from the governance module."""

    def __init__(
        self,
        *,
        selector: str,
        journey_id: str,
        execution_mode: str,
        evidence_schema: str,
        evidence_prefix: str,
        artifact_id: str,
        step_id_order: tuple[str, ...],
        step_requirement_ids: dict[str, set[str]],
        promotable_requirement_ids: set[str],
        true_observations: set[str],
        false_observations: set[str],
        release_evidence_requirement_id: str,
        money_path_tables: tuple[str, ...] = (),
    ) -> None:
        self.selector = selector
        self.journey_id = journey_id
        self.execution_mode = execution_mode
        self.evidence_schema = evidence_schema
        self.evidence_prefix = evidence_prefix
        self.artifact_id = artifact_id
        self.step_id_order = step_id_order
        self.step_requirement_ids = step_requirement_ids
        self.promotable_requirement_ids = promotable_requirement_ids
        self.true_observations = true_observations
        self.false_observations = false_observations
        self.release_evidence_requirement_id = release_evidence_requirement_id
        self.money_path_tables = money_path_tables

    def allowed_step_requirement_ids(self, step_id: str) -> set[str]:
        # The release-evidence requirement is what the journey as a whole proves,
        # so it is admissible on any step; every other id must be the requirement
        # subject that step actually exercises.
        return self.step_requirement_ids[step_id] | {self.release_evidence_requirement_id}


DISCOVERY_CONTRACT = JourneyContract(
    selector="discovery",
    journey_id=PROVIDER_BYOM_DISCOVERY_JOURNEY_ID,
    execution_mode=PROVIDER_BYOM_DISCOVERY_EXECUTION_MODE,
    evidence_schema=PROVIDER_BYOM_DISCOVERY_EVIDENCE_SCHEMA,
    evidence_prefix=PROVIDER_BYOM_DISCOVERY_EVIDENCE_PREFIX,
    artifact_id=PROVIDER_BYOM_DISCOVERY_ARTIFACT_ID,
    step_id_order=PROVIDER_BYOM_DISCOVERY_STEP_ID_ORDER,
    step_requirement_ids=PROVIDER_BYOM_DISCOVERY_STEP_REQUIREMENT_IDS,
    promotable_requirement_ids=set(PROVIDER_BYOM_DISCOVERY_PROMOTABLE_REQUIREMENT_IDS),
    true_observations=PROVIDER_BYOM_DISCOVERY_TRUE_OBSERVATIONS,
    false_observations=PROVIDER_BYOM_DISCOVERY_FALSE_OBSERVATIONS,
    release_evidence_requirement_id="SPEC-046-R008",
)
ADMISSION_CONTRACT = JourneyContract(
    selector="admission",
    journey_id=NETWORK_MODEL_ADMISSION_JOURNEY_ID,
    execution_mode=NETWORK_MODEL_ADMISSION_EXECUTION_MODE,
    evidence_schema=NETWORK_MODEL_ADMISSION_EVIDENCE_SCHEMA,
    evidence_prefix=NETWORK_MODEL_ADMISSION_EVIDENCE_PREFIX,
    artifact_id=NETWORK_MODEL_ADMISSION_ARTIFACT_ID,
    step_id_order=NETWORK_MODEL_ADMISSION_STEP_ID_ORDER,
    step_requirement_ids=NETWORK_MODEL_ADMISSION_STEP_REQUIREMENT_IDS,
    promotable_requirement_ids=set(NETWORK_MODEL_ADMISSION_PROMOTABLE_REQUIREMENT_IDS),
    true_observations=NETWORK_MODEL_ADMISSION_TRUE_OBSERVATIONS,
    false_observations=NETWORK_MODEL_ADMISSION_FALSE_OBSERVATIONS,
    release_evidence_requirement_id="SPEC-047-R008",
    money_path_tables=NETWORK_MODEL_ADMISSION_MONEY_PATH_TABLES,
)
CONTRACTS: dict[str, JourneyContract] = {
    DISCOVERY_CONTRACT.selector: DISCOVERY_CONTRACT,
    DISCOVERY_CONTRACT.journey_id: DISCOVERY_CONTRACT,
    ADMISSION_CONTRACT.selector: ADMISSION_CONTRACT,
    ADMISSION_CONTRACT.journey_id: ADMISSION_CONTRACT,
}


def contract_for(selector: str) -> JourneyContract:
    try:
        return CONTRACTS[selector]
    except KeyError:
        raise BYOMEvidenceError(f"unknown journey selector: {selector!r}") from None


def fail(message: str) -> None:
    raise BYOMEvidenceError(message)


def require_object(value: Any, location: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        fail(f"{location} must be an object")
    return value


def require_list(value: Any, location: str) -> list[Any]:
    if not isinstance(value, list):
        fail(f"{location} must be an array")
    return value


def require_string(value: Any, pattern: re.Pattern[str] | None, location: str) -> str:
    if not isinstance(value, str) or not value:
        fail(f"{location} must be a non-empty string")
    if pattern is not None and not pattern.fullmatch(value):
        fail(f"{location} has invalid format")
    return value


def require_exact_keys(value: dict[str, Any], required: set[str], allowed: set[str], location: str) -> None:
    observed = set(value)
    missing = sorted(required - observed)
    if missing:
        fail(f"{location} is missing required key(s): {', '.join(missing)}")
    unexpected = sorted(observed - allowed)
    if unexpected:
        fail(f"{location} has unexpected key(s): {', '.join(unexpected)}")


def load_json_object(path: Path, label: str) -> dict[str, Any]:
    result = ValidationResult()
    value = _load_json(path, result)
    if result.errors:
        fail(f"{label} rejected: " + "; ".join(result.errors))
    if not isinstance(value, dict):
        fail(f"{label} must be a JSON object")
    return value


def load_json_object_bytes(path: Path, label: str) -> tuple[dict[str, Any], bytes]:
    try:
        payload = path.read_bytes()
        value = json.loads(payload.decode("utf-8"), object_pairs_hook=_unique_json_object)
    except DuplicateJSONKeyError as exc:
        fail(f"{label} has a duplicate JSON object key: {exc.args[0]!r}")
    except (UnicodeDecodeError, json.JSONDecodeError, OSError) as exc:
        fail(f"{label} rejected: {exc}")
    if not isinstance(value, dict):
        fail(f"{label} must be a JSON object")
    return value, payload


def write_json_atomically(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(value, indent=2, sort_keys=False) + "\n"
    with tempfile.NamedTemporaryFile(
        "w", encoding="utf-8", dir=path.parent, prefix=f".{path.name}.", delete=False
    ) as handle:
        temporary = Path(handle.name)
        handle.write(payload)
    try:
        if path.exists() and path.is_symlink():
            fail(f"output must not be a symlink: {path}")
        temporary.replace(path)
    finally:
        if temporary.exists():
            temporary.unlink()


def reject_forbidden_keys(value: Any, location: str = "$") -> None:
    if isinstance(value, dict):
        for key, item in value.items():
            lowered = key.lower()
            for fragment in FORBIDDEN_KEY_FRAGMENTS:
                if fragment in lowered and not (lowered.endswith("_redacted") and item is True):
                    fail(f"{location}.{key} uses a forbidden secret-bearing field name")
            reject_forbidden_keys(item, f"{location}.{key}")
    elif isinstance(value, list):
        for index, item in enumerate(value):
            reject_forbidden_keys(item, f"{location}[{index}]")


def reject_secret_like_text(text: str, location: str) -> None:
    for pattern in FORBIDDEN_SECRET_VALUE_PATTERNS:
        if pattern.search(text):
            fail(f"{location} contains a credential-like value")


def _is_allowlisted_hostname_shape(candidate: str) -> bool:
    return any(pattern.fullmatch(candidate) for pattern in HOSTNAME_ALLOWLISTED_VALUE_SHAPES)


def reject_hostname_like_text(text: str, location: str) -> None:
    """Fail closed on any DNS-shaped token that is not an allowlisted value shape."""
    for match in DNS_HOSTNAME_RE.finditer(text):
        if not _is_allowlisted_hostname_shape(match.group(0)):
            fail(f"{location} contains a hostname; evidence must stay redacted")


def reject_unredacted_text(text: str, location: str) -> None:
    reject_secret_like_text(text, location)
    for label, pattern in FORBIDDEN_VALUE_PATTERNS:
        if pattern.search(text):
            fail(f"{location} contains {label}; evidence must stay redacted")
    reject_hostname_like_text(text, location)


def assert_redacted(value: Any, location: str = "$") -> None:
    """Fail closed on any URL, path, hostname, IP, or credential in the evidence."""
    reject_forbidden_keys(value, location)
    _walk_redaction(value, location)


def _walk_redaction(value: Any, location: str) -> None:
    if isinstance(value, dict):
        for key, item in value.items():
            reject_unredacted_text(key, f"{location} key {key!r}")
            _walk_redaction(item, f"{location}.{key}")
    elif isinstance(value, list):
        for index, item in enumerate(value):
            _walk_redaction(item, f"{location}[{index}]")
    elif isinstance(value, str):
        reject_unredacted_text(value, location)


def repository_relative(root: Path, value: str, label: str) -> str:
    root = root.resolve()
    candidate = Path(value)
    if candidate.is_absolute():
        fail(f"{label} must be repository-relative")
    normalized = candidate.as_posix()
    if normalized.startswith("../") or "/../" in normalized or normalized in ("..", "."):
        fail(f"{label} must not contain parent traversal")
    resolved = (root / normalized).resolve(strict=False)
    try:
        resolved.relative_to(root)
    except ValueError:
        fail(f"{label} must stay inside the repository")
    return normalized


def require_evidence_source(root: Path, contract: JourneyContract, source: str) -> tuple[str, Path]:
    root = root.resolve()
    normalized = repository_relative(root, source, "redacted evidence source")
    if not normalized.startswith(contract.evidence_prefix) or not normalized.endswith(".redacted.json"):
        fail(f"redacted evidence source must be {contract.evidence_prefix}*.redacted.json")
    candidate = root
    for component in Path(normalized).parts:
        candidate = candidate / component
        if candidate.is_symlink():
            fail(f"redacted evidence source is absent or unsafe: {normalized}")
    path = root / normalized
    if not path.is_file():
        fail(f"redacted evidence source is absent or unsafe: {normalized}")
    return normalized, path


def require_reachable_commit(root: Path, commit: str, label: str) -> None:
    completed = subprocess.run(
        ["git", "cat-file", "-e", f"{commit}^{{commit}}"],
        cwd=root,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if completed.returncode != 0:
        fail(f"{label} is not a reachable commit")


def require_ancestor_commit(root: Path, ancestor: str, descendant: str) -> None:
    completed = subprocess.run(
        ["git", "merge-base", "--is-ancestor", ancestor, descendant],
        cwd=root,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if completed.returncode != 0:
        fail("--source-sha must be an ancestor of --evidence-sha")


def require_git_file_matches(root: Path, commit: str, source: str, expected: bytes) -> None:
    completed = subprocess.run(["git", "show", f"{commit}:{source}"], cwd=root, capture_output=True, check=False)
    if completed.returncode != 0:
        fail("redacted evidence source must exist at --evidence-sha")
    if completed.stdout != expected:
        fail("redacted evidence source bytes must match --evidence-sha")


def parse_requirement_ids(raw: str | None, covered: list[str], contract: JourneyContract) -> list[str]:
    if raw is None:
        selected = list(covered)
    else:
        selected = [item.strip() for item in raw.split(",") if item.strip()]
    if not selected:
        fail("requirement_ids must not be empty")
    if len(set(selected)) != len(selected):
        fail("requirement_ids must be unique")
    invalid = [item for item in selected if not REQUIREMENT_RE.fullmatch(item)]
    if invalid:
        fail(f"invalid requirement id(s): {', '.join(invalid)}")
    overclaimed = [item for item in selected if item not in covered]
    if overclaimed:
        fail(f"requirement ids must be covered by evidence.requirement_ids: {', '.join(sorted(overclaimed))}")
    forbidden = [item for item in selected if item not in contract.promotable_requirement_ids]
    if forbidden:
        fail(f"{contract.journey_id} cannot promote {', '.join(sorted(forbidden))}")
    return selected


def load_mapped_pending_requirements(root: Path, contract: JourneyContract) -> set[str]:
    conformance = load_json_object(root / "specs" / "CONFORMANCE.json", "spec conformance")
    requirements = require_list(conformance.get("requirements"), "specs/CONFORMANCE.json requirements")
    mapped: set[str] = set()
    for row in requirements:
        if not isinstance(row, dict):
            continue
        journeys = row.get("journeys")
        if isinstance(journeys, list) and contract.journey_id in journeys and row.get("state") == "pending":
            requirement_id = row.get("requirement_id")
            if isinstance(requirement_id, str):
                mapped.add(requirement_id)
    return mapped


def _digest_document(manifest_dir: Path, entry: Any, step_id: str, index: int) -> dict[str, Any]:
    location = f"{step_id}.documents[{index}]"
    document = require_object(entry, location)
    require_exact_keys(document, {"id", "schema", "path"}, {"id", "schema", "path"}, location)
    document_id = require_string(document.get("id"), SAFE_LABEL_RE, f"{location}.id")
    schema = require_string(document.get("schema"), DOCUMENT_SCHEMA_RE, f"{location}.schema")
    raw_path = require_string(document.get("path"), None, f"{location}.path")
    candidate = Path(raw_path)
    path = candidate if candidate.is_absolute() else (manifest_dir / candidate)
    if path.is_symlink() or not path.is_file():
        fail(f"{location}.path is absent or unsafe")
    try:
        payload = path.read_bytes()
    except OSError as exc:
        fail(f"{location}.path cannot be read: {exc}")
    try:
        decoded = payload.decode("utf-8")
    except UnicodeDecodeError:
        fail(f"{location}.path must be a UTF-8 CLI JSON document")
    try:
        json.loads(decoded)
    except json.JSONDecodeError as exc:
        fail(f"{location}.path must be a JSON document: {exc}")
    # The document itself is never embedded, but its digest is what the signed
    # journey-result binds to, so the redaction claim has to hold for the bytes we
    # digest: a captured document that still carries a URL, an absolute or
    # home-relative path, a hostname, an IP literal, a localhost reference, or a
    # credential must not be archived at all. There is deliberately no allowlist
    # for raw-document fields -- a CLI document that legitimately needs an
    # endpoint or a path in it is a document the operator redacts before capture.
    reject_unredacted_text(decoded, f"{location}.path")
    return {
        "id": document_id,
        "schema": schema,
        "sha256": hashlib.sha256(payload).hexdigest(),
        "bytes": len(payload),
    }


def validate_evidence_steps(
    contract: JourneyContract, value: Any, *, location: str = "steps"
) -> tuple[list[dict[str, Any]], list[str]]:
    """Validate redacted-evidence steps against one journey contract.

    This is the only step validator. Capture runs it on the steps it derives from
    the run manifest, and the journey-result builders run it again on the
    committed redacted evidence, so hand-authored evidence cannot claim a
    requirement its steps do not actually exercise. It requires the exact step-key
    set for the journey, validates every per-step requirement id against
    `allowed_step_requirement_ids()`, and returns the steps in contract order plus
    the recomputed union of those requirement ids.
    """
    steps = require_list(value, location)
    by_id: dict[str, dict[str, Any]] = {}
    covered: set[str] = set()
    for index, item in enumerate(steps):
        step_location = f"{location}[{index}]"
        step = require_object(item, step_location)
        require_exact_keys(
            step,
            {"id", "status", "assertion", "artifacts", "requirement_ids", "documents"},
            {"id", "status", "assertion", "artifacts", "requirement_ids", "documents"},
            step_location,
        )
        step_id = require_string(step.get("id"), None, f"{step_location}.id")
        if step_id not in contract.step_requirement_ids:
            fail(f"unknown {contract.journey_id} step id: {step_id}")
        if step_id in by_id:
            fail(f"duplicate step id: {step_id}")
        if step.get("status") != "pass":
            fail(f"{step_id}.status must equal 'pass'")
        assertion = require_string(step.get("assertion"), None, f"{step_id}.assertion")
        if step.get("artifacts") != [contract.artifact_id]:
            fail(f"{step_id}.artifacts must reference {contract.artifact_id}")
        requirement_ids = require_list(step.get("requirement_ids"), f"{step_id}.requirement_ids")
        if not requirement_ids:
            fail(f"{step_id}.requirement_ids must not be empty")
        allowed = contract.allowed_step_requirement_ids(step_id)
        normalized_requirements: list[str] = []
        for requirement_index, requirement in enumerate(requirement_ids):
            requirement_id = require_string(
                requirement, REQUIREMENT_RE, f"{step_id}.requirement_ids[{requirement_index}]"
            )
            if requirement_id not in allowed:
                fail(
                    f"{step_id}.requirement_ids: {requirement_id} is not a requirement this step "
                    f"exercises; allowed: {', '.join(sorted(allowed))}"
                )
            if requirement_id in normalized_requirements:
                fail(f"{step_id}.requirement_ids must be unique")
            normalized_requirements.append(requirement_id)
        covered.update(normalized_requirements)
        documents = require_list(step.get("documents"), f"{step_id}.documents")
        if not documents:
            fail(f"{step_id}.documents must reference at least one captured CLI JSON document")
        normalized_documents: list[dict[str, Any]] = []
        for document_index, document in enumerate(documents):
            document_location = f"{step_id}.documents[{document_index}]"
            entry = require_object(document, document_location)
            require_exact_keys(
                entry,
                {"id", "schema", "sha256", "bytes"},
                {"id", "schema", "sha256", "bytes"},
                document_location,
            )
            size = entry.get("bytes")
            if isinstance(size, bool) or not isinstance(size, int) or size <= 0:
                fail(f"{document_location}.bytes must be a positive integer")
            normalized_documents.append(
                {
                    "id": require_string(entry.get("id"), SAFE_LABEL_RE, f"{document_location}.id"),
                    "schema": require_string(
                        entry.get("schema"), DOCUMENT_SCHEMA_RE, f"{document_location}.schema"
                    ),
                    "sha256": require_string(entry.get("sha256"), SHA256_RE, f"{document_location}.sha256"),
                    "bytes": size,
                }
            )
        document_ids = [document["id"] for document in normalized_documents]
        if len(set(document_ids)) != len(document_ids):
            fail(f"{step_id}.documents ids must be unique")
        by_id[step_id] = {
            "id": step_id,
            "status": "pass",
            "assertion": assertion,
            "artifacts": [contract.artifact_id],
            "requirement_ids": sorted(normalized_requirements),
            "documents": normalized_documents,
        }
    missing = [step_id for step_id in contract.step_id_order if step_id not in by_id]
    if missing:
        fail(f"missing {contract.journey_id} step(s): {', '.join(missing)}")
    uncovered = sorted(contract.promotable_requirement_ids - covered)
    if uncovered:
        fail(f"steps do not cover every mapped requirement: {', '.join(uncovered)}")
    return [by_id[step_id] for step_id in contract.step_id_order], sorted(covered)


def _require_manifest_steps(
    manifest_dir: Path, contract: JourneyContract, value: Any
) -> tuple[list[dict[str, Any]], list[str]]:
    """Digest the manifest's captured documents, then apply the shared step validator."""
    steps = require_list(value, "steps")
    candidates: list[dict[str, Any]] = []
    for index, item in enumerate(steps):
        location = f"steps[{index}]"
        step = require_object(item, location)
        require_exact_keys(
            step,
            {"id", "status", "assertion", "requirement_ids", "documents"},
            {"id", "status", "assertion", "requirement_ids", "documents"},
            location,
        )
        step_id = require_string(step.get("id"), None, f"{location}.id")
        documents = require_list(step.get("documents"), f"{step_id}.documents")
        candidates.append(
            {
                "id": step_id,
                "status": step.get("status"),
                "assertion": step.get("assertion"),
                "artifacts": [contract.artifact_id],
                "requirement_ids": step.get("requirement_ids"),
                "documents": [
                    _digest_document(manifest_dir, document, step_id, document_index)
                    for document_index, document in enumerate(documents)
                ],
            }
        )
    return validate_evidence_steps(contract, candidates)


def validate_evidence_observations(contract: JourneyContract, value: Any) -> dict[str, Any]:
    """Validate and normalize the observation block, including the money-path zero rows.

    Shared by capture, the builders, and the governance source re-validation so the
    required-true/required-false names and the money-path zero-row rule have one
    implementation.
    """
    observations = require_object(value, "observations")
    required = set(contract.true_observations) | set(contract.false_observations)
    allowed = set(required)
    if contract.money_path_tables:
        allowed.add("money_path_zero_rows")
        required.add("money_path_zero_rows")
    require_exact_keys(observations, required, allowed, "observations")
    for field in sorted(contract.true_observations):
        if observations.get(field) is not True:
            fail(f"observations.{field} must be true")
    for field in sorted(contract.false_observations):
        if observations.get(field) is not False:
            fail(f"observations.{field} must be false")
    normalized = {field: observations[field] for field in sorted(contract.true_observations | contract.false_observations)}
    if contract.money_path_tables:
        money_path = require_object(observations.get("money_path_zero_rows"), "observations.money_path_zero_rows")
        require_exact_keys(
            money_path,
            set(contract.money_path_tables),
            set(contract.money_path_tables),
            "observations.money_path_zero_rows",
        )
        for table in contract.money_path_tables:
            count = money_path.get(table)
            if isinstance(count, bool) or not isinstance(count, int) or count != 0:
                fail(f"observations.money_path_zero_rows.{table} must be the integer 0")
        normalized["money_path_zero_rows"] = {table: 0 for table in contract.money_path_tables}
    return normalized


def _parse_captured_at(raw: str | None) -> str:
    if raw is None:
        return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return require_string(raw, DATETIME_Z_RE, "--captured-at")


def _parse_expires_at(raw: str | None, captured_at: str) -> str:
    if raw is None:
        captured = datetime.strptime(captured_at, "%Y-%m-%dT%H:%M:%SZ").date()
        return (captured + timedelta(days=DEFAULT_EVIDENCE_LIFETIME_DAYS)).isoformat()
    expires_at = require_string(raw, DATE_RE, "--expires-at")
    if date.fromisoformat(expires_at) < date.today():
        fail("--expires-at must not be in the past")
    return expires_at


def build_evidence(
    root: Path,
    contract: JourneyContract,
    manifest_path: Path,
    *,
    source_sha: str,
    operator_role: str,
    operator_identity_fingerprint: str,
    hardware_profile: str,
    candidate: str,
    captured_at: str | None,
    expires_at: str | None,
    summary: str,
) -> dict[str, Any]:
    require_string(source_sha, COMMIT_RE, "--source-sha")
    require_reachable_commit(root, source_sha, "--source-sha")
    manifest = load_json_object(manifest_path, "run manifest")
    require_exact_keys(
        manifest,
        {"schema_version", "journey_id", "run_id", "environment_class", "cli_version", "harness", "steps", "observations"},
        {"schema_version", "journey_id", "run_id", "environment_class", "cli_version", "harness", "steps", "observations"},
        "run manifest",
    )
    if manifest.get("schema_version") != RUN_MANIFEST_SCHEMA:
        fail(f"run manifest schema_version must equal {RUN_MANIFEST_SCHEMA!r}")
    if manifest.get("journey_id") != contract.journey_id:
        fail(f"run manifest journey_id must equal {contract.journey_id!r}")
    run_id = require_string(manifest.get("run_id"), SAFE_LABEL_RE, "run_id")
    environment_class = require_string(manifest.get("environment_class"), None, "environment_class")
    if environment_class not in BYOM_JOURNEY_ENVIRONMENT_CLASSES:
        fail(f"environment_class must be one of {sorted(BYOM_JOURNEY_ENVIRONMENT_CLASSES)}")
    cli_version = require_string(manifest.get("cli_version"), SAFE_LABEL_RE, "cli_version")

    harness = require_object(manifest.get("harness"), "harness")
    require_exact_keys(harness, {"name", "status"}, {"name", "status"}, "harness")
    harness_name = require_string(harness.get("name"), REPO_RELATIVE_FILE_RE, "harness.name")
    repository_relative(root, harness_name, "harness.name")
    if harness.get("status") != "pass":
        fail("harness.status must equal 'pass'")

    steps, requirement_ids = _require_manifest_steps(
        manifest_path.parent.resolve(), contract, manifest.get("steps")
    )
    observations = validate_evidence_observations(contract, manifest.get("observations"))

    captured = _parse_captured_at(captured_at)
    evidence = {
        "schema_version": contract.evidence_schema,
        "journey_id": contract.journey_id,
        "run_id": run_id,
        "execution_mode": contract.execution_mode,
        "requirement_ids": requirement_ids,
        "repository": {"name": REPOSITORY, "commit": source_sha},
        "captured_at": captured,
        "expires_at": _parse_expires_at(expires_at, captured),
        "operator": {
            "role": require_string(operator_role, SAFE_LABEL_RE, "--operator-role"),
            "identity_fingerprint": require_string(
                operator_identity_fingerprint, SHA256_RE, "--operator-identity-fingerprint"
            ),
        },
        "environment": {
            "class": environment_class,
            "hardware_profile": require_string(hardware_profile, SAFE_LABEL_RE, "--hardware-profile"),
            "candidate": require_string(candidate, SAFE_LABEL_RE, "--candidate"),
        },
        "harness": {"name": harness_name, "status": "pass", "cli_version": cli_version},
        "result": {"status": "pass", "summary": require_string(summary, None, "--summary")},
        "steps": steps,
        "observations": observations,
        "redaction": {
            "secrets_redacted": True,
            "operator_identity_redacted": True,
            "local_account_names_redacted": True,
        },
    }
    assert_redacted(evidence)
    return evidence


def build_journey_result_payload(
    root: Path,
    contract: JourneyContract,
    source: str,
    *,
    source_sha: str,
    evidence_sha: str,
    requirement_ids: str | None,
) -> dict[str, Any]:
    require_string(source_sha, COMMIT_RE, "--source-sha")
    require_string(evidence_sha, COMMIT_RE, "--evidence-sha")
    normalized_source, path = require_evidence_source(root, contract, source)
    evidence, evidence_bytes = load_json_object_bytes(path, "BYOM redacted evidence")
    assert_redacted(evidence)
    if evidence.get("schema_version") != contract.evidence_schema:
        fail(f"schema_version must equal {contract.evidence_schema!r}")
    if evidence.get("journey_id") != contract.journey_id:
        fail(f"journey_id must equal {contract.journey_id!r}")
    if evidence.get("execution_mode") != contract.execution_mode:
        fail(f"execution_mode must equal {contract.execution_mode!r}")

    require_reachable_commit(root, source_sha, "--source-sha")
    require_reachable_commit(root, evidence_sha, "--evidence-sha")
    require_ancestor_commit(root, source_sha, evidence_sha)
    repository = require_object(evidence.get("repository"), "repository")
    if repository.get("name") != REPOSITORY:
        fail(f"repository.name must equal {REPOSITORY!r}")
    if require_string(repository.get("commit"), COMMIT_RE, "repository.commit") != source_sha:
        fail("repository.commit must exactly match --source-sha")
    require_git_file_matches(root, evidence_sha, normalized_source, evidence_bytes)

    # Committed redacted evidence is input, not truth: re-run the same step
    # validator capture used and recompute the requirement union from the steps
    # rather than trusting the top-level list a hand-authored artifact declares.
    validated_steps, covered_ids = validate_evidence_steps(contract, evidence.get("steps"))
    declared = require_list(evidence.get("requirement_ids"), "requirement_ids")
    declared_ids = [require_string(item, REQUIREMENT_RE, "requirement_ids[]") for item in declared]
    if len(set(declared_ids)) != len(declared_ids):
        fail("requirement_ids must be unique")
    if sorted(declared_ids) != covered_ids:
        fail(
            "requirement_ids must equal the union of the evidence step requirement ids: "
            f"expected {', '.join(covered_ids)}"
        )
    selected = parse_requirement_ids(requirement_ids, covered_ids, contract)
    mapped = load_mapped_pending_requirements(root, contract)
    not_mapped = [item for item in selected if item not in mapped]
    if not_mapped:
        fail(
            f"requirement_ids must be pending and mapped to {contract.journey_id}: "
            + ", ".join(sorted(not_mapped))
        )

    captured_at = require_string(evidence.get("captured_at"), DATETIME_Z_RE, "captured_at")
    expires_at = require_string(evidence.get("expires_at"), DATE_RE, "expires_at")
    if date.fromisoformat(expires_at) < date.today():
        fail("expires_at must not be in the past")

    operator = deepcopy(require_object(evidence.get("operator"), "operator"))
    require_string(operator.get("role"), SAFE_LABEL_RE, "operator.role")
    require_string(operator.get("identity_fingerprint"), SHA256_RE, "operator.identity_fingerprint")
    environment = deepcopy(require_object(evidence.get("environment"), "environment"))
    require_exact_keys(
        environment, {"class", "hardware_profile", "candidate"}, {"class", "hardware_profile", "candidate"}, "environment"
    )
    if environment.get("class") not in BYOM_JOURNEY_ENVIRONMENT_CLASSES:
        fail(f"environment.class must be one of {sorted(BYOM_JOURNEY_ENVIRONMENT_CLASSES)}")

    run_result = deepcopy(require_object(evidence.get("result"), "result"))
    if run_result.get("status") != "pass":
        fail("result.status must equal 'pass'")
    require_exact_keys(run_result, {"status"}, {"status", "summary"}, "result")

    observations = validate_evidence_observations(contract, evidence.get("observations"))
    redaction = deepcopy(require_object(evidence.get("redaction"), "redaction"))
    for field in ("secrets_redacted", "operator_identity_redacted", "local_account_names_redacted"):
        if redaction.get(field) is not True:
            fail(f"redaction.{field} must be true")

    # Steps in the signed payload carry only the governance-closed keys; the
    # per-step requirement ids and captured-document digests stay in the
    # hash-bound evidence artifact.
    steps_payload = [
        {
            "id": step["id"],
            "status": "pass",
            "assertion": step["assertion"],
            "artifacts": [contract.artifact_id],
        }
        for step in validated_steps
    ]

    return {
        "schema_version": JOURNEY_RESULT_PAYLOAD_SCHEMA,
        "journey_id": contract.journey_id,
        "requirement_ids": selected,
        "repository": {"name": REPOSITORY, "commit": source_sha},
        "captured_at": captured_at,
        "expires_at": expires_at,
        "operator": operator,
        "environment": environment,
        "artifacts": [
            {
                "id": contract.artifact_id,
                "sha256": hashlib.sha256(evidence_bytes).hexdigest(),
                "source": normalized_source,
            }
        ],
        "result": run_result,
        "steps": steps_payload,
        "redaction": redaction,
        "run_id": require_string(evidence.get("run_id"), SAFE_LABEL_RE, "run_id"),
        "execution_mode": contract.execution_mode,
        "observations": observations,
    }


def run_builder_cli(contract: JourneyContract, argv: list[str] | None, program: str) -> int:
    import argparse

    parser = argparse.ArgumentParser(description=f"Build an unsigned {contract.journey_id} journey-result payload.")
    parser.add_argument("redacted_evidence_source", help=f"{contract.evidence_prefix}*.redacted.json")
    parser.add_argument("--root", default=".", help="repository root")
    parser.add_argument("--output", required=True, help="unsigned journey-result payload output path")
    parser.add_argument("--source-sha", required=True, help="source/build commit captured by the evidence")
    parser.add_argument("--evidence-sha", required=True, help="commit containing the redacted evidence")
    parser.add_argument("--requirement-ids", default=None, help="comma-separated requirement IDs to cover")
    args = parser.parse_args(argv)

    root = Path(args.root).resolve()
    output = Path(args.output)
    if not output.is_absolute():
        output = root / output
    try:
        payload = build_journey_result_payload(
            root,
            contract,
            args.redacted_evidence_source,
            source_sha=args.source_sha,
            evidence_sha=args.evidence_sha,
            requirement_ids=args.requirement_ids,
        )
        write_json_atomically(output, payload)
    except BYOMEvidenceError as exc:
        print(f"{program}: {exc}", file=sys.stderr)
        return 1
    print(f"{program}: wrote {output}")
    return 0
