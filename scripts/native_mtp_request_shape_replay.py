#!/usr/bin/env python3
"""Project sanitized request-shape captures into SPEC-048-R015 replay inputs.

The capture records consumed here are metadata, not buyer prompts. Projection
uses the native-MTP selector ordering from phase3-binary/Sources/macprovider-cli/
NativeMTP.swift and emits only the stripped fields accepted by
native_mtp_post_gateway_replay_analyze.py.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any


CAPTURE_SCHEMA = "macprovider.native-mtp-request-shape-capture.v1"
PLAN_SCHEMA = "macprovider.native-mtp-request-shape-replay-plan.v1"
POLICY_SCHEMA = "macprovider.native-mtp-post-gateway-replay-policy.v1"
REPLAY_SCHEMA = "macprovider.native-mtp-post-gateway-replay.v1"
POLICY_ISSUE = "SPEC-048-R015-post-gateway-replay"
CONFIDENCE_METHOD = "paired_block_bootstrap_holm_v1"
BOOTSTRAP_DRAWS = 10000
ALPHA = 0.05
MIN_BLOCKS = 10
THRESHOLDS = {
    "min_eligible_request_fraction": 0.10,
    "min_eligible_completion_token_fraction": 0.10,
    "ordinary_row_ttft_p95_regression_upper_bound": 0.05,
    "ordinary_row_itl_p95_regression_upper_bound": 0.05,
    "ordinary_row_throughput_change_lower_bound": -0.05,
}

SAFE_ID = re.compile(r"^[A-Za-z0-9_.:-]{1,128}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
ISO_DATEISH = re.compile(r"^\d{4}-\d{2}-\d{2}")
LOCAL_HOSTS = {"127.0.0.1", "::1", "localhost"}
CAPTURE_HEADER_KEYS = {
    "schema",
    "record_type",
    "captured_at",
    "native_mtp_mode",
    "capture_requires_native_mtp_off",
    "served_identity",
    "build_source_commit",
    "build_cdhash",
    "cli_version",
    "max_records",
    "max_bytes",
    "privacy_review_id",
    "privacy_reviewed_at",
    "capture_stage",
    "capture_mode",
    "sampling_plan_id",
    "sample_period_start",
    "sample_period_end",
    "captured_request_count",
    "captured_completion_tokens",
}
CAPTURE_SHAPE_KEYS = {
    "schema",
    "record_type",
    "sequence",
    "shape_id",
    "captured_at",
    "served_model_hash_sha256",
    "served_weights_manifest_sha256",
    "native_mtp_tuple_sha256",
    "native_mtp_served_snapshot_id_sha256",
    "native_mtp_target_generation",
    "stream",
    "stop_sequences",
    "sampling_requested",
    "multiple_completions_requested",
    "tools_present",
    "structured_output_requested",
    "logprobs_requested",
    "logit_controls_requested",
    "reasoning_or_template_model",
    "multimodal_requested",
    "unknown_request_fields_present",
    "generated_completion_tokens",
    "max_completion_tokens_requested",
    "pre_capacity_selector_reason",
    "pre_capacity_eligible",
    "effective_path",
    "observed_count",
    "prompt_tokens",
    "completion_tokens",
    "conversation_key_present",
    "conversation_key_cache_only",
    "conversation_cache_lease",
    "conversation_cache_cached_prompt_tokens",
    "conversation_cache_retained_handoff",
    "cache_group",
    "features",
}
FEATURE_KEYS = {
    "model",
    "temperature",
    "top_p",
    "top_k_present",
    "min_p_nonzero",
    "frequency_penalty_nonzero",
    "presence_penalty_nonzero",
    "repetition_penalty_nondefault",
    "n",
    "logit_bias_present",
    "logprobs",
    "top_logprobs",
    "reasoning_or_template",
    "unknown_top_level_keys",
    "unknown_stream_option_keys",
    "tools",
    "tool_choice",
    "tool_turn_state",
    "response_format",
    "multimodal",
    "unsupported_processor",
    "unsupported_state_cache",
    "stop_sequences",
    "stream",
}
TUPLE_KEYS = {
    "maximum_prompt_tokens",
    "maximum_completion_tokens",
    "request_feature_profile",
    "supports_stop_sequences",
    "supports_streaming",
    "supports_non_streaming",
    "has_qualified_row_mapped_transactions",
    "maximum_proposal_depth",
    "supports_current_processor",
    "supports_current_state_cache",
    "tuple_admitted",
    "tuple_revoked",
    "revocation_state_available",
}
PRIVATE_PATH_MARKERS = ("/Users/", "/private/", "/var/folders/", ".ssh/", "operator-secrets", "payout", "wallet")
RAW_TEXT_KEY_PARTS = ("prompt", "message", "content")
RAW_KEY_NAMES = {"conversation_key", "request_id", "account_id", "buyer_id", "provider_id", "trace_id"}
SENSITIVE_KEY_PARTS = ("api_key", "authorization", "bearer", "credential", "password", "private_key", "secret", "token")
SANITIZED_TEXT_KEYS = {
    "prompt_tokens",
    "completion_tokens",
    "conversation_cache_cached_prompt_tokens",
    "maximum_prompt_tokens",
    "maximum_completion_tokens",
    "captured_completion_tokens",
    "generated_completion_tokens",
    "max_completion_tokens_requested",
}
LEASE_STATES = {"not_applicable", "miss", "hit", "missing"}


def _reject_duplicate_keys(pairs: list[tuple[str, object]]) -> dict:
    keys = [key for key, _ in pairs]
    repeated = sorted(key for key in set(keys) if keys.count(key) > 1)
    if repeated:
        raise ValueError("duplicate JSON key: " + ",".join(repeated))
    return dict(pairs)


def _strict_loads(text: str) -> Any:
    return json.loads(
        text,
        object_pairs_hook=_reject_duplicate_keys,
        parse_constant=lambda value: (_ for _ in ()).throw(ValueError(f"non-finite JSON number: {value}")),
    )


def _read_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as fh:
        return _strict_loads(fh.read())


def _write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", "utf-8")


def _sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def _canonical_digest(value: object) -> str:
    return _sha256_bytes(json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8"))


def _is_int(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _is_count(value: object) -> bool:
    return _is_int(value) and value >= 0



def _strict_object(value: object, allowed: set[str], label: str) -> list[str]:
    if not isinstance(value, dict):
        return [f"{label}_not_object"]
    unknown = sorted(set(value) - allowed)
    return [f"{label}_unknown_fields:" + ",".join(unknown)] if unknown else []


def _privacy_violations(value: object, path: str = "$") -> list[str]:
    violations: list[str] = []
    if isinstance(value, dict):
        for key, child in value.items():
            lowered = key.lower()
            if lowered in RAW_KEY_NAMES:
                violations.append(f"raw_identifier_field:{path}.{key}")
            if lowered not in SANITIZED_TEXT_KEYS and any(part in lowered for part in RAW_TEXT_KEY_PARTS):
                violations.append(f"raw_text_field:{path}.{key}")
            if lowered not in SANITIZED_TEXT_KEYS and any(part in lowered for part in SENSITIVE_KEY_PARTS):
                violations.append(f"credential_field:{path}.{key}")
            violations.extend(_privacy_violations(child, f"{path}.{key}"))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            violations.extend(_privacy_violations(child, f"{path}[{index}]"))
    elif isinstance(value, str):
        lowered = value.lower()
        if any(marker.lower() in lowered for marker in PRIVATE_PATH_MARKERS):
            violations.append(f"private_path_value:{path}")
        if "-----begin " in lowered or "bearer " in lowered or "sk-" in lowered:
            violations.append(f"credential_value:{path}")
    return violations


@dataclass(frozen=True)
class CapturedShape:
    shape_id: str
    observed_count: int
    prompt_tokens: int
    completion_tokens: int
    conversation_key_present: bool
    conversation_key_cache_only: bool | None
    conversation_cache_lease: str | None
    conversation_cache_cached_prompt_tokens: int | None
    conversation_cache_retained_handoff: bool | None
    cache_group: str | None
    features: dict[str, Any]


def _require_bool(value: object, path: str, failures: list[str]) -> bool:
    if not isinstance(value, bool):
        failures.append(f"{path}:field_invalid")
        return False
    return value


def _validate_features(features: object, path: str) -> tuple[dict[str, Any], list[str]]:
    failures = _strict_object(features, FEATURE_KEYS, path)
    if not isinstance(features, dict):
        return {}, failures
    failures.extend(_privacy_violations(features, path))
    defaults: dict[str, Any] = {
        "model": "synthetic-native-mtp-replay",
        "temperature": 0,
        "top_p": 1,
        "top_k_present": False,
        "min_p_nonzero": False,
        "frequency_penalty_nonzero": False,
        "presence_penalty_nonzero": False,
        "repetition_penalty_nondefault": False,
        "n": 1,
        "logit_bias_present": False,
        "logprobs": False,
        "top_logprobs": False,
        "reasoning_or_template": False,
        "unknown_top_level_keys": False,
        "unknown_stream_option_keys": False,
        "tools": False,
        "tool_choice": False,
        "tool_turn_state": False,
        "response_format": "text",
        "multimodal": False,
        "unsupported_processor": False,
        "unsupported_state_cache": False,
        "stop_sequences": 0,
        "stream": True,
    }
    merged = {**defaults, **features}
    for key in (
        "top_k_present",
        "min_p_nonzero",
        "frequency_penalty_nonzero",
        "presence_penalty_nonzero",
        "repetition_penalty_nondefault",
        "logit_bias_present",
        "logprobs",
        "top_logprobs",
        "reasoning_or_template",
        "unknown_top_level_keys",
        "unknown_stream_option_keys",
        "tools",
        "tool_choice",
        "tool_turn_state",
        "multimodal",
        "unsupported_processor",
        "unsupported_state_cache",
        "stream",
    ):
        if not isinstance(merged.get(key), bool):
            failures.append(f"{path}.{key}:field_invalid")
    if not isinstance(merged.get("model"), str) or not SAFE_ID.match(merged["model"]):
        failures.append(f"{path}.model:field_invalid")
    for key in ("temperature", "top_p"):
        value = merged.get(key)
        if not isinstance(value, (int, float)) or isinstance(value, bool) or not math.isfinite(value):
            failures.append(f"{path}.{key}:field_invalid")
    if not _is_int(merged.get("n")) or merged["n"] < 1:
        failures.append(f"{path}.n:field_invalid")
    if merged.get("response_format") not in {"text", "json_object", "json_schema"}:
        failures.append(f"{path}.response_format:field_invalid")
    if not _is_count(merged.get("stop_sequences")):
        failures.append(f"{path}.stop_sequences:field_invalid")
    return merged, failures


def _shape_from_record(record: object, path: str) -> tuple[CapturedShape | None, list[str]]:
    failures = _strict_object(record, CAPTURE_SHAPE_KEYS, path)
    if not isinstance(record, dict):
        return None, failures
    failures.extend(_privacy_violations(record, path))
    if record.get("schema") != CAPTURE_SCHEMA or record.get("record_type") not in {"shape", "request_shape"}:
        failures.append(f"{path}:schema_invalid")
    if not (isinstance(record.get("shape_id"), str) and SAFE_ID.match(record["shape_id"])):
        failures.append(f"{path}.shape_id:field_invalid")
    observed_count = record.get("observed_count", 1)
    if not (_is_count(observed_count) and observed_count > 0):
        failures.append(f"{path}.observed_count:field_invalid")
    if not (_is_count(record.get("prompt_tokens")) and record["prompt_tokens"] > 0):
        failures.append(f"{path}.prompt_tokens:field_invalid")
    if not (_is_count(record.get("completion_tokens")) and record["completion_tokens"] > 0):
        failures.append(f"{path}.completion_tokens:field_invalid")
    key_present = _require_bool(record.get("conversation_key_present"), f"{path}.conversation_key_present", failures)
    cache_only = record.get("conversation_key_cache_only")
    lease = record.get("conversation_cache_lease")
    cached_tokens = record.get("conversation_cache_cached_prompt_tokens")
    retained = record.get("conversation_cache_retained_handoff")
    cache_group = record.get("cache_group")
    if cache_group is not None and not (isinstance(cache_group, str) and SAFE_ID.match(cache_group)):
        failures.append(f"{path}.cache_group:field_invalid")
    if not key_present:
        if cache_only is not None and cache_only is not False:
            failures.append(f"{path}.conversation_key_cache_only:field_invalid")
        if lease is not None and lease != "not_applicable":
            failures.append(f"{path}.conversation_cache_lease:field_invalid")
        if cached_tokens is not None and not (_is_int(cached_tokens) and cached_tokens == 0):
            failures.append(f"{path}.conversation_cache_cached_prompt_tokens:field_invalid")
        if retained is not None and retained is not False:
            failures.append(f"{path}.conversation_cache_retained_handoff:field_invalid")
    else:
        if not isinstance(cache_only, bool):
            failures.append(f"{path}.conversation_key_cache_only:field_missing")
        if cache_only is True:
            if lease not in LEASE_STATES - {"not_applicable"}:
                failures.append(f"{path}.conversation_cache_lease:field_invalid")
            if not _is_count(cached_tokens):
                failures.append(f"{path}.conversation_cache_cached_prompt_tokens:field_invalid")
            elif lease == "miss" and cached_tokens != 0:
                failures.append(f"{path}.conversation_cache_miss_with_cached_prompt_tokens")
            elif lease == "missing" and cached_tokens != 0:
                failures.append(f"{path}.conversation_cache_missing_with_cached_prompt_tokens")
            elif lease == "hit" and cached_tokens <= 0:
                failures.append(f"{path}.conversation_cache_hit_without_cached_prompt_tokens")
            if not isinstance(retained, bool):
                failures.append(f"{path}.conversation_cache_retained_handoff:field_invalid")
        else:
            if lease is not None and lease != "not_applicable":
                failures.append(f"{path}.sticky_key_with_cache_lease")
            if cached_tokens is not None and not (_is_int(cached_tokens) and cached_tokens == 0):
                failures.append(f"{path}.sticky_key_with_cached_prompt_tokens")
            if retained is not None and retained is not False:
                failures.append(f"{path}.sticky_key_with_retained_handoff")
    features, feature_failures = _validate_features(_features_from_record(record), f"{path}.features")
    failures.extend(feature_failures)
    if failures:
        return None, failures
    return CapturedShape(
        shape_id=record["shape_id"],
        observed_count=observed_count,
        prompt_tokens=record["prompt_tokens"],
        completion_tokens=record["completion_tokens"],
        conversation_key_present=key_present,
        conversation_key_cache_only=cache_only if isinstance(cache_only, bool) else None,
        conversation_cache_lease=lease if isinstance(lease, str) else None,
        conversation_cache_cached_prompt_tokens=cached_tokens if _is_int(cached_tokens) else None,
        conversation_cache_retained_handoff=retained if isinstance(retained, bool) else None,
        cache_group=cache_group if isinstance(cache_group, str) else None,
        features=features,
    ), []


def _features_from_record(record: dict) -> dict[str, Any]:
    if isinstance(record.get("features"), dict):
        return record["features"]
    logit_controls = bool(record.get("logit_controls_requested"))
    return {
        "temperature": 0.5 if record.get("sampling_requested") else 0,
        "top_p": 1,
        "frequency_penalty_nonzero": logit_controls,
        "presence_penalty_nonzero": False,
        "top_k_present": False,
        "min_p_nonzero": False,
        "repetition_penalty_nondefault": False,
        "n": 2 if record.get("multiple_completions_requested") else 1,
        "logit_bias_present": False,
        "logprobs": bool(record.get("logprobs_requested")),
        "top_logprobs": False,
        "reasoning_or_template": bool(record.get("reasoning_or_template_model")),
        "unknown_top_level_keys": bool(record.get("unknown_request_fields_present")),
        "unknown_stream_option_keys": False,
        "tools": bool(record.get("tools_present")),
        "tool_choice": False,
        "tool_turn_state": False,
        "response_format": "json_object" if record.get("structured_output_requested") else "text",
        "multimodal": bool(record.get("multimodal_requested")),
        "unsupported_processor": False,
        "unsupported_state_cache": False,
        "stop_sequences": int(record.get("stop_sequences", 0)) if _is_count(record.get("stop_sequences", 0)) else 0,
        "stream": bool(record.get("stream", True)),
    }


def load_capture(path: Path) -> tuple[dict, list[CapturedShape]]:
    header: dict | None = None
    shapes: list[CapturedShape] = []
    failures: list[str] = []
    with path.open("r", encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, 1):
            line = line.strip()
            if not line:
                continue
            record = _strict_loads(line)
            if not isinstance(record, dict):
                failures.append(f"{path}:{lineno}:record_not_object")
                continue
            if record.get("record_type") == "header":
                failures.extend(_strict_object(record, CAPTURE_HEADER_KEYS, f"{path}:{lineno}:header"))
                failures.extend(_privacy_violations(record, f"{path}:{lineno}:header"))
                if record.get("schema") != CAPTURE_SCHEMA:
                    failures.append(f"{path}:{lineno}:header_schema_invalid")
                if header is not None:
                    failures.append(f"{path}:{lineno}:duplicate_header")
                header = record
            elif record.get("record_type") in {"shape", "request_shape"}:
                shape, shape_failures = _shape_from_record(record, f"{path}:{lineno}:shape")
                failures.extend(shape_failures)
                if shape is not None:
                    shapes.append(shape)
            else:
                failures.append(f"{path}:{lineno}:record_type_invalid")
    if header is None:
        failures.append("missing_header")
    else:
        capture_mode = header.get("capture_mode") or (
            "mtp_off" if header.get("native_mtp_mode") == "off" else header.get("native_mtp_mode")
        )
        if capture_mode != "mtp_off":
            failures.append("header_capture_mode_not_mtp_off")
        capture_stage = header.get("capture_stage") or "post_gateway_provider_bound"
        if capture_stage not in {"post_gateway_provider_bound", "offline_projection_fixture"}:
            failures.append("header_capture_stage_invalid")
        if "privacy_review_id" in header and not (isinstance(header.get("privacy_review_id"), str) and SAFE_ID.match(header["privacy_review_id"])):
            failures.append("header_privacy_review_id_invalid")
        if "privacy_reviewed_at" in header and not (isinstance(header.get("privacy_reviewed_at"), str) and ISO_DATEISH.match(header["privacy_reviewed_at"])):
            failures.append("header_privacy_reviewed_at_invalid")
        if "sampling_plan_id" in header and not (isinstance(header.get("sampling_plan_id"), str) and SAFE_ID.match(header["sampling_plan_id"])):
            failures.append("header_sampling_plan_id_invalid")
        if "sample_period_start" in header and not (isinstance(header.get("sample_period_start"), str) and ISO_DATEISH.match(header["sample_period_start"])):
            failures.append("header_sample_period_start_invalid")
        if "sample_period_end" in header and not (isinstance(header.get("sample_period_end"), str) and ISO_DATEISH.match(header["sample_period_end"])):
            failures.append("header_sample_period_end_invalid")
        if "captured_request_count" in header and not (_is_count(header.get("captured_request_count")) and header["captured_request_count"] > 0):
            failures.append("header_captured_request_count_invalid")
        if "captured_completion_tokens" in header and not (_is_count(header.get("captured_completion_tokens")) and header["captured_completion_tokens"] > 0):
            failures.append("header_captured_completion_tokens_invalid")
    if not shapes:
        failures.append("missing_shapes")
    elif header is not None and "captured_request_count" in header and "captured_completion_tokens" in header:
        observed_requests = sum(shape.observed_count for shape in shapes)
        observed_tokens = sum(shape.observed_count * shape.completion_tokens for shape in shapes)
        if observed_requests != header.get("captured_request_count"):
            failures.append(f"captured_request_count_mismatch:{observed_requests}/{header.get('captured_request_count')}")
        if observed_tokens != header.get("captured_completion_tokens"):
            failures.append(f"captured_completion_tokens_mismatch:{observed_tokens}/{header.get('captured_completion_tokens')}")
    if failures:
        raise ValueError("capture invalid: " + "; ".join(sorted(set(failures))))
    return header or {}, shapes


def load_tuple_bounds(path: Path) -> dict:
    value = _read_json(path)
    failures = _strict_object(value, TUPLE_KEYS, "tuple")
    failures.extend(_privacy_violations(value, "tuple"))
    if isinstance(value, dict):
        for key in ("maximum_prompt_tokens", "maximum_completion_tokens"):
            if not (_is_count(value.get(key)) and value[key] > 0):
                failures.append(f"tuple.{key}:field_invalid")
        if not _is_count(value.get("maximum_proposal_depth")):
            failures.append("tuple.maximum_proposal_depth:field_invalid")
        if value.get("request_feature_profile") not in {"native_mtp_greedy_text_v1", "native_mtp_sampled_text_v1"}:
            failures.append("tuple.request_feature_profile:field_invalid")
        for key in (
            "supports_stop_sequences",
            "supports_streaming",
            "supports_non_streaming",
            "has_qualified_row_mapped_transactions",
            "supports_current_processor",
            "supports_current_state_cache",
            "tuple_admitted",
            "tuple_revoked",
            "revocation_state_available",
        ):
            if not isinstance(value.get(key), bool):
                failures.append(f"tuple.{key}:field_invalid")
    if failures:
        raise ValueError("tuple bounds invalid: " + "; ".join(sorted(set(failures))))
    return value


def _supports_sampler(temperature: float, top_p: float) -> bool:
    return 0 <= temperature <= 2 and 0 <= top_p <= 1


def selector_reason(shape: CapturedShape, tuple_bounds: dict) -> str:
    features = shape.features
    if not tuple_bounds["has_qualified_row_mapped_transactions"]:
        return "capability_mismatch"
    if not tuple_bounds["revocation_state_available"]:
        return "revocation_state_unavailable"
    if tuple_bounds["tuple_revoked"]:
        return "tuple_revoked"
    if not tuple_bounds["tuple_admitted"]:
        return "tuple_not_admitted"
    if not tuple_bounds["has_qualified_row_mapped_transactions"]:
        return "capability_mismatch"
    if tuple_bounds["maximum_proposal_depth"] <= 0:
        return "insufficient_verification_capacity"
    if not tuple_bounds["supports_current_processor"]:
        return "unsupported_processor"
    if not tuple_bounds["supports_current_state_cache"]:
        return "unsupported_state_cache"
    if not tuple_bounds["supports_current_processor"] or features["unsupported_processor"]:
        return "unsupported_processor"
    if not tuple_bounds["supports_current_state_cache"] or features["unsupported_state_cache"]:
        return "unsupported_state_cache"
    if features["stream"]:
        if not tuple_bounds["supports_streaming"]:
            return "capability_mismatch"
    elif not tuple_bounds["supports_non_streaming"]:
        return "capability_mismatch"
    if tuple_bounds["maximum_proposal_depth"] <= 0:
        return "insufficient_verification_capacity"
    if shape.prompt_tokens > tuple_bounds["maximum_prompt_tokens"]:
        return "capability_mismatch"
    if shape.completion_tokens > tuple_bounds["maximum_completion_tokens"]:
        return "capability_mismatch"
    if features["stop_sequences"] > 0 and not tuple_bounds["supports_stop_sequences"]:
        return "capability_mismatch"
    if features["unknown_top_level_keys"] or features["unknown_stream_option_keys"]:
        return "unknown_request_field"
    sampled = features["temperature"] != 0 or features["top_p"] != 1
    if sampled and (
        tuple_bounds["request_feature_profile"] != "native_mtp_sampled_text_v1"
        or not _supports_sampler(float(features["temperature"]), float(features["top_p"]))
    ):
        return "sampling"
    if features["n"] != 1:
        return "multiple_completions"
    if (
        features["presence_penalty_nonzero"]
        or features["frequency_penalty_nonzero"]
        or features["top_k_present"]
        or features["min_p_nonzero"]
        or features["repetition_penalty_nondefault"]
    ):
        return "logit_controls"
    if shape.conversation_key_present and not shape.conversation_key_cache_only:
        return "conversation_key"
    if features["multimodal"]:
        return "multimodal"
    if features["response_format"] != "text":
        return "structured_output"
    if features["tools"] or features["tool_choice"] or features["tool_turn_state"]:
        return "tools"
    if features["logprobs"] or features["top_logprobs"]:
        return "logprobs"
    if features["logit_bias_present"]:
        return "logit_controls"
    if features["reasoning_or_template"]:
        return "reasoning_or_template"
    if shape.conversation_key_present and shape.conversation_key_cache_only:
        if (
            shape.conversation_cache_lease == "miss"
            and shape.conversation_cache_cached_prompt_tokens == 0
            and shape.conversation_cache_retained_handoff is False
        ):
            return "eligible"
        return "conversation_key"
    return "eligible"


def expand_observed_shapes(shapes: list[CapturedShape]) -> list[tuple[CapturedShape, str]]:
    expanded: list[tuple[CapturedShape, str]] = []
    for shape in shapes:
        if shape.observed_count == 1:
            expanded.append((shape, shape.shape_id))
            continue
        for index in range(shape.observed_count):
            expanded.append((shape, f"{shape.shape_id}:{index + 1}"))
    return expanded


def analyzer_shape(shape: CapturedShape, tuple_bounds: dict, effective_path: str, *, shape_id: str | None = None) -> dict:
    reason = selector_reason(shape, tuple_bounds)
    eligible = reason == "eligible"
    result = {
        "shape_id": shape_id or shape.shape_id,
        "conversation_key_present": shape.conversation_key_present,
        "completion_tokens": shape.completion_tokens,
        "pre_capacity_selector_reason": reason,
        "pre_capacity_eligible": eligible,
        "effective_path": "native_mtp" if eligible and effective_path == "observed_mixed" else "ordinary",
    }
    if shape.conversation_key_present:
        result["conversation_key_cache_only"] = shape.conversation_key_cache_only
        if shape.conversation_key_cache_only:
            result["conversation_cache_lease"] = shape.conversation_cache_lease
            result["conversation_cache_cached_prompt_tokens"] = shape.conversation_cache_cached_prompt_tokens
            result["conversation_cache_retained_handoff"] = shape.conversation_cache_retained_handoff
    return result


def _synthetic_words(prompt_tokens: int) -> str:
    return " ".join("synthetic" for _ in range(max(1, prompt_tokens)))


def synthetic_request(shape: CapturedShape) -> dict:
    features = shape.features
    body: dict[str, Any] = {
        "model": features["model"],
        "messages": [{"role": "user", "content": _synthetic_words(shape.prompt_tokens)}],
        "stream": True,
        "max_tokens": shape.completion_tokens,
        "temperature": features["temperature"],
        "top_p": features["top_p"],
    }
    if features["stop_sequences"]:
        body["stop"] = ["<STOP>"][:1]
    if features["n"] != 1:
        body["n"] = features["n"]
    if features["tools"]:
        body["tools"] = [{"type": "function", "function": {"name": "synthetic_tool", "parameters": {"type": "object"}}}]
    if features["tool_choice"]:
        body["tool_choice"] = "auto"
    if features["response_format"] == "json_object":
        body["response_format"] = {"type": "json_object"}
    elif features["response_format"] == "json_schema":
        body["response_format"] = {"type": "json_schema", "json_schema": {"name": "synthetic", "schema": {"type": "object"}}}
    if features["logprobs"]:
        body["logprobs"] = True
    if features["top_logprobs"]:
        body["top_logprobs"] = 1
    return body


def build_policy(privacy_review_id: str, privacy_reviewed_at: str, preregistration_digest: str, sample_digest: str, seed: int) -> dict:
    if not (SAFE_ID.match(privacy_review_id) and ISO_DATEISH.match(privacy_reviewed_at) and HEX64.match(preregistration_digest)):
        raise ValueError("invalid privacy/preregistration metadata")
    return {
        "schema": POLICY_SCHEMA,
        "issue": POLICY_ISSUE,
        "confidence_method": CONFIDENCE_METHOD,
        "preregistration_digest_sha256": preregistration_digest,
        "privacy_review_id": privacy_review_id,
        "privacy_reviewed_at": privacy_reviewed_at,
        "sample_digest_sha256": sample_digest,
        "seed": seed,
        "bootstrap_draws": BOOTSTRAP_DRAWS,
        "alpha": ALPHA,
        "min_paired_blocks": MIN_BLOCKS,
        "thresholds": THRESHOLDS,
    }


def project_capture(
    capture_path: Path,
    tuple_bounds_path: Path,
    *,
    blocks: int,
    privacy_review_id: str,
    privacy_reviewed_at: str,
    preregistration_digest: str,
    seed: int,
) -> tuple[dict, dict]:
    if blocks < MIN_BLOCKS:
        raise ValueError(f"blocks must be >= {MIN_BLOCKS}")
    capture_header, shapes = load_capture(capture_path)
    tuple_bounds = load_tuple_bounds(tuple_bounds_path)
    sample_projection = [
        {
            "shape_id": shape.shape_id,
            "prompt_tokens": shape.prompt_tokens,
            "completion_tokens": shape.completion_tokens,
            "observed_count": shape.observed_count,
            "conversation_key_present": shape.conversation_key_present,
            "conversation_key_cache_only": shape.conversation_key_cache_only,
            "conversation_cache_lease": shape.conversation_cache_lease,
            "conversation_cache_cached_prompt_tokens": shape.conversation_cache_cached_prompt_tokens,
            "conversation_cache_retained_handoff": shape.conversation_cache_retained_handoff,
            "features": shape.features,
            "pre_capacity_selector_reason": selector_reason(shape, tuple_bounds),
        }
        for shape in shapes
    ]
    sample_digest = _canonical_digest(sample_projection)
    expanded_shapes = expand_observed_shapes(shapes)
    policy = build_policy(privacy_review_id, privacy_reviewed_at, preregistration_digest, sample_digest, seed)
    policy_sha = _canonical_digest(policy)
    plan_blocks = []
    for block_index in range(blocks):
        request_shapes = [
            analyzer_shape(shape, tuple_bounds, "observed_mixed", shape_id=shape_id)
            for shape, shape_id in expanded_shapes
        ]
        replay_requests = [
            {
                "shape_id": shape_id,
                "cache_group": shape.cache_group,
                "synthetic_content_notice": "synthetic prompt content preserves captured token length/features only",
                "request": synthetic_request(shape),
            }
            for shape, shape_id in expanded_shapes
        ]
        plan_blocks.append({"block_index": block_index, "request_shapes": request_shapes, "replay_requests": replay_requests})
    plan = {
        "schema": PLAN_SCHEMA,
        "policy_sha256": policy_sha,
        "sample_digest_sha256": sample_digest,
        "source_capture_sha256": _sha256_file(capture_path),
        "tuple_bounds_sha256": _sha256_file(tuple_bounds_path),
        "projection_stage": "offline_sanitized_shape_projection",
        "capture_mode": capture_header.get("capture_mode"),
        "sample_report": {
            "sampling_plan_id": capture_header.get("sampling_plan_id"),
            "sample_period_start": capture_header.get("sample_period_start"),
            "sample_period_end": capture_header.get("sample_period_end"),
            "captured_request_count": capture_header.get("captured_request_count"),
            "captured_completion_tokens": capture_header.get("captured_completion_tokens"),
            "projected_request_count_per_block": len(expanded_shapes),
            "representativeness_claim": "bounded preregistered captured counts only; no population representativeness inferred",
        },
        "replay_requirements": {
            "endpoint": "isolated signed local no-join provider",
            "metrics": "true timestamped SSE observations only",
            "synthetic_content": "not real buyer metadata and not unknown cache recreation",
        },
        "blocks": plan_blocks,
    }
    return policy, plan


@dataclass(frozen=True)
class StreamObservation:
    request_started_at: float
    first_token_at: float
    token_times: tuple[float, ...]
    completed_at: float
    token_count: int


def _iter_sse_events(byte_chunks: list[tuple[float, bytes]]) -> list[tuple[float, str]]:
    buffer = ""
    events: list[tuple[float, str]] = []
    event_time = 0.0
    for timestamp, chunk in byte_chunks:
        event_time = timestamp
        buffer += chunk.decode("utf-8")
        while "\n\n" in buffer:
            raw, buffer = buffer.split("\n\n", 1)
            data_lines = []
            for line in raw.splitlines():
                if line.startswith("data:"):
                    data_lines.append(line[5:].strip())
            if data_lines:
                events.append((event_time, "\n".join(data_lines)))
    return events


def observation_from_sse(started_at: float, chunks: list[tuple[float, bytes]]) -> StreamObservation:
    token_times: list[float] = []
    completed_at: float | None = None
    for timestamp, data in _iter_sse_events(chunks):
        if data == "[DONE]":
            completed_at = timestamp
            continue
        try:
            event = _strict_loads(data)
        except Exception:
            continue
        if isinstance(event, dict):
            choices = event.get("choices")
            if isinstance(choices, list) and choices:
                delta = choices[0].get("delta") if isinstance(choices[0], dict) else None
                if isinstance(delta, dict) and (delta.get("content") or delta.get("reasoning_content")):
                    token_times.append(timestamp)
    if not token_times:
        raise ValueError("stream emitted no token SSE events")
    if completed_at is None:
        completed_at = token_times[-1]
    return StreamObservation(
        request_started_at=started_at,
        first_token_at=token_times[0],
        token_times=tuple(token_times),
        completed_at=completed_at,
        token_count=len(token_times),
    )


def _percentile(values: list[float], q: float) -> float:
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    pos = (len(ordered) - 1) * q
    lo = math.floor(pos)
    hi = math.ceil(pos)
    if lo == hi:
        return ordered[lo]
    return ordered[lo] + (ordered[hi] - ordered[lo]) * (pos - lo)


def metrics_from_observations(observations: list[StreamObservation]) -> dict:
    if not observations:
        raise ValueError("missing measured observations")
    ttfts = [obs.first_token_at - obs.request_started_at for obs in observations]
    gaps = [
        later - earlier
        for obs in observations
        for earlier, later in zip(obs.token_times, obs.token_times[1:])
    ]
    decode_tokens = sum(max(0, obs.token_count - 1) for obs in observations)
    first = min(obs.first_token_at for obs in observations)
    last = max(obs.completed_at for obs in observations)
    duration = last - first
    if duration <= 0 or decode_tokens <= 0:
        raise ValueError("non-positive measured decode interval")
    return {
        "ordinary_row_p95_ttft_seconds": _percentile(ttfts, 0.95),
        "ordinary_row_p95_itl_seconds": _percentile(gaps or ttfts, 0.95),
        "ordinary_row_throughput_tps": decode_tokens / duration,
        "end_to_end_aggregate_throughput_tps": sum(obs.token_count for obs in observations) / (max(obs.completed_at for obs in observations) - min(obs.request_started_at for obs in observations)),
    }


def _ensure_local_endpoint(endpoint: str, allow_nonlocal: bool) -> None:
    parsed = urllib.parse.urlparse(endpoint)
    if parsed.scheme not in {"http", "https"}:
        raise ValueError("endpoint must be http or https")
    if not allow_nonlocal and parsed.hostname not in LOCAL_HOSTS:
        raise ValueError("endpoint must be local unless --allow-nonlocal is set")


def _post_sse(endpoint: str, body: dict, timeout: float) -> StreamObservation:
    payload = json.dumps(body, sort_keys=True).encode("utf-8")
    request = urllib.request.Request(
        endpoint,
        data=payload,
        headers={"Content-Type": "application/json", "Accept": "text/event-stream"},
        method="POST",
    )
    started = time.monotonic()
    chunks: list[tuple[float, bytes]] = []
    context = ssl.create_default_context()
    try:
        with urllib.request.urlopen(request, timeout=timeout, context=context) as response:
            while True:
                chunk = response.readline()
                if not chunk:
                    break
                chunks.append((time.monotonic(), chunk))
    except urllib.error.URLError as exc:
        raise ValueError(f"request failed: {exc}") from exc
    return observation_from_sse(started, chunks)


def run_replay(plan_path: Path, policy_path: Path, output_path: Path, endpoint: str, *, timeout: float, allow_nonlocal: bool) -> None:
    _ensure_local_endpoint(endpoint, allow_nonlocal)
    plan = _read_json(plan_path)
    policy_sha = _sha256_file(policy_path)
    if not isinstance(plan, dict) or plan.get("schema") != PLAN_SCHEMA:
        raise ValueError("plan schema invalid")
    records = [
        {
            "schema": REPLAY_SCHEMA,
            "record_type": "header",
            "policy_sha256": policy_sha,
            "sample_digest_sha256": plan["sample_digest_sha256"],
            "preregistration_digest_sha256": _read_json(policy_path)["preregistration_digest_sha256"],
            "privacy_review_id": _read_json(policy_path)["privacy_review_id"],
        }
    ]
    for block in plan["blocks"]:
        for path in ("mtp_disabled", "observed_mixed"):
            observations = [_post_sse(endpoint, item["request"], timeout) for item in block["replay_requests"]]
            metrics = metrics_from_observations(observations)
            shapes = []
            for shape in block["request_shapes"]:
                out = dict(shape)
                out["effective_path"] = "ordinary" if path == "mtp_disabled" else out["effective_path"]
                shapes.append(out)
            records.append(
                {
                    "schema": REPLAY_SCHEMA,
                    "record_type": "block",
                    "policy_sha256": policy_sha,
                    "block_index": block["block_index"],
                    "path": path,
                    "request_shapes": shapes,
                    **metrics,
                }
            )
    output_path.write_text("\n".join(json.dumps(record, sort_keys=True) for record in records) + "\n", "utf-8")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)
    project = sub.add_parser("project")
    project.add_argument("--capture", type=Path, required=True)
    project.add_argument("--tuple-bounds", type=Path, required=True)
    project.add_argument("--policy-out", type=Path, required=True)
    project.add_argument("--plan-out", type=Path, required=True)
    project.add_argument("--privacy-review-id", required=True)
    project.add_argument("--privacy-reviewed-at", required=True)
    project.add_argument("--preregistration-digest-sha256", required=True)
    project.add_argument("--seed", type=int, default=48015)
    project.add_argument("--blocks", type=int, default=MIN_BLOCKS)
    run = sub.add_parser("run")
    run.add_argument("--plan", type=Path, required=True)
    run.add_argument("--policy", type=Path, required=True)
    run.add_argument("--output", type=Path, required=True)
    run.add_argument("--endpoint", required=True)
    run.add_argument("--timeout", type=float, default=60.0)
    run.add_argument("--allow-nonlocal", action="store_true")
    run.add_argument("--no-join-confirmed", action="store_true")
    run.add_argument("--signed-local-candidate", action="store_true")
    args = parser.parse_args(argv)
    try:
        if args.cmd == "project":
            policy, plan = project_capture(
                args.capture,
                args.tuple_bounds,
                blocks=args.blocks,
                privacy_review_id=args.privacy_review_id,
                privacy_reviewed_at=args.privacy_reviewed_at,
                preregistration_digest=args.preregistration_digest_sha256,
                seed=args.seed,
            )
            _write_json(args.policy_out, policy)
            _write_json(args.plan_out, plan)
        else:
            if not args.no_join_confirmed or not args.signed_local_candidate:
                raise ValueError("run requires --no-join-confirmed and --signed-local-candidate")
            run_replay(args.plan, args.policy, args.output, args.endpoint, timeout=args.timeout, allow_nonlocal=args.allow_nonlocal)
    except Exception as exc:
        print(json.dumps({"status": "FAIL", "error": str(exc)}, sort_keys=True))
        return 1
    print(json.dumps({"status": "PASS"}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
