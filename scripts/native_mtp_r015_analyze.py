#!/usr/bin/env python3
"""Analyze SPEC-048-R015 native-MTP JSONL benchmark evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import random
import re
import statistics
import sys
from collections import defaultdict
from pathlib import Path


SCHEMA = "macprovider.native-mtp-r015-run.v1"


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


EXPLORATORY_POLICY_SCHEMA = "macprovider.native-mtp-exploratory-policy.v1"


def _reject_duplicate_keys(pairs: list[tuple[str, object]]) -> dict:
    keys = [key for key, _ in pairs]
    if len(set(keys)) != len(keys):
        raise ValueError(f"duplicate JSON key: {sorted(k for k in set(keys) if keys.count(k) > 1)}")
    return dict(pairs)


def _reject_non_finite_constant(token: str) -> object:
    raise ValueError(f"non-finite JSON constant: {token}")


def _strict_loads(text: str) -> object:
    """json.loads that rejects duplicate object keys (last-key-wins would let
    one hash-bound record mean two things) and NaN/Infinity constants (a NaN
    threshold compares false against every bound)."""
    return json.loads(
        text,
        object_pairs_hook=_reject_duplicate_keys,
        parse_constant=_reject_non_finite_constant,
    )


def _load_policy(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as fh:
        return _strict_loads(fh.read())


def _is_exploratory(policy: dict) -> bool:
    return policy.get("schema") == EXPLORATORY_POLICY_SCHEMA


# SPEC-048-R015 mandatory matrix: native-eligible cells at every slot count
# from one to max_native_active_rows, prompt strata 1536/4096 capped by the
# tuple's signed max prompt tokens (cap included), and both output budgets;
# gated cells at bound + 1 and qualified_slots; the sustained window at
# qualified_slots. Gated and sustained cells run at prompt 1536, output 512.
NATIVE_ELIGIBLE_PROMPT_STRATA = (1536, 4096)
MANDATORY_MAX_TOKENS = (128, 512)
GATED_PROMPT_TOKENS = 1536
GATED_MAX_TOKENS = 512
MINIMUM_SUSTAINED_SECONDS = 1800
# SPEC-023-R024 max_prompt_tokens upper bound.
MAXIMUM_PROMPT_TOKENS = 1_048_576
# The bench parses policy integers as Swift Int.
SWIFT_INT_MAX = (1 << 63) - 1


def _is_int(value) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


_CELL_ID = re.compile(r"^s([1-9]\d*)-p([1-9]\d*)-o([1-9]\d*)$")


def _cell_id(slots: int, prompt: int, output: int) -> str:
    return f"s{slots}-p{prompt}-o{output}"


def mandatory_prompt_tokens(cap: int) -> list[int]:
    return sorted({p for p in NATIVE_ELIGIBLE_PROMPT_STRATA if p <= cap} | {cap})


def mandatory_gated_cells(bound: int, qualified: int) -> list[str]:
    if bound >= qualified:
        return []
    return [_cell_id(s, GATED_PROMPT_TOKENS, GATED_MAX_TOKENS) for s in sorted({bound + 1, qualified})]


ADMISSION_POLICY_SCHEMA = "macprovider.native-mtp-r015-policy.v1"
POLICY_KEYS = {
    "schema", "model_id", "target_sha256", "mtp_sha256", "tokenizer_sha256",
    "slots", "prompt_tokens", "max_tokens", "warmup_runs", "blocks", "seed",
    "sustained_seconds", "sustained_cell_id", "memory_safety_margin_bytes", "thresholds",
    "hw_model", "chip", "ram_gb", "os_build", "xcode_build_version", "swift_version",
    "provider_commit", "mlx_fork_revision", "quantization", "cache_mode", "proposal_depth",
    "run_order", "prompt_corpus", "exclusion_rules", "confidence_method",
    "max_native_active_rows", "qualified_slots", "temperature", "arrival_interval_ms",
    "gated_cells", "maximum_prompt_tokens",
}
# Mirrors NativeMTPBenchPolicy.load: the frozen methodology and thresholds an
# admission policy must carry, so the analyzer never judges a policy the bench
# would refuse.
FIXED_METHODOLOGY = {
    "quantization": "4bit",
    "cache_mode": "paged_kv_mixed",
    "proposal_depth": 1,
    "run_order": "seeded_random_counterbalanced",
    "prompt_corpus": "deterministic_synthetic_unique_v2",
    "exclusion_rules": "none",
    "confidence_method": "paired_block_bootstrap_holm_v1",
}
# SPEC-048 0.1.25 gate set. The latency gates are per-output-token latency
# (TPOT) and a worst-chunk-gap bound; the inter-chunk p95 gate of earlier
# versions compared one native verify step, which carries up to
# proposal_depth + 1 tokens, against one ordinary token.
FROZEN_THRESHOLDS = {
    "throughput_lower_bound_min": 0.15,
    "ttft_p95_upper_bound_max": 0.10,
    "tpot_p95_upper_bound_max": 0.0,
    "chunk_gap_p99_upper_bound_max": 1.0,
    "rejection_increase_max_pp": 1.0,
    "min_available_memory_fraction": 0.10,
    "bootstrap_draws": 10000,
    "alpha": 0.05,
    "gated_throughput_lower_bound_min": -0.05,
    "gated_ttft_p95_upper_bound_max": 0.05,
    "gated_tpot_p95_upper_bound_max": 0.05,
}
# The SPEC-048 0.1.24-and-earlier gate set. Policies frozen with it are still
# judged by it, so every recorded verdict reproduces unchanged; the bench no
# longer accepts it for new runs.
LEGACY_ITL_THRESHOLDS = {
    "throughput_lower_bound_min": 0.15,
    "ttft_p95_upper_bound_max": 0.10,
    "itl_p95_upper_bound_max": 0.0,
    "rejection_increase_max_pp": 1.0,
    "min_available_memory_fraction": 0.10,
    "bootstrap_draws": 10000,
    "alpha": 0.05,
    "gated_throughput_lower_bound_min": -0.05,
    "gated_ttft_p95_upper_bound_max": 0.05,
    "gated_itl_p95_upper_bound_max": 0.05,
}
GATE_SET_AMENDED = "tpot_chunk_gap_v2"
GATE_SET_LEGACY = "inter_chunk_itl_v1"
GATE_METRICS = {
    GATE_SET_AMENDED: ("throughput", "ttft", "tpot", "chunk_gap_p99", "rejection"),
    GATE_SET_LEGACY: ("throughput", "ttft", "itl", "rejection"),
}


def _gate_set(thresholds: object) -> str | None:
    """The frozen gate set a policy's threshold key set selects, if any."""
    if not isinstance(thresholds, dict):
        return None
    if set(thresholds) == set(FROZEN_THRESHOLDS):
        return GATE_SET_AMENDED
    if set(thresholds) == set(LEGACY_ITL_THRESHOLDS):
        return GATE_SET_LEGACY
    return None


def _frozen_values(gate_set: str) -> dict:
    expected = dict(FROZEN_THRESHOLDS if gate_set == GATE_SET_AMENDED else LEGACY_ITL_THRESHOLDS)
    # One draw count for both sets (tests lower it on FROZEN_THRESHOLDS).
    expected["bootstrap_draws"] = FROZEN_THRESHOLDS["bootstrap_draws"]
    return expected


