"""
SPEC-029 workload-class sweep helpers.

This module is deliberately pure: the harness records raw rows, then the
selector turns evaluated search cells into partition-local winner/no-winner
profiles for reports or future static-catalog publication.
"""

from __future__ import annotations

import json
import os
import statistics
from dataclasses import dataclass
from typing import Any, NamedTuple

try:
    import workloads
except ImportError:  # pragma: no cover - package-relative test imports
    from . import workloads  # type: ignore


INCLUDED_WORKLOADS = frozenset({
    "short_chat",
    "medium_with_system",
    "long_context",
    "code_completion",
    "agent_style",
})
PROBE_ONLY_WORKLOADS = frozenset({"streaming_check"})
ALL_SPEC029_WORKLOADS = INCLUDED_WORKLOADS | PROBE_ONLY_WORKLOADS
RAM_TIER_KEYS = frozenset({"8gb", "16gb", "32gb", "64gb_plus"})
NO_WINNER_REASONS = frozenset({
    "insufficient_samples",
    "gate_unmet",
    "hard_failure",
    "no_cells_evaluated",
})
RUNNABLE_CELL_EXECUTION_SOURCES = frozenset({
    "cell_control_url",
    "cell_apply_command",
})
NON_RUNNABLE_CELL_EXECUTION_SOURCES = frozenset({"cell_apply_failed"})
EVALUATED_CELL_EXECUTION_SOURCES = RUNNABLE_CELL_EXECUTION_SOURCES | NON_RUNNABLE_CELL_EXECUTION_SOURCES

SPEC028_DRAFT_CONTEXT_CAPS = {
    "8gb": 8_192,
    "16gb": 20_000,
    "32gb": 50_000,
    "64gb_plus": 120_000,
}

APPROVED_DRAFT_SOURCE_PREFIXES = (
    "static_draft_candidates:",
    "research_fixture:",
    "local_operator_override:",
)

DEFAULT_SWEEP_CELLS = (
    {
        "kv_bits": 8,
        "max_context_override": 8_192,
        "max_concurrency_override": 1,
    },
    {
        "kv_bits": 4,
        "max_context_override": 20_000,
        "max_concurrency_override": 1,
    },
)


class ProviderRAM(NamedTuple):
    host_ram_bytes: int | None
    ram_tier_key: str | None
    source: str


@dataclass(frozen=True)
class GatePolicy:
    min_samples: int
    max_p95_ttft_ms: int
    max_stop_token_leak_rate: float = 0.0
    min_median_tps: float | None = None

    def as_json(self) -> dict[str, Any]:
        return {
            "min_samples": self.min_samples,
            "max_p95_ttft_ms": self.max_p95_ttft_ms,
            "max_stop_token_leak_rate": self.max_stop_token_leak_rate,
            "min_median_tps": self.min_median_tps,
        }


GATE_POLICIES = {
    "short_chat": GatePolicy(20, 8_000),
    "medium_with_system": GatePolicy(20, 12_000),
    "long_context": GatePolicy(20, 60_000),
    "code_completion": GatePolicy(20, 12_000),
    "agent_style": GatePolicy(20, 20_000),
    "streaming_check": GatePolicy(20, 2_000),
}


