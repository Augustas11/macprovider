#!/usr/bin/env python3
"""Build a promotable local-consumer endpoint journey-result payload from redacted evidence."""

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
    DuplicateJSONKeyError,
    JOURNEY_RESULT_PAYLOAD_SCHEMA,
    LOCAL_CONSUMER_ENDPOINT_ARTIFACT_ID,
    LOCAL_CONSUMER_ENDPOINT_ALLOWED_GATEWAY_ORIGIN_SHA256,
    LOCAL_CONSUMER_ENDPOINT_EVIDENCE_REQUIREMENT_IDS,
    LOCAL_CONSUMER_ENDPOINT_EXECUTION_MODE,
    LOCAL_CONSUMER_ENDPOINT_JOURNEY_ID,
    LOCAL_CONSUMER_ENDPOINT_STEP_ID_ORDER,
    ValidationResult,
    _load_json,
    _unique_json_object,
)


EVIDENCE_SCHEMA = "macprovider.local-consumer-endpoint-evidence.v1"
JOURNEY_ID = "JOURNEY-LOCAL-CONSUMER-ENDPOINT"
REPOSITORY = "Augustas11/macprovider"
ARTIFACT_ID = "redacted-local-consumer-endpoint"
REQUIREMENT_RE = re.compile(r"^SPEC-[0-9]{3}-R[0-9]{3}$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
DATETIME_Z_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
DATE_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
FINGERPRINT_RE = re.compile(r"^[0-9a-f]{64}$")
SAFE_METADATA_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:@/+~-]{0,127}$")
SAFE_LOCAL_METADATA_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$")
SAFE_RUN_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
LOCAL_CONSUMER_ENDPOINT_OPERATOR_ROLES = {"release-operator"}
LOCAL_CONSUMER_ENDPOINT_HARDWARE_PROFILES = {"ci-staging-runner", "local-macos-redacted"}
CANDIDATE_IDENTITY_VERSION_RE = re.compile(r"^v?[0-9]+[.][0-9]+[.][0-9]+(?:-(?:test|dev[0-9]*|alpha[0-9]*|beta[0-9]*|rc[0-9]*))?$")
CANDIDATE_IDENTITY_MODEL_ID_RE = re.compile(
    r"^(?:"
    r"model-test|"
    r"mlx-community/(?:Llama-3[.]2-3B-Instruct-4bit|Qwen3-8B-4bit)|"
    r"gpt-[0-9]+(?:[-.](?:mini|nano|turbo|preview|latest|instruct|realtime|audio|search|chat|transcribe|tts|[0-9]{4}(?:-[0-9]{2}(?:-[0-9]{2})?)?)){0,6}|"
    r"o[1-9](?:[-.](?:mini|pro|preview|latest|reasoning|[0-9]{4}(?:-[0-9]{2}(?:-[0-9]{2})?)?)){0,6}"
    r")$"
)
CANDIDATE_IDENTITY_SDK_NAMES = {
    "openai-dotnet",
    "openai-go",
    "openai-java",
    "openai-js",
    "openai-node",
    "openai-python",
    "openai-ruby",
}
AUTHORIZATION_CONTEXT_RE = re.compile(r"(?im)['\"]?\bauthorization['\"]?\s*[:=]\s*([^\r\n]+)")
SECRET_CONTEXT_RE = re.compile(
    r"(?i)\b(local[_-]?token|api[_-]?key|x-api-key|buyer[_-]?credential|upstream[_-]?credential)\s*[:=]\s*['\"]?([^'\"\s,;)}\]]*)"
)
TEXT_KEY_CONTEXT_RE = re.compile(r"['\"]?([^\r\n:=]+?)['\"]?\s*[:=]")
ALLOWED_REDACTED_AUTHORIZATION_VALUES = {
    "basic redacted",
    "bearer redacted",
    "redacted",
}
ALLOWED_REDACTED_SECRET_VALUES = {"redacted"}
FORBIDDEN_KEY_FRAGMENTS = (
    "access_token",
    "api_key",
    "authorization",
    "authorization_header",
    "bearer_token",
    "client_secret",
    "credential",
    "id_token",
    "local_token",
    "password",
    "private_key",
    "raw_completion",
    "raw_prompt",
    "raw_request",
    "raw_response",
    "raw_secret",
    "raw_signature",
    "raw_token",
    "refresh_token",
    "secret_key",
    "session_token",
    "upstream_token",
    "wallet_private",
)
FORBIDDEN_SECRET_VALUE_PATTERNS = (
    re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----"),
    re.compile(r"(?i)\bauthorization\s*[:=][ \t]*(?!(?:redacted|bearer[ \t]+redacted|basic[ \t]+redacted)\b)(?:basic[ \t]+|bearer[ \t]+|token[ \t]+|api[-_]?key[ \t]+)?[A-Za-z0-9._~+/=-]{8,}"),
    re.compile(r"(?i)\bauthorization\s*:\s*bearer\s+(?!redacted\b)[A-Za-z0-9._~+/=-]{8,}"),
    re.compile(r"(?i)\bbearer\s+(?!redacted\b)[A-Za-z0-9._~+/=-]{20,}"),
    re.compile(r"(?i)\blocal[_-]?token\s*[:=]\s*(?!redacted\b)[A-Za-z0-9_-]{20,}"),
    re.compile(r"(?i)\bapi[_-]?key\s*[:=]\s*(?!redacted\b)[A-Za-z0-9._~+/=-]{8,}"),
    re.compile(r"(?i)\bx-api-key\s*[:=]\s*(?!redacted\b)[A-Za-z0-9._~+/=-]{8,}"),
    re.compile(r"(?i)\bbuyer[_-]?credential\s*[:=]\s*(?!redacted\b)[A-Za-z0-9._~+/=-]{8,}"),
    re.compile(r"(?i)\bupstream[_-]?credential\s*[:=]\s*(?!redacted\b)[A-Za-z0-9._~+/=-]{8,}"),
    re.compile(r"(?i)\"(?:local_token|api_key|x-api-key|x_api_key|authorization|buyer_credential|upstream_credential)\"\s*:"),
    re.compile(r"(?i)\\\"(?:local_token|api_key|x-api-key|x_api_key|authorization|buyer_credential|upstream_credential)\\\"\s*:"),
    re.compile(r"\bghp_[A-Za-z0-9_]{20,}\b"),
    re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}\b"),
    re.compile(r"\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}\b"),
    re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{20,}\b"),
    re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    re.compile(r"\bmp_[A-Za-z0-9_-]{16,}\b"),
)
FORBIDDEN_TRANSCRIPT_VALUE_PATTERNS = (
    re.compile(r"(?i)\braw[_ -]?prompt\s*[:=]"),
    re.compile(r"(?i)\braw[_ -]?completion\s*[:=]"),
    re.compile(r"(?i)(?<!_)prompt\s*[:=]"),
    re.compile(r"(?i)(?<!_)completion\s*[:=]"),
    re.compile(r"(?i)\brequest\s*[:=]"),
    re.compile(r"(?i)\bresponse\s*[:=]"),
    re.compile(r"(?i)\"choices\"\s*:"),
    re.compile(r"(?i)\"content\"\s*:"),
    re.compile(r"(?i)\"message\"\s*:"),
    re.compile(r"(?i)\"messages\"\s*:"),
    re.compile(r"(?i)\\\"choices\\\"\s*:"),
    re.compile(r"(?i)\\\"content\\\"\s*:"),
    re.compile(r"(?i)\\\"message\\\"\s*:"),
    re.compile(r"(?i)\\\"messages\\\"\s*:"),
)
FORBIDDEN_TRANSCRIPT_KEY_NAMES = {
    "completion",
    "content",
    "message",
    "messages",
    "prompt",
    "request",
    "response",
}
ALLOWED_SECRET_FINGERPRINT_KEYS = {
    "buyer_credential_fingerprint",
    "local_token_fingerprint",
}
ALLOWED_SECRET_OBSERVATION_VALUES = {
    "generated_local_token_used_as_api_key": True,
    "local_token_logged": False,
    "permitted_chat_completion_observed": True,
    "raw_completion_logged": False,
    "raw_prompt_logged": False,
    "upstream_credential_logged": False,
}
ALLOWED_SECRET_KEY_NAMES = set(ALLOWED_SECRET_FINGERPRINT_KEYS) | set(ALLOWED_SECRET_OBSERVATION_VALUES) | {
    "authorization",
    "bearer_tokens_redacted",
    "generated_local_token_used_as_api_key",
    "permitted_chat_completion_observed",
    "raw_prompt_output_redacted",
}
SUPPORT_ARTIFACT_IDS = {
    "cli_binary",
    "ledger_capture",
    "log_capture",
    "rate_card_capture",
    "status_capture",
}
SUPPORT_ARTIFACT_ROLES = {
    "cli_binary": "cli-binary",
    "ledger_capture": "redacted-ledger-capture",
    "log_capture": "redacted-log-capture",
    "rate_card_capture": "redacted-rate-card-capture",
    "status_capture": "redacted-status-capture",
}
REVIEW_FIELDS = {
    "reviewed_at",
    "reviewer_role",
    "support_artifacts_reviewed",
    "real_gateway_basis",
    "sdk_client_basis",
    "redaction_basis",
}