def _policy_contract_violations(policy: dict) -> list[str]:
    """Closed-policy violations of an admission policy beyond the matrix."""
    violations: list[str] = []
    if policy.get("schema") != ADMISSION_POLICY_SCHEMA:
        violations.append("policy_schema_not_admission")
    unknown = sorted(set(policy) - POLICY_KEYS)
    if unknown:
        violations.append("policy_unknown_keys:" + ",".join(unknown))
    for key, expected in FIXED_METHODOLOGY.items():
        if policy.get(key) != expected or isinstance(policy.get(key), bool):
            violations.append(f"methodology_not_frozen:{key}")
    # Field types and ranges, mirroring NativeMTPBenchPolicy.load.
    hex64 = re.compile(r"^[0-9a-f]{64}$")
    hex40 = re.compile(r"^[0-9a-f]{40}$")
    for key in ("target_sha256", "mtp_sha256", "tokenizer_sha256"):
        if not (isinstance(policy.get(key), str) and hex64.match(policy[key])):
            violations.append(f"field_invalid:{key}")
    for key in ("provider_commit", "mlx_fork_revision"):
        if not (isinstance(policy.get(key), str) and hex40.match(policy[key])):
            violations.append(f"field_invalid:{key}")
    for key in ("model_id", "hw_model", "chip", "os_build", "xcode_build_version", "swift_version", "sustained_cell_id"):
        if not (isinstance(policy.get(key), str) and policy[key]):
            violations.append(f"field_invalid:{key}")
    for key, minimum in (("warmup_runs", 0), ("seed", 0), ("memory_safety_margin_bytes", 0),
                         ("ram_gb", 1), ("arrival_interval_ms", 0), ("sustained_seconds", 0)):
        if key == "arrival_interval_ms" and key not in policy:
            continue
        if not (_is_int(policy.get(key)) and minimum <= policy[key] <= SWIFT_INT_MAX):
            violations.append(f"field_invalid:{key}")
    if "temperature" in policy:
        t = policy["temperature"]
        if isinstance(t, bool) or not isinstance(t, (int, float)) or not math.isfinite(t) or not 0 <= t <= 2:
            violations.append("field_invalid:temperature")
    for key, low, high in (("slots", 1, 8), ("prompt_tokens", 1, None), ("max_tokens", 1, None)):
        values = policy.get(key)
        if not (isinstance(values, list) and values and all(_is_int(v) and v >= low and (high is None or v <= high) for v in values)
                and len(set(values)) == len(values)):
            violations.append(f"field_invalid:{key}")
    thresholds = policy.get("thresholds")
    gate_set = _gate_set(thresholds)
    if gate_set is None:
        violations.append("thresholds_key_set_not_frozen")
    else:
        for key, expected in _frozen_values(gate_set).items():
            value = thresholds[key]
            if (
                isinstance(value, bool)
                or not isinstance(value, (int, float))
                or not math.isfinite(value)
                or abs(value - expected) >= 1e-7
            ):
                violations.append(f"threshold_not_frozen:{key}")
    return violations


def _matrix_violations(policy: dict) -> list[str]:
    """Mandatory-matrix violations of an admission (non-exploratory) policy;
    duplicate cells are rejected for every policy, as the bench does."""
    if _is_exploratory(policy):
        try:
            cells = _observed_cells(policy)
        except (KeyError, TypeError):
            return ["matrix_malformed"]
        return ["duplicate_cells"] if len(set(cells)) != len(cells) else []
    violations: list[str] = _policy_contract_violations(policy)
    blocks = policy.get("blocks")
    if not _is_int(blocks) or blocks < 10:
        violations.append("blocks_below_ten")
    qualified = policy.get("qualified_slots")
    if not _is_int(qualified) or not 2 <= qualified <= 8:
        return ["qualified_slots_missing_or_out_of_range"]
    bound = policy.get("max_native_active_rows")
    if not _is_int(bound) or not 1 <= bound <= qualified:
        return violations + ["max_native_active_rows_missing_or_out_of_range"]
    cap = policy.get("maximum_prompt_tokens")
    if not _is_int(cap) or not GATED_PROMPT_TOKENS <= cap <= MAXIMUM_PROMPT_TOKENS:
        return violations + ["maximum_prompt_tokens_missing_or_out_of_range"]
    slots = policy.get("slots")
    prompts = policy.get("prompt_tokens")
    outputs = policy.get("max_tokens")
    for key, value in (("slots", slots), ("prompt_tokens", prompts), ("max_tokens", outputs)):
        if not isinstance(value, list) or not all(_is_int(v) for v in value):
            violations.append(f"{key}_malformed")
    gated = policy.get("gated_cells", [])
    if not isinstance(gated, list) or not all(isinstance(v, str) and _CELL_ID.match(v) for v in gated):
        violations.append("gated_cells_malformed")
    if violations:
        return violations
    if sorted(slots) != list(range(1, bound + 1)):
        violations.append("slots_not_exactly_1_to_bound:" + ",".join(map(str, sorted(slots))))
    expected_prompts = mandatory_prompt_tokens(cap)
    if sorted(prompts) != expected_prompts:
        violations.append("prompt_tokens_not_exactly:" + ",".join(map(str, expected_prompts)))
    if sorted(outputs) != list(MANDATORY_MAX_TOKENS):
        violations.append("max_tokens_not_exactly:" + ",".join(map(str, MANDATORY_MAX_TOKENS)))
    expected_gated = mandatory_gated_cells(bound, qualified)
    if sorted(gated) != expected_gated or len(set(gated)) != len(gated):
        violations.append("gated_cells_not_exactly:" + ",".join(expected_gated))
    cells = _observed_cells(policy)
    if len(set(cells)) != len(cells):
        violations.append("duplicate_cells")
    expected_sustained = _cell_id(qualified, GATED_PROMPT_TOKENS, GATED_MAX_TOKENS)
    if policy.get("sustained_cell_id") != expected_sustained:
        violations.append("sustained_cell_not:" + expected_sustained)
    if policy.get("sustained_cell_id") not in cells:
        violations.append("sustained_cell_not_in_matrix")
    sustained_seconds = policy.get("sustained_seconds")
    if not _is_int(sustained_seconds) or sustained_seconds < MINIMUM_SUSTAINED_SECONDS:
        violations.append("sustained_seconds_below_1800")
    # A gated cell must exercise the in-flight hold: staggered arrivals let the
    # first request admit native before later ones cross the bound.
    arrival = policy.get("arrival_interval_ms")
    if (
        any(_is_gated_cell(cell, bound) for cell in cells)
        and not (_is_int(arrival) and arrival > 0)
    ):
        violations.append("arrival_interval_ms_required_for_gated_cells")
    return violations


GATED_THRESHOLD_KEYS = (
    "gated_throughput_lower_bound_min",
    "gated_ttft_p95_upper_bound_max",
)
_CELL_SLOTS = re.compile(r"^s(\d+)-")


def _native_bound(policy: dict) -> int | None:
    bound = policy.get("max_native_active_rows")
    return bound if _is_int(bound) and bound >= 1 else None


def _is_gated_cell(cell_id: str, bound: int | None) -> bool:
    """SPEC-048-R015: a cell above the R007 bound measures the load gate."""
    match = _CELL_SLOTS.match(cell_id)
    return bound is not None and match is not None and int(match.group(1)) > bound


def _admission_bound_failures(native_runs: list[dict], bound: int) -> list[str]:
    """Prove each gated-cell admission honored the bound it was taken under:
    native only while the other in-flight rows were below it, downgraded only
    at or above it."""
    failures: set[str] = set()
    for run in native_runs:
        paths = run.get("effective_paths")
        if not isinstance(paths, list) or len(paths) != run["native_requests"]:
            failures.add("admission_active_rows_missing")
            continue
        for entry in paths:
            other = entry.get("other_active_rows") if isinstance(entry, dict) else None
            if not _is_int(other) or other < 0:
                failures.add("admission_active_rows_missing")
                continue
            if entry.get("effective_path") == "native_mtp" and other >= bound:
                failures.add("native_admission_above_bound")
            if entry.get("selector_reason") == "capacity_above_native_bound" and other < bound:
                failures.add("load_gate_downgrade_below_bound")
    return sorted(failures)


