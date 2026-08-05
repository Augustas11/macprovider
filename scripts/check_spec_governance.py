#!/usr/bin/env python3
"""Validate structured SPEC authority and conformance manifests.

This checker deliberately treats Markdown as human-readable documentation only.
It validates exact files, IDs, structured references, mappings, lifecycle
states, and evidence records from JSON manifests. It does not infer normative
meaning from rendered prose.
"""

from __future__ import annotations

import argparse
import ast
import base64
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Any


AUTHORITY_SCHEMA_PATH = "../schemas/spec-authority-v1.schema.json"
CONFORMANCE_SCHEMA_PATH = "../schemas/spec-conformance-v1.schema.json"
JOURNEY_RESULT_SCHEMA_ID = "https://github.com/Augustas11/macprovider/schemas/journey-result-v1.schema.json"
JOURNEY_RESULT_ENVELOPE_SCHEMA = "macprovider.journey-result-envelope.v1"
JOURNEY_RESULT_PAYLOAD_SCHEMA = "macprovider.journey-result.v1"
JOURNEY_RESULT_SIGNING_ALGORITHM = "ecdsa-p256-sha256"
JOURNEY_RESULT_SIGNING_KEY_ID = "macprovider-acceptance-p256-v1"
JOURNEY_RESULT_SIGNING_DOMAIN = b"macprovider.journey-result.v1\n"
JOURNEY_RESULT_PUBLIC_KEY_PATH = "security/acceptance-candidate-signing-public.pem"
JOURNEY_RESULT_PUBLIC_KEY_SHA256 = "849e9c9bc53db1fb8e28d3b46ab431089b12cb50b398c5317ced682d39bdbd38"
SPEC016_PAYOUT_JOURNEY_ID = "JOURNEY-SPEC-016-PAYOUT-ADDRESS-REGISTRATION"
SPEC016_PAYOUT_SPEC_ID = "SPEC-016"
SPEC016_PAYOUT_REQUIREMENT_ID = "SPEC-016-R002"
SPEC016_PAYOUT_EXECUTION_MODE = "candidate-derived-handler-only-conformance-harness"
SPEC016_PAYOUT_STEP_IDS = {f"step-{index:02d}" for index in range(1, 12)}
PROVIDER_PREBETA_JOURNEY_ID = "JOURNEY-PROVIDER-PREBETA-ADMISSION"
PROVIDER_PREBETA_EXECUTION_MODE = "physical-provider-prebeta-admission"
PROVIDER_PREBETA_ARTIFACT_ID = "redacted-provider-prebeta-admission"
PROVIDER_PREBETA_EVIDENCE_SCHEMA = "macprovider.provider-prebeta-admission-evidence.v1"
PROVIDER_PREBETA_STEP_ID_ORDER = (
    "step-01-private-prebeta-authorization",
    "step-02-install-launch-identity",
    "step-03-provider-registration-admission",
    "step-04-catalog-autotune-readiness",
    "step-05-hardware-evidence-verifier",
    "step-06-provider-runtime-routing",
    "step-07-buyer-serving-smoke",
    "step-08-redaction-and-correlation",
)
PROVIDER_PREBETA_STEP_IDS = set(PROVIDER_PREBETA_STEP_ID_ORDER)
TRUSTED_OPENSSL_CANDIDATES = (
    "/usr/bin/openssl",
    "/opt/homebrew/opt/openssl@3/bin/openssl",
    "/opt/homebrew/bin/openssl",
    "/usr/local/bin/openssl",
)


def _trusted_openssl_paths() -> set[Path]:
    trusted: set[Path] = set()
    for candidate in TRUSTED_OPENSSL_CANDIDATES:
        try:
            resolved = Path(candidate).resolve(strict=True)
        except OSError:
            continue
        if resolved.is_file() and os.access(resolved, os.X_OK):
            trusted.add(resolved)
    return trusted