def die(message: str) -> None:
    print(f"build-local-consumer-endpoint-journey-result: {message}", file=sys.stderr)
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
    if Path(normalized).parent.as_posix() != "journeys/evidence":
        die("redacted evidence source must be directly under journeys/evidence")
    if not name.startswith("local-consumer-endpoint-") or not name.endswith(".redacted.json"):
        die("redacted evidence source must be journeys/evidence/local-consumer-endpoint-*.redacted.json")
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


def normalize_evidence_key(key: str) -> str:
    acronym_split = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1_\2", key)
    camel_split = re.sub(r"(?<=[a-z0-9])(?=[A-Z])", "_", acronym_split)
    normalized = re.sub(r"[^A-Za-z0-9]+", "_", camel_split).strip("_").lower()
    return re.sub(r"_+", "_", normalized)


def is_forbidden_evidence_key(key: str) -> bool:
    normalized = normalize_evidence_key(key)
    if normalized in ALLOWED_SECRET_KEY_NAMES:
        return False
    return normalized in FORBIDDEN_TRANSCRIPT_KEY_NAMES or any(
        fragment in normalized for fragment in FORBIDDEN_KEY_FRAGMENTS
    )


def normalize_framed_scalar(value: str) -> str:
    normalized = value.strip()
    if normalized.startswith(("'", "\"")):
        quote = normalized[0]
        end = normalized.find(quote, 1)
        if end == -1:
            return normalized[1:].strip()
        scalar = normalized[1:end].strip()
        trailing = normalized[end + 1 :].strip()
        trailing = trailing.rstrip("]})").strip()
        if trailing.startswith(","):
            trailing = trailing[1:].strip()
        if trailing:
            return f"{scalar},{trailing}"
        return scalar
    normalized = normalized.strip("\"'")
    if "," in normalized:
        before, after = normalized.split(",", 1)
        if after.strip():
            return normalized
        normalized = before.strip()
    return normalized.rstrip("]})").strip().strip("\"'")