@dataclass(frozen=True)
class SearchCellResult:
    workload_name: str
    ram_tier_key: str
    kv_bits: int
    max_context_override: int
    max_concurrency_override: int
    successful_sample_count: int
    p95_ttft_ms: float | None
    median_tps: float | None
    stop_token_leak_rate: float
    hard_failure_count: int = 0
    non_runnable_reason: str | None = None
    draft_model: str | None = None
    draft_model_artifact_sha256: str | None = None
    num_draft_tokens: int | None = None
    spec_decode_acceptance_rate: float | None = None
    candidate_source: str | None = None
    model: str | None = None

    @property
    def draft_validation_error(self) -> str | None:
        if not self.draft_model:
            if self.draft_model_artifact_sha256 is not None or self.num_draft_tokens is not None:
                return "partial_speculative_tuple"
            return None
        if not self.candidate_source:
            return "missing_candidate_source"
        if not self.candidate_source.startswith(APPROVED_DRAFT_SOURCE_PREFIXES):
            return "unapproved_candidate_source"
        if not self.draft_model_artifact_sha256 or not _is_lower_hex(self.draft_model_artifact_sha256, 64):
            return "invalid_draft_model_artifact_sha256"
        if self.num_draft_tokens is None or not 1 <= self.num_draft_tokens <= 16:
            return "invalid_num_draft_tokens"
        if self.max_concurrency_override > 1:
            return "draft_concurrency_cap_exceeded"
        cap = SPEC028_DRAFT_CONTEXT_CAPS[self.ram_tier_key]
        if self.max_context_override > cap:
            return "draft_context_cap_exceeded"
        return None

    @property
    def runnable(self) -> bool:
        return self.non_runnable_reason is None and self.draft_validation_error is None

    @property
    def produced_successful_sample(self) -> bool:
        return self.successful_sample_count > 0 and self.runnable

    @property
    def hard_failed(self) -> bool:
        return not self.runnable or self.successful_sample_count == 0

    def reached_min_samples(self, policy: GatePolicy) -> bool:
        return self.produced_successful_sample and self.successful_sample_count >= policy.min_samples

    def passes_hard_gates(self, policy: GatePolicy) -> bool:
        return (
            self.reached_min_samples(policy)
            and self.p95_ttft_ms is not None
            and self.p95_ttft_ms <= policy.max_p95_ttft_ms
            and self.stop_token_leak_rate <= policy.max_stop_token_leak_rate
            and self.runnable
        )

    def recommended_json(self) -> dict[str, Any]:
        if self.draft_validation_error is not None:
            raise ValueError(f"invalid SPEC-029 speculative tuple: {self.draft_validation_error}")
        out: dict[str, Any] = {
            "kv_bits": self.kv_bits,
            "max_context_override": self.max_context_override,
            "max_concurrency_override": self.max_concurrency_override,
        }
        if self.draft_model:
            out["draft_model"] = self.draft_model
            out["draft_model_artifact_sha256"] = self.draft_model_artifact_sha256
            out["num_draft_tokens"] = self.num_draft_tokens
        return out


@dataclass(frozen=True)
class SelectionResult:
    workload_name: str
    ram_tier_key: str
    gate_policy: GatePolicy
    winner: SearchCellResult | None
    no_winner_reason: str | None
    evaluated_cell_count: int
    highest_successful_sample_count: int
    tie_breaker_reason: str | None

    @property
    def status(self) -> str:
        return "winner" if self.winner is not None else "no_winner"


def host_ram_bytes() -> int | None:
    try:
        pages = os.sysconf("SC_PHYS_PAGES")
        page_size = os.sysconf("SC_PAGE_SIZE")
        if pages > 0 and page_size > 0:
            return int(pages * page_size)
    except (OSError, ValueError, AttributeError):
        return None
    return None


def ram_tier_key_for_gib(physical_memory_gib: int | float) -> str:
    if physical_memory_gib <= 12:
        return "8gb"
    if physical_memory_gib <= 24:
        return "16gb"
    if physical_memory_gib <= 48:
        return "32gb"
    return "64gb_plus"


def ram_tier_key_for_bytes(physical_memory_bytes: int) -> str:
    gib = physical_memory_bytes / (1024 ** 3)
    return ram_tier_key_for_gib(gib)


def normalize_provider_ram_tier(raw: str) -> str:
    normalized = raw.strip().lower()
    if normalized in {"8gb", "16gb", "32gb"}:
        return normalized
    if normalized == "64gb+":
        return "64gb_plus"
    raise ValueError(f"invalid SPEC-029 RAM-tier string: {raw!r}")