SPEC_ID_RE = re.compile(r"^SPEC-\d{3}$")
SPEC_PATH_RE = re.compile(r"^specs/SPEC-\d{3}-[a-z0-9-]+\.md$")
REQUIREMENT_ID_RE = re.compile(r"^(SPEC-\d{3})-R\d{3}$")
DOMAIN_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
OWNER_RE = re.compile(r"^@[A-Za-z0-9-]+$")
ISSUE_RE = re.compile(r"^https://github\.com/Augustas11/macprovider/issues/\d+$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
ARTIFACT_RE = re.compile(r"^(?:commit:[0-9a-f]{40}|sha256:[0-9a-f]{64})$")
SHA256_RE = re.compile(r"^sha256:([0-9a-f]{64})$")
SHA256_HEX_RE = re.compile(r"^[0-9a-f]{64}$")
JOURNEY_RE = re.compile(r"^JOURNEY-[A-Z0-9]+(?:-[A-Z0-9]+)*$")
DATETIME_Z_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
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
LIFECYCLE_RANK = {
    "draft": 0,
    "normative": 1,
    "implemented-unverified": 2,
    "physically-verified": 3,
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


def resolve_trusted_openssl(path: str | None = None) -> str:
    trusted_paths = _trusted_openssl_paths()
    if path:
        openssl = Path(path)
        if not openssl.is_absolute():
            raise ValueError("OpenSSL path must be absolute")
        try:
            resolved = openssl.resolve(strict=True)
        except OSError:
            raise ValueError(f"OpenSSL binary is absent or unsafe: {openssl}")
        if resolved not in trusted_paths:
            raise ValueError("OpenSSL path is not in the trusted allowlist")
        return str(resolved)

    candidates = list(TRUSTED_OPENSSL_CANDIDATES)
    for value in candidates:
        openssl = Path(value)
        try:
            resolved = openssl.resolve(strict=True)
        except OSError:
            continue
        if resolved.is_file() and os.access(resolved, os.X_OK):
            return str(resolved)
    raise ValueError("could not resolve trusted OpenSSL binary")


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


def _bool_value(value: Any, location: str, result: ValidationResult) -> bool | None:
    if isinstance(value, bool):
        return value
    result.error(location, "must be a boolean")
    return None


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


def _datetime_z(value: Any, location: str, result: ValidationResult) -> datetime | None:
    if not isinstance(value, str) or not DATETIME_Z_RE.fullmatch(value):
        result.error(location, "must be an ISO UTC timestamp like 2026-08-04T12:34:56Z")
        return None
    parsed = datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    if parsed > datetime.now(timezone.utc):
        result.error(location, f"timestamp is in the future: {value}")
    return parsed


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


def _mapping_selector(value: str) -> str | None:
    if "::" in value:
        return value.split("::", 1)[1]
    if ":" in value:
        return value.split(":", 1)[1]
    return None


def _normalized_mapping_file(root: Path, value: str) -> str:
    try:
        return str((root / _mapping_file(value)).resolve().relative_to(root.resolve()))
    except (OSError, ValueError):
        return _mapping_file(value)


def _validate_mapping_paths(root: Path, mappings: list[str], location: str, result: ValidationResult) -> None:
    for index, mapping in enumerate(mappings):
        file_part = _mapping_file(mapping)
        selector = _mapping_selector(mapping)
        if not selector:
            result.error(f"{location}[{index}]", "mapping selector is required")
        path = _repository_path(root, file_part, f"{location}[{index}]", result)
        if path is None:
            continue
        if not path.exists():
            result.error(f"{location}[{index}]", f"mapping path does not exist: {file_part!r}")
        elif path.is_dir():
            result.error(f"{location}[{index}]", f"mapping path must be a file: {file_part!r}")
        elif selector:
            try:
                text = path.read_text(encoding="utf-8")
            except UnicodeDecodeError as exc:
                result.error(f"{location}[{index}]", f"mapped file is not UTF-8 text: {exc}")
            else:
                if _mapping_selector_resolves(text, selector, file_part) is None:
                    result.error(f"{location}[{index}]", f"mapping selector {selector!r} does not resolve in {file_part!r}")


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


def _canonical_json_sha256(value: Any) -> str:
    return hashlib.sha256(_canonical_json_bytes(value)).hexdigest()


def _canonical_json_bytes(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")


def _reachable_commit(root: Path, commit: str) -> bool:
    return subprocess.run(
        ["git", "cat-file", "-e", f"{commit}^{{commit}}"],
        cwd=root,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    ).returncode == 0


def _looks_like_signed_journey_result(root: Path, source: str) -> bool:
    path = _repository_path(root, source, source, ValidationResult())
    if path is None:
        return False
    probe = _load_json(path, ValidationResult())
    return isinstance(probe, dict) and probe.get("schema_version") == JOURNEY_RESULT_ENVELOPE_SCHEMA


def _verify_journey_result_signature(
    root: Path,
    signed: dict[str, Any],
    signature: dict[str, Any],
    trusted_public_key_sha256: str,
    openssl_bin: str,
    location: str,
    result: ValidationResult,
) -> bool:
    if signature.get("algorithm") != JOURNEY_RESULT_SIGNING_ALGORITHM:
        result.error(f"{location}.algorithm", f"must equal {JOURNEY_RESULT_SIGNING_ALGORITHM!r}")
    if signature.get("key_id") != JOURNEY_RESULT_SIGNING_KEY_ID:
        result.error(f"{location}.key_id", f"must equal {JOURNEY_RESULT_SIGNING_KEY_ID!r}")
    encoded = signature.get("signature")
    if not isinstance(encoded, str) or not encoded:
        result.error(f"{location}.signature", "must be a non-empty base64 DER ECDSA signature")
        return False
    try:
        signature_bytes = base64.b64decode(encoded.encode("ascii"), validate=True)
    except (UnicodeEncodeError, ValueError) as exc:
        result.error(f"{location}.signature", f"invalid base64: {exc}")
        return False
    if base64.b64encode(signature_bytes).decode("ascii") != encoded:
        result.error(f"{location}.signature", "must use canonical base64 encoding")
        return False
    if not 64 <= len(signature_bytes) <= 80:
        result.error(f"{location}.signature", "invalid P-256 DER signature length")
        return False
    public_key = root / JOURNEY_RESULT_PUBLIC_KEY_PATH
    if not public_key.exists():
        result.error(location, f"trusted public key missing: {JOURNEY_RESULT_PUBLIC_KEY_PATH}")
        return False
    try:
        public_key_bytes = public_key.read_bytes()
    except OSError as exc:
        result.error(location, f"cannot read trusted public key: {exc}")
        return False
    public_key_sha256 = hashlib.sha256(public_key_bytes).hexdigest()
    if public_key_sha256 != trusted_public_key_sha256:
        result.error(location, "trusted public key does not match pinned journey-result trust anchor")
        return False
    with tempfile.TemporaryDirectory(prefix="journey-result-verify.") as directory:
        tmp = Path(directory)
        message = tmp / "message"
        signature_path = tmp / "signature.der"
        message.write_bytes(JOURNEY_RESULT_SIGNING_DOMAIN + _canonical_json_bytes(signed))
        signature_path.write_bytes(signature_bytes)
        completed = subprocess.run(
            [
                openssl_bin,
                "dgst",
                "-sha256",
                "-verify",
                str(public_key),
                "-signature",
                str(signature_path),
                str(message),
            ],
            cwd=root,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
            env={"PATH": "/usr/bin:/bin"},
            timeout=20,
        )
    if completed.returncode != 0:
        result.error(f"{location}.signature", "cryptographic verification failed")
        return False
    return True


def _require_false(mapping: dict[str, Any], field: str, location: str, result: ValidationResult) -> None:
    value = _bool_value(mapping.get(field), f"{location}.{field}", result)
    if value is not None and value is not False:
        result.error(f"{location}.{field}", "must be false for SPEC-016 contract-only payout evidence")


def _require_sha_field(mapping: dict[str, Any], field: str, location: str, result: ValidationResult) -> None:
    _string(mapping.get(field), SHA256_HEX_RE, f"{location}.{field}", result)


def _validate_spec016_payout_artifact(root: Path, artifact: dict[str, Any], location: str, result: ValidationResult) -> None:
    source = artifact.get("source")
    if not isinstance(source, str):
        return
    if source.endswith(".candidate.json"):
        result.error(f"{location}.source", "SPEC-016 payout journey-result cannot promote candidate-only artifact files")
        return
    artifact_path = _repository_path(root, source, f"{location}.source", result)
    if artifact_path is None:
        return
    payload = _load_json(artifact_path, ValidationResult())
    if not isinstance(payload, dict):
        return
    if payload.get("schema_version") == "macprovider.journey-result-candidate.v1" or payload.get("promotion_ready") is False:
        result.error(f"{location}.source", "SPEC-016 payout journey-result cannot promote candidate-only artifact content")


def _provider_prebeta_normalized_redaction(value: Any, location: str, result: ValidationResult) -> dict[str, bool] | None:
    if not _expect_object(value, location, result):
        return None
    required = ("secrets_redacted", "operator_identity_redacted", "local_account_names_redacted")
    output: dict[str, bool] = {}
    for key in required:
        if value.get(key) is not True:
            result.error(f"{location}.{key}", "must be true")
        else:
            output[key] = True
    for key, item in value.items():
        if key.endswith("_redacted") and item is not True:
            result.error(f"{location}.{key}", "must be true")
    return output


def _provider_prebeta_normalized_steps(value: Any, location: str, result: ValidationResult) -> list[dict[str, Any]]:
    if not isinstance(value, list):
        result.error(location, "field 'steps' must be an array")
        return []
    by_id: dict[str, dict[str, Any]] = {}
    for index, item in enumerate(value):
        loc = f"{location}[{index}]"
        if not _expect_object(item, loc, result):
            continue
        step_id = _string(item.get("id"), None, f"{loc}.id", result)
        if step_id is None:
            continue
        if step_id in by_id:
            result.error(f"{loc}.id", f"duplicate provider-prebeta physical step {step_id!r}")
            continue
        if step_id not in PROVIDER_PREBETA_STEP_IDS:
            result.error(f"{loc}.id", f"unexpected provider-prebeta physical step {step_id!r}")
        if item.get("status") != "pass":
            result.error(f"{loc}.status", "must equal 'pass'")
        assertion = _string(item.get("assertion"), None, f"{loc}.assertion", result)
        artifacts = item.get("artifacts", [PROVIDER_PREBETA_ARTIFACT_ID])
        artifact_ids = _string_list(artifacts, f"{loc}.artifacts", result)
        if artifact_ids != [PROVIDER_PREBETA_ARTIFACT_ID]:
            result.error(f"{loc}.artifacts", f"must reference {PROVIDER_PREBETA_ARTIFACT_ID!r}")
        by_id[step_id] = {
            "id": step_id,
            "status": "pass",
            "assertion": assertion,
            "artifacts": [PROVIDER_PREBETA_ARTIFACT_ID],
        }
    missing_steps = PROVIDER_PREBETA_STEP_IDS - by_id.keys()
    if missing_steps:
        result.error(location, f"missing provider-prebeta physical steps: {sorted(missing_steps)}")
    if len(by_id) != len(PROVIDER_PREBETA_STEP_IDS):
        result.error(location, f"must contain exactly {len(PROVIDER_PREBETA_STEP_IDS)} provider-prebeta physical steps")
    return [by_id[step_id] for step_id in PROVIDER_PREBETA_STEP_ID_ORDER if step_id in by_id]


def _provider_prebeta_compare_signed_source(source_value: Any, signed_value: Any, location: str, result: ValidationResult) -> None:
    if signed_value != source_value:
        result.error(location, "must match provider-prebeta redacted evidence source")


def _validate_provider_prebeta_artifact(
    root: Path,
    artifact: dict[str, Any],
    signed: dict[str, Any],
    location: str,
    result: ValidationResult,
) -> None:
    if artifact.get("id") != PROVIDER_PREBETA_ARTIFACT_ID:
        result.error(f"{location}.id", f"must equal {PROVIDER_PREBETA_ARTIFACT_ID!r}")
    source = artifact.get("source")
    if not isinstance(source, str):
        return
    if not source.startswith("journeys/evidence/provider-prebeta-admission-") or not source.endswith(".redacted.json"):
        result.error(f"{location}.source", "provider-prebeta journey-result artifact must be a provider-prebeta redacted evidence file")
        return
    artifact_path = _repository_path(root, source, f"{location}.source", result)
    if artifact_path is None:
        return
    payload = _load_json(artifact_path, ValidationResult())
    if not isinstance(payload, dict):
        result.error(f"{location}.source", "provider-prebeta redacted evidence must be a JSON object")
        return
    if payload.get("schema_version") != PROVIDER_PREBETA_EVIDENCE_SCHEMA:
        result.error(f"{location}.source.schema_version", f"must equal {PROVIDER_PREBETA_EVIDENCE_SCHEMA!r}")
    if payload.get("journey_id") != PROVIDER_PREBETA_JOURNEY_ID:
        result.error(f"{location}.source.journey_id", f"must equal {PROVIDER_PREBETA_JOURNEY_ID!r}")
    payload_requirement_ids = _string_list(payload.get("requirement_ids"), f"{location}.source.requirement_ids", result, REQUIREMENT_ID_RE)
    signed_requirement_ids = _string_list(signed.get("requirement_ids"), f"{location}.signed.requirement_ids", result, REQUIREMENT_ID_RE)
    overclaimed = [item for item in signed_requirement_ids if item not in payload_requirement_ids]
    if overclaimed:
        result.error(f"{location}.source.requirement_ids", f"must cover every signed requirement ID: {overclaimed}")
    repository = payload.get("repository")
    signed_repository = signed.get("repository")
    if _expect_object(repository, f"{location}.source.repository", result) and isinstance(signed_repository, dict):
        _expect_keys(repository, {"name", "commit"}, {"name", "commit"}, f"{location}.source.repository", result)
        if repository.get("name") != signed_repository.get("name"):
            result.error(f"{location}.source.repository.name", "must match signed.repository.name")
        if repository.get("commit") != signed_repository.get("commit"):
            result.error(f"{location}.source.repository.commit", "must match signed.repository.commit")
    if payload.get("captured_at") != signed.get("captured_at"):
        result.error(f"{location}.source.captured_at", "must match signed.captured_at")
    if payload.get("expires_at") != signed.get("expires_at"):
        result.error(f"{location}.source.expires_at", "must match signed.expires_at")
    _provider_prebeta_compare_signed_source(payload.get("run_id"), signed.get("run_id"), f"{location}.source.run_id", result)
    for field_name in ("operator", "environment", "result"):
        _provider_prebeta_compare_signed_source(
            payload.get(field_name),
            signed.get(field_name),
            f"{location}.source.{field_name}",
            result,
        )
    source_result = payload.get("result")
    if _expect_object(source_result, f"{location}.source.result", result) and source_result.get("status") != "pass":
        result.error(f"{location}.source.result.status", "must equal 'pass'")
    source_steps = _provider_prebeta_normalized_steps(payload.get("steps"), f"{location}.source.steps", result)
    signed_steps = _provider_prebeta_normalized_steps(signed.get("steps"), f"{location}.signed.steps", result)
    _provider_prebeta_compare_signed_source(source_steps, signed_steps, f"{location}.source.steps", result)
    source_redaction = _provider_prebeta_normalized_redaction(payload.get("redaction"), f"{location}.source.redaction", result)
    signed_redaction = {
        "secrets_redacted": signed.get("redaction", {}).get("secrets_redacted") if isinstance(signed.get("redaction"), dict) else None,
        "operator_identity_redacted": signed.get("redaction", {}).get("operator_identity_redacted") if isinstance(signed.get("redaction"), dict) else None,
        "local_account_names_redacted": signed.get("redaction", {}).get("local_account_names_redacted") if isinstance(signed.get("redaction"), dict) else None,
    }
    _provider_prebeta_compare_signed_source(source_redaction, signed_redaction, f"{location}.source.redaction", result)


def _validate_provider_prebeta_journey_result(
    root: Path,
    signed: dict[str, Any],
    journeys: list[str],
    artifacts: list[Any],
    steps: list[Any],
    location: str,
    result: ValidationResult,
) -> None:
    if signed.get("journey_id") != PROVIDER_PREBETA_JOURNEY_ID:
        result.error(f"{location}.signed.journey_id", f"must equal {PROVIDER_PREBETA_JOURNEY_ID!r}")
    if journeys != [PROVIDER_PREBETA_JOURNEY_ID]:
        result.error(location, f"provider-prebeta requirement journeys must equal [{PROVIDER_PREBETA_JOURNEY_ID!r}]")
    if signed.get("execution_mode") != PROVIDER_PREBETA_EXECUTION_MODE:
        result.error(f"{location}.signed.execution_mode", f"must equal {PROVIDER_PREBETA_EXECUTION_MODE!r}")

    observed_step_ids: set[str] = set()
    valid_step_count = 0
    for index, step in enumerate(steps):
        if not isinstance(step, dict) or not isinstance(step.get("id"), str):
            continue
        valid_step_count += 1
        step_id = step["id"]
        if step_id in observed_step_ids:
            result.error(f"{location}.signed.steps[{index}].id", f"duplicate provider-prebeta physical step {step_id!r}")
        observed_step_ids.add(step_id)
    missing_steps = PROVIDER_PREBETA_STEP_IDS - observed_step_ids
    unexpected_steps = observed_step_ids - PROVIDER_PREBETA_STEP_IDS
    if missing_steps:
        result.error(f"{location}.signed.steps", f"missing provider-prebeta physical steps: {sorted(missing_steps)}")
    if unexpected_steps:
        result.error(f"{location}.signed.steps", f"unexpected provider-prebeta physical steps: {sorted(unexpected_steps)}")
    if valid_step_count != len(PROVIDER_PREBETA_STEP_IDS):
        result.error(f"{location}.signed.steps", f"must contain exactly {len(PROVIDER_PREBETA_STEP_IDS)} provider-prebeta physical steps")

    valid_artifacts = [artifact for artifact in artifacts if isinstance(artifact, dict)]
    if len(valid_artifacts) != 1:
        result.error(f"{location}.signed.artifacts", "provider-prebeta journey-result must contain exactly one redacted evidence artifact")
    for index, artifact in enumerate(artifacts):
        if isinstance(artifact, dict):
            _validate_provider_prebeta_artifact(root, artifact, signed, f"{location}.signed.artifacts[{index}]", result)


def _validate_spec016_payout_journey_result(
    root: Path,
    signed: dict[str, Any],
    source: str,
    journeys: list[str],
    artifacts: list[Any],
    steps: list[Any],
    location: str,
    result: ValidationResult,
) -> None:
    if signed.get("journey_id") != SPEC016_PAYOUT_JOURNEY_ID:
        result.error(f"{location}.signed.journey_id", f"must equal {SPEC016_PAYOUT_JOURNEY_ID!r}")
    if journeys != [SPEC016_PAYOUT_JOURNEY_ID]:
        result.error(location, f"SPEC-016 payout requirement journeys must equal [{SPEC016_PAYOUT_JOURNEY_ID!r}]")
    if signed.get("spec_id") != SPEC016_PAYOUT_SPEC_ID:
        result.error(f"{location}.signed.spec_id", f"must equal {SPEC016_PAYOUT_SPEC_ID!r}")
    if signed.get("requirement_ids") != [SPEC016_PAYOUT_REQUIREMENT_ID]:
        result.error(f"{location}.signed.requirement_ids", f"must equal [{SPEC016_PAYOUT_REQUIREMENT_ID!r}]")
    if source.endswith(".candidate.json"):
        result.error(location, "SPEC-016 payout journey-result cannot promote candidate-only artifact files")
    _string(signed.get("run_id"), re.compile(r"^spec016-r002-payout-address-[A-Za-z0-9_.:-]+$"), f"{location}.signed.run_id", result)
    if signed.get("execution_mode") != SPEC016_PAYOUT_EXECUTION_MODE:
        result.error(f"{location}.signed.execution_mode", f"must equal {SPEC016_PAYOUT_EXECUTION_MODE!r}")

    harness = signed.get("harness")
    if _expect_object(harness, f"{location}.signed.harness", result):
        allowed_harness = {
            "id",
            "version",
            "execution_mode",
            "isolated_sqlite",
            "real_provider_token_check",
            "real_pause_validation",
            "controlled_dependencies",
            "production_runner_built",
            "external_rpc_client_built",
            "settlement_signer_built",
            "release_promotion_attempted",
        }
        _expect_keys(harness, allowed_harness, allowed_harness, f"{location}.signed.harness", result)
        _string(harness.get("id"), None, f"{location}.signed.harness.id", result)
        _string(harness.get("version"), None, f"{location}.signed.harness.version", result)
        if harness.get("execution_mode") != SPEC016_PAYOUT_EXECUTION_MODE:
            result.error(f"{location}.signed.harness.execution_mode", f"must equal {SPEC016_PAYOUT_EXECUTION_MODE!r}")
        for field_name in (
            "isolated_sqlite",
            "real_provider_token_check",
            "real_pause_validation",
            "controlled_dependencies",
        ):
            value = _bool_value(harness.get(field_name), f"{location}.signed.harness.{field_name}", result)
            if value is not None and value is not True:
                result.error(f"{location}.signed.harness.{field_name}", "must be true")
        for field_name in (
            "production_runner_built",
            "external_rpc_client_built",
            "settlement_signer_built",
            "release_promotion_attempted",
        ):
            _require_false(harness, field_name, f"{location}.signed.harness", result)

    config_before = signed.get("config_before")
    if _expect_object(config_before, f"{location}.signed.config_before", result):
        required_config_before = {"payout_enabled", "runner_started", "external_rpc_started", "settlement_signer_started"}
        _expect_keys(config_before, required_config_before, required_config_before, f"{location}.signed.config_before", result)
        for field_name in sorted(required_config_before):
            _require_false(config_before, field_name, f"{location}.signed.config_before", result)

    config_after = signed.get("config_after")
    if _expect_object(config_after, f"{location}.signed.config_after", result):
        required_config_after = {
            "payout_enabled",
            "runner_started",
            "external_rpc_started",
            "settlement_signer_started",
            "settlement_attempted",
            "production_side_effects",
        }
        _expect_keys(config_after, required_config_after, required_config_after, f"{location}.signed.config_after", result)
        for field_name in sorted(required_config_after):
            _require_false(config_after, field_name, f"{location}.signed.config_after", result)

    restoration = signed.get("restoration")
    if _expect_object(restoration, f"{location}.signed.restoration", result):
        _expect_keys(restoration, {"result"}, {"result"}, f"{location}.signed.restoration", result)
        _string(restoration.get("result"), None, f"{location}.signed.restoration.result", result)

    observations = signed.get("observations")
    if _expect_object(observations, f"{location}.signed.observations", result):
        required_observations = {
            "provider_id_sha256",
            "hot_wallet_sha256",
            "first_address_sha256",
            "eip712_digest_sha256",
            "raw_signature_redacted",
            "provider_token_redacted",
            "private_keys_redacted",
        }
        allowed_observations = required_observations | {"rotated_address_sha256", "cooling_off_hours"}
        _expect_keys(observations, required_observations, allowed_observations, f"{location}.signed.observations", result)
        for field_name in ("provider_id_sha256", "hot_wallet_sha256", "first_address_sha256", "eip712_digest_sha256"):
            _require_sha_field(observations, field_name, f"{location}.signed.observations", result)
        if "rotated_address_sha256" in observations:
            _require_sha_field(observations, "rotated_address_sha256", f"{location}.signed.observations", result)
        if "cooling_off_hours" in observations and not isinstance(observations.get("cooling_off_hours"), int):
            result.error(f"{location}.signed.observations.cooling_off_hours", "must be an integer")
        for field_name in ("raw_signature_redacted", "provider_token_redacted", "private_keys_redacted"):
            value = _bool_value(observations.get(field_name), f"{location}.signed.observations.{field_name}", result)
            if value is not None and value is not True:
                result.error(f"{location}.signed.observations.{field_name}", "must be true")

    eip712 = signed.get("eip712")
    if _expect_object(eip712, f"{location}.signed.eip712", result):
        required_eip712 = {
            "typed_data_artifact_sha256",
            "digest_sha256",
            "signer_address_sha256",
            "verifier",
            "verification_result",
            "raw_signature_access_controlled",
        }
        _expect_keys(eip712, required_eip712, required_eip712, f"{location}.signed.eip712", result)
        for field_name in ("typed_data_artifact_sha256", "digest_sha256", "signer_address_sha256"):
            _require_sha_field(eip712, field_name, f"{location}.signed.eip712", result)
        _string(eip712.get("verifier"), None, f"{location}.signed.eip712.verifier", result)
        if eip712.get("verification_result") != "pass":
            result.error(f"{location}.signed.eip712.verification_result", "must equal 'pass'")
        value = _bool_value(eip712.get("raw_signature_access_controlled"), f"{location}.signed.eip712.raw_signature_access_controlled", result)
        if value is not None and value is not True:
            result.error(f"{location}.signed.eip712.raw_signature_access_controlled", "must be true")

    candidate = signed.get("candidate")
    if _expect_object(candidate, f"{location}.signed.candidate", result):
        allowed_candidate = {
            "coordinator_sha256",
            "malibu_sha256",
            "addresses_go_sha256",
            "eip712_go_sha256",
            "attempts_go_sha256",
            "payout_address_client_sha256",
            "payout_wallet_flow_sha256",
            "payout_signer_resource_sha256",
        }
        _expect_keys(candidate, {"payout_address_client_sha256"}, allowed_candidate, f"{location}.signed.candidate", result)
        coordinator_hash_fields = ("addresses_go_sha256", "eip712_go_sha256", "attempts_go_sha256")
        if "coordinator_sha256" in candidate:
            _require_sha_field(candidate, "coordinator_sha256", f"{location}.signed.candidate", result)
        else:
            for field_name in coordinator_hash_fields:
                _require_sha_field(candidate, field_name, f"{location}.signed.candidate", result)
        _require_sha_field(candidate, "payout_address_client_sha256", f"{location}.signed.candidate", result)
        if "malibu_sha256" in candidate:
            _require_sha_field(candidate, "malibu_sha256", f"{location}.signed.candidate", result)
        else:
            _require_sha_field(candidate, "payout_wallet_flow_sha256", f"{location}.signed.candidate", result)
            _require_sha_field(candidate, "payout_signer_resource_sha256", f"{location}.signed.candidate", result)

    signer = signed.get("signer")
    if _expect_object(signer, f"{location}.signed.signer", result):
        required_signer = {"key_id", "identity_fingerprint", "trust_root_sha256", "verification_result"}
        _expect_keys(signer, required_signer, required_signer, f"{location}.signed.signer", result)
        _string(signer.get("key_id"), None, f"{location}.signed.signer.key_id", result)
        _require_sha_field(signer, "identity_fingerprint", f"{location}.signed.signer", result)
        _require_sha_field(signer, "trust_root_sha256", f"{location}.signed.signer", result)
        if signer.get("verification_result") != "pass":
            result.error(f"{location}.signed.signer.verification_result", "must equal 'pass'")

    observed_step_ids: set[str] = set()
    valid_step_count = 0
    for index, step in enumerate(steps):
        if not isinstance(step, dict) or not isinstance(step.get("id"), str):
            continue
        valid_step_count += 1
        step_id = step["id"]
        if step_id in observed_step_ids:
            result.error(f"{location}.signed.steps[{index}].id", f"duplicate SPEC-016 payout physical step {step_id!r}")
        observed_step_ids.add(step_id)
    missing_steps = SPEC016_PAYOUT_STEP_IDS - observed_step_ids
    unexpected_steps = observed_step_ids - SPEC016_PAYOUT_STEP_IDS
    if missing_steps:
        result.error(f"{location}.signed.steps", f"missing SPEC-016 payout physical steps: {sorted(missing_steps)}")
    if unexpected_steps:
        result.error(f"{location}.signed.steps", f"unexpected SPEC-016 payout physical steps: {sorted(unexpected_steps)}")
    if valid_step_count != len(SPEC016_PAYOUT_STEP_IDS):
        result.error(f"{location}.signed.steps", f"must contain exactly {len(SPEC016_PAYOUT_STEP_IDS)} SPEC-016 payout physical steps")

    for index, artifact in enumerate(artifacts):
        if isinstance(artifact, dict):
            _validate_spec016_payout_artifact(root, artifact, f"{location}.signed.artifacts[{index}]", result)


def _validate_signed_journey_result(
    root: Path,
    source: str,
    requirement_id: str,
    journeys: list[str],
    evidence_commits: set[str],
    trusted_public_key_sha256: str,
    openssl_bin: str,
    location: str,
    result: ValidationResult,
) -> bool:
    before = len(result.errors)
    path = _repository_path(root, source, location, result)
    if path is None:
        return False
    envelope = _load_json(path, result)
    if not _expect_object(envelope, location, result):
        return False
    _expect_keys(envelope, {"schema_version", "signatures", "signed"}, {"schema_version", "signatures", "signed"}, location, result)
    if envelope.get("schema_version") != JOURNEY_RESULT_ENVELOPE_SCHEMA:
        result.error(f"{location}.schema_version", f"must equal {JOURNEY_RESULT_ENVELOPE_SCHEMA!r}")

    signed = envelope.get("signed")
    if not _expect_object(signed, f"{location}.signed", result):
        signed = {}
    signed_digest = _canonical_json_sha256(signed)

    signatures = envelope.get("signatures")
    matching_verified_signature = False
    if not isinstance(signatures, list):
        result.error(f"{location}.signatures", "field 'signatures' must be an array")
        signatures = []
    if not signatures:
        result.error(f"{location}.signatures", "signed journey-result requires at least one signature")
    for index, signature in enumerate(signatures):
        loc = f"{location}.signatures[{index}]"
        if not _expect_object(signature, loc, result):
            continue
        _expect_keys(
            signature,
            {"algorithm", "key_id", "signature", "signed_sha256", "verified_at", "verifier"},
            {"algorithm", "key_id", "signature", "signed_sha256", "verified_at", "verifier"},
            loc,
            result,
        )
        digest = _string(signature.get("signed_sha256"), SHA256_HEX_RE, f"{loc}.signed_sha256", result)
        if digest and digest != signed_digest:
            result.error(f"{loc}.signed_sha256", "does not match canonical signed payload SHA-256")
        _datetime_z(signature.get("verified_at"), f"{loc}.verified_at", result)
        _string(signature.get("verifier"), None, f"{loc}.verifier", result)
        if digest == signed_digest and _verify_journey_result_signature(root, signed, signature, trusted_public_key_sha256, openssl_bin, loc, result):
            matching_verified_signature = True
    if not matching_verified_signature:
        result.error(location, "signed journey-result requires a verified signature over the signed payload")

    _expect_keys(
        signed,
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
        },
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
            "spec_id",
            "run_id",
            "execution_mode",
            "harness",
            "config_before",
            "config_after",
            "restoration",
            "observations",
            "eip712",
            "candidate",
            "signer",
        },
        f"{location}.signed",
        result,
    )
    if signed.get("schema_version") != JOURNEY_RESULT_PAYLOAD_SCHEMA:
        result.error(f"{location}.signed.schema_version", f"must equal {JOURNEY_RESULT_PAYLOAD_SCHEMA!r}")
    journey_id = _string(signed.get("journey_id"), JOURNEY_RE, f"{location}.signed.journey_id", result)
    if journey_id and journey_id not in journeys:
        result.error(f"{location}.signed.journey_id", f"does not match mapped journeys {journeys}")
    requirement_ids = _string_list(signed.get("requirement_ids"), f"{location}.signed.requirement_ids", result, REQUIREMENT_ID_RE)
    if requirement_id not in requirement_ids:
        result.error(f"{location}.signed.requirement_ids", f"does not cover requirement {requirement_id}")
    _datetime_z(signed.get("captured_at"), f"{location}.signed.captured_at", result)
    expires_at = _date(signed.get("expires_at"), f"{location}.signed.expires_at", result)
    if expires_at and expires_at < date.today():
        result.error(f"{location}.signed.expires_at", f"signed journey-result expired on {expires_at.isoformat()}")

    operator = signed.get("operator")
    if _expect_object(operator, f"{location}.signed.operator", result):
        _expect_keys(operator, {"role", "identity_fingerprint"}, {"role", "identity_fingerprint"}, f"{location}.signed.operator", result)
        _string(operator.get("role"), None, f"{location}.signed.operator.role", result)
        _string(operator.get("identity_fingerprint"), SHA256_HEX_RE, f"{location}.signed.operator.identity_fingerprint", result)

    environment = signed.get("environment")
    if _expect_object(environment, f"{location}.signed.environment", result):
        _expect_keys(
            environment,
            {"class", "hardware_profile", "candidate"},
            {"class", "hardware_profile", "candidate"},
            f"{location}.signed.environment",
            result,
        )
        _string(environment.get("class"), None, f"{location}.signed.environment.class", result)
        _string(environment.get("hardware_profile"), None, f"{location}.signed.environment.hardware_profile", result)
        _string(environment.get("candidate"), None, f"{location}.signed.environment.candidate", result)

    repository = signed.get("repository")
    if _expect_object(repository, f"{location}.signed.repository", result):
        _expect_keys(repository, {"name", "commit"}, {"name", "commit"}, f"{location}.signed.repository", result)
        if repository.get("name") != "Augustas11/macprovider":
            result.error(f"{location}.signed.repository.name", "must equal 'Augustas11/macprovider'")
        commit = _string(repository.get("commit"), COMMIT_RE, f"{location}.signed.repository.commit", result)
        if commit and not _reachable_commit(root, commit):
            result.error(f"{location}.signed.repository.commit", f"commit is not reachable: {commit}")
        if commit and evidence_commits and commit not in evidence_commits:
            result.error(f"{location}.signed.repository.commit", "must match this requirement's commit evidence")

    artifact_ids: set[str] = set()
    artifact_records = signed.get("artifacts")
    if not isinstance(artifact_records, list):
        result.error(f"{location}.signed.artifacts", "field 'artifacts' must be an array")
        artifact_records = []
    if not artifact_records:
        result.error(f"{location}.signed.artifacts", "must contain at least one hash-bound artifact")
    for index, artifact in enumerate(artifact_records):
        loc = f"{location}.signed.artifacts[{index}]"
        if not _expect_object(artifact, loc, result):
            continue
        _expect_keys(artifact, {"id", "sha256", "source"}, {"id", "sha256", "source"}, loc, result)
        artifact_id = _string(artifact.get("id"), None, f"{loc}.id", result)
        if artifact_id:
            if artifact_id in artifact_ids:
                result.error(f"{loc}.id", f"duplicate artifact id {artifact_id!r}")
            artifact_ids.add(artifact_id)
        expected_sha = _string(artifact.get("sha256"), SHA256_HEX_RE, f"{loc}.sha256", result)
        artifact_source = _string(artifact.get("source"), None, f"{loc}.source", result)
        if artifact_source:
            if not _source_under_journey_evidence(root, artifact_source):
                result.error(f"{loc}.source", "must be under journeys/evidence/")
            artifact_path = _repository_path(root, artifact_source, f"{loc}.source", result)
            if artifact_path is not None:
                try:
                    actual_sha = hashlib.sha256(artifact_path.read_bytes()).hexdigest()
                except OSError as exc:
                    result.error(f"{loc}.source", f"cannot read artifact source: {exc}")
                else:
                    if expected_sha and actual_sha != expected_sha:
                        result.error(f"{loc}.sha256", "does not match artifact source bytes")

    run_result = signed.get("result")
    if _expect_object(run_result, f"{location}.signed.result", result):
        _expect_keys(run_result, {"status"}, {"status", "summary"}, f"{location}.signed.result", result)
        if run_result.get("status") != "pass":
            result.error(f"{location}.signed.result.status", "must equal 'pass'")
        if "summary" in run_result:
            _string(run_result.get("summary"), None, f"{location}.signed.result.summary", result)

    steps = signed.get("steps")
    if not isinstance(steps, list):
        result.error(f"{location}.signed.steps", "field 'steps' must be an array")
        steps = []
    if not steps:
        result.error(f"{location}.signed.steps", "must contain at least one result entry")
    for index, step in enumerate(steps):
        loc = f"{location}.signed.steps[{index}]"
        if not _expect_object(step, loc, result):
            continue
        _expect_keys(step, {"id", "status", "artifacts"}, {"id", "status", "artifacts", "assertion"}, loc, result)
        _string(step.get("id"), None, f"{loc}.id", result)
        if step.get("status") != "pass":
            result.error(f"{loc}.status", "must equal 'pass'")
        step_artifacts = _string_list(step.get("artifacts"), f"{loc}.artifacts", result)
        if not step_artifacts:
            result.error(f"{loc}.artifacts", "must contain at least one artifact reference")
        for artifact_id in step_artifacts:
            if artifact_ids and artifact_id not in artifact_ids:
                result.error(f"{loc}.artifacts", f"unknown artifact reference {artifact_id!r}")
        if "assertion" in step:
            _string(step.get("assertion"), None, f"{loc}.assertion", result)

    redaction = signed.get("redaction")
    if _expect_object(redaction, f"{location}.signed.redaction", result):
        required_redactions = {"secrets_redacted", "operator_identity_redacted", "local_account_names_redacted"}
        _expect_keys(redaction, required_redactions, required_redactions, f"{location}.signed.redaction", result)
        for field_name in sorted(required_redactions):
            if redaction.get(field_name) is not True:
                result.error(f"{location}.signed.redaction.{field_name}", "must be true")

    if journey_id == SPEC016_PAYOUT_JOURNEY_ID or requirement_id == SPEC016_PAYOUT_REQUIREMENT_ID:
        if requirement_id != SPEC016_PAYOUT_REQUIREMENT_ID:
            result.error(f"{location}.signed.requirement_ids", f"SPEC-016 payout journey-result may only promote {SPEC016_PAYOUT_REQUIREMENT_ID}")
        _validate_spec016_payout_journey_result(root, signed, source, journeys, artifact_records, steps, location, result)
    if journey_id == PROVIDER_PREBETA_JOURNEY_ID:
        _validate_provider_prebeta_journey_result(root, signed, [item for item in journeys if isinstance(item, str)], artifact_records, steps, location, result)

    return len(result.errors) == before


def _signed_journey_result_satisfies(
    root: Path,
    requirement: dict[str, Any],
    location: str,
    result: ValidationResult,
    trusted_public_key_sha256: str,
    openssl_bin: str,
    emit_errors: bool = True,
) -> bool:
    requirement_id = requirement.get("requirement_id")
    journeys = requirement.get("journeys")
    if not isinstance(requirement_id, str) or not isinstance(journeys, list):
        return False
    evidence_items = requirement.get("evidence", []) if isinstance(requirement.get("evidence"), list) else []
    evidence_commits = {
        evidence.get("artifact", "").split(":", 1)[1]
        for evidence in evidence_items
        if isinstance(evidence, dict)
        and isinstance(evidence.get("artifact"), str)
        and evidence["artifact"].startswith("commit:")
    }
    candidate_errors: list[str] = []
    saw_candidate = False
    for index, evidence in enumerate(evidence_items):
        if not isinstance(evidence, dict):
            continue
        artifact = evidence.get("artifact")
        source = evidence.get("source")
        if (
            isinstance(artifact, str)
            and artifact.startswith("sha256:")
            and isinstance(source, str)
            and _source_under_journey_evidence(root, source)
        ):
            if not _looks_like_signed_journey_result(root, source):
                continue
            saw_candidate = True
            candidate_result = ValidationResult()
            if _validate_signed_journey_result(
                root,
                source,
                requirement_id,
                [item for item in journeys if isinstance(item, str)],
                evidence_commits,
                trusted_public_key_sha256,
                openssl_bin,
                f"{location}.evidence[{index}].source",
                candidate_result,
            ):
                return True
            candidate_errors.extend(candidate_result.errors)
    if emit_errors:
        if candidate_errors:
            result.errors.extend(candidate_errors)
        elif not saw_candidate:
            result.error(location, "sensitive conformant requirement requires sha256 signed journey-result evidence under journeys/evidence/")
    return False


def _line_bounds(text: str, index: int) -> tuple[int, int]:
    start = text.rfind("\n", 0, index) + 1
    end = text.find("\n", index)
    if end == -1:
        end = len(text)
    return start, end


def _find_brace_block_end(text: str, open_brace: int) -> int | None:
    depth = 0
    index = open_brace
    in_line_comment = False
    in_block_comment = False
    in_string: str | None = None
    while index < len(text):
        character = text[index]
        next_character = text[index + 1] if index + 1 < len(text) else ""
        if in_line_comment:
            if character == "\n":
                in_line_comment = False
            index += 1
            continue
        if in_block_comment:
            if character == "*" and next_character == "/":
                in_block_comment = False
                index += 2
            else:
                index += 1
            continue
        if in_string is not None:
            if character == "\\" and in_string != "`":
                index += 2
                continue
            if character == in_string:
                in_string = None
            index += 1
            continue
        if character == "/" and next_character == "/":
            in_line_comment = True
            index += 2
            continue
        if character == "/" and next_character == "*":
            in_block_comment = True
            index += 2
            continue
        if character in {'"', "'", "`"}:
            in_string = character
            index += 1
            continue
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                line_end = text.find("\n", index)
                return len(text) if line_end == -1 else line_end
        index += 1
    return None


def _shell_uncommented_line(line: str) -> str:
    index = 0
    in_single = False
    in_double = False
    in_backtick = False
    while index < len(line):
        character = line[index]
        if character == "\\" and not in_single:
            index += 2
            continue
        if in_single:
            if character == "'":
                in_single = False
            index += 1
            continue
        if in_double:
            if character == '"':
                in_double = False
            elif character == "`":
                in_backtick = not in_backtick
            index += 1
            continue
        if in_backtick:
            if character == "`":
                in_backtick = False
            index += 1
            continue
        if character == "'":
            in_single = True
        elif character == '"':
            in_double = True
        elif character == "`":
            in_backtick = True
        elif character == "#":
            return line[:index]
        index += 1
    return line


def _shell_mask_quoted(line: str) -> str:
    chars = list(line)
    index = 0
    in_single = False
    in_double = False
    in_backtick = False
    while index < len(chars):
        character = chars[index]
        if character == "\\" and not in_single:
            if index + 1 < len(chars):
                chars[index] = " "
                chars[index + 1] = " "
            index += 2
            continue
        if in_single:
            if character == "'":
                in_single = False
            chars[index] = " "
            index += 1
            continue
        if in_double:
            if character == '"':
                in_double = False
            chars[index] = " "
            index += 1
            continue
        if in_backtick:
            if character == "`":
                in_backtick = False
            chars[index] = " "
            index += 1
            continue
        if character == "'":
            in_single = True
            chars[index] = " "
        elif character == '"':
            in_double = True
            chars[index] = " "
        elif character == "`":
            in_backtick = True
            chars[index] = " "
        index += 1
    return "".join(chars)


def _shell_heredoc_delimiters(line: str) -> list[tuple[str, bool]]:
    delimiters: list[tuple[str, bool]] = []
    for match in re.finditer(r"<<(-)?\s*(?:'([^']+)'|\"([^\"]+)\"|\\?([A-Za-z_][A-Za-z0-9_]*))", line):
        delimiters.append((match.group(2) or match.group(3) or match.group(4), bool(match.group(1))))
    return delimiters


def _shell_line_continues(line: str) -> bool:
    return _shell_uncommented_line(line).rstrip().endswith("\\")


def _shell_invokes_python(command: str) -> bool:
    active = _shell_uncommented_line(command)
    for segment in re.split(r"(?:^|\$\(|[;|&({])", active):
        words = re.findall(r"[A-Za-z_][A-Za-z0-9_./=-]*", segment)
        index = 0
        while index < len(words) and re.match(r"[A-Za-z_][A-Za-z0-9_]*=", words[index]):
            index += 1
        if index < len(words) and words[index] in {"exec", "command"}:
            index += 1
        if index < len(words) and re.fullmatch(r"(?:python|python3|python3\.[0-9]+)", Path(words[index]).name):
            return True
    return False


def _shell_materializes_script(command: str) -> bool:
    active = _shell_uncommented_line(command)
    if ">" not in active or "<<" not in active:
        return False
    targets = [
        match.group(1) or match.group(2) or match.group(3)
        for match in re.finditer(r"(?:^|\s)(?:>|>>)\s*(?:\"([^\"]+)\"|'([^']+)'|([^\s<>&;|]+))", active)
    ]
    material_targets = [
        target
        for target in targets
        if target not in {"/dev/null", "null"}
        and (
            "WATCHDOG_PATH" in target
            or "watchdog" in target.lower()
            or target.endswith((".sh", ".bash", ".zsh"))
        )
    ]
    if not material_targets:
        return False
    for segment in re.split(r"(?:^|[;|&({])", active):
        words = re.findall(r"[A-Za-z_][A-Za-z0-9_./=-]*", segment)
        index = 0
        while index < len(words) and re.match(r"[A-Za-z_][A-Za-z0-9_]*=", words[index]):
            index += 1
        if index < len(words) and words[index] == "cat":
            return True
    return False


def _find_shell_brace_block_end(text: str, open_brace: int) -> int | None:
    line_start = text.rfind("\n", 0, open_brace) + 1
    cursor = line_start
    depth = 0
    heredocs: list[tuple[str, bool]] = []
    while cursor < len(text):
        line_end = text.find("\n", cursor)
        if line_end == -1:
            line_end = len(text)
            line = text[cursor:line_end]
            next_cursor = line_end
        else:
            line = text[cursor:line_end]
            next_cursor = line_end + 1
        if heredocs:
            delimiter, strip_tabs = heredocs[0]
            candidate = line.lstrip("\t") if strip_tabs else line
            if candidate == delimiter:
                heredocs.pop(0)
            cursor = next_cursor
            continue
        active_line = _shell_uncommented_line(line)
        segment_start = max(0, open_brace - cursor) if cursor == line_start else 0
        segment = active_line[segment_start:]
        masked_segment = _shell_mask_quoted(segment)
        for offset, character in enumerate(masked_segment, start=segment_start):
            if character == "{":
                depth += 1
            elif character == "}":
                depth -= 1
                if depth == 0:
                    return line_end
                if depth < 0:
                    return None
        heredocs.extend(_shell_heredoc_delimiters(active_line))
        cursor = next_cursor
    return None


def _line_before(text: str, index: int) -> str:
    return text[text.rfind("\n", 0, index) + 1:index].strip()


def _block_kind_for_open_brace(text: str, open_brace: int, suffix: str) -> str:
    line = _line_before(text, open_brace)
    if suffix == ".swift":
        modifiers = r"(?:(?:private|public|internal|fileprivate|static|mutating|nonisolated|final|lazy|override|open|required|convenience)\s+)*"
        if re.match(rf"{modifiers}(?:struct|enum|actor|class|extension)\b", line):
            return "type"
        if re.match(rf"{modifiers}(?:func|init)\b", line):
            return "function"
    if suffix == ".go":
        if re.match(r"func\s+(?:\([^)]*\)\s*)?[A-Za-z_][A-Za-z0-9_]*\s*\(", line):
            return "function"
        if re.match(r"type\s+[A-Za-z_][A-Za-z0-9_]*\s+(?:struct|interface)\b", line):
            return "type"
    return "block"


def _block_stack_at(text: str, limit: int, suffix: str) -> list[str]:
    stack: list[str] = []
    index = 0
    in_line_comment = False
    in_block_comment = False
    in_string: str | None = None
    while index < limit:
        character = text[index]
        next_character = text[index + 1] if index + 1 < limit else ""
        if in_line_comment:
            if character == "\n":
                in_line_comment = False
            index += 1
            continue
        if in_block_comment:
            if character == "*" and next_character == "/":
                in_block_comment = False
                index += 2
            else:
                index += 1
            continue
        if in_string is not None:
            if character == "\\" and in_string != "`":
                index += 2
                continue
            if character == in_string:
                in_string = None
            index += 1
            continue
        if character == "/" and next_character == "/":
            in_line_comment = True
            index += 2
            continue
        if character == "/" and next_character == "*":
            in_block_comment = True
            index += 2
            continue
        if character in {'"', "'", "`"}:
            in_string = character
            index += 1
            continue
        if character == "{":
            stack.append(_block_kind_for_open_brace(text, index, suffix))
        elif character == "}" and stack:
            stack.pop()
        index += 1
    return stack


def _inactive_line_starts(text: str, suffix: str) -> set[int]:
    if suffix == ".sh":
        return set()
    inactive: set[int] = set()
    line_start = 0
    index = 0
    in_line_comment = False
    in_block_comment = False
    in_string: str | None = None
    swift_inactive_depth = 0
    while index < len(text):
        if index == line_start:
            line_end = text.find("\n", index)
            if line_end == -1:
                line_end = len(text)
            line_text = text[index:line_end].strip()
            if suffix == ".swift":
                if swift_inactive_depth:
                    inactive.add(line_start)
                    if re.match(r"#if\b", line_text):
                        swift_inactive_depth += 1
                    elif re.match(r"#endif\b", line_text):
                        swift_inactive_depth -= 1
                elif re.match(r"#if\s+false\b", line_text):
                    inactive.add(line_start)
                    swift_inactive_depth = 1
            if in_block_comment or in_string is not None:
                inactive.add(line_start)
        character = text[index]
        next_character = text[index + 1] if index + 1 < len(text) else ""
        if in_line_comment:
            if character == "\n":
                in_line_comment = False
                line_start = index + 1
            index += 1
            continue
        if in_block_comment:
            if character == "*" and next_character == "/":
                in_block_comment = False
                index += 2
            else:
                if character == "\n":
                    line_start = index + 1
                index += 1
            continue
        if in_string is not None:
            if in_string == '"""' and text.startswith('"""', index):
                in_string = None
                index += 3
                continue
            if character == "\\" and in_string in {'"', "'"}:
                index += 2
                continue
            if in_string != '"""' and character == in_string:
                in_string = None
            if character == "\n":
                line_start = index + 1
            index += 1
            continue
        if character == "/" and next_character == "/":
            in_line_comment = True
            index += 2
            continue
        if character == "/" and next_character == "*":
            in_block_comment = True
            index += 2
            continue
        if suffix == ".swift" and text.startswith('"""', index):
            in_string = '"""'
            index += 3
            continue
        if character in {'"', "'", "`"}:
            in_string = character
            index += 1
            continue
        if character == "\n":
            line_start = index + 1
        index += 1
    return inactive


def _declaration_scope_allows(text: str, cursor: int, suffix: str) -> bool:
    stack = _block_stack_at(text, cursor, suffix)
    if suffix == ".go":
        return not stack or stack == ["type"]
    if suffix == ".swift":
        return not stack or stack == ["type"]
    return True


def _declaration_may_have_brace_body(line: str, suffix: str) -> bool:
    stripped = line.strip()
    if suffix == ".go":
        return bool(re.match(r"(?:func|type)\b", stripped))
    modifiers = r"(?:(?:private|public|internal|fileprivate|static|mutating|nonisolated|final|lazy|override|open|required|convenience)\s+)*"
    return bool(re.match(rf"{modifiers}(?:func|init|struct|enum|actor|class|extension)\b", stripped))


def _find_balanced_initializer_end(text: str, start: int, line_end: int) -> int | None:
    assignment = text.find("=", start, line_end)
    if assignment == -1:
        return None
    pairs = {"[": "]", "(": ")", "{": "}"}
    closers = {value: key for key, value in pairs.items()}
    stack: list[str] = []
    index = assignment + 1
    in_line_comment = False
    in_block_comment = False
    in_string: str | None = None
    while index < len(text):
        character = text[index]
        next_character = text[index + 1] if index + 1 < len(text) else ""
        if in_line_comment:
            if character == "\n":
                in_line_comment = False
            index += 1
            continue
        if in_block_comment:
            if character == "*" and next_character == "/":
                in_block_comment = False
                index += 2
            else:
                index += 1
            continue
        if in_string is not None:
            if character == "\\" and in_string != "`":
                index += 2
                continue
            if character == in_string:
                in_string = None
            index += 1
            continue
        if character == "/" and next_character == "/":
            in_line_comment = True
            index += 2
            continue
        if character == "/" and next_character == "*":
            in_block_comment = True
            index += 2
            continue
        if character in {'"', "'", "`"}:
            in_string = character
            index += 1
            continue
        if character in pairs:
            stack.append(character)
        elif character in closers:
            if stack and stack[-1] == closers[character]:
                stack.pop()
                if not stack:
                    end = text.find("\n", index)
                    return len(text) if end == -1 else end
            elif not stack:
                return None
        elif character == "\n" and not stack:
            return None
        index += 1
    return None


def _extract_indented_block(text: str, line_start: int, line_end: int) -> str:
    line = text[line_start:line_end]
    stripped = line.lstrip(" ")
    if not stripped.startswith(("def ", "async def ", "class ")):
        return line.rstrip()
    indent = len(line) - len(stripped)
    end = line_end
    cursor = line_end + 1 if line_end < len(text) else len(text)
    while cursor < len(text):
        next_end = text.find("\n", cursor)
        if next_end == -1:
            next_end = len(text)
        next_line = text[cursor:next_end]
        if next_line.strip():
            next_indent = len(next_line) - len(next_line.lstrip(" "))
            if next_indent <= indent:
                break
        end = next_end
        cursor = next_end + 1 if next_end < len(text) else len(text)
    return text[line_start:end].rstrip()


def _python_selector_names(selector: str) -> set[str]:
    names: set[str] = set()
    stripped = selector.strip()
    for prefix in ("async def ", "def ", "class "):
        if stripped.startswith(prefix):
            match = re.match(rf"{re.escape(prefix)}([A-Za-z_][A-Za-z0-9_]*)", stripped)
            if match:
                names.add(match.group(1))
    if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", stripped):
        names.add(stripped)
    return names


def _python_node_source(lines: list[str], node: ast.AST) -> str | None:
    start_lineno = getattr(node, "lineno", None)
    end_lineno = getattr(node, "end_lineno", None)
    if not isinstance(start_lineno, int) or not isinstance(end_lineno, int):
        return None
    decorator_lines = [decorator.lineno for decorator in getattr(node, "decorator_list", [])]
    if decorator_lines:
        start_lineno = min(start_lineno, *decorator_lines)
    return "\n".join(lines[start_lineno - 1:end_lineno]).rstrip()


def _python_assigned_names(node: ast.AST) -> set[str]:
    targets: list[ast.AST] = []
    if isinstance(node, ast.Assign):
        targets = list(node.targets)
    elif isinstance(node, ast.AnnAssign):
        targets = [node.target]
    elif isinstance(node, ast.AugAssign):
        targets = [node.target]
    names: set[str] = set()
    for target in targets:
        if isinstance(target, ast.Name):
            names.add(target.id)
    return names


def _extract_embedded_python_mapping_fragments(text: str, selector: str, *, _depth: int = 0) -> list[str]:
    selector_names = _python_selector_names(selector)
    if not selector_names:
        return []
    stripped_selector = selector.strip()
    if not stripped_selector.startswith(("def ", "async def ", "class ")):
        return []
    python_bodies: list[tuple[int, str]] = []
    generated_shell_bodies: list[str] = []
    logical_command_parts: list[str] = []
    cursor = 0
    heredocs: list[tuple[str, bool, bool, bool, int, list[str]]] = []
    while cursor < len(text):
        line_end = text.find("\n", cursor)
        if line_end == -1:
            line_end = len(text)
        line = text[cursor:line_end]
        next_cursor = line_end + 1 if line_end < len(text) else len(text)
        if heredocs:
            delimiter, strip_tabs, is_python, is_generated_shell, body_start, body_lines = heredocs[0]
            candidate = line.lstrip("\t") if strip_tabs else line
            if candidate == delimiter:
                if is_python:
                    python_bodies.append((body_start, "\n".join(body_lines)))
                elif is_generated_shell:
                    generated_shell_bodies.append("\n".join(body_lines))
                heredocs.pop(0)
            else:
                body_lines.append(line)
            cursor = next_cursor
            continue
        active_line = _shell_uncommented_line(line)
        command_context = "\n".join([*logical_command_parts, active_line])
        command_is_python = _shell_invokes_python(active_line) or _shell_invokes_python(command_context)
        command_is_generated_shell = _shell_materializes_script(active_line) or _shell_materializes_script(command_context)
        for delimiter, strip_tabs in _shell_heredoc_delimiters(active_line):
            heredocs.append((delimiter, strip_tabs, command_is_python, command_is_generated_shell, next_cursor, []))
        if _shell_line_continues(line):
            logical_command_parts.append(active_line.rstrip()[:-1])
        else:
            logical_command_parts = []
        cursor = next_cursor
    fragments: list[str] = []
    for body_start, body in python_bodies:
        cursor = 0
        while cursor < len(body):
            line_end = body.find("\n", cursor)
            if line_end == -1:
                line_end = len(body)
            line = body[cursor:line_end]
            stripped = line.lstrip(" ")
            if stripped.startswith(("def ", "async def ", "class ")):
                match = re.match(r"(?:async\s+def|def|class)\s+([A-Za-z_][A-Za-z0-9_]*)", stripped)
                if match and match.group(1) in selector_names:
                    fragments.append(_extract_indented_block(body, cursor, line_end))
            cursor = line_end + 1
    if _depth < 3:
        for shell_body in generated_shell_bodies:
            fragments.extend(_extract_embedded_python_mapping_fragments(shell_body, selector, _depth=_depth + 1))
    return fragments


def _embedded_python_selector_requires_declaration(selector: str) -> bool:
    return selector.strip().startswith(("def ", "async def ", "class "))


def _extract_python_mapping_fragment(text: str, selector: str) -> str | None:
    selector_names = _python_selector_names(selector)
    if not selector_names:
        return None
    try:
        tree = ast.parse(text)
    except SyntaxError:
        return None
    lines = text.splitlines()
    fragments: list[str] = []
    for node in tree.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)) and node.name in selector_names:
            fragment = _python_node_source(lines, node)
            if fragment is not None:
                fragments.append(fragment)
        if _python_assigned_names(node) & selector_names:
            fragment = _python_node_source(lines, node)
            if fragment is not None:
                fragments.append(fragment)
    if len(fragments) != 1:
        return None
    return fragments[0]