def reject_bad_allowed_evidence_text_key_value(key: str, value: str, location: str) -> None:
    normalized_key = normalize_evidence_key(key)
    normalized_value = normalize_framed_scalar(value).lower()
    if normalized_key in ALLOWED_SECRET_FINGERPRINT_KEYS and FINGERPRINT_RE.fullmatch(normalized_value) is None:
        die(f"{location} contains an invalid allowed fingerprint key")
    expected = ALLOWED_SECRET_OBSERVATION_VALUES.get(normalized_key)
    if expected is not None and normalized_value != str(expected).lower():
        die(f"{location} contains an invalid allowed observation key")
    if normalized_key == "bearer_tokens_redacted" and normalized_value != "true":
        die(f"{location} contains an invalid allowed redaction key")
    if normalized_key == "raw_prompt_output_redacted" and normalized_value != "true":
        die(f"{location} contains an invalid allowed redaction key")


def scan_string_for_forbidden_values(text: str, location: str, *, scan_keys: bool = True) -> None:
    variants: list[str] = []
    seen: set[str] = set()
    candidate = text
    decode_count = 0
    while True:
        if candidate not in seen:
            variants.append(candidate)
            seen.add(candidate)
        if "\\u" not in candidate and "\\\"" not in candidate and "\\\\" not in candidate:
            break
        if decode_count >= 8:
            die(f"{location} contains over-escaped text")
        try:
            unescaped = candidate.encode("utf-8").decode("unicode_escape")
        except UnicodeDecodeError:
            die(f"{location} contains malformed escaped text")
        if unescaped == candidate:
            break
        decode_count += 1
        candidate = unescaped
    for candidate in variants:
        for match in AUTHORIZATION_CONTEXT_RE.finditer(candidate):
            value = normalize_framed_scalar(match.group(1))
            if value.lower() not in ALLOWED_REDACTED_AUTHORIZATION_VALUES:
                die(f"{location} contains a forbidden authorization value")
        for match in SECRET_CONTEXT_RE.finditer(candidate):
            value = match.group(2).strip().strip("\"'")
            if value.lower() not in ALLOWED_REDACTED_SECRET_VALUES:
                die(f"{location} contains a forbidden secret context")
        if scan_keys:
            for match in TEXT_KEY_CONTEXT_RE.finditer(candidate):
                reject_bad_allowed_evidence_text_key_value(match.group(1), candidate[match.end() :], location)
                if is_forbidden_evidence_key(match.group(1)):
                    die(f"{location} contains a forbidden secret-bearing key")
        if any(pattern.search(candidate) for pattern in FORBIDDEN_SECRET_VALUE_PATTERNS + FORBIDDEN_TRANSCRIPT_VALUE_PATTERNS):
            die(f"{location} contains a forbidden secret-like value")