def resolve_provider_ram(cfg: dict[str, Any], require: bool = False) -> ProviderRAM:
    """Resolve the measured provider/sweep-host RAM from config.

    The beta harness often runs buyer-side against a remote provider, so SPEC-029
    sweep artifacts must prefer explicit provider metadata over local machine RAM.
    """
    explicit = _provider_ram_from_mapping(cfg, "config")
    if explicit.ram_tier_key:
        return explicit

    selected = cfg.get("_selected_model_entry")
    if isinstance(selected, dict):
        entry = _provider_ram_from_mapping(selected, "selected_model")
        if entry.ram_tier_key:
            return entry

    if require:
        raise ValueError(
            "SPEC-029 sweep requires provider_host_ram_bytes, provider_ram_gib, "
            "or provider_ram_tier in config or selected model entry"
        )

    local = host_ram_bytes()
    return ProviderRAM(
        local,
        ram_tier_key_for_bytes(local) if local else None,
        "local_harness_fallback",
    )


def _provider_ram_from_mapping(mapping: dict[str, Any], source: str) -> ProviderRAM:
    raw_bytes = mapping.get("provider_host_ram_bytes") or mapping.get("host_ram_bytes")
    if raw_bytes is not None:
        host_ram = int(raw_bytes)
        if host_ram <= 0:
            raise ValueError(f"{source}: provider host RAM bytes must be positive")
        return ProviderRAM(host_ram, ram_tier_key_for_bytes(host_ram), source)

    raw_gib = mapping.get("provider_ram_gib") or mapping.get("ram_gib")
    if raw_gib is not None:
        gib = float(raw_gib)
        if gib <= 0:
            raise ValueError(f"{source}: provider RAM GiB must be positive")
        return ProviderRAM(int(gib * 1024 ** 3), ram_tier_key_for_gib(gib), source)

    raw_tier = mapping.get("provider_ram_tier") or mapping.get("ram_tier")
    if raw_tier:
        return ProviderRAM(None, normalize_provider_ram_tier(str(raw_tier)), source)

    return ProviderRAM(None, None, source)


def _is_lower_hex(value: str, count: int) -> bool:
    return len(value) == count and all(ch in "0123456789abcdef" for ch in value)


def corpus_class_for_workload(workload_name: str) -> str | None:
    return workloads._WORKLOAD_CORPUS_MAP.get(workload_name)


def gate_policy_for_workload(workload_name: str) -> GatePolicy:
    try:
        return GATE_POLICIES[workload_name]
    except KeyError as exc:
        raise ValueError(f"unknown SPEC-029 workload: {workload_name}") from exc


def is_publishable_workload(workload_name: str) -> bool:
    return workload_name in INCLUDED_WORKLOADS


def metric_unavailable_reason(
    prompt_tokens: int | None,
    completion_tokens: int | None,
    throughput_tps: float | None,
) -> str | None:
    missing: list[str] = []
    if prompt_tokens is None:
        missing.append("missing_prompt_tokens")
    if completion_tokens is None:
        missing.append("missing_completion_tokens")
    if throughput_tps is None:
        missing.append("missing_throughput_tps")
    return ",".join(missing) if missing else None


def sweep_cell_from_config(cfg: dict[str, Any]) -> dict[str, Any]:
    cell = dict(cfg.get("sweep_cell") or {})
    for key in [
        "max_context_override",
        "max_concurrency_override",
        "kv_bits",
        "draft_model",
        "draft_model_artifact_sha256",
        "num_draft_tokens",
        "candidate_source",
    ]:
        if key in cfg and key not in cell:
            cell[key] = cfg[key]
    return cell