GATED_EVIDENCE_FIELDS = (
    "gated_depth_zero_rounds",
    "gated_hold_episodes",
    "gated_depth_restorations",
    "gated_held_finishes_clean",
    "gated_held_unresolved",
)


def _gated_hold_failures(native_runs: list[dict], bound: int) -> list[str]:
    """SPEC-048-R015 gated cell: the cell must show the gate at work on real
    hardware — a native admission under the bound, a downgrade at it, rounds
    in which an admitted native row was held at depth zero, and every hold
    ending in a restored native round or a clean terminal."""
    failures: set[str] = set()
    admitted = downgraded = False
    held_rounds = 0
    for run in native_runs:
        for entry in run.get("effective_paths") or []:
            if not isinstance(entry, dict) or not _is_int(entry.get("other_active_rows")):
                continue
            if entry.get("effective_path") == "native_mtp" and entry["other_active_rows"] < bound:
                admitted = True
            if entry.get("selector_reason") == "capacity_above_native_bound" and entry["other_active_rows"] >= bound:
                downgraded = True
        if not all(_is_count(run.get(field)) for field in GATED_EVIDENCE_FIELDS):
            failures.add("gated_load_gate_evidence_missing")
            continue
        held_rounds += run["gated_depth_zero_rounds"]
        if run["gated_held_unresolved"] or run["gated_hold_episodes"] != (
            run["gated_depth_restorations"] + run["gated_held_finishes_clean"]
        ):
            failures.add("gated_hold_unresolved")
    if not admitted:
        failures.add("gated_cell_missing_native_admission")
    if not downgraded:
        failures.add("gated_cell_missing_load_gate_downgrade")
    if held_rounds <= 0:
        failures.add("gated_depth_zero_hold_missing")
    return sorted(failures)


_U64 = (1 << 64) - 1
_GOLDEN = 0x9E3779B97F4A7C15