def _selector_identifier(selector: str) -> str | None:
    stripped = selector.strip()
    for pattern in (
        r"(?:func|type|var|const)\s+(?:\([^)]*\)\s*)?([A-Za-z_][A-Za-z0-9_]*)",
        r"(?:static\s+)?(?:func|let|var|struct|enum|actor|class)\s+([A-Za-z_][A-Za-z0-9_]*)",
        r"([A-Za-z_][A-Za-z0-9_]*)\s+[^=]+",
    ):
        match = re.search(pattern, stripped)
        if match:
            return match.group(1)
    if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", stripped):
        return stripped
    return None


def _go_build_context(text: str) -> str:
    context: list[str] = []
    cursor = 0
    while cursor < len(text):
        line_end = text.find("\n", cursor)
        if line_end == -1:
            line_end = len(text)
        line = text[cursor:line_end]
        stripped = line.strip()
        if stripped.startswith("package "):
            break
        if stripped.startswith("//go:build ") or stripped.startswith("// +build "):
            context.append(line.rstrip())
        cursor = line_end + 1
    return "\n".join(context)


def _swift_conditional_context_at(text: str, limit: int) -> str:
    inactive_lines = _inactive_line_starts(text, ".swift")
    stack: list[str] = []
    cursor = 0
    while cursor < limit:
        line_end = text.find("\n", cursor)
        if line_end == -1 or line_end > limit:
            line_end = limit
        line = text[cursor:line_end]
        stripped = line.strip()
        if cursor not in inactive_lines and stripped.startswith("#"):
            if re.match(r"#if\b", stripped):
                stack.append(line.rstrip())
            elif re.match(r"#(?:elseif|else)\b", stripped):
                if stack:
                    stack[-1] = line.rstrip()
            elif re.match(r"#endif\b", stripped):
                if stack:
                    stack.pop()
        if line_end >= limit or line_end == len(text):
            break
        cursor = line_end + 1
    return "\n".join(stack)