def sweep_cells_from_config(cfg: dict[str, Any], require_grid: bool = False) -> list[dict[str, Any]]:
    spec_cfg = cfg.get("spec029_sweep") or {}
    raw_cells = spec_cfg.get("cells") or cfg.get("sweep_cells")
    if raw_cells is None:
        raw_grid = spec_cfg.get("grid") or cfg.get("sweep_grid")
        raw_cells = expand_sweep_grid(raw_grid) if raw_grid else None

    if raw_cells is None:
        if require_grid:
            raise ValueError("SPEC-029 sweep requires explicit spec029_sweep.cells or spec029_sweep.grid")
        else:
            raw_cells = [sweep_cell_from_config(cfg)]

    cells = [normalize_sweep_cell(cell, cfg) for cell in raw_cells]
    if require_grid and not cells:
        raise ValueError("SPEC-029 sweep requires at least one configured search cell")
    return cells


def expand_sweep_grid(raw_grid: dict[str, Any]) -> list[dict[str, Any]]:
    if not isinstance(raw_grid, dict):
        raise ValueError("SPEC-029 sweep grid must be a mapping")
    kv_values = raw_grid.get("kv_bits", [4])
    context_values = raw_grid.get("max_context_override", [20_000])
    concurrency_values = raw_grid.get("max_concurrency_override", [1])
    draft_entries = raw_grid.get("draft_candidates") or [None]
    cells: list[dict[str, Any]] = []
    for kv_bits in _as_list(kv_values):
        for context in _as_list(context_values):
            for concurrency in _as_list(concurrency_values):
                for draft in _as_list(draft_entries):
                    cell = {
                        "kv_bits": kv_bits,
                        "max_context_override": context,
                        "max_concurrency_override": concurrency,
                    }
                    if draft:
                        if not isinstance(draft, dict):
                            raise ValueError("SPEC-029 draft grid entries must be mappings")
                        cell.update(draft)
                    cells.append(cell)
    return cells


def normalize_sweep_cell(cell: dict[str, Any], cfg: dict[str, Any] | None = None) -> dict[str, Any]:
    if not isinstance(cell, dict):
        raise ValueError("SPEC-029 sweep cell must be a mapping")
    cfg = cfg or {}
    merged = dict(cell)
    for key in [
        "max_context_override",
        "max_concurrency_override",
        "kv_bits",
        "draft_model",
        "draft_model_artifact_sha256",
        "num_draft_tokens",
        "candidate_source",
    ]:
        if key in cfg and key not in merged:
            merged[key] = cfg[key]
    for key in ["kv_bits", "max_context_override", "max_concurrency_override"]:
        if key not in merged:
            raise ValueError(f"SPEC-029 sweep cell missing {key}")
        merged[key] = int(merged[key])
    if "num_draft_tokens" in merged and merged["num_draft_tokens"] is not None:
        merged["num_draft_tokens"] = int(merged["num_draft_tokens"])
    return merged


def spec029_workloads_from_config(cfg: dict[str, Any]) -> list[str]:
    spec_cfg = cfg.get("spec029_sweep") or {}
    workloads_list = list(spec_cfg.get("workloads") or cfg.get("spec029_batch") or sorted(INCLUDED_WORKLOADS) + sorted(PROBE_ONLY_WORKLOADS))
    invalid = [name for name in workloads_list if name not in ALL_SPEC029_WORKLOADS]
    if invalid:
        raise ValueError(f"SPEC-029 sweep cannot run workload(s): {', '.join(invalid)}")
    return workloads_list


def spec029_samples_per_cell(cfg: dict[str, Any]) -> int:
    spec_cfg = cfg.get("spec029_sweep") or {}
    samples = int(spec_cfg.get("samples_per_cell") or cfg.get("spec029_samples_per_cell") or 1)
    if samples <= 0:
        raise ValueError("SPEC-029 samples_per_cell must be positive")
    return samples


def _as_list(value: Any) -> list[Any]:
    return value if isinstance(value, list) else [value]


