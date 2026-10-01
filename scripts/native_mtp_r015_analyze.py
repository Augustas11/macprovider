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


def _load_policy(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as fh:
        return json.load(fh)


def _is_exploratory(policy: dict) -> bool:
    return policy.get("schema") == EXPLORATORY_POLICY_SCHEMA


# SPEC-048-R015 mandatory strata; R007 additionally requires a cell at every
# slot count from one up to the advertised qualified_slots.
MANDATORY_PROMPT_TOKENS = (1536, 4096, 8192)
MANDATORY_MAX_TOKENS = (128, 512)


def _is_int(value) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _matrix_violations(policy: dict) -> list[str]:
    """Mandatory-matrix violations of an admission (non-exploratory) policy."""
    if _is_exploratory(policy):
        return []
    violations: list[str] = []
    qualified = policy.get("qualified_slots")
    if not _is_int(qualified) or not 2 <= qualified <= 8:
        return ["qualified_slots_missing_or_out_of_range"]
    bound = policy.get("max_native_active_rows")
    if not _is_int(bound) or not 1 <= bound <= qualified:
        violations.append("max_native_active_rows_missing_or_out_of_range")
    slots = policy.get("slots")
    prompts = policy.get("prompt_tokens")
    outputs = policy.get("max_tokens")
    for key, value in (("slots", slots), ("prompt_tokens", prompts), ("max_tokens", outputs)):
        if not isinstance(value, list) or not all(_is_int(v) for v in value):
            violations.append(f"{key}_malformed")
    if violations:
        return violations
    missing_slots = sorted(set(range(1, qualified + 1)) - set(slots))
    if missing_slots:
        violations.append("slots_missing:" + ",".join(map(str, missing_slots)))
    over_slots = sorted(v for v in set(slots) if v > qualified or v < 1)
    if over_slots:
        violations.append("slots_outside_qualified:" + ",".join(map(str, over_slots)))
    missing_prompts = sorted(set(MANDATORY_PROMPT_TOKENS) - set(prompts))
    if missing_prompts:
        violations.append("prompt_tokens_missing:" + ",".join(map(str, missing_prompts)))
    missing_outputs = sorted(set(MANDATORY_MAX_TOKENS) - set(outputs))
    if missing_outputs:
        violations.append("max_tokens_missing:" + ",".join(map(str, missing_outputs)))
    if policy.get("sustained_cell_id") not in _observed_cells(policy):
        violations.append("sustained_cell_not_in_matrix")
    return violations


GATED_THRESHOLD_KEYS = (
    "gated_throughput_lower_bound_min",
    "gated_ttft_p95_upper_bound_max",
    "gated_itl_p95_upper_bound_max",
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


def _load_jsonl(path: Path) -> tuple[dict, list[dict]]:
    header = None
    runs: list[dict] = []
    with path.open("r", encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, 1):
            line = line.strip()
            if not line:
                continue
            record = json.loads(line)
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


def _invalid_run_fields(run: dict) -> list[str]:
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
    if name == "rejection":
        ordinary_rate = float(ordinary["capacity_rejections"]) / float(ordinary["requests"])
        native_rate = float(native["capacity_rejections"]) / float(native["requests"])
        return (native_rate - ordinary_rate) * 100.0
    raise AssertionError(name)


# R015 reporting family: every metric the campaign must report with a median
# and corrected confidence interval, per path, from the same paired blocks.
def _reported_values(run: dict) -> dict[str, float | None]:
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
    }


def _report_metrics(pairs: list[tuple[dict, dict]], draws: int, alpha: float, seed: int) -> dict:
    """Median and Bonferroni-corrected two-sided percentile bootstrap CI over
    whole paired blocks for every reported metric and path."""
    per_block = [
        {"ordinary": _reported_values(ordinary), "native_mtp": _reported_values(native)}
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
    values: list[float] = []
    for _ in range(draws):
        sample = [_metric(pairs[rng.randrange(n)], metric_name) for _ in range(n)]
        values.append(statistics.median(sample))
    return values


def _observed_cells(policy: dict) -> list[str]:
    cells = []
    for slots in policy["slots"]:
        for prompt in policy["prompt_tokens"]:
            for max_tokens in policy["max_tokens"]:
                cells.append(f"s{slots}-p{prompt}-o{max_tokens}")
    return cells


def _pair_runs(runs: list[dict], cell_id: str) -> tuple[list[tuple[dict, dict]], list[str]]:
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
    for block in sorted(by_block):
        item = by_block[block]
        if "ordinary" not in item or "native_mtp" not in item:
            issues.append(f"block {block} missing paired path")
            continue
        pairs.append((item["ordinary"], item["native_mtp"]))
    return pairs, issues


def analyze(jsonl_path: Path, policy_path: Path) -> dict:
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
    bound = _native_bound(policy)
    if any(_is_gated_cell(cell_id, bound) for cell_id in _observed_cells(policy)) and any(
        not isinstance(thresholds.get(key), (int, float))
        or isinstance(thresholds.get(key), bool)
        or not math.isfinite(thresholds[key])
        for key in GATED_THRESHOLD_KEYS
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
        pairs, issues = _pair_runs(runs, cell_id)
        hard_failures = list(issues)
        if len(pairs) < required_blocks:
            hard_failures.append(f"incomplete: {len(pairs)}/{required_blocks} paired blocks")
        sustained_runs = [
            run for run in runs
            if run.get("cell_id") == cell_id and run.get("sustained") is True and run.get("warmup") is not True
        ]
        hard_gate_runs = [run for pair in pairs for run in pair] + sustained_runs
        invalid_records = [
            f"invalid_run_record:{run.get('path')}:{run.get('block_index')}:{','.join(fields)}"
            for run in hard_gate_runs
            if (fields := _invalid_run_fields(run))
        ]
        hard_failures.extend(invalid_records)
        # Only fully valid records feed any statistic; an invalid record has
        # already failed the cell above.
        pairs = [pair for pair in pairs if not _invalid_run_fields(pair[0]) and not _invalid_run_fields(pair[1])]
        sustained_runs = [run for run in sustained_runs if not _invalid_run_fields(run)]
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
        for metric_name in ("throughput", "ttft", "itl", "rejection"):
            observed = [_metric(pair, metric_name) for pair in usable_pairs]
            median = _median(observed)
            boot = _bootstrap(usable_pairs, metric_name, draws, base_seed + cell_index * 17 + len(metric_name)) if usable_pairs else []
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
            "reported_metrics": _report_metrics(pairs, draws, alpha, base_seed + cell_index * 17 + 101),
            "peak_phys_footprint_bytes": max([r["peak_phys_footprint_bytes"] for r in hard_gate_runs] or [0]),
            "min_available_memory_fraction": min([float(r["min_available_memory_fraction"]) for r in hard_gate_runs] or [0]),
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
        if cell["cell_id"] == policy.get("sustained_cell_id") and cell["sustained_min_available_memory_fraction"] < min_available:
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
    return {
        "schema": "macprovider.native-mtp-r015-analysis.v1",
        "overall_status": overall,
        "policy_sha256": policy_sha,
        "provider_commit": header.get("provider_commit"),
        "unavailable_metrics": header.get("unavailable_metrics", []),
        "cells": cell_results,
    }


def markdown_table(result: dict) -> str:
    lines = [
        "| Cell | Status | Blocks | Decode ratio | Decode LB | TTFT UB | ITL UB | Rejection UB | E2E ratio (info) | Hard failures |",
        "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |",
    ]
    for cell in result.get("cells", []):
        metrics = cell["metrics"]
        hard = ",".join(cell["hard_failures"]) if cell["hard_failures"] else "-"
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
                itl=_fmt(metrics["itl"].get("corrected_upper_bound")),
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
    args = parser.parse_args(argv)
    result = analyze(args.jsonl, args.policy)
    if args.format == "json":
        print(json.dumps(result, indent=2, sort_keys=True))
    else:
        print(markdown_table(result))
    return 0 if result["overall_status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