def _native_first_order(seed: int, slots: int, prompt_tokens: int, max_tokens: int, blocks: int) -> list[bool]:
    """SPEC-048-R015 preregistered, counterbalanced order: per cell, half the
    blocks (rounded up) run native first, shuffled by a Fisher-Yates
    permutation seeded from the frozen policy seed and the cell. Mirrors
    NativeMTPBenchPolicy.nativeFirstOrder bit for bit (UInt64 wrapping)."""
    if blocks <= 0:
        return []
    order = [index < (blocks + 1) // 2 for index in range(blocks)]
    value = seed & _U64
    for component in (slots, prompt_tokens, max_tokens):
        value ^= ((component & _U64) + _GOLDEN + ((value << 6) & _U64) + (value >> 2)) & _U64
    state = value if value else _GOLDEN
    for index in range(blocks - 1, 0, -1):
        state = (state + _GOLDEN) & _U64
        z = state
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & _U64
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & _U64
        z ^= z >> 31
        swap = z % (index + 1)
        order[index], order[swap] = order[swap], order[index]
    return order


def _load_jsonl(path: Path) -> tuple[dict, list[dict]]:
    header = None
    runs: list[dict] = []
    with path.open("r", encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, 1):
            line = line.strip()
            if not line:
                continue
            record = _strict_loads(line)
            if not isinstance(record, dict):
                raise ValueError(f"{path}:{lineno}: record is not a JSON object")
            if record.get("schema") != SCHEMA:
                raise ValueError(f"{path}:{lineno}: unexpected schema {record.get('schema')!r}")
            if record.get("record_type") == "header":
                if header is not None:
                    raise ValueError("multiple header records")
                header = record
            elif record.get("record_type") == "run":
                runs.append(record)
            else:
                raise ValueError(f"{path}:{lineno}: unexpected record_type {record.get('record_type')!r}")
    if header is None:
        raise ValueError("missing header record")
    return header, runs


def _median(values: list[float]) -> float | None:
    return statistics.median(values) if values else None


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


def _safe_ratio(numerator: float, denominator: float) -> float:
    return numerator / denominator if denominator > 0 else float("inf")


def _optional_ratio(numerator: float, denominator: float) -> float | None:
    return numerator / denominator if denominator > 0 else None


# Every field a hard gate or gated hypothesis reads. A missing, null,
# non-finite, negative, or wrongly typed value fails the record closed; it is
# never defaulted, because a defaulted zero reads as a perfect measurement.
_REQUIRED_NUMBER_FIELDS = (
    "aggregate_committed_tps",
    "aggregate_decode_tps",
    "ttft_p50_seconds",
    "ttft_p95_seconds",
    "inter_token_gap_p50_seconds",
    "inter_token_gap_p95_seconds",
    "wall_seconds",
    "min_available_memory_fraction",
)
_REQUIRED_COUNT_FIELDS = (
    "requests",
    "committed_completion_tokens",
    "capacity_rejections",
    "fallbacks",
    "errors",
    "non_native_admissions",
    "native_admissions",
    "native_requests",
    "peak_phys_footprint_bytes",
)
_REQUIRED_STRING_FIELDS = ("thermal_state_start", "thermal_state_end")


def _is_number(value: object) -> bool:
    return (
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and math.isfinite(value)
        and value >= 0
    )


def _is_count(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


def _chunk_gaps(run: dict) -> list[float] | None:
    """Every inter-chunk gap of the run's requests, or None when the record
    carries none or any is malformed."""
    raw = run.get("raw_inter_token_gaps_seconds")
    if not isinstance(raw, list) or not all(isinstance(item, list) for item in raw):
        return None
    gaps = [gap for item in raw for gap in item]
    if not gaps or not all(_is_number(gap) for gap in gaps):
        return None
    return [float(gap) for gap in gaps]


def _tpot_p95(run: dict) -> float:
    """p95 across the run's requests of per-output-token latency: a request's
    decode interval (first token to completion) over the tokens after its
    first, which is the token-weighted mean of every later chunk's gap divided
    by the tokens that chunk carries. Callers validate the record first."""
    return _percentile([1.0 / float(v) for v in run["per_request_decode_tps"]], 0.95)  # type: ignore[return-value]


def _chunk_gap_p99(run: dict) -> float:
    """p99 of every inter-chunk gap in the run. Callers validate first."""
    return _percentile(_chunk_gaps(run) or [], 0.99)  # type: ignore[return-value]


def _per_request_misalignment(run: dict) -> list[str]:
    """The amended gates take a p95 or p99 over per-request series. Each
    series must hold exactly one entry per request, in the order of the
    record's own request_metrics, so no request can drop out of a gate."""
    requests = run.get("requests")
    if not _is_count(requests):
        return []
    invalid = [
        field
        for field in ("per_request_tps", "per_request_decode_tps", "raw_inter_token_gaps_seconds", "request_metrics")
        if not isinstance(run.get(field), list) or len(run[field]) != requests
    ]
    if invalid:
        return invalid
    for index, item in enumerate(run["request_metrics"]):
        gaps = run["raw_inter_token_gaps_seconds"][index]
        if not isinstance(item, dict):
            invalid.append("request_metrics")
            continue
        if item.get("inter_token_gaps_seconds") != gaps:
            invalid.append("raw_inter_token_gaps_seconds")
        if item.get("decode_tps") != run["per_request_decode_tps"][index]:
            invalid.append("per_request_decode_tps")
        # Decode throughput and TPOT are defined over the tokens after the
        # first, so a request with fewer than two completion tokens has no
        # decode interval: a positive decode rate on it is fabricated, and its
        # empty gap series could hide behind another request's gaps. Every
        # chunk carries at least one token, so a request has at most
        # completion_tokens - 1 gaps.
        tokens = item.get("completion_tokens")
        if (
            not _is_count(tokens)
            or tokens < 2
            or (isinstance(gaps, list) and len(gaps) > tokens - 1)
        ):
            invalid.append("request_metrics")
    return invalid


def _invalid_run_fields(run: dict, require_chunk_gaps: bool = False) -> list[str]:
    invalid = [field for field in _REQUIRED_NUMBER_FIELDS if not _is_number(run.get(field))]
    invalid += [field for field in _REQUIRED_COUNT_FIELDS if not _is_count(run.get(field))]
    invalid += [
        field
        for field in _REQUIRED_STRING_FIELDS
        if not isinstance(run.get(field), str) or not run.get(field)
    ]
    if not isinstance(run.get("parity_mismatch"), bool):
        invalid.append("parity_mismatch")
    if _is_count(run.get("requests")) and run["requests"] < 1:
        invalid.append("requests")
    if _is_number(run.get("min_available_memory_fraction")) and run["min_available_memory_fraction"] > 1:
        invalid.append("min_available_memory_fraction")
    per_request = run.get("per_request_tps")
    if not isinstance(per_request, list) or not per_request or not all(_is_number(v) for v in per_request):
        invalid.append("per_request_tps")
    # The throughput gate divides by decode throughput; zero would read as an
    # infinite native speedup.
    if _is_number(run.get("aggregate_decode_tps")) and run["aggregate_decode_tps"] <= 0:
        invalid.append("aggregate_decode_tps")
    per_request_decode = run.get("per_request_decode_tps")
    if (
        not isinstance(per_request_decode, list)
        or not per_request_decode
        or not all(_is_number(v) and v > 0 for v in per_request_decode)
    ):
        invalid.append("per_request_decode_tps")
    # The worst-gap bound reads the recorded gaps; none, or one malformed,
    # fails the record rather than reading as a stall-free run.
    if require_chunk_gaps:
        if _chunk_gaps(run) is None:
            invalid.append("raw_inter_token_gaps_seconds")
        invalid += _per_request_misalignment(run)
    return sorted(set(invalid))


# Header run_metrics_version 2 and later: every run record carries decode
# throughput, and a missing value fails the record closed.
DECODE_METRICS_VERSION = 2
_REQUEST_INDEX = re.compile(r"-r(\d+)$")


def _legacy_decode_metrics(run: dict, arrival_interval_seconds: float) -> tuple[float, list[float]] | None:
    """Recover decode throughput from a pre-version-2 record.

    Request wall = completion tokens / per_request_tps; per-request decode
    throughput = (tokens - 1) / (wall - TTFT). The aggregate uses the bench's
    definition (tokens after each request's first, over earliest first token
    to latest completion) with each request's nominal arrival offset
    (index * arrival interval). Anything missing or degenerate returns None so
    the record fails closed.
    """
    tps = run.get("per_request_tps")
    ttfts = run.get("per_request_ttft_seconds")
    metrics = run.get("request_metrics")
    if not (isinstance(tps, list) and isinstance(ttfts, list) and isinstance(metrics, list)):
        return None
    if not tps or not (len(tps) == len(ttfts) == len(metrics)):
        return None
    per_request: list[float] = []
    decode_tokens = 0
    first_token = math.inf
    last_end = -math.inf
    for rate, ttft, item in zip(tps, ttfts, metrics):
        if not isinstance(item, dict):
            return None
        tokens = item.get("completion_tokens")
        match = _REQUEST_INDEX.search(str(item.get("request_id", "")))
        if not (_is_number(rate) and rate > 0 and _is_number(ttft) and _is_count(tokens) and tokens >= 2 and match):
            return None
        wall = tokens / rate
        if wall - ttft <= 0:
            return None
        per_request.append((tokens - 1) / (wall - ttft))
        offset = int(match.group(1)) * arrival_interval_seconds
        first_token = min(first_token, offset + ttft)
        last_end = max(last_end, offset + wall)
        decode_tokens += tokens - 1
    window = last_end - first_token
    if window <= 0:
        return None
    return decode_tokens / window, per_request


def _with_decode_metrics(run: dict, header: dict) -> dict:
    """Return the run with decode throughput present, recorded or derived."""
    if run.get("record_type") != "run":
        return run
    if "aggregate_decode_tps" in run:
        return {**run, "decode_tps_source": "recorded"}
    version = header.get("run_metrics_version")
    if _is_count(version) and version >= DECODE_METRICS_VERSION:
        return run
    interval_ms = header.get("arrival_interval_ms", 0)
    if not _is_number(interval_ms):
        return run
    derived = _legacy_decode_metrics(run, float(interval_ms) / 1000.0)
    if derived is None:
        return run
    aggregate, per_request = derived
    return {
        **run,
        "aggregate_decode_tps": aggregate,
        "per_request_decode_tps": per_request,
        "decode_tps_source": "derived_legacy",
    }


def _metric(pair: tuple[dict, dict], name: str) -> float:
    """Gated paired-block statistic. Callers validate both records first."""
    ordinary, native = pair
    if name == "throughput":
        # SPEC-048-R015: the gate is decode throughput; prefill is TTFT.
        return _safe_ratio(float(native["aggregate_decode_tps"]), float(ordinary["aggregate_decode_tps"])) - 1.0
    if name == "end_to_end_throughput":
        return _safe_ratio(float(native["aggregate_committed_tps"]), float(ordinary["aggregate_committed_tps"])) - 1.0
    if name == "ttft":
        return _safe_ratio(float(native["ttft_p95_seconds"]), float(ordinary["ttft_p95_seconds"])) - 1.0
    if name == "itl":
        return _safe_ratio(float(native["inter_token_gap_p95_seconds"]), float(ordinary["inter_token_gap_p95_seconds"])) - 1.0
    if name == "tpot":
        return _safe_ratio(_tpot_p95(native), _tpot_p95(ordinary)) - 1.0
    if name == "chunk_gap_p99":
        return _safe_ratio(_chunk_gap_p99(native), _chunk_gap_p99(ordinary)) - 1.0
    if name == "rejection":
        ordinary_rate = float(ordinary["capacity_rejections"]) / float(ordinary["requests"])
        native_rate = float(native["capacity_rejections"]) / float(native["requests"])
        return (native_rate - ordinary_rate) * 100.0
    raise AssertionError(name)


# R015 reporting family: every metric the campaign must report with a median
# and corrected confidence interval, per path, from the same paired blocks.
def _reported_values(run: dict, amended: bool = True) -> dict[str, float | None]:
    requests = float(run["requests"])
    proposed = run.get("mtp_proposed_tokens")
    accepted = run.get("mtp_accepted_tokens")
    return {
        "aggregate_committed_tps": float(run["aggregate_committed_tps"]),
        "per_request_tps": statistics.median(float(v) for v in run["per_request_tps"]),
        "aggregate_decode_tps": float(run["aggregate_decode_tps"]),
        "per_request_decode_tps": statistics.median(float(v) for v in run["per_request_decode_tps"]),
        "ttft_p50_seconds": float(run["ttft_p50_seconds"]),
        "ttft_p95_seconds": float(run["ttft_p95_seconds"]),
        "inter_token_gap_p50_seconds": float(run["inter_token_gap_p50_seconds"]),
        "inter_token_gap_p95_seconds": float(run["inter_token_gap_p95_seconds"]),
        "mtp_proposed_tokens": float(proposed) if _is_number(proposed) else None,
        "mtp_accepted_tokens": float(accepted) if _is_number(accepted) else None,
        "mtp_acceptance_rate": (
            _optional_ratio(float(accepted), float(proposed))
            if _is_number(accepted) and _is_number(proposed)
            else None
        ),
        "target_forwards_per_committed_token": (
            float(run["target_forwards_per_committed_token"])
            if _is_number(run.get("target_forwards_per_committed_token"))
            else None
        ),
        "peak_phys_footprint_bytes": float(run["peak_phys_footprint_bytes"]),
        "capacity_rejection_rate": float(run["capacity_rejections"]) / requests,
        "fallback_error_rate": (float(run["fallbacks"]) + float(run["errors"])) / requests,
        # Amended-gate latency series; absent under the legacy gate set so its
        # corrected intervals reproduce unchanged.
        **(
            {
                "tpot_p95_seconds": _tpot_p95(run),
                "chunk_gap_p99_seconds": _chunk_gap_p99(run) if _chunk_gaps(run) is not None else None,
            }
            if amended
            else {}
        ),
    }


def _report_metrics(pairs: list[tuple[dict, dict]], draws: int, alpha: float, seed: int, amended: bool = True) -> dict:
    """Median and Bonferroni-corrected two-sided percentile bootstrap CI over
    whole paired blocks for every reported metric and path."""
    per_block = [
        {"ordinary": _reported_values(ordinary, amended), "native_mtp": _reported_values(native, amended)}
        for ordinary, native in pairs
    ]
    series: dict[tuple[str, str], list[float]] = {}
    for path in ("ordinary", "native_mtp"):
        for name in per_block[0][path] if per_block else []:
            values = [block[path][name] for block in per_block]
            if all(value is not None for value in values):
                series[(path, name)] = values  # type: ignore[assignment]
    if not series:
        return {}
    level = alpha / len(series)
    rng = random.Random(seed)
    n = len(per_block)
    boot: dict[tuple[str, str], list[float]] = {key: [] for key in series}
    for _ in range(draws):
        indices = [rng.randrange(n) for _ in range(n)]
        for key, values in series.items():
            boot[key].append(statistics.median(values[i] for i in indices))
    report: dict[str, dict] = {"ordinary": {}, "native_mtp": {}}
    for (path, name), values in series.items():
        report[path][name] = {
            "median": statistics.median(values),
            "ci_lower": _percentile(boot[(path, name)], level / 2),
            "ci_upper": _percentile(boot[(path, name)], 1.0 - level / 2),
            "confidence_level": 1.0 - level,
        }
    return report


def _holm_adjusted(p_values: list[float]) -> list[float]:
    """Holm step-down adjusted p-values, in the input order."""
    m = len(p_values)
    order = sorted(range(m), key=lambda i: p_values[i])
    adjusted = [1.0] * m
    running = 0.0
    for rank, index in enumerate(order):
        running = max(running, min(1.0, (m - rank) * p_values[index]))
        adjusted[index] = running
    return adjusted


def _bootstrap(pairs: list[tuple[dict, dict]], metric_name: str, draws: int, seed: int) -> list[float]:
    rng = random.Random(seed)
    n = len(pairs)
    # A block's statistic is fixed, so compute it once per block; the draw
    # sequence is unchanged.
    per_block = [_metric(pair, metric_name) for pair in pairs]
    values: list[float] = []
    for _ in range(draws):
        sample = [per_block[rng.randrange(n)] for _ in range(n)]
        values.append(statistics.median(sample))
    return values


def _observed_cells(policy: dict) -> list[str]:
    """The native-eligible cross product, then the policy's gated cells."""
    cells = []
    for slots in policy["slots"]:
        for prompt in policy["prompt_tokens"]:
            for max_tokens in policy["max_tokens"]:
                cells.append(_cell_id(slots, prompt, max_tokens))
    gated = policy.get("gated_cells", [])
    if isinstance(gated, list):
        cells.extend(cell for cell in gated if isinstance(cell, str))
    return cells


def _expected_native_first(policy: dict, cell_id: str) -> list[bool] | None:
    match = _CELL_ID.match(cell_id)
    seed, blocks = policy.get("seed"), policy.get("blocks")
    if match is None or not _is_int(seed) or not _is_int(blocks):
        return None
    slots, prompt, output = (int(group) for group in match.groups())
    return _native_first_order(seed, slots, prompt, output, blocks)


def _order_issue(label: str, item: dict[str, dict], native_first: bool | None) -> str | None:
    """One ordinary and one native record at order positions {0, 1}, in the
    preregistered order when one is given."""
    positions = {path: item[path].get("order_position") for path in ("ordinary", "native_mtp")}
    if not all(_is_int(value) for value in positions.values()) or set(positions.values()) != {0, 1}:
        return f"{label} order_position not exactly one of each of 0 and 1"
    if native_first is not None and (positions["native_mtp"] == 0) != native_first:
        return f"{label} run order differs from the preregistered order"
    return None


def _pair_runs(
    runs: list[dict], cell_id: str, expected_native_first: list[bool] | None = None
) -> tuple[list[tuple[dict, dict]], list[str]]:
    """SPEC-048-R015 paired blocks: exactly one ordinary and one native record
    per measured block, run in the preregistered counterbalanced order."""
    by_block: dict[int, dict[str, dict]] = defaultdict(dict)
    issues: list[str] = []
    for run in runs:
        if run.get("cell_id") != cell_id or run.get("sustained") is True or run.get("warmup") is True:
            continue
        path = run.get("path")
        if path in ("ordinary", "native_mtp"):
            block = int(run.get("block_index", -1))
            if path in by_block[block]:
                issues.append(f"block {block} duplicate {path} path")
                continue
            by_block[block][path] = run
    pairs = []
    native_first_seen: set[bool] = set()
    for block in sorted(by_block):
        item = by_block[block]
        if "ordinary" not in item or "native_mtp" not in item:
            issues.append(f"block {block} missing paired path")
            continue
        if expected_native_first is not None and not 0 <= block < len(expected_native_first):
            issues.append(f"block {block} outside the preregistered blocks")
            continue
        expected = expected_native_first[block] if expected_native_first is not None else None
        issue = _order_issue(f"block {block}", item, expected)
        if issue:
            issues.append(issue)
            continue
        native_first_seen.add(item["native_mtp"]["order_position"] == 0)
        pairs.append((item["ordinary"], item["native_mtp"]))
    if len(pairs) >= 2 and len(native_first_seen) < 2:
        issues.append("run order not counterbalanced")
    return pairs, issues


def _sustained_order_issues(sustained_runs: list[dict]) -> list[str]:
    """The sustained window alternates (native first on even blocks) and its
    blocks are contiguous from zero: a resume never skips an index."""
    by_block: dict[int, dict[str, dict]] = defaultdict(dict)
    for run in sustained_runs:
        by_block[int(run.get("block_index", -1))][run.get("path")] = run
    issues = []
    if by_block and sorted(by_block) != list(range(max(by_block) + 1)):
        issues.append("sustained blocks not contiguous from 0")
    for block in sorted(by_block):
        item = by_block[block]
        if "ordinary" not in item or "native_mtp" not in item:
            issues.append(f"sustained block {block} missing paired path")
            continue
        issue = _order_issue(f"sustained block {block}", item, block % 2 == 0)
        if issue:
            issues.append(issue)
    return issues


def analyze(jsonl_path: Path, policy_path: Path, exploratory_amended_gates: bool = False) -> dict:
    """Judge the run against its frozen policy. `exploratory_amended_gates`
    re-reads a legacy-gate policy's records under the amended (SPEC-048
    0.1.25) gates for a sanity check; that result never carries a verdict."""
    policy = _load_policy(policy_path)
    policy_sha = _sha256(policy_path)
    header, runs = _load_jsonl(jsonl_path)
    runs = [_with_decode_metrics(run, header) for run in runs]
    matrix_violations = _matrix_violations(policy)
    if matrix_violations:
        return {
            "schema": "macprovider.native-mtp-r015-analysis.v1",
            "overall_status": "FAIL",
            "reason": "policy_matrix_incomplete",
            "matrix_violations": matrix_violations,
            "cells": [],
        }
    if header.get("policy_sha256") != policy_sha:
        return {
            "schema": "macprovider.native-mtp-r015-analysis.v1",
            "overall_status": "FAIL",
            "reason": "policy_digest_mismatch",
            "expected_policy_sha256": policy_sha,
            "observed_policy_sha256": header.get("policy_sha256"),
            "cells": [],
        }
    bad_run_policy_records = [
        {
            "cell_id": run.get("cell_id"),
            "block_index": run.get("block_index"),
            "path": run.get("path"),
            "observed_policy_sha256": run.get("policy_sha256"),
        }
        for run in runs
        if run.get("policy_sha256") != policy_sha
    ]
    if bad_run_policy_records:
        return {
            "schema": "macprovider.native-mtp-r015-analysis.v1",
            "overall_status": "FAIL",
            "reason": "run_policy_digest_mismatch",
            "expected_policy_sha256": policy_sha,
            "bad_run_policy_records": bad_run_policy_records,
            "cells": [],
        }
    seen_run_keys: set[tuple[object, ...]] = set()
    duplicate_run_keys: list[tuple[object, ...]] = []
    for run in runs:
        key = (
            run.get("cell_id"),
            run.get("block_index"),
            run.get("path"),
            bool(run.get("sustained", False)),
            bool(run.get("warmup", False)),
        )
        if key in seen_run_keys:
            duplicate_run_keys.append(key)
        seen_run_keys.add(key)
    if duplicate_run_keys:
        return {
            "schema": "macprovider.native-mtp-r015-analysis.v1",
            "overall_status": "FAIL",
            "reason": "duplicate_run_record",
            "duplicate_run_keys": [list(key) for key in duplicate_run_keys],
            "cells": [],
        }
    machine = header.get("machine") or {}
    frozen_environment = {
        "hw_model": policy.get("hw_model"),
        "chip": policy.get("chip"),
        "ram_gb": policy.get("ram_gb"),
        "os_build": policy.get("os_build"),
        "xcode_build_version": policy.get("xcode_build_version"),
        "swift_version": policy.get("swift_version"),
        "provider_commit": policy.get("provider_commit"),
        "mlx_fork_revision": policy.get("mlx_fork_revision"),
    }
    observed_environment = {
        "hw_model": machine.get("hw_model"),
        "chip": machine.get("chip"),
        "ram_gb": machine.get("ram_gb"),
        "os_build": machine.get("os_build"),
        "xcode_build_version": header.get("xcode_build_version"),
        "swift_version": header.get("swift_version"),
        "provider_commit": header.get("provider_commit"),
        "mlx_fork_revision": header.get("mlx_fork_revision"),
    }
    environment_mismatches = {
        key: {"frozen": frozen_environment[key], "observed": observed_environment[key]}
        for key in frozen_environment
        if frozen_environment[key] != observed_environment[key]
    }
    if environment_mismatches:
        return {
            "schema": "macprovider.native-mtp-r015-analysis.v1",
            "overall_status": "FAIL",
            "reason": "environment_mismatch",
            "environment_mismatches": environment_mismatches,
            "cells": [],
        }

    thresholds = policy["thresholds"]
    gate_set = _gate_set(thresholds)
    if gate_set is None:
        return {
            "schema": "macprovider.native-mtp-r015-analysis.v1",
            "overall_status": "FAIL",
            "reason": "thresholds_key_set_not_frozen",
            "cells": [],
        }
    reanalysis_of = None
    if exploratory_amended_gates:
        if gate_set != GATE_SET_LEGACY:
            return {
                "schema": "macprovider.native-mtp-r015-analysis.v1",
                "overall_status": "FAIL",
                "reason": "exploratory_reanalysis_needs_legacy_policy",
                "cells": [],
            }
        reanalysis_of = gate_set
        thresholds = {
            **{key: value for key, value in FROZEN_THRESHOLDS.items()},
            "bootstrap_draws": thresholds["bootstrap_draws"],
            "alpha": thresholds["alpha"],
        }
        gate_set = GATE_SET_AMENDED
    require_chunk_gaps = gate_set == GATE_SET_AMENDED

    def invalid_fields(run: dict) -> list[str]:
        return _invalid_run_fields(run, require_chunk_gaps)

    bound = _native_bound(policy)
    if any(_is_gated_cell(cell_id, bound) for cell_id in _observed_cells(policy)) and any(
        not isinstance(thresholds.get(key), (int, float))
        or isinstance(thresholds.get(key), bool)
        or not math.isfinite(thresholds[key])
        for key in GATED_THRESHOLD_KEYS + ("gated_tpot_p95_upper_bound_max" if gate_set == GATE_SET_AMENDED else "gated_itl_p95_upper_bound_max",)
    ):
        return {
            "schema": "macprovider.native-mtp-r015-analysis.v1",
            "overall_status": "FAIL",
            "reason": "gated_thresholds_missing",
            "cells": [],
        }
    draws = int(thresholds["bootstrap_draws"])
    alpha = float(thresholds["alpha"])
    required_blocks = int(policy["blocks"])
    base_seed = int(policy["seed"])
    ram_gb = machine.get("ram_gb") or 0
    ram_bytes = int(float(ram_gb) * 1_073_741_824)
    memory_margin = int(policy.get("memory_safety_margin_bytes", 0))
    unavailable_metrics = set(header.get("unavailable_metrics", []))

    cell_results = []
    hypotheses = []
    for cell_index, cell_id in enumerate(_observed_cells(policy)):
        gated = _is_gated_cell(cell_id, bound)
        pairs, issues = _pair_runs(runs, cell_id, _expected_native_first(policy, cell_id))
        hard_failures = list(issues)
        if len(pairs) < required_blocks:
            hard_failures.append(f"incomplete: {len(pairs)}/{required_blocks} paired blocks")
        sustained_runs = [
            run for run in runs
            if run.get("cell_id") == cell_id and run.get("sustained") is True and run.get("warmup") is not True
        ]
        hard_failures.extend(_sustained_order_issues(sustained_runs))
        # run_metrics_version 5 binds every sustained record to its run: an
        # admission window must be one continuous run, never stitched.
        if sustained_runs and isinstance(header.get("run_metrics_version"), int) and header["run_metrics_version"] >= 5:
            window_ids = {run.get("sustained_window_id") for run in sustained_runs}
            if len(window_ids) != 1 or not all(isinstance(w, str) and w for w in window_ids):
                hard_failures.append("sustained_window_not_one_continuous_run")
        hard_gate_runs = [run for pair in pairs for run in pair] + sustained_runs
        invalid_records = [
            f"invalid_run_record:{run.get('path')}:{run.get('block_index')}:{','.join(fields)}"
            for run in hard_gate_runs
            if (fields := invalid_fields(run))
        ]
        hard_failures.extend(invalid_records)
        # Only fully valid records feed any statistic; an invalid record has
        # already failed the cell above.
        pairs = [pair for pair in pairs if not invalid_fields(pair[0]) and not invalid_fields(pair[1])]
        sustained_runs = [run for run in sustained_runs if not invalid_fields(run)]
        hard_gate_runs = [run for pair in pairs for run in pair] + sustained_runs
        parity_mismatches = sum(int(r["parity_mismatch"]) for r in hard_gate_runs)
        non_native_admissions = sum(r["non_native_admissions"] for r in hard_gate_runs)
        # A load-gate downgrade is a recorded admission decision, not a
        # missing one.
        missing_native_admissions = sum(
            max(
                0,
                r["native_requests"]
                - r["native_admissions"]
                - (r["load_gate_downgrades"] if _is_count(r.get("load_gate_downgrades")) else 0),
            )
            for r in hard_gate_runs
            if r.get("path") == "native_mtp"
        )
        fallback_errors = sum(r["fallbacks"] + r["errors"] for r in hard_gate_runs)
        native_runs = [r for r in hard_gate_runs if r.get("path") == "native_mtp"]
        load_gate_downgrades = sum(
            r["load_gate_downgrades"] for r in native_runs if _is_count(r.get("load_gate_downgrades"))
        )
        # A downgrade can never cover more requests than the run issued.
        over_accounted_runs = [
            r for r in native_runs
            if r["native_admissions"]
            + (r["load_gate_downgrades"] if _is_count(r.get("load_gate_downgrades")) else 0)
            > r["native_requests"]
        ]
        # SPEC-048-R007: only a run whose every request the admission load
        # gate sent to ordinary decode legitimately has no native work. Any run
        # with a native admission must still prove it proposed and verified,
        # however many of its other requests were downgraded.
        ungated_native_runs = [
            r for r in native_runs
            if r["native_admissions"] > 0
            or not (_is_count(r.get("load_gate_downgrades")) and r["load_gate_downgrades"] > 0)
        ]
        # A gated cell (slots above the R007 bound) runs with the in-flight
        # gate engaged, which holds admitted native rows at depth zero inside
        # the ordinary forward: their counters must be recorded, but positive
        # proposals cannot be demanded. The cell instead proves every
        # admission honored the bound and that native is non-inferior.
        counter_runs = ungated_native_runs
        proof_runs = [] if gated else ungated_native_runs
        if gated and bound is not None:
            hard_failures.extend(_admission_bound_failures(native_runs, bound))
            hard_failures.extend(_gated_hold_failures(native_runs, bound))
        elif load_gate_downgrades:
            hard_failures.append("load_gate_downgrade_in_native_eligible_cell")
        if any(
            _is_count(r.get("mtp_accepted_tokens"))
            and _is_count(r.get("mtp_proposed_tokens"))
            and r["mtp_accepted_tokens"] > r["mtp_proposed_tokens"]
            for r in counter_runs
        ):
            hard_failures.append("native_mtp_counters_inconsistent")
        if parity_mismatches:
            hard_failures.append("parity_mismatch")
        if non_native_admissions:
            hard_failures.append("non_native_admissions")
        if missing_native_admissions:
            hard_failures.append("missing_native_admissions")
        if over_accounted_runs:
            hard_failures.append("native_admission_accounting_inconsistent")
        if fallback_errors:
            hard_failures.append("fallback_or_error")
        native_counter_fields = (
            "mtp_proposed_tokens",
            "mtp_accepted_tokens",
            "mtp_accepted_by_position",
            "target_forwards",
            "target_forwards_per_committed_token",
        )
        missing_counter_fields = [
            field
            for field in native_counter_fields
            if field not in unavailable_metrics
            and any(run.get(field) is None for run in counter_runs)
        ]
        if missing_counter_fields:
            hard_failures.append("native_mtp_counters_missing:" + ",".join(missing_counter_fields))
        if "mtp_proposed_tokens" not in unavailable_metrics and any(
            int(run.get("mtp_proposed_tokens") or 0) <= 0 for run in proof_runs
        ):
            hard_failures.append("native_mtp_proposals_missing")
        if "target_forwards" not in unavailable_metrics and any(
            int(run.get("target_forwards") or 0) <= 0 for run in proof_runs
        ):
            hard_failures.append("native_mtp_target_forwards_missing")
        if cell_id == policy.get("sustained_cell_id") and not sustained_runs and not (
            _is_exploratory(policy) and int(policy.get("sustained_seconds", 0)) == 0
        ):
            hard_failures.append("sustained_missing")
        sustained_elapsed = [
            float(r["sustained_window_elapsed_seconds"])
            for r in sustained_runs
            if r.get("sustained_window_elapsed_seconds") is not None
        ]
        sustained_duration_seconds = (
            max(sustained_elapsed)
            if sustained_elapsed
            else sum(float(r.get("wall_seconds") or 0) for r in sustained_runs)
        )
        if (
            cell_id == policy.get("sustained_cell_id")
            and sustained_duration_seconds < float(policy.get("sustained_seconds", 0))
        ):
            hard_failures.append(
                f"sustained_incomplete: {sustained_duration_seconds:.6g}/{policy.get('sustained_seconds')} seconds"
            )
        if ram_bytes <= 0:
            hard_failures.append("machine_ram_missing")

        metrics = {}
        usable_pairs = pairs if pairs else []
        for metric_name in GATE_METRICS[gate_set]:
            observed = [_metric(pair, metric_name) for pair in usable_pairs]
            median = _median(observed)
            # Seeds of the original four metrics are unchanged so legacy
            # analyses reproduce byte for byte.
            seed = base_seed + cell_index * 17 + {"tpot": 307, "chunk_gap_p99": 401}.get(metric_name, len(metric_name))
            boot = _bootstrap(usable_pairs, metric_name, draws, seed) if usable_pairs else []
            metrics[metric_name] = {"median": median, "draws": boot}
        # Prefill-inclusive throughput: reported, never gated (prefill is the
        # same work on both paths and is gated as TTFT).
        end_to_end = [_metric(pair, "end_to_end_throughput") for pair in usable_pairs]
        end_to_end_draws = (
            _bootstrap(usable_pairs, "end_to_end_throughput", draws, base_seed + cell_index * 17 + 211)
            if usable_pairs
            else []
        )
        informational = {
            "end_to_end_throughput": {
                "median": _median(end_to_end),
                "ci_lower": _percentile(end_to_end_draws, alpha / 2),
                "ci_upper": _percentile(end_to_end_draws, 1.0 - alpha / 2),
                "confidence_level": 1.0 - alpha,
                "gated": False,
            }
        }

        cell = {
            "cell_id": cell_id,
            "cell_class": "gated" if gated else "native_eligible",
            "paired_blocks": len(pairs),
            "required_blocks": required_blocks,
            "load_gate_downgrades": load_gate_downgrades,
            "hard_failures": hard_failures,
            "metrics": metrics,
            "informational_metrics": informational,
            "decode_tps_sources": sorted({str(r.get("decode_tps_source")) for r in hard_gate_runs}),
            "acceptance_rate": _median([
                value
                for _, r in pairs
                if (value := _optional_ratio(float(r.get("mtp_accepted_tokens", 0)), float(r.get("mtp_proposed_tokens", 0)))) is not None
            ]),
            "forwards_per_committed_token": _median([
                value
                for _, r in pairs
                if (value := _optional_ratio(float(r.get("target_forwards", 0)), float(r.get("committed_completion_tokens", 0)))) is not None
            ]),
            "reported_metrics": _report_metrics(pairs, draws, alpha, base_seed + cell_index * 17 + 101, gate_set == GATE_SET_AMENDED),
            "peak_phys_footprint_bytes": max([r["peak_phys_footprint_bytes"] for r in hard_gate_runs] or [0]),
            "min_available_memory_fraction": min([float(r["min_available_memory_fraction"]) for r in hard_gate_runs] or [0]),
            "sustained_runs": len(sustained_runs),
            "sustained_duration_seconds": sustained_duration_seconds,
            "sustained_min_available_memory_fraction": min([float(r["min_available_memory_fraction"]) for r in sustained_runs] or [0]),
            "thermal_start_states": sorted({str(r.get("thermal_state_start")) for r in hard_gate_runs}),
            "thermal_end_states": sorted({str(r.get("thermal_state_end")) for r in hard_gate_runs}),
        }
        cell_results.append(cell)
        for metric_name, metric in metrics.items():
            draws_for_metric = metric["draws"]
            # Gated cells gate non-inferiority to ordinary; eligible cells
            # gate the native improvement.
            prefix = "gated_" if cell["cell_class"] == "gated" else ""
            if metric_name == "throughput":
                threshold = float(thresholds[prefix + "throughput_lower_bound_min"])
                failing_side = sum(1 for x in draws_for_metric if x <= threshold)
            elif metric_name == "ttft":
                threshold = float(thresholds[prefix + "ttft_p95_upper_bound_max"])
                failing_side = sum(1 for x in draws_for_metric if x >= threshold)
            elif metric_name == "itl":
                threshold = float(thresholds[prefix + "itl_p95_upper_bound_max"])
                failing_side = sum(1 for x in draws_for_metric if x >= threshold)
            elif metric_name == "tpot":
                threshold = float(thresholds[prefix + "tpot_p95_upper_bound_max"])
                failing_side = sum(1 for x in draws_for_metric if x >= threshold)
            elif metric_name == "chunk_gap_p99":
                # One structural bound for every cell class: a native chunk
                # covers at most proposal_depth + 1 committed tokens.
                threshold = float(thresholds["chunk_gap_p99_upper_bound_max"])
                failing_side = sum(1 for x in draws_for_metric if x >= threshold)
            else:
                threshold = float(thresholds["rejection_increase_max_pp"])
                failing_side = sum(1 for x in draws_for_metric if x >= threshold)
            # One-sided p-value for H0 "the gate is not met", by inverting the
            # paired percentile bootstrap: the smallest alpha at which the
            # one-sided bound clears the threshold. The +1 correction keeps a
            # finite number of draws from ever reporting p = 0; no draws means
            # no evidence (p = 1).
            p_value = (failing_side + 1) / (len(draws_for_metric) + 1) if draws_for_metric else 1.0
            hypotheses.append((p_value, cell, metric_name, threshold))

    # Holm step-down across every gated hypothesis in every cell: once the
    # k-th smallest p-value misses alpha/(m-k+1), it and every later
    # hypothesis fail, whatever their own bounds say.
    adjusted = _holm_adjusted([item[0] for item in hypotheses])
    order = sorted(range(len(hypotheses)), key=lambda i: hypotheses[i][0])
    m = len(hypotheses)
    for rank, index in enumerate(order):
        p_value, cell, metric_name, threshold = hypotheses[index]
        adjusted_alpha = alpha / max(1, m - rank)
        metric = cell["metrics"][metric_name]
        draws_for_metric = metric.pop("draws")
        if metric_name == "throughput":
            metric["corrected_lower_bound"] = _percentile(draws_for_metric, adjusted_alpha)
        else:
            metric["corrected_upper_bound"] = _percentile(draws_for_metric, 1.0 - adjusted_alpha)
        metric["holm_rank"] = rank + 1
        metric["holm_alpha"] = adjusted_alpha
        metric["confidence_level"] = 1.0 - adjusted_alpha
        metric["p_value"] = p_value
        metric["holm_adjusted_p_value"] = adjusted[index]
        metric["threshold"] = threshold
        metric["status"] = "PASS" if adjusted[index] <= alpha else "FAIL"

    min_available = float(thresholds["min_available_memory_fraction"])
    for cell in cell_results:
        metric_failures = [name for name, metric in cell["metrics"].items() if metric["status"] != "PASS"]
        memory_failures = []
        if cell["min_available_memory_fraction"] < min_available:
            memory_failures.append("min_available_memory_fraction")
        # Judged only on recorded sustained runs: a cell analyzed without its
        # sustained window (an exploratory matrix-only policy) has no window
        # to judge, and a required window that is absent already failed the
        # cell as `sustained_missing`.
        if (
            cell["cell_id"] == policy.get("sustained_cell_id")
            and cell["sustained_runs"] > 0
            and cell["sustained_min_available_memory_fraction"] < min_available
        ):
            memory_failures.append("sustained_min_available_memory_fraction")
        if ram_bytes > 0 and cell["peak_phys_footprint_bytes"] + memory_margin > ram_bytes:
            memory_failures.append("peak_plus_margin_exceeds_ram")
        cell["status"] = "PASS" if not cell["hard_failures"] and not metric_failures and not memory_failures else "FAIL"
        cell["metric_failures"] = metric_failures
        cell["memory_failures"] = memory_failures

    overall = "PASS" if all(cell["status"] == "PASS" for cell in cell_results) else "FAIL"
    # Pilot data never yields an admission verdict, whatever its numbers say.
    if _is_exploratory(policy) or header.get("exploratory") is True:
        if _is_exploratory(policy) != (header.get("exploratory") is True):
            overall = "FAIL"
        else:
            overall = "EXPLORATORY_NO_VERDICT"
    elif reanalysis_of is not None:
        overall = "EXPLORATORY_NO_VERDICT"
    return {
        "schema": "macprovider.native-mtp-r015-analysis.v1",
        "overall_status": overall,
        "gate_set": gate_set,
        **({"exploratory_reanalysis_of_gate_set": reanalysis_of} if reanalysis_of else {}),
        "policy_sha256": policy_sha,
        "provider_commit": header.get("provider_commit"),
        "unavailable_metrics": header.get("unavailable_metrics", []),
        "cells": cell_results,
    }


def markdown_table(result: dict) -> str:
    amended = result.get("gate_set") == GATE_SET_AMENDED
    latency_header = "TPOT p95 UB | Gap p99 UB" if amended else "ITL UB"
    lines = [
        f"| Cell | Status | Blocks | Decode ratio | Decode LB | TTFT UB | {latency_header} | Rejection UB | E2E ratio (info) | Hard failures |",
        "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |"
        if amended
        else "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |",
    ]
    for cell in result.get("cells", []):
        metrics = cell["metrics"]
        failures = cell["hard_failures"] + [f"memory:{name}" for name in cell.get("memory_failures", [])]
        hard = ",".join(failures) if failures else "-"
        lines.append(
            "| {cell} | {status} | {blocks}/{required} | {ratio} | {thr} | {ttft} | {itl} | {rej} | {e2e} | {hard} |".format(
                cell=cell["cell_id"],
                status=cell["status"],
                blocks=cell["paired_blocks"],
                required=cell["required_blocks"],
                ratio=_fmt_ratio(metrics["throughput"].get("median")),
                thr=_fmt(metrics["throughput"].get("corrected_lower_bound")),
                e2e=_fmt_ratio(cell["informational_metrics"]["end_to_end_throughput"]["median"]),
                ttft=_fmt(metrics["ttft"].get("corrected_upper_bound")),
                itl=(
                    _fmt(metrics["tpot"].get("corrected_upper_bound")) + " | " + _fmt(metrics["chunk_gap_p99"].get("corrected_upper_bound"))
                    if amended
                    else _fmt(metrics["itl"].get("corrected_upper_bound"))
                ),
                rej=_fmt(metrics["rejection"].get("corrected_upper_bound")),
                hard=hard,
            )
        )
    return "\n".join(lines)


def _fmt(value: float | None) -> str:
    return "null" if value is None else f"{value:.6g}"


def _fmt_ratio(delta: float | None) -> str:
    """Native/ordinary ratio from a ratio-minus-one statistic."""
    return "null" if delta is None else f"{delta + 1.0:.4g}"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("jsonl", type=Path)
    parser.add_argument("policy", type=Path)
    parser.add_argument(
        "--format",
        choices=("json", "markdown"),
        default="json",
        help="json (default) prints one parseable JSON document; markdown prints the summary table.",
    )
    parser.add_argument(
        "--exploratory-amended-gates",
        action="store_true",
        help="re-read a legacy-gate policy's records under the SPEC-048 0.1.25 gates; never a verdict.",
    )
    args = parser.parse_args(argv)
    result = analyze(args.jsonl, args.policy, exploratory_amended_gates=args.exploratory_amended_gates)
    if args.format == "json":
        print(json.dumps(result, indent=2, sort_keys=True))
    else:
        print(markdown_table(result))
    return 0 if result["overall_status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
