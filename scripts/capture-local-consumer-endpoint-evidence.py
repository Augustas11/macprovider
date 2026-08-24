#!/usr/bin/env python3
"""Capture SPEC-045 local-consumer endpoint redacted evidence metadata."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
import tempfile
from datetime import UTC, date, datetime, timedelta
from pathlib import Path
from urllib.parse import urlparse
from typing import Any

from check_spec_governance import (
    DuplicateJSONKeyError,
    LOCAL_CONSUMER_ENDPOINT_ARTIFACT_ID,
    LOCAL_CONSUMER_ENDPOINT_ALLOWED_GATEWAY_ORIGINS,
    LOCAL_CONSUMER_ENDPOINT_EVIDENCE_REQUIREMENT_IDS,
    LOCAL_CONSUMER_ENDPOINT_EXECUTION_MODE,
    LOCAL_CONSUMER_ENDPOINT_JOURNEY_ID,
    LOCAL_CONSUMER_ENDPOINT_STEP_ID_ORDER,
    _unique_json_object,
)


EVIDENCE_SCHEMA = "macprovider.local-consumer-endpoint-evidence.v1"
REVIEW_SCHEMA = "macprovider.local-consumer-endpoint-capture-review.v1"
REPOSITORY = "Augustas11/macprovider"
REQUIREMENT_RE = re.compile(r"^SPEC-[0-9]{3}-R[0-9]{3}$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
FINGERPRINT_RE = re.compile(r"^[0-9a-f]{64}$")
DATETIME_Z_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
DATE_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
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
FORBIDDEN_CAPTURE_KEY_NAMES = {
    "access_token",
    "api_key",
    "authorization",
    "authorization_header",
    "bearer_token",
    "buyer_credential",
    "client_secret",
    "completion",
    "content",
    "credential",
    "id_token",
    "local_token",
    "message",
    "messages",
    "password",
    "private_key",
    "prompt",
    "raw_completion",
    "raw_prompt",
    "raw_request",
    "raw_response",
    "raw_secret",
    "raw_signature",
    "raw_token",
    "refresh_token",
    "request",
    "response",
    "secret_key",
    "session_token",
    "upstream_credential",
    "upstream_token",
    "x-api-key",
    "x_api_key",
}
FORBIDDEN_CAPTURE_KEY_FRAGMENTS = {
    "access_token",
    "api_key",
    "authorization",
    "bearer_token",
    "client_secret",
    "completion",
    "content",
    "credential",
    "id_token",
    "local_token",
    "message",
    "password",
    "private_key",
    "prompt",
    "raw_completion",
    "raw_prompt",
    "raw_request",
    "raw_response",
    "raw_secret",
    "raw_signature",
    "raw_token",
    "refresh_token",
    "request",
    "response",
    "secret_key",
    "session_token",
    "upstream_token",
}
ALLOWED_CAPTURE_KEY_NAMES = {
    "authorization",
    "bearer_tokens_redacted",
    "buyer_credential_fingerprint",
    "generated_local_token_used_as_api_key",
    "local_token_fingerprint",
    "local_token_logged",
    "permitted_chat_completion_observed",
    "raw_completion_logged",
    "raw_prompt_logged",
    "raw_prompt_output_redacted",
    "upstream_credential_logged",
}
ALLOWED_TRUE_CAPTURE_KEY_NAMES = {
    "bearer_tokens_redacted",
    "generated_local_token_used_as_api_key",
    "permitted_chat_completion_observed",
    "raw_prompt_output_redacted",
}
ALLOWED_FALSE_CAPTURE_KEY_NAMES = {
    "local_token_logged",
    "raw_completion_logged",
    "raw_prompt_logged",
    "upstream_credential_logged",
}
ALLOWED_FINGERPRINT_CAPTURE_KEY_NAMES = {
    "buyer_credential_fingerprint",
    "local_token_fingerprint",
}
ALLOWED_AUTHORIZATION_CAPTURE_KEY_NAMES = {"authorization"}
SAFE_METADATA_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:@/+~-]{0,127}$")
SAFE_LOCAL_METADATA_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$")
SAFE_RUN_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
LOCAL_CONSUMER_ENDPOINT_OPERATOR_ROLES = {"release-operator"}
LOCAL_CONSUMER_ENDPOINT_HARDWARE_PROFILES = {"ci-staging-runner", "local-macos-redacted"}
CANDIDATE_IDENTITY_VERSION_RE = re.compile(r"^v?[0-9]+[.][0-9]+[.][0-9]+(?:-(?:test|dev[0-9]*|alpha[0-9]*|beta[0-9]*|rc[0-9]*))?$")
CANDIDATE_IDENTITY_MODEL_ID_RE = re.compile(
    r"^(?:"
    r"model-test|"
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
SUPPORT_ARTIFACT_IDS = (
    "cli_binary",
    "ledger_capture",
    "log_capture",
    "rate_card_capture",
    "status_capture",
)
ALLOWED_GATEWAY_ORIGINS = {
    kind: set(origins)
    for kind, origins in LOCAL_CONSUMER_ENDPOINT_ALLOWED_GATEWAY_ORIGINS.items()
}
TRUE_OBSERVATION_FIELDS = {
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
FALSE_OBSERVATION_FIELDS = {
    "fake_gateway_used",
    "local_token_logged",
    "raw_completion_logged",
    "raw_prompt_logged",
    "upstream_credential_logged",
}
REDACTION_FIELDS = {
    "local_account_names_redacted",
    "operator_identity_redacted",
    "secrets_redacted",
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
    print(f"capture-local-consumer-endpoint-evidence: {message}", file=sys.stderr)
    raise SystemExit(1)


def require_string(value: str, pattern: re.Pattern[str] | None, label: str) -> str:
    if not isinstance(value, str) or not value:
        die(f"{label} must be non-empty")
    if pattern is not None and pattern.fullmatch(value) is None:
        die(f"{label} has invalid format")
    return value


def require_safe_metadata(value: str, label: str, *, run_id: bool = False, local: bool = False) -> str:
    pattern = SAFE_RUN_ID_RE if run_id else SAFE_LOCAL_METADATA_RE if local else SAFE_METADATA_RE
    require_string(value, pattern, label)
    if local and ("@" in value or "/" in value or "\\" in value or "~" in value or value.lower().endswith(".local")):
        die(f"{label} must not contain operator-local identifiers")
    scan_text_for_forbidden_values(value, label)
    if local:
        if label in {"--operator-role", "review.reviewer_role"} and value not in LOCAL_CONSUMER_ENDPOINT_OPERATOR_ROLES:
            die(f"{label} must equal one of {sorted(LOCAL_CONSUMER_ENDPOINT_OPERATOR_ROLES)}")
        if label == "--hardware-profile" and value not in LOCAL_CONSUMER_ENDPOINT_HARDWARE_PROFILES:
            die(f"{label} must equal one of {sorted(LOCAL_CONSUMER_ENDPOINT_HARDWARE_PROFILES)}")
    return value


def require_support_artifacts_reviewed(value: Any, label: str) -> list[str]:
    if not isinstance(value, list):
        die(f"{label} must be an array")
    if any(not isinstance(item, str) for item in value):
        die(f"{label} must contain only strings")
    if len(set(value)) != len(value):
        die(f"{label} must not contain duplicate artifact ids")
    expected = list(SUPPORT_ARTIFACT_IDS)
    if sorted(value) != sorted(expected):
        die(f"{label} must equal {expected}")
    return expected


def require_candidate_identity_metadata(value: str, label: str, *, field: str) -> str:
    text = require_safe_metadata(value, label)
    if field in {"cli_version", "sdk_version"} and CANDIDATE_IDENTITY_VERSION_RE.fullmatch(text) is None:
        die(f"{label} has invalid version format")
    elif field == "sdk_name" and text not in CANDIDATE_IDENTITY_SDK_NAMES:
        die(f"{label} must be a known OpenAI SDK name")
    elif field == "model_id" and CANDIDATE_IDENTITY_MODEL_ID_RE.fullmatch(text) is None:
        die(f"{label} has invalid model id format")
    return text


def require_exact_keys(value: dict[str, Any], required: set[str], allowed: set[str], label: str) -> None:
    missing = required - set(value)
    extra = set(value) - allowed
    if missing:
        die(f"{label} missing keys: {sorted(missing)}")
    if extra:
        die(f"{label} has unexpected keys: {sorted(extra)}")


def require_repo_root(root: Path) -> Path:
    resolved = root.resolve()
    completed = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        cwd=resolved,
        capture_output=True,
        text=True,
        check=False,
    )
    if completed.returncode != 0:
        die(f"not a git repository: {resolved}")
    discovered = Path(completed.stdout.strip()).resolve()
    if discovered != resolved:
        die(f"--root must be the repository root: expected {discovered}")
    return resolved


def require_commit(root: Path, commit: str) -> str:
    require_string(commit, COMMIT_RE, "--source-sha")
    completed = subprocess.run(
        ["git", "cat-file", "-e", f"{commit}^{{commit}}"],
        cwd=root,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if completed.returncode != 0:
        die("--source-sha is not a reachable commit")
    return commit


def require_output_path(root: Path, value: str) -> Path:
    output = Path(value)
    if output.is_absolute():
        die("--output must be repository-relative")
    normalized = output.as_posix()
    if normalized.startswith("../") or "/../" in normalized or normalized == "..":
        die("--output must not contain parent traversal")
    if output.parent.as_posix() != "journeys/evidence":
        die("--output must be directly under journeys/evidence")
    if not output.name.startswith("local-consumer-endpoint-") or not output.name.endswith(".redacted.json"):
        die("--output must match journeys/evidence/local-consumer-endpoint-*.redacted.json")
    resolved = (root / output).resolve(strict=False)
    try:
        resolved.relative_to(root)
    except ValueError:
        die("--output must stay inside the repository")
    candidate = root / output
    for parent in candidate.parents:
        if parent == root.parent:
            break
        if parent.exists() and parent.is_symlink():
            die("--output parent must not be a symlink")
        if parent == root:
            break
    if candidate.exists() and candidate.is_symlink():
        die("--output must not be a symlink")
    return resolved


def require_regular_file(path: Path, label: str) -> Path:
    expanded = path.expanduser()
    current = Path(expanded.anchor) if expanded.is_absolute() else Path.cwd()
    for component in expanded.parts:
        if component in {"", expanded.anchor}:
            continue
        current = current / component
        if current.is_symlink():
            die(f"{label} must not traverse a symlink")
    resolved = expanded.resolve(strict=False)
    if not resolved.is_file() or resolved.is_symlink():
        die(f"{label} must be a regular non-symlink file")
    return resolved


def sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def sha256_text(value: str) -> str:
    return sha256_bytes(value.encode("utf-8"))


def sha256_file(path: Path, label: str, *, binary: bool = False) -> tuple[str, int]:
    resolved = require_regular_file(path, label)
    payload = resolved.read_bytes()
    if not binary:
        scan_redacted_artifact_payload(payload, label)
    return sha256_bytes(payload), len(payload)


def require_fingerprint_or_hash_text(fingerprint: str | None, text: str | None, label: str) -> str:
    if fingerprint and text:
        die(f"{label}: pass either fingerprint or value, not both")
    if fingerprint:
        return require_string(fingerprint, FINGERPRINT_RE, f"{label} fingerprint")
    if text:
        scan_text_for_forbidden_values(text, label)
        return sha256_text(text)
    die(f"{label}: missing fingerprint or value")


def scan_text_for_forbidden_values(text: str, label: str, *, scan_keys: bool = True) -> None:
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
            die(f"{label} contains over-escaped text")
        try:
            unescaped = candidate.encode("utf-8").decode("unicode_escape")
        except UnicodeDecodeError:
            die(f"{label} contains malformed escaped text")
        if unescaped == candidate:
            break
        decode_count += 1
        candidate = unescaped
    for candidate in variants:
        for match in AUTHORIZATION_CONTEXT_RE.finditer(candidate):
            value = normalize_framed_scalar(match.group(1))
            if value.lower() not in ALLOWED_REDACTED_AUTHORIZATION_VALUES:
                die(f"{label} appears to contain an unredacted authorization value")
        for match in SECRET_CONTEXT_RE.finditer(candidate):
            value = match.group(2).strip().strip("\"'")
            if value.lower() not in ALLOWED_REDACTED_SECRET_VALUES:
                die(f"{label} appears to contain an unredacted secret context")
        if scan_keys:
            for match in TEXT_KEY_CONTEXT_RE.finditer(candidate):
                key = match.group(1)
                reject_bad_allowed_capture_text_key_value(key, candidate[match.end() :], label)
                if is_forbidden_capture_key(key):
                    die(f"{label} contains forbidden transcript-bearing key {key!r}")
        for pattern in FORBIDDEN_SECRET_VALUE_PATTERNS + FORBIDDEN_TRANSCRIPT_VALUE_PATTERNS:
            if pattern.search(candidate):
                die(f"{label} appears to contain an unredacted secret or transcript")


def normalize_capture_key(key: str) -> str:
    acronym_split = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1_\2", key)
    camel_split = re.sub(r"(?<=[a-z0-9])(?=[A-Z])", "_", acronym_split)
    normalized = re.sub(r"[^A-Za-z0-9]+", "_", camel_split).strip("_").lower()
    return re.sub(r"_+", "_", normalized)


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


def is_forbidden_capture_key(key: str) -> bool:
    normalized_key = normalize_capture_key(key)
    if normalized_key in ALLOWED_CAPTURE_KEY_NAMES:
        return False
    return normalized_key in FORBIDDEN_CAPTURE_KEY_NAMES or any(
        fragment in normalized_key for fragment in FORBIDDEN_CAPTURE_KEY_FRAGMENTS
    )


def reject_bad_allowed_capture_key_value(key: str, value: Any, label: str) -> None:
    normalized_key = normalize_capture_key(key)
    if normalized_key in ALLOWED_AUTHORIZATION_CAPTURE_KEY_NAMES and (
        not isinstance(value, str)
        or normalize_framed_scalar(value).lower() not in ALLOWED_REDACTED_AUTHORIZATION_VALUES
    ):
        die(f"{label} contains invalid allowed authorization key {key!r}")
    if normalized_key in ALLOWED_TRUE_CAPTURE_KEY_NAMES and value is not True:
        die(f"{label} contains invalid allowed redaction key {key!r}")
    if normalized_key in ALLOWED_FALSE_CAPTURE_KEY_NAMES and value is not False:
        die(f"{label} contains invalid allowed redaction key {key!r}")
    if normalized_key in ALLOWED_FINGERPRINT_CAPTURE_KEY_NAMES and (
        not isinstance(value, str) or FINGERPRINT_RE.fullmatch(value) is None
    ):
        die(f"{label} contains invalid allowed fingerprint key {key!r}")


def reject_bad_allowed_capture_text_key_value(key: str, value: str, label: str) -> None:
    normalized_key = normalize_capture_key(key)
    normalized_value = normalize_framed_scalar(value).lower()
    if normalized_key in ALLOWED_TRUE_CAPTURE_KEY_NAMES and normalized_value != "true":
        die(f"{label} contains invalid allowed redaction key {key!r}")
    if normalized_key in ALLOWED_FALSE_CAPTURE_KEY_NAMES and normalized_value != "false":
        die(f"{label} contains invalid allowed redaction key {key!r}")
    if normalized_key in ALLOWED_FINGERPRINT_CAPTURE_KEY_NAMES and FINGERPRINT_RE.fullmatch(normalized_value) is None:
        die(f"{label} contains invalid allowed fingerprint key {key!r}")


def reject_forbidden_json_keys(value: Any, label: str) -> None:
    if isinstance(value, dict):
        for key, item in value.items():
            reject_bad_allowed_capture_key_value(key, item, label)
            if is_forbidden_capture_key(key):
                die(f"{label} contains forbidden transcript-bearing key {key!r}")
            reject_forbidden_json_keys(item, label)
    elif isinstance(value, list):
        for item in value:
            reject_forbidden_json_keys(item, label)
    elif isinstance(value, str):
        scan_text_for_forbidden_values(value, label, scan_keys=True)


def scan_redacted_artifact_payload(payload: bytes, label: str) -> None:
    try:
        text = payload.decode("utf-8")
    except UnicodeDecodeError as exc:
        die(f"{label} must be UTF-8 redacted text: {exc}")
    stripped = text.lstrip()
    if stripped.startswith("{") or stripped.startswith("["):
        try:
            parsed = json.loads(text, object_pairs_hook=_unique_json_object)
        except DuplicateJSONKeyError as exc:
            die(f"{label} contains duplicate JSON object key {exc.args[0]!r}")
        except json.JSONDecodeError:
            pass
        else:
            reject_forbidden_json_keys(parsed, label)
            return
    scan_text_for_forbidden_values(text, label)
    for line_number, line in enumerate(text.splitlines(), 1):
        stripped_line = line.lstrip()
        if not stripped_line or not stripped_line.startswith("{"):
            continue
        try:
            parsed = json.loads(line, object_pairs_hook=_unique_json_object)
        except DuplicateJSONKeyError as exc:
            die(f"{label} line {line_number} contains duplicate JSON object key {exc.args[0]!r}")
        except json.JSONDecodeError:
            die(f"{label} line {line_number} contains malformed JSON")
        else:
            reject_forbidden_json_keys(parsed, label)


def load_review_manifest(path: Path) -> dict[str, Any]:
    resolved = require_regular_file(path, "--review-manifest")
    payload = resolved.read_bytes()
    scan_redacted_artifact_payload(payload, "--review-manifest")
    try:
        value = json.loads(payload.decode("utf-8"), object_pairs_hook=_unique_json_object)
    except DuplicateJSONKeyError as exc:
        die(f"--review-manifest contains duplicate JSON object key {exc.args[0]!r}")
    except json.JSONDecodeError as exc:
        die(f"--review-manifest contains malformed JSON: {exc}")
    if not isinstance(value, dict):
        die("--review-manifest must be a JSON object")
    return value


def require_bool_map(value: Any, true_fields: set[str], false_fields: set[str], label: str) -> dict[str, bool]:
    if not isinstance(value, dict):
        die(f"{label} must be an object")
    required = true_fields | false_fields
    require_exact_keys(value, required, required, label)
    result: dict[str, bool] = {}
    for field in sorted(true_fields):
        if value.get(field) is not True:
            die(f"{label}.{field} must be true")
        result[field] = True
    for field in sorted(false_fields):
        if value.get(field) is not False:
            die(f"{label}.{field} must be false")
        result[field] = False
    return result


def require_steps_from_review(value: Any) -> list[dict[str, Any]]:
    if not isinstance(value, list):
        die("review.steps must be an array")
    by_id: dict[str, dict[str, Any]] = {}
    for index, item in enumerate(value):
        if not isinstance(item, dict):
            die(f"review.steps[{index}] must be an object")
        require_exact_keys(item, {"id", "status", "artifacts", "support_artifacts"}, {"id", "status", "artifacts", "support_artifacts"}, f"review.steps[{index}]")
        step_id = require_string(item.get("id"), None, f"review.steps[{index}].id")
        if step_id in by_id:
            die(f"duplicate review step id: {step_id}")
        if item.get("status") != "pass":
            die(f"review step {step_id} status must be pass")
        if item.get("artifacts") != [LOCAL_CONSUMER_ENDPOINT_ARTIFACT_ID]:
            die(f"review step {step_id} artifacts must reference {LOCAL_CONSUMER_ENDPOINT_ARTIFACT_ID}")
        support = item.get("support_artifacts")
        if not isinstance(support, list) or not support or any(artifact not in SUPPORT_ARTIFACT_IDS for artifact in support):
            die(f"review step {step_id} must bind to known support artifacts")
        by_id[step_id] = {"id": step_id, "status": "pass", "artifacts": [LOCAL_CONSUMER_ENDPOINT_ARTIFACT_ID], "support_artifacts": sorted(set(support))}
    missing = [step_id for step_id in LOCAL_CONSUMER_ENDPOINT_STEP_ID_ORDER if step_id not in by_id]
    extra = [step_id for step_id in by_id if step_id not in LOCAL_CONSUMER_ENDPOINT_STEP_ID_ORDER]
    if missing:
        die(f"review.steps missing local-consumer endpoint steps: {missing}")
    if extra:
        die(f"review.steps has unknown local-consumer endpoint steps: {extra}")
    return [by_id[step_id] for step_id in LOCAL_CONSUMER_ENDPOINT_STEP_ID_ORDER]


def require_review(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        die("review.review must be an object")
    require_exact_keys(value, REVIEW_FIELDS, REVIEW_FIELDS, "review.review")
    reviewed_at = require_string(value.get("reviewed_at"), DATETIME_Z_RE, "review.reviewed_at")
    support = require_support_artifacts_reviewed(value.get("support_artifacts_reviewed"), "review.support_artifacts_reviewed")
    reviewer_role = require_safe_metadata(value.get("reviewer_role"), "review.reviewer_role", local=True)
    if value.get("real_gateway_basis") != "staging-or-production-gateway":
        die("review.real_gateway_basis must equal 'staging-or-production-gateway'")
    if value.get("sdk_client_basis") != "openai-sdk-local-token-api-key":
        die("review.sdk_client_basis must equal 'openai-sdk-local-token-api-key'")
    if value.get("redaction_basis") != "redacted-support-artifacts-reviewed":
        die("review.redaction_basis must equal 'redacted-support-artifacts-reviewed'")
    return {
        "reviewed_at": reviewed_at,
        "reviewer_role": reviewer_role,
        "support_artifacts_reviewed": support,
        "real_gateway_basis": "staging-or-production-gateway",
        "sdk_client_basis": "openai-sdk-local-token-api-key",
        "redaction_basis": "redacted-support-artifacts-reviewed",
    }


def require_manifest_support_artifacts(value: Any, expected: dict[str, Any]) -> None:
    if not isinstance(value, dict):
        die("review.support_artifacts must be an object")
    require_exact_keys(value, set(SUPPORT_ARTIFACT_IDS), set(SUPPORT_ARTIFACT_IDS), "review.support_artifacts")
    for artifact_id in SUPPORT_ARTIFACT_IDS:
        artifact = value.get(artifact_id)
        if not isinstance(artifact, dict):
            die(f"review.support_artifacts.{artifact_id} must be an object")
        require_exact_keys(artifact, {"sha256", "bytes"}, {"sha256", "bytes"}, f"review.support_artifacts.{artifact_id}")
        sha256 = require_string(artifact.get("sha256"), FINGERPRINT_RE, f"review.support_artifacts.{artifact_id}.sha256")
        byte_count = artifact.get("bytes")
        if not isinstance(byte_count, int) or isinstance(byte_count, bool) or byte_count <= 0:
            die(f"review.support_artifacts.{artifact_id}.bytes must be a positive integer")
        if sha256 != expected[artifact_id]["sha256"] or byte_count != expected[artifact_id]["bytes"]:
            die(f"review.support_artifacts.{artifact_id} must match the reviewed artifact bytes")


def require_review_manifest(value: dict[str, Any], *, run_id: str, support_artifacts: dict[str, Any]) -> tuple[list[dict[str, Any]], dict[str, bool], dict[str, bool], dict[str, Any]]:
    required = {"schema_version", "journey_id", "run_id", "result", "steps", "redaction", "observations", "support_artifacts", "review"}
    require_exact_keys(value, required, required, "review")
    if value.get("schema_version") != REVIEW_SCHEMA:
        die(f"review.schema_version must equal {REVIEW_SCHEMA!r}")
    if value.get("journey_id") != LOCAL_CONSUMER_ENDPOINT_JOURNEY_ID:
        die(f"review.journey_id must equal {LOCAL_CONSUMER_ENDPOINT_JOURNEY_ID!r}")
    if value.get("run_id") != run_id:
        die("review.run_id must match --run-id")
    require_manifest_support_artifacts(value.get("support_artifacts"), support_artifacts)
    result = value.get("result")
    if not isinstance(result, dict):
        die("review.result must be an object")
    require_exact_keys(result, {"status"}, {"status"}, "review.result")
    if result.get("status") != "pass":
        die("review.result.status must equal pass")
    steps = require_steps_from_review(value.get("steps"))
    redaction = require_bool_map(value.get("redaction"), REDACTION_FIELDS, set(), "review.redaction")
    observations = require_bool_map(value.get("observations"), TRUE_OBSERVATION_FIELDS, FALSE_OBSERVATION_FIELDS, "review.observations")
    review = require_review(value.get("review"))
    return steps, redaction, observations, review


def require_local_endpoint_url(value: str) -> str:
    parsed = urlparse(value)
    if parsed.scheme != "http" or parsed.hostname not in {"127.0.0.1", "localhost", "::1"}:
        die("local endpoint base URL must be an http loopback URL")
    if parsed.port is None or parsed.port <= 0:
        die("local endpoint base URL must include a nonzero port")
    if parsed.path != "/v1":
        die("local endpoint base URL path must equal /v1")
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        die("local endpoint base URL must not contain userinfo, query, or fragment")
    scan_text_for_forbidden_values(value, "local endpoint base URL")
    return value


def require_gateway_origin(value: str, gateway_kind: str) -> str:
    parsed = urlparse(value)
    if parsed.scheme != "https" or not parsed.hostname:
        die("upstream gateway origin must be an https origin")
    if parsed.username or parsed.password or parsed.path not in {"", "/"} or parsed.query or parsed.fragment:
        die("upstream gateway origin must not contain userinfo, path, query, or fragment")
    hostname = parsed.hostname.lower()
    if hostname.endswith(".invalid") or hostname in {"localhost", "127.0.0.1", "::1"}:
        die("upstream gateway origin must be a staging or production origin, not a fake/local origin")
    normalized = f"https://{hostname}"
    if parsed.port is not None:
        normalized = f"{normalized}:{parsed.port}"
    allowed = ALLOWED_GATEWAY_ORIGINS.get(gateway_kind, set())
    if normalized not in allowed:
        die(f"upstream gateway origin must be one of the {gateway_kind} allowlisted origins")
    scan_text_for_forbidden_values(value, "upstream gateway origin")
    return normalized


def parse_requirement_ids(raw: str) -> list[str]:
    ids = [item.strip() for item in raw.split(",") if item.strip()]
    if not ids:
        die("--requirement-ids must not be empty")
    if len(ids) != len(set(ids)):
        die("--requirement-ids must be unique")
    invalid = [item for item in ids if REQUIREMENT_RE.fullmatch(item) is None]
    if invalid:
        die(f"invalid requirement id(s): {', '.join(invalid)}")
    forbidden = [item for item in ids if item not in LOCAL_CONSUMER_ENDPOINT_EVIDENCE_REQUIREMENT_IDS]
    if forbidden:
        die(f"local-consumer endpoint evidence cannot cover {', '.join(forbidden)}")
    return ids


def parse_captured_at(raw: str | None) -> str:
    if raw is None:
        return datetime.now(UTC).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")
    require_string(raw, DATETIME_Z_RE, "--captured-at")
    return raw


def parse_expires_at(raw: str | None, captured_at: str) -> str:
    if raw is None:
        captured = datetime.strptime(captured_at, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=UTC)
        return (captured.date() + timedelta(days=30)).isoformat()
    require_string(raw, DATE_RE, "--expires-at")
    if date.fromisoformat(raw) < date.today():
        die("--expires-at must not be in the past")
    return raw


def build_evidence(args: argparse.Namespace) -> dict[str, Any]:
    root = require_repo_root(Path(args.root))
    source_sha = require_commit(root, args.source_sha)
    output = require_output_path(root, args.output)
    relative_output = output.relative_to(root).as_posix()
    captured_at = parse_captured_at(args.captured_at)
    expires_at = parse_expires_at(args.expires_at, captured_at)
    run_id = require_safe_metadata(args.run_id, "--run-id", run_id=True)
    review_manifest = load_review_manifest(Path(args.review_manifest))

    if args.gateway_kind not in {"staging", "production"}:
        die("--gateway-kind must equal 'staging' or 'production'")

    requirement_ids = parse_requirement_ids(args.requirement_ids)
    cli_binary_sha256, cli_binary_bytes = sha256_file(Path(args.cli_binary), "--cli-binary", binary=True)
    ledger_sha256, ledger_bytes = sha256_file(Path(args.ledger_capture), "--ledger-capture")
    log_capture_sha256, log_bytes = sha256_file(Path(args.log_capture), "--log-capture")
    rate_card_sha256, rate_card_bytes = sha256_file(Path(args.rate_card_capture), "--rate-card-capture")
    status_capture_sha256, status_bytes = sha256_file(Path(args.status_capture), "--status-capture")
    if args.local_endpoint_base_url_sha256:
        die("--local-endpoint-base-url-sha256 is not accepted for capture; pass --local-endpoint-base-url")
    if args.upstream_gateway_origin_sha256:
        die("--upstream-gateway-origin-sha256 is not accepted for capture; pass --upstream-gateway-origin")
    local_endpoint_base_url_sha256 = sha256_text(require_local_endpoint_url(args.local_endpoint_base_url or ""))
    upstream_gateway_origin_sha256 = sha256_text(require_gateway_origin(args.upstream_gateway_origin or "", args.gateway_kind))

    operator_identity_fingerprint = require_string(
        args.operator_identity_fingerprint,
        FINGERPRINT_RE,
        "--operator-identity-fingerprint",
    )
    buyer_credential_fingerprint = require_string(
        args.buyer_credential_fingerprint,
        FINGERPRINT_RE,
        "--buyer-credential-fingerprint",
    )
    local_token_fingerprint = require_string(
        args.local_token_fingerprint,
        FINGERPRINT_RE,
        "--local-token-fingerprint",
    )
    support_artifacts = {
        "cli_binary": {"role": "cli-binary", "sha256": cli_binary_sha256, "bytes": cli_binary_bytes},
        "ledger_capture": {"role": "redacted-ledger-capture", "sha256": ledger_sha256, "bytes": ledger_bytes},
        "log_capture": {"role": "redacted-log-capture", "sha256": log_capture_sha256, "bytes": log_bytes},
        "rate_card_capture": {"role": "redacted-rate-card-capture", "sha256": rate_card_sha256, "bytes": rate_card_bytes},
        "status_capture": {"role": "redacted-status-capture", "sha256": status_capture_sha256, "bytes": status_bytes},
    }
    steps, redaction, observations, review = require_review_manifest(review_manifest, run_id=run_id, support_artifacts=support_artifacts)
    candidate = require_safe_metadata(args.candidate, "--candidate")
    if candidate != f"commit:{source_sha}":
        die("--candidate must equal commit:<source-sha>")

    evidence = {
        "schema_version": EVIDENCE_SCHEMA,
        "journey_id": LOCAL_CONSUMER_ENDPOINT_JOURNEY_ID,
        "requirement_ids": requirement_ids,
        "repository": {"name": REPOSITORY, "commit": source_sha},
        "captured_at": captured_at,
        "expires_at": expires_at,
        "operator": {
            "role": require_safe_metadata(args.operator_role, "--operator-role", local=True),
            "identity_fingerprint": operator_identity_fingerprint,
        },
        "environment": {
            "class": LOCAL_CONSUMER_ENDPOINT_EXECUTION_MODE,
            "hardware_profile": require_safe_metadata(args.hardware_profile, "--hardware-profile", local=True),
            "candidate": candidate,
        },
        "result": {"status": "pass"},
        "steps": steps,
        "redaction": redaction,
        "observations": observations,
        "candidate_identity": {
            "buyer_credential_fingerprint": buyer_credential_fingerprint,
            "cli_binary_sha256": cli_binary_sha256,
            "cli_version": require_candidate_identity_metadata(args.cli_version, "--cli-version", field="cli_version"),
            "gateway_kind": args.gateway_kind,
            "ledger_sha256": ledger_sha256,
            "local_endpoint_base_url_sha256": local_endpoint_base_url_sha256,
            "local_token_fingerprint": local_token_fingerprint,
            "log_capture_sha256": log_capture_sha256,
            "model_id": require_candidate_identity_metadata(args.model_id, "--model-id", field="model_id"),
            "rate_card_sha256": rate_card_sha256,
            "sdk_name": require_candidate_identity_metadata(args.sdk_name, "--sdk-name", field="sdk_name"),
            "sdk_version": require_candidate_identity_metadata(args.sdk_version, "--sdk-version", field="sdk_version"),
            "status_capture_sha256": status_capture_sha256,
            "upstream_gateway_origin_sha256": upstream_gateway_origin_sha256,
        },
        "support_artifacts": support_artifacts,
        "review": review,
        "run_id": run_id,
    }
    scan_redacted_artifact_payload(json.dumps(evidence, sort_keys=True).encode("utf-8"), "generated evidence")
    args._resolved_output = output
    args._relative_output = relative_output
    return evidence


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


def parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    all_requirements = ",".join(sorted(LOCAL_CONSUMER_ENDPOINT_EVIDENCE_REQUIREMENT_IDS))
    parser.add_argument("--root", default=".", help="repository root")
    parser.add_argument("--output", required=True, help="journeys/evidence/local-consumer-endpoint-*.redacted.json")
    parser.add_argument("--source-sha", required=True, help="candidate source commit")
    parser.add_argument("--captured-at", default=None, help="UTC capture timestamp, e.g. 2026-08-24T00:00:00Z")
    parser.add_argument("--expires-at", default=None, help="evidence expiry date, defaults to capture date + 30 days")
    parser.add_argument("--requirement-ids", default=all_requirements, help="comma-separated SPEC-045 requirement IDs")
    parser.add_argument("--review-manifest", required=True, help="closed JSON review manifest for the physical journey")
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--operator-role", required=True)
    parser.add_argument("--operator-identity-fingerprint", required=True)
    parser.add_argument("--hardware-profile", required=True)
    parser.add_argument("--candidate", required=True)
    parser.add_argument("--gateway-kind", choices=("staging", "production"), required=True)
    parser.add_argument("--model-id", required=True)
    parser.add_argument("--sdk-name", required=True)
    parser.add_argument("--sdk-version", required=True)
    parser.add_argument("--buyer-credential-fingerprint", required=True)
    parser.add_argument("--local-token-fingerprint", required=True)
    parser.add_argument("--local-endpoint-base-url", default=None)
    parser.add_argument("--local-endpoint-base-url-sha256", default=None)
    parser.add_argument("--upstream-gateway-origin", default=None)
    parser.add_argument("--upstream-gateway-origin-sha256", default=None)
    parser.add_argument("--cli-version", required=True)
    parser.add_argument("--cli-binary", required=True)
    parser.add_argument("--ledger-capture", required=True)
    parser.add_argument("--log-capture", required=True)
    parser.add_argument("--rate-card-capture", required=True)
    parser.add_argument("--status-capture", required=True)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    evidence = build_evidence(args)
    write_json_atomically(args._resolved_output, evidence)
    print(args._relative_output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