def require_safe_metadata(value: Any, location: str, *, run_id: bool = False, local: bool = False) -> str:
    pattern = SAFE_RUN_ID_RE if run_id else SAFE_LOCAL_METADATA_RE if local else SAFE_METADATA_RE
    text = require_string(value, pattern, location)
    if local and ("@" in text or "/" in text or "\\" in text or "~" in text or text.lower().endswith(".local")):
        die(f"{location} must not contain operator-local identifiers")
    scan_string_for_forbidden_values(text, location)
    if local:
        if location in {"operator.role", "review.reviewer_role"} and text not in LOCAL_CONSUMER_ENDPOINT_OPERATOR_ROLES:
            die(f"{location} must equal one of {sorted(LOCAL_CONSUMER_ENDPOINT_OPERATOR_ROLES)}")
        if location == "environment.hardware_profile" and text not in LOCAL_CONSUMER_ENDPOINT_HARDWARE_PROFILES:
            die(f"{location} must equal one of {sorted(LOCAL_CONSUMER_ENDPOINT_HARDWARE_PROFILES)}")
    return text


def require_support_artifacts_reviewed(value: Any, location: str) -> list[str]:
    if not isinstance(value, list):
        die(f"{location} must be an array")
    if any(not isinstance(item, str) for item in value):
        die(f"{location} must contain only strings")
    if len(set(value)) != len(value):
        die(f"{location} must not contain duplicate artifact ids")
    expected = sorted(SUPPORT_ARTIFACT_IDS)
    if sorted(value) != expected:
        die(f"{location} must equal {expected}")
    return expected


def require_candidate_identity_metadata(value: Any, location: str, *, field: str) -> str:
    text = require_safe_metadata(value, location)
    if field in {"cli_version", "sdk_version"} and CANDIDATE_IDENTITY_VERSION_RE.fullmatch(text) is None:
        die(f"{location} has invalid version format")
    elif field == "sdk_name" and text not in CANDIDATE_IDENTITY_SDK_NAMES:
        die(f"{location} must be a known OpenAI SDK name")
    elif field == "model_id" and CANDIDATE_IDENTITY_MODEL_ID_RE.fullmatch(text) is None:
        die(f"{location} has invalid model id format")
    return text