def choose_partition(
    cells: list[SearchCellResult],
    workload_name: str,
    ram_tier_key: str,
    model: str | None = None,
) -> SelectionResult:
    if workload_name in PROBE_ONLY_WORKLOADS:
        raise ValueError(f"{workload_name} is probe-only and cannot publish a winner")
    if workload_name not in INCLUDED_WORKLOADS:
        raise ValueError(f"{workload_name} is not included in SPEC-029 v0.1")
    if ram_tier_key not in RAM_TIER_KEYS:
        raise ValueError(f"invalid RAM-tier key: {ram_tier_key}")

    partition = [
        cell for cell in cells
        if cell.workload_name == workload_name and cell.ram_tier_key == ram_tier_key
        and (model is None or cell.model == model)
    ]
    policy = gate_policy_for_workload(workload_name)
    if not partition:
        return SelectionResult(workload_name, ram_tier_key, policy, None, "no_cells_evaluated", 0, 0, None)
    if model is None and len({cell.model for cell in partition}) > 1:
        raise ValueError(f"{workload_name}/{ram_tier_key} partition contains multiple target models")

    highest_success = max(
        (
            cell.successful_sample_count for cell in partition
            if cell.produced_successful_sample
        ),
        default=0,
    )
    winners = [cell for cell in partition if cell.passes_hard_gates(policy)]
    if winners:
        winner = sorted(winners, key=_winner_sort_key)[0]
        return SelectionResult(
            workload_name,
            ram_tier_key,
            policy,
            winner,
            None,
            len(partition),
            highest_success,
            _tie_breaker_reason(winners),
        )

    reason = no_winner_reason_for_cells(partition, policy)
    return SelectionResult(workload_name, ram_tier_key, policy, None, reason, len(partition), highest_success, None)


def no_winner_reason_for_cells(cells: list[SearchCellResult], policy: GatePolicy) -> str:
    if not cells:
        return "no_cells_evaluated"
    if all(cell.hard_failed for cell in cells):
        return "hard_failure"
    if any(cell.produced_successful_sample for cell in cells) and not any(
        cell.reached_min_samples(policy) for cell in cells
    ):
        return "insufficient_samples"
    if any(cell.reached_min_samples(policy) for cell in cells):
        return "gate_unmet"
    return "hard_failure"


def _winner_sort_key(cell: SearchCellResult) -> tuple[Any, ...]:
    serialized_tuple = json.dumps(cell.recommended_json(), sort_keys=True, separators=(",", ":"))
    return (
        0 if cell.hard_failure_count == 0 and cell.stop_token_leak_rate == 0 else 1,
        -(cell.median_tps if cell.median_tps is not None else -1.0),
        cell.p95_ttft_ms if cell.p95_ttft_ms is not None else float("inf"),
        cell.max_context_override,
        cell.max_concurrency_override,
        serialized_tuple,
    )


def _tie_breaker_reason(winners: list[SearchCellResult]) -> str:
    ordered = sorted(winners, key=_winner_sort_key)
    if len(ordered) == 1:
        return "only_gate_passing_cell"

    winner_key = _winner_sort_key(ordered[0])
    runner_key = _winner_sort_key(ordered[1])
    labels = [
        "zero_hard_failures_and_leaks",
        "higher_median_tps",
        "lower_ttft",
        "lower_context_memory_risk",
        "lower_concurrency_memory_risk",
        "lexical_tuple",
    ]
    for label, winner_value, runner_value in zip(labels, winner_key, runner_key, strict=True):
        if winner_value != runner_value:
            return label
    return "deterministic_tie"


def workload_profile(result: SelectionResult, source: str) -> dict[str, Any]:
    policy_json = result.gate_policy.as_json()
    if result.winner is not None:
        winner = result.winner
        profile = {
            "status": "winner",
            "recommended": winner.recommended_json(),
            "candidate_source": winner.candidate_source,
            "tie_breaker_reason": result.tie_breaker_reason,
            "gate_policy": policy_json,
            "profile_metrics": {
                "median_tps": winner.median_tps,
                "p95_ttft_ms": winner.p95_ttft_ms,
                "stop_token_leak_rate": winner.stop_token_leak_rate,
                "spec_decode_acceptance_rate": winner.spec_decode_acceptance_rate,
                "sample_count": winner.successful_sample_count,
            },
            "source": source,
        }
        return profile

    return {
        "status": "no_winner",
        "no_winner_reason": result.no_winner_reason,
        "gate_policy": policy_json,
        "profile_metrics": {
            "median_tps": None,
            "p95_ttft_ms": None,
            "stop_token_leak_rate": None,
            "spec_decode_acceptance_rate": None,
            "sample_count": result.highest_successful_sample_count,
        },
        "source": source,
    }