def _declaration_build_context(text: str, cursor: int, suffix: str) -> str:
    if suffix == ".go":
        return _go_build_context(text)
    if suffix == ".swift":
        return _swift_conditional_context_at(text, cursor)
    return ""


def _fragment_with_context(context: str, fragment: str) -> str:
    if not context:
        return fragment
    return f"{context}\n{fragment}"


def _go_declaration_line_matches(line: str, selector: str) -> bool:
    stripped = line.strip()
    if stripped.startswith(("//", "/*", "*")):
        return False
    selector_stripped = selector.strip()
    if re.match(r"(?:func|type|var|const)\s+", selector_stripped):
        return re.sub(r"\s+", " ", stripped).startswith(re.sub(r"\s+", " ", selector_stripped))
    identifier = _selector_identifier(selector)
    if identifier is None:
        return False
    escaped = re.escape(identifier)
    return any(
        re.match(pattern, stripped)
        for pattern in (
            rf"func\s+(?:\([^)]*\)\s*)?{escaped}\b\s*\(",
            rf"type\s+{escaped}\b",
            rf"(?:var|const)\s+{escaped}\b",
            rf"{escaped}\b\s*=",
            rf"{escaped}\b\s+[^=]+$",
        )
    )


def _swift_declaration_line_matches(line: str, selector: str) -> bool:
    stripped = line.strip()
    if stripped.startswith(("//", "/*", "*")):
        return False
    selector_stripped = selector.strip()
    modifiers = r"(?:(?:private|public|internal|fileprivate|static|mutating|nonisolated|final|lazy|override|open|required|convenience)\s+)*"
    if re.match(rf"{modifiers}(?:func|let|var|struct|enum|actor|class)\s+", selector_stripped):
        return re.sub(r"\s+", " ", stripped).startswith(re.sub(r"\s+", " ", selector_stripped))
    identifier = _selector_identifier(selector)
    if identifier is None:
        return False
    escaped = re.escape(identifier)
    return any(
        re.match(pattern, stripped)
        for pattern in (
            rf"{modifiers}func\s+{escaped}\b\s*\(",
            rf"{modifiers}(?:let|var)\s+{escaped}\b",
            rf"{modifiers}(?:struct|enum|actor|class)\s+{escaped}\b",
        )
    )


