#!/usr/bin/env python3
"""Analyze SPEC-048-R015 native-MTP JSONL benchmark evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import random
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


def _metric(pair: tuple[dict, dict], name: str) -> float:
    ordinary, native = pair
    if name == "throughput":
        return _safe_ratio(float(native.get("aggregate_committed_tps", 0.0)), float(ordinary.get("aggregate_committed_tps", 0.0))) - 1.0
    if name == "ttft":
        return _safe_ratio(float(native.get("ttft_p95_seconds", 0.0)), float(ordinary.get("ttft_p95_seconds", 0.0))) - 1.0
    if name == "itl":
        return _safe_ratio(float(native.get("inter_token_gap_p95_seconds", 0.0)), float(ordinary.get("inter_token_gap_p95_seconds", 0.0))) - 1.0
    if name == "rejection":
        ordinary_requests = max(1.0, float(ordinary.get("requests", 0)))
        native_requests = max(1.0, float(native.get("requests", 0)))
        ordinary_rate = float(ordinary.get("capacity_rejections", 0)) / ordinary_requests
        native_rate = float(native.get("capacity_rejections", 0)) / native_requests
        return (native_rate - ordinary_rate) * 100.0
    raise AssertionError(name)


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
    diagnostic_modes = [
        name
        for name, enabled in (
            ("native_mtp_profile", header.get("native_mtp_profile") is True),
            ("ordinary_self_check", header.get("ordinary_self_check") is True),
        )
        if enabled
    ]
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
        pairs, issues = _pair_runs(runs, cell_id)
        hard_failures = list(issues)
        if len(pairs) < required_blocks:
            hard_failures.append(f"incomplete: {len(pairs)}/{required_blocks} paired blocks")
        sustained_runs = [
            run for run in runs
            if run.get("cell_id") == cell_id and run.get("sustained") is True and run.get("warmup") is not True
        ]
        hard_gate_runs = [run for pair in pairs for run in pair] + sustained_runs
        parity_evidence_invalid = any(
            not isinstance(r.get("parity_hard_mismatch"), bool)
            or isinstance(r.get("parity_tolerated_ties"), bool)
            or not isinstance(r.get("parity_tolerated_ties"), int)
            or r["parity_tolerated_ties"] < 0
            for r in hard_gate_runs
        )
        native_runs = [r for r in hard_gate_runs if r.get("path") == "native_mtp"]
        parity_hard_mismatches = sum(
            int(r["parity_hard_mismatch"])
            for r in native_runs
            if isinstance(r.get("parity_hard_mismatch"), bool)
        )
        parity_tolerated_ties = sum(
            r["parity_tolerated_ties"]
            for r in native_runs
            if isinstance(r.get("parity_tolerated_ties"), int)
            and not isinstance(r.get("parity_tolerated_ties"), bool)
            and r["parity_tolerated_ties"] >= 0
        )
        non_native_admissions = sum(int(r.get("non_native_admissions", 0)) for r in hard_gate_runs)
        missing_native_admissions = sum(
            max(0, int(r.get("native_requests", 0)) - int(r.get("native_admissions", 0)))
            for r in hard_gate_runs
            if r.get("path") == "native_mtp"
        )
        fallback_errors = sum(int(r.get("fallbacks", 0)) + int(r.get("errors", 0)) for r in hard_gate_runs)
        if parity_evidence_invalid:
            hard_failures.append("parity_evidence_missing_or_invalid")
        if parity_hard_mismatches:
            hard_failures.append("parity_hard_mismatch")
        if non_native_admissions:
            hard_failures.append("non_native_admissions")
        if missing_native_admissions:
            hard_failures.append("missing_native_admissions")
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
            and any(run.get(field) is None for run in native_runs)
        ]
        if missing_counter_fields:
            hard_failures.append("native_mtp_counters_missing:" + ",".join(missing_counter_fields))
        if "mtp_proposed_tokens" not in unavailable_metrics and any(
            int(run.get("mtp_proposed_tokens") or 0) <= 0 for run in native_runs
        ):
            hard_failures.append("native_mtp_proposals_missing")
        if "target_forwards" not in unavailable_metrics and any(
            int(run.get("target_forwards") or 0) <= 0 for run in native_runs
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
        if any(r.get("peak_phys_footprint_bytes") is None for r in hard_gate_runs):
            hard_failures.append("peak_phys_footprint_missing")
        if any(r.get("min_available_memory_fraction") is None for r in hard_gate_runs):
            hard_failures.append("available_memory_missing")
        if any(r.get("min_available_memory_fraction") is None for r in sustained_runs):
            hard_failures.append("sustained_available_memory_missing")

        metrics = {}
        usable_pairs = pairs if pairs else []
        for metric_name in ("throughput", "ttft", "itl", "rejection"):
            observed = [_metric(pair, metric_name) for pair in usable_pairs]
            median = _median(observed)
            boot = _bootstrap(usable_pairs, metric_name, draws, base_seed + cell_index * 17 + len(metric_name)) if usable_pairs else []
            metrics[metric_name] = {"median": median, "draws": boot}

        cell = {
            "cell_id": cell_id,
            "paired_blocks": len(pairs),
            "required_blocks": required_blocks,
            "hard_failures": hard_failures,
            "parity_hard_mismatches": parity_hard_mismatches,
            "parity_tolerated_ties": parity_tolerated_ties,
            "metrics": metrics,
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
            "peak_phys_footprint_bytes": max([int(r.get("peak_phys_footprint_bytes") or 0) for r in hard_gate_runs] or [0]),
            "min_available_memory_fraction": min([float(r.get("min_available_memory_fraction") or 0) for r in hard_gate_runs] or [0]),
            "sustained_duration_seconds": sustained_duration_seconds,
            "sustained_min_available_memory_fraction": min([float(r.get("min_available_memory_fraction") or 0) for r in sustained_runs] or [0]),
            "thermal_start_states": sorted({str(r.get("thermal_state_start")) for r in hard_gate_runs}),
            "thermal_end_states": sorted({str(r.get("thermal_state_end")) for r in hard_gate_runs}),
        }
        cell_results.append(cell)
        for metric_name, metric in metrics.items():
            draws_for_metric = metric["draws"]
            if metric_name == "throughput":
                threshold = float(thresholds["throughput_lower_bound_min"])
                p_value = sum(1 for x in draws_for_metric if x < threshold) / max(1, len(draws_for_metric))
            elif metric_name == "ttft":
                threshold = float(thresholds["ttft_p95_upper_bound_max"])
                p_value = sum(1 for x in draws_for_metric if x > threshold) / max(1, len(draws_for_metric))
            elif metric_name == "itl":
                threshold = float(thresholds["itl_p95_upper_bound_max"])
                p_value = sum(1 for x in draws_for_metric if x > threshold) / max(1, len(draws_for_metric))
            else:
                threshold = float(thresholds["rejection_increase_max_pp"])
                p_value = sum(1 for x in draws_for_metric if x > threshold) / max(1, len(draws_for_metric))
            hypotheses.append((p_value, cell, metric_name, threshold))

    hypotheses.sort(key=lambda item: item[0])
    m = len(hypotheses)
    for rank, (p_value, cell, metric_name, threshold) in enumerate(hypotheses):
        adjusted_alpha = alpha / max(1, m - rank)
        metric = cell["metrics"][metric_name]
        draws_for_metric = metric.pop("draws")
        if metric_name == "throughput":
            bound = _percentile(draws_for_metric, adjusted_alpha)
            passed = bound is not None and bound >= threshold
            metric["corrected_lower_bound"] = bound
        else:
            bound = _percentile(draws_for_metric, 1.0 - adjusted_alpha)
            passed = bound is not None and bound <= threshold
            metric["corrected_upper_bound"] = bound
        metric["holm_rank"] = rank + 1
        metric["holm_alpha"] = adjusted_alpha
        metric["confidence_level"] = 1.0 - adjusted_alpha
        metric["p_value"] = p_value
        metric["threshold"] = threshold
        metric["status"] = "PASS" if passed else "FAIL"

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
    elif diagnostic_modes and overall == "PASS":
        overall = "DIAGNOSTIC_NO_VERDICT"
    return {
        "schema": "macprovider.native-mtp-r015-analysis.v1",
        "overall_status": overall,
        "policy_sha256": policy_sha,
        "provider_commit": header.get("provider_commit"),
        "diagnostic_modes": diagnostic_modes,
        "unavailable_metrics": header.get("unavailable_metrics", []),
        "cells": cell_results,
    }


def markdown_table(result: dict) -> str:
    lines = [
        "| Cell | Status | Blocks | Throughput LB | TTFT UB | ITL UB | Rejection UB | Hard failures |",
        "| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |",
    ]
    for cell in result.get("cells", []):
        metrics = cell["metrics"]
        hard = ",".join(cell["hard_failures"]) if cell["hard_failures"] else "-"
        lines.append(
            "| {cell} | {status} | {blocks}/{required} | {thr} | {ttft} | {itl} | {rej} | {hard} |".format(
                cell=cell["cell_id"],
                status=cell["status"],
                blocks=cell["paired_blocks"],
                required=cell["required_blocks"],
                thr=_fmt(metrics["throughput"].get("corrected_lower_bound")),
                ttft=_fmt(metrics["ttft"].get("corrected_upper_bound")),
                itl=_fmt(metrics["itl"].get("corrected_upper_bound")),
                rej=_fmt(metrics["rejection"].get("corrected_upper_bound")),
                hard=hard,
            )
        )
    return "\n".join(lines)


def _fmt(value: float | None) -> str:
    return "null" if value is None else f"{value:.6g}"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("jsonl", type=Path)
    parser.add_argument("policy", type=Path)
    args = parser.parse_args(argv)
    result = analyze(args.jsonl, args.policy)
    print(json.dumps(result, indent=2, sort_keys=True))
    print()
    print(markdown_table(result))
    return 0 if result["overall_status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
