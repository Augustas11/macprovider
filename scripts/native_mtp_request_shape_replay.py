#!/usr/bin/env python3
"""Project sanitized native-MTP request-shape captures into a replay plan.

This tool is intentionally projection-only. It does not run replay traffic and
it does not claim qualification evidence: a real lab runner must provide
separate disabled/mixed modes, actual path/capacity/lease proof, committed token
counts/timestamps, cache-group replay ordering, and measured metrics.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any


CAPTURE_SCHEMA = "macprovider.native-mtp-request-shape-capture.v1"
PLAN_SCHEMA = "macprovider.native-mtp-request-shape-replay-plan.v1"
POLICY_SCHEMA = "macprovider.native-mtp-post-gateway-replay-policy.v1"
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
PRIVATE_PATH_MARKERS = ("/Users/", "/private/", "/var/folders/", ".ssh/", "operator-secrets", "payout", "wallet")
RAW_TEXT_KEY_PARTS = ("prompt", "message", "content")
RAW_KEY_NAMES = {"conversation_key", "request_id", "account_id", "buyer_id", "provider_id", "trace_id"}
SENSITIVE_KEY_PARTS = ("api_key", "authorization", "bearer", "credential", "password", "private_key", "secret", "token")
SANITIZED_TEXT_KEYS = {
    "prompt_tokens",
    "completion_tokens",
    "generated_completion_tokens",
    "requested_max_completion_tokens",
    "effective_max_output_tokens",
    "captured_completion_tokens",
    "target_completion_tokens",
    "tool_message_count",
    "assistant_tool_call_count",
    "min_eligible_completion_token_fraction",
    "maximum_prompt_tokens",
    "maximum_completion_tokens",
    "conversation_cache_cached_prompt_tokens",
}
LEASE_STATES = {"not_applicable", "miss", "hit", "missing"}

REPLAY_RESULT_SCHEMA = "macprovider.native-mtp-request-shape-replay.v1"
ANALYZER_JSONL_SCHEMA = "macprovider.native-mtp-post-gateway-replay.v1"
ANALYZER_PATHS = {"ordinary": "mtp_disabled", "native_mtp": "observed_mixed"}
EXPECTED_TARGET_STOP_CONTROL = "lab_decode_output_cap_by_request_id"
EXPECTED_COMPLETION_LENGTH_BINDING = "effective_max_output_tokens drives admission; LAB decode output caps bind measured generation to target_completion_tokens without cancellation; exact measured match is required for qualification"
REPLAY_HEADER_KEYS = {
    "schema",
    "record_type",
    "provider_commit",
    "model_id",
    "target_sha256",
    "mtp_sha256",
    "tokenizer_sha256",
    "policy_sha256",
    "bench_policy_sha256",
    "sample_digest_sha256",
    "preregistration_digest_sha256",
    "privacy_review_id",
    "capture_sha256",
    "capture_schema",
    "capture_requires_native_mtp_off",
    "run_order",
    "mixed_rows",
    "max_native_active_rows",
    "cache_key_scope",
    "exports_raw_prompt_text",
    "exports_recoverable_cache_groups",
    "completion_length_binding",
    "target_stop_control",
    "synthetic_stand_ins",
    "run_metrics_version",
    "sample_filter_included_count",
    "sample_filter_excluded_count",
    "request_shapes",
}
REPLAY_RUN_KEYS = {
    "schema",
    "record_type",
    "policy_sha256",
    "bench_policy_sha256",
    "capture_sha256",
    "block_index",
    "path",
    "order_position",
    "requests",
    "wall_seconds",
    "ordinary_observed_requests",
    "ordinary_observed_completion_tokens",
    "ordinary_observed_interval_seconds",
    "ordinary_observed_throughput_tps",
    "aggregate_completion_tokens",
    "aggregate_throughput_tps",
    "qualification_status",
    "sample_coverage_complete",
    "admission_observation_complete",
    "missing_admission_request_ids",
    "target_completion_observation_complete",
    "target_completion_mismatch_request_ids",
    "committed_timing_observation_complete",
    "completion_tokens_by_request",
    "effective_paths",
    "admission_projection",
}
REPLAY_SHAPE_KEYS = {
    "shape_id",
    "served_model_hash_sha256",
    "served_weights_manifest_sha256",
    "stream",
    "requested_temperature",
    "requested_top_p",
    "requested_max_completion_tokens",
    "effective_max_output_tokens",
    "prompt_tokens",
    "target_completion_tokens",
    "completion_tokens",
    "generated_completion_tokens",
    "pre_capacity_selector_reason",
    "pre_capacity_eligible",
    "effective_path",
    "conversation_key_present",
    "conversation_key_cache_only",
    "conversation_cache_lease",
    "conversation_cache_cached_prompt_tokens",
    "conversation_cache_retained_handoff",
    "anonymous_cache_group_sha256",
}
REPLAY_COMPLETION_KEYS = {
    "request_id",
    "target_completion_tokens",
    "completion_tokens",
    "target_completion_matched",
    "target_stop_triggered",
    "generated_completion_tokens",
    "committed_timing_events",
    "ttft_seconds",
    "inter_token_gaps",
}
REPLAY_ADMISSION_KEYS = {
    "request_id",
    "shape_id",
    "target_completion_tokens",
    "effective_max_output_tokens",
    "expected_selector_reason",
    "actual_selector_reason",
    "expected_effective_path",
    "actual_effective_path",
    "matches",
    "reproduced",
    "pending_reason",
}
ANALYZER_HEADER_KEYS = {
    "schema",
    "record_type",
    "policy_sha256",
    "sample_digest_sha256",
    "preregistration_digest_sha256",
    "privacy_review_id",
}
ANALYZER_BLOCK_KEYS = {
    "schema",
    "record_type",
    "policy_sha256",
    "block_index",
    "path",
    "request_shapes",
    "ordinary_row_p95_ttft_seconds",
    "ordinary_row_p95_itl_seconds",
    "ordinary_row_throughput_tps",
    "end_to_end_aggregate_throughput_tps",
}

CAPTURE_HEADER_KEYS = {
    "schema",
    "record_type",
    "captured_at",
    "native_mtp_mode",
    "capture_requires_native_mtp_off",
    "sample_method",
    "sample_window_started_at",
    "served_identity",
    "build_source_commit",
    "build_cdhash",
    "build_identity_complete",
    "cli_version",
    "max_records",
    "max_bytes",
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
    "stop_sequence_utf8_length_buckets",
    "requested_temperature",
    "requested_top_p",
    "requested_top_k",
    "requested_min_p",
    "requested_presence_penalty",
    "requested_frequency_penalty",
    "requested_repetition_penalty",
    "requested_n",
    "requested_max_completion_tokens",
    "effective_max_output_tokens",
    "sampling_requested",
    "multiple_completions_requested",
    "top_k_present",
    "min_p_nonzero",
    "frequency_penalty_nonzero",
    "presence_penalty_nonzero",
    "repetition_penalty_nondefault",
    "logit_bias_present",
    "logit_bias_geometry",
    "tools_present",
    "tool_count",
    "tool_choice_present",
    "tool_choice_kind",
    "tool_turn_state_present",
    "tool_message_count",
    "assistant_tool_call_count",
    "structured_output_requested",
    "response_format_kind",
    "response_schema_geometry",
    "logprobs_requested",
    "top_logprobs_requested",
    "logit_controls_requested",
    "reasoning_or_template_model",
    "multimodal_requested",
    "unknown_request_fields_present",
    "unknown_top_level_keys_present",
    "unknown_stream_option_keys_present",
    "conversation_key_present",
    "conversation_key_cache_only",
    "conversation_cache_lease",
    "conversation_cache_cached_prompt_tokens",
    "conversation_cache_retained_handoff",
    "anonymous_cache_group_sha256",
    "prompt_tokens",
    "completion_tokens",
    "generated_completion_tokens",
    "pre_capacity_selector_reason",
    "pre_capacity_eligible",
    "effective_path",
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
    return _strict_loads(path.read_text("utf-8"))


def _canonical_bytes(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8") + b"\n"


def _write_json(path: Path, value: object) -> None:
    path.write_bytes(_canonical_bytes(value))


def _sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def _digest(value: object) -> str:
    return _sha256_bytes(_canonical_bytes(value))


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


def _require_bool(record: dict, key: str, path: str, failures: list[str]) -> bool:
    value = record.get(key)
    if not isinstance(value, bool):
        failures.append(f"{path}.{key}:field_invalid")
        return False
    return value


def _require_count(record: dict, key: str, path: str, failures: list[str], *, positive: bool = False) -> int:
    value = record.get(key)
    if not _is_count(value) or (positive and value <= 0):
        failures.append(f"{path}.{key}:field_invalid")
        return 0
    return value


@dataclass(frozen=True)
class CapturedShape:
    shape_id: str
    prompt_tokens: int
    completion_tokens: int
    requested_max_completion_tokens: int | None
    effective_max_output_tokens: int
    conversation_key_present: bool
    conversation_key_cache_only: bool
    conversation_cache_lease: str
    conversation_cache_cached_prompt_tokens: int
    conversation_cache_retained_handoff: bool
    stream: bool
    stop_sequences: int
    requested_temperature: float
    requested_top_p: float
    requested_n: int
    sampling_requested: bool
    multiple_completions_requested: bool
    top_k_present: bool
    min_p_nonzero: bool
    frequency_penalty_nonzero: bool
    presence_penalty_nonzero: bool
    repetition_penalty_nondefault: bool
    logit_bias_present: bool
    tools_present: bool
    tool_choice_present: bool
    tool_turn_state_present: bool
    structured_output_requested: bool
    response_format_kind: str
    logprobs_requested: bool
    top_logprobs_requested: bool
    logit_controls_requested: bool
    reasoning_or_template_model: bool
    multimodal_requested: bool
    unknown_request_fields_present: bool
    captured_pre_capacity_selector_reason: str
    captured_pre_capacity_eligible: bool
    unknown_top_level_keys_present: bool
    unknown_stream_option_keys_present: bool
    sanitized_geometry: dict[str, object]


def _shape_from_record(record: object, path: str) -> tuple[CapturedShape | None, list[str]]:
    failures = _strict_object(record, CAPTURE_SHAPE_KEYS, path)
    if not isinstance(record, dict):
        return None, failures
    failures.extend(_privacy_violations(record, path))
    if record.get("schema") != CAPTURE_SCHEMA or record.get("record_type") != "request_shape":
        failures.append(f"{path}:schema_invalid")
    if not (isinstance(record.get("shape_id"), str) and SAFE_ID.match(record["shape_id"])):
        failures.append(f"{path}.shape_id:field_invalid")
    prompt_tokens = _require_count(record, "prompt_tokens", path, failures, positive=True)
    completion_tokens = _require_count(record, "completion_tokens", path, failures, positive=True)
    _require_count(record, "generated_completion_tokens", path, failures)
    requested_max_completion_tokens_raw = record.get("requested_max_completion_tokens")
    if requested_max_completion_tokens_raw is None:
        requested_max_completion_tokens = None
    elif _is_count(requested_max_completion_tokens_raw) and requested_max_completion_tokens_raw > 0:
        requested_max_completion_tokens = requested_max_completion_tokens_raw
    else:
        failures.append(f"{path}.requested_max_completion_tokens:field_invalid")
        requested_max_completion_tokens = None
    effective_max_output_tokens = _require_count(record, "effective_max_output_tokens", path, failures, positive=True)
    key_present = _require_bool(record, "conversation_key_present", path, failures)
    cache_only = _require_bool(record, "conversation_key_cache_only", path, failures)
    retained = _require_bool(record, "conversation_cache_retained_handoff", path, failures)
    cached_tokens = _require_count(record, "conversation_cache_cached_prompt_tokens", path, failures)
    lease = record.get("conversation_cache_lease")
    if lease not in LEASE_STATES:
        failures.append(f"{path}.conversation_cache_lease:field_invalid")
    if not key_present:
        if cache_only or lease != "not_applicable" or cached_tokens != 0 or retained:
            failures.append(f"{path}.conversation_cache_proof_inconsistent_without_key")
    elif cache_only:
        if lease == "not_applicable":
            failures.append(f"{path}.conversation_cache_lease:field_invalid")
        if lease in {"miss", "missing"} and cached_tokens != 0:
            failures.append(f"{path}.conversation_cache_{lease}_with_cached_prompt_tokens")
        if lease == "hit" and cached_tokens <= 0:
            failures.append(f"{path}.conversation_cache_hit_without_cached_prompt_tokens")
    elif lease != "not_applicable" or cached_tokens != 0 or retained:
        failures.append(f"{path}.sticky_key_with_cache_proof")
    captured_reason = record.get("pre_capacity_selector_reason")
    if not isinstance(captured_reason, str):
        failures.append(f"{path}.pre_capacity_selector_reason:field_invalid")
    captured_eligible = _require_bool(record, "pre_capacity_eligible", path, failures)
    bools = {
        key: _require_bool(record, key, path, failures)
        for key in (
            "stream",
            "sampling_requested",
            "multiple_completions_requested",
            "top_k_present",
            "min_p_nonzero",
            "frequency_penalty_nonzero",
            "presence_penalty_nonzero",
            "repetition_penalty_nondefault",
            "logit_bias_present",
            "tools_present",
            "tool_choice_present",
            "tool_turn_state_present",
            "structured_output_requested",
            "logprobs_requested",
            "top_logprobs_requested",
            "logit_controls_requested",
            "reasoning_or_template_model",
            "multimodal_requested",
            "unknown_request_fields_present",
            "unknown_top_level_keys_present",
            "unknown_stream_option_keys_present",
        )
    }
    if bools["sampling_requested"] != (record.get("requested_temperature") != 0 or record.get("requested_top_p") != 1):
        failures.append(f"{path}.sampling_requested_inconsistent")
    if bools["multiple_completions_requested"] != (record.get("requested_n") != 1):
        failures.append(f"{path}.multiple_completions_requested_inconsistent")
    detailed_tools = bools["tool_choice_present"] or bools["tool_turn_state_present"]
    if bools["tools_present"] is False and detailed_tools:
        failures.append(f"{path}.tools_present_inconsistent")
    if bools["structured_output_requested"] != (record.get("response_format_kind") != "text"):
        failures.append(f"{path}.structured_output_requested_inconsistent")
    if bools["logprobs_requested"] is False and bools["top_logprobs_requested"]:
        failures.append(f"{path}.logprobs_requested_inconsistent")
    if bools["unknown_request_fields_present"] != (bools["unknown_top_level_keys_present"] or bools["unknown_stream_option_keys_present"]):
        failures.append(f"{path}.unknown_request_fields_present_inconsistent")
    for key in ("requested_temperature", "requested_top_p", "requested_presence_penalty", "requested_frequency_penalty"):
        value = record.get(key)
        if not isinstance(value, (int, float)) or isinstance(value, bool) or not math.isfinite(value):
            failures.append(f"{path}.{key}:field_invalid")
    sanitized_geometry_keys = {
        "stop_sequence_utf8_length_buckets",
        "requested_top_k",
        "requested_min_p",
        "requested_presence_penalty",
        "requested_frequency_penalty",
        "requested_repetition_penalty",
        "logit_bias_geometry",
        "tool_count",
        "tool_choice_kind",
        "tool_message_count",
        "assistant_tool_call_count",
        "response_schema_geometry",
        "anonymous_cache_group_sha256",
    }
    sanitized_geometry = {key: record.get(key) for key in sanitized_geometry_keys if key in record}
    requested_n = _require_count(record, "requested_n", path, failures, positive=True)
    response_format_kind = record.get("response_format_kind")
    if response_format_kind not in {"text", "json_object", "json_schema"}:
        failures.append(f"{path}.response_format_kind:field_invalid")
    stop_sequences = _require_count(record, "stop_sequences", path, failures)
    if failures:
        return None, failures
    return CapturedShape(
        shape_id=record["shape_id"],
        prompt_tokens=prompt_tokens,
        completion_tokens=completion_tokens,
        requested_max_completion_tokens=requested_max_completion_tokens,
        effective_max_output_tokens=effective_max_output_tokens,
        conversation_key_present=key_present,
        conversation_key_cache_only=cache_only,
        conversation_cache_lease=lease,
        conversation_cache_cached_prompt_tokens=cached_tokens,
        conversation_cache_retained_handoff=retained,
        stop_sequences=stop_sequences,
        requested_temperature=float(record["requested_temperature"]),
        requested_top_p=float(record["requested_top_p"]),
        requested_n=requested_n,
        response_format_kind=response_format_kind,
        captured_pre_capacity_selector_reason=captured_reason,
        captured_pre_capacity_eligible=captured_eligible,
        sanitized_geometry=sanitized_geometry,
        **bools,
    ), []


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
            elif record.get("record_type") == "request_shape":
                shape, shape_failures = _shape_from_record(record, f"{path}:{lineno}:shape")
                failures.extend(shape_failures)
                if shape is not None:
                    shapes.append(shape)
            else:
                failures.append(f"{path}:{lineno}:record_type_invalid")
    if header is None:
        failures.append("missing_header")
    else:
        missing = sorted(CAPTURE_HEADER_KEYS - set(header))
        if missing:
            failures.append("header_missing_fields:" + ",".join(missing))
        if header.get("native_mtp_mode") != "off" or header.get("capture_requires_native_mtp_off") is not True:
            failures.append("header_capture_not_mtp_off")
        for key in ("captured_at",):
            if not (isinstance(header.get(key), str) and ISO_DATEISH.match(header[key])):
                failures.append(f"header_{key}_invalid")
        for key in ("max_records", "max_bytes"):
            if not (_is_count(header.get(key)) and header[key] > 0):
                failures.append(f"header_{key}_invalid")
    if not shapes:
        failures.append("missing_shapes")
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
        for key in TUPLE_KEYS - {"maximum_prompt_tokens", "maximum_completion_tokens", "maximum_proposal_depth", "request_feature_profile"}:
            if not isinstance(value.get(key), bool):
                failures.append(f"tuple.{key}:field_invalid")
    if failures:
        raise ValueError("tuple bounds invalid: " + "; ".join(sorted(set(failures))))
    return value


def _sampler_supports(temperature: float, top_p: float) -> bool:
    return math.isfinite(temperature) and temperature >= 0 and math.isfinite(top_p) and 0 <= top_p <= 1


def selector_reason(shape: CapturedShape, tuple_bounds: dict) -> str:
    if not tuple_bounds["has_qualified_row_mapped_transactions"]:
        return "capability_mismatch"
    if not tuple_bounds["revocation_state_available"]:
        return "revocation_state_unavailable"
    if tuple_bounds["tuple_revoked"]:
        return "tuple_revoked"
    if not tuple_bounds["tuple_admitted"]:
        return "tuple_not_admitted"
    if not tuple_bounds["supports_current_processor"]:
        return "unsupported_processor"
    if not tuple_bounds["supports_current_state_cache"]:
        return "unsupported_state_cache"
    if shape.stream and not tuple_bounds["supports_streaming"]:
        return "capability_mismatch"
    if not shape.stream and not tuple_bounds["supports_non_streaming"]:
        return "capability_mismatch"
    if tuple_bounds["maximum_proposal_depth"] <= 0:
        return "insufficient_verification_capacity"
    if (
        shape.requested_max_completion_tokens is not None
        and shape.requested_max_completion_tokens > tuple_bounds["maximum_completion_tokens"]
    ):
        return "capability_mismatch"
    if shape.stop_sequences > 0 and not tuple_bounds["supports_stop_sequences"]:
        return "capability_mismatch"
    if shape.unknown_request_fields_present:
        return "unknown_request_field"
    if shape.sampling_requested and (
        tuple_bounds["request_feature_profile"] != "native_mtp_sampled_text_v1"
        or not _sampler_supports(shape.requested_temperature, shape.requested_top_p)
    ):
        return "sampling"
    if shape.multiple_completions_requested:
        return "multiple_completions"
    if (
        shape.presence_penalty_nonzero
        or shape.frequency_penalty_nonzero
        or shape.top_k_present
        or shape.min_p_nonzero
        or shape.repetition_penalty_nondefault
    ):
        return "logit_controls"
    if shape.conversation_key_present and not shape.conversation_key_cache_only:
        return "conversation_key"
    if shape.multimodal_requested:
        return "multimodal"
    if shape.structured_output_requested:
        return "structured_output"
    if shape.tools_present:
        return "tools"
    if shape.logprobs_requested:
        return "logprobs"
    if shape.logit_bias_present:
        return "logit_controls"
    if shape.reasoning_or_template_model:
        return "reasoning_or_template"
    if shape.conversation_key_present and shape.conversation_key_cache_only:
        if shape.conversation_cache_lease == "miss" and shape.conversation_cache_cached_prompt_tokens == 0 and not shape.conversation_cache_retained_handoff:
            return _eligible_or_bound_mismatch(shape, tuple_bounds)
        return "conversation_key"
    return _eligible_or_bound_mismatch(shape, tuple_bounds)


def _eligible_or_bound_mismatch(shape: CapturedShape, tuple_bounds: dict) -> str:
    if shape.prompt_tokens > tuple_bounds["maximum_prompt_tokens"]:
        return "capability_mismatch"
    if shape.effective_max_output_tokens > tuple_bounds["maximum_completion_tokens"]:
        return "capability_mismatch"
    return "eligible"


def analyzer_shape_template(shape: CapturedShape, tuple_bounds: dict) -> dict:
    reason = selector_reason(shape, tuple_bounds)
    result = {
        "shape_id": shape.shape_id,
        "conversation_key_present": shape.conversation_key_present,
        "completion_tokens": shape.completion_tokens,
        "pre_capacity_selector_reason": reason,
        "pre_capacity_eligible": reason == "eligible",
        "effective_path": "PENDING_ACTUAL_REPLAY_PATH",
    }
    if shape.conversation_key_present:
        result["conversation_key_cache_only"] = shape.conversation_key_cache_only
        if shape.conversation_key_cache_only:
            result["conversation_cache_lease"] = shape.conversation_cache_lease
            result["conversation_cache_cached_prompt_tokens"] = shape.conversation_cache_cached_prompt_tokens
            result["conversation_cache_retained_handoff"] = shape.conversation_cache_retained_handoff
    return result


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
    sampling_plan_id: str,
    sample_period_start: str,
    sample_period_end: str,
) -> tuple[dict, dict]:
    if blocks < MIN_BLOCKS:
        raise ValueError(f"blocks must be >= {MIN_BLOCKS}")
    if not (SAFE_ID.match(sampling_plan_id) and ISO_DATEISH.match(sample_period_start) and ISO_DATEISH.match(sample_period_end)):
        raise ValueError("invalid sampling plan metadata")
    capture_header, shapes = load_capture(capture_path)
    tuple_bounds = load_tuple_bounds(tuple_bounds_path)
    capture_mode_mismatches = []
    for shape in shapes:
        if shape.captured_pre_capacity_selector_reason != "mode_off":
            capture_mode_mismatches.append(f"{shape.shape_id}:selector_reason={shape.captured_pre_capacity_selector_reason}")
        if shape.captured_pre_capacity_eligible:
            capture_mode_mismatches.append(f"{shape.shape_id}:captured_eligible_under_mtp_off")
    if capture_mode_mismatches:
        raise ValueError("capture did not prove native-MTP-off ordinary service: " + "; ".join(capture_mode_mismatches))
    sample_projection = [
        {
            "shape_id": shape.shape_id,
            "prompt_tokens": shape.prompt_tokens,
            "completion_tokens": shape.completion_tokens,
            "requested_max_completion_tokens": shape.requested_max_completion_tokens,
            "effective_max_output_tokens": shape.effective_max_output_tokens,
            "conversation_key_present": shape.conversation_key_present,
            "conversation_key_cache_only": shape.conversation_key_cache_only,
            "conversation_cache_lease": shape.conversation_cache_lease,
            "conversation_cache_cached_prompt_tokens": shape.conversation_cache_cached_prompt_tokens,
            "conversation_cache_retained_handoff": shape.conversation_cache_retained_handoff,
            "stream": shape.stream,
            "stop_sequences": shape.stop_sequences,
            "requested_temperature": shape.requested_temperature,
            "requested_top_p": shape.requested_top_p,
            "requested_n": shape.requested_n,
            **shape.sanitized_geometry,
            "sampling_requested": shape.sampling_requested,
            "multiple_completions_requested": shape.multiple_completions_requested,
            "top_k_present": shape.top_k_present,
            "min_p_nonzero": shape.min_p_nonzero,
            "frequency_penalty_nonzero": shape.frequency_penalty_nonzero,
            "presence_penalty_nonzero": shape.presence_penalty_nonzero,
            "repetition_penalty_nondefault": shape.repetition_penalty_nondefault,
            "logit_bias_present": shape.logit_bias_present,
            "tools_present": shape.tools_present,
            "tool_choice_present": shape.tool_choice_present,
            "tool_turn_state_present": shape.tool_turn_state_present,
            "structured_output_requested": shape.structured_output_requested,
            "response_format_kind": shape.response_format_kind,
            "logprobs_requested": shape.logprobs_requested,
            "top_logprobs_requested": shape.top_logprobs_requested,
            "logit_controls_requested": shape.logit_controls_requested,
            "reasoning_or_template_model": shape.reasoning_or_template_model,
            "multimodal_requested": shape.multimodal_requested,
            "unknown_request_fields_present": shape.unknown_request_fields_present,
            "unknown_top_level_keys_present": shape.unknown_top_level_keys_present,
            "unknown_stream_option_keys_present": shape.unknown_stream_option_keys_present,
            "pre_capacity_selector_reason": selector_reason(shape, tuple_bounds),
            **shape.sanitized_geometry,
        }
        for shape in shapes
    ]
    sample_digest = _digest(sample_projection)
    policy = build_policy(privacy_review_id, privacy_reviewed_at, preregistration_digest, sample_digest, seed)
    policy_sha = _digest(policy)
    request_shapes = [analyzer_shape_template(shape, tuple_bounds) for shape in shapes]
    plan = {
        "schema": PLAN_SCHEMA,
        "qualification_status": "PENDING_REAL_LAB_REPLAY",
        "policy_sha256": policy_sha,
        "sample_digest_sha256": sample_digest,
        "source_capture_sha256": _sha256_file(capture_path),
        "tuple_bounds_sha256": _sha256_file(tuple_bounds_path),
        "projection_stage": "offline_sanitized_shape_projection_only",
        "capture_schema": CAPTURE_SCHEMA,
        "capture_header": {
            "captured_at": capture_header["captured_at"],
            "native_mtp_mode": capture_header["native_mtp_mode"],
            "capture_requires_native_mtp_off": capture_header["capture_requires_native_mtp_off"],
            "served_identity": capture_header["served_identity"],
            "build_source_commit": capture_header["build_source_commit"],
            "build_cdhash": capture_header["build_cdhash"],
            "cli_version": capture_header["cli_version"],
        },
        "sample_report": {
            "sampling_plan_id": sampling_plan_id,
            "sample_period_start": sample_period_start,
            "sample_period_end": sample_period_end,
            "captured_request_count": len(shapes),
            "captured_completion_tokens": sum(shape.completion_tokens for shape in shapes),
            "projected_request_count_per_block": len(shapes),
            "representativeness_claim": "bounded preregistered captured counts only; no population representativeness inferred",
        },
        "replay_requirements": {
            "status": "PENDING",
            "reason": "offline projection cannot qualify SPEC-048-R015 performance evidence",
            "must_provide": [
                "distinct native-MTP-disabled and native-MTP-mixed execution modes",
                "actual per-request effective path, capacity, lease, and retained-handoff proof",
                "committed tokenizer token counts and token timestamps, not SSE-event counts",
                "mixed-mode concurrent row scheduling evidence",
                "cache-group warm/order proof or explicit fail-closed unknown-cache disposition",
                "analyzer JSONL blocks populated by the real lab runner only",
            ],
        },
        "blocks": [
            {
                "block_index": block_index,
                "request_shape_templates": request_shapes,
                "metrics_status": "PENDING_REAL_REPLAY",
            }
            for block_index in range(blocks)
        ],
    }
    return policy, plan


def _load_jsonl_records(path: Path) -> list[dict]:
    records: list[dict] = []
    with path.open("r", encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, 1):
            line = line.strip()
            if not line:
                continue
            record = _strict_loads(line)
            if not isinstance(record, dict):
                raise ValueError(f"{path}:{lineno}:record_not_object")
            records.append(record)
    if not records:
        raise ValueError("replay evidence empty")
    return records


def _is_positive_number(value: object) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) and value > 0


def _p95(values: list[float]) -> float:
    if not values:
        raise ValueError("missing timing samples")
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    pos = (len(ordered) - 1) * 0.95
    lo = math.floor(pos)
    hi = math.ceil(pos)
    if lo == hi:
        return ordered[lo]
    return ordered[lo] + (ordered[hi] - ordered[lo]) * (pos - lo)


def _load_policy_for_analyzer(path: Path) -> tuple[dict, str]:
    policy = _read_json(path)
    if not isinstance(policy, dict):
        raise ValueError("policy must be an object")
    failures = _strict_object(policy, {
        "schema",
        "issue",
        "confidence_method",
        "preregistration_digest_sha256",
        "privacy_review_id",
        "privacy_reviewed_at",
        "sample_digest_sha256",
        "seed",
        "bootstrap_draws",
        "alpha",
        "min_paired_blocks",
        "thresholds",
    }, "policy")
    failures.extend(_privacy_violations(policy, "policy"))
    if policy.get("schema") != POLICY_SCHEMA:
        failures.append("policy_schema_invalid")
    for key in ("sample_digest_sha256", "preregistration_digest_sha256"):
        if not (isinstance(policy.get(key), str) and HEX64.match(policy[key])):
            failures.append(f"policy.{key}:field_invalid")
    if not (isinstance(policy.get("privacy_review_id"), str) and SAFE_ID.match(policy["privacy_review_id"])):
        failures.append("policy.privacy_review_id:field_invalid")
    if failures:
        raise ValueError("policy invalid: " + "; ".join(sorted(set(failures))))
    return policy, _sha256_file(path)


def _load_replay_runs(path: Path, policy: dict, policy_sha: str, capture_sha256: str | None) -> tuple[dict, list[dict]]:
    records = _load_jsonl_records(path)
    if records[0].get("schema") == PLAN_SCHEMA or records[0].get("projection_stage") == "offline_sanitized_shape_projection_only":
        raise ValueError("replay evidence is projection-only, not actual NativeMTPRequestShapeReplayCommand output")
    header: dict | None = None
    runs: list[dict] = []
    failures: list[str] = []
    for index, record in enumerate(records, 1):
        if record.get("schema") != REPLAY_RESULT_SCHEMA:
            failures.append(f"line {index}:schema_invalid")
            continue
        record_type = record.get("record_type")
        if record_type == "header":
            if header is not None:
                failures.append(f"line {index}:duplicate_header")
            failures.extend(_strict_object(record, REPLAY_HEADER_KEYS, f"line {index}:header"))
            header = record
        elif record_type == "run":
            failures.extend(_strict_object(record, REPLAY_RUN_KEYS, f"line {index}:run"))
            runs.append(record)
        elif record_type == "pending" or record.get("status") == "pending":
            failures.append(f"line {index}:pending_replay_result")
        else:
            failures.append(f"line {index}:record_type_invalid")
    if header is None:
        failures.append("missing_replay_header")
    else:
        if header.get("policy_sha256") != policy_sha:
            failures.append("header_policy_sha256_mismatch")
        for key in ("sample_digest_sha256", "preregistration_digest_sha256", "privacy_review_id"):
            if header.get(key) != policy.get(key):
                failures.append(f"header_policy_field_mismatch:{key}")
        if not (isinstance(header.get("bench_policy_sha256"), str) and HEX64.match(header["bench_policy_sha256"])):
            failures.append("header_bench_policy_sha256_invalid")
        if capture_sha256 is not None and header.get("capture_sha256") != capture_sha256:
            failures.append("header_capture_sha256_mismatch")
        if header.get("capture_schema") != CAPTURE_SCHEMA or header.get("capture_requires_native_mtp_off") is not True:
            failures.append("header_capture_binding_invalid")
        if header.get("exports_raw_prompt_text") is not False or header.get("exports_recoverable_cache_groups") is not False:
            failures.append("header_privacy_exports_invalid")
        if header.get("run_order") != "paired_random_counterbalanced":
            failures.append("header_run_order_invalid")
        if header.get("cache_key_scope") != "paired_block_and_path_isolated":
            failures.append("header_cache_key_scope_invalid")
        if header.get("completion_length_binding") != EXPECTED_COMPLETION_LENGTH_BINDING:
            failures.append("header_completion_length_binding_invalid")
        if header.get("target_stop_control") != EXPECTED_TARGET_STOP_CONTROL:
            failures.append("header_target_stop_control_invalid")
        if not isinstance(header.get("synthetic_stand_ins"), dict):
            failures.append("header_synthetic_stand_ins_invalid")
        if not (_is_count(header.get("mixed_rows")) and header["mixed_rows"] > 0):
            failures.append("header_mixed_rows_invalid")
        if not (_is_count(header.get("max_native_active_rows")) and header["max_native_active_rows"] > 0):
            failures.append("header_max_native_active_rows_invalid")
        request_shapes = header.get("request_shapes")
        if not isinstance(request_shapes, list) or not request_shapes:
            failures.append("header_request_shapes_invalid")
        if not (_is_count(header.get("sample_filter_included_count")) and header["sample_filter_included_count"] == len(request_shapes or [])):
            failures.append("header_sample_filter_included_count_invalid")
        if not _is_count(header.get("sample_filter_excluded_count")):
            failures.append("header_sample_filter_excluded_count_invalid")
    if not runs:
        failures.append("missing_replay_runs")
    for run_index, run in enumerate(runs):
        if run.get("policy_sha256") != policy_sha:
            failures.append(f"run[{run_index}]:policy_sha256_mismatch")
        if header is not None and run.get("bench_policy_sha256") != header.get("bench_policy_sha256"):
            failures.append(f"run[{run_index}]:bench_policy_sha256_mismatch")
        if header is not None and run.get("capture_sha256") != header.get("capture_sha256"):
            failures.append(f"run[{run_index}]:capture_sha256_mismatch")
        if run.get("path") not in ANALYZER_PATHS:
            failures.append(f"run[{run_index}]:path_invalid")
        if not _is_count(run.get("block_index")):
            failures.append(f"run[{run_index}]:block_index_invalid")
        if not _is_positive_number(run.get("wall_seconds")):
            failures.append(f"run[{run_index}]:wall_seconds_invalid")
        if not _is_positive_number(run.get("ordinary_observed_interval_seconds")):
            failures.append(f"run[{run_index}]:ordinary_observed_interval_seconds_invalid")
        if run.get("qualification_status") != "qualified":
            failures.append(f"run[{run_index}]:qualification_status_not_qualified")
        if run.get("sample_coverage_complete") is not True:
            failures.append(f"run[{run_index}]:sample_coverage_incomplete")
        if run.get("admission_observation_complete") is not True or run.get("missing_admission_request_ids") != []:
            failures.append(f"run[{run_index}]:admission_observation_incomplete")
        if run.get("target_completion_observation_complete") is not True or run.get("target_completion_mismatch_request_ids") != []:
            failures.append(f"run[{run_index}]:target_completion_observation_incomplete")
        if run.get("committed_timing_observation_complete") is not True:
            failures.append(f"run[{run_index}]:committed_timing_observation_incomplete")
        for key in ("completion_tokens_by_request", "admission_projection"):
            if not isinstance(run.get(key), list) or not run[key]:
                failures.append(f"run[{run_index}]:{key}_invalid")
        if "effective_paths" in run and not isinstance(run.get("effective_paths"), list):
            failures.append(f"run[{run_index}]:effective_paths_invalid")
    if failures:
        raise ValueError("replay evidence invalid: " + "; ".join(sorted(set(failures))))
    return header or {}, runs


def _request_shape_for_analyzer(shape: object, header: dict) -> dict:
    failures = _strict_object(shape, REPLAY_SHAPE_KEYS, "request_shape")
    if not isinstance(shape, dict):
        raise ValueError("request_shape invalid: " + "; ".join(failures))
    failures.extend(_privacy_violations(shape, "request_shape"))
    shape_id = shape.get("shape_id")
    if not (isinstance(shape_id, str) and SAFE_ID.match(shape_id)):
        failures.append("shape_id_invalid")
    served_model = shape.get("served_model_hash_sha256")
    served_weights = shape.get("served_weights_manifest_sha256")
    if not (isinstance(served_model, str) and HEX64.match(served_model)):
        failures.append("served_model_hash_sha256_invalid")
    elif served_model != header.get("target_sha256"):
        failures.append("served_model_hash_sha256_not_target")
    if not (isinstance(served_weights, str) and HEX64.match(served_weights)):
        failures.append("served_weights_manifest_sha256_invalid")
    target_completion_tokens = shape.get("target_completion_tokens")
    if not (_is_count(target_completion_tokens) and target_completion_tokens > 0):
        failures.append("target_completion_tokens_invalid")
    key_present = shape.get("conversation_key_present")
    cache_only = shape.get("conversation_key_cache_only")
    lease = shape.get("conversation_cache_lease")
    cached = shape.get("conversation_cache_cached_prompt_tokens")
    retained = shape.get("conversation_cache_retained_handoff")
    if not isinstance(key_present, bool):
        failures.append("conversation_key_present_invalid")
    if not isinstance(cache_only, bool):
        failures.append("conversation_key_cache_only_invalid")
    if lease not in LEASE_STATES:
        failures.append("conversation_cache_lease_invalid")
    if not _is_count(cached):
        failures.append("conversation_cache_cached_prompt_tokens_invalid")
    if not isinstance(retained, bool):
        failures.append("conversation_cache_retained_handoff_invalid")
    if key_present is False:
        if cache_only or lease != "not_applicable" or cached != 0 or retained:
            failures.append("cache_proof_inconsistent_without_key")
    elif key_present is True and cache_only is True:
        if lease == "not_applicable":
            failures.append("cache_only_lease_missing")
        if lease in {"miss", "missing"} and cached != 0:
            failures.append(f"cache_{lease}_with_cached_prompt_tokens")
        if lease == "hit" and cached <= 0:
            failures.append("cache_hit_without_cached_prompt_tokens")
    elif key_present is True:
        if lease != "not_applicable" or cached != 0 or retained:
            failures.append("sticky_key_with_cache_proof")
    if shape.get("effective_path") != "ordinary":
        failures.append("capture_shape_effective_path_not_ordinary")
    if failures:
        raise ValueError("request_shape invalid: " + "; ".join(sorted(set(failures))))
    result = {
        "shape_id": shape_id,
        "conversation_key_present": key_present,
        "completion_tokens": target_completion_tokens,
        "pre_capacity_selector_reason": "PENDING_ACTUAL_ADMISSION",
        "pre_capacity_eligible": False,
        "effective_path": "PENDING_ACTUAL_PATH",
    }
    if key_present:
        result.update({
            "conversation_key_cache_only": cache_only,
            "conversation_cache_lease": lease,
            "conversation_cache_cached_prompt_tokens": cached,
            "conversation_cache_retained_handoff": retained,
        })
    return result


def _indexed_completion_timings(run: dict, run_label: str) -> dict[str, dict]:
    timings: dict[str, dict] = {}
    failures: list[str] = []
    for index, item in enumerate(run.get("completion_tokens_by_request", [])):
        failures.extend(_strict_object(item, REPLAY_COMPLETION_KEYS, f"{run_label}.completion[{index}]"))
        if not isinstance(item, dict):
            continue
        request_id = item.get("request_id")
        if not (isinstance(request_id, str) and SAFE_ID.match(request_id)):
            failures.append(f"{run_label}.completion[{index}]:request_id_invalid")
            continue
        if request_id in timings:
            failures.append(f"{run_label}.completion[{index}]:duplicate_request_id")
        target_tokens = item.get("target_completion_tokens")
        completion_tokens = item.get("completion_tokens")
        committed_events = item.get("committed_timing_events")
        ttft = item.get("ttft_seconds")
        gaps = item.get("inter_token_gaps")
        if not (_is_count(target_tokens) and target_tokens > 0):
            failures.append(f"{run_label}.completion[{index}]:target_completion_tokens_invalid")
        if not (_is_count(completion_tokens) and completion_tokens > 0):
            failures.append(f"{run_label}.completion[{index}]:completion_tokens_invalid")
        if completion_tokens != target_tokens or item.get("target_completion_matched") is not True:
            failures.append(f"{run_label}.completion[{index}]:target_completion_mismatch")
        target_stop = item.get("target_stop_triggered")
        if target_stop is not True and target_stop is not False:
            failures.append(f"{run_label}.completion[{index}]:target_stop_triggered_invalid")
        if committed_events != completion_tokens:
            failures.append(f"{run_label}.completion[{index}]:committed_timing_events_mismatch")
        if not _is_positive_number(ttft):
            failures.append(f"{run_label}.completion[{index}]:ttft_seconds_invalid")
        if not isinstance(gaps, list) or len(gaps) != max(int(completion_tokens or 0) - 1, 0):
            failures.append(f"{run_label}.completion[{index}]:inter_token_gaps_incomplete")
        elif any(not _is_positive_number(gap) for gap in gaps):
            failures.append(f"{run_label}.completion[{index}]:inter_token_gaps_invalid")
        timings[request_id] = item
    if failures:
        raise ValueError("replay timing invalid: " + "; ".join(sorted(set(failures))))
    return timings


def _admission_rows(run: dict, run_label: str) -> list[dict]:
    failures: list[str] = []
    rows: list[dict] = []
    seen: set[str] = set()
    for index, item in enumerate(run.get("admission_projection", [])):
        failures.extend(_strict_object(item, REPLAY_ADMISSION_KEYS, f"{run_label}.admission[{index}]"))
        if not isinstance(item, dict):
            continue
        request_id = item.get("request_id")
        shape_id = item.get("shape_id")
        if not (isinstance(request_id, str) and SAFE_ID.match(request_id)):
            failures.append(f"{run_label}.admission[{index}]:request_id_invalid")
        elif request_id in seen:
            failures.append(f"{run_label}.admission[{index}]:duplicate_request_id")
        else:
            seen.add(request_id)
        if not (isinstance(shape_id, str) and SAFE_ID.match(shape_id)):
            failures.append(f"{run_label}.admission[{index}]:shape_id_invalid")
        if item.get("pending_reason") not in {None, ""}:
            failures.append(f"{run_label}.admission[{index}]:row_pending")
        if item.get("reproduced") is not True:
            failures.append(f"{run_label}.admission[{index}]:row_unreproduced")
        if item.get("actual_selector_reason") in {None, "missing"} or item.get("actual_effective_path") in {None, "missing"}:
            failures.append(f"{run_label}.admission[{index}]:actual_admission_missing")
        if item.get("matches") is not True:
            failures.append(f"{run_label}.admission[{index}]:actual_admission_mismatch")
        if item.get("actual_effective_path") not in {"ordinary", "native_mtp"}:
            failures.append(f"{run_label}.admission[{index}]:actual_effective_path_invalid")
        if not isinstance(item.get("actual_selector_reason"), str):
            failures.append(f"{run_label}.admission[{index}]:actual_selector_reason_invalid")
        if not (_is_count(item.get("target_completion_tokens")) and item["target_completion_tokens"] > 0):
            failures.append(f"{run_label}.admission[{index}]:target_completion_tokens_invalid")
        rows.append(item)
    if failures:
        raise ValueError("replay admission invalid: " + "; ".join(sorted(set(failures))))
    return rows


def _metrics_from_run(run: dict, ordinary_request_ids: set[str], run_label: str) -> dict:
    timings = _indexed_completion_timings(run, run_label)
    wall_seconds = float(run["wall_seconds"])
    if set(timings) != {row["request_id"] for row in _admission_rows(run, run_label)}:
        raise ValueError(f"replay timing invalid: {run_label}:timing_admission_request_id_mismatch")
    if not ordinary_request_ids:
        raise ValueError(f"replay timing invalid: {run_label}:missing_ordinary_rows")
    if not ordinary_request_ids.issubset(timings):
        raise ValueError(f"replay timing invalid: {run_label}:ordinary_timing_missing")
    ordinary_timings = [timings[request_id] for request_id in sorted(ordinary_request_ids)]
    ordinary_tokens = sum(int(item["completion_tokens"]) for item in ordinary_timings)
    ordinary_gaps = [float(gap) for item in ordinary_timings for gap in item["inter_token_gaps"]]
    if not ordinary_gaps:
        raise ValueError(f"replay timing invalid: {run_label}:ordinary_inter_token_gaps_missing")
    if not _is_positive_number(run.get("ordinary_observed_throughput_tps")):
        raise ValueError(f"replay timing invalid: {run_label}:ordinary_observed_throughput_tps_invalid")
    if not _is_positive_number(run.get("aggregate_throughput_tps")):
        raise ValueError(f"replay timing invalid: {run_label}:aggregate_throughput_tps_invalid")
    ordinary_reported_tokens = run.get("ordinary_observed_completion_tokens")
    if not (_is_count(ordinary_reported_tokens) and ordinary_reported_tokens == ordinary_tokens):
        raise ValueError(f"replay timing invalid: {run_label}:ordinary_observed_completion_tokens_mismatch")
    ordinary_interval = float(run["ordinary_observed_interval_seconds"])
    if not (0 < ordinary_interval <= wall_seconds):
        raise ValueError(f"replay timing invalid: {run_label}:ordinary_observed_interval_invalid")
    expected_ordinary_tps = float(ordinary_reported_tokens) / ordinary_interval
    if not math.isclose(float(run["ordinary_observed_throughput_tps"]), expected_ordinary_tps, rel_tol=1e-9, abs_tol=1e-9):
        raise ValueError(f"replay timing invalid: {run_label}:ordinary_observed_throughput_tps_mismatch")
    aggregate_tokens = sum(int(item["completion_tokens"]) for item in timings.values())
    if run.get("aggregate_completion_tokens") != aggregate_tokens:
        raise ValueError(f"replay timing invalid: {run_label}:aggregate_completion_tokens_mismatch")
    expected_aggregate_tps = float(aggregate_tokens) / wall_seconds
    if not math.isclose(float(run["aggregate_throughput_tps"]), expected_aggregate_tps, rel_tol=1e-9, abs_tol=1e-9):
        raise ValueError(f"replay timing invalid: {run_label}:aggregate_throughput_tps_mismatch")
    return {
        "ordinary_row_p95_ttft_seconds": _p95([float(item["ttft_seconds"]) for item in ordinary_timings]),
        "ordinary_row_p95_itl_seconds": _p95(ordinary_gaps),
        "ordinary_row_throughput_tps": float(run["ordinary_observed_throughput_tps"]),
        "end_to_end_aggregate_throughput_tps": float(run["aggregate_throughput_tps"]),
    }


def convert_replay_to_analyzer_jsonl(
    replay_path: Path,
    policy_path: Path,
    *,
    capture_sha256: str | None = None,
) -> list[dict]:
    policy, policy_sha = _load_policy_for_analyzer(policy_path)
    header, runs = _load_replay_runs(replay_path, policy, policy_sha, capture_sha256)
    shape_templates_by_id: dict[str, dict] = {}
    ordered_shape_ids: list[str] = []
    for shape in header["request_shapes"]:
        template = _request_shape_for_analyzer(shape, header)
        shape_id = template["shape_id"]
        if shape_id in shape_templates_by_id:
            raise ValueError(f"replay header duplicate shape_id: {shape_id}")
        shape_templates_by_id[shape_id] = template
        ordered_shape_ids.append(shape_id)
    by_block: dict[int, dict[str, dict]] = {}
    for run in runs:
        block_runs = by_block.setdefault(run["block_index"], {})
        if run["path"] in block_runs:
            raise ValueError(f"replay conversion invalid: block {run['block_index']}:duplicate_path:{run['path']}")
        block_runs[run["path"]] = run
    records: list[dict] = [{
        "schema": ANALYZER_JSONL_SCHEMA,
        "record_type": "header",
        "policy_sha256": policy_sha,
        "sample_digest_sha256": policy["sample_digest_sha256"],
        "preregistration_digest_sha256": policy["preregistration_digest_sha256"],
        "privacy_review_id": policy["privacy_review_id"],
    }]
    failures: list[str] = []
    for block_index in sorted(by_block):
        paths = by_block[block_index]
        missing = sorted(set(ANALYZER_PATHS) - set(paths))
        if missing:
            failures.append(f"block {block_index}:missing_path:{','.join(missing)}")
            continue
        extra = sorted(set(paths) - set(ANALYZER_PATHS))
        if extra:
            failures.append(f"block {block_index}:extra_path:{','.join(extra)}")
            continue
        mixed_rows = _admission_rows(paths["native_mtp"], f"block[{block_index}].native_mtp")
        disabled_rows = _admission_rows(paths["ordinary"], f"block[{block_index}].ordinary")
        mixed_by_shape: dict[str, list[dict]] = {}
        disabled_by_shape: dict[str, list[dict]] = {}
        for row in mixed_rows:
            mixed_by_shape.setdefault(row["shape_id"], []).append(row)
        for row in disabled_rows:
            disabled_by_shape.setdefault(row["shape_id"], []).append(row)
        if set(mixed_by_shape) != set(ordered_shape_ids) or set(disabled_by_shape) != set(ordered_shape_ids):
            failures.append(f"block {block_index}:shape_set_mismatch")
            continue
        analyzer_shapes_mixed: list[dict] = []
        analyzer_shapes_disabled: list[dict] = []
        block_failed = False
        for shape_id in ordered_shape_ids:
            if len(mixed_by_shape[shape_id]) != 1 or len(disabled_by_shape[shape_id]) != 1:
                failures.append(f"block {block_index}:shape {shape_id}:replay_count_not_one_per_captured_row")
                block_failed = True
                continue
            mixed_actuals = {(row["actual_selector_reason"], row["actual_effective_path"], row["target_completion_tokens"]) for row in mixed_by_shape[shape_id]}
            disabled_actuals = {(row["actual_selector_reason"], row["actual_effective_path"], row["target_completion_tokens"]) for row in disabled_by_shape[shape_id]}
            if len(mixed_actuals) != 1 or len(disabled_actuals) != 1:
                failures.append(f"block {block_index}:shape {shape_id}:admission_not_stable")
                block_failed = True
                continue
            mixed_reason, mixed_path, mixed_tokens = next(iter(mixed_actuals))
            disabled_reason, disabled_path, disabled_tokens = next(iter(disabled_actuals))
            if disabled_reason != "mode_off" or disabled_path != "ordinary":
                failures.append(f"block {block_index}:shape {shape_id}:disabled_actual_path_invalid")
                block_failed = True
            if mixed_tokens != disabled_tokens or mixed_tokens != shape_templates_by_id[shape_id]["completion_tokens"]:
                failures.append(f"block {block_index}:shape {shape_id}:sample_completion_token_mismatch")
                block_failed = True
            eligible = mixed_reason == "eligible"
            if mixed_path == "native_mtp" and not eligible:
                failures.append(f"block {block_index}:shape {shape_id}:native_path_without_eligible_reason")
                block_failed = True
            if mixed_path == "ordinary" and eligible:
                failures.append(f"block {block_index}:shape {shape_id}:eligible_reason_without_native_path")
                block_failed = True
            base = dict(shape_templates_by_id[shape_id])
            base["pre_capacity_selector_reason"] = mixed_reason
            base["pre_capacity_eligible"] = eligible
            mixed_shape = dict(base)
            mixed_shape["effective_path"] = mixed_path
            disabled_shape = dict(base)
            disabled_shape["effective_path"] = "ordinary"
            analyzer_shapes_mixed.append(mixed_shape)
            analyzer_shapes_disabled.append(disabled_shape)
        if block_failed:
            continue
        disabled_ordinary_ids = {row["request_id"] for row in disabled_rows if row["actual_effective_path"] == "ordinary"}
        mixed_ordinary_ids = {row["request_id"] for row in mixed_rows if row["actual_effective_path"] == "ordinary"}
        disabled_metrics = _metrics_from_run(paths["ordinary"], disabled_ordinary_ids, f"block[{block_index}].ordinary")
        mixed_metrics = _metrics_from_run(paths["native_mtp"], mixed_ordinary_ids, f"block[{block_index}].native_mtp")
        for path_name, shapes, metrics in (
            ("mtp_disabled", analyzer_shapes_disabled, disabled_metrics),
            ("observed_mixed", analyzer_shapes_mixed, mixed_metrics),
        ):
            block = {
                "schema": ANALYZER_JSONL_SCHEMA,
                "record_type": "block",
                "policy_sha256": policy_sha,
                "block_index": block_index,
                "path": path_name,
                "request_shapes": shapes,
                **metrics,
            }
            failures.extend(_strict_object(block, ANALYZER_BLOCK_KEYS, f"block[{block_index}].{path_name}"))
            records.append(block)
    if failures:
        raise ValueError("replay conversion invalid: " + "; ".join(sorted(set(failures))))
    return records


def write_replay_analyzer_jsonl(records: list[dict], output_path: Path) -> None:
    with output_path.open("w", encoding="utf-8") as fh:
        for record in records:
            fh.write(json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n")

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
    project.add_argument("--sampling-plan-id", default="r015-bounded-prospective-sample")
    project.add_argument("--sample-period-start", required=True)
    project.add_argument("--sample-period-end", required=True)
    project.add_argument("--seed", type=int, default=48015)
    project.add_argument("--blocks", type=int, default=MIN_BLOCKS)
    run = sub.add_parser("run")
    run.add_argument("--plan", type=Path, required=False)
    convert = sub.add_parser("convert")
    convert.add_argument("--replay", type=Path, required=True)
    convert.add_argument("--policy", type=Path, required=True)
    convert.add_argument("--out", type=Path, required=True)
    convert.add_argument("--capture-sha256", required=False)
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
                sampling_plan_id=args.sampling_plan_id,
                sample_period_start=args.sample_period_start,
                sample_period_end=args.sample_period_end,
            )
            _write_json(args.policy_out, policy)
            _write_json(args.plan_out, plan)
        elif args.cmd == "convert":
            records = convert_replay_to_analyzer_jsonl(args.replay, args.policy, capture_sha256=args.capture_sha256)
            write_replay_analyzer_jsonl(records, args.out)
            print(json.dumps({"status": "OK", "records": len(records)}, sort_keys=True))
            return 0
        else:
            print(json.dumps({"status": "PENDING", "error": "replay runner disabled until real lab mode/path/token/cache proof exists"}, sort_keys=True))
            return 2
    except Exception as exc:
        print(json.dumps({"status": "FAIL", "error": str(exc)}, sort_keys=True))
        return 1
    print(json.dumps({"status": "PENDING", "reason": "projection only; real replay evidence still required"}, sort_keys=True))
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
