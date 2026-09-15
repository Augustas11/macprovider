#!/usr/bin/env python3
"""Validate redacted Build 1 narrow MVP physical acceptance evidence.

This validator is intentionally narrow. It accepts only the approved Build 1 MVP
profile and only physical-staging evidence that proves the request went through a
physical `macprovider-cli` MLX provider, not a fixture/fake provider, before any
human or PR text may cite it as Build 1 MVP physical acceptance.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import hashlib
import json
import math
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

SCHEMA_VERSION = "macprovider.build1-narrow-mvp-evidence.v1"
BUILD_ID = "build1-narrow-mvp"
CATALOG_KEY = "meta-llama/llama-3.2-3b-instruct"
MODEL_ID = "mlx-community/Llama-3.2-3B-Instruct-4bit"
RUNTIME_SOURCE = "mlx_cache"
ARTIFACT_ID = "mlx-4bit"
MODEL_REVISION = "7f0dc925e0d0afb0322d96f9255cfddf2ba5636e"
ARTIFACT_HASH_ALGORITHM = "macprovider.snapshot-manifest.v1"
ARTIFACT_HASH = "e7e5bff4248768b4db7a53afb3b514ba5867b800f63d1abd0330eaf08e54aa90"
WEIGHTS_MANIFEST_ALGORITHM = "macprovider.safetensors-manifest.v1"
TRUSTED_ARTIFACT_FEED_SIGNER_KEY_ID = "streamvc-autotune-static-v4"
ROUTE_SNAPSHOT_POLICY_VERSION = "spec022-prereq-v1"
RATE_CARD_KEY = CATALOG_KEY
PROMPT_RATE = 13_500
CACHED_PROMPT_RATE = 3_375
COMPLETION_RATE = 27_000
PROVIDER_SHARE_BPS = 9_000
GLOBAL_MULTIPLIER_PPM = 1_000_000
USD_PER_MILLION_CREDITS = 1.0
MIN_EVIDENCE_CAPTURED_AT = _dt.datetime(2026, 9, 14, 0, 0, 0, tzinfo=_dt.UTC)
MAX_EVIDENCE_AGE_SECONDS = 7 * 24 * 60 * 60
MAX_FUTURE_SKEW_SECONDS = 5 * 60

STAGING_CONFIG_SOURCE_VALUES = {
    "settlement_mode_source": "redacted staging coordinator config capture",
    "rewards_disabled_source": "redacted staging job config capture",
    "operator_payment_jobs_disabled_source": "redacted staging job config capture",
    "operator_payment_execution_disabled_source": "redacted staging operator config capture",
    "production_enforcement_source": "redacted production config diff capture",
}

HEX40_RE = re.compile(r"^[0-9a-f]{40}$")
HEX64_RE = re.compile(r"^[0-9a-f]{64}$")
REQUEST_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:@+-]{0,127}$")
PROVIDER_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:@+-]{0,127}$")
ISO_Z_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
RECEIPT_KEY_ID_RE = re.compile(r"^ed25519-sha256:[0-9a-f]{64}$")
IDENTIFIER_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:@+/-]{0,127}$")
BINARY_VERSION_RE = re.compile(r"^[0-9A-Za-z][0-9A-Za-z._+-]{0,63}$")
MACOS_VERSION_RE = re.compile(r"^macOS [0-9]+(?:\.[0-9]+){0,2}(?: \([0-9A-Za-z._-]{1,32}\))?$")
APPLE_SILICON_CHIP_RE = re.compile(r"^(?:Apple )?M[1-9][0-9]?(?: (?:Pro|Max|Ultra))?$")
MLX_VERSION_RE = re.compile(r"^[0-9]+(?:\.[0-9]+){1,3}(?:[._+-][0-9A-Za-z]+)?$")
CURSOR_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:@+-]{0,127}$")
SECRET_KEY_PARTS = (
    "access_token", "api_key", "apikey", "auth_header", "auth_token",
    "authorization", "bearer", "client_key", "cloud_token", "credential", "hot_wallet",
    "kek", "password", "private_key", "raw_path", "raw_secret",
    "raw_token", "secret", "x_api_key",
)
PAYOUT_SECRET_KEY_PARTS = ("encrypted_payout", "encrypted_wallet", "payout", "wallet")
ALLOWED_SECRET_KEY_PATHS = {
    "$.scope.payout_jobs_enabled",
    "$.scope.payout_execution_enabled",
    "$.production_blockers.payout_jobs_enabled",
    "$.production_blockers.payout_execution_enabled",
}
FORBIDDEN_TRUE_FLAG_KEYS = {
    "economic_activation_enabled",
    "enforcement_enabled",
    "payout_enabled",
    "payout_execution_enabled",
    "payout_jobs_enabled",
    "payouts_enabled",
    "production_activated",
    "production_activation_enabled",
    "production_enforcement_changed",
    "production_enforcement_enabled",
    "production_rewards_enabled",
    "production_settlement_enforced",
    "release_published",
    "reward_payout_enabled",
    "rewards_enabled",
    "physical_acceptance",
    "acceptance_passed",
    "acceptance_qualified",
}
TRUTHY_STATUS_VALUES = {"true", "yes", "enabled", "active", "activated", "published", "enforced", "qualified", "ready", "on", "1"}
DISQUALIFYING_ACCEPTANCE_KEYS = {
    "fixture_only",
    "historical_run",
    "operator_claimed_physical",
    "skipped",
    "timed_out",
    "zero_selected",
}
DISQUALIFYING_ACCEPTANCE_VALUES = {
    "fixture_integration",
    "fixture_only",
    "historical_run",
    "operator_claimed_physical",
    "skipped",
    "timed_out",
    "zero_selected",
}
FORBIDDEN_VALUE_PATTERNS = (
    re.compile(r"(?i)[a-z][a-z0-9+.-]*://"),
    re.compile(r"(?i)authorization\s*:\s*bearer\s+(?!redacted\b)[A-Za-z0-9._~+/=-]{8,}"),
    re.compile(r"(?i)\bbearer\s+(?!redacted\b)\S{8,}"),
    re.compile(r"(?i)\bbearer\s+redacted\s+\S+"),
    re.compile(r"(?i)-----BEGIN [A-Z ]*(?:PRIVATE|PUBLIC) KEY-----"),
    re.compile(r"(?i)\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"),
    re.compile(r"(?i)\b(?:sk|sk-proj|ghp|github_pat|xox[baprs]-|AKIA|ASIA)[A-Za-z0-9_\-]{8,}\b"),
    re.compile(r"\bAIza[A-Za-z0-9_-]{20,}\b"),
    re.compile(r"\bya29\.[A-Za-z0-9_-]{20,}\b"),
    re.compile(r"\bglpat-[A-Za-z0-9_-]{20,}\b"),
    re.compile(r"(?i)(?:\?|&)(?:sv|se|sp|sig)=[A-Za-z0-9%._~+/-]{3,}"),
    re.compile(r"(?i)\bMACPROVIDER_[A-Z0-9_]*(?:SECRET|TOKEN|KEY|KEK)[A-Z0-9_]*\b"),
    re.compile(r"(?:^|[\s\"'=,;([])(?:/Users|/home|/root|/private|/tmp|/var/folders|/Volumes|/etc)/[A-Za-z0-9._~ /-]+"),
    re.compile(r"(?:^|[\s\"'=,;([])(?:~|\$HOME)/[A-Za-z0-9._~ /-]+"),
)
FORBIDDEN_TEXT_PATTERNS = (
    re.compile(r"(?i)\bproduction\b.{0,80}\b(?:qualified|ready|activated|enabled|enforced|live|on|working|operational)\b"),
    re.compile(r"(?i)\bproduction settlement\b.{0,80}\b(?:running|active|activated|enabled|enforced|live|on|working|operational)\b"),
    re.compile(r"(?i)\b(?:shipped|published|released)\b.{0,80}\bproduction release\b"),
    re.compile(r"(?i)\bproduction release\b.{0,80}\b(?:shipped|published|released)\b"),
    re.compile(r"(?i)\b(?:payouts?|rewards?)\b.{0,40}\b(?:enabled|active|activated|ready|qualified|live|on)\b"),
    re.compile(r"(?i)\b(?:payouts?|reward payments?|rewards?)\b.{0,80}\b(?:processed|distributed|paid|completed|sent|succeeded|issued)\b"),
    re.compile(r"(?i)\b(?:historical|fixture)\b.{0,80}\b(?:acceptance|physical|run|evidence)\b"),
    re.compile(r"(?i)\b(?:acceptance|physical|run|evidence)\b.{0,80}\b(?:historical|fixture)\b"),
    re.compile(r"(?i)\bskipp?ed\b.{0,80}\b(?:physical|mac|run|acceptance)\b"),
    re.compile(r"(?i)\b(?:physical|mac|run|acceptance)\b.{0,80}\bskipp?ed\b"),
    re.compile(r"(?i)\b(?:mac test|physical test|physical run|test run)\b.{0,80}\bdid not run\b"),
    re.compile(r"(?i)\blast year(?:'s|s)?\b.{0,80}\bphysical evidence\b"),
    re.compile(r"(?i)\boperator[- ]claimed\b.{0,80}\b(?:physical|inference|acceptance)\b"),
    re.compile(r"(?i)\breused\b.{0,80}\bold test run\b"),
    re.compile(r"(?i)\bold test run\b.{0,80}\breused\b"),
)

SAFE_ERROR_KEY_NAMES = {
    "schema_version", "build_id", "validation_scope", "evidence_class", "captured_at",
    "repository", "scope", "capture", "profile", "environment", "staging_config",
    "hardware", "runtime", "artifact_feed", "preparation", "provider", "admission",
    "request", "route_snapshot", "settlement", "settlement_verdict", "production_blockers",
    "name", "commit", "branch", "production_activation_enabled", "production_enforcement_changed",
    "production_rewards_enabled", "payout_jobs_enabled", "payout_execution_enabled", "release_published",
    "command", "started_at", "completed_at", "binary_version", "binary_sha256", "redaction_passed",
    "skipped", "operator_notes", "source_captures", "review_required", "manifest_sha256",
    "physical_run_log_sha256", "request_transcript_sha256", "status_before_sha256",
    "status_after_sha256", "provider_receipt_audit_sha256", "coordinator_route_snapshot_sha256",
    "coordinator_settlement_verdict_sha256", "redaction_report_sha256", "catalog_key", "model_id",
    "runtime_source", "artifact_id", "model_revision", "artifact_hash_algorithm", "artifact_hash",
    "rate", "rate_card_key", "prompt_rate_per_mtok", "prompt_cache_hit_rate_per_mtok",
    "completion_rate_per_mtok", "provider_share_bps", "global_multiplier_ppm",
    "usd_per_million_credits", "class", "verified_model_settlement_mode", "staging_isolated",
    "production_endpoints_untouched", "credentials_redacted", "secrets_redacted", "environment_id",
    "coordinator_url_redacted", "gateway_url_redacted", "rewards_disabled",
    "operator_payment_jobs_disabled", "operator_payment_execution_disabled", "production_enforcement_unchanged",
    "policy_version", "config_source_kind", "config_digest", "deploy_event_id",
    "settlement_mode_source", "rewards_disabled_source", "operator_payment_jobs_disabled_source",
    "operator_payment_execution_disabled_source", "production_enforcement_source",
    "rewards_disabled_evidence_digest", "operator_payment_jobs_disabled_evidence_digest",
    "operator_payment_execution_disabled_evidence_digest", "production_enforcement_evidence_digest",
    "context_id", "chip", "ram_gb", "free_disk_bytes", "os_version", "source", "mlx_version",
    "context_profile", "max_concurrency", "hardware_context_id", "freshness", "signature_verified",
    "release_bound", "measured_size", "size_bytes", "feed_sha256", "candidate_catalog_sha256",
    "release_id", "artifact_feed_signer_key_id", "verification_status", "primary_artifact_id",
    "route_binding", "candidate_catalog_body_digest", "status", "available_disk_bytes", "staged_bytes",
    "snapshot_manifest_verified", "cancellation_preserves_active_model", "recovery_safe",
    "adopted_model_id", "inventory_digest", "weights_manifest_sha256", "kind", "fake_provider",
    "provider_id", "pid", "receipt_key_available", "receipt_audit_cursor_before", "status_before",
    "status_after", "correlation", "endpoint", "model_loaded", "model", "model_hash",
    "model_hash_algorithm", "weights_manifest_algorithm", "event_type", "timestamp", "cursor",
    "served_count_supporting_only", "request_id", "tokens_out", "ttft_ms", "unix_ts",
    "receipt_metadata_present", "event_id", "state", "rate_card_key", "model_admission_candidate_id",
    "model_admission_coordinator_event_id", "model_admission_served_model_ref",
    "model_admission_catalog_model_key", "model_admission_discovery_digest_sha256",
    "model_admission_evaluation_digest_sha256", "streaming", "response_status", "actual_mlx_inference",
    "route_provider_id", "admission_event_id", "usage", "billable_input_tokens",
    "billable_output_tokens", "delivered_output_bytes", "observed_input_tokens", "observed_output_tokens",
    "route_snapshot_digest", "artifact_binding", "artifact_binding_digest", "artifact_binding_source",
    "route_snapshot_v1", "account_scope", "attempt_n", "provider_session_id",
    "provider_generation_id", "paid_entrypoint", "provider_receipt_key_id", "provider_receipt_key_source",
    "provider_reported_model_hash", "provider_reported_model_hash_algorithm", "expected_catalog_model_hash",
    "expected_catalog_model_hash_algorithm", "catalog_id", "catalog_body_digest",
    "catalog_signature_key_id", "catalog_signature_pubkey_fingerprint", "catalog_expires_at_unix_ms",
    "spec008_hash_status", "artifact_feed_sha256", "artifact_candidate_catalog_sha256",
    "route_snapshot_policy_version", "route_snapshot_mode", "route_decision_ts_unix_ms",
    "request_start_ts_unix_ms", "pending_deadline_seconds", "prompt_hash_basis", "prompt_hash",
    "verified", "cached_billable_input_tokens", "credits", "provider_share_credits", "outcome",
    "receipt_verification_outcome", "receipt_version", "terminal_state", "qualification",
}

ENDPOINT_KEY_PARTS = ("url", "endpoint", "host", "coordinator", "gateway")
SINGLE_LABEL_PATH_RE = re.compile(r"(?i)^[a-z][a-z0-9-]*/[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]+$")
SINGLE_LABEL_PATH_SUBSTRING_RE = re.compile(r"(?i)(?:^|[\s\"'=,;(\[])[a-z][a-z0-9_-]*/[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]+(?=$|[\s\"'),;\]}])")
SENSITIVE_SINGLE_LABEL_PATH_SUBSTRING_RE = re.compile(r"(?i)(?:^|[\s\"'=,;(\[])[a-z0-9_-]*(?:coordinator|gateway)[a-z0-9_-]*/[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]+(?=$|[\s\"'),;\]}])")
DOMAIN_ONLY_RE = re.compile(r"(?i)^(?:[a-z0-9-]+\.)+[a-z]{2,63}$")
BARE_ENDPOINT_RE = re.compile(r"(?i)(?:\b(?:[a-z0-9-]+\.)+[a-z]{2,63}(?:(?::[0-9]{2,5})(?:/[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]*)?|/[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]*)|\blocalhost(?::[0-9]{2,5})?(?:/[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]*)?|\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?::[0-9]{2,5})?(?:/[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]*)?|\[[0-9a-f:.]+\](?::[0-9]{2,5})?(?:/[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]*)?|(?:^|[\s\"'=,;(\[])[a-z][a-z0-9_-]*:[0-9]{2,5}(?:/[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]*)?(?=$|[\s\"'),;\]}]))")


@dataclass
class ValidationResult:
    errors: list[str] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return not self.errors

    def add(self, path: str, message: str) -> None:
        self.errors.append(f"{path}: {message}")


def _as_object(value: Any, path: str, result: ValidationResult) -> dict[str, Any]:
    if isinstance(value, dict):
        return value
    result.add(path, "must be an object")
    return {}


def _get_object(obj: dict[str, Any], key: str, path: str, result: ValidationResult) -> dict[str, Any]:
    if key not in obj:
        result.add(path, f"missing {key}")
        return {}
    return _as_object(obj[key], f"{path}.{key}", result)


def _require_equal(obj: dict[str, Any], key: str, expected: Any, path: str, result: ValidationResult) -> None:
    value = obj.get(key)
    if value != expected:
        result.add(f"{path}.{key}", "must match required value")


def _require_number_equal(obj: dict[str, Any], key: str, expected: float, path: str, result: ValidationResult) -> None:
    value = obj.get(key)
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        result.add(f"{path}.{key}", f"must be numeric {expected!r}")
        return
    try:
        numeric_value = float(value)
    except OverflowError:
        result.add(f"{path}.{key}", f"must be numeric {expected!r}")
        return
    if not math.isfinite(numeric_value) or numeric_value != expected:
        result.add(f"{path}.{key}", f"must be numeric {expected!r}")


def _require_exact_keys(obj: dict[str, Any], expected: set[str], path: str, result: ValidationResult) -> None:
    actual = set(obj)
    if actual != expected:
        missing = _safe_sorted_keys(expected - actual)
        extra = _redacted_extra_summary(actual - expected)
        result.add(path, f"must contain exactly expected fields; missing={missing} extra={extra}")


def _require_exact_keys_with_optional(obj: dict[str, Any], required: set[str], optional: set[str], path: str, result: ValidationResult) -> None:
    actual = set(obj)
    allowed = required | optional
    if not required.issubset(actual) or not actual.issubset(allowed):
        missing = _safe_sorted_keys(required - actual)
        extra = _redacted_extra_summary(actual - allowed)
        result.add(path, f"must contain exactly expected fields; missing={missing} extra={extra}")


def _safe_path_segment(key: str) -> str:
    if key in SAFE_ERROR_KEY_NAMES:
        return key
    return "<redacted-key>"


def _safe_sorted_keys(keys: set[Any]) -> list[str]:
    return sorted(_safe_path_segment(key) if isinstance(key, str) else "<non-string-key>" for key in keys)


def _redacted_extra_summary(keys: set[Any]) -> list[str]:
    return [] if not keys else [f"<{len(keys)} redacted extra key(s)>"]


def _require_bool(obj: dict[str, Any], key: str, expected: bool, path: str, result: ValidationResult) -> None:
    if obj.get(key) is not expected:
        result.add(f"{path}.{key}", f"must be {expected}")


def _require_text(obj: dict[str, Any], key: str, path: str, result: ValidationResult, *, pattern: re.Pattern[str] | None = None) -> str:
    value = obj.get(key)
    if not isinstance(value, str) or not value:
        result.add(f"{path}.{key}", "must be a non-empty string")
        return ""
    if pattern and not pattern.fullmatch(value):
        result.add(f"{path}.{key}", "has invalid shape")
    return value


def _require_int(obj: dict[str, Any], key: str, path: str, result: ValidationResult, *, minimum: int | None = None) -> int | None:
    value = obj.get(key)
    if not isinstance(value, int) or isinstance(value, bool):
        result.add(f"{path}.{key}", "must be an integer")
        return None
    if minimum is not None and value < minimum:
        result.add(f"{path}.{key}", f"must be >= {minimum}")
    return value


def _require_ascii_digest_strings(value: Any, path: str, result: ValidationResult) -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            child_path = f"{path}.{_safe_path_segment(key) if isinstance(key, str) else '<non-string-key>'}"
            _require_ascii_digest_strings(child, child_path, result)
    elif isinstance(value, list):
        for index, child in enumerate(value):
            _require_ascii_digest_strings(child, f"{path}[{index}]", result)
    elif isinstance(value, str) and any(ord(ch) > 0x7F for ch in value):
        result.add(path, "must be ASCII before route digest validation")


def _parse_iso_z(value: str, path: str, result: ValidationResult) -> _dt.datetime | None:
    if not ISO_Z_RE.fullmatch(value):
        result.add(path, "has invalid timestamp shape")
        return None
    try:
        return _dt.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=_dt.UTC)
    except ValueError:
        result.add(path, "has invalid timestamp value")
        return None


def _require_iso_z(obj: dict[str, Any], key: str, path: str, result: ValidationResult) -> _dt.datetime | None:
    value = _require_text(obj, key, path, result, pattern=ISO_Z_RE)
    if not value:
        return None
    return _parse_iso_z(value, f"{path}.{key}", result)


def _require_order(before: _dt.datetime | None, after: _dt.datetime | None, before_path: str, after_path: str, result: ValidationResult) -> None:
    if before is not None and after is not None and before > after:
        result.add(after_path, f"must be >= {before_path}")


def _require_not_stale(value: _dt.datetime | None, path: str, result: ValidationResult) -> None:
    if value is not None and value < MIN_EVIDENCE_CAPTURED_AT:
        result.add(path, "must be on or after 2026-09-14 for this MVP acceptance gate")


def _require_near_now(value: _dt.datetime | None, path: str, result: ValidationResult, now: _dt.datetime) -> None:
    if value is None:
        return
    if value > now + _dt.timedelta(seconds=MAX_FUTURE_SKEW_SECONDS):
        result.add(path, "must not be in the future for this MVP acceptance gate")
    if now - value > _dt.timedelta(seconds=MAX_EVIDENCE_AGE_SECONDS):
        result.add(path, "must be recent for this MVP acceptance gate")


def _datetime_from_unix_ms(value: int | None, path: str, result: ValidationResult) -> _dt.datetime | None:
    if value is None:
        return None
    try:
        return _dt.datetime.fromtimestamp(value / 1000, tz=_dt.UTC)
    except (OverflowError, OSError, ValueError):
        result.add(path, "is outside supported timestamp range")
        return None


def _round_half_even(numerator: int, denominator: int) -> int:
    if denominator <= 0:
        return 0
    q, r = divmod(abs(numerator), denominator)
    twice = r * 2
    rounded = q
    if twice > denominator or (twice == denominator and q % 2 == 1):
        rounded += 1
    return rounded if numerator >= 0 else -rounded


def _key_forms(key: str) -> tuple[str, str, str]:
    lowered = key.lower()
    normalized = re.sub(r"[^a-z0-9]+", "_", lowered).strip("_")
    compact = re.sub(r"[^a-z0-9]+", "", lowered)
    return lowered, normalized, compact


def _jcs_sha256(obj: Any) -> str:
    canonical = json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def _is_forbidden_secret_key(key: str, path: str) -> bool:
    lowered, normalized, compact = _key_forms(key)
    full_path = f"{path}.{key}"
    if full_path in ALLOWED_SECRET_KEY_PATHS:
        return False
    if normalized in {"credentials_redacted", "secrets_redacted", "tokens_redacted", "route_provider_id"}:
        return False
    forms = (lowered, normalized, compact)
    payout_parts = PAYOUT_SECRET_KEY_PARTS + tuple(part.replace("_", "") for part in PAYOUT_SECRET_KEY_PARTS)
    secret_parts = SECRET_KEY_PARTS + tuple(part.replace("_", "") for part in SECRET_KEY_PARTS)
    if any(part in form for form in forms for part in payout_parts):
        return True
    if any(part in form for form in forms for part in secret_parts):
        return True
    return normalized == "token" or compact == "token"




def _require_hex64_match(obj: dict[str, Any], key: str, expected: str, path: str, result: ValidationResult) -> None:
    value = _require_text(obj, key, path, result, pattern=HEX64_RE)
    if value and value != expected:
        result.add(f"{path}.{key}", f"must be {expected!r}")


def _require_positive_number(obj: dict[str, Any], key: str, path: str, result: ValidationResult) -> float | None:
    value = obj.get(key)
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        result.add(f"{path}.{key}", "must be a number")
        return None
    if not math.isfinite(float(value)):
        result.add(f"{path}.{key}", "must be finite")
        return None
    if value <= 0:
        result.add(f"{path}.{key}", "must be > 0")
    return float(value)


def _require_credit_int(obj: dict[str, Any], key: str, expected: int, path: str, result: ValidationResult) -> None:
    value = _require_int(obj, key, path, result, minimum=1)
    if value is not None and value != expected:
        result.add(f"{path}.{key}", f"must equal {expected} from coordinator half-even integer rate-card math")


def _require_usage(obj: dict[str, Any], path: str, result: ValidationResult) -> dict[str, int | None]:
    expected_keys = {
        "billable_input_tokens",
        "billable_output_tokens",
        "delivered_output_bytes",
        "observed_input_tokens",
        "observed_output_tokens",
    }
    actual_keys = set(obj)
    if actual_keys != expected_keys:
        missing = _safe_sorted_keys(expected_keys - actual_keys)
        extra = _redacted_extra_summary(actual_keys - expected_keys)
        result.add(path, f"must contain exactly SPEC-015 v0.4 usage fields; missing={missing} extra={extra}")
    usage: dict[str, int | None] = {}
    for key in sorted(expected_keys):
        usage[key] = _require_int(obj, key, path, result, minimum=0)
    output_bytes = usage.get("delivered_output_bytes")
    observed_output = usage.get("observed_output_tokens")
    if output_bytes == 0 and observed_output and observed_output > 0:
        result.add(f"{path}.delivered_output_bytes", "must be positive when observed_output_tokens is positive")
    return usage


def _usage_matches(left: dict[str, Any], right: dict[str, Any]) -> bool:
    return all(left.get(key) == right.get(key) for key in (
        "billable_input_tokens", "billable_output_tokens", "delivered_output_bytes",
        "observed_input_tokens", "observed_output_tokens",
    ))


def _is_truthy_claim(value: Any) -> bool:
    if value is True:
        return True
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return value != 0
    if isinstance(value, str):
        return value.strip().lower() in TRUTHY_STATUS_VALUES
    return False


def _is_disqualifying_acceptance_claim(key: str, value: Any) -> bool:
    _, normalized, compact = _key_forms(key)
    if normalized == "selected_tests" and isinstance(value, int) and not isinstance(value, bool) and value == 0:
        return True
    if normalized in DISQUALIFYING_ACCEPTANCE_KEYS or compact in {item.replace("_", "") for item in DISQUALIFYING_ACCEPTANCE_KEYS}:
        if value is False or value is None:
            return False
        if isinstance(value, (int, float)) and not isinstance(value, bool) and value == 0:
            return False
        if isinstance(value, str) and value.strip().lower() in {"", "false", "no", "0"}:
            return False
        return True
    if isinstance(value, str):
        _, normalized_value, compact_value = _key_forms(value.strip())
        disqualifying_compact = {item.replace("_", "") for item in DISQUALIFYING_ACCEPTANCE_VALUES}
        if normalized_value in DISQUALIFYING_ACCEPTANCE_VALUES or compact_value in disqualifying_compact:
            return True
    return False


def _is_activation_claim_key(key: str) -> bool:
    _, normalized, compact = _key_forms(key)
    if any(safe in normalized for safe in ("disabled", "untouched", "unchanged", "redacted")) or normalized.endswith("_source"):
        return False
    if normalized in {"production", "economic_status", "settlement_status", "acceptance_status"}:
        return True
    if normalized in FORBIDDEN_TRUE_FLAG_KEYS or compact in {flag.replace("_", "") for flag in FORBIDDEN_TRUE_FLAG_KEYS}:
        return True
    fragments = (
        "production_activation", "production_activated", "production_enforcement",
        "production_rewards", "production_settlement", "economic_activation",
        "reward_payout", "rewards_status", "release_publish", "production_ready", "production_qualif",
    )
    compact_fragments = tuple(fragment.replace("_", "") for fragment in fragments)
    return any(fragment in normalized for fragment in fragments) or any(fragment in compact for fragment in compact_fragments)


def _require_artifact_binding(obj: dict[str, Any], path: str, result: ValidationResult, *, feed_sha256: str, signer_key_id: str, candidate_catalog_sha256: str) -> None:
    _require_exact_keys(obj, {
        "artifact_feed_sha256", "artifact_id", "artifact_hash", "artifact_hash_algorithm",
        "artifact_feed_signer_key_id", "candidate_catalog_body_digest",
    }, path, result)
    _require_equal(obj, "artifact_feed_sha256", feed_sha256, path, result)
    _require_equal(obj, "artifact_id", ARTIFACT_ID, path, result)
    _require_equal(obj, "artifact_hash", ARTIFACT_HASH, path, result)
    _require_equal(obj, "artifact_hash_algorithm", ARTIFACT_HASH_ALGORITHM, path, result)
    _require_equal(obj, "artifact_feed_signer_key_id", signer_key_id, path, result)
    _require_equal(obj, "candidate_catalog_body_digest", candidate_catalog_sha256, path, result)


def _expected_credits(usage: dict[str, Any], cached_input_tokens: int, result: ValidationResult, path: str) -> tuple[int, int]:
    billable_input = usage.get("billable_input_tokens")
    billable_output = usage.get("billable_output_tokens")
    if not isinstance(billable_input, int) or not isinstance(billable_output, int):
        return 0, 0
    if cached_input_tokens > billable_input:
        result.add(f"{path}.cached_billable_input_tokens", "must be <= billable_input_tokens")
    uncached_input = max(billable_input - cached_input_tokens, 0)
    raw = (
        uncached_input * PROMPT_RATE
        + cached_input_tokens * CACHED_PROMPT_RATE
        + billable_output * COMPLETION_RATE
    )
    credits = _round_half_even(raw * GLOBAL_MULTIPLIER_PPM, 1_000_000 * 1_000_000)
    provider_share = _round_half_even(credits * PROVIDER_SHARE_BPS, 10_000)
    return credits, provider_share

def _check_string_forbidden(value: str, path: str, key_hint: str, result: ValidationResult) -> None:
    text_variants = (value, re.sub(r"[_-]+", " ", value))
    for pattern in FORBIDDEN_VALUE_PATTERNS:
        if any(pattern.search(candidate) for candidate in text_variants):
            result.add(path, "contains unredacted endpoint, path, or credential-shaped value")
            break
    for pattern in FORBIDDEN_TEXT_PATTERNS:
        if any(pattern.search(candidate) for candidate in text_variants):
            result.add(path, "contains disallowed production, payout, fixture, historical, skipped, or operator-claimed acceptance text")
            break
    if value != "GET /v1/status" and BARE_ENDPOINT_RE.search(value):
        result.add(path, "contains unredacted endpoint, path, or credential-shaped value")
    if value != "GET /v1/status" and SENSITIVE_SINGLE_LABEL_PATH_SUBSTRING_RE.search(value):
        result.add(path, "contains unredacted endpoint, path, or credential-shaped value")
    _, normalized_key, _ = _key_forms(key_hint)
    explicit_endpoint_key = any(part in normalized_key for part in ("url", "endpoint", "host"))
    coordinator_gateway_key = "coordinator" in normalized_key or "gateway" in normalized_key
    if value != "GET /v1/status":
        if explicit_endpoint_key and ("/" in value or DOMAIN_ONLY_RE.fullmatch(value) or SINGLE_LABEL_PATH_SUBSTRING_RE.search(value)):
            result.add(path, "contains unredacted endpoint, path, or credential-shaped value")
        elif coordinator_gateway_key and (SINGLE_LABEL_PATH_RE.fullmatch(value) or SINGLE_LABEL_PATH_SUBSTRING_RE.search(value) or DOMAIN_ONLY_RE.fullmatch(value)):
            result.add(path, "contains unredacted endpoint, path, or credential-shaped value")


def _walk_forbidden(value: Any, path: str, result: ValidationResult, *, key_hint: str = "") -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            if not isinstance(key, str):
                result.add(path, "object keys must be strings")
                continue
            child_path = f"{path}.{_safe_path_segment(key)}"
            if _is_forbidden_secret_key(key, path):
                result.add(child_path, "forbidden secret-bearing key")
            if _is_activation_claim_key(key) and _is_truthy_claim(child):
                result.add(child_path, "must not claim production economic activation, rewards, payout, release, or enforcement")
            if _is_disqualifying_acceptance_claim(key, child):
                result.add(child_path, "must not claim skipped, timed-out, zero-selected, fixture-only, historical, or operator-claimed physical acceptance")
            _walk_forbidden(child, child_path, result, key_hint=key)
    elif isinstance(value, list):
        for index, child in enumerate(value):
            _walk_forbidden(child, f"{path}[{index}]", result, key_hint=key_hint)
    elif isinstance(value, str):
        _check_string_forbidden(value, path, key_hint, result)
    elif isinstance(value, (int, float)) and not isinstance(value, bool):
        if isinstance(value, float) and not math.isfinite(value):
            result.add(path, "must be finite")


def validate_build1_narrow_mvp_evidence(payload: dict[str, Any], *, now: _dt.datetime | None = None) -> ValidationResult:
    if now is None:
        now = _dt.datetime.now(_dt.UTC)
    result = ValidationResult()
    _walk_forbidden(payload, "$", result)

    top_level_keys = {
        "schema_version", "build_id", "validation_scope", "evidence_class", "captured_at",
        "repository", "scope", "capture", "profile", "environment", "staging_config",
        "hardware", "runtime", "artifact_feed", "preparation", "provider", "admission",
        "request", "route_snapshot", "settlement", "settlement_verdict", "production_blockers",
    }
    if set(payload) != top_level_keys:
        missing = _safe_sorted_keys(top_level_keys - set(payload))
        extra = _redacted_extra_summary(set(payload) - top_level_keys)
        result.add("$", f"must contain exactly Build 1 narrow MVP evidence fields; missing={missing} extra={extra}")

    _require_equal(payload, "schema_version", SCHEMA_VERSION, "$", result)
    _require_equal(payload, "build_id", BUILD_ID, "$", result)
    _require_equal(payload, "validation_scope", "schema_valid_structural_only", "$", result)
    _require_equal(payload, "evidence_class", "physical_staging", "$", result)
    captured_at = _require_iso_z(payload, "captured_at", "$", result)
    _require_not_stale(captured_at, "$.captured_at", result)
    _require_near_now(captured_at, "$.captured_at", result, now)

    repo = _get_object(payload, "repository", "$", result)
    _require_exact_keys(repo, {"name", "commit", "branch"}, "$.repository", result)
    _require_equal(repo, "name", "Augustas11/macprovider", "$.repository", result)
    _require_text(repo, "commit", "$.repository", result, pattern=HEX40_RE)
    _require_text(repo, "branch", "$.repository", result, pattern=IDENTIFIER_RE)

    scope = _get_object(payload, "scope", "$", result)
    _require_exact_keys(scope, {
        "production_activation_enabled", "production_enforcement_changed", "production_rewards_enabled",
        "payout_jobs_enabled", "payout_execution_enabled", "release_published",
    }, "$.scope", result)
    for key in (
        "production_activation_enabled", "production_enforcement_changed", "production_rewards_enabled",
        "payout_jobs_enabled", "payout_execution_enabled", "release_published",
    ):
        _require_bool(scope, key, False, "$.scope", result)

    capture = _get_object(payload, "capture", "$", result)
    _require_exact_keys(capture, {
        "command", "started_at", "completed_at", "binary_version", "binary_sha256",
        "redaction_passed", "skipped", "operator_notes", "source_captures",
    }, "$.capture", result)
    _require_equal(capture, "command", "scripts/collect-build1-narrow-mvp-evidence --redacted", "$.capture", result)
    capture_started_at = _require_iso_z(capture, "started_at", "$.capture", result)
    capture_completed_at = _require_iso_z(capture, "completed_at", "$.capture", result)
    _require_not_stale(capture_started_at, "$.capture.started_at", result)
    _require_not_stale(capture_completed_at, "$.capture.completed_at", result)
    _require_order(capture_started_at, capture_completed_at, "$.capture.started_at", "$.capture.completed_at", result)
    _require_order(capture_completed_at, captured_at, "$.capture.completed_at", "$.captured_at", result)
    _require_bool(capture, "redaction_passed", True, "$.capture", result)
    _require_bool(capture, "skipped", False, "$.capture", result)
    _require_equal(capture, "operator_notes", "redacted physical staging run", "$.capture", result)
    source_captures = _get_object(capture, "source_captures", "$.capture", result)
    _require_exact_keys(source_captures, {
        "review_required", "manifest_sha256", "physical_run_log_sha256", "request_transcript_sha256",
        "status_before_sha256", "status_after_sha256", "provider_receipt_audit_sha256",
        "coordinator_route_snapshot_sha256", "coordinator_settlement_verdict_sha256", "redaction_report_sha256",
    }, "$.capture.source_captures", result)
    _require_equal(source_captures, "review_required", True, "$.capture.source_captures", result)
    for key in (
        "manifest_sha256", "physical_run_log_sha256", "request_transcript_sha256", "status_before_sha256",
        "status_after_sha256", "provider_receipt_audit_sha256", "coordinator_route_snapshot_sha256",
        "coordinator_settlement_verdict_sha256", "redaction_report_sha256",
    ):
        _require_text(source_captures, key, "$.capture.source_captures", result, pattern=HEX64_RE)

    profile = _get_object(payload, "profile", "$", result)
    _require_exact_keys(profile, {
        "catalog_key", "model_id", "runtime_source", "artifact_id", "model_revision",
        "artifact_hash_algorithm", "artifact_hash", "rate",
    }, "$.profile", result)
    _require_equal(profile, "catalog_key", CATALOG_KEY, "$.profile", result)
    _require_equal(profile, "model_id", MODEL_ID, "$.profile", result)
    _require_equal(profile, "runtime_source", RUNTIME_SOURCE, "$.profile", result)
    _require_equal(profile, "artifact_id", ARTIFACT_ID, "$.profile", result)
    _require_equal(profile, "model_revision", MODEL_REVISION, "$.profile", result)
    _require_equal(profile, "artifact_hash_algorithm", ARTIFACT_HASH_ALGORITHM, "$.profile", result)
    _require_equal(profile, "artifact_hash", ARTIFACT_HASH, "$.profile", result)

    rate = _get_object(profile, "rate", "$.profile", result)
    _require_exact_keys(rate, {
        "rate_card_key", "prompt_rate_per_mtok", "prompt_cache_hit_rate_per_mtok",
        "completion_rate_per_mtok", "provider_share_bps", "global_multiplier_ppm",
        "usd_per_million_credits",
    }, "$.profile.rate", result)
    _require_equal(rate, "rate_card_key", RATE_CARD_KEY, "$.profile.rate", result)
    _require_equal(rate, "prompt_rate_per_mtok", PROMPT_RATE, "$.profile.rate", result)
    _require_equal(rate, "prompt_cache_hit_rate_per_mtok", CACHED_PROMPT_RATE, "$.profile.rate", result)
    _require_equal(rate, "completion_rate_per_mtok", COMPLETION_RATE, "$.profile.rate", result)
    _require_equal(rate, "provider_share_bps", PROVIDER_SHARE_BPS, "$.profile.rate", result)
    _require_equal(rate, "global_multiplier_ppm", GLOBAL_MULTIPLIER_PPM, "$.profile.rate", result)
    _require_number_equal(rate, "usd_per_million_credits", USD_PER_MILLION_CREDITS, "$.profile.rate", result)

    environment = _get_object(payload, "environment", "$", result)
    _require_exact_keys(environment, {
        "class", "verified_model_settlement_mode", "staging_isolated",
        "production_endpoints_untouched", "credentials_redacted", "secrets_redacted",
    }, "$.environment", result)
    _require_equal(environment, "class", "staging", "$.environment", result)
    _require_equal(environment, "verified_model_settlement_mode", "enforce", "$.environment", result)
    for key in ("staging_isolated", "production_endpoints_untouched", "credentials_redacted", "secrets_redacted"):
        _require_bool(environment, key, True, "$.environment", result)

    staging_config = _get_object(payload, "staging_config", "$", result)
    _require_exact_keys(staging_config, {
        "environment_id", "verified_model_settlement_mode", "coordinator_url_redacted", "gateway_url_redacted",
        "rewards_disabled", "operator_payment_jobs_disabled", "operator_payment_execution_disabled",
        "production_enforcement_unchanged", "policy_version", "config_source_kind", "config_digest",
        "deploy_event_id", "captured_at", "settlement_mode_source", "rewards_disabled_source",
        "operator_payment_jobs_disabled_source", "operator_payment_execution_disabled_source",
        "production_enforcement_source", "rewards_disabled_evidence_digest",
        "operator_payment_jobs_disabled_evidence_digest", "operator_payment_execution_disabled_evidence_digest",
        "production_enforcement_evidence_digest",
    }, "$.staging_config", result)
    staging_environment_id = _require_text(staging_config, "environment_id", "$.staging_config", result, pattern=REQUEST_ID_RE)
    _require_equal(staging_config, "verified_model_settlement_mode", "enforce", "$.staging_config", result)
    for key in (
        "coordinator_url_redacted", "gateway_url_redacted", "rewards_disabled", "operator_payment_jobs_disabled",
        "operator_payment_execution_disabled", "production_enforcement_unchanged",
    ):
        _require_bool(staging_config, key, True, "$.staging_config", result)
    _require_text(staging_config, "policy_version", "$.staging_config", result, pattern=IDENTIFIER_RE)
    if staging_config.get("config_source_kind") not in {"deploy_config_snapshot", "staging_config_snapshot"}:
        result.add("$.staging_config.config_source_kind", "must identify a config snapshot source")
    _require_text(staging_config, "config_digest", "$.staging_config", result, pattern=HEX64_RE)
    _require_text(staging_config, "deploy_event_id", "$.staging_config", result, pattern=REQUEST_ID_RE)
    staging_config_captured_at = _require_iso_z(staging_config, "captured_at", "$.staging_config", result)
    _require_not_stale(staging_config_captured_at, "$.staging_config.captured_at", result)
    _require_order(staging_config_captured_at, capture_completed_at, "$.staging_config.captured_at", "$.capture.completed_at", result)
    for key, expected in STAGING_CONFIG_SOURCE_VALUES.items():
        _require_equal(staging_config, key, expected, "$.staging_config", result)
    for key in (
        "rewards_disabled_evidence_digest", "operator_payment_jobs_disabled_evidence_digest",
        "operator_payment_execution_disabled_evidence_digest", "production_enforcement_evidence_digest",
    ):
        _require_text(staging_config, key, "$.staging_config", result, pattern=HEX64_RE)

    hardware = _get_object(payload, "hardware", "$", result)
    _require_exact_keys(hardware, {
        "context_id", "chip", "ram_gb", "free_disk_bytes", "os_version", "binary_version", "binary_sha256",
    }, "$.hardware", result)
    hardware_context_id = _require_text(hardware, "context_id", "$.hardware", result, pattern=REQUEST_ID_RE)
    chip = _require_text(hardware, "chip", "$.hardware", result, pattern=APPLE_SILICON_CHIP_RE)
    if chip and not APPLE_SILICON_CHIP_RE.fullmatch(chip):
        result.add("$.hardware.chip", "must identify a supported Apple Silicon chip")
    _require_int(hardware, "ram_gb", "$.hardware", result, minimum=8)
    _require_int(hardware, "free_disk_bytes", "$.hardware", result, minimum=1)
    _require_text(hardware, "os_version", "$.hardware", result, pattern=MACOS_VERSION_RE)

    runtime = _get_object(payload, "runtime", "$", result)
    _require_exact_keys(runtime, {"source", "mlx_version", "context_profile", "max_concurrency", "hardware_context_id"}, "$.runtime", result)
    _require_equal(runtime, "source", RUNTIME_SOURCE, "$.runtime", result)
    _require_text(runtime, "mlx_version", "$.runtime", result, pattern=MLX_VERSION_RE)
    _require_equal(runtime, "context_profile", "batch-1-context-4096", "$.runtime", result)
    _require_int(runtime, "max_concurrency", "$.runtime", result, minimum=1)
    _require_equal(runtime, "hardware_context_id", hardware_context_id, "$.runtime", result)

    feed = _get_object(payload, "artifact_feed", "$", result)
    _require_exact_keys(feed, {
        "freshness", "signature_verified", "release_bound", "measured_size", "size_bytes",
        "feed_sha256", "candidate_catalog_sha256", "release_id", "artifact_feed_signer_key_id",
        "verification_status", "primary_artifact_id", "artifact_hash_algorithm", "artifact_hash",
        "route_binding",
    }, "$.artifact_feed", result)
    _require_equal(feed, "freshness", "fresh", "$.artifact_feed", result)
    _require_bool(feed, "signature_verified", True, "$.artifact_feed", result)
    _require_bool(feed, "release_bound", True, "$.artifact_feed", result)
    _require_bool(feed, "measured_size", True, "$.artifact_feed", result)
    size_bytes = _require_int(feed, "size_bytes", "$.artifact_feed", result, minimum=1)
    feed_sha256 = _require_text(feed, "feed_sha256", "$.artifact_feed", result, pattern=HEX64_RE)
    candidate_catalog_sha256 = _require_text(feed, "candidate_catalog_sha256", "$.artifact_feed", result, pattern=HEX64_RE)
    _require_text(feed, "release_id", "$.artifact_feed", result, pattern=IDENTIFIER_RE)
    signer_key_id = _require_text(feed, "artifact_feed_signer_key_id", "$.artifact_feed", result, pattern=IDENTIFIER_RE)
    _require_equal(feed, "artifact_feed_signer_key_id", TRUSTED_ARTIFACT_FEED_SIGNER_KEY_ID, "$.artifact_feed", result)
    _require_equal(feed, "verification_status", "verified", "$.artifact_feed", result)
    _require_equal(feed, "primary_artifact_id", ARTIFACT_ID, "$.artifact_feed", result)
    _require_equal(feed, "artifact_hash", ARTIFACT_HASH, "$.artifact_feed", result)
    _require_equal(feed, "artifact_hash_algorithm", ARTIFACT_HASH_ALGORITHM, "$.artifact_feed", result)

    route_binding = _get_object(feed, "route_binding", "$.artifact_feed", result)
    _require_artifact_binding(
        route_binding,
        "$.artifact_feed.route_binding",
        result,
        feed_sha256=feed_sha256,
        signer_key_id=signer_key_id,
        candidate_catalog_sha256=candidate_catalog_sha256,
    )

    preparation = _get_object(payload, "preparation", "$", result)
    _require_exact_keys_with_optional(preparation, {
        "status", "artifact_hash", "size_bytes", "available_disk_bytes", "staged_bytes",
        "snapshot_manifest_verified", "cancellation_preserves_active_model", "recovery_safe",
        "adopted_model_id", "inventory_digest",
    }, {"weights_manifest_sha256"}, "$.preparation", result)
    _require_equal(preparation, "status", "adopted", "$.preparation", result)
    _require_equal(preparation, "artifact_hash", ARTIFACT_HASH, "$.preparation", result)
    if size_bytes is not None:
        _require_equal(preparation, "size_bytes", size_bytes, "$.preparation", result)
    _require_int(preparation, "available_disk_bytes", "$.preparation", result, minimum=1)
    staged_bytes = _require_int(preparation, "staged_bytes", "$.preparation", result, minimum=1)
    if staged_bytes is not None and size_bytes is not None and staged_bytes != size_bytes:
        result.add("$.preparation.staged_bytes", "must equal artifact_feed.size_bytes")
    _require_bool(preparation, "snapshot_manifest_verified", True, "$.preparation", result)
    _require_bool(preparation, "cancellation_preserves_active_model", True, "$.preparation", result)
    _require_bool(preparation, "recovery_safe", True, "$.preparation", result)
    _require_equal(preparation, "adopted_model_id", MODEL_ID, "$.preparation", result)
    _require_text(preparation, "inventory_digest", "$.preparation", result, pattern=HEX64_RE)
    prepared_weights = preparation.get("weights_manifest_sha256")
    if prepared_weights is not None:
        if not isinstance(prepared_weights, str) or not HEX64_RE.fullmatch(prepared_weights):
            result.add("$.preparation.weights_manifest_sha256", "must be a lowercase 64-hex string when present")
            prepared_weights = None

    provider = _get_object(payload, "provider", "$", result)
    _require_exact_keys(provider, {
        "kind", "fake_provider", "provider_id", "binary_sha256", "binary_version", "pid",
        "hardware_context_id", "runtime_source", "receipt_key_available", "receipt_audit_cursor_before",
        "status_before", "status_after", "correlation",
    }, "$.provider", result)
    _require_equal(provider, "kind", "physical_mlx_cli", "$.provider", result)
    _require_bool(provider, "fake_provider", False, "$.provider", result)
    provider_id = _require_text(provider, "provider_id", "$.provider", result, pattern=PROVIDER_ID_RE)
    provider_binary_sha256 = _require_text(provider, "binary_sha256", "$.provider", result, pattern=HEX64_RE)
    binary_version = _require_text(provider, "binary_version", "$.provider", result, pattern=BINARY_VERSION_RE)
    _require_int(provider, "pid", "$.provider", result, minimum=1)
    _require_equal(provider, "hardware_context_id", hardware_context_id, "$.provider", result)
    _require_equal(provider, "runtime_source", RUNTIME_SOURCE, "$.provider", result)
    _require_bool(provider, "receipt_key_available", True, "$.provider", result)
    _require_text(provider, "receipt_audit_cursor_before", "$.provider", result, pattern=CURSOR_RE)

    if provider_binary_sha256:
        _require_equal(capture, "binary_sha256", provider_binary_sha256, "$.capture", result)
        _require_equal(hardware, "binary_sha256", provider_binary_sha256, "$.hardware", result)
    if binary_version:
        _require_equal(capture, "binary_version", binary_version, "$.capture", result)
        _require_equal(hardware, "binary_version", binary_version, "$.hardware", result)

    status_before = _get_object(provider, "status_before", "$.provider", result)
    status_after = _get_object(provider, "status_after", "$.provider", result)
    for label, status in (("status_before", status_before), ("status_after", status_after)):
        path = f"$.provider.{label}"
        _require_exact_keys(status, {
            "endpoint", "status", "model_loaded", "model", "model_hash", "model_hash_algorithm",
            "weights_manifest_sha256", "weights_manifest_algorithm",
        }, path, result)
        _require_equal(status, "endpoint", "GET /v1/status", path, result)
        if status.get("status") not in {"ready", "busy"}:
            result.add(f"{path}.status", "must be ready or busy")
        _require_bool(status, "model_loaded", True, path, result)
        _require_equal(status, "model", MODEL_ID, path, result)
        _require_equal(status, "model_hash", ARTIFACT_HASH, path, result)
        _require_equal(status, "model_hash_algorithm", ARTIFACT_HASH_ALGORITHM, path, result)
        weights = _require_text(status, "weights_manifest_sha256", path, result, pattern=HEX64_RE)
        _require_equal(status, "weights_manifest_algorithm", WEIGHTS_MANIFEST_ALGORITHM, path, result)
        if prepared_weights is not None and weights and weights != prepared_weights:
            result.add(f"{path}.weights_manifest_sha256", "must match preparation.weights_manifest_sha256")
    before_weights = status_before.get("weights_manifest_sha256")
    after_weights = status_after.get("weights_manifest_sha256")
    if isinstance(before_weights, str) and isinstance(after_weights, str) and before_weights != after_weights:
        result.add("$.provider.status_after.weights_manifest_sha256", "must equal status_before.weights_manifest_sha256")

    admission = _get_object(payload, "admission", "$", result)
    _require_exact_keys(admission, {
        "event_id", "source", "environment_id", "state", "provider_id", "model_id", "catalog_key",
        "artifact_hash", "receipt_key_available", "verified_model_settlement_mode", "rate_card_key",
        "model_admission_candidate_id", "model_admission_coordinator_event_id",
        "model_admission_served_model_ref", "model_admission_catalog_model_key",
        "model_admission_discovery_digest_sha256", "model_admission_evaluation_digest_sha256",
    }, "$.admission", result)
    admission_event_id = _require_text(admission, "event_id", "$.admission", result, pattern=REQUEST_ID_RE)
    _require_equal(admission, "source", "coordinator", "$.admission", result)
    _require_equal(admission, "environment_id", staging_environment_id, "$.admission", result)
    _require_equal(admission, "state", "settlement_capable", "$.admission", result)
    _require_equal(admission, "provider_id", provider_id, "$.admission", result)
    _require_equal(admission, "model_id", MODEL_ID, "$.admission", result)
    _require_equal(admission, "catalog_key", CATALOG_KEY, "$.admission", result)
    _require_equal(admission, "artifact_hash", ARTIFACT_HASH, "$.admission", result)
    _require_bool(admission, "receipt_key_available", True, "$.admission", result)
    _require_equal(admission, "verified_model_settlement_mode", "enforce", "$.admission", result)
    model_admission_candidate_id = _require_text(admission, "model_admission_candidate_id", "$.admission", result, pattern=REQUEST_ID_RE)
    model_admission_coordinator_event_id = _require_text(admission, "model_admission_coordinator_event_id", "$.admission", result, pattern=HEX64_RE)
    model_admission_served_model_ref = _require_text(admission, "model_admission_served_model_ref", "$.admission", result, pattern=REQUEST_ID_RE)
    _require_equal(admission, "model_admission_catalog_model_key", CATALOG_KEY, "$.admission", result)
    model_admission_discovery_digest = _require_text(admission, "model_admission_discovery_digest_sha256", "$.admission", result, pattern=HEX64_RE)
    model_admission_evaluation_digest = _require_text(admission, "model_admission_evaluation_digest_sha256", "$.admission", result, pattern=HEX64_RE)
    _require_equal(admission, "rate_card_key", RATE_CARD_KEY, "$.admission", result)

    request = _get_object(payload, "request", "$", result)
    _require_exact_keys(request, {
        "request_id", "model", "streaming", "response_status", "actual_mlx_inference",
        "route_provider_id", "admission_event_id", "usage",
    }, "$.request", result)
    request_id = _require_text(request, "request_id", "$.request", result, pattern=REQUEST_ID_RE)
    _require_equal(request, "model", MODEL_ID, "$.request", result)
    _require_bool(request, "streaming", False, "$.request", result)
    _require_equal(request, "response_status", 200, "$.request", result)
    _require_bool(request, "actual_mlx_inference", True, "$.request", result)
    route_provider_id = _require_text(request, "route_provider_id", "$.request", result, pattern=PROVIDER_ID_RE)
    _require_equal(request, "admission_event_id", admission_event_id, "$.request", result)
    request_usage = _get_object(request, "usage", "$.request", result)
    request_usage_values = _require_usage(request_usage, "$.request.usage", result)

    if provider_id and route_provider_id and provider_id != route_provider_id:
        result.add("$.request.route_provider_id", "must equal provider.provider_id")

    correlation = _get_object(provider, "correlation", "$.provider", result)
    _require_exact_keys(correlation, {
        "source", "event_type", "timestamp", "cursor", "served_count_supporting_only",
        "request_id", "provider_id", "model_id", "tokens_out", "ttft_ms", "unix_ts",
        "receipt_metadata_present",
    }, "$.provider.correlation", result)
    source = correlation.get("source")
    if source not in {"receipt_audit", "equivalent_provider_log"}:
        result.add("$.provider.correlation.source", "must be receipt_audit or equivalent_provider_log; served_count_only is not accepted")
    _require_equal(correlation, "event_type", "receipt_issued", "$.provider.correlation", result)
    correlation_timestamp = _require_iso_z(correlation, "timestamp", "$.provider.correlation", result)
    _require_not_stale(correlation_timestamp, "$.provider.correlation.timestamp", result)
    _require_order(capture_started_at, correlation_timestamp, "$.capture.started_at", "$.provider.correlation.timestamp", result)
    _require_order(correlation_timestamp, capture_completed_at, "$.provider.correlation.timestamp", "$.capture.completed_at", result)
    _require_text(correlation, "cursor", "$.provider.correlation", result, pattern=CURSOR_RE)
    _require_bool(correlation, "served_count_supporting_only", True, "$.provider.correlation", result)
    _require_equal(correlation, "request_id", request_id, "$.provider.correlation", result)
    _require_equal(correlation, "provider_id", provider_id, "$.provider.correlation", result)
    _require_equal(correlation, "model_id", MODEL_ID, "$.provider.correlation", result)
    _require_equal(correlation, "tokens_out", request_usage_values.get("billable_output_tokens"), "$.provider.correlation", result)
    _require_int(correlation, "ttft_ms", "$.provider.correlation", result, minimum=0)
    correlation_unix_ts = _require_int(correlation, "unix_ts", "$.provider.correlation", result, minimum=1)
    if correlation_timestamp is not None and correlation_unix_ts is not None and correlation_unix_ts != int(correlation_timestamp.timestamp()):
        result.add("$.provider.correlation.unix_ts", "must equal provider.correlation.timestamp seconds")
    _require_bool(correlation, "receipt_metadata_present", True, "$.provider.correlation", result)

    route_snapshot = _get_object(payload, "route_snapshot", "$", result)
    route_snapshot_keys = {"route_snapshot_digest", "route_snapshot_v1", "artifact_binding", "artifact_binding_digest", "artifact_binding_source"}
    if set(route_snapshot) != route_snapshot_keys:
        result.add("$.route_snapshot", f"must contain exactly {sorted(route_snapshot_keys)}")
    route_snapshot_digest = _require_text(route_snapshot, "route_snapshot_digest", "$.route_snapshot", result, pattern=HEX64_RE)
    artifact_binding_digest = _require_text(route_snapshot, "artifact_binding_digest", "$.route_snapshot", result, pattern=HEX64_RE)
    _require_equal(route_snapshot, "artifact_binding_source", "route_snapshot_referenced_immutable_record", "$.route_snapshot", result)
    route_artifact_binding = _get_object(route_snapshot, "artifact_binding", "$.route_snapshot", result)
    _require_artifact_binding(
        route_artifact_binding,
        "$.route_snapshot.artifact_binding",
        result,
        feed_sha256=feed_sha256,
        signer_key_id=signer_key_id,
        candidate_catalog_sha256=candidate_catalog_sha256,
    )
    if artifact_binding_digest and route_artifact_binding and artifact_binding_digest != _jcs_sha256(route_artifact_binding):
        result.add("$.route_snapshot.artifact_binding_digest", "must equal JCS SHA-256 of route_snapshot.artifact_binding")

    route_snapshot_v1 = _get_object(route_snapshot, "route_snapshot_v1", "$.route_snapshot", result)
    _require_ascii_digest_strings(route_snapshot_v1, "$.route_snapshot.route_snapshot_v1", result)
    route_snapshot_v1_keys = {
        "account_scope", "request_id", "attempt_n", "provider_id", "provider_session_id",
        "provider_generation_id", "paid_entrypoint", "provider_receipt_key_id",
        "provider_receipt_key_source", "model_id", "provider_reported_model_hash",
        "provider_reported_model_hash_algorithm", "expected_catalog_model_hash",
        "expected_catalog_model_hash_algorithm", "catalog_id", "catalog_body_digest",
        "catalog_signature_key_id", "catalog_signature_pubkey_fingerprint",
        "catalog_expires_at_unix_ms", "spec008_hash_status",
        "model_admission_candidate_id", "model_admission_coordinator_event_id",
        "model_admission_served_model_ref", "model_admission_catalog_model_key",
        "model_admission_discovery_digest_sha256", "model_admission_evaluation_digest_sha256",
        "artifact_feed_sha256", "artifact_id", "artifact_hash", "artifact_hash_algorithm",
        "artifact_feed_signer_key_id", "artifact_candidate_catalog_sha256",
        "route_snapshot_policy_version", "route_snapshot_mode", "route_decision_ts_unix_ms",
        "request_start_ts_unix_ms", "pending_deadline_seconds", "prompt_hash_basis", "prompt_hash",
    }
    if set(route_snapshot_v1) != route_snapshot_v1_keys:
        missing = _safe_sorted_keys(route_snapshot_v1_keys - set(route_snapshot_v1))
        extra = _redacted_extra_summary(set(route_snapshot_v1) - route_snapshot_v1_keys)
        result.add("$.route_snapshot.route_snapshot_v1", f"must contain exactly SPEC-015 route_snapshot_v1 fields; missing={missing} extra={extra}")
    provider_receipt_key_id = _require_text(route_snapshot_v1, "provider_receipt_key_id", "$.route_snapshot.route_snapshot_v1", result, pattern=RECEIPT_KEY_ID_RE)
    attempt_n = _require_int(route_snapshot_v1, "attempt_n", "$.route_snapshot.route_snapshot_v1", result, minimum=0)
    _require_text(route_snapshot_v1, "account_scope", "$.route_snapshot.route_snapshot_v1", result, pattern=REQUEST_ID_RE)
    _require_equal(route_snapshot_v1, "request_id", request_id, "$.route_snapshot.route_snapshot_v1", result)
    _require_equal(route_snapshot_v1, "provider_id", provider_id, "$.route_snapshot.route_snapshot_v1", result)
    for nullable_key in ("provider_session_id", "provider_generation_id"):
        nullable_value = route_snapshot_v1.get(nullable_key)
        if nullable_value is not None and (not isinstance(nullable_value, str) or not REQUEST_ID_RE.fullmatch(nullable_value)):
            result.add(f"$.route_snapshot.route_snapshot_v1.{nullable_key}", "must be a request-shaped identifier or null")
    _require_text(route_snapshot_v1, "paid_entrypoint", "$.route_snapshot.route_snapshot_v1", result, pattern=REQUEST_ID_RE)
    if route_snapshot_v1.get("provider_receipt_key_source") not in {"auth_session", "rotation_grace", "operator_pin"}:
        result.add("$.route_snapshot.route_snapshot_v1.provider_receipt_key_source", "has invalid value")
    _require_equal(route_snapshot_v1, "model_id", MODEL_ID, "$.route_snapshot.route_snapshot_v1", result)
    _require_equal(route_snapshot_v1, "provider_reported_model_hash", ARTIFACT_HASH, "$.route_snapshot.route_snapshot_v1", result)
    _require_equal(route_snapshot_v1, "provider_reported_model_hash_algorithm", ARTIFACT_HASH_ALGORITHM, "$.route_snapshot.route_snapshot_v1", result)
    _require_equal(route_snapshot_v1, "expected_catalog_model_hash", ARTIFACT_HASH, "$.route_snapshot.route_snapshot_v1", result)
    _require_equal(route_snapshot_v1, "expected_catalog_model_hash_algorithm", ARTIFACT_HASH_ALGORITHM, "$.route_snapshot.route_snapshot_v1", result)
    _require_equal(route_snapshot_v1, "catalog_id", CATALOG_KEY, "$.route_snapshot.route_snapshot_v1", result)
    _require_equal(route_snapshot_v1, "catalog_body_digest", candidate_catalog_sha256, "$.route_snapshot.route_snapshot_v1", result)
    _require_equal(route_snapshot_v1, "model_admission_candidate_id", model_admission_candidate_id, "$.route_snapshot.route_snapshot_v1", result)
    _require_equal(route_snapshot_v1, "model_admission_coordinator_event_id", model_admission_coordinator_event_id, "$.route_snapshot.route_snapshot_v1", result)
    _require_equal(route_snapshot_v1, "model_admission_served_model_ref", model_admission_served_model_ref, "$.route_snapshot.route_snapshot_v1", result)
    _require_equal(route_snapshot_v1, "model_admission_catalog_model_key", CATALOG_KEY, "$.route_snapshot.route_snapshot_v1", result)
    _require_equal(route_snapshot_v1, "model_admission_discovery_digest_sha256", model_admission_discovery_digest, "$.route_snapshot.route_snapshot_v1", result)
    _require_equal(route_snapshot_v1, "model_admission_evaluation_digest_sha256", model_admission_evaluation_digest, "$.route_snapshot.route_snapshot_v1", result)
    _require_equal(route_snapshot_v1, "artifact_feed_sha256", feed_sha256, "$.route_snapshot.route_snapshot_v1", result)
    _require_equal(route_snapshot_v1, "artifact_id", ARTIFACT_ID, "$.route_snapshot.route_snapshot_v1", result)
    _require_equal(route_snapshot_v1, "artifact_hash", ARTIFACT_HASH, "$.route_snapshot.route_snapshot_v1", result)
    _require_equal(route_snapshot_v1, "artifact_hash_algorithm", ARTIFACT_HASH_ALGORITHM, "$.route_snapshot.route_snapshot_v1", result)
    _require_equal(route_snapshot_v1, "artifact_feed_signer_key_id", signer_key_id, "$.route_snapshot.route_snapshot_v1", result)
    _require_equal(route_snapshot_v1, "artifact_candidate_catalog_sha256", candidate_catalog_sha256, "$.route_snapshot.route_snapshot_v1", result)
    _require_text(route_snapshot_v1, "catalog_signature_key_id", "$.route_snapshot.route_snapshot_v1", result, pattern=REQUEST_ID_RE)
    _require_text(route_snapshot_v1, "catalog_signature_pubkey_fingerprint", "$.route_snapshot.route_snapshot_v1", result, pattern=RECEIPT_KEY_ID_RE)
    catalog_expires_at_unix_ms = _require_int(route_snapshot_v1, "catalog_expires_at_unix_ms", "$.route_snapshot.route_snapshot_v1", result, minimum=1)
    _require_equal(route_snapshot_v1, "spec008_hash_status", "hash_verified", "$.route_snapshot.route_snapshot_v1", result)
    _require_equal(staging_config, "policy_version", ROUTE_SNAPSHOT_POLICY_VERSION, "$.staging_config", result)
    _require_equal(route_snapshot_v1, "route_snapshot_policy_version", ROUTE_SNAPSHOT_POLICY_VERSION, "$.route_snapshot.route_snapshot_v1", result)
    _require_equal(route_snapshot_v1, "route_snapshot_mode", "enforce", "$.route_snapshot.route_snapshot_v1", result)
    route_decision_ts_unix_ms = _require_int(route_snapshot_v1, "route_decision_ts_unix_ms", "$.route_snapshot.route_snapshot_v1", result, minimum=1)
    request_start_ts_unix_ms = _require_int(route_snapshot_v1, "request_start_ts_unix_ms", "$.route_snapshot.route_snapshot_v1", result, minimum=1)
    if catalog_expires_at_unix_ms is not None and route_decision_ts_unix_ms is not None and catalog_expires_at_unix_ms <= route_decision_ts_unix_ms:
        result.add("$.route_snapshot.route_snapshot_v1.catalog_expires_at_unix_ms", "must be after route_decision_ts_unix_ms")
    if route_decision_ts_unix_ms is not None and request_start_ts_unix_ms is not None and route_decision_ts_unix_ms > request_start_ts_unix_ms:
        result.add("$.route_snapshot.route_snapshot_v1.request_start_ts_unix_ms", "must be >= route_decision_ts_unix_ms")
    route_decision_at = _datetime_from_unix_ms(route_decision_ts_unix_ms, "$.route_snapshot.route_snapshot_v1.route_decision_ts_unix_ms", result)
    request_start_at = _datetime_from_unix_ms(request_start_ts_unix_ms, "$.route_snapshot.route_snapshot_v1.request_start_ts_unix_ms", result)
    catalog_expires_at = _datetime_from_unix_ms(catalog_expires_at_unix_ms, "$.route_snapshot.route_snapshot_v1.catalog_expires_at_unix_ms", result)
    _require_not_stale(route_decision_at, "$.route_snapshot.route_snapshot_v1.route_decision_ts_unix_ms", result)
    _require_not_stale(request_start_at, "$.route_snapshot.route_snapshot_v1.request_start_ts_unix_ms", result)
    _require_order(capture_started_at, route_decision_at, "$.capture.started_at", "$.route_snapshot.route_snapshot_v1.route_decision_ts_unix_ms", result)
    _require_order(route_decision_at, request_start_at, "$.route_snapshot.route_snapshot_v1.route_decision_ts_unix_ms", "$.route_snapshot.route_snapshot_v1.request_start_ts_unix_ms", result)
    _require_order(request_start_at, correlation_timestamp, "$.route_snapshot.route_snapshot_v1.request_start_ts_unix_ms", "$.provider.correlation.timestamp", result)
    _require_order(correlation_timestamp, capture_completed_at, "$.provider.correlation.timestamp", "$.capture.completed_at", result)
    _require_order(request_start_at, catalog_expires_at, "$.route_snapshot.route_snapshot_v1.request_start_ts_unix_ms", "$.route_snapshot.route_snapshot_v1.catalog_expires_at_unix_ms", result)
    _require_int(route_snapshot_v1, "pending_deadline_seconds", "$.route_snapshot.route_snapshot_v1", result, minimum=1)
    _require_text(route_snapshot_v1, "prompt_hash_basis", "$.route_snapshot.route_snapshot_v1", result, pattern=REQUEST_ID_RE)
    _require_text(route_snapshot_v1, "prompt_hash", "$.route_snapshot.route_snapshot_v1", result, pattern=HEX64_RE)
    if route_snapshot_digest and route_snapshot_v1 and route_snapshot_digest != _jcs_sha256(route_snapshot_v1):
        result.add("$.route_snapshot.route_snapshot_digest", "must equal JCS SHA-256 of route_snapshot_v1")

    settlement = _get_object(payload, "settlement", "$", result)
    _require_exact_keys(settlement, {
        "verified", "request_id", "provider_id", "model_id", "catalog_key", "artifact_hash",
        "hardware_context_id", "route_snapshot_digest", "attempt_n", "usage",
        "cached_billable_input_tokens", "credits", "provider_share_credits", "rate",
    }, "$.settlement", result)
    _require_bool(settlement, "verified", True, "$.settlement", result)
    _require_equal(settlement, "request_id", request_id, "$.settlement", result)
    _require_equal(settlement, "provider_id", provider_id, "$.settlement", result)
    _require_equal(settlement, "model_id", MODEL_ID, "$.settlement", result)
    _require_equal(settlement, "catalog_key", CATALOG_KEY, "$.settlement", result)
    _require_equal(settlement, "artifact_hash", ARTIFACT_HASH, "$.settlement", result)
    _require_equal(settlement, "hardware_context_id", hardware_context_id, "$.settlement", result)
    _require_equal(settlement, "route_snapshot_digest", route_snapshot_digest, "$.settlement", result)
    settlement_attempt_n = _require_int(settlement, "attempt_n", "$.settlement", result, minimum=0)
    if attempt_n is not None and settlement_attempt_n is not None and settlement_attempt_n != attempt_n:
        result.add("$.settlement.attempt_n", "must equal route_snapshot.route_snapshot_v1.attempt_n")
    settlement_usage = _get_object(settlement, "usage", "$.settlement", result)
    _require_usage(settlement_usage, "$.settlement.usage", result)
    if not _usage_matches(request_usage, settlement_usage):
        result.add("$.settlement.usage", "must match request.usage")
    settlement_cached_tokens = _require_int(settlement, "cached_billable_input_tokens", "$.settlement", result, minimum=0) or 0
    expected_credits, expected_provider_share = _expected_credits(settlement_usage, settlement_cached_tokens, result, "$.settlement")
    _require_credit_int(settlement, "credits", expected_credits, "$.settlement", result)
    _require_credit_int(settlement, "provider_share_credits", expected_provider_share, "$.settlement", result)
    settlement_rate = _get_object(settlement, "rate", "$.settlement", result)
    _require_exact_keys(settlement_rate, {
        "rate_card_key", "prompt_rate_per_mtok", "prompt_cache_hit_rate_per_mtok",
        "completion_rate_per_mtok", "provider_share_bps", "global_multiplier_ppm",
        "usd_per_million_credits",
    }, "$.settlement.rate", result)
    for key, expected in (
        ("rate_card_key", RATE_CARD_KEY),
        ("prompt_rate_per_mtok", PROMPT_RATE),
        ("prompt_cache_hit_rate_per_mtok", CACHED_PROMPT_RATE),
        ("completion_rate_per_mtok", COMPLETION_RATE),
        ("provider_share_bps", PROVIDER_SHARE_BPS),
        ("global_multiplier_ppm", GLOBAL_MULTIPLIER_PPM),
    ):
        _require_equal(settlement_rate, key, expected, "$.settlement.rate", result)
    _require_number_equal(settlement_rate, "usd_per_million_credits", USD_PER_MILLION_CREDITS, "$.settlement.rate", result)

    settlement_verdict = _get_object(payload, "settlement_verdict", "$", result)
    _require_exact_keys(settlement_verdict, {
        "outcome", "receipt_verification_outcome", "request_id", "attempt_n", "provider_id",
        "provider_receipt_key_id", "model_id", "provider_reported_model_hash",
        "expected_catalog_model_hash", "catalog_id", "catalog_body_digest", "route_snapshot_digest",
        "route_snapshot_mode", "receipt_version", "terminal_state", "hardware_context_id", "usage",
        "cached_billable_input_tokens", "credits", "provider_share_credits", "artifact_binding",
    }, "$.settlement_verdict", result)
    _require_equal(settlement_verdict, "outcome", "verified", "$.settlement_verdict", result)
    _require_equal(settlement_verdict, "receipt_verification_outcome", "verified", "$.settlement_verdict", result)
    _require_equal(settlement_verdict, "request_id", request_id, "$.settlement_verdict", result)
    verdict_attempt_n = _require_int(settlement_verdict, "attempt_n", "$.settlement_verdict", result, minimum=0)
    if attempt_n is not None and verdict_attempt_n is not None and verdict_attempt_n != attempt_n:
        result.add("$.settlement_verdict.attempt_n", "must equal route_snapshot.route_snapshot_v1.attempt_n")
    _require_equal(settlement_verdict, "provider_id", provider_id, "$.settlement_verdict", result)
    _require_equal(settlement_verdict, "provider_receipt_key_id", provider_receipt_key_id, "$.settlement_verdict", result)
    _require_equal(settlement_verdict, "model_id", MODEL_ID, "$.settlement_verdict", result)
    _require_equal(settlement_verdict, "provider_reported_model_hash", ARTIFACT_HASH, "$.settlement_verdict", result)
    _require_equal(settlement_verdict, "expected_catalog_model_hash", ARTIFACT_HASH, "$.settlement_verdict", result)
    _require_equal(settlement_verdict, "catalog_id", CATALOG_KEY, "$.settlement_verdict", result)
    _require_equal(settlement_verdict, "catalog_body_digest", candidate_catalog_sha256, "$.settlement_verdict", result)
    _require_equal(settlement_verdict, "route_snapshot_digest", route_snapshot_digest, "$.settlement_verdict", result)
    _require_equal(settlement_verdict, "route_snapshot_mode", "enforce", "$.settlement_verdict", result)
    _require_equal(settlement_verdict, "receipt_version", "4", "$.settlement_verdict", result)
    _require_equal(settlement_verdict, "terminal_state", "normal_done", "$.settlement_verdict", result)
    _require_equal(settlement_verdict, "hardware_context_id", hardware_context_id, "$.settlement_verdict", result)
    verdict_usage = _get_object(settlement_verdict, "usage", "$.settlement_verdict", result)
    _require_usage(verdict_usage, "$.settlement_verdict.usage", result)
    if not _usage_matches(request_usage, verdict_usage):
        result.add("$.settlement_verdict.usage", "must match request.usage")
    verdict_cached_tokens = _require_int(settlement_verdict, "cached_billable_input_tokens", "$.settlement_verdict", result, minimum=0)
    if verdict_cached_tokens is not None and verdict_cached_tokens != settlement_cached_tokens:
        result.add("$.settlement_verdict.cached_billable_input_tokens", "must equal settlement.cached_billable_input_tokens")
    _require_credit_int(settlement_verdict, "credits", expected_credits, "$.settlement_verdict", result)
    _require_credit_int(settlement_verdict, "provider_share_credits", expected_provider_share, "$.settlement_verdict", result)
    verdict_artifact_binding = _get_object(settlement_verdict, "artifact_binding", "$.settlement_verdict", result)
    _require_artifact_binding(
        verdict_artifact_binding,
        "$.settlement_verdict.artifact_binding",
        result,
        feed_sha256=feed_sha256,
        signer_key_id=signer_key_id,
        candidate_catalog_sha256=candidate_catalog_sha256,
    )

    blockers = _get_object(payload, "production_blockers", "$", result)
    _require_exact_keys(blockers, {
        "production_activation_enabled", "production_enforcement_changed", "production_rewards_enabled",
        "payout_jobs_enabled", "payout_execution_enabled", "release_published", "qualification",
    }, "$.production_blockers", result)
    for key in (
        "production_activation_enabled", "production_enforcement_changed", "production_rewards_enabled",
        "payout_jobs_enabled", "payout_execution_enabled", "release_published",
    ):
        _require_bool(blockers, key, False, "$.production_blockers", result)
    _require_equal(blockers, "qualification", "not_activated", "$.production_blockers", result)

    return result


def load_json(path: Path) -> dict[str, Any]:
    def reject_constant(value: str) -> None:
        raise ValueError(f"non-standard JSON number {value!r} is not allowed")

    with path.open("r", encoding="utf-8") as fh:
        data = json.load(fh, parse_constant=reject_constant)
    if not isinstance(data, dict):
        raise ValueError("top-level JSON value must be an object")
    return data


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evidence", type=Path, nargs="+", help="redacted evidence JSON file(s) to validate")
    args = parser.parse_args(argv)
    failed = False
    for path in args.evidence:
        try:
            payload = load_json(path)
        except Exception as exc:  # noqa: BLE001 - CLI should report any parse/load problem.
            print(f"{path}: {exc}", file=sys.stderr)
            failed = True
            continue
        result = validate_build1_narrow_mvp_evidence(payload)
        if result.ok:
            print(f"{path}: schema-valid")
        else:
            failed = True
            for error in result.errors:
                print(f"{path}: {error}", file=sys.stderr)
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
