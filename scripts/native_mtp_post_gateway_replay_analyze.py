#!/usr/bin/env python3
"""Analyze SPEC-048-R015 post-gateway native-MTP eligibility replay evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import random
import re
import statistics
from collections import defaultdict
from pathlib import Path
from typing import Any

from scripts.native_mtp_r015_analyze import _holm_adjusted


POLICY_SCHEMA = "macprovider.native-mtp-post-gateway-replay-policy.v1"
JSONL_SCHEMA = "macprovider.native-mtp-post-gateway-replay.v1"
ANALYSIS_SCHEMA = "macprovider.native-mtp-post-gateway-replay-analysis.v1"

PATH_DISABLED = "mtp_disabled"
PATH_MIXED = "observed_mixed"
PATHS = (PATH_DISABLED, PATH_MIXED)

POLICY_KEYS = {
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
}
FROZEN_CONFIDENCE_METHOD = "paired_block_bootstrap_holm_v1"
FROZEN_BOOTSTRAP_DRAWS = 10000
FROZEN_ALPHA = 0.05
FROZEN_MIN_PAIRED_BLOCKS = 10
FROZEN_THRESHOLDS = {
    "min_eligible_request_fraction": 0.10,
    "min_eligible_completion_token_fraction": 0.10,
    "ordinary_row_ttft_p95_regression_upper_bound": 0.05,
    "ordinary_row_itl_p95_regression_upper_bound": 0.05,
    "ordinary_row_throughput_change_lower_bound": -0.05,
}
THRESHOLD_KEYS = {
    "min_eligible_request_fraction",
    "min_eligible_completion_token_fraction",
    "ordinary_row_ttft_p95_regression_upper_bound",
    "ordinary_row_itl_p95_regression_upper_bound",
    "ordinary_row_throughput_change_lower_bound",
}
HEADER_KEYS = {
    "schema",
    "record_type",
    "policy_sha256",
    "sample_digest_sha256",
    "preregistration_digest_sha256",
    "privacy_review_id",
}
BLOCK_KEYS = {
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
SHAPE_KEYS = {
    "shape_id",
    "conversation_key_present",
    "completion_tokens",
    "pre_capacity_selector_reason",
    "pre_capacity_eligible",
    "effective_path",
}
ELIGIBLE_REASON = "eligible"
SELECTOR_REASONS = {
    "eligible",
    "mode_off",
    "classic_draft_configured",
    "sampling",
    "multiple_completions",
    "tools",
    "structured_output",
    "logprobs",
    "logit_controls",
    "reasoning_or_template",
    "unknown_request_field",
    "conversation_key",
    "multimodal",
    "unsupported_processor",
    "unsupported_state_cache",
    "insufficient_verification_capacity",
    "capacity_above_native_bound",
    "capability_mismatch",
    "tuple_not_admitted",
    "tuple_revoked",
    "revocation_state_unavailable",
}
PRE_CAPACITY_REJECTED_REASONS = {
    "insufficient_verification_capacity",
    "capacity_above_native_bound",
}
EFFECTIVE_PATHS = {"ordinary", "native_mtp"}
HEX64 = re.compile(r"^[0-9a-f]{64}$")
ISO_DATEISH = re.compile(r"^\d{4}-\d{2}-\d{2}")
SAFE_ID = re.compile(r"^[A-Za-z0-9_.:-]{1,128}$")
PRIVATE_PATH_MARKERS = (
    "/Users/",
    "/private/",
    "/var/folders/",
    ".ssh/",
    "operator-secrets",
    "payout",
    "wallet",
)
SENSITIVE_KEY_PARTS = (
    "api_key",
    "authorization",
    "bearer",
    "credential",
    "password",
    "private_key",
    "secret",
    "token_value",
)
RAW_TEXT_KEY_PARTS = ("prompt", "message", "content")


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


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def _is_int(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _is_count(value: object) -> bool:
    return _is_int(value) and value >= 0


def _is_positive_number(value: object) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) and value > 0


def _is_fraction(value: object) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) and 0 <= value <= 1


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
            if lowered == "conversation_key":
                violations.append(f"raw_conversation_key_field:{path}.{key}")
            if lowered.startswith("conversation_key") and lowered != "conversation_key_present":
                violations.append(f"raw_conversation_key_field:{path}.{key}")
            if any(part in lowered for part in RAW_TEXT_KEY_PARTS):
                violations.append(f"raw_text_field:{path}.{key}")
            if any(part in lowered for part in SENSITIVE_KEY_PARTS):
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


def _load_policy(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as fh:
        value = _strict_loads(fh.read())
    if not isinstance(value, dict):
        raise ValueError("policy must be a JSON object")
    return value


def _load_jsonl(path: Path) -> tuple[dict, list[dict]]:
    header = None
    blocks: list[dict] = []
    with path.open("r", encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, 1):
            line = line.strip()
            if not line:
                continue
            record = _strict_loads(line)
            if not isinstance(record, dict):
                raise ValueError(f"{path}:{lineno}: record must be an object")
            if record.get("schema") != JSONL_SCHEMA:
                raise ValueError(f"{path}:{lineno}: unexpected schema {record.get('schema')!r}")
            if record.get("record_type") == "header":
                if header is not None:
                    raise ValueError("multiple header records")
                header = record
            elif record.get("record_type") == "block":
                blocks.append(record)
            else:
                raise ValueError(f"{path}:{lineno}: unexpected record_type {record.get('record_type')!r}")
    if header is None:
        raise ValueError("missing header record")
    return header, blocks


def _policy_violations(policy: dict) -> list[str]:
    violations = _strict_object(policy, POLICY_KEYS, "policy")
    violations.extend(_privacy_violations(policy))
    if policy.get("schema") != POLICY_SCHEMA:
        violations.append("policy_schema_invalid")
    if policy.get("issue") != "SPEC-048-R015-post-gateway-replay":
        violations.append("issue_invalid")
    if policy.get("confidence_method") != FROZEN_CONFIDENCE_METHOD:
        violations.append("methodology_not_frozen:confidence_method")
    for key in ("preregistration_digest_sha256", "sample_digest_sha256"):
        if not (isinstance(policy.get(key), str) and HEX64.match(policy[key])):
            violations.append(f"field_invalid:{key}")
    if not (isinstance(policy.get("privacy_review_id"), str) and SAFE_ID.match(policy["privacy_review_id"])):
        violations.append("field_invalid:privacy_review_id")
    if not (isinstance(policy.get("privacy_reviewed_at"), str) and ISO_DATEISH.match(policy["privacy_reviewed_at"])):
        violations.append("field_invalid:privacy_reviewed_at")
    for key, minimum in (("seed", 0), ("bootstrap_draws", 1), ("min_paired_blocks", 10)):
        if not (_is_int(policy.get(key)) and policy[key] >= minimum):
            violations.append(f"field_invalid:{key}")
    if policy.get("bootstrap_draws") != FROZEN_BOOTSTRAP_DRAWS:
        violations.append("field_not_frozen:bootstrap_draws")
    if policy.get("alpha") != FROZEN_ALPHA:
        violations.append("field_not_frozen:alpha")
    if policy.get("min_paired_blocks") != FROZEN_MIN_PAIRED_BLOCKS:
        violations.append("field_not_frozen:min_paired_blocks")
    thresholds = policy.get("thresholds")
    if not isinstance(thresholds, dict) or set(thresholds) != THRESHOLD_KEYS:
        violations.append("thresholds_key_set_invalid")
    else:
        if not _is_fraction(policy.get("alpha")) or policy["alpha"] <= 0:
            violations.append("field_invalid:alpha")
        for key, expected in FROZEN_THRESHOLDS.items():
            if thresholds.get(key) != expected:
                violations.append(f"threshold_not_frozen:{key}")
        for key in ("min_eligible_request_fraction", "min_eligible_completion_token_fraction"):
            if not _is_fraction(thresholds.get(key)):
                violations.append(f"threshold_invalid:{key}")
        for key in (
            "ordinary_row_ttft_p95_regression_upper_bound",
            "ordinary_row_itl_p95_regression_upper_bound",
            "ordinary_row_throughput_change_lower_bound",
        ):
            value = thresholds.get(key)
            if not isinstance(value, (int, float)) or isinstance(value, bool) or not math.isfinite(value):
                violations.append(f"threshold_invalid:{key}")
    return sorted(set(violations))


def _shape_violations(shape: object, path: str, disabled_record: bool) -> list[str]:
    violations = _strict_object(shape, SHAPE_KEYS, path)
    if not isinstance(shape, dict):
        return violations
    violations.extend(_privacy_violations(shape, path))
    if not (isinstance(shape.get("shape_id"), str) and SAFE_ID.match(shape["shape_id"])):
        violations.append(f"{path}:field_invalid:shape_id")
    if not isinstance(shape.get("conversation_key_present"), bool):
        violations.append(f"{path}:field_invalid:conversation_key_present")
    if not (_is_count(shape.get("completion_tokens")) and shape["completion_tokens"] > 0):
        violations.append(f"{path}:field_invalid:completion_tokens")
    eligible = shape.get("pre_capacity_eligible")
    reason = shape.get("pre_capacity_selector_reason")
    effective = shape.get("effective_path")
    if not isinstance(eligible, bool):
        violations.append(f"{path}:field_invalid:pre_capacity_eligible")
    if not isinstance(reason, str) or reason not in SELECTOR_REASONS:
        violations.append(f"{path}:field_invalid:pre_capacity_selector_reason")
    if reason in PRE_CAPACITY_REJECTED_REASONS:
        violations.append(f"{path}:pre_capacity_selector_reason_runtime_only")
    if effective not in EFFECTIVE_PATHS:
        violations.append(f"{path}:field_invalid:effective_path")
    if eligible is True and reason != ELIGIBLE_REASON:
        violations.append(f"{path}:selector_reason_inconsistent")
    if eligible is False and reason == ELIGIBLE_REASON:
        violations.append(f"{path}:selector_reason_inconsistent")
    if eligible is True and shape.get("conversation_key_present") is not False:
        violations.append(f"{path}:eligible_with_conversation_key")
    if shape.get("conversation_key_present") is True and (reason != "conversation_key" or eligible is not False):
        violations.append(f"{path}:conversation_key_state_inconsistent")
    if reason == "conversation_key" and shape.get("conversation_key_present") is not True:
        violations.append(f"{path}:conversation_key_reason_without_key")
    if effective == "native_mtp" and eligible is not True:
        violations.append(f"{path}:native_path_without_pre_capacity_eligibility")
    if disabled_record and effective != "ordinary":
        violations.append(f"{path}:disabled_record_not_ordinary_path")
    return violations


def _block_violations(block: dict) -> list[str]:
    violations = _strict_object(block, BLOCK_KEYS, "block")
    violations.extend(_privacy_violations(block))
    if block.get("schema") != JSONL_SCHEMA or block.get("record_type") != "block":
        violations.append("block_schema_invalid")
    if not (isinstance(block.get("policy_sha256"), str) and HEX64.match(block["policy_sha256"])):
        violations.append("field_invalid:policy_sha256")
    if not _is_count(block.get("block_index")):
        violations.append("field_invalid:block_index")
    if block.get("path") not in PATHS:
        violations.append("field_invalid:path")
    for field in (
        "ordinary_row_p95_ttft_seconds",
        "ordinary_row_p95_itl_seconds",
        "ordinary_row_throughput_tps",
        "end_to_end_aggregate_throughput_tps",
    ):
        if not _is_positive_number(block.get(field)):
            violations.append(f"field_invalid:{field}")
    shapes = block.get("request_shapes")
    if not isinstance(shapes, list) or not shapes:
        violations.append("field_invalid:request_shapes")
    else:
        seen_shape_ids: set[str] = set()
        disabled_record = block.get("path") == PATH_DISABLED
        for index, shape in enumerate(shapes):
            violations.extend(_shape_violations(shape, f"request_shapes[{index}]", disabled_record))
            if isinstance(shape, dict) and isinstance(shape.get("shape_id"), str):
                if shape["shape_id"] in seen_shape_ids:
                    violations.append(f"request_shapes[{index}]:duplicate_shape_id")
                seen_shape_ids.add(shape["shape_id"])
    return sorted(set(violations))


def _header_violations(header: dict, policy: dict, policy_sha: str) -> list[str]:
    violations = _strict_object(header, HEADER_KEYS, "header")
    violations.extend(_privacy_violations(header))
    if header.get("schema") != JSONL_SCHEMA or header.get("record_type") != "header":
        violations.append("header_schema_invalid")
    if header.get("policy_sha256") != policy_sha:
        violations.append("policy_digest_mismatch")
    for key in ("sample_digest_sha256", "preregistration_digest_sha256", "privacy_review_id"):
        if header.get(key) != policy.get(key):
            violations.append(f"header_policy_field_mismatch:{key}")
    return sorted(set(violations))


def _shape_signature(shape: dict) -> tuple:
    return (
        shape.get("shape_id"),
        shape.get("conversation_key_present"),
        shape.get("completion_tokens"),
        shape.get("pre_capacity_selector_reason"),
        shape.get("pre_capacity_eligible"),
    )


def _pair_blocks(blocks: list[dict]) -> tuple[list[tuple[dict, dict]], list[str]]:
    by_block: dict[int, dict[str, dict]] = defaultdict(dict)
    failures: list[str] = []
    for block in blocks:
        key = block.get("block_index")
        path = block.get("path")
        if not _is_count(key) or path not in PATHS:
            continue
        if path in by_block[key]:
            failures.append(f"duplicate_pair:block {key} path {path}")
            continue
        by_block[key][path] = block
    pairs = []
    for index in sorted(by_block):
        item = by_block[index]
        missing = [path for path in PATHS if path not in item]
        if missing:
            failures.append(f"missing_pair:block {index} missing {','.join(missing)}")
            continue
        disabled_shapes = [_shape_signature(shape) for shape in item[PATH_DISABLED]["request_shapes"]]
        mixed_shapes = [_shape_signature(shape) for shape in item[PATH_MIXED]["request_shapes"]]
        if disabled_shapes != mixed_shapes:
            failures.append(f"shape_sample_mismatch:block {index}")
            continue
        pairs.append((item[PATH_DISABLED], item[PATH_MIXED]))
    return pairs, failures


def _ratio_delta(numerator: float, denominator: float) -> float:
    return numerator / denominator - 1.0


def _metric(pair: tuple[dict, dict], name: str) -> float:
    disabled, mixed = pair
    if name == "ordinary_throughput":
        return _ratio_delta(float(mixed["ordinary_row_throughput_tps"]), float(disabled["ordinary_row_throughput_tps"]))
    if name == "ttft":
        return _ratio_delta(float(mixed["ordinary_row_p95_ttft_seconds"]), float(disabled["ordinary_row_p95_ttft_seconds"]))
    if name == "itl":
        return _ratio_delta(float(mixed["ordinary_row_p95_itl_seconds"]), float(disabled["ordinary_row_p95_itl_seconds"]))
    if name == "end_to_end_throughput":
        return _ratio_delta(float(mixed["end_to_end_aggregate_throughput_tps"]), float(disabled["end_to_end_aggregate_throughput_tps"]))
    raise AssertionError(name)


def _percentile(values: list[float], q: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    pos = (len(ordered) - 1) * q
    lo = math.floor(pos)
    hi = math.ceil(pos)
    if lo == hi:
        return ordered[lo]
    return ordered[lo] + (ordered[hi] - ordered[lo]) * (pos - lo)


def _bootstrap(pairs: list[tuple[dict, dict]], metric_name: str, draws: int, seed: int) -> list[float]:
    rng = random.Random(seed)
    n = len(pairs)
    values: list[float] = []
    for _ in range(draws):
        sample = [_metric(pairs[rng.randrange(n)], metric_name) for _ in range(n)]
        values.append(statistics.median(sample))
    return values


def _eligibility_summary(pairs: list[tuple[dict, dict]]) -> dict:
    shapes = [shape for _, mixed in pairs for shape in mixed["request_shapes"]]
    requests = len(shapes)
    completion_tokens = sum(int(shape["completion_tokens"]) for shape in shapes)
    eligible_shapes = [shape for shape in shapes if shape["pre_capacity_eligible"] is True]
    eligible_requests = len(eligible_shapes)
    eligible_completion_tokens = sum(int(shape["completion_tokens"]) for shape in eligible_shapes)
    return {
        "requests": requests,
        "eligible_requests": eligible_requests,
        "eligible_request_fraction": eligible_requests / requests if requests else None,
        "completion_tokens": completion_tokens,
        "eligible_completion_tokens": eligible_completion_tokens,
        "eligible_completion_token_fraction": eligible_completion_tokens / completion_tokens if completion_tokens else None,
    }


def _bad_result(reason: str, **extra: object) -> dict:
    return {"schema": ANALYSIS_SCHEMA, "overall_status": "FAIL", "reason": reason, **extra}


def analyze(jsonl_path: Path, policy_path: Path) -> dict:
    policy = _load_policy(policy_path)
    policy_sha = _sha256(policy_path)
    policy_failures = _policy_violations(policy)
    if policy_failures:
        return _bad_result("policy_invalid", policy_sha256=policy_sha, hard_failures=policy_failures)

    header, blocks = _load_jsonl(jsonl_path)
    header_failures = _header_violations(header, policy, policy_sha)
    if header_failures:
        return _bad_result(
            "header_invalid",
            policy_sha256=policy_sha,
            observed_policy_sha256=header.get("policy_sha256"),
            hard_failures=header_failures,
        )

    block_failures = [
        {
            "block_index": block.get("block_index"),
            "path": block.get("path"),
            "failures": failures,
        }
        for block in blocks
        if (failures := _block_violations(block))
    ]
    if block_failures:
        return _bad_result("block_invalid", policy_sha256=policy_sha, block_failures=block_failures)

    bad_policy_records = [
        {"block_index": block["block_index"], "path": block["path"], "observed_policy_sha256": block["policy_sha256"]}
        for block in blocks
        if block["policy_sha256"] != policy_sha
    ]
    if bad_policy_records:
        return _bad_result(
            "result_policy_digest_mismatch",
            policy_sha256=policy_sha,
            bad_policy_records=bad_policy_records,
        )

    pairs, pair_failures = _pair_blocks(blocks)
    required_blocks = int(policy["min_paired_blocks"])
    if len(pairs) < required_blocks:
        pair_failures.append(f"paired_blocks_below_minimum:{len(pairs)}/{required_blocks}")

    thresholds = policy["thresholds"]
    eligibility = _eligibility_summary(pairs) if pairs else {
        "requests": 0,
        "eligible_requests": 0,
        "eligible_request_fraction": None,
        "completion_tokens": 0,
        "eligible_completion_tokens": 0,
        "eligible_completion_token_fraction": None,
    }
    floor_failures = []
    if (
        eligibility["eligible_request_fraction"] is None
        or eligibility["eligible_request_fraction"] < thresholds["min_eligible_request_fraction"]
    ):
        floor_failures.append("eligible_request_fraction_below_floor")
    if (
        eligibility["eligible_completion_token_fraction"] is None
        or eligibility["eligible_completion_token_fraction"] < thresholds["min_eligible_completion_token_fraction"]
    ):
        floor_failures.append("eligible_completion_token_fraction_below_floor")

    draws = int(policy["bootstrap_draws"])
    alpha = float(policy["alpha"])
    seed = int(policy["seed"])
    metrics = {}
    hypotheses: list[tuple[float, str, str, float, list[float]]] = []
    gate_specs = (
        ("ordinary_throughput", "lower", float(thresholds["ordinary_row_throughput_change_lower_bound"])),
        ("ttft", "upper", float(thresholds["ordinary_row_ttft_p95_regression_upper_bound"])),
        ("itl", "upper", float(thresholds["ordinary_row_itl_p95_regression_upper_bound"])),
    )
    for index, (metric_name, side, threshold) in enumerate(gate_specs):
        observed = [_metric(pair, metric_name) for pair in pairs]
        boot = _bootstrap(pairs, metric_name, draws, seed + index * 17) if pairs else []
        if side == "lower":
            failing_side = sum(1 for value in boot if value <= threshold)
        else:
            failing_side = sum(1 for value in boot if value >= threshold)
        p_value = (failing_side + 1) / (len(boot) + 1) if boot else 1.0
        metrics[metric_name] = {
            "median": statistics.median(observed) if observed else None,
            "threshold": threshold,
            "bound_side": side,
            "p_value": p_value,
        }
        hypotheses.append((p_value, metric_name, side, threshold, boot))

    adjusted = _holm_adjusted([item[0] for item in hypotheses])
    order = sorted(range(len(hypotheses)), key=lambda i: hypotheses[i][0])
    metric_failures = []
    for rank, index in enumerate(order):
        _, metric_name, side, threshold, boot = hypotheses[index]
        adjusted_alpha = alpha / max(1, len(hypotheses) - rank)
        metric = metrics[metric_name]
        if side == "lower":
            metric["corrected_lower_bound"] = _percentile(boot, adjusted_alpha)
            passed = adjusted[index] <= alpha
        else:
            metric["corrected_upper_bound"] = _percentile(boot, 1.0 - adjusted_alpha)
            passed = adjusted[index] <= alpha
        metric["holm_rank"] = rank + 1
        metric["holm_alpha"] = adjusted_alpha
        metric["confidence_level"] = 1.0 - adjusted_alpha
        metric["holm_adjusted_p_value"] = adjusted[index]
        metric["status"] = "PASS" if passed else "FAIL"
        if not passed:
            metric_failures.append(metric_name)

    e2e_observed = [_metric(pair, "end_to_end_throughput") for pair in pairs]
    e2e_boot = _bootstrap(pairs, "end_to_end_throughput", draws, seed + 211) if pairs else []
    evidence = {
        "end_to_end_aggregate_throughput_change": {
            "median": statistics.median(e2e_observed) if e2e_observed else None,
            "ci_lower": _percentile(e2e_boot, alpha / 2),
            "ci_upper": _percentile(e2e_boot, 1.0 - alpha / 2),
            "confidence_level": 1.0 - alpha,
            "gated": False,
        }
    }

    hard_failures = pair_failures + floor_failures
    overall = "PASS" if not hard_failures and not metric_failures else "FAIL"
    return {
        "schema": ANALYSIS_SCHEMA,
        "overall_status": overall,
        "policy_sha256": policy_sha,
        "sample_digest_sha256": policy["sample_digest_sha256"],
        "preregistration_digest_sha256": policy["preregistration_digest_sha256"],
        "privacy_review_id": policy["privacy_review_id"],
        "paired_blocks": len(pairs),
        "required_paired_blocks": required_blocks,
        "eligibility": eligibility,
        "hard_failures": hard_failures,
        "metric_failures": sorted(metric_failures),
        "metrics": metrics,
        "reported_evidence": evidence,
    }


def _fmt(value: object) -> str:
    return "null" if value is None else f"{float(value):.6g}"


def markdown_summary(result: dict) -> str:
    lines = [
        "| Status | Paired Blocks | Eligible Requests | Eligible Tokens | Throughput LB | TTFT UB | ITL UB | E2E Throughput | Failures |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |",
    ]
    eligibility = result.get("eligibility", {})
    metrics = result.get("metrics", {})
    e2e = result.get("reported_evidence", {}).get("end_to_end_aggregate_throughput_change", {})
    failures = ",".join(result.get("hard_failures", []) + result.get("metric_failures", [])) or "-"
    lines.append(
        "| {status} | {blocks}/{required} | {req} | {tok} | {thr} | {ttft} | {itl} | {e2e} | {failures} |".format(
            status=result.get("overall_status"),
            blocks=result.get("paired_blocks", 0),
            required=result.get("required_paired_blocks", 0),
            req=_fmt(eligibility.get("eligible_request_fraction")),
            tok=_fmt(eligibility.get("eligible_completion_token_fraction")),
            thr=_fmt(metrics.get("ordinary_throughput", {}).get("corrected_lower_bound")),
            ttft=_fmt(metrics.get("ttft", {}).get("corrected_upper_bound")),
            itl=_fmt(metrics.get("itl", {}).get("corrected_upper_bound")),
            e2e=_fmt(e2e.get("median")),
            failures=failures,
        )
    )
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("jsonl", type=Path)
    parser.add_argument("policy", type=Path)
    parser.add_argument("--format", choices=("json", "markdown"), default="json")
    args = parser.parse_args(argv)
    try:
        result = analyze(args.jsonl, args.policy)
    except Exception as exc:  # CLI contract: bad input exits 1 with parseable evidence.
        result = _bad_result("bad_input", error=str(exc))
    if args.format == "json":
        print(json.dumps(result, indent=2, sort_keys=True))
    else:
        print(markdown_summary(result))
    return 0 if result["overall_status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