def _extract_declaration_fragment(text: str, selector: str, relative: str) -> str | None:
    suffix = Path(relative).suffix
    matcher = _go_declaration_line_matches if suffix == ".go" else _swift_declaration_line_matches
    inactive_lines = _inactive_line_starts(text, suffix)
    fragments: list[str] = []
    cursor = 0
    while cursor < len(text):
        line_end = text.find("\n", cursor)
        if line_end == -1:
            line_end = len(text)
        line = text[cursor:line_end]
        if cursor not in inactive_lines and matcher(line, selector) and _declaration_scope_allows(text, cursor, suffix):
            context = _declaration_build_context(text, cursor, suffix)
            if _declaration_may_have_brace_body(line, suffix):
                declaration_window_end = min(len(text), line_end + 1024)
                open_brace = text.find("{", cursor, declaration_window_end)
                if open_brace != -1:
                    block_end = _find_brace_block_end(text, open_brace)
                    if block_end is not None:
                        fragments.append(_fragment_with_context(context, text[cursor:block_end].rstrip()))
                        cursor = line_end + 1
                        continue
            balanced_end = _find_balanced_initializer_end(text, cursor, line_end)
            if balanced_end is not None:
                fragments.append(_fragment_with_context(context, text[cursor:balanced_end].rstrip()))
            else:
                fragments.append(_fragment_with_context(context, line.rstrip()))
        cursor = line_end + 1
    if len(fragments) != 1:
        return None
    return fragments[0]