def no_winner_profile(result: SelectionResult, cells: list[SearchCellResult], source: str) -> dict[str, Any]:
    return workload_profile(result, source)


def class_aware_report(
    cells: list[SearchCellResult],
    source: str,
    ram_tier_keys: list[str] | None = None,
) -> dict[str, Any]:
    tiers = ram_tier_keys or sorted({cell.ram_tier_key for cell in cells if cell.ram_tier_key in RAM_TIER_KEYS})
    models = sorted({cell.model for cell in cells}, key=lambda value: value or "")
    partitions: list[dict[str, Any]] = []
    for model in models:
        model_cells = [cell for cell in cells if cell.model == model]
        for workload_name in sorted(INCLUDED_WORKLOADS):
            for ram_tier_key in tiers:
                result = choose_partition(model_cells, workload_name, ram_tier_key)
                profile = workload_profile(result, source)
                partitions.append({
                    "model": model,
                    "workload": workload_name,
                    "corpus_class": corpus_class_for_workload(workload_name),
                    "ram_tier_key": ram_tier_key,
                    "status": result.status,
                    "no_winner_reason": result.no_winner_reason,
                    "gate_policy": result.gate_policy.as_json(),
                    "evaluated_cell_count": result.evaluated_cell_count,
                    "profile_metrics": profile["profile_metrics"],
                    "source": profile["source"],
                    "candidate_source": profile.get("candidate_source"),
                    "tie_breaker_reason": result.tie_breaker_reason,
                    "tie_breaker_order": [
                        "zero_hard_failures_and_leaks",
                        "ttft_gate",
                        "higher_median_tps",
                        "lower_ttft",
                        "lower_memory_risk",
                        "lexical_tuple",
                    ],
                    "winner_tuple": result.winner.recommended_json() if result.winner else None,
                    "profile": profile,
                })

    streaming = [
        cell for cell in cells
        if cell.workload_name in PROBE_ONLY_WORKLOADS and cell.ram_tier_key in RAM_TIER_KEYS
    ]
    probe_partitions = []
    for model in sorted({cell.model for cell in streaming}, key=lambda value: value or ""):
        for ram_tier_key in sorted({cell.ram_tier_key for cell in streaming if cell.model == model}):
            policy = gate_policy_for_workload("streaming_check")
            group = [
                cell for cell in streaming
                if cell.model == model and cell.ram_tier_key == ram_tier_key
            ]
            highest_success = max(
                (
                    cell.successful_sample_count for cell in group
                    if cell.produced_successful_sample
                ),
                default=0,
            )
            passing_cells = [cell for cell in group if cell.passes_hard_gates(policy)]
            passed = bool(passing_cells)
            representative = sorted(passing_cells, key=_winner_sort_key)[0] if passing_cells else None
            probe_partitions.append({
                "model": model,
                "workload": "streaming_check",
                "corpus_class": corpus_class_for_workload("streaming_check"),
                "ram_tier_key": ram_tier_key,
                "status": "probe_pass" if passed else "probe_no_winner",
                "no_winner_reason": None if passed else no_winner_reason_for_cells(group, policy),
                "gate_policy": policy.as_json(),
                "evaluated_cell_count": len(group),
                "profile_metrics": {
                    "median_tps": representative.median_tps if representative else None,
                    "p95_ttft_ms": representative.p95_ttft_ms if representative else None,
                    "stop_token_leak_rate": representative.stop_token_leak_rate if representative else None,
                    "spec_decode_acceptance_rate": representative.spec_decode_acceptance_rate if representative else None,
                    "sample_count": representative.successful_sample_count if representative else highest_success,
                },
                "source": source,
                "winner_tuple": None,
            })

    return {
        "source": source,
        "evaluated_cells": [
            search_cell_json(cell) for cell in sorted(cells, key=_cell_identity_sort_key)
        ],
        "partitions": partitions,
        "streaming_probes": probe_partitions,
    }