def require_object(value: Any, location: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        die(f"{location} must be an object")
    return value


def require_exact_keys(value: dict[str, Any], required: set[str], allowed: set[str], location: str) -> None:
    missing = required - set(value)
    extra = set(value) - allowed
    if missing:
        die(f"{location} missing keys: {sorted(missing)}")
    if extra:
        die(f"{location} has unexpected keys: {sorted(extra)}")


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
    forbidden = [item for item in input_ids if item not in LOCAL_CONSUMER_ENDPOINT_EVIDENCE_REQUIREMENT_IDS]
    if forbidden:
        die(f"local-consumer endpoint journey-result cannot promote {', '.join(forbidden)}")
    return input_ids


def load_mapped_local_consumer_requirements(root: Path) -> set[str]:
    conformance = load_object(root / "specs" / "CONFORMANCE.json", "spec conformance")
    requirements = conformance.get("requirements")
    if not isinstance(requirements, list):
        die("specs/CONFORMANCE.json requirements must be an array")
    mapped: set[str] = set()
    for row in requirements:
        if not isinstance(row, dict):
            continue
        journeys = row.get("journeys")
        if isinstance(journeys, list) and LOCAL_CONSUMER_ENDPOINT_JOURNEY_ID in journeys and row.get("state") == "pending":
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
        require_exact_keys(step, {"id", "status", "artifacts", "support_artifacts"}, {"id", "status", "artifacts", "support_artifacts"}, f"steps[{index}]")
        step_id = require_string(step.get("id"), None, f"steps[{index}].id")
        if step_id in by_id:
            die(f"duplicate step id: {step_id}")
        if step.get("status") != "pass":
            die(f"{step_id}.status must equal 'pass'")
        artifacts = step.get("artifacts")
        if not isinstance(artifacts, list) or not artifacts or any(item != ARTIFACT_ID for item in artifacts):
            die(f"{step_id}.artifacts must reference {ARTIFACT_ID}")
        support = step.get("support_artifacts")
        if not isinstance(support, list) or not support or any(item not in SUPPORT_ARTIFACT_IDS for item in support):
            die(f"{step_id}.support_artifacts must reference known support artifacts")
        by_id[step_id] = {"id": step_id, "status": "pass", "artifacts": [ARTIFACT_ID]}
    missing = [step_id for step_id in LOCAL_CONSUMER_ENDPOINT_STEP_ID_ORDER if step_id not in by_id]
    extra = [step_id for step_id in by_id if step_id not in LOCAL_CONSUMER_ENDPOINT_STEP_ID_ORDER]
    if missing:
        die(f"missing local-consumer endpoint step(s): {', '.join(missing)}")
    if extra:
        die(f"unknown local-consumer endpoint step(s): {', '.join(extra)}")
    return [by_id[step_id] for step_id in LOCAL_CONSUMER_ENDPOINT_STEP_ID_ORDER]


def reject_forbidden_secret_keys(value: Any, location: str = "$") -> None:
    if isinstance(value, dict):
        for key, item in value.items():
            lowered = key.lower()
            normalized = normalize_evidence_key(key)
            if lowered in FORBIDDEN_TRANSCRIPT_KEY_NAMES:
                die(f"{location}.{key} uses a forbidden transcript-bearing field name")
            if any(fragment in lowered or fragment in normalized for fragment in FORBIDDEN_KEY_FRAGMENTS):
                is_expected_authorization = (
                    normalized == "authorization"
                    and isinstance(item, str)
                    and normalize_framed_scalar(item).lower() in ALLOWED_REDACTED_AUTHORIZATION_VALUES
                )
                is_redaction_flag = lowered.endswith("_redacted") and item is True
                is_expected_fingerprint = (
                    lowered in ALLOWED_SECRET_FINGERPRINT_KEYS
                    and isinstance(item, str)
                    and FINGERPRINT_RE.fullmatch(item) is not None
                )
                is_expected_observation = (
                    lowered in ALLOWED_SECRET_OBSERVATION_VALUES
                    and item is ALLOWED_SECRET_OBSERVATION_VALUES[lowered]
                )
                if not is_expected_authorization and not is_redaction_flag and not is_expected_fingerprint and not is_expected_observation:
                    die(f"{location}.{key} uses a forbidden secret-bearing field name")
            reject_forbidden_secret_keys(item, f"{location}.{key}")
    elif isinstance(value, list):
        for index, item in enumerate(value):
            reject_forbidden_secret_keys(item, f"{location}[{index}]")
    elif isinstance(value, str):
        scan_string_for_forbidden_values(value, location)


def require_redaction(value: Any) -> dict[str, bool]:
    redaction = require_object(value, "redaction")
    required = {"secrets_redacted", "operator_identity_redacted", "local_account_names_redacted"}
    require_exact_keys(redaction, required, required, "redaction")
    for key in required:
        if redaction.get(key) is not True:
            die(f"redaction.{key} must be true")
    return {key: True for key in sorted(required)}


def require_observations(value: Any) -> dict[str, Any]:
    observations = require_object(value, "observations")
    true_fields = {
        "bearer_tokens_redacted",
        "generated_local_token_used_as_api_key",
        "held_reservation_survived_restart",
        "local_base_url_configured",
        "openai_sdk_used",
        "over_budget_denial_observed",
        "permitted_chat_completion_observed",
        "raw_prompt_output_redacted",
        "recovery_release_observed",
        "redacted_artifacts_reviewed",
        "staging_or_production_gateway",
    }
    false_fields = {
        "fake_gateway_used",
        "local_token_logged",
        "raw_completion_logged",
        "raw_prompt_logged",
        "upstream_credential_logged",
    }
    required = true_fields | false_fields
    extra = set(observations) - required
    missing = required - set(observations)
    if extra:
        die(f"observations has unexpected keys: {sorted(extra)}")
    if missing:
        die(f"observations missing keys: {sorted(missing)}")
    for field in sorted(true_fields):
        if observations.get(field) is not True:
            die(f"observations.{field} must be true")
    for field in sorted(false_fields):
        if observations.get(field) is not False:
            die(f"observations.{field} must be false")
    return deepcopy(observations)


def require_candidate_identity(value: Any) -> dict[str, Any]:
    identity = require_object(value, "candidate_identity")
    fingerprint_fields = {
        "buyer_credential_fingerprint",
        "cli_binary_sha256",
        "ledger_sha256",
        "local_endpoint_base_url_sha256",
        "local_token_fingerprint",
        "log_capture_sha256",
        "rate_card_sha256",
        "status_capture_sha256",
        "upstream_gateway_origin_sha256",
    }
    candidate_metadata_fields = {"cli_version", "model_id", "sdk_name", "sdk_version"}
    string_fields = candidate_metadata_fields | {"gateway_kind"}
    required = fingerprint_fields | string_fields
    extra = set(identity) - required
    missing = required - set(identity)
    if extra:
        die(f"candidate_identity has unexpected keys: {sorted(extra)}")
    if missing:
        die(f"candidate_identity missing keys: {sorted(missing)}")
    for field in sorted(fingerprint_fields):
        require_string(identity.get(field), FINGERPRINT_RE, f"candidate_identity.{field}")
    for field in sorted(candidate_metadata_fields):
        require_candidate_identity_metadata(identity.get(field), f"candidate_identity.{field}", field=field)
    require_safe_metadata(identity.get("gateway_kind"), "candidate_identity.gateway_kind")
    gateway_kind = identity.get("gateway_kind")
    if gateway_kind not in {"staging", "production"}:
        die("candidate_identity.gateway_kind must equal 'staging' or 'production'")
    origin_sha = identity.get("upstream_gateway_origin_sha256")
    if origin_sha not in LOCAL_CONSUMER_ENDPOINT_ALLOWED_GATEWAY_ORIGIN_SHA256[gateway_kind]:
        die(f"candidate_identity.upstream_gateway_origin_sha256 must match one of the {gateway_kind} allowlisted origins")
    return deepcopy(identity)


def require_support_artifacts(value: Any, candidate_identity: dict[str, Any]) -> dict[str, Any]:
    support = require_object(value, "support_artifacts")
    require_exact_keys(support, SUPPORT_ARTIFACT_IDS, SUPPORT_ARTIFACT_IDS, "support_artifacts")
    expected_hashes = {
        "cli_binary": candidate_identity["cli_binary_sha256"],
        "ledger_capture": candidate_identity["ledger_sha256"],
        "log_capture": candidate_identity["log_capture_sha256"],
        "rate_card_capture": candidate_identity["rate_card_sha256"],
        "status_capture": candidate_identity["status_capture_sha256"],
    }
    normalized: dict[str, Any] = {}
    for artifact_id in sorted(SUPPORT_ARTIFACT_IDS):
        artifact = require_object(support.get(artifact_id), f"support_artifacts.{artifact_id}")
        require_exact_keys(artifact, {"role", "sha256", "bytes"}, {"role", "sha256", "bytes"}, f"support_artifacts.{artifact_id}")
        if artifact.get("role") != SUPPORT_ARTIFACT_ROLES[artifact_id]:
            die(f"support_artifacts.{artifact_id}.role has invalid value")
        artifact_sha = require_string(artifact.get("sha256"), FINGERPRINT_RE, f"support_artifacts.{artifact_id}.sha256")
        if artifact_sha != expected_hashes[artifact_id]:
            die(f"support_artifacts.{artifact_id}.sha256 must match candidate_identity")
        byte_count = artifact.get("bytes")
        if not isinstance(byte_count, int) or isinstance(byte_count, bool) or byte_count <= 0:
            die(f"support_artifacts.{artifact_id}.bytes must be a positive integer")
        normalized[artifact_id] = {"role": artifact["role"], "sha256": artifact_sha, "bytes": byte_count}
    return normalized


def require_review(value: Any) -> dict[str, Any]:
    review = require_object(value, "review")
    require_exact_keys(review, REVIEW_FIELDS, REVIEW_FIELDS, "review")
    reviewed_at = require_string(review.get("reviewed_at"), DATETIME_Z_RE, "review.reviewed_at")
    reviewer_role = require_safe_metadata(review.get("reviewer_role"), "review.reviewer_role", local=True)
    support_reviewed = require_support_artifacts_reviewed(review.get("support_artifacts_reviewed"), "review.support_artifacts_reviewed")
    if review.get("real_gateway_basis") != "staging-or-production-gateway":
        die("review.real_gateway_basis must equal 'staging-or-production-gateway'")
    if review.get("sdk_client_basis") != "openai-sdk-local-token-api-key":
        die("review.sdk_client_basis must equal 'openai-sdk-local-token-api-key'")
    if review.get("redaction_basis") != "redacted-support-artifacts-reviewed":
        die("review.redaction_basis must equal 'redacted-support-artifacts-reviewed'")
    return {
        "reviewed_at": reviewed_at,
        "reviewer_role": reviewer_role,
        "support_artifacts_reviewed": support_reviewed,
        "real_gateway_basis": "staging-or-production-gateway",
        "sdk_client_basis": "openai-sdk-local-token-api-key",
        "redaction_basis": "redacted-support-artifacts-reviewed",
    }


def build_payload(root: Path, source: str, *, source_sha: str, evidence_sha: str, requirement_ids: str | None) -> dict[str, Any]:
    require_string(source_sha, COMMIT_RE, "--source-sha")
    require_string(evidence_sha, COMMIT_RE, "--evidence-sha")
    source, path = require_evidence_source(root, source)
    evidence, evidence_bytes = load_object_bytes(path, "local-consumer endpoint redacted evidence")
    require_exact_keys(
        evidence,
        {
            "schema_version",
            "journey_id",
            "requirement_ids",
            "repository",
            "captured_at",
            "expires_at",
            "operator",
            "environment",
            "result",
            "steps",
            "redaction",
            "observations",
            "candidate_identity",
            "support_artifacts",
            "review",
            "run_id",
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
            "result",
            "steps",
            "redaction",
            "observations",
            "candidate_identity",
            "support_artifacts",
            "review",
            "run_id",
        },
        "evidence",
    )
    reject_forbidden_secret_keys(evidence)
    if evidence.get("schema_version") != EVIDENCE_SCHEMA:
        die(f"schema_version must equal {EVIDENCE_SCHEMA!r}")
    if evidence.get("journey_id") != JOURNEY_ID:
        die(f"journey_id must equal {JOURNEY_ID!r}")
    if JOURNEY_ID != LOCAL_CONSUMER_ENDPOINT_JOURNEY_ID:
        die("JOURNEY_ID drifted from LOCAL_CONSUMER_ENDPOINT_JOURNEY_ID")
    if ARTIFACT_ID != LOCAL_CONSUMER_ENDPOINT_ARTIFACT_ID:
        die("ARTIFACT_ID drifted from LOCAL_CONSUMER_ENDPOINT_ARTIFACT_ID")
    if LOCAL_CONSUMER_ENDPOINT_EXECUTION_MODE != "staging-or-production-local-consumer-endpoint":
        die("execution mode drifted from local-consumer endpoint contract")
    require_reachable_commit(root, source_sha, "--source-sha")
    require_reachable_commit(root, evidence_sha, "--evidence-sha")
    require_ancestor_commit(root, source_sha, evidence_sha)
    repository = require_object(evidence.get("repository"), "repository")
    require_exact_keys(repository, {"name", "commit"}, {"name", "commit"}, "repository")
    if repository.get("name") != REPOSITORY:
        die(f"repository.name must equal {REPOSITORY!r}")
    evidence_source_sha = require_string(repository.get("commit"), COMMIT_RE, "repository.commit")
    if evidence_source_sha != source_sha:
        die("repository.commit must exactly match --source-sha")
    require_git_file_matches(root, evidence_sha, source, evidence_bytes)

    selected_requirements = parse_requirement_ids(requirement_ids, evidence)
    mapped = load_mapped_local_consumer_requirements(root)
    not_mapped = [item for item in selected_requirements if item not in mapped]
    if not_mapped:
        die(f"requirement_ids must be pending and mapped to {LOCAL_CONSUMER_ENDPOINT_JOURNEY_ID}: {', '.join(not_mapped)}")

    captured_at = require_string(evidence.get("captured_at"), DATETIME_Z_RE, "captured_at")
    expires_at = require_string(evidence.get("expires_at"), DATE_RE, "expires_at")
    if date.fromisoformat(expires_at) < date.today():
        die("expires_at must not be in the past")
    operator = deepcopy(require_object(evidence.get("operator"), "operator"))
    require_exact_keys(operator, {"role", "identity_fingerprint"}, {"role", "identity_fingerprint"}, "operator")
    require_safe_metadata(operator.get("role"), "operator.role", local=True)
    require_string(operator.get("identity_fingerprint"), FINGERPRINT_RE, "operator.identity_fingerprint")
    environment = deepcopy(require_object(evidence.get("environment"), "environment"))
    require_exact_keys(environment, {"class", "hardware_profile", "candidate"}, {"class", "hardware_profile", "candidate"}, "environment")
    require_string(environment.get("class"), None, "environment.class")
    require_safe_metadata(environment.get("hardware_profile"), "environment.hardware_profile", local=True)
    candidate = require_safe_metadata(environment.get("candidate"), "environment.candidate")
    if candidate != f"commit:{source_sha}":
        die("environment.candidate must equal commit:<source-sha>")
    if environment.get("class") != LOCAL_CONSUMER_ENDPOINT_EXECUTION_MODE:
        die(f"environment.class must equal {LOCAL_CONSUMER_ENDPOINT_EXECUTION_MODE!r}")
    result = deepcopy(require_object(evidence.get("result"), "result"))
    require_exact_keys(result, {"status"}, {"status"}, "result")
    if result.get("status") != "pass":
        die("result.status must equal 'pass'")
    steps = require_steps(evidence.get("steps"))
    redaction = require_redaction(evidence.get("redaction"))
    observations = require_observations(evidence.get("observations"))
    candidate_identity = require_candidate_identity(evidence.get("candidate_identity"))
    require_support_artifacts(evidence.get("support_artifacts"), candidate_identity)
    require_review(evidence.get("review"))
    artifact_sha = hashlib.sha256(evidence_bytes).hexdigest()
    run_id = require_safe_metadata(evidence.get("run_id"), "run_id", run_id=True)

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
        "execution_mode": LOCAL_CONSUMER_ENDPOINT_EXECUTION_MODE,
        "observations": observations,
        "candidate_identity": candidate_identity,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("redacted_evidence_source", help="journeys/evidence/local-consumer-endpoint-*.redacted.json")
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
    print(f"build-local-consumer-endpoint-journey-result: wrote {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