def _shell_selector_name(selector: str) -> str | None:
    stripped = selector.strip()
    for pattern in (
        r"function\s+([A-Za-z_][A-Za-z0-9_]*)",
        r"([A-Za-z_][A-Za-z0-9_]*)\s*\(\s*\)",
    ):
        match = re.fullmatch(pattern, stripped)
        if match:
            return match.group(1)
    if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", stripped):
        return stripped
    return None


def _shell_selector_requires_function(selector: str) -> bool:
    stripped = selector.strip()
    return bool(re.fullmatch(r"function\s+[A-Za-z_][A-Za-z0-9_]*", stripped) or re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*\s*\(\s*\)", stripped))


def _extract_shell_mapping_fragments(text: str, selector: str) -> list[str]:
    name = _shell_selector_name(selector)
    if name is None:
        return []
    inactive_lines = _inactive_line_starts(text, ".sh")
    escaped = re.escape(name)
    fragments: list[str] = []
    cursor = 0
    while cursor < len(text):
        line_end = text.find("\n", cursor)
        if line_end == -1:
            line_end = len(text)
        line = text[cursor:line_end]
        stripped = line.strip()
        if (
            cursor not in inactive_lines
            and not stripped.startswith("#")
            and re.match(rf"(?:function\s+{escaped}\b|{escaped}\s*\(\s*\))", stripped)
        ):
            open_brace = text.find("{", cursor, min(len(text), line_end + 256))
            if open_brace == -1:
                fragments.append(line.rstrip())
            else:
                block_end = _find_shell_brace_block_end(text, open_brace)
                if block_end is not None:
                    fragments.append(text[cursor:block_end].rstrip())
        cursor = line_end + 1
    return fragments


def _extract_shell_mapping_fragment(text: str, selector: str) -> str | None:
    fragments = _extract_shell_mapping_fragments(text, selector)
    if len(fragments) != 1:
        return None
    return fragments[0]


def _extract_text_anchor_fragment(text: str, selector: str) -> str | None:
    index = text.find(selector)
    if index == -1:
        return None
    line_start, line_end = _line_bounds(text, index)
    return text[line_start:line_end].rstrip()


def _extract_mapping_fragment(text: str, selector: str, relative: str) -> str | None:
    suffix = Path(relative).suffix
    if suffix == ".py":
        return _extract_python_mapping_fragment(text, selector)
    if suffix in {".go", ".swift"}:
        return _extract_declaration_fragment(text, selector, relative)
    if suffix == ".sh":
        function_fragments = _extract_shell_mapping_fragments(text, selector)
        if len(function_fragments) == 1:
            return function_fragments[0]
        if function_fragments or _shell_selector_requires_function(selector):
            return None
        embedded_python_fragments = _extract_embedded_python_mapping_fragments(text, selector)
        if len(embedded_python_fragments) == 1:
            return embedded_python_fragments[0]
        if embedded_python_fragments or _embedded_python_selector_requires_declaration(selector):
            return None
        return _extract_text_anchor_fragment(text, selector)
    return _extract_text_anchor_fragment(text, selector)


def _mapping_selector_resolves(text: str, selector: str, relative: str) -> str | None:
    return _extract_mapping_fragment(text, selector, relative)


def _commit_mapping_selector_matches_current(root: Path, commit: str, mapping: str) -> bool:
    relative = _mapping_file(mapping)
    selector = _mapping_selector(mapping)
    if not selector:
        return False
    try:
        current_path = (root / relative).resolve()
        current_path.relative_to(root.resolve())
    except (OSError, ValueError):
        return False
    completed = subprocess.run(
        ["git", "show", f"{commit}:{relative}"],
        cwd=root,
        capture_output=True,
        check=False,
    )
    if completed.returncode != 0:
        return False
    try:
        committed = completed.stdout.decode("utf-8")
        current = current_path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return False
    committed_fragment = _extract_mapping_fragment(committed, selector, relative)
    current_fragment = _extract_mapping_fragment(current, selector, relative)
    return committed_fragment is not None and committed_fragment == current_fragment


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
    if not isinstance(base_authority, dict):
        result.error("base-ref", f"cannot load specs/AUTHORITY.json from {base_ref!r}")
        return
    if not isinstance(base_conformance, dict):
        result.error("base-ref", f"cannot load specs/CONFORMANCE.json from {base_ref!r}")
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
        if item.get("status") == "deprecated" and head.get("status") != "deprecated":
            result.error("specs/AUTHORITY.json", f"authority domain {domain_id!r} revived from deprecated to {head.get('status')}")

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
        base_status = item.get("status")
        head_status = head.get("status")
        if base_status == "deprecated" and head_status != "deprecated":
            result.error("specs/CONFORMANCE.json", f"SPEC record {spec_id} revived from deprecated to {head_status}")
        elif isinstance(base_status, str) and isinstance(head_status, str) and head_status != "deprecated":
            base_rank = LIFECYCLE_RANK.get(base_status)
            head_rank = LIFECYCLE_RANK.get(head_status)
            if base_rank is not None and head_rank is not None and head_rank < base_rank:
                result.error("specs/CONFORMANCE.json", f"SPEC record {spec_id} lifecycle regressed from {base_status} to {head_status}")

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
            {"id", "owner_spec", "consumers", "status", "requires_signed_journey_result", "owner", "issue"},
            {"id", "owner_spec", "consumers", "status", "requires_signed_journey_result", "owner", "issue"},
            loc,
            result,
        )
        _string(domain.get("id"), DOMAIN_RE, f"{loc}.id", result)
        _string(domain.get("owner_spec"), SPEC_ID_RE, f"{loc}.owner_spec", result)
        _string_list(domain.get("consumers"), f"{loc}.consumers", result, SPEC_ID_RE)
        if domain.get("status") not in AUTHORITY_STATES:
            result.error(f"{loc}.status", f"invalid authority status {domain.get('status')!r}")
        if not isinstance(domain.get("requires_signed_journey_result"), bool):
            result.error(f"{loc}.requires_signed_journey_result", "must be a boolean")
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
        elif state == "not-applicable":
            gap = requirement.get("gap")
            if gap is None:
                result.error(loc, "state 'not-applicable' requires an owned, issue-linked rationale")
            else:
                _validate_gap(gap, f"{loc}.gap", result)
                if not isinstance(gap, dict) or not isinstance(gap.get("rationale"), str) or not gap.get("rationale").strip():
                    result.error(f"{loc}.gap.rationale", "not-applicable requires a non-empty rationale")
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
                    selector = _mapping_selector(mapping)
                    if not _commit_mapping_selector_matches_current(root, commit, mapping):
                        result.error(loc, f"commit evidence {commit} does not match current mapped selector fragment {selector!r} in {mapped_file!r}")
    return [item for item in specs if isinstance(item, dict)], [item for item in requirements if isinstance(item, dict)]


