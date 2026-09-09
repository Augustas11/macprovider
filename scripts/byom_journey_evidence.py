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
# DNS-shaped by coincidence (repository source file names); they are permitted
# only in the structurally validated `REPO_SOURCE_FILE_FIELDS` below, never by a
# global allowlist, so `provider-mac.sh` in free text still fails closed.
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
# Repository source file names (`test/e2e/byom/run-cli-onboarding-e2e.py`,
# `run-manifest.json`) are `<name>.<ext>` and therefore DNS-shaped by
# coincidence. They are accepted ONLY at the JSON paths in
# `REPO_SOURCE_FILE_FIELDS`, which capture validates structurally; the global
# hostname rule has no allowlist, so a `.sh`/`.md`/`.py`-suffixed token in an
# assertion or a captured value is still a hostname and fails closed. Every
# other value the contract emits -- evidence and document schema ids
# (`...-evidence.v1`, `..._status.v1`), step ids, requirement ids, run ids,
# CLI/semantic versions -- ends in a label that is not purely alphabetic, so it
# is not DNS-shaped at all.
REPO_SOURCE_FILE_NAME_RE = re.compile(
    r"(?i)^[A-Za-z0-9][A-Za-z0-9._-]*(?:/[A-Za-z0-9][A-Za-z0-9._-]*)*"
    r"\.(?:go|json|jsonl|md|mjs|py|sh|swift|toml|ts|txt|yaml|yml)$"
)
REPO_SOURCE_FILE_FIELDS = frozenset({"$.harness.name"})
# SPEC-046-R003 requires every `provider_guidance` object to carry
# `state_label_key` and `state_meaning_key`. Those two values are dotted
# localization label paths (`byom.local.offerable`) and are therefore DNS-shaped
# by coincidence, exactly like the repository source-file names above. Captured
# CLI documents are archived whole -- deleting the fields would leave the digest
# proving nothing about them -- so they get the same treatment: a closed grammar
# checked at exactly those two field names inside a `provider_guidance` object,
# at any depth, with every other rule (credential, URL, absolute/home path,
# IPv4, IPv6, localhost) still applied to the value. Anything that is not a
# whole localization key fails closed, and a localization-key-shaped string in
# any other field is still just a hostname. The exemption is scoped to captured
# CLI documents: the emitted-evidence scan (`assert_redacted`) has no exemption
# at all, and evidence never carries a `provider_guidance` object.
GUIDANCE_OBJECT_KEY = "provider_guidance"
GUIDANCE_LOCALIZATION_KEY_FIELDS = frozenset({"state_label_key", "state_meaning_key"})
LOCALIZATION_KEY_RE = re.compile(r"^byom\.[a-z0-9_]+(?:\.[a-z0-9_]+)+$")
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
        expected_harness_name: str,
        step_id_order: tuple[str, ...],
        step_requirement_ids: dict[str, set[str]],
        promotable_requirement_ids: set[str],
        true_observations: set[str],
        false_observations: set[str],
        release_evidence_requirement_id: str,
        typed_capture_validation: bool,
        money_path_tables: tuple[str, ...] = (),
    ) -> None:
        self.selector = selector
        self.journey_id = journey_id
        self.execution_mode = execution_mode
        self.evidence_schema = evidence_schema
        self.evidence_prefix = evidence_prefix
        self.artifact_id = artifact_id
        # The one harness whose run manifest may back this journey's evidence.
        # Without it the contract accepted any existing repository-relative
        # source file, so a discovery manifest could claim the admission
        # harness's provenance (R4 MEDIUM).
        self.expected_harness_name = expected_harness_name
        self.step_id_order = step_id_order
        self.step_requirement_ids = step_requirement_ids
        self.promotable_requirement_ids = promotable_requirement_ids
        self.true_observations = true_observations
        self.false_observations = false_observations
        self.release_evidence_requirement_id = release_evidence_requirement_id
        # Whether `_digest_document` runs the typed closed-enum capture
        # validators over this journey's documents. See the SCOPE note above
        # `validate_captured_cli_document`: the discovery journey has a
        # hermetic driver producing real CLI captures, so its documents are
        # validated in full. The admission journey's captures cannot be
        # produced end to end until catalog binding exists, so it keeps the
        # earlier boundary (redaction scans plus top-level `schema` equality)
        # until the admission-journey slice (epic #1453 slice 7) captures it.
        self.typed_capture_validation = typed_capture_validation
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
    expected_harness_name="test/e2e/byom/run-discovery-journey.py",
    step_id_order=PROVIDER_BYOM_DISCOVERY_STEP_ID_ORDER,
    step_requirement_ids=PROVIDER_BYOM_DISCOVERY_STEP_REQUIREMENT_IDS,
    promotable_requirement_ids=set(PROVIDER_BYOM_DISCOVERY_PROMOTABLE_REQUIREMENT_IDS),
    true_observations=PROVIDER_BYOM_DISCOVERY_TRUE_OBSERVATIONS,
    false_observations=PROVIDER_BYOM_DISCOVERY_FALSE_OBSERVATIONS,
    release_evidence_requirement_id="SPEC-046-R008",
    typed_capture_validation=True,
)
ADMISSION_CONTRACT = JourneyContract(
    selector="admission",
    journey_id=NETWORK_MODEL_ADMISSION_JOURNEY_ID,
    execution_mode=NETWORK_MODEL_ADMISSION_EXECUTION_MODE,
    evidence_schema=NETWORK_MODEL_ADMISSION_EVIDENCE_SCHEMA,
    evidence_prefix=NETWORK_MODEL_ADMISSION_EVIDENCE_PREFIX,
    artifact_id=NETWORK_MODEL_ADMISSION_ARTIFACT_ID,
    expected_harness_name="test/e2e/byom/run-cli-onboarding-e2e.py",
    step_id_order=NETWORK_MODEL_ADMISSION_STEP_ID_ORDER,
    step_requirement_ids=NETWORK_MODEL_ADMISSION_STEP_REQUIREMENT_IDS,
    promotable_requirement_ids=set(NETWORK_MODEL_ADMISSION_PROMOTABLE_REQUIREMENT_IDS),
    true_observations=NETWORK_MODEL_ADMISSION_TRUE_OBSERVATIONS,
    false_observations=NETWORK_MODEL_ADMISSION_FALSE_OBSERVATIONS,
    release_evidence_requirement_id="SPEC-047-R008",
    # Scoped off in this slice; see `typed_capture_validation` above.
    typed_capture_validation=False,
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


def reject_hostname_like_text(text: str, location: str) -> None:
    """Fail closed on any DNS-shaped token; there is no value-shape allowlist."""
    if DNS_HOSTNAME_RE.search(text):
        fail(f"{location} contains a hostname; evidence must stay redacted")


def reject_unredacted_text_except_hostname(text: str, location: str) -> None:
    """Every redaction rule except the shape-based DNS hostname rule."""
    reject_secret_like_text(text, location)
    for label, pattern in FORBIDDEN_VALUE_PATTERNS:
        if pattern.search(text):
            fail(f"{location} contains {label}; evidence must stay redacted")


def reject_unredacted_repo_source_file(value: str, location: str) -> None:
    """Scoped rule for the repository source file-name fields.

    Runs every scan except the hostname rule, then requires the whole value to be
    a repository-relative source file name with a known extension.
    """
    reject_unredacted_text_except_hostname(value, location)
    if ".." in Path(value).parts or not REPO_SOURCE_FILE_NAME_RE.fullmatch(value):
        fail(f"{location} must be a repository-relative source file name")


def reject_unredacted_localization_key(value: str, location: str) -> None:
    """Scoped rule for `provider_guidance.state_label_key` / `state_meaning_key`.

    Runs every scan except the hostname rule, then requires the WHOLE value to
    match the closed localization-key grammar. A value that is a hostname, a
    partial key, or anything else fails closed.
    """
    reject_unredacted_text_except_hostname(value, location)
    if not LOCALIZATION_KEY_RE.fullmatch(value):
        fail(f"{location} must be a closed byom localization key")


def reject_unredacted_text(text: str, location: str) -> None:
    reject_unredacted_text_except_hostname(text, location)
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
        if location in REPO_SOURCE_FILE_FIELDS:
            reject_unredacted_repo_source_file(value, location)
        else:
            reject_unredacted_text(value, location)


def assert_captured_document_redacted(value: Any, location: str = "$") -> None:
    """Fail-closed scan for a whole captured CLI document.

    Identical to `assert_redacted` except that inside a `provider_guidance`
    object -- at any depth, so candidate rows and top-level evaluation, dry-run,
    and status documents are all covered -- the two SPEC-046-R003
    localization-key fields are validated against the closed localization-key
    grammar instead of the shape-based hostname rule. Every other key and every
    other string value, including any other field of the same guidance object,
    keeps the full rule set.
    """
    reject_forbidden_keys(value, location)
    _walk_captured_document(value, location, in_guidance=False)


def _walk_captured_document(value: Any, location: str, *, in_guidance: bool) -> None:
    if isinstance(value, dict):
        for key, item in value.items():
            reject_unredacted_text(key, f"{location} key {key!r}")
            if in_guidance and key in GUIDANCE_LOCALIZATION_KEY_FIELDS and isinstance(item, str):
                reject_unredacted_localization_key(item, f"{location}.{key}")
                continue
            _walk_captured_document(
                item,
                f"{location}.{key}",
                in_guidance=(key == GUIDANCE_OBJECT_KEY and isinstance(item, dict)),
            )
    elif isinstance(value, list):
        for index, item in enumerate(value):
            _walk_captured_document(item, f"{location}[{index}]", in_guidance=False)
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


# --- Closed CLI-document schemas -------------------------------------------
#
# A captured CLI document is the thing the signed evidence digests, so the
# digest is only a conformance claim if the document is COMPLETE. Redaction
# alone is not enough: a discovery envelope that stopped emitting `capabilities`,
# or an evaluation whose `mutation_summary` carried one field, is redaction-clean
# and still a false claim. These key sets are therefore enforced here, at the
# capture trust boundary (`_digest_document`), not in whichever harness produced
# the document, so a hand-authored physical discovery run goes through the same
# gate as the hermetic discovery driver.
#
# SCOPE (epic #1453 slice 1b): these schemas cover the DISCOVERY journey's
# documents only -- `provider_byom_discovery.v1`, `provider_byom_evaluation.v1`,
# `model_admission_offer_dry_run.v1`, `model_admission_status.v1`, and
# `model_catalog_economics.v1` as the discovery driver emits them. The admission
# journey (`JOURNEY-NETWORK-MODEL-ADMISSION`) is NOT typed-validated here: see
# `JourneyContract.typed_capture_validation` and the note in `_digest_document`.
#
# Every set is exact: a missing key and an unknown key both fail closed. The
# field lists are the normative ones -- SPEC-046-R003 (discovery envelope,
# candidate, provider_guidance), SPEC-046-R004 (capability object), SPEC-046-R005
# (evaluation envelope), SPEC-047-R002 (dry-run and status envelopes) -- except
# the two the specs describe without enumerating field names, `adapters[]` rows
# and the `model_catalog_economics.v1` row, which are frozen here at the shape
# the CLI actually emits so a silent projection change fails closed rather than
# passing unnoticed.

DISCOVERY_ENVELOPE_KEYS = frozenset({
    "schema", "generated_at", "cli_version", "projection_sequence",
    "adapters", "candidates", "warnings",
})
DISCOVERY_ADAPTER_KEYS = frozenset({
    "runtime_source", "origin_class", "status", "warning_codes",
})
DISCOVERY_CANDIDATE_KEYS = frozenset({
    "candidate_id", "runtime_source", "display_name", "served_model_ref",
    "catalog_model_key", "identity_state", "locality", "estimated_gb",
    "context_window_tokens", "capabilities", "readiness_state", "fit_state",
    "evaluation_state", "admission_state", "admission_state_source",
    "provider_guidance", "warning_codes",
})
# SPEC-046-R004, exactly.
CAPABILITY_KEYS = frozenset({
    "chat_completions", "streaming", "tool_call_passthrough",
    "structured_output_passthrough", "json_mode", "usage_reporting",
    "max_context_tokens", "quantization", "family", "runtime_version",
})
# SPEC-046-R003; SPEC-047-R002 requires the dry-run and status envelopes to
# reuse this same object.
PROVIDER_GUIDANCE_KEYS = frozenset({
    "state_label_key", "state_meaning_key", "next_action",
    "transition_reason_code", "earning_path_class",
})
EVALUATION_ENVELOPE_KEYS = frozenset({
    "schema", "generated_at", "cli_version", "candidate_id", "runtime_source",
    "served_model_ref", "catalog_model_key", "adapter_identity",
    "health_result", "latency_ms", "tokens_per_second", "completion_tokens",
    "output_bytes", "request_count", "usage_reporting_source",
    "capability_results", "fit_estimate_source", "mutation_summary",
    "diagnostic_hashes", "provider_guidance",
    "offer_preconditions_appear_satisfied", "warnings",
})
EVALUATION_MUTATION_SUMMARY_KEYS = frozenset({
    "production_config_mutated", "production_model_switched", "runtime_started",
    "downloads_started", "temporary_files_created", "coordinator_state_mutated",
})
# SPEC-047-R002, exactly.
OFFER_DRY_RUN_ENVELOPE_KEYS = frozenset({
    "schema", "generated_at", "cli_version", "candidate_id", "served_model_ref",
    "catalog_model_key", "would_submit", "likely_admission_state",
    "likely_admission_state_source", "provider_guidance", "reason_code",
    "warnings",
})
ADMISSION_STATUS_ENVELOPE_KEYS = frozenset({
    "schema", "generated_at", "cli_version", "provider_id", "candidate_id",
    "served_model_ref", "catalog_model_key", "admission_state",
    "admission_state_source", "coordinator_event_id", "state_observed_at",
    "provider_guidance", "allowed_next_states", "warnings",
})
CATALOG_ECONOMICS_ENVELOPE_KEYS = frozenset({
    "schema", "generated_at", "projection_sequence", "source", "rows", "warnings",
})
CATALOG_ECONOMICS_ROW_KEYS = frozenset({
    "model_key", "display_model_id", "served_model_id", "action_model_id",
    "is_current", "runtime_state", "economics_state", "admission", "fit",
    "estimated_gb", "weights_present_locally", "ready_provider_count",
    "demand_rank", "demand_weight", "supply_deficit_score",
    "prompt_rate_usd_per_million_tokens", "completion_rate_usd_per_million_tokens",
    "provider_prompt_payout_usd_per_million_tokens",
    "provider_completion_payout_usd_per_million_tokens", "provider_share_bps",
    "rate_source", "rate_card_key", "rate_card_version", "rate_card_generated_at",
    "adopt_recommendation", "prepare", "evaluate", "switch", "cleanup_staging",
    "disabled_reason", "warning_codes",
})
CATALOG_ECONOMICS_ADMISSION_KEYS = frozenset({
    "state", "source", "settlement_capable", "catalog_economics_permitted",
    "coordinator_event_id", "state_observed_at",
})
# `model_catalog_economics.v1` nested objects. The spec does not enumerate these
# either, so -- like the row itself -- they are frozen at the shape
# `ModelCatalogEconomicsWire.Source` / `.Action` actually encodes. The R4 audit
# found hand-authored fixtures carrying `prepare: false` and a string `source`
# where the CLI emits objects; only a shape check catches that.
CATALOG_ECONOMICS_SOURCE_KEYS = frozenset({
    "cli_version", "cli_build_commit", "process_launch_id", "process_started_at",
    "projection_protocol_version", "rate_card_source", "rate_card_digest",
    "rate_card_signature_digest", "demand_feed_digest", "candidate_feed_digest",
    "rate_card_max_age_seconds",
})
CATALOG_ECONOMICS_ACTION_KEYS = frozenset({
    "available", "requires_confirmation", "transaction_kind", "transaction_id",
    "action_timeout_seconds", "estimated_bytes", "unavailable_reason",
})
CATALOG_ECONOMICS_ACTION_FIELDS = (
    "switch", "prepare", "evaluate", "adopt_recommendation", "cleanup_staging",
)

# --- Closed value enums ----------------------------------------------------
#
# Exact key sets prove a document is COMPLETE; they do not prove its values are
# ones the CLI can emit. The R4 audit showed that gap concretely: fixtures
# carrying `identity_state: declared_local`, `locality: local_weights`,
# `evaluation_state: evaluated`, and `next_action: serve_traffic` passed
# validation and could have backed signed evidence. Every enum below is
# transcribed from the normative spec text; where a spec deliberately leaves a
# field's vocabulary to the implementation, the set is frozen from the CLI
# encoder instead and says so.

# SPEC-046-R002 v0.1 adapter enum, exactly.
RUNTIME_SOURCES = frozenset({
    "mlx_cache", "ollama_loopback", "lmstudio_loopback", "llamacpp_loopback",
    "openai_compatible_loopback",
})
# SPEC-046-R003 candidate enums, exactly.
IDENTITY_STATES = frozenset({
    "catalog_matched", "artifact_hash_available", "runtime_reported",
    "opaque_endpoint", "unknown",
})
LOCALITIES = frozenset({
    "local_artifact", "loopback_runtime", "opaque_local_endpoint", "unknown",
})
READINESS_STATES = frozenset({
    "ready", "needs_runtime", "needs_weights", "requires_preparation",
    "unreachable", "unknown",
})
FIT_STATES = frozenset({"fits", "does_not_fit", "unknown"})
EVALUATION_STATES = frozenset({
    "not_evaluated", "running", "passed", "failed", "timed_out", "blocked",
})
ADMISSION_STATE_SOURCES = frozenset({"local_default", "coordinator"})
# SPEC-046-R003 `admission_state`, all twelve values.
ADMISSION_STATES = frozenset({
    "local_only", "not_offered", "offerable", "offer_submitted", "offer_rejected",
    "sandbox_probe_only", "network_visible_unpriced", "network_admitted_unsettled",
    "catalog_priced", "settlement_capable", "withdrawn", "revoked",
})
# SPEC-046-R003: under `admission_state_source: local_default` the CLI may only
# report its own local ladder. A network state carried on a local default would
# be the CLI promoting a candidate no coordinator ever admitted.
LOCAL_DEFAULT_ADMISSION_STATES = frozenset({"local_only", "not_offered", "offerable"})
# SPEC-047-R001 v0.1 coordinator states, exactly. `local_only` and `offerable`
# are CLI-only inventory states and are deliberately absent.
COORDINATOR_ADMISSION_STATES = frozenset({
    "not_offered", "offer_submitted", "offer_rejected", "sandbox_probe_only",
    "network_visible_unpriced", "network_admitted_unsettled", "catalog_priced",
    "settlement_capable", "withdrawn", "revoked",
})
# SPEC-047-R001 transition table. `allowed_next_states` must be a subset of the
# row for the state the document reports: a document offering an edge the state
# machine has no row for is not readback of any legal coordinator state.
ADMISSION_ALLOWED_NEXT_STATES = {
    "not_offered": frozenset({"offer_submitted"}),
    "offer_submitted": frozenset({
        "offer_rejected", "sandbox_probe_only", "network_visible_unpriced",
        "network_admitted_unsettled", "catalog_priced", "withdrawn", "revoked",
    }),
    "offer_rejected": frozenset({"offer_submitted", "revoked"}),
    "sandbox_probe_only": frozenset({
        "network_visible_unpriced", "network_admitted_unsettled", "catalog_priced",
        "withdrawn", "revoked",
    }),
    "network_visible_unpriced": frozenset({
        "network_admitted_unsettled", "catalog_priced", "withdrawn", "revoked",
    }),
    "network_admitted_unsettled": frozenset({
        "catalog_priced", "settlement_capable", "withdrawn", "revoked",
    }),
    "catalog_priced": frozenset({
        "network_admitted_unsettled", "settlement_capable", "withdrawn", "revoked",
    }),
    "settlement_capable": frozenset({
        "network_admitted_unsettled", "catalog_priced", "withdrawn", "revoked",
    }),
    "withdrawn": frozenset({"offer_submitted"}),
    "revoked": frozenset({"offer_submitted"}),
}
# SPEC-046-R003 `provider_guidance` enums, exactly.
NEXT_ACTIONS = frozenset({
    "fix_local_blocker", "evaluate", "offer_dry_run", "submit_offer",
    "revise_and_reoffer", "check_status", "withdraw", "wait_for_coordinator",
    "maintain_runtime", "none",
})
EARNING_PATH_CLASSES = frozenset({
    "local_inventory_only", "not_earning_yet_catalog_or_receipt_path_exists",
    "no_earning_path_in_v0_1", "settlement_capable",
})
# SPEC-046-R003 warning-code enum plus the four R007 redaction-provenance codes,
# which that section adds to the same enum. Mirrors `BYOMDiscoveryWarning`.
WARNING_CODES = frozenset({
    "candidate_id_unstable", "adapter_unavailable", "adapter_timeout",
    "adapter_rejected_non_loopback", "adapter_malformed_response",
    "adapter_response_truncated", "catalog_match_unverified",
    "capability_unevaluated", "evaluation_required", "evaluation_failed",
    "requires_preparation", "namespace_permission_invalid",
    "coordinator_state_unavailable", "capability_family_redacted",
    "capability_quantization_redacted", "capability_runtime_version_redacted",
    "model_reference_redacted",
})
# The vocabularies below are left to the implementation by their specs, so each
# set is frozen from the CLI encoder rather than from spec text. A CLI that
# starts emitting a value outside one of them fails capture, which is the
# intended outcome: an unreviewed projection change must not silently back
# signed evidence.
#
# `adapters[].status`: BYOMDiscovery.swift emits exactly these six.
ADAPTER_STATUSES = frozenset({
    "ok", "unavailable", "timeout", "malformed", "truncated", "rejected",
})
# `adapters[].origin_class`: null for a non-HTTP adapter such as `mlx_cache`.
ORIGIN_CLASSES = frozenset({"loopback_http", "rejected"})
# `provider_byom_evaluation.v1` scalars, from the evaluation encoder.
EVALUATION_HEALTH_RESULTS = frozenset({"passed", "failed", "blocked"})
EVALUATION_ADAPTER_IDENTITIES = frozenset({
    "openai_compatible_loopback", "mlx_cache_local_artifact", "unknown",
})
EVALUATION_USAGE_REPORTING_SOURCES = frozenset({
    "runtime_reported", "absent", "not_evaluated",
})
EVALUATION_FIT_ESTIMATE_SOURCES = frozenset({"discovery_fit_state"})
# A blocked evaluation reports `runtime_source: "unknown"` for a candidate it
# never resolved, so the evaluation envelope admits one value discovery does not.
EVALUATION_RUNTIME_SOURCES = RUNTIME_SOURCES | {"unknown"}
# SPEC-046-R005 capability test results; the CLI models each as an object, not a
# bare string. The R4 audit found a fixture using strings here.
EVALUATION_CAPABILITY_RESULT_KEYS = frozenset({"result", "source", "reason_code"})
EVALUATION_CAPABILITY_RESULTS = frozenset({"passed", "failed", "not_tested"})
EVALUATION_CAPABILITY_SOURCES = frozenset({
    "evaluation", "not_evaluated", "runtime_reported", "absent",
})
# SPEC-046-R005 requires transcripts to be content-hashed, never retained; these
# are the hash fields the evaluation encoder emits. The R4 audit found a fixture
# using `completion_sha256`, a key the CLI has never emitted.
EVALUATION_DIAGNOSTIC_HASH_KEYS = frozenset({"prompt_sha256", "response_body_sha256"})


def require_bool(value: Any, where: str) -> bool:
    if not isinstance(value, bool):
        fail(f"{where} must be a JSON boolean")
    return value


def require_int(value: Any, where: str) -> int:
    # `isinstance(True, int)` is True in Python; a boolean is not an integer here.
    if isinstance(value, bool) or not isinstance(value, int):
        fail(f"{where} must be a JSON integer")
    return value


def require_number(value: Any, where: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        fail(f"{where} must be a JSON number")
    return value


def require_text(value: Any, where: str) -> str:
    """A non-empty string. A free-text field may still not be null or a number."""
    if not isinstance(value, str) or not value:
        fail(f"{where} must be a non-empty JSON string")
    return value


def require_nullable(value: Any, where: str, check) -> Any:
    """A nullable field is either JSON null or whatever `check` accepts.

    SPEC-046-R004 is explicit that an unknown value is null -- never `false`,
    never a sentinel string -- so for those fields the nullable wrapper is the
    whole rule rather than a convenience.
    """
    if value is None:
        return None
    return check(value, where)


def require_enum(value: Any, allowed: frozenset[str], where: str) -> str:
    if not isinstance(value, str):
        fail(f"{where} must be a JSON string")
    if value not in allowed:
        fail(f"{where} is not a permitted value: {value!r}")
    return value


def require_enum_list(value: Any, allowed: frozenset[str], where: str) -> list[str]:
    items = require_list(value, where)
    for index, item in enumerate(items):
        require_enum(item, allowed, f"{where}[{index}]")
    return items


def _require_admission_pair(
    document: dict[str, Any], state_field: str, source_field: str, where: str
) -> tuple[str, str]:
    """SPEC-046-R003 / SPEC-047-R002 cross-field rule on a state and its source.

    Reading the state without its source is the mistake both specs single out:
    `not_offered` means local advisory inventory under `local_default` and
    authoritative coordinator readback under `coordinator`. A document claiming
    a network state under `local_default` is the CLI promoting a candidate no
    coordinator admitted, so it must never reach a digest.
    """
    source = require_enum(
        document[source_field], ADMISSION_STATE_SOURCES, f"{where}.{source_field}"
    )
    state = require_enum(document[state_field], ADMISSION_STATES, f"{where}.{state_field}")
    allowed = (
        LOCAL_DEFAULT_ADMISSION_STATES if source == "local_default"
        else COORDINATOR_ADMISSION_STATES
    )
    if state not in allowed:
        fail(
            f"{where}.{state_field} {state!r} is not a permitted state for "
            f"{source_field} {source!r}"
        )
    return state, source


def assert_exact_object(value: Any, expected_keys: frozenset[str], where: str) -> dict[str, Any]:
    """The captured document must carry exactly these fields -- no more, no less."""
    if not isinstance(value, dict):
        fail(f"{where} must be a JSON object")
    present = set(value)
    missing = sorted(expected_keys - present)
    if missing:
        fail(f"{where} is missing required fields: " + ", ".join(missing))
    unknown = sorted(present - expected_keys)
    if unknown:
        fail(f"{where} carries unknown fields: " + ", ".join(unknown))
    return value


def _validate_guidance(document: dict[str, Any], where: str) -> None:
    """SPEC-046-R003 `provider_guidance`, reused verbatim by every SPEC-047-R002
    envelope. The two `*_key` fields are localization keys, so they are checked
    as non-empty strings; the rest are closed enums."""
    location = where + ".provider_guidance"
    guidance = assert_exact_object(document["provider_guidance"], PROVIDER_GUIDANCE_KEYS, location)
    require_text(guidance["state_label_key"], location + ".state_label_key")
    require_text(guidance["state_meaning_key"], location + ".state_meaning_key")
    require_enum(guidance["next_action"], NEXT_ACTIONS, location + ".next_action")
    require_nullable(
        guidance["transition_reason_code"], location + ".transition_reason_code", require_text
    )
    require_enum(
        guidance["earning_path_class"], EARNING_PATH_CLASSES, location + ".earning_path_class"
    )


def _validate_envelope_header(document: dict[str, Any], where: str) -> None:
    """Fields every CLI envelope carries. `schema` itself is cross-checked
    against the manifest's claim in `_digest_document`."""
    require_text(document["schema"], where + ".schema")
    require_text(document["generated_at"], where + ".generated_at")
    require_text(document["cli_version"], where + ".cli_version")


def _validate_capabilities(candidate: dict[str, Any], where: str) -> None:
    """SPEC-046-R004: six nullable booleans, one nullable number, three nullable
    strings. `false` is a claim that the capability is absent, so a `false`
    standing in for an unknown value is exactly what this rejects."""
    location = where + ".capabilities"
    capabilities = assert_exact_object(candidate["capabilities"], CAPABILITY_KEYS, location)
    for field in (
        "chat_completions", "streaming", "tool_call_passthrough",
        "structured_output_passthrough", "json_mode", "usage_reporting",
    ):
        require_nullable(capabilities[field], f"{location}.{field}", require_bool)
    require_nullable(capabilities["max_context_tokens"], location + ".max_context_tokens", require_number)
    for field in ("quantization", "family", "runtime_version"):
        require_nullable(capabilities[field], f"{location}.{field}", require_text)


def _validate_discovery(parsed: dict[str, Any], location: str) -> None:
    assert_exact_object(parsed, DISCOVERY_ENVELOPE_KEYS, location)
    _validate_envelope_header(parsed, location)
    require_int(parsed["projection_sequence"], location + ".projection_sequence")
    require_enum_list(parsed["warnings"], WARNING_CODES, location + ".warnings")
    for index, adapter in enumerate(require_list(parsed["adapters"], location + ".adapters")):
        where = f"{location} adapters[{index}]"
        assert_exact_object(adapter, DISCOVERY_ADAPTER_KEYS, where)
        require_enum(adapter["runtime_source"], RUNTIME_SOURCES, where + ".runtime_source")
        require_enum(adapter["status"], ADAPTER_STATUSES, where + ".status")
        require_nullable(
            adapter["origin_class"], where + ".origin_class",
            lambda value, at: require_enum(value, ORIGIN_CLASSES, at),
        )
        require_enum_list(adapter["warning_codes"], WARNING_CODES, where + ".warning_codes")
    for index, candidate in enumerate(require_list(parsed["candidates"], location + ".candidates")):
        where = f"{location} candidates[{index}]"
        assert_exact_object(candidate, DISCOVERY_CANDIDATE_KEYS, where)
        require_text(candidate["candidate_id"], where + ".candidate_id")
        require_enum(candidate["runtime_source"], RUNTIME_SOURCES, where + ".runtime_source")
        require_text(candidate["display_name"], where + ".display_name")
        require_text(candidate["served_model_ref"], where + ".served_model_ref")
        require_nullable(candidate["catalog_model_key"], where + ".catalog_model_key", require_text)
        require_enum(candidate["identity_state"], IDENTITY_STATES, where + ".identity_state")
        require_enum(candidate["locality"], LOCALITIES, where + ".locality")
        require_nullable(candidate["estimated_gb"], where + ".estimated_gb", require_number)
        require_nullable(
            candidate["context_window_tokens"], where + ".context_window_tokens", require_int
        )
        _validate_capabilities(candidate, where)
        require_enum(candidate["readiness_state"], READINESS_STATES, where + ".readiness_state")
        require_enum(candidate["fit_state"], FIT_STATES, where + ".fit_state")
        require_enum(candidate["evaluation_state"], EVALUATION_STATES, where + ".evaluation_state")
        _require_admission_pair(candidate, "admission_state", "admission_state_source", where)
        _validate_guidance(candidate, where)
        require_enum_list(candidate["warning_codes"], WARNING_CODES, where + ".warning_codes")


def _validate_evaluation(parsed: dict[str, Any], location: str) -> None:
    assert_exact_object(parsed, EVALUATION_ENVELOPE_KEYS, location)
    _validate_envelope_header(parsed, location)
    require_text(parsed["candidate_id"], location + ".candidate_id")
    require_enum(parsed["runtime_source"], EVALUATION_RUNTIME_SOURCES, location + ".runtime_source")
    require_text(parsed["served_model_ref"], location + ".served_model_ref")
    require_nullable(parsed["catalog_model_key"], location + ".catalog_model_key", require_text)
    require_enum(
        parsed["adapter_identity"], EVALUATION_ADAPTER_IDENTITIES, location + ".adapter_identity"
    )
    require_enum(parsed["health_result"], EVALUATION_HEALTH_RESULTS, location + ".health_result")
    require_nullable(parsed["latency_ms"], location + ".latency_ms", require_int)
    require_nullable(parsed["tokens_per_second"], location + ".tokens_per_second", require_number)
    require_nullable(parsed["completion_tokens"], location + ".completion_tokens", require_int)
    require_int(parsed["output_bytes"], location + ".output_bytes")
    require_int(parsed["request_count"], location + ".request_count")
    require_enum(
        parsed["usage_reporting_source"], EVALUATION_USAGE_REPORTING_SOURCES,
        location + ".usage_reporting_source",
    )
    results = require_object(parsed["capability_results"], location + ".capability_results")
    for name, result in results.items():
        where = f"{location}.capability_results[{name!r}]"
        entry = assert_exact_object(result, EVALUATION_CAPABILITY_RESULT_KEYS, where)
        require_enum(entry["result"], EVALUATION_CAPABILITY_RESULTS, where + ".result")
        require_enum(entry["source"], EVALUATION_CAPABILITY_SOURCES, where + ".source")
        require_nullable(entry["reason_code"], where + ".reason_code", require_text)
    require_enum(
        parsed["fit_estimate_source"], EVALUATION_FIT_ESTIMATE_SOURCES,
        location + ".fit_estimate_source",
    )
    mutations = assert_exact_object(
        parsed["mutation_summary"], EVALUATION_MUTATION_SUMMARY_KEYS,
        location + ".mutation_summary",
    )
    # Every mutation flag is a hard SPEC-046-R006 claim; a missing or non-boolean
    # value must not read as "no mutation".
    for field in sorted(EVALUATION_MUTATION_SUMMARY_KEYS):
        require_bool(mutations[field], f"{location}.mutation_summary.{field}")
    hashes = assert_exact_object(
        parsed["diagnostic_hashes"], EVALUATION_DIAGNOSTIC_HASH_KEYS,
        location + ".diagnostic_hashes",
    )
    require_string(
        hashes["prompt_sha256"], SHA256_RE, location + ".diagnostic_hashes.prompt_sha256"
    )
    require_nullable(
        hashes["response_body_sha256"], location + ".diagnostic_hashes.response_body_sha256",
        lambda value, at: require_string(value, SHA256_RE, at),
    )
    _validate_guidance(parsed, location)
    require_bool(
        parsed["offer_preconditions_appear_satisfied"],
        location + ".offer_preconditions_appear_satisfied",
    )
    require_enum_list(parsed["warnings"], WARNING_CODES, location + ".warnings")


def _validate_offer_dry_run(parsed: dict[str, Any], location: str) -> None:
    assert_exact_object(parsed, OFFER_DRY_RUN_ENVELOPE_KEYS, location)
    _validate_envelope_header(parsed, location)
    require_text(parsed["candidate_id"], location + ".candidate_id")
    require_text(parsed["served_model_ref"], location + ".served_model_ref")
    require_nullable(parsed["catalog_model_key"], location + ".catalog_model_key", require_text)
    require_bool(parsed["would_submit"], location + ".would_submit")
    _require_admission_pair(
        parsed, "likely_admission_state", "likely_admission_state_source", location
    )
    _validate_guidance(parsed, location)
    require_nullable(parsed["reason_code"], location + ".reason_code", require_text)
    require_enum_list(parsed["warnings"], WARNING_CODES, location + ".warnings")


def _validate_admission_status(parsed: dict[str, Any], location: str) -> None:
    assert_exact_object(parsed, ADMISSION_STATUS_ENVELOPE_KEYS, location)
    _validate_envelope_header(parsed, location)
    require_text(parsed["provider_id"], location + ".provider_id")
    require_text(parsed["candidate_id"], location + ".candidate_id")
    require_text(parsed["served_model_ref"], location + ".served_model_ref")
    require_nullable(parsed["catalog_model_key"], location + ".catalog_model_key", require_text)
    state, source = _require_admission_pair(
        parsed, "admission_state", "admission_state_source", location
    )
    require_nullable(parsed["coordinator_event_id"], location + ".coordinator_event_id", require_text)
    require_nullable(parsed["state_observed_at"], location + ".state_observed_at", require_text)
    _validate_guidance(parsed, location)
    next_states = require_enum_list(
        parsed["allowed_next_states"], ADMISSION_STATES, location + ".allowed_next_states"
    )
    # SPEC-047-R002: empty for a local default that has not entered coordinator
    # admission, and otherwise only edges SPEC-047-R001 actually allows.
    if source == "local_default":
        if next_states:
            fail(
                f"{location}.allowed_next_states must be empty for a local_default state"
            )
    else:
        allowed = ADMISSION_ALLOWED_NEXT_STATES[state]
        for index, next_state in enumerate(next_states):
            if next_state not in allowed:
                fail(
                    f"{location}.allowed_next_states[{index}] {next_state!r} is not an "
                    f"allowed transition from {state!r}"
                )
    require_enum_list(parsed["warnings"], WARNING_CODES, location + ".warnings")


def _validate_catalog_economics(parsed: dict[str, Any], location: str) -> None:
    assert_exact_object(parsed, CATALOG_ECONOMICS_ENVELOPE_KEYS, location)
    require_text(parsed["schema"], location + ".schema")
    require_text(parsed["generated_at"], location + ".generated_at")
    require_int(parsed["projection_sequence"], location + ".projection_sequence")
    assert_exact_object(parsed["source"], CATALOG_ECONOMICS_SOURCE_KEYS, location + ".source")
    require_list(parsed["warnings"], location + ".warnings")
    for index, row in enumerate(require_list(parsed["rows"], location + ".rows")):
        where = f"{location} rows[{index}]"
        assert_exact_object(row, CATALOG_ECONOMICS_ROW_KEYS, where)
        require_text(row["model_key"], where + ".model_key")
        require_text(row["served_model_id"], where + ".served_model_id")
        require_text(row["display_model_id"], where + ".display_model_id")
        require_nullable(row["action_model_id"], where + ".action_model_id", require_text)
        require_bool(row["is_current"], where + ".is_current")
        require_bool(row["weights_present_locally"], where + ".weights_present_locally")
        require_text(row["runtime_state"], where + ".runtime_state")
        require_nullable(row["estimated_gb"], where + ".estimated_gb", require_number)
        require_enum(row["fit"], FIT_STATES, where + ".fit")
        require_nullable(row["disabled_reason"], where + ".disabled_reason", require_text)
        require_list(row["warning_codes"], where + ".warning_codes")
        admission = assert_exact_object(
            row["admission"], CATALOG_ECONOMICS_ADMISSION_KEYS, where + ".admission"
        )
        _require_admission_pair(admission, "state", "source", where + ".admission")
        require_bool(
            admission["catalog_economics_permitted"],
            where + ".admission.catalog_economics_permitted",
        )
        require_bool(admission["settlement_capable"], where + ".admission.settlement_capable")
        require_nullable(
            admission["coordinator_event_id"], where + ".admission.coordinator_event_id", require_text
        )
        require_nullable(
            admission["state_observed_at"], where + ".admission.state_observed_at", require_text
        )
        # Money fields. A string or boolean here would read as a rate.
        for field in (
            "prompt_rate_usd_per_million_tokens", "completion_rate_usd_per_million_tokens",
            "provider_prompt_payout_usd_per_million_tokens",
            "provider_completion_payout_usd_per_million_tokens", "demand_weight",
            "supply_deficit_score",
        ):
            require_nullable(row[field], f"{where}.{field}", require_number)
        for field in ("provider_share_bps", "demand_rank", "ready_provider_count"):
            require_nullable(row[field], f"{where}.{field}", require_int)
        for field in ("rate_card_version", "rate_card_generated_at", "rate_card_key"):
            require_nullable(row[field], f"{where}.{field}", require_text)
        require_text(row["rate_source"], where + ".rate_source")
        require_text(row["economics_state"], where + ".economics_state")
        for field in CATALOG_ECONOMICS_ACTION_FIELDS:
            action = assert_exact_object(
                row[field], CATALOG_ECONOMICS_ACTION_KEYS, f"{where}.{field}"
            )
            require_bool(action["available"], f"{where}.{field}.available")
            require_bool(action["requires_confirmation"], f"{where}.{field}.requires_confirmation")
            for nullable_text in ("transaction_kind", "transaction_id", "unavailable_reason"):
                require_nullable(
                    action[nullable_text], f"{where}.{field}.{nullable_text}", require_text
                )
            for nullable_int in ("action_timeout_seconds", "estimated_bytes"):
                require_nullable(
                    action[nullable_int], f"{where}.{field}.{nullable_int}", require_int
                )


def validate_captured_cli_document(schema: Any, parsed: Any, location: str = "$") -> None:
    """Validate one captured CLI document against its complete closed schema.

    Invoked from `_digest_document` for the DISCOVERY journey only in this slice
    (epic #1453 slice 1b), so every discovery document that reaches evidence --
    driver-produced or hand-authored -- is complete before its bytes are hashed.
    An unrecognised schema fails closed: a document nobody enumerated cannot be
    known to be complete, so it may not back a signed step. Consequently only
    the five schemas the discovery driver emits are enumerated below;
    `model_admission_withdraw.v1` appears in the admission journey alone and is
    typed with that journey (slice 7).

    "Complete" means the exact key set AND the values: R4 showed that key-set
    validation alone accepts `identity_state: declared_local`, capability results
    as strings, and `next_action: serve_traffic` -- none of which the CLI can
    emit -- so each schema below also checks wire types, nullability, the closed
    enums its spec defines, and the state/source cross-field rules.
    """
    if schema == "provider_byom_discovery.v1":
        _validate_discovery(parsed, location)
    elif schema == "provider_byom_evaluation.v1":
        _validate_evaluation(parsed, location)
    elif schema == "model_admission_offer_dry_run.v1":
        _validate_offer_dry_run(parsed, location)
    elif schema == "model_admission_status.v1":
        _validate_admission_status(parsed, location)
    elif schema == "model_catalog_economics.v1":
        _validate_catalog_economics(parsed, location)
    else:
        fail(f"captured document {location} has an unvalidated schema: {schema!r}")


def _digest_document(
    manifest_dir: Path, contract: JourneyContract, entry: Any, step_id: str, index: int
) -> dict[str, Any]:
    location = f"{step_id}.documents[{index}]"
    document = require_object(entry, location)
    require_exact_keys(document, {"id", "schema", "path"}, {"id", "schema", "path"}, location)
    document_id = require_string(document.get("id"), SAFE_LABEL_RE, f"{location}.id")
    schema = require_string(document.get("schema"), DOCUMENT_SCHEMA_RE, f"{location}.schema")
    raw_path = require_string(document.get("path"), None, f"{location}.path")
    candidate = Path(raw_path)
    # Raw CLI documents live beside the run manifest; the operator contract says
    # paths are manifest-relative, so an absolute path or a parent traversal is a
    # manifest-authoring error, not a file to go and hash.
    if candidate.is_absolute() or ".." in candidate.parts:
        fail(f"{location}.path must be relative to the run manifest directory")
    manifest_root = manifest_dir.resolve()
    path = (manifest_root / candidate).resolve()
    try:
        path.relative_to(manifest_root)
    except ValueError:
        fail(f"{location}.path must stay under the run manifest directory")
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
        parsed = json.loads(decoded, object_pairs_hook=_unique_json_object)
    except DuplicateJSONKeyError as exc:
        fail(f"{location}.path must not contain duplicate JSON keys: {exc}")
    except json.JSONDecodeError as exc:
        fail(f"{location}.path must be a JSON document: {exc}")
    # The raw document is never committed, so this is the only point at which
    # the manifest's claimed schema can be checked against what was actually
    # digested. A signed step must not claim `model_admission_status.v1` backing
    # while the bytes under the digest are some other document.
    if not isinstance(parsed, dict):
        fail(f"{location}.path must be a JSON object document")
    actual_schema = parsed.get("schema")
    if not isinstance(actual_schema, str) or actual_schema != schema:
        fail(
            f"{location}.schema {schema!r} does not match the captured document's "
            f"top-level schema {actual_schema!r}"
        )
    # The document itself is never embedded, but its digest is what the signed
    # journey-result binds to, so the redaction claim has to hold for the bytes we
    # digest: a captured document that still carries a URL, an absolute or
    # home-relative path, a hostname, an IP literal, a localhost reference, or a
    # credential must not be archived at all. A CLI document that legitimately
    # needs an endpoint or a path in it is a document the operator redacts before
    # capture; the one exemption is the field-scoped localization-key rule.
    #
    # The DECODED structural walk is the authority here. It is the only scan that
    # can tell a `provider_guidance` localization key from a hostname, it covers
    # every key and every string value field by field, and JSON string escapes
    # (\u002f, \u002e, ...) that would hide a URL, path, or hostname from a
    # serialized-text scan are already decoded by the time it runs.
    assert_captured_document_redacted(parsed, f"{location}.document")
    # The raw-text scan over the archived bytes runs every rule EXCEPT the
    # hostname rule -- the structural walk owns that one -- so material sitting
    # outside any decoded string still fails closed.
    reject_unredacted_text_except_hostname(decoded, f"{location}.path")
    # Completeness is the other half of the trust claim. A redaction-clean but
    # schema-incomplete document would let a signed step assert conformance the
    # bytes under the digest do not carry, so the closed key sets are checked
    # here -- the one boundary every capture crosses -- rather than in whichever
    # harness produced the document.
    #
    # SCOPE (epic #1453 slice 1b): typed validation is enabled for the DISCOVERY
    # journey, whose hermetic driver produces every capture from a real CLI run,
    # so the enums and cross-field rules are checked against documents the CLI
    # actually emitted. The ADMISSION journey keeps the earlier boundary --
    # redaction scans plus top-level `schema` equality, both already applied
    # above -- because that journey cannot be captured end to end before catalog
    # binding exists, so there is no real admission run to type the validators
    # against. Typed validation of admission captures lands with the
    # admission-journey slice (epic #1453 slice 7).
    if contract.typed_capture_validation:
        validate_captured_cli_document(schema, parsed, f"{location}.document")
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
                    _digest_document(manifest_dir, contract, document, step_id, document_index)
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
    # Each journey has exactly one harness that can produce its run manifest.
    # "Some existing repository file" was not provenance: it let a discovery
    # manifest be signed under the admission harness's identity, and vice versa.
    if harness_name != contract.expected_harness_name:
        fail(
            f"harness.name must equal {contract.expected_harness_name!r} for "
            f"{contract.journey_id}, not {harness_name!r}"
        )
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

    payload = {
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
    if set(payload) != BYOM_JOURNEY_RESULT_PAYLOAD_KEYS:
        fail("builder payload keys drifted from BYOM_JOURNEY_RESULT_PAYLOAD_KEYS")
    return payload


# The closed key set of a BYOM journey-result payload. The builder emits exactly
# these keys, and governance requires a signed BYOM payload to carry exactly
# these keys: the generic signed-result schema permits optional fields such as
# `harness`, `config_before`, `candidate`, or `eip712`, but nothing binds those to
# the redacted evidence, so a hand-signed BYOM payload must not be able to smuggle
# them past source re-validation.
BYOM_JOURNEY_RESULT_PAYLOAD_KEYS = frozenset(
    {
        "schema_version",
        "journey_id",
        "requirement_ids",
        "repository",
        "captured_at",
        "expires_at",
        "operator",
        "environment",
        "artifacts",
        "result",
        "steps",
        "redaction",
        "run_id",
        "execution_mode",
        "observations",
    }
)


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
