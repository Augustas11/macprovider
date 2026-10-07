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
    "max_completion_tokens_requested",
    "requested_max_completion_tokens",
    "resolved_max_completion_tokens",
    "captured_completion_tokens",
    "maximum_prompt_tokens",
    "maximum_completion_tokens",
    "conversation_cache_cached_prompt_tokens",
}
LEASE_STATES = {"not_applicable", "miss", "hit", "missing"}

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
    "requested_temperature",
    "requested_top_p",
    "requested_n",
    "requested_max_completion_tokens",
    "resolved_max_completion_tokens",
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
    "response_format_kind",
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
    "prompt_tokens",
    "completion_tokens",
    "generated_completion_tokens",
    "max_completion_tokens_requested",
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
    max_completion_tokens_requested: int
    resolved_max_completion_tokens: int
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
    max_completion_tokens_requested = _require_count(record, "max_completion_tokens_requested", path, failures)
    resolved_max_completion_tokens = _require_count(record, "resolved_max_completion_tokens", path, failures, positive=True)
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
    for key in ("requested_temperature", "requested_top_p"):
        value = record.get(key)
        if not isinstance(value, (int, float)) or isinstance(value, bool) or not math.isfinite(value):
            failures.append(f"{path}.{key}:field_invalid")
    requested_n = _require_count(record, "requested_n", path, failures, positive=True)
    _require_count(record, "requested_max_completion_tokens", path, failures)
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
        max_completion_tokens_requested=max_completion_tokens_requested,
        resolved_max_completion_tokens=resolved_max_completion_tokens,
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
    if shape.prompt_tokens > tuple_bounds["maximum_prompt_tokens"]:
        return "capability_mismatch"
    if shape.resolved_max_completion_tokens > tuple_bounds["maximum_completion_tokens"]:
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
            return "eligible"
        return "conversation_key"
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
            "max_completion_tokens_requested": shape.max_completion_tokens_requested,
            "resolved_max_completion_tokens": shape.resolved_max_completion_tokens,
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