def validate_repository(
    root: Path,
    base_ref: str | None = None,
    trusted_journey_result_public_key_sha256: str = JOURNEY_RESULT_PUBLIC_KEY_SHA256,
    conformance_override: dict[str, Any] | None = None,
    openssl_bin: str | None = None,
) -> ValidationResult:
    root = root.resolve()
    result = ValidationResult()
    try:
        trusted_openssl = resolve_trusted_openssl(openssl_bin)
    except ValueError as exc:
        result.error("openssl", str(exc))
        return result
    authority = _load_json(root / "specs" / "AUTHORITY.json", result)
    conformance = conformance_override if conformance_override is not None else _load_json(root / "specs" / "CONFORMANCE.json", result)
    if authority is None or conformance is None:
        return result

    domains = _validate_authority_schema(authority, result)
    specs, requirements = _validate_conformance_schema(root, conformance, result)
    schema_authority = _load_json(root / "schemas" / "spec-authority-v1.schema.json", result)
    schema_conformance = _load_json(root / "schemas" / "spec-conformance-v1.schema.json", result)
    schema_journey_result = _load_json(root / "schemas" / "journey-result-v1.schema.json", result)
    schema_pr = _load_json(root / "schemas" / "spec-pr-governance-v1.schema.json", result)
    if isinstance(schema_authority, dict) and schema_authority.get("$id") != "https://github.com/Augustas11/macprovider/schemas/spec-authority-v1.schema.json":
        result.error("schemas/spec-authority-v1.schema.json.$id", "unexpected schema id")
    if isinstance(schema_conformance, dict) and schema_conformance.get("$id") != "https://github.com/Augustas11/macprovider/schemas/spec-conformance-v1.schema.json":
        result.error("schemas/spec-conformance-v1.schema.json.$id", "unexpected schema id")
    if isinstance(schema_journey_result, dict) and schema_journey_result.get("$id") != JOURNEY_RESULT_SCHEMA_ID:
        result.error("schemas/journey-result-v1.schema.json.$id", "unexpected schema id")
    if isinstance(schema_journey_result, dict):
        schema_signature = schema_journey_result.get("$defs", {}).get("signature", {}).get("properties", {})
        if schema_signature.get("algorithm", {}).get("const") != JOURNEY_RESULT_SIGNING_ALGORITHM:
            result.error("schemas/journey-result-v1.schema.json.$defs.signature.properties.algorithm.const", "does not match validator signing algorithm")
        if schema_signature.get("key_id", {}).get("const") != JOURNEY_RESULT_SIGNING_KEY_ID:
            result.error("schemas/journey-result-v1.schema.json.$defs.signature.properties.key_id.const", "does not match validator signing key id")
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
            elif domain.get("status") == "deprecated":
                result.error(spec_id, f"authority domain {domain_id!r} is deprecated and must not be listed as active")
            elif domain.get("owner_spec") != spec_id:
                result.error(spec_id, f"authority domain {domain_id!r} is owned by {domain.get('owner_spec')}")

    active_domain_owners: dict[str, list[str]] = {}
    for spec_id, spec in spec_records.items():
        for domain_id in spec.get("authority_domains", []) if isinstance(spec.get("authority_domains"), list) else []:
            active_domain_owners.setdefault(domain_id, []).append(spec_id)
    for domain_id, domain in domain_records.items():
        if domain.get("status") == "deprecated":
            continue
        owner_spec = domain.get("owner_spec")
        listed_by = active_domain_owners.get(domain_id, [])
        if listed_by != [owner_spec]:
            result.error(
                f"authority domain {domain_id}",
                f"must be listed exactly on owner_spec {owner_spec}; found {listed_by or 'no owner spec listing'}",
            )

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
        if spec.get("implementation_status") == "implemented" and not owned_requirements:
            result.error(spec_id, "implementation_status implemented requires at least one owned requirement")
        if spec.get("status") == "implemented-unverified":
            nonconformant = [
                item.get("requirement_id")
                for item in owned_requirements
                if item.get("state") != "conformant"
            ]
            if nonconformant:
                result.error(spec_id, "implemented-unverified requires every owned requirement to be conformant")
        if spec.get("implementation_status") == "implemented":
            nonconformant = [
                item.get("requirement_id")
                for item in owned_requirements
                if item.get("state") != "conformant"
            ]
            if nonconformant:
                result.error(spec_id, "implementation_status implemented requires every owned requirement to be conformant")
        requires_signed_result = any(
            domain_records.get(domain_id, {}).get("requires_signed_journey_result") is True
            for domain_id in spec.get("authority_domains", [])
            if isinstance(domain_id, str)
        )
        if spec.get("production_status") == "physically-verified":
            if not owned_requirements:
                result.error(spec_id, "production_status physically-verified requires at least one owned requirement")
            nonconformant = [
                item.get("requirement_id")
                for item in owned_requirements
                if item.get("state") != "conformant"
            ]
            if nonconformant:
                result.error(spec_id, "production_status physically-verified requires every owned requirement to be conformant")
            if requires_signed_result:
                missing_signed = [
                    item.get("requirement_id")
                    for item in owned_requirements
                    if item.get("state") == "conformant"
                    and not _signed_journey_result_satisfies(
                        root,
                        item,
                        str(item.get("requirement_id")),
                        result,
                        trusted_journey_result_public_key_sha256,
                        trusted_openssl,
                        emit_errors=False,
                    )
                ]
                if missing_signed:
                    result.error(spec_id, "production_status physically-verified requires valid signed journey-result evidence for every owned requirement")
        if spec.get("status") == "physically-verified":
            nonconformant = [
                item.get("requirement_id")
                for item in owned_requirements
                if item.get("state") != "conformant"
            ]
            if nonconformant:
                result.error(spec_id, "physically-verified requires every owned requirement to be conformant")
            if requires_signed_result:
                missing_signed = [
                    item.get("requirement_id")
                    for item in owned_requirements
                    if item.get("state") == "conformant"
                    and not _signed_journey_result_satisfies(
                        root,
                        item,
                        str(item.get("requirement_id")),
                        result,
                        trusted_journey_result_public_key_sha256,
                        trusted_openssl,
                        emit_errors=False,
                    )
                ]
                if missing_signed:
                    result.error(spec_id, "physically-verified requires valid signed journey-result evidence for every owned requirement")

    for requirement_id, requirement in requirements_by_id.items():
        for mapping_key in ("implementation", "tests"):
            for mapping in requirement.get(mapping_key, []) if isinstance(requirement.get(mapping_key), list) else []:
                if isinstance(mapping, str) and SPEC_PATH_RE.match(_normalized_mapping_file(root, mapping)):
                    result.error(requirement_id, f"{mapping_key} mapping must not point at SPEC Markdown as implementation or test evidence")
        for domain_id in spec_records.get(requirement.get("spec_id"), {}).get("authority_domains", []):
            domain = domain_records.get(domain_id, {})
            if (
                domain.get("requires_signed_journey_result") is True
                and requirement.get("state") == "conformant"
            ):
                if not requirement.get("journeys"):
                    result.error(requirement_id, "sensitive conformant requirement requires a physical journey mapping")
                if not _signed_journey_result_satisfies(
                    root,
                    requirement,
                    requirement_id,
                    result,
                    trusted_journey_result_public_key_sha256,
                    trusted_openssl,
                ):
                    result.error(requirement_id, "sensitive conformant requirement requires valid signed journey-result evidence")

    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=".", help="repository root")
    parser.add_argument("--base-ref", default=None, help="trusted base ref for structured identity immutability checks")
    parser.add_argument("--openssl-bin", default=None, help="absolute path to trusted OpenSSL")
    args = parser.parse_args(argv)
    result = validate_repository(Path(args.root), args.base_ref, openssl_bin=args.openssl_bin)
    if result.errors:
        for error in result.errors:
            print(f"error: {error}", file=sys.stderr)
        return 1
    print("SPEC governance validation passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