def search_cell_json(cell: SearchCellResult) -> dict[str, Any]:
    return {
        "workload": cell.workload_name,
        "model": cell.model,
        "ram_tier_key": cell.ram_tier_key,
        "kv_bits": cell.kv_bits,
        "max_context_override": cell.max_context_override,
        "max_concurrency_override": cell.max_concurrency_override,
        "draft_model": cell.draft_model,
        "draft_model_artifact_sha256": cell.draft_model_artifact_sha256,
        "num_draft_tokens": cell.num_draft_tokens,
        "candidate_source": cell.candidate_source,
        "successful_sample_count": cell.successful_sample_count,
        "p95_ttft_ms": cell.p95_ttft_ms,
        "median_tps": cell.median_tps,
        "stop_token_leak_rate": cell.stop_token_leak_rate,
        "hard_failure_count": cell.hard_failure_count,
        "spec_decode_acceptance_rate": cell.spec_decode_acceptance_rate,
        "draft_validation_error": cell.draft_validation_error,
    }


def trial_row_json(row: Any) -> dict[str, Any]:
    return {
        "ts_utc": _row_get(row, "ts_utc"),
        "workload": _row_get(row, "workload"),
        "model": _row_get(row, "model"),
        "streamed": _row_get(row, "streamed"),
        "http_status": _row_get(row, "http_status"),
        "error": _row_get(row, "error"),
        "ttft_ms": _row_get(row, "ttft_ms"),
        "total_ms": _row_get(row, "total_ms"),
        "prompt_tokens": _row_get(row, "prompt_tokens"),
        "completion_tokens": _row_get(row, "completion_tokens"),
        "throughput_tps": _row_get(row, "throughput_tps"),
        "host_ram_bytes": _row_get(row, "host_ram_bytes"),
        "ram_tier_key": _row_get(row, "ram_tier_key"),
        "provider_ram_source": _row_get(row, "provider_ram_source"),
        "cell_execution_source": _row_get(row, "cell_execution_source"),
        "non_runnable_reason": _row_get(row, "non_runnable_reason"),
        "corpus_class": _row_get(row, "corpus_class"),
        "max_context_override": _row_get(row, "max_context_override"),
        "max_concurrency_override": _row_get(row, "max_concurrency_override"),
        "kv_bits": _row_get(row, "kv_bits"),
        "metric_unavailable_reason": _row_get(row, "metric_unavailable_reason"),
        "draft_model": _row_get(row, "draft_model"),
        "draft_model_artifact_sha256": _row_get(row, "draft_model_artifact_sha256"),
        "num_draft_tokens": _row_get(row, "num_draft_tokens"),
        "drafted_tokens": _row_get(row, "drafted_tokens"),
        "accepted_tokens": _row_get(row, "accepted_tokens"),
        "spec_decode_acceptance_rate": _row_get(row, "spec_decode_acceptance_rate"),
        "candidate_source": _row_get(row, "candidate_source"),
        "winner_status": _row_get(row, "winner_status"),
        "no_winner_reason": _row_get(row, "no_winner_reason"),
        "stop_token_leak": _row_get(row, "stop_token_leak"),
    }


def _cell_identity_sort_key(cell: SearchCellResult) -> tuple[Any, ...]:
    return (
        cell.workload_name,
        cell.model or "",
        cell.ram_tier_key,
        cell.kv_bits,
        cell.max_context_override,
        cell.max_concurrency_override,
        cell.draft_model or "",
        cell.draft_model_artifact_sha256 or "",
        cell.num_draft_tokens if cell.num_draft_tokens is not None else -1,
        cell.candidate_source or "",
    )


def cells_from_rows(rows: list[Any]) -> list[SearchCellResult]:
    grouped: dict[tuple[Any, ...], list[Any]] = {}
    for row in rows:
        cell_execution_source = _row_get(row, "cell_execution_source")
        if cell_execution_source not in EVALUATED_CELL_EXECUTION_SOURCES:
            continue
        if cell_execution_source in NON_RUNNABLE_CELL_EXECUTION_SOURCES and not _row_get(row, "non_runnable_reason"):
            continue
        workload_name = _row_get(row, "workload")
        ram_tier_key = _row_get(row, "ram_tier_key")
        kv_bits = _row_get(row, "kv_bits")
        context = _row_get(row, "max_context_override")
        concurrency = _row_get(row, "max_concurrency_override")
        if not workload_name or not ram_tier_key or kv_bits is None or context is None or concurrency is None:
            continue
        key = (
            workload_name,
            _row_get(row, "model"),
            ram_tier_key,
            int(kv_bits),
            int(context),
            int(concurrency),
            _row_get(row, "draft_model"),
            _row_get(row, "draft_model_artifact_sha256"),
            _row_get(row, "num_draft_tokens"),
            _row_get(row, "candidate_source"),
        )
        grouped.setdefault(key, []).append(row)

    out: list[SearchCellResult] = []
    for key, group in grouped.items():
        (
            workload_name,
            model,
            ram_tier_key,
            kv_bits,
            context,
            concurrency,
            draft_model,
            draft_hash,
            num_draft_tokens,
            candidate_source,
        ) = key
        non_runnable_reason = next(
            (
                _row_get(row, "non_runnable_reason")
                for row in group
                if _row_get(row, "non_runnable_reason")
            ),
            None,
        )
        successful_rows = [row for row in group if _row_ok(row)]
        successful_sample_count = len(successful_rows)
        ttft_values = [
            float(_row_get(row, "ttft_ms"))
            for row in successful_rows
            if _row_get(row, "ttft_ms") is not None
        ]
        tps_values = [
            float(_row_get(row, "throughput_tps"))
            for row in successful_rows
            if _row_get(row, "throughput_tps") is not None
        ]
        acceptance_values = [
            float(_row_get(row, "spec_decode_acceptance_rate"))
            for row in successful_rows
            if _row_get(row, "spec_decode_acceptance_rate") is not None
        ]
        leak_count = sum(1 for row in successful_rows if _row_get(row, "stop_token_leak"))
        leak_rate = (leak_count / successful_sample_count) if successful_sample_count else 0.0
        hard_failure_count = len(group) - successful_sample_count
        out.append(SearchCellResult(
            workload_name=workload_name,
            model=model,
            ram_tier_key=ram_tier_key,
            kv_bits=kv_bits,
            max_context_override=context,
            max_concurrency_override=concurrency,
            successful_sample_count=successful_sample_count,
            p95_ttft_ms=p95(ttft_values),
            median_tps=statistics.median(tps_values) if tps_values else None,
            stop_token_leak_rate=leak_rate,
            hard_failure_count=hard_failure_count,
            non_runnable_reason=non_runnable_reason,
            draft_model=draft_model,
            draft_model_artifact_sha256=draft_hash,
            num_draft_tokens=num_draft_tokens,
            spec_decode_acceptance_rate=statistics.median(acceptance_values) if acceptance_values else None,
            candidate_source=candidate_source,
        ))
    return out


def _row_ok(row: Any) -> bool:
    return _row_get(row, "http_status") == 200 and not _row_get(row, "error")


def _row_get(row: Any, key: str, default=None):
    if hasattr(row, "keys") and key in row.keys():
        return row[key]
    if isinstance(row, dict):
        return row.get(key, default)
    return getattr(row, key, default)


def p95(values: list[float]) -> float | None:
    if not values:
        return None
    if len(values) == 1:
        return values[0]
    return statistics.quantiles(values, n=100, method="inclusive")[94]
