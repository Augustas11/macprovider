#!/usr/bin/env python3
"""Generate and verify the immutable SPEC-023 catalog release bundle."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import math
import os
import pathlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from datetime import datetime, timezone


ROOT = pathlib.Path(__file__).resolve().parents[1]
CATALOG_DIR = ROOT / "phase3-binary" / "catalog" / "autotune"
STATIC_DIR = ROOT / "phase3-binary" / "dist" / "static"
SWIFT_SOURCE = ROOT / "phase3-binary" / "Sources" / "macprovider-cli" / "AutotuneRecommend.swift"
SWIFT_GENERATED = ROOT / "phase3-binary" / "Sources" / "macprovider-cli" / "AutotuneCatalog.generated.swift"
GO_REJECTED_RELEASES_GENERATED = ROOT / "phase4-coordinator" / "internal" / "autotune" / "rejected_release_ids.generated.go"
KEYS_PATH = CATALOG_DIR / "trusted-keys.json"
MANIFEST_PATH = CATALOG_DIR / "release.json"
LEDGER_PATH = CATALOG_DIR / "release-ledger.json"
TIER2_BINDING_PATH = CATALOG_DIR / "tier2-identity-binding.json"
TIER2_BINDING_SCHEMA = "macprovider.tier2-identity-binding.v1"
TIER2_CATALOG_PATH = CATALOG_DIR / "tier2-catalog.json"
TIER2_CATALOG_FEED_NAME = "tier2-catalog.json"
RATE_CARD_FEED_NAME = "rate-card.json"
ARTIFACT_FEED_NAME = "autotune-artifacts.json"
ARTIFACT_FEED_PATH = CATALOG_DIR / ARTIFACT_FEED_NAME
ARTIFACT_SOURCE_PATH = CATALOG_DIR / "autotune-artifacts-source.json"
ARTIFACT_SOURCE_SCHEMA = "macprovider.autotune-artifacts-source.v1"
ARTIFACT_FEED_SOURCE_VALUE = "operator_curated_autotune_artifact_catalog"
RATE_CARD_SOURCE_PATH = CATALOG_DIR / "rate-card-source.json"
RATE_CARD_SOURCE_SCHEMA = "macprovider.rate-card-source.v1"
INTAKE_DECISION_PATH = CATALOG_DIR / "intake-decision.json"
LEDGER_SCHEMA_V2 = "macprovider.autotune-release-ledger.v2"
LEDGER_SCHEMA_V3 = "macprovider.autotune-release-ledger.v3"
LEGACY_LEDGER_FEEDS = frozenset({"autotune-candidates.json", "demand-rank.json"})
TIER2_BOUND_LEDGER_FEEDS = LEGACY_LEDGER_FEEDS | {TIER2_CATALOG_FEED_NAME}
RATE_CARD_BOUND_LEDGER_FEEDS = TIER2_BOUND_LEDGER_FEEDS | {RATE_CARD_FEED_NAME}
ARTIFACT_BOUND_LEDGER_FEEDS = RATE_CARD_BOUND_LEDGER_FEEDS | {ARTIFACT_FEED_NAME}
HEX64 = re.compile(r"^[0-9a-f]{64}$")
HEX40 = re.compile(r"^[0-9a-f]{40}$")
ARTIFACT_ID = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}$")
FULL_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
# SPEC-023 §3.3.1 rule 1: closed rate-class enum. Extending it is a SPEC revision.
RATE_CLASSES = frozenset({
    "class-3b", "class-8b", "class-20b-moe", "class-30b-moe",
    "class-32b", "class-70b", "class-120b-moe",
})
# SPEC-023 §3.3.1 rule 3: a source row/class carries ONLY these three fields.
RATE_CREDIT_FIELDS = ("completion_rate_per_mtok", "prompt_cache_hit_rate_per_mtok", "prompt_rate_per_mtok")
# SPEC-023 §3.3.1 rule 4: the exact published-JSON -> coordinator-YAML mapping.
COORDINATOR_RATE_FIELD_MAP = {
    "prompt_rate_per_mtok": "prompt_credits_per_mtok",
    "prompt_cache_hit_rate_per_mtok": "prompt_cache_hit_credits_per_mtok",
    "completion_rate_per_mtok": "completion_credits_per_mtok",
}
SNAPSHOT_MANIFEST_ALG = "macprovider.snapshot-manifest.v1"
GGUF_FILE_ALG = "macprovider.gguf-file.v1"
# SPEC-023 §3.7.4 closed artifact-identity matrix: runtime_format determines the
# only legal hash_algorithm, source_ref.kind, and allowed_runtime_sources set.
ARTIFACT_IDENTITY_MATRIX = {
    "mlx_safetensors": (SNAPSHOT_MANIFEST_ALG, "huggingface_revision", frozenset({"mlx_cache"})),
    "gguf": (GGUF_FILE_ALG, "ollama_library_tag", frozenset({
        "ollama_loopback", "llamacpp_loopback", "lmstudio_loopback", "openai_compatible_loopback",
    })),
}
ARTIFACT_VERIFICATION_STATUSES = frozenset({"declared", "verified", "blocked"})
# SPEC-005 §5.5 NormalizeModelKey parity (phase4-coordinator/internal/billing/formula.go).
KNOWN_MODEL_NAMESPACES = frozenset({"mlx-community", "openai", "google", "meta-llama", "nvidia", "qwen"})
TIER2_HASH_SCOPES = {"primary_weight_file", "artifact_manifest", "coordinator_endorsed_incremental"}
TIER2_SIG_PATTERN = re.compile(r"^[A-Za-z0-9_-]{86}$")
MODEL_KEY = re.compile(r"^[a-z0-9][a-z0-9._/-]{0,127}$")
MODEL_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$")
RFC3339 = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$")
INT64_MIN = -(2**63)
INT64_MAX = 2**63 - 1
OPENSSL_PROBE_TIMEOUT_SECONDS = 5
OPENSSL_VERIFY_TIMEOUT_SECONDS = 15
SIGN_CATALOG_GO_PATH = ROOT / "scripts" / "sign-catalog.go"
COORDINATOR_YAML_PATH = ROOT / "phase4-coordinator" / "dist" / "coordinator.yaml"
GO_PROBE_TIMEOUT_SECONDS = 5
TIER2_SIGN_VERIFY_TIMEOUT_SECONDS = 60
FIXED_GO_EXECUTABLES = (
    "/opt/homebrew/bin/go",
    "/usr/local/go/bin/go",
    "/usr/local/bin/go",
    "/private/var/macprovider-go-verifier/bin/go",
)
ALWAYS_ROOT_TRUSTED_GO_EXECUTABLES = frozenset({"/private/var/macprovider-go-verifier/bin/go"})
REQUIRE_SEALED_GO_ENV = "CATALOG_RELEASE_REQUIRE_SEALED_GO_VERIFIER"


class CatalogError(RuntimeError):
    pass


def fail(message: str) -> None:
    raise CatalogError(message)


def strict_json(data: bytes, label: str) -> dict:
    def reject_pairs(pairs: list[tuple[str, object]]) -> dict:
        value = {}
        for key, item in pairs:
            if key in value:
                fail(f"{label}: duplicate object key {key!r}")
            value[key] = item
        return value

    def reject_constant(constant: str) -> object:
        fail(f"{label}: non-standard numeric constant {constant}")

    def bounded_int(raw: str) -> int:
        value = int(raw)
        if value < INT64_MIN or value > INT64_MAX:
            fail(f"{label}: integer is outside the signed 64-bit runtime range")
        return value

    try:
        text = data.decode("utf-8")
        decoder = json.JSONDecoder(
            object_pairs_hook=reject_pairs,
            parse_constant=reject_constant,
            parse_int=bounded_int,
        )
        value, end = decoder.raw_decode(text)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        fail(f"{label}: invalid JSON: {exc}")
    if text[end:].strip():
        fail(f"{label}: trailing JSON data")
    if not isinstance(value, dict):
        fail(f"{label}: top level must be an object")
    return value


def exact_keys(value: dict, allowed: set[str], required: set[str], label: str) -> None:
    keys = set(value)
    missing = required - keys
    unknown = keys - allowed
    if missing:
        fail(f"{label}: missing fields {sorted(missing)}")
    if unknown:
        fail(f"{label}: unknown fields {sorted(unknown)}")


def parse_timestamp(raw: object, label: str) -> datetime:
    """Validate an RFC3339 `generated_at` and return the AWARE `datetime`.

    Anything that ORDERS releases must compare these instants, never the raw
    strings: the grammar admits any explicit offset and optional fractional
    seconds, so lexical string order is not chronological order.
    """
    if not isinstance(raw, str) or not RFC3339.fullmatch(raw):
        fail(f"{label}: generated_at must be RFC3339 with an explicit timezone")
    try:
        parsed = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError as exc:
        fail(f"{label}: generated_at must be RFC3339: {exc}")
    if parsed.utcoffset() is None:
        fail(f"{label}: generated_at must include a timezone")
    return parsed


def parse_time(raw: object, label: str) -> None:
    parse_timestamp(raw, label)


def finite_number(value: object) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def validate_candidate_workloads(row: dict, row_key: str) -> None:
    drafts = row.get("draft_candidates")
    if drafts is None:
        drafts = []
    if not isinstance(drafts, list):
        fail(f"candidate row {row_key}: draft_candidates must be an array")
    for index, draft in enumerate(drafts):
        if not isinstance(draft, dict):
            fail(f"candidate row {row_key}: draft_candidates[{index}] must be an object")
        exact_keys(draft, {"draft_model", "draft_model_artifact_sha256"}, {"draft_model", "draft_model_artifact_sha256"}, f"candidate row {row_key} draft {index}")
        if not isinstance(draft["draft_model"], str) or not isinstance(draft["draft_model_artifact_sha256"], str):
            fail(f"candidate row {row_key}: invalid draft candidate")

    profiles = row.get("workload_profiles")
    if profiles is None:
        return
    if not isinstance(profiles, dict):
        fail(f"candidate row {row_key}: workload_profiles must be an object")
    expected_ttft = {"short_chat": 8000, "medium_with_system": 12000, "long_context": 60000, "code_completion": 12000, "agent_style": 20000}
    context_caps = {"8gb": 8192, "16gb": 20000, "32gb": 50000, "64gb_plus": 120000}
    allowed_reasons = {"insufficient_samples", "gate_unmet", "hard_failure", "no_cells_evaluated"}
    for workload, tiers in profiles.items():
        if workload not in expected_ttft or not isinstance(tiers, dict) or not tiers:
            fail(f"candidate row {row_key}: invalid workload or tiers")
        for tier, profile in tiers.items():
            if tier not in context_caps or not isinstance(profile, dict):
                fail(f"candidate row {row_key}: invalid workload tier")
            allowed_profile = {"status", "no_winner_reason", "recommended", "gate_policy", "profile_metrics", "source", "candidate_source"}
            exact_keys(profile, allowed_profile, {"gate_policy", "profile_metrics", "source"}, f"candidate row {row_key} workload profile")
            if not isinstance(profile["source"], str) or not profile["source"]:
                fail(f"candidate row {row_key}: workload source required")
            gate = profile["gate_policy"]
            metrics = profile["profile_metrics"]
            gate_fields = {"min_samples", "max_p95_ttft_ms", "max_stop_token_leak_rate", "min_median_tps"}
            metric_fields = {"median_tps", "p95_ttft_ms", "stop_token_leak_rate", "spec_decode_acceptance_rate", "sample_count"}
            if not isinstance(gate, dict) or not isinstance(metrics, dict):
                fail(f"candidate row {row_key}: workload policy and metrics must be objects")
            exact_keys(gate, gate_fields, gate_fields, f"candidate row {row_key} workload gate")
            exact_keys(metrics, metric_fields, metric_fields, f"candidate row {row_key} workload metrics")
            if gate["min_samples"] != 20 or gate["max_p95_ttft_ms"] != expected_ttft[workload] or gate["max_stop_token_leak_rate"] != 0 or gate["min_median_tps"] is not None:
                fail(f"candidate row {row_key}: workload gate policy mismatch")
            if not isinstance(metrics["sample_count"], int) or isinstance(metrics["sample_count"], bool) or metrics["sample_count"] < 0:
                fail(f"candidate row {row_key}: invalid workload sample_count")
            for field in ("median_tps", "p95_ttft_ms"):
                if metrics[field] is not None and (not finite_number(metrics[field]) or metrics[field] < 0):
                    fail(f"candidate row {row_key}: invalid workload {field}")
            for field in ("stop_token_leak_rate", "spec_decode_acceptance_rate"):
                if metrics[field] is not None and (not finite_number(metrics[field]) or not 0 <= metrics[field] <= 1):
                    fail(f"candidate row {row_key}: invalid workload {field}")

            status = profile.get("status")
            if status == "no_winner":
                reason = profile.get("no_winner_reason")
                if reason not in allowed_reasons or profile.get("recommended") is not None or any(metrics[field] is not None for field in metric_fields - {"sample_count"}):
                    fail(f"candidate row {row_key}: invalid no_winner profile")
                samples = metrics["sample_count"]
                if reason in {"no_cells_evaluated", "hard_failure"} and samples != 0:
                    fail(f"candidate row {row_key}: invalid no_winner sample_count")
                if reason == "insufficient_samples" and not 0 < samples < gate["min_samples"]:
                    fail(f"candidate row {row_key}: invalid insufficient_samples count")
                if reason == "gate_unmet" and samples < gate["min_samples"]:
                    fail(f"candidate row {row_key}: invalid gate_unmet count")
                continue
            if status not in {None, "winner"} or profile.get("no_winner_reason") is not None:
                fail(f"candidate row {row_key}: invalid winner status")
            recommended = profile.get("recommended")
            if not isinstance(recommended, dict):
                fail(f"candidate row {row_key}: winner recommendation required")
            recommended_fields = {"kv_bits", "max_context_override", "max_concurrency_override", "draft_model", "draft_model_artifact_sha256", "num_draft_tokens"}
            exact_keys(recommended, recommended_fields, {"kv_bits", "max_context_override", "max_concurrency_override"}, f"candidate row {row_key} workload recommendation")
            if not all(isinstance(recommended[field], int) and not isinstance(recommended[field], bool) for field in ("kv_bits", "max_context_override", "max_concurrency_override")):
                fail(f"candidate row {row_key}: invalid winner knobs")
            if recommended["kv_bits"] < 0 or recommended["max_context_override"] <= 0 or recommended["max_concurrency_override"] <= 0 or metrics["p95_ttft_ms"] is None or metrics["p95_ttft_ms"] > gate["max_p95_ttft_ms"] or metrics["stop_token_leak_rate"] is None or metrics["stop_token_leak_rate"] > gate["max_stop_token_leak_rate"] or metrics["sample_count"] < gate["min_samples"]:
                fail(f"candidate row {row_key}: invalid winner metrics")
            has_draft = any(recommended.get(field) is not None for field in ("draft_model", "draft_model_artifact_sha256", "num_draft_tokens"))
            if not has_draft:
                continue
            source = profile.get("candidate_source")
            if not isinstance(recommended.get("draft_model"), str) or not isinstance(recommended.get("draft_model_artifact_sha256"), str) or not HEX64.fullmatch(recommended["draft_model_artifact_sha256"]) or not isinstance(recommended.get("num_draft_tokens"), int) or isinstance(recommended.get("num_draft_tokens"), bool) or not 1 <= recommended["num_draft_tokens"] <= 16 or recommended["max_concurrency_override"] > 1 or recommended["max_context_override"] > context_caps[tier] or not isinstance(source, str) or not source.startswith(("static_draft_candidates:", "research_fixture:", "local_operator_override:")):
                fail(f"candidate row {row_key}: invalid speculative recommendation")
            if source.startswith("static_draft_candidates:") and not any(draft["draft_model"] == recommended["draft_model"] and draft["draft_model_artifact_sha256"] == recommended["draft_model_artifact_sha256"] for draft in drafts):
                fail(f"candidate row {row_key}: speculative recommendation is not bound to draft_candidates")


def validate_candidate(data: bytes, *, require_provenance: bool = True) -> dict:
    value = strict_json(data, "autotune-candidates")
    top = {"version", "generated_at", "source", "policy_version", "rows"}
    exact_keys(value, top, {"version", "generated_at", "source", "policy_version", "rows"}, "autotune-candidates")
    if value["source"] != "operator_curated_autotune_candidate_catalog":
        fail("autotune-candidates: invalid source")
    if not isinstance(value["version"], str) or not value["version"] or value["version"].strip() != value["version"]:
        fail("autotune-candidates: version must be a non-empty trimmed string")
    if value["policy_version"] != "autotune-policy-v1":
        fail("autotune-candidates: unsupported policy_version")
    parse_time(value["generated_at"], "autotune-candidates")
    rows = value["rows"]
    if not isinstance(rows, dict) or not rows:
        fail("autotune-candidates: rows required")
    required = {"model_id", "min_ram_gb", "min_bandwidth_tier", "bench_gate", "runtime_status"}
    allowed = required | {"model_revision", "model_sha256", "notes", "draft_candidates", "workload_profiles"}
    for key, row in rows.items():
        if not isinstance(key, str) or not MODEL_KEY.fullmatch(key) or "//" in key or not isinstance(row, dict):
            fail("autotune-candidates: invalid row")
        exact_keys(row, allowed, required, f"candidate row {key}")
        if not isinstance(row["model_id"], str) or not MODEL_ID.fullmatch(row["model_id"]):
            fail(f"candidate row {key}: invalid model_id")
        revision = row.get("model_revision")
        artifact_hash = row.get("model_sha256")
        if revision is not None and (not isinstance(revision, str) or not HEX40.fullmatch(revision)):
            fail(f"candidate row {key}: model_revision must be lowercase 40-hex")
        if artifact_hash is not None and (not isinstance(artifact_hash, str) or not HEX64.fullmatch(artifact_hash)):
            fail(f"candidate row {key}: model_sha256 must be lowercase 64-hex")
        if row["runtime_status"] != "blocked" and (revision is None or artifact_hash is None):
            fail(f"candidate row {key}: downloadable model requires model_revision and model_sha256")
        if "notes" in row and not isinstance(row["notes"], str):
            fail(f"candidate row {key}: notes must be a string")
        if not isinstance(row["min_ram_gb"], int) or isinstance(row["min_ram_gb"], bool) or row["min_ram_gb"] < 0:
            fail(f"candidate row {key}: invalid min_ram_gb")
        if row["min_bandwidth_tier"] not in {"A", "B", "C", "S"}:
            fail(f"candidate row {key}: invalid min_bandwidth_tier")
        if row["runtime_status"] not in {"candidate", "listed", "recommendable", "blocked"}:
            fail(f"candidate row {key}: invalid runtime_status")
        gate = row["bench_gate"]
        if not isinstance(gate, dict):
            fail(f"candidate row {key}: bench_gate must be an object")
        required_gate_fields = {"min_sustained_tps", "max_4k_ttft_ms"}
        if require_provenance:
            required_gate_fields.add("provenance")
        exact_keys(
            gate,
            {"min_sustained_tps", "max_4k_ttft_ms", "provenance"},
            required_gate_fields,
            f"candidate row {key} bench_gate",
        )
        if not isinstance(gate["min_sustained_tps"], (int, float)) or isinstance(gate["min_sustained_tps"], bool) or not math.isfinite(gate["min_sustained_tps"]) or gate["min_sustained_tps"] < 0:
            fail(f"candidate row {key}: invalid min_sustained_tps")
        if not isinstance(gate["max_4k_ttft_ms"], int) or isinstance(gate["max_4k_ttft_ms"], bool) or gate["max_4k_ttft_ms"] < 0:
            fail(f"candidate row {key}: invalid max_4k_ttft_ms")
        if "provenance" in gate and gate["provenance"] is None:
            fail(f"candidate row {key}: bench_gate.provenance must be an object")
        provenance = gate.get("provenance")
        if provenance is not None:
            if not isinstance(provenance, dict):
                fail(f"candidate row {key}: bench_gate.provenance must be an object")
            provenance_fields = {"source", "hardware", "measured_at", "notes"}
            exact_keys(provenance, provenance_fields, {"source"}, f"candidate row {key} bench_gate provenance")
            if provenance["source"] not in {
                "measured_single_host",
                "runtime_validated_only",
                "policy",
                "no_throughput_bench",
                "never_benched",
                "legacy_unverified",
            }:
                fail(f"candidate row {key}: invalid bench_gate provenance source")
            for optional_field in ("hardware", "measured_at", "notes"):
                if optional_field in provenance and (
                    not isinstance(provenance[optional_field], str)
                    or not provenance[optional_field].strip()
                ):
                    fail(f"candidate row {key}: invalid bench_gate provenance {optional_field}")
        validate_candidate_workloads(row, key)
    # Reject keys that equal some model_id's normalized form while declaring a
    # different model_id. Go HighestClaimedTier prefers rowsByKey[normalized]
    # and would otherwise shadow the real model row (#608 audit MEDIUM).
    for key, row in rows.items():
        if key != row["model_id"].lower().strip() and any(
            other["model_id"].lower().strip() == key for other in rows.values()
        ):
            fail(
                f"candidate row {key}: key shadows model_id {key!r} but declares "
                f"model_id {row['model_id']!r}"
            )
    # Reject conflicting artifact hashes under one normalized model_id so every
    # consumer (including check-tier2-binding) inherits fail-closed parity.
    by_model_hash: dict[str, str] = {}
    for key, row in rows.items():
        artifact_hash = row.get("model_sha256")
        if not isinstance(artifact_hash, str) or not artifact_hash:
            continue
        normalized = row["model_id"].lower().strip()
        prior = by_model_hash.get(normalized)
        if prior is not None and prior != artifact_hash:
            fail(
                f"candidate row {key}: model_id {row['model_id']!r} has conflicting "
                f"model_sha256 across catalog keys"
            )
        by_model_hash[normalized] = artifact_hash
    return value


def validate_demand(data: bytes) -> dict:
    value = strict_json(data, "demand-rank")
    top = {"version", "generated_at", "source", "policy_version", "cold_start_floor", "diversification_band", "rows"}
    exact_keys(value, top, top, "demand-rank")
    if value["source"] not in {
        "openrouter_completion_token_rank_operator_curated",
        "macprovider_buyer_supply_deficit_v1",
    }:
        fail("demand-rank: invalid source")
    if not isinstance(value["version"], str) or not value["version"] or value["version"].strip() != value["version"]:
        fail("demand-rank: version must be a non-empty trimmed string")
    if value["policy_version"] != "autotune-policy-v1":
        fail("demand-rank: policy_version required")
    parse_time(value["generated_at"], "demand-rank")
    if not isinstance(value["cold_start_floor"], (int, float)) or isinstance(value["cold_start_floor"], bool) or value["cold_start_floor"] != 0.15:
        fail("demand-rank: cold_start_floor must equal 0.15")
    if not isinstance(value["diversification_band"], (int, float)) or isinstance(value["diversification_band"], bool) or value["diversification_band"] != 0.85:
        fail("demand-rank: diversification_band must equal 0.85")
    rows = value["rows"]
    if not isinstance(rows, dict) or not rows:
        fail("demand-rank: rows required")
    allowed = {
        "demand_weight", "rank", "recommendable", "min_provider_target",
        "ready_provider_count", "supply_deficit_multiplier", "min_dwell_hours",
    }
    required = {"demand_weight", "rank", "recommendable", "min_provider_target"}
    for key, row in rows.items():
        if not isinstance(row, dict):
            fail(f"demand row {key}: must be an object")
        exact_keys(row, allowed, required, f"demand row {key}")
        if not isinstance(row["demand_weight"], (int, float)) or isinstance(row["demand_weight"], bool) or not math.isfinite(row["demand_weight"]) or not 0 <= row["demand_weight"] <= 1:
            fail(f"demand row {key}: invalid demand_weight")
        if row.get("rank") is not None and (not isinstance(row["rank"], int) or isinstance(row["rank"], bool) or row["rank"] <= 0):
            fail(f"demand row {key}: invalid rank")
        if not isinstance(row["recommendable"], bool):
            fail(f"demand row {key}: recommendable must be boolean")
        if not isinstance(row["min_provider_target"], int) or isinstance(row["min_provider_target"], bool) or row["min_provider_target"] < 0:
            fail(f"demand row {key}: invalid min_provider_target")
        ready = row.get("ready_provider_count")
        if ready is not None and (not isinstance(ready, int) or isinstance(ready, bool) or ready < 0):
            fail(f"demand row {key}: invalid ready_provider_count")
        multiplier = row.get("supply_deficit_multiplier")
        if multiplier is not None and (not isinstance(multiplier, (int, float)) or isinstance(multiplier, bool) or not math.isfinite(multiplier) or not 0.5 <= multiplier <= 2.0):
            fail(f"demand row {key}: supply_deficit_multiplier must be in [0.5,2.0]")
        dwell = row.get("min_dwell_hours")
        if dwell is not None and (not isinstance(dwell, int) or isinstance(dwell, bool) or not 0 <= dwell <= 720):
            fail(f"demand row {key}: min_dwell_hours must be in [0,720]")
    return value


def canonical_bytes(value: dict) -> bytes:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def canonical_sorted_bytes(value: dict) -> bytes:
    """Deterministic compact JSON with every object key sorted.

    Generated feeds (the materialised rate card, the artifact feed) are emitted
    through this so two conforming generators fed one source produce identical
    bytes regardless of the source document's own key order.
    """
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode("utf-8")


def normalize_model_key(model: str) -> str:
    """Python port of SPEC-005 §5.5 `NormalizeModelKey`.

    Mirrors `phase4-coordinator/internal/billing/formula.go::NormalizeModelKey`
    exactly, including `knownModelNamespace` and `servedAliasNamespace`. It is
    used only for the §3.3.1 rule-7 authoring-time invariant ("a recommendable
    row MUST resolve to a rate row"), never for billing. The port is pinned by a
    table test so Go/Python drift fails a test rather than a release.

    Equivalence is scoped to `MODEL_KEY`-conforming input, which every caller
    enforces first: Python `str.strip()` / `str.lower()` and Go
    `strings.TrimSpace` / `strings.ToLower` differ on a few code points
    (U+001C–U+001F, U+0130) that the grammar cannot admit.
    """
    key = model.strip().lower()
    namespace = ""
    slash = key.find("/")
    if slash >= 0:
        namespace = key[:slash]
        if namespace in KNOWN_MODEL_NAMESPACES:
            key = key[slash + 1:]
    for suffix in ("-mxfp4-q8", "-4bit", "-8bit"):
        if key.endswith(suffix):
            key = key[: -len(suffix)]

    def served_alias(canonical_vendor: str) -> bool:
        return namespace in {"", "mlx-community", canonical_vendor}

    if namespace == "meta-llama" and key.startswith("llama-"):
        return "meta-llama/" + key
    if served_alias("meta-llama") and key.startswith("meta-llama-"):
        return "meta-llama/" + key[len("meta-"):]
    if served_alias("nvidia") and key.startswith("nvidia-nemotron-"):
        return key[len("nvidia-"):]
    if served_alias("openai") and key.startswith("gpt-oss-"):
        return "openai/" + key
    return key


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def extract_baked(name: str) -> dict:
    source = SWIFT_SOURCE.read_text()
    match = re.search(rf"static let {re.escape(name)} = \"\"\"\n(.*?)\n    \"\"\"", source, re.S)
    if not match:
        fail(f"cannot find {name} in {SWIFT_SOURCE}")
    body = "\n".join(
        line[4:] if line.startswith("    ") else line
        for line in match.group(1).splitlines()
    )
    return strict_json(body.encode("utf-8"), name)


def keyring(path: pathlib.Path = KEYS_PATH) -> dict[str, bytes]:
    data = strict_json(path.read_bytes(), "trusted-keys")
    exact_keys(data, {"schema_version", "keys"}, {"schema_version", "keys"}, "trusted-keys")
    if data["schema_version"] != "macprovider.autotune-keys.v1" or not isinstance(data["keys"], dict):
        fail("trusted-keys: invalid schema")
    result: dict[str, bytes] = {}
    for key_id, row in data["keys"].items():
        if not isinstance(row, dict):
            fail(f"trusted-keys: invalid row {key_id}")
        exact_keys(row, {"public_key_base64", "status"}, {"public_key_base64", "status"}, f"trusted key {key_id}")
        if row["status"] not in {"active", "bridge", "retired"}:
            fail(f"trusted key {key_id}: invalid status")
        try:
            raw = base64.b64decode(row["public_key_base64"], validate=True)
        except (ValueError, TypeError) as exc:
            fail(f"trusted key {key_id}: invalid base64: {exc}")
        if base64.b64encode(raw).decode("ascii") != row["public_key_base64"]:
            fail(f"trusted key {key_id}: base64 is not canonical")
        if len(raw) != 32:
            fail(f"trusted key {key_id}: Ed25519 public key must be 32 bytes")
        if row["status"] != "retired":
            result[key_id] = raw
    return result


def parse_sidecar(data: bytes, label: str) -> tuple[str, bytes]:
    value = strict_json(data, label)
    exact_keys(value, {"key_id", "alg", "signature"}, {"key_id", "alg", "signature"}, label)
    if value["alg"] != "ed25519" or not isinstance(value["key_id"], str):
        fail(f"{label}: invalid key_id or alg")
    try:
        signature = base64.b64decode(value["signature"], validate=True)
    except (ValueError, TypeError) as exc:
        fail(f"{label}: invalid signature base64: {exc}")
    if base64.b64encode(signature).decode("ascii") != value["signature"]:
        fail(f"{label}: signature base64 is not canonical")
    if len(signature) != 64:
        fail(f"{label}: Ed25519 signature must be 64 bytes")
    return value["key_id"], signature


def root_trusted_executable(candidate: str) -> bool:
    path = pathlib.Path(candidate)
    if not path.is_absolute() or ".." in path.parts:
        return False
    try:
        resolved = path.resolve(strict=True)
    except OSError:
        return False

    for checked_path in {path, resolved}:
        current = pathlib.Path(checked_path.anchor)
        components = [current]
        for component in checked_path.parts[1:]:
            current /= component
            components.append(current)
        for component in components:
            try:
                metadata = component.lstat()
            except OSError:
                return False
            if metadata.st_uid != 0:
                return False
            if not stat.S_ISLNK(metadata.st_mode) and metadata.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
                return False

    try:
        return resolved.is_file() and os.access(resolved, os.X_OK)
    except OSError:
        return False


def openssl_executable() -> str:
    override = os.environ.get("OPENSSL_BIN")
    if override and not pathlib.Path(override).is_absolute():
        fail("OPENSSL_BIN must be an absolute path to OpenSSL 3 or newer")
    candidates = [override] if override else [
        "/opt/homebrew/opt/openssl@3/bin/openssl",
        "/usr/local/opt/openssl@3/bin/openssl",
        shutil.which("openssl"),
    ]

    checked: list[str] = []
    for candidate in candidates:
        if not candidate or candidate in checked:
            continue
        checked.append(candidate)
        if os.geteuid() == 0 and not root_trusted_executable(candidate):
            continue
        try:
            result = subprocess.run(
                [candidate, "version"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=OPENSSL_PROBE_TIMEOUT_SECONDS,
            )
        except (OSError, subprocess.TimeoutExpired):
            continue
        version = re.match(r"^OpenSSL ([0-9]+)\.", result.stdout)
        if result.returncode == 0 and version and int(version.group(1)) >= 3:
            return candidate

    if override:
        fail("OPENSSL_BIN must identify a trusted OpenSSL 3 or newer executable; LibreSSL and OpenSSL 1.x are unsupported")
    fail("OpenSSL 3 or newer is required for Ed25519 catalog verification; LibreSSL and OpenSSL 1.x are unsupported")


def verify_ed25519(public_key: bytes, signature: bytes, message: bytes, label: str) -> None:
    # RFC 8410 SubjectPublicKeyInfo prefix for a raw Ed25519 public key.
    spki = bytes.fromhex("302a300506032b6570032100") + public_key
    with tempfile.TemporaryDirectory(prefix="macprovider-catalog-verify-") as tmp:
        tmpdir = pathlib.Path(tmp)
        pub_path = tmpdir / "public.der"
        sig_path = tmpdir / "signature.bin"
        msg_path = tmpdir / "message.bin"
        pub_path.write_bytes(spki)
        sig_path.write_bytes(signature)
        msg_path.write_bytes(message)
        try:
            result = subprocess.run(
                [openssl_executable(), "pkeyutl", "-verify", "-pubin", "-inkey", str(pub_path),
                 "-keyform", "DER", "-rawin", "-in", str(msg_path), "-sigfile", str(sig_path)],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=OPENSSL_VERIFY_TIMEOUT_SECONDS,
            )
        except subprocess.TimeoutExpired:
            fail(f"{label}: signature verification timed out")
    if result.returncode != 0:
        fail(f"{label}: signature verification failed")


def generated_swift(candidate: bytes, demand: bytes, rate_card: bytes, signer_key_id: str | None = None) -> str:
    trusted = keyring()
    swift_keys = "\n".join(
        f'        "{key_id}": "{base64.b64encode(raw).decode()}",'
        for key_id, raw in sorted(trusted.items())
    )
    if signer_key_id is None:
        sidecar = STATIC_DIR / "autotune-candidates.json.sig"
        if sidecar.exists():
            signer_key_id = parse_sidecar(sidecar.read_bytes(), sidecar.name)[0]
    swift_signer = f'"{signer_key_id}"' if signer_key_id is not None else "nil"
    return (
        "// Generated by scripts/catalog-release.py. DO NOT EDIT.\n"
        "import Foundation\n\n"
        "extension AutotuneStaticInputs {\n"
        "    static let bakedDemandRankJSON = \"\"\"\n"
        + "    " + demand.decode("utf-8")
        + "\n    \"\"\"\n\n"
        "    static let bakedCandidateCatalogJSON = \"\"\"\n"
        + "    " + candidate.decode("utf-8")
        + "\n    \"\"\"\n"
        + "\n    static let bakedRateCardJSON = \"\"\"\n"
        + "    " + rate_card.decode("utf-8")
        + "\n    \"\"\"\n"
        + "\n    static let generatedTrustedPublicKeys = [\n"
        + swift_keys
        + "\n    ]\n"
        + f"\n    static let bakedCatalogSignerKeyID: String? = {swift_signer}\n"
        "}\n"
    )


def validate_pair(candidate_obj: dict, demand_obj: dict) -> None:
    for field in ("version", "generated_at", "policy_version"):
        if candidate_obj[field] != demand_obj[field]:
            fail(f"candidate and demand {field} must match the atomic release")


def validate_release_inputs(candidate_obj: dict, demand_obj: dict, rate_card_obj: dict) -> None:
    validate_pair(candidate_obj, demand_obj)
    for field in ("generated_at", "policy_version"):
        if candidate_obj[field] != rate_card_obj[field]:
            fail(f"rate-card {field} must match the atomic release")


def rate_card_projection_hash(value: dict) -> str:
    def json_number(raw: int | float) -> str:
        if isinstance(raw, int):
            return str(raw)
        if raw.is_integer():
            return str(int(raw))
        return f"{raw:.15f}".rstrip("0").rstrip(".")

    default_row = value["rows"]["default"]
    parts = [
        '{"global_multiplier_ppm":',
        str(default_row["global_multiplier_ppm"]),
        ',"provider_share_bps":',
        str(default_row["provider_share_bps"]),
        ',"rows":{',
    ]
    for index, key in enumerate(sorted(value["rows"])):
        if index > 0:
            parts.append(",")
        row = value["rows"][key]
        parts.extend([
            json.dumps(key, separators=(",", ":")),
            ':{"completion_rate_per_mtok":',
            str(row["completion_rate_per_mtok"]),
            ',"global_multiplier_ppm":',
            str(row["global_multiplier_ppm"]),
            ',"prompt_cache_hit_rate_per_mtok":',
            str(row["prompt_cache_hit_rate_per_mtok"]),
            ',"prompt_rate_per_mtok":',
            str(row["prompt_rate_per_mtok"]),
            ',"provider_share_bps":',
            str(row["provider_share_bps"]),
            "}",
        ])
    parts.extend([
        '},"usd_per_million_credits":',
        json_number(value["usd_per_million_credits"]),
        "}",
    ])
    return sha256("".join(parts).encode())


def validate_rate_card(data: bytes) -> dict:
    value = strict_json(data, "rate-card")
    exact_keys(
        value,
        {"version", "policy_version", "generated_at", "usd_per_million_credits", "rows"},
        {"version", "policy_version", "generated_at", "usd_per_million_credits", "rows"},
        "rate-card",
    )
    if not isinstance(value["version"], str) or not value["version"].strip() or value["version"].strip() != value["version"]:
        fail("rate-card: version required")
    if not isinstance(value["policy_version"], str) or not value["policy_version"].strip() or value["policy_version"].strip() != value["policy_version"]:
        fail("rate-card: policy_version required")
    parse_time(value["generated_at"], "rate-card generated_at")
    usd = value["usd_per_million_credits"]
    if not isinstance(usd, (int, float)) or isinstance(usd, bool) or not math.isfinite(usd) or usd < 0:
        fail("rate-card: usd_per_million_credits must be finite and >= 0")
    rows = value["rows"]
    if not isinstance(rows, dict) or not rows:
        fail("rate-card: rows required")
    if "default" not in rows:
        fail("rate-card: default row required")
    row_fields = {
        "prompt_rate_per_mtok",
        "prompt_cache_hit_rate_per_mtok",
        "completion_rate_per_mtok",
        "provider_share_bps",
        "global_multiplier_ppm",
    }
    for key, row in rows.items():
        if key != "default":
            if not MODEL_KEY.fullmatch(key):
                fail(f"rate-card row {key}: invalid model key")
            # Same invariant as `validate_rate_card_source`, in the SHARED
            # validator so `verify-directory` and the parity gate enforce it on
            # bytes they did not generate: billing resolves exact spelling first.
            normalized = normalize_model_key(key)
            if normalized != key:
                fail(
                    f"rate-card row {key}: must be the SPEC-005 normalized model key "
                    f"({normalized!r}); billing resolves exact spelling first"
                )
        if not isinstance(row, dict):
            fail(f"rate-card row {key}: row must be an object")
        exact_keys(row, row_fields, row_fields, f"rate-card row {key}")
        for field in ("prompt_rate_per_mtok", "prompt_cache_hit_rate_per_mtok", "completion_rate_per_mtok", "global_multiplier_ppm"):
            value_int = row[field]
            if not isinstance(value_int, int) or isinstance(value_int, bool) or value_int < 0:
                fail(f"rate-card row {key}: {field} must be >= 0")
        share = row["provider_share_bps"]
        if not isinstance(share, int) or isinstance(share, bool) or not 0 <= share <= 10000:
            fail(f"rate-card row {key}: provider_share_bps must be in [0,10000]")
    # SPEC-023 §3.3.1 rule 3: `provider_share_bps` and `global_multiplier_ppm` are
    # RELEASE-GLOBAL values materialised onto every published row, "identical
    # across every row of a release". The published feed carries them only per
    # row, so the `default` row is their in-band representation and every other
    # row MUST equal it. This lives in the shared validator, not in expansion, so
    # `verify`, `verify-directory`, and the parity gate all enforce it on bytes
    # they did not generate (a signed feed whose non-default row carries a
    # different share would otherwise verify).
    globals_row = rows["default"]
    for key in sorted(rows):
        for field in ("provider_share_bps", "global_multiplier_ppm"):
            if rows[key][field] != globals_row[field]:
                fail(
                    f"rate-card row {key}: {field}={rows[key][field]} is not the release-global "
                    f"value {globals_row[field]}; SPEC-023 §3.3.1 rule 3 requires it on every row"
                )
    expected_version = rate_card_projection_hash(value)
    if value["version"] != expected_version:
        fail(f"rate-card: version must equal projection hash {expected_version}")
    return value


def _credit_row(value: object, label: str) -> dict:
    """Validate one `rate-card-source.json` row/class body (SPEC-023 §3.3.1 rule 3).

    A source row or class carries EXACTLY the three credit-rate fields. Declaring
    `provider_share_bps` or `global_multiplier_ppm` on either is rejected here:
    those are release-global values and a per-class share is not representable in
    the coordinator billing fallback the expansion writes into.
    """
    if not isinstance(value, dict):
        fail(f"{label}: must be an object")
    exact_keys(value, set(RATE_CREDIT_FIELDS), set(RATE_CREDIT_FIELDS), label)
    for field in RATE_CREDIT_FIELDS:
        credit = value[field]
        if not isinstance(credit, int) or isinstance(credit, bool) or credit < 0:
            fail(f"{label}: {field} must be an integer >= 0")
    return value


def validate_rate_card_source(data: bytes, label: str = "rate-card-source") -> dict:
    """Validate the never-published rate-card authoring source (SPEC-023 §3.3.1 rule 3).

    The top level is the exact closed set below; `rows` and `classes` MAY be
    empty objects but MUST be present. An unknown key, a missing key, a
    wrong-typed value, an unknown `schema_version`, or a row/class entry with any
    field beyond the three credit-rate fields fails the release closed before
    signing (AC-CAT-9).
    """
    value = strict_json(data, label)
    top = {
        "schema_version", "generated_at", "policy_version", "usd_per_million_credits",
        "provider_share_bps", "global_multiplier_ppm", "rows", "classes",
    }
    exact_keys(value, top, top, label)
    if value["schema_version"] != RATE_CARD_SOURCE_SCHEMA:
        fail(f"{label}: schema_version must be {RATE_CARD_SOURCE_SCHEMA}")
    if not isinstance(value["policy_version"], str) or value["policy_version"].strip() != value["policy_version"] or not value["policy_version"]:
        fail(f"{label}: policy_version must be a non-empty trimmed string")
    parse_time(value["generated_at"], label)
    usd = value["usd_per_million_credits"]
    if not isinstance(usd, (int, float)) or isinstance(usd, bool) or not math.isfinite(usd) or usd < 0:
        fail(f"{label}: usd_per_million_credits must be finite and >= 0")
    share = value["provider_share_bps"]
    if not isinstance(share, int) or isinstance(share, bool) or not 0 <= share <= 10000:
        fail(f"{label}: provider_share_bps must be in [0,10000]")
    multiplier = value["global_multiplier_ppm"]
    if not isinstance(multiplier, int) or isinstance(multiplier, bool) or multiplier < 0:
        fail(f"{label}: global_multiplier_ppm must be an integer >= 0")
    # `global_multiplier_ppm` is already bounded to the coordinator's int64
    # domain by `strict_json`, which rejects any wider integer at parse time.
    rows = value["rows"]
    classes = value["classes"]
    if not isinstance(rows, dict) or not isinstance(classes, dict):
        fail(f"{label}: rows and classes must be objects")
    for key, row in rows.items():
        if key != "default":
            if not MODEL_KEY.fullmatch(key):
                fail(f"{label} row {key}: invalid model key")
            # §3.3.1 rule 3: `rows` maps NORMALIZED model keys. Billing resolves
            # exact spelling before `NormalizeModelKey`, so an un-normalized
            # explicit row would price one spelling of a model differently from
            # its equivalents. Requiring every key to be its own normalization
            # also makes two rows colliding under normalization unrepresentable.
            normalized = normalize_model_key(key)
            if normalized != key:
                fail(
                    f"{label} row {key}: must be the SPEC-005 normalized model key "
                    f"({normalized!r}); billing resolves exact spelling first"
                )
        _credit_row(row, f"{label} row {key}")
    for name, entry in classes.items():
        if name not in RATE_CLASSES:
            fail(f"{label} class {name}: unknown rate_class")
        _credit_row(entry, f"{label} class {name}")
    return value


def expand_rate_card(source_obj: dict, rate_classes: dict[str, str], candidate_obj: dict) -> bytes:
    """Materialise the published §3.3 rate card from the §3.3.1 authoring source.

    `rate_classes` maps an artifact-feed model key to the `rate_class` its entry
    declares. Precedence is rule 5: an explicit source row is published verbatim
    and the class expansion for that key is discarded. Because a source row is
    schema-forced to carry all three credit fields, a partial override is not
    representable, so the rule-5 ambiguity case cannot be authored. Rule 4's
    release-global `provider_share_bps` / `global_multiplier_ppm` are materialised
    onto every published row without rounding or unit conversion.

    An explicit row resolves the same way rule 7 (and SPEC-005 §5.5 rate
    resolution) resolves one: by EXACT key first, then by `NormalizeModelKey`.
    The catalog carries both spellings — the artifact feed and candidate catalog
    key `nvidia/nemotron-3-nano-30b-a3b` is priced by the published row
    `nemotron-3-nano-30b-a3b` — so exact-key-only lookup would treat a
    fully-priced key as unpriced and demand class rates for it. Resolving through
    normalization publishes NO new row for the key: the explicit row already
    prices it, and adding a second spelling would change the published bytes.
    A declared `rate_class` whose class has no rates is therefore an error only
    when no explicit row resolves for that key.

    A class row is materialised under `NormalizeModelKey(key)`, never under the
    artifact-feed spelling: rule 4 requires the published and coordinator rows
    to carry the same normalized key, and billing resolves exact spelling BEFORE
    normalization, so a class row published under `vendor/model` would make
    `model` and `vendor/model` — one model — resolve to different rows. Two
    artifact keys that normalize to one key must declare one class; anything
    else is an authoring conflict that fails closed rather than letting sort
    order pick the price.
    """
    explicit = source_obj["rows"]
    rows: dict[str, dict] = {}
    for key in sorted(explicit):
        rows[key] = dict(explicit[key])
    class_owner: dict[str, tuple[str, str]] = {}
    for key in sorted(rate_classes):
        # Precedence is decided against the EXPLICIT rows only: a row this loop
        # materialised for an earlier spelling of the same model is not an
        # override, it is the collision the owner check below has to see.
        if key in explicit and key != "default":
            continue
        normalized = normalize_model_key(key)
        if normalized == "default":
            fail(f"rate-card expansion: model key {key!r} normalizes to the reserved row 'default'")
        if normalized in explicit:
            continue
        name = rate_classes[key]
        entry = source_obj["classes"].get(name)
        if entry is None:
            fail(
                f"rate-card expansion: model key {key!r} declares rate_class {name!r} "
                "but the rate-card source has no rates for that class, and no explicit "
                f"row resolves for it by exact key or NormalizeModelKey ({normalized!r})"
            )
        owner = class_owner.get(normalized)
        if owner is not None:
            if owner[1] != name:
                fail(
                    f"rate-card expansion: model keys {owner[0]!r} and {key!r} both normalize to "
                    f"{normalized!r} but declare rate classes {owner[1]!r} and {name!r}; one "
                    "normalized key prices one way"
                )
            continue
        class_owner[normalized] = (key, name)
        rows[normalized] = dict(entry)
    for row in rows.values():
        row["provider_share_bps"] = source_obj["provider_share_bps"]
        row["global_multiplier_ppm"] = source_obj["global_multiplier_ppm"]
    value = {
        "generated_at": source_obj["generated_at"],
        "policy_version": source_obj["policy_version"],
        "rows": rows,
        "usd_per_million_credits": source_obj["usd_per_million_credits"],
        "version": "",
    }
    value["version"] = rate_card_projection_hash(value)
    rate_card = canonical_sorted_bytes(value)
    rate_card_obj = validate_rate_card(rate_card)
    require_recommendable_rate_rows(candidate_obj, rate_card_obj)
    return rate_card


def require_recommendable_rate_rows(candidate_obj: dict, rate_card_obj: dict) -> None:
    """SPEC-023 §3.3.1 rule 7 / AC-CAT-10: every `recommendable` candidate row MUST
    resolve to a concrete published rate row by exact key or `NormalizeModelKey`.
    Reaching only the `default` row does not satisfy the authoring-time invariant.
    """
    rows = rate_card_obj["rows"]
    for key, row in sorted(candidate_obj["rows"].items()):
        if row["runtime_status"] != "recommendable":
            continue
        if key in rows and key != "default":
            continue
        normalized = normalize_model_key(key)
        if normalized in rows and normalized != "default":
            continue
        fail(
            f"rate-card: recommendable candidate row {key!r} resolves to no rate-card "
            f"row by exact key or NormalizeModelKey ({normalized!r}); the default row "
            "does not satisfy SPEC-023 §3.3.1 rule 7"
        )


def parse_coordinator_rewards(text: str) -> tuple[float, float, dict[str, dict]]:
    """Read `rewards.provider_share`, `rewards.global_multiplier`, and the inline
    `rewards.rate_card` fallback rows from the committed coordinator config.

    Deliberately a narrow, fail-closed reader for exactly the block SPEC-023
    §3.3.1 rule 4 maps into, rather than a YAML dependency (this repo pins its
    dependency set) or a `sed`-shaped rewrite. Anything it does not recognise
    inside the block fails the release closed instead of being ignored.
    """
    share: str | None = None
    multiplier: str | None = None
    rows: dict[str, dict] = {}
    in_rewards = False
    in_rate_card = False
    current: str | None = None
    for raw_line in text.splitlines():
        if "\t" in raw_line:
            if raw_line.strip().startswith("#") or not raw_line.strip():
                continue
            if not in_rewards:
                # Tabs outside the block are the YAML loader's concern, not
                # this indentation parser's; do not misreport them as a
                # rewards-block defect.
                continue
            if raw_line[:1] not in (" ", "\t"):
                break  # a new top-level key ends the rewards block
            fail("coordinator.yaml: tabs are not permitted in the rewards block")
        line = re.sub(r"(?:(?<=\s)|^)#.*$", "", raw_line).rstrip()
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip(" "))
        body = line.strip()
        if indent == 0:
            if in_rewards:
                break
            in_rewards = body == "rewards:"
            continue
        if not in_rewards:
            continue
        if indent == 2:
            in_rate_card = False
            current = None
            if body == "rate_card:":
                in_rate_card = True
            elif body.startswith("provider_share:"):
                share = body.split(":", 1)[1].strip()
            elif body.startswith("global_multiplier:"):
                multiplier = body.split(":", 1)[1].strip()
            continue
        if not in_rate_card:
            continue
        if indent == 4:
            if not body.endswith(":"):
                fail(f"coordinator.yaml: unexpected rewards.rate_card entry {body!r}")
            current = body[:-1].strip().strip("\"'")
            if current in rows:
                fail(f"coordinator.yaml: duplicate rewards.rate_card row {current!r}")
            rows[current] = {}
            continue
        if indent == 6 and current is not None:
            name, _, value = body.partition(":")
            name = name.strip()
            if name not in COORDINATOR_RATE_FIELD_MAP.values():
                fail(f"coordinator.yaml: rewards.rate_card.{current}.{name} is not a credit field")
            if name in rows[current]:
                fail(f"coordinator.yaml: duplicate rewards.rate_card.{current}.{name}")
            try:
                rows[current][name] = int(value.strip())
            except ValueError:
                fail(f"coordinator.yaml: rewards.rate_card.{current}.{name} must be an integer")
            continue
        fail(f"coordinator.yaml: unexpected line in the rewards block: {raw_line.strip()!r}")
    if share is None or multiplier is None:
        fail("coordinator.yaml: rewards.provider_share and rewards.global_multiplier are required")
    try:
        return float(share), float(multiplier), rows
    except ValueError:
        fail("coordinator.yaml: rewards.provider_share and rewards.global_multiplier must be numbers")


def scaled_nonnegative_integer(raw: float, scale: int, label: str) -> int:
    """Port of Go `int64(math.Round(v * float64(scale)))` for a non-negative `v`.

    `billing.ParseShareBps` / `billing.ParseMultiplierPPM` multiply the value the
    coordinator PARSED — a binary64 — by the binary64 scale, then round half away
    from zero. Reconstructing the value's shortest decimal text and rounding a
    `Decimal` is a different computation: it answers what the operator WROTE, not
    what the coordinator computes, and the two disagree whenever the binary64
    product falls just off a half unit that the decimal text lands exactly on.
    The release gate would then accept a signed `provider_share_bps` the
    coordinator never derives, so the parity rule (§3.3.1 rule 9) would be
    enforcing the wrong integer.

    So: do exactly what Go does. `math.Round` compares the FRACTIONAL PART to one
    half; it never forms `x + 0.5`, and that distinction is not academic.
    `math.floor(x + 0.5)` answers one unit HIGH whenever the binary64 SUM rounds
    up onto the integer boundary `x` itself sits below — the value is then carried
    across on an addition's rounding error rather than on its own magnitude. The
    product `0.49999999999999994` (the largest binary64 below one half, which
    `4.9999999999999996e-05 * 10000` produces exactly) is the case: `floor(x+0.5)`
    answers 1 bps, `math.Round` answers 0, and the release gate would then accept
    a signed `provider_share_bps` settlement never derives.

    `x - math.floor(x)` is EXACT for every `0 <= x < 2**52`, so the comparison
    below is Go's semantics with no intermediate rounding at all; at or above
    2**52 every binary64 is already an integer.
    `scripts/tests/fixtures/rate_global_rounding_cases.json` pins the vectors
    IMMEDIATELY below and above the half-unit products against BOTH this port and
    the Go functions themselves.
    """
    if not isinstance(raw, (int, float)) or isinstance(raw, bool):
        fail(f"{label}: expected a finite non-negative number, got {raw!r}")
    value = float(raw)
    if not math.isfinite(value) or value < 0:
        fail(f"{label}: expected a finite non-negative number, got {raw!r}")
    scaled = value * float(scale)
    if not math.isfinite(scaled):
        fail(f"{label}: {raw!r} scaled by {scale} is not finite")
    if scaled >= 2.0 ** 52:
        rounded = int(scaled)
    else:
        truncated = math.floor(scaled)
        rounded = int(truncated) + 1 if scaled - truncated >= 0.5 else int(truncated)
    if rounded > INT64_MAX:
        # Go's float64 -> int64 conversion is implementation-defined out of
        # range; a "parity" integer wider than int64 is not what billing holds.
        fail(f"{label}: {raw!r} scaled by {scale} exceeds the coordinator int64 domain")
    return rounded


def check_rate_card_parity(rate_card_obj: dict, coordinator_text: str) -> None:
    """SPEC-023 §3.3.1 rule 9 / AC-CAT-14: generated-feed vs billing-config parity.

    The published rows and the coordinator inline fallback rows must agree
    row-for-row under the rule-4 mapping, and the release-global share/multiplier
    must equal the coordinator globals after unit conversion. Any disagreement,
    in either direction, fails the release closed before signing.
    """
    share, multiplier, coordinator_rows = parse_coordinator_rewards(coordinator_text)
    published = rate_card_obj["rows"]
    missing = sorted(set(published) - set(coordinator_rows))
    extra = sorted(set(coordinator_rows) - set(published))
    if missing:
        fail(f"rate-card parity: coordinator rewards.rate_card is missing rows {missing}")
    if extra:
        fail(f"rate-card parity: coordinator rewards.rate_card has extra rows {extra}")
    for key in sorted(published):
        coordinator_row = coordinator_rows[key]
        for field, coordinator_field in COORDINATOR_RATE_FIELD_MAP.items():
            if coordinator_field not in coordinator_row:
                fail(f"rate-card parity: coordinator rewards.rate_card.{key} is missing {coordinator_field}")
            if coordinator_row[coordinator_field] != published[key][field]:
                fail(
                    f"rate-card parity: {key}.{field}={published[key][field]} disagrees with "
                    f"coordinator rewards.rate_card.{key}.{coordinator_field}={coordinator_row[coordinator_field]}"
                )
        unknown = sorted(set(coordinator_row) - set(COORDINATOR_RATE_FIELD_MAP.values()))
        if unknown:
            fail(f"rate-card parity: coordinator rewards.rate_card.{key} carries non-credit fields {unknown}")
    # Mirrors billing.ParseShareBps / billing.ParseMultiplierPPM (round-half-away).
    # Checked on EVERY published row, not only `default`: the globals are
    # release-global (rule 3) and the coordinator holds exactly one of each, so a
    # non-default row that disagrees is a money-path divergence even though the
    # projection hash only quotes the default row's copy.
    expected_share = scaled_nonnegative_integer(share, 10000, "coordinator rewards.provider_share")
    expected_multiplier = scaled_nonnegative_integer(
        multiplier, 1000000, "coordinator rewards.global_multiplier"
    )
    for key in sorted(published):
        row = published[key]
        if row["provider_share_bps"] != expected_share:
            fail(
                f"rate-card parity: {key}.provider_share_bps={row['provider_share_bps']} disagrees "
                f"with coordinator rewards.provider_share={share}"
            )
        if row["global_multiplier_ppm"] != expected_multiplier:
            fail(
                f"rate-card parity: {key}.global_multiplier_ppm={row['global_multiplier_ppm']} disagrees "
                f"with coordinator rewards.global_multiplier={multiplier}"
            )


def coordinator_rate_card_yaml(rate_card_obj: dict) -> str:
    """Deterministic `rewards.rate_card:` block for the published rows.

    The operator pastes this into `phase4-coordinator/dist/coordinator.yaml` when
    a class expansion introduces or changes a fallback row; the rule-9 parity gate
    above then refuses to cut a release until the committed config agrees. The
    generator emits rather than rewrites because that file carries reviewed
    money-path provenance comments that a machine rewrite would destroy.
    """
    lines = ["  rate_card:"]
    for key in sorted(rate_card_obj["rows"]):
        lines.append(f"    {key}:")
        for field, coordinator_field in COORDINATOR_RATE_FIELD_MAP.items():
            lines.append(f"      {coordinator_field}: {rate_card_obj['rows'][key][field]}")
    return "\n".join(lines) + "\n"


def _validate_artifact_source_ref(entry: dict, expected_kind: str, label: str) -> None:
    ref = entry["source_ref"]
    if not isinstance(ref, dict):
        fail(f"{label}: source_ref must be an object")
    kind = ref.get("kind")
    if kind != expected_kind:
        fail(
            f"{label}: runtime_format {entry['runtime_format']!r} requires "
            f"source_ref.kind {expected_kind!r}, not {kind!r}"
        )
    if kind == "huggingface_revision":
        fields = {"kind", "repo_id", "revision"}
        exact_keys(ref, fields, fields, f"{label} source_ref")
        if not isinstance(ref["repo_id"], str) or not MODEL_ID.fullmatch(ref["repo_id"]):
            fail(f"{label}: source_ref.repo_id must be a HuggingFace repo id")
        if not isinstance(ref["revision"], str) or not HEX40.fullmatch(ref["revision"]):
            fail(f"{label}: source_ref.revision must be an immutable lowercase 40-hex commit")
    else:
        fields = {"kind", "library_tag", "digest"}
        exact_keys(ref, fields, fields, f"{label} source_ref")
        if not isinstance(ref["library_tag"], str) or not ref["library_tag"].strip():
            fail(f"{label}: source_ref.library_tag required")
        digest = ref["digest"]
        if not isinstance(digest, str) or not digest.startswith("sha256:") or not HEX64.fullmatch(digest[len("sha256:"):]):
            fail(f"{label}: source_ref.digest must be 'sha256:' plus lowercase 64-hex")
        # SPEC-023 §3.7.4: both fields describe the same GGUF bytes.
        if digest != "sha256:" + entry["hash"]:
            fail(f"{label}: gguf source_ref.digest must equal 'sha256:' + hash")


def validate_artifact_entry(entry: object, label: str, *, allow_unmeasured_size: bool) -> None:
    """Validate one `artifacts.<artifact_id>` object (SPEC-023 §3.7.3, §3.7.4).

    The field set is closed, and the four identity fields are validated as one
    closed matrix row: `runtime_format` determines the only legal
    `hash_algorithm`, `source_ref.kind`, and `allowed_runtime_sources` set. Any
    other tuple is a feed-integrity failure at generation (AC-CAT-16).
    """
    if not isinstance(entry, dict):
        fail(f"{label}: artifact entry must be an object")
    allowed = {
        "runtime_format", "quantization", "source_ref", "hash_algorithm", "hash",
        "size_bytes", "min_ram_gb", "allowed_runtime_sources", "verification_status",
        "verified_at", "notes",
    }
    exact_keys(entry, allowed, allowed - {"notes"}, label)
    runtime_format = entry["runtime_format"]
    if runtime_format not in ARTIFACT_IDENTITY_MATRIX:
        fail(f"{label}: unknown runtime_format {runtime_format!r}")
    algorithm, kind, sources = ARTIFACT_IDENTITY_MATRIX[runtime_format]
    if entry["hash_algorithm"] != algorithm:
        fail(
            f"{label}: runtime_format {runtime_format!r} requires hash_algorithm "
            f"{algorithm!r}, not {entry['hash_algorithm']!r}"
        )
    if not isinstance(entry["quantization"], str) or not entry["quantization"].strip():
        fail(f"{label}: quantization must be a non-empty string")
    if not isinstance(entry["hash"], str) or not HEX64.fullmatch(entry["hash"]):
        fail(f"{label}: hash must be lowercase 64-hex")
    size = entry["size_bytes"]
    if size is None:
        if not allow_unmeasured_size:
            fail(f"{label}: size_bytes must be measured before the release is generated")
    elif not isinstance(size, int) or isinstance(size, bool) or size <= 0:
        fail(f"{label}: size_bytes must be an integer > 0")
    if not finite_number(entry["min_ram_gb"]) or entry["min_ram_gb"] <= 0:
        fail(f"{label}: min_ram_gb must be a number > 0")
    runtime_sources = entry["allowed_runtime_sources"]
    if (
        not isinstance(runtime_sources, list)
        or not runtime_sources
        or not all(isinstance(item, str) for item in runtime_sources)
    ):
        fail(f"{label}: allowed_runtime_sources must be a non-empty array of strings")
    if len(set(runtime_sources)) != len(runtime_sources):
        fail(f"{label}: allowed_runtime_sources must not repeat an adapter")
    outside = sorted(set(runtime_sources) - sources)
    if outside:
        fail(
            f"{label}: runtime_format {runtime_format!r} may not allow runtime sources "
            f"{outside} (permitted: {sorted(sources)})"
        )
    status = entry["verification_status"]
    if status not in ARTIFACT_VERIFICATION_STATUSES:
        fail(f"{label}: invalid verification_status {status!r}")
    if status == "verified" and "openai_compatible_loopback" in runtime_sources:
        fail(f"{label}: a verified artifact may not allow openai_compatible_loopback")
    verified_at = entry["verified_at"]
    if status == "verified":
        if not isinstance(verified_at, str) or not FULL_DATE.fullmatch(verified_at):
            fail(f"{label}: verified_at must be an RFC3339 full-date (YYYY-MM-DD) when verified")
        try:
            datetime.strptime(verified_at, "%Y-%m-%d")
        except ValueError as exc:
            fail(f"{label}: verified_at is not a real date: {exc}")
    elif verified_at is not None:
        fail(f"{label}: verified_at must be null unless verification_status is 'verified'")
    if "notes" in entry and not isinstance(entry["notes"], str):
        fail(f"{label}: notes must be a string")
    _validate_artifact_source_ref(entry, kind, label)


def validate_artifact_models(models: object, label: str, *, allow_unmeasured_size: bool) -> None:
    """Validate the shared `models` block of the artifact source and published feed."""
    if not isinstance(models, dict) or not models:
        fail(f"{label}: models must be a non-empty object")
    for model_key, entry in models.items():
        model_label = f"{label} model {model_key}"
        if not isinstance(model_key, str) or not MODEL_KEY.fullmatch(model_key) or "//" in model_key:
            fail(f"{label}: invalid model key {model_key!r}")
        if not isinstance(entry, dict):
            fail(f"{model_label}: must be an object")
        exact_keys(
            entry,
            {"rate_class", "primary_artifact_id", "artifacts"},
            {"primary_artifact_id", "artifacts"},
            model_label,
        )
        if "rate_class" in entry and entry["rate_class"] not in RATE_CLASSES:
            fail(f"{model_label}: invalid rate_class {entry['rate_class']!r}")
        artifacts = entry["artifacts"]
        if not isinstance(artifacts, dict) or not artifacts:
            fail(f"{model_label}: artifacts must be a non-empty object")
        for artifact_id, artifact in artifacts.items():
            if not isinstance(artifact_id, str) or not ARTIFACT_ID.fullmatch(artifact_id):
                fail(f"{model_label}: artifact_id {artifact_id!r} does not match ^[a-z0-9][a-z0-9-]{{0,63}}$")
            validate_artifact_entry(
                artifact,
                f"{model_label} artifact {artifact_id}",
                allow_unmeasured_size=allow_unmeasured_size,
            )
        primary_id = entry["primary_artifact_id"]
        if not isinstance(primary_id, str) or primary_id not in artifacts:
            fail(f"{model_label}: primary_artifact_id {primary_id!r} does not name an artifact of this model")
        if artifacts[primary_id]["runtime_format"] != "mlx_safetensors":
            fail(f"{model_label}: primary_artifact_id must name an mlx_safetensors artifact")


def require_unique_artifact_hashes(models: dict, label: str) -> None:
    """SPEC-023 §3.7.4 / AC-CAT-18: within one feed a `(hash_algorithm, hash)` pair
    MUST appear under exactly one model key and exactly one `artifact_id`.

    This is a NEW check that closes the opposite direction from
    `validate_candidate`'s conflicting-`model_sha256` check; neither subsumes the
    other and a release fails closed on either.
    """
    seen: dict[tuple[str, str], tuple[str, str]] = {}
    for model_key in sorted(models):
        for artifact_id in sorted(models[model_key]["artifacts"]):
            artifact = models[model_key]["artifacts"][artifact_id]
            identity = (artifact["hash_algorithm"], artifact["hash"])
            prior = seen.get(identity)
            if prior is not None:
                fail(
                    f"{label}: ({identity[0]}, {identity[1]}) appears under both "
                    f"{prior[0]}/{prior[1]} and {model_key}/{artifact_id}; one hash must "
                    "resolve to exactly one pricing identity"
                )
            seen[identity] = (model_key, artifact_id)


def require_primary_artifact_consistency(models: dict, candidate_obj: dict, label: str) -> None:
    """SPEC-023 §3.7.5 / AC-CAT-5: primary-artifact consistency with the candidate row.

    Every `listed` or `recommendable` row MUST have a model entry whose primary
    artifact is `verified` and identity-identical to that row. A `candidate` row is
    out of scope for the `verified` requirement only: its primary artifact MAY stay
    `declared`, but must still be present, `mlx_safetensors`, and identity-
    corresponding. `blocked` rows are out of scope as before.
    """
    rows = candidate_obj["rows"]
    for model_key in sorted(models):
        if model_key not in rows:
            fail(f"{label}: model key {model_key!r} is absent from the candidate catalog")
    for model_key in sorted(rows):
        row = rows[model_key]
        status = row["runtime_status"]
        if status == "blocked":
            continue
        entry = models.get(model_key)
        if entry is None:
            if status == "candidate":
                continue
            fail(f"{label}: {status} candidate row {model_key!r} has no artifact-feed model entry")
        primary = entry["artifacts"][entry["primary_artifact_id"]]
        if primary["hash"] != row.get("model_sha256"):
            fail(f"{label}: model {model_key} primary artifact hash does not equal the candidate model_sha256")
        if primary["source_ref"]["repo_id"] != row["model_id"]:
            fail(f"{label}: model {model_key} primary artifact repo_id does not equal the candidate model_id")
        if primary["source_ref"]["revision"] != row.get("model_revision"):
            fail(f"{label}: model {model_key} primary artifact revision does not equal the candidate model_revision")
        if primary["min_ram_gb"] != row["min_ram_gb"]:
            fail(f"{label}: model {model_key} primary artifact min_ram_gb does not equal the candidate min_ram_gb")
        if status != "candidate" and primary["verification_status"] != "verified":
            fail(f"{label}: {status} candidate row {model_key!r} requires a verified primary artifact")
        if status == "recommendable" and "rate_class" not in entry:
            fail(f"{label}: recommendable candidate row {model_key!r} must declare a rate_class")


def validate_artifact_source(
    data: bytes,
    candidate_obj: dict | None = None,
    label: str = "autotune-artifacts-source",
) -> dict:
    """Validate the operator-authored artifact-feed source document.

    The source carries the `models` block verbatim; the generator supplies the
    release-bound header (`version`, `release_id`, `generated_at`,
    `policy_version`, `candidate_catalog_sha256`). `size_bytes` MAY be `null` here
    to mean "the operator has not measured this artifact yet"; generation then
    fails closed rather than publishing a fabricated byte count.

    STRUCTURAL checks — schema closure, the identity-tuple matrix, artifact_id
    grammar, GGUF digest equality, global hash uniqueness — always run: they are
    properties of the document alone. Consistency with the CANDIDATE CATALOG runs
    only when `candidate_obj` is supplied, which is activation time and every
    artifact-bound cut. Pre-activation the source is committed but unpublished and
    may still carry unmeasured sizes, so an ordinary candidate-catalog change
    (adding a row, updating an identity) must not block the four-feed release it
    has always produced; that drift is caught at the release cut that would
    actually publish the feed. See `docs/runbooks/catalog-artifact-feed-release.md`.
    """
    value = strict_json(data, label)
    top = {"schema_version", "source", "models"}
    exact_keys(value, top, top, label)
    if value["schema_version"] != ARTIFACT_SOURCE_SCHEMA:
        fail(f"{label}: schema_version must be {ARTIFACT_SOURCE_SCHEMA}")
    if value["source"] != ARTIFACT_FEED_SOURCE_VALUE:
        fail(f"{label}: source must be {ARTIFACT_FEED_SOURCE_VALUE}")
    validate_artifact_models(value["models"], label, allow_unmeasured_size=True)
    require_unique_artifact_hashes(value["models"], label)
    if candidate_obj is not None:
        require_primary_artifact_consistency(value["models"], candidate_obj, label)
    return value


def build_artifact_feed(source_obj: dict, candidate: bytes, candidate_obj: dict) -> bytes:
    """Materialise the published, release-bound artifact feed from the source."""
    value = {
        "candidate_catalog_sha256": sha256(candidate),
        "generated_at": candidate_obj["generated_at"],
        "models": source_obj["models"],
        "policy_version": candidate_obj["policy_version"],
        "release_id": candidate_obj["version"],
        "source": ARTIFACT_FEED_SOURCE_VALUE,
        "version": candidate_obj["version"],
    }
    feed = canonical_sorted_bytes(value)
    validate_artifact_feed(feed, candidate, candidate_obj)
    return feed


def validate_artifact_feed(
    data: bytes,
    candidate: bytes,
    candidate_obj: dict,
    label: str = "autotune-artifacts",
) -> dict:
    """Validate a published artifact feed against SPEC-023 §3.7.3-§3.7.5.

    Every failure here is `catalog_artifact_feed_integrity_failure` at generation:
    the release fails closed before signing and no artifact of the feed may be
    matched, priced, or settled.
    """
    value = strict_json(data, label)
    top = {
        "version", "generated_at", "policy_version", "source", "release_id",
        "candidate_catalog_sha256", "models",
    }
    exact_keys(value, top, top, label)
    if value["source"] != ARTIFACT_FEED_SOURCE_VALUE:
        fail(f"{label}: source must be {ARTIFACT_FEED_SOURCE_VALUE}")
    parse_time(value["generated_at"], label)
    for field in ("version", "release_id"):
        if value[field] != candidate_obj["version"]:
            fail(f"{label}: {field} must equal the candidate catalog version for this release")
    if value["generated_at"] != candidate_obj["generated_at"]:
        fail(f"{label}: generated_at must equal the candidate catalog generated_at")
    if value["policy_version"] != candidate_obj["policy_version"]:
        fail(f"{label}: policy_version must equal the candidate catalog policy_version")
    digest = value["candidate_catalog_sha256"]
    if not isinstance(digest, str) or not HEX64.fullmatch(digest):
        fail(f"{label}: candidate_catalog_sha256 must be lowercase 64-hex")
    if digest != sha256(candidate):
        fail(f"{label}: candidate_catalog_sha256 does not match the candidate catalog bytes")
    validate_artifact_models(value["models"], label, allow_unmeasured_size=False)
    require_unique_artifact_hashes(value["models"], label)
    require_primary_artifact_consistency(value["models"], candidate_obj, label)
    return value


def artifact_bindings(feed_obj: dict) -> list[dict]:
    """SPEC-023 §3.7.8 `artifact_bindings` wire shape.

    One element per published `(model_key, artifact_id)` pair regardless of
    `verification_status`, ordered ascending by `model_key` then `artifact_id`
    compared as UTF-8 bytes. The order is part of the wire shape, so two
    conforming generators fed one feed emit byte-identical bindings.
    """
    rows: list[dict] = []
    models = feed_obj["models"]
    for model_key in sorted(models, key=lambda key: key.encode("utf-8")):
        artifacts = models[model_key]["artifacts"]
        for artifact_id in sorted(artifacts, key=lambda key: key.encode("utf-8")):
            artifact = artifacts[artifact_id]
            rows.append({
                "artifact_id": artifact_id,
                "hash": artifact["hash"],
                "hash_algorithm": artifact["hash_algorithm"],
                "model_key": model_key,
            })
    return rows


def artifact_rate_classes(feed_obj: dict) -> dict[str, str]:
    return {
        model_key: entry["rate_class"]
        for model_key, entry in feed_obj["models"].items()
        if "rate_class" in entry
    }


def artifact_binding_history(
    releases: dict[str, dict],
    label: str = "release ledger",
) -> dict[tuple[str, str], tuple[str, str]]:
    """Reconstruct every `(model_key, artifact_id) -> (hash_algorithm, hash)`
    binding recorded across `releases`, which §3.7.8 makes the durable authority
    for the §3.7.4 cross-release rebinding check.

    Two rows recording one pair under two identities is itself a §3.7.4 violation
    — a retired `artifact_id` stays bound to its bytes forever — so this fails
    closed rather than letting a later row shadow an earlier one.
    """
    prior: dict[tuple[str, str], tuple[str, str]] = {}
    for release_id in sorted(releases):
        record = releases[release_id]
        if not isinstance(record, dict):
            continue
        for binding in record.get("artifact_bindings") or []:
            pair = (binding["model_key"], binding["artifact_id"])
            identity = (binding["hash_algorithm"], binding["hash"])
            existing = prior.get(pair)
            if existing is not None and existing != identity:
                fail(
                    f"{label}: artifact {pair[0]}/{pair[1]} is recorded with two "
                    f"different bindings across published releases "
                    f"({existing[0]}:{existing[1]} vs {identity[0]}:{identity[1]})"
                )
            prior[pair] = identity
    return prior


def require_artifact_signer_equality(
    artifact_signer: object,
    candidate_signer: object,
    label: str,
) -> None:
    """SPEC-023 §3.7.2: one release's artifact feed and candidate catalog MUST be
    signed by the SAME operator key.

    Keyring membership is not the test. During a rotation bridge more than one key
    is concurrently trusted, so two feeds can each carry a valid signature, each
    agree with its own `release.json` binding and its own ledger `signer_key_id`,
    and still bind an artifact identity authority to a catalog no single operator
    ever signed together. Every place that establishes artifact-feed authority —
    generating this release's manifest, validating any artifact-bound ledger row,
    and authenticating a previous release directory — routes through here so the
    equality is one rule with one error, not three near-copies.
    """
    if not isinstance(artifact_signer, str) or not artifact_signer:
        fail(f"{label}: the artifact feed must record a signer key ID")
    if not isinstance(candidate_signer, str) or not candidate_signer:
        fail(f"{label}: the candidate catalog must record a signer key ID")
    if artifact_signer != candidate_signer:
        fail(
            f"{label}: {ARTIFACT_FEED_NAME} signer {artifact_signer!r} must equal the "
            f"candidate-catalog signer {candidate_signer!r} for this release"
        )


def artifact_bound_row(record: object) -> bool:
    return (
        isinstance(record, dict)
        and isinstance(record.get("feeds"), dict)
        and set(record["feeds"]) == ARTIFACT_BOUND_LEDGER_FEEDS
    )


def release_history(ledger: dict[str, dict], current_release_id: str) -> dict[str, dict]:
    """Every recorded release EXCEPT the one being generated.

    Regenerating one release_id — the idempotent re-run `resign-autotune-static.sh`
    performs before and after replacing the sidecars — must not see that
    release's own freshly written ledger row as prior history, or the second
    generation would reject its own bindings as a rebinding and no artifact-bound
    release could ever be signed.
    """
    return {
        release_id: record
        for release_id, record in ledger["releases"].items()
        if release_id != current_release_id
    }


def release_order_key(release_id: str, record: dict, label: str = "release ledger") -> tuple[datetime, str]:
    """Chronological ordering key for one ledger row.

    The INSTANT first, `release_id` only as the deterministic tie-breaker. Raw
    `generated_at` strings must never be compared: `2026-09-20T00:00:00Z` and
    `2026-09-19T23:00:00-02:00` are one hour apart in the other direction from
    their lexical order, and a fractional-second spelling reorders again. Getting
    this wrong picks the wrong "previous release" — the authority the §3.7.4
    rebinding check and the §3.7.8 intake-transition comparison both read from.
    """
    return parse_timestamp(record["generated_at"], f"{label} release {release_id}"), release_id


def latest_artifact_bound_release(releases: dict[str, dict]) -> tuple[str, dict] | None:
    """The most recently generated artifact-bound row in `releases`.

    Ordered chronologically by `generated_at` then `release_id`; because §3.7.8
    forbids reverting to a smaller feed set, this is also "the previous release"
    whenever any row is artifact-bound.
    """
    rows = [
        (release_order_key(release_id, record), release_id, record)
        for release_id, record in releases.items()
        if artifact_bound_row(record)
    ]
    if not rows:
        return None
    _, release_id, record = max(rows, key=lambda row: row[0])
    return release_id, record


def load_previous_release(
    directory: pathlib.Path,
    releases: dict[str, dict],
    keys: dict[str, bytes] | None = None,
) -> dict:
    """Authenticate the previous artifact-bound release DIRECTORY (§3.7.4 input).

    The rebinding check's prior-binding authority has to be a named, signed
    release, not raw JSON bytes an operator points at: unauthenticated previous
    feed bytes prove nothing about which release they came from, and the ledger
    row alone does not prove the operator is comparing against the right one.

    This verifies the directory's `release.json`, every static feed's digest and
    length against it, and every detached Ed25519 signature under the repo's
    TRUSTED keyring; requires each sidecar's signer to equal the signer
    `release.json` binds; requires the directory to be the release the ledger
    records as the latest artifact-bound one, with `release.json` feed bindings
    equal to that row's (which carries the per-feed versions the ledger validator
    already checked); and requires its published artifact bindings to equal that
    row's `artifact_bindings` EXACTLY — no missing pair, no extra pair, no
    differing identity.
    """
    expected = latest_artifact_bound_release(releases)
    if expected is None:
        fail(
            "--previous-release-dir was supplied but the release ledger records no "
            "earlier artifact-bound release to compare against"
        )
    expected_release_id, record = expected
    manifest_path = directory / "release.json"
    if not manifest_path.exists():
        fail(f"--previous-release-dir {directory}: missing release.json")
    previous_manifest = strict_json(manifest_path.read_bytes(), "previous release.json")
    if previous_manifest.get("release_id") != expected_release_id:
        fail(
            f"--previous-release-dir {directory}: binds release "
            f"{previous_manifest.get('release_id')!r}, but the ledger's latest artifact-bound "
            f"release is {expected_release_id!r}"
        )
    feeds = previous_manifest.get("feeds")
    if not isinstance(feeds, dict) or set(feeds) != ARTIFACT_BOUND_LEDGER_FEEDS:
        fail(
            f"--previous-release-dir {directory}: release.json must bind the artifact-bound "
            f"five-feed set {sorted(ARTIFACT_BOUND_LEDGER_FEEDS)}"
        )
    if feeds != record["feeds"]:
        fail(
            f"--previous-release-dir {directory}: release.json feed bindings do not equal the "
            f"release-ledger row for {expected_release_id!r}"
        )
    keys = keyring() if keys is None else keys
    bodies: dict[str, bytes] = {}
    authenticated_signers: dict[str, str] = {}
    signed_names = ("autotune-candidates.json", "demand-rank.json", RATE_CARD_FEED_NAME, ARTIFACT_FEED_NAME)
    for name in signed_names:
        path = directory / name
        if not path.exists():
            fail(f"--previous-release-dir {directory}: missing {name}")
        body = path.read_bytes()
        binding = feeds[name]
        if sha256(body) != binding["sha256"] or len(body) != binding["bytes"]:
            fail(f"--previous-release-dir {directory}: {name} does not match its release.json binding")
        sidecar_path = directory / f"{name}.sig"
        if not sidecar_path.exists():
            fail(f"--previous-release-dir {directory}: missing {name}.sig")
        key_id, signature = parse_sidecar(sidecar_path.read_bytes(), sidecar_path.name)
        if key_id != binding["signer_key_id"]:
            fail(
                f"--previous-release-dir {directory}: {name}.sig is signed by {key_id!r}, not the "
                f"{binding['signer_key_id']!r} release.json binds"
            )
        public_key = keys.get(key_id)
        if public_key is None:
            fail(f"--previous-release-dir {directory}: {name}.sig key_id {key_id!r} is not trusted")
        verify_ed25519(public_key, signature, body, f"previous {name}.sig")
        bodies[name] = body
        authenticated_signers[name] = key_id
    # §3.7.2 equality over the AUTHENTICATED signers, not the recorded ones. Every
    # check above is per-feed: a directory whose artifact feed and candidate
    # catalog were signed by two different concurrently trusted keys satisfies all
    # of them and would otherwise become rebinding authority.
    require_artifact_signer_equality(
        authenticated_signers[ARTIFACT_FEED_NAME],
        authenticated_signers["autotune-candidates.json"],
        f"--previous-release-dir {directory}",
    )
    previous_candidate_obj = validate_candidate(bodies["autotune-candidates.json"])
    previous_feed_obj = validate_artifact_feed(
        bodies[ARTIFACT_FEED_NAME],
        bodies["autotune-candidates.json"],
        previous_candidate_obj,
        label="previous autotune-artifacts",
    )
    if artifact_bindings(previous_feed_obj) != record["artifact_bindings"]:
        fail(
            f"--previous-release-dir {directory}: the signed artifact feed's bindings do not "
            f"equal the release-ledger artifact_bindings for {expected_release_id!r}"
        )
    return {
        "release_id": expected_release_id,
        "feed_obj": previous_feed_obj,
        "candidate_obj": previous_candidate_obj,
        "record": record,
    }


def require_no_artifact_rebinding(
    feed_obj: dict,
    history: dict[str, dict],
    previous_release: dict | None,
) -> None:
    """SPEC-023 §3.7.4 / AC-CAT-19: an `artifact_id` MUST NOT be rebound to
    different bytes, within or across releases.

    The prior-binding authority is the release ledger's history (every row EXCEPT
    the release being generated) plus the previous release's authenticated signed
    artifact feed, so the verdict is reconstructible from named release inputs.
    For the FIRST artifact-bound release there is no previous release and no
    recorded binding: every binding is new and the check passes vacuously. Once
    an EARLIER release has been recorded with the artifact-bound feed set, the
    previous signed release directory becomes a REQUIRED generator input.
    """
    prior = artifact_binding_history(history)
    if previous_release is not None:
        for binding in artifact_bindings(previous_release["feed_obj"]):
            pair = (binding["model_key"], binding["artifact_id"])
            identity = (binding["hash_algorithm"], binding["hash"])
            existing = prior.get(pair)
            if existing is not None and existing != identity:
                fail(
                    f"previous autotune-artifacts: artifact {pair[0]}/{pair[1]} disagrees with "
                    "the binding the release ledger records for it"
                )
            prior[pair] = identity
    elif prior:
        fail(
            "generate: --previous-release-dir is required once an earlier release has been "
            "recorded with the artifact-bound feed set; the previous release's signed "
            "directory is a named input to the rebinding check"
        )
    for binding in artifact_bindings(feed_obj):
        pair = (binding["model_key"], binding["artifact_id"])
        identity = (binding["hash_algorithm"], binding["hash"])
        existing = prior.get(pair)
        if existing is not None and existing != identity:
            fail(
                f"autotune-artifacts: artifact_id {pair[1]!r} of model {pair[0]!r} is rebound "
                f"from {existing[0]}:{existing[1]} to {identity[0]}:{identity[1]}; publish new "
                "bytes under a NEW artifact_id and retire the old id as blocked"
            )


def manifest(
    candidate: bytes,
    demand: bytes,
    rate_card: bytes,
    candidate_obj: dict,
    demand_obj: dict,
    rate_card_obj: dict,
    sidecar_directory: pathlib.Path = STATIC_DIR,
    signer_key_id: str | None = None,
    tier2: bytes | None = None,
    tier2_obj: dict | None = None,
    tier2_signer_key_id: str | None = None,
    artifacts: bytes | None = None,
    artifact_obj: dict | None = None,
) -> bytes:
    validate_release_inputs(candidate_obj, demand_obj, rate_card_obj)
    static_feed_names = ["autotune-candidates.json", "demand-rank.json", RATE_CARD_FEED_NAME]
    if artifacts is not None:
        static_feed_names.append(ARTIFACT_FEED_NAME)
    signer_ids = {}
    if signer_key_id is not None:
        signer_ids = {name: signer_key_id for name in static_feed_names}
    else:
        for name in static_feed_names:
            sidecar_path = sidecar_directory / f"{name}.sig"
            if sidecar_path.exists():
                signer_ids[name] = parse_sidecar(sidecar_path.read_bytes(), sidecar_path.name)[0]
    if artifacts is not None:
        # SPEC-023 §3.7.2 signer-identity equality is a CHECKED equality, not an
        # assumption (AC-CAT-1).
        artifact_signer = signer_ids.get(ARTIFACT_FEED_NAME)
        candidate_signer = signer_ids.get("autotune-candidates.json")
        if artifact_signer is None or candidate_signer is None:
            fail("manifest: the artifact feed and the candidate catalog must both be signed before binding")
        require_artifact_signer_equality(artifact_signer, candidate_signer, "manifest")
    feeds = {
        "autotune-candidates.json": {
            "sha256": sha256(candidate), "bytes": len(candidate), "version": candidate_obj["version"],
            "signer_key_id": signer_ids.get("autotune-candidates.json"),
        },
        "demand-rank.json": {
            "sha256": sha256(demand), "bytes": len(demand), "version": demand_obj["version"],
            "signer_key_id": signer_ids.get("demand-rank.json"),
        },
        RATE_CARD_FEED_NAME: {
            "sha256": sha256(rate_card), "bytes": len(rate_card), "version": rate_card_obj["version"],
            "signer_key_id": signer_ids.get(RATE_CARD_FEED_NAME),
        },
    }
    if tier2 is not None:
        if tier2_obj is None:
            fail("manifest: tier2 bytes provided without a parsed tier2_obj")
        if not tier2_signer_key_id:
            fail("manifest: tier2 bytes provided without an authenticated tier2_signer_key_id")
        # Tier-2 is versioned by its own catalog_id, not the autotune release
        # train, so it is bound as a feed member without claiming release_id
        # identity (#608 Partial: ledger feed membership). `signer_key_id`
        # comes from the caller's authentication result (verify_tier2_signature),
        # NOT from tier2_obj["signature"]["key_id"]: that field is metadata
        # alongside the signature, not part of the signed canonical body in
        # sign-catalog.go, so it is not itself authenticated (#608 audit).
        feeds[TIER2_CATALOG_FEED_NAME] = {
            "sha256": sha256(tier2), "bytes": len(tier2), "version": tier2_obj["catalog_id"],
            "signer_key_id": tier2_signer_key_id,
        }
    if artifacts is not None:
        if artifact_obj is None:
            fail("manifest: artifact feed bytes provided without a parsed artifact_obj")
        # Release-train versioned like the candidate and demand feeds (§3.7.8).
        feeds[ARTIFACT_FEED_NAME] = {
            "sha256": sha256(artifacts), "bytes": len(artifacts), "version": artifact_obj["version"],
            "signer_key_id": signer_ids.get(ARTIFACT_FEED_NAME),
        }
    value = {
        "schema_version": "macprovider.autotune-release.v1",
        "release_id": candidate_obj["version"],
        "generated_at": candidate_obj["generated_at"],
        "policy_version": candidate_obj["policy_version"],
        "feeds": feeds,
    }
    return json.dumps(value, indent=2, sort_keys=True).encode("utf-8") + b"\n"


def release_record(
    manifest_bytes: bytes,
    bindings: list[dict] | None = None,
    intake_decision_sha256: str | None = None,
) -> tuple[str, dict]:
    value = strict_json(manifest_bytes, "release manifest")
    exact_keys(
        value,
        {"schema_version", "release_id", "generated_at", "policy_version", "feeds"},
        {"schema_version", "release_id", "generated_at", "policy_version", "feeds"},
        "release manifest",
    )
    if value["schema_version"] != "macprovider.autotune-release.v1":
        fail("release manifest: unsupported schema_version")
    release_id = value["release_id"]
    if not isinstance(release_id, str) or not release_id:
        fail("release manifest: release_id required")
    record = {
        "generated_at": value["generated_at"],
        "policy_version": value["policy_version"],
        "feeds": value["feeds"],
    }
    artifact_bound = set(value["feeds"]) == ARTIFACT_BOUND_LEDGER_FEEDS
    if artifact_bound != (bindings is not None):
        fail(
            "release manifest: artifact_bindings are REQUIRED exactly when the release "
            "binds the artifact-bound five-feed set"
        )
    if artifact_bound:
        # SPEC-023 §3.7.8: a v3 artifact-bound row is the exact closed set
        # {generated_at, policy_version, feeds, artifact_bindings, intake_decision_sha256}.
        record["artifact_bindings"] = bindings
        record["intake_decision_sha256"] = intake_decision_sha256
    return release_id, record


def validate_artifact_binding_rows(bindings: object, label: str) -> None:
    """SPEC-023 §3.7.8 / AC-CAT-19: the concrete `artifact_bindings` wire shape."""
    if not isinstance(bindings, list) or not bindings:
        fail(f"{label}: artifact_bindings must be a non-empty array")
    fields = {"model_key", "artifact_id", "hash_algorithm", "hash"}
    seen_pairs: set[tuple[str, str]] = set()
    seen_hashes: set[tuple[str, str]] = set()
    previous: tuple[bytes, bytes] | None = None
    algorithms = {algorithm for algorithm, _, _ in ARTIFACT_IDENTITY_MATRIX.values()}
    for index, binding in enumerate(bindings):
        entry_label = f"{label} artifact_bindings[{index}]"
        if not isinstance(binding, dict):
            fail(f"{entry_label}: must be an object")
        exact_keys(binding, fields, fields, entry_label)
        if not all(isinstance(binding[field], str) for field in fields):
            fail(f"{entry_label}: every value must be a string")
        if not MODEL_KEY.fullmatch(binding["model_key"]) or "//" in binding["model_key"]:
            fail(f"{entry_label}: invalid model_key")
        if not ARTIFACT_ID.fullmatch(binding["artifact_id"]):
            fail(f"{entry_label}: artifact_id does not match ^[a-z0-9][a-z0-9-]{{0,63}}$")
        if binding["hash_algorithm"] not in algorithms:
            fail(f"{entry_label}: hash_algorithm is not a SPEC-023 §3.7.4 matrix algorithm")
        if not HEX64.fullmatch(binding["hash"]):
            fail(f"{entry_label}: hash must be lowercase 64-hex")
        pair = (binding["model_key"], binding["artifact_id"])
        if pair in seen_pairs:
            fail(f"{entry_label}: duplicate (model_key, artifact_id)")
        seen_pairs.add(pair)
        identity = (binding["hash_algorithm"], binding["hash"])
        if identity in seen_hashes:
            fail(f"{entry_label}: duplicate (hash_algorithm, hash)")
        seen_hashes.add(identity)
        ordering = (binding["model_key"].encode("utf-8"), binding["artifact_id"].encode("utf-8"))
        if previous is not None and ordering <= previous:
            fail(f"{entry_label}: artifact_bindings must ascend by model_key then artifact_id (UTF-8 bytes)")
        previous = ordering


def validate_ledger_feed(feed: object, label: str) -> None:
    if not isinstance(feed, dict):
        fail(f"{label}: feed binding must be an object")
    fields = {"bytes", "sha256", "signer_key_id", "version"}
    exact_keys(feed, fields, fields, label)
    if (
        not isinstance(feed["bytes"], int)
        or isinstance(feed["bytes"], bool)
        or feed["bytes"] <= 0
        or not isinstance(feed["sha256"], str)
        or not HEX64.fullmatch(feed["sha256"])
        or not isinstance(feed["signer_key_id"], str)
        or not feed["signer_key_id"]
        or not isinstance(feed["version"], str)
        or not feed["version"]
    ):
        fail(f"{label}: invalid feed binding")


def validate_release_ledger(data: bytes, label: str = "release ledger") -> dict[str, dict]:
    value = strict_json(data, label)
    schema_version = value.get("schema_version")
    if schema_version == "macprovider.autotune-release-ledger.v1":
        exact_keys(value, {"schema_version", "releases"}, {"schema_version", "releases"}, label)
        value = {"releases": value["releases"], "tombstones": {}}
    elif schema_version in (LEDGER_SCHEMA_V2, LEDGER_SCHEMA_V3):
        exact_keys(value, {"schema_version", "releases", "tombstones"}, {"schema_version", "releases", "tombstones"}, label)
    else:
        fail(f"{label}: invalid schema")
    document_schema = LEDGER_SCHEMA_V3 if schema_version == LEDGER_SCHEMA_V3 else LEDGER_SCHEMA_V2
    if not isinstance(value["releases"], dict) or not isinstance(value["tombstones"], dict):
        fail(f"{label}: releases and tombstones must be objects")
    overlapping_release_ids = set(value["releases"]).intersection(value["tombstones"])
    if overlapping_release_ids:
        release_id = sorted(overlapping_release_ids)[0]
        fail(f"{label}: release ID {release_id!r} cannot be both published and tombstoned")
    for release_id, record in value["releases"].items():
        if not isinstance(release_id, str) or not release_id or not isinstance(record, dict):
            fail(f"{label}: invalid release entry {release_id!r}")
        base_row_fields = {"generated_at", "policy_version", "feeds"}
        artifact_row_fields = base_row_fields | {"artifact_bindings", "intake_decision_sha256"}
        # SPEC-023 §3.7.8: within one v3 document, artifact_bindings and
        # intake_decision_sha256 are REQUIRED exactly when the row's feed-name set
        # is the artifact-bound five-feed set, and PROHIBITED otherwise. A row
        # written under v1 or v2 keeps its exact three-key shape forever.
        artifact_bound = isinstance(record.get("feeds"), dict) and set(record["feeds"]) == ARTIFACT_BOUND_LEDGER_FEEDS
        row_fields = artifact_row_fields if artifact_bound else base_row_fields
        exact_keys(record, row_fields, row_fields, f"{label} release {release_id}")
        if artifact_bound and document_schema != LEDGER_SCHEMA_V3:
            fail(
                f"{label}: release {release_id!r} binds the artifact-bound feed set but the "
                f"ledger is serialized as {document_schema}; it must be {LEDGER_SCHEMA_V3}"
            )
        if not isinstance(record["generated_at"], str) or (record["policy_version"] is not None and not isinstance(record["policy_version"], str)) or not isinstance(record["feeds"], dict):
            fail(f"{label}: invalid release entry {release_id!r}")
        parse_time(record["generated_at"], f"{label} release {release_id}")
        feed_names = set(record["feeds"])
        # Historical-safe: old releases keep their original 2-feed or
        # Tier-2-bound 3-feed shape. Current releases bind the signed
        # rate-card feed as the fourth immutable SPEC-023 input, and
        # artifact-bound releases add autotune-artifacts.json as the fifth.
        if feed_names not in (LEGACY_LEDGER_FEEDS, TIER2_BOUND_LEDGER_FEEDS, RATE_CARD_BOUND_LEDGER_FEEDS, ARTIFACT_BOUND_LEDGER_FEEDS):
            fail(
                f"{label}: release {release_id!r} feeds must be exactly "
                f"{sorted(LEGACY_LEDGER_FEEDS)} (historical) or "
                f"{sorted(TIER2_BOUND_LEDGER_FEEDS)} (Tier-2 bound) or "
                f"{sorted(RATE_CARD_BOUND_LEDGER_FEEDS)} (rate-card bound) or "
                f"{sorted(ARTIFACT_BOUND_LEDGER_FEEDS)} (artifact bound)"
            )
        if artifact_bound:
            validate_artifact_binding_rows(record["artifact_bindings"], f"{label} release {release_id}")
            intake_digest = record["intake_decision_sha256"]
            if intake_digest is not None and (not isinstance(intake_digest, str) or not HEX64.fullmatch(intake_digest)):
                fail(f"{label}: release {release_id!r} intake_decision_sha256 must be lowercase 64-hex or null")
        for feed_name, feed in record["feeds"].items():
            validate_ledger_feed(feed, f"{label} release {release_id} {feed_name}")
            # tier2-catalog.json and rate-card.json are versioned by their own
            # content identities, not the autotune release train (see manifest()).
            if feed_name not in {TIER2_CATALOG_FEED_NAME, RATE_CARD_FEED_NAME} and feed["version"] != release_id:
                fail(f"{label}: feed version does not match release ID {release_id!r}")
        if artifact_bound:
            # After validate_ledger_feed, so both signer IDs are known-good strings.
            require_artifact_signer_equality(
                record["feeds"][ARTIFACT_FEED_NAME]["signer_key_id"],
                record["feeds"]["autotune-candidates.json"]["signer_key_id"],
                f"{label} release {release_id}",
            )
    # SPEC-023 §3.7.4 across the WHOLE document, not only within one row: an
    # `artifact_id` may not be rebound to different bytes in a later release
    # either. Enforced here, in the shared ledger validator, so `verify` rejects a
    # hand-assembled and correctly signed release that reuses a
    # `(model_key, artifact_id)` under a new identity — generation is not the only
    # path a ledger reaches the release host by.
    artifact_binding_history(value["releases"], label)
    for release_id, tombstone in value["tombstones"].items():
        if not isinstance(release_id, str) or not release_id or not isinstance(tombstone, dict):
            fail(f"{label}: invalid tombstone entry {release_id!r}")
        exact_keys(
            tombstone,
            {"status", "reason", "observed_bindings"},
            {"status", "reason", "observed_bindings"},
            f"{label} tombstone {release_id}",
        )
        bindings = tombstone["observed_bindings"]
        if tombstone["status"] != "permanently_rejected" or tombstone["reason"] != "historical_release_id_rebound" or not isinstance(bindings, list) or len(bindings) < 2:
            fail(f"{label}: invalid tombstone entry {release_id!r}")
        seen = set()
        binding_fields = {"candidate_bytes", "candidate_sha256", "demand_bytes", "demand_sha256", "generated_at", "signer_key_id"}
        for index, binding in enumerate(bindings):
            if not isinstance(binding, dict):
                fail(f"{label}: invalid tombstone binding {release_id!r}")
            exact_keys(binding, binding_fields, binding_fields, f"{label} tombstone {release_id} binding {index}")
            parse_time(binding["generated_at"], f"{label} tombstone {release_id} binding {index}")
            if (
                not isinstance(binding["candidate_bytes"], int)
                or isinstance(binding["candidate_bytes"], bool)
                or binding["candidate_bytes"] <= 0
                or not isinstance(binding["demand_bytes"], int)
                or isinstance(binding["demand_bytes"], bool)
                or binding["demand_bytes"] <= 0
                or not isinstance(binding["candidate_sha256"], str)
                or not HEX64.fullmatch(binding["candidate_sha256"])
                or not isinstance(binding["demand_sha256"], str)
                or not HEX64.fullmatch(binding["demand_sha256"])
                or not isinstance(binding["signer_key_id"], str)
                or not binding["signer_key_id"]
            ):
                fail(f"{label}: invalid tombstone binding {release_id!r}")
            identity = (binding["candidate_sha256"], binding["demand_sha256"], binding["signer_key_id"])
            if identity in seen:
                fail(f"{label}: duplicate tombstone binding {release_id!r}")
            seen.add(identity)
    return {
        "schema_version": document_schema,
        "releases": value["releases"],
        "tombstones": value["tombstones"],
    }


def empty_release_ledger() -> dict:
    return {"schema_version": LEDGER_SCHEMA_V2, "releases": {}, "tombstones": {}}


def ledger_bytes(ledger: dict) -> bytes:
    value = {
        "schema_version": ledger.get("schema_version", LEDGER_SCHEMA_V2),
        "releases": ledger["releases"],
        "tombstones": ledger["tombstones"],
    }
    return json.dumps(value, indent=2, sort_keys=True).encode("utf-8") + b"\n"


def generated_rejected_releases_go(ledger: dict[str, dict]) -> str:
    entries = "\n".join(
        f"\t{json.dumps(release_id)}: {{}},"
        for release_id in sorted(ledger["tombstones"])
    )
    if entries:
        entries += "\n"
    return (
        "// Generated by scripts/catalog-release.py. DO NOT EDIT.\n"
        "package autotune\n\n"
        "var permanentlyRejectedReleaseIDs = map[string]struct{}{\n"
        f"{entries}"
        "}\n\n"
        "func IsPermanentlyRejectedReleaseID(releaseID string) bool {\n"
        "\t_, rejected := permanentlyRejectedReleaseIDs[releaseID]\n"
        "\treturn rejected\n"
        "}\n"
    )


def is_tier2_enrichment(base_record: dict, current_record: dict) -> bool:
    """Return true only for the one-way #608 legacy 2-feed -> Tier-2-bound shape.

    Existing current releases may be enriched with authenticated Tier-2 bytes
    without re-signing the unchanged autotune/demand feed bytes. No other
    rebinding is allowed: the two historical feed records, generated_at, and
    policy_version must be byte-for-byte identical.
    """
    if base_record.get("generated_at") != current_record.get("generated_at"):
        return False
    if base_record.get("policy_version") != current_record.get("policy_version"):
        return False
    base_feeds = base_record.get("feeds")
    current_feeds = current_record.get("feeds")
    if not isinstance(base_feeds, dict) or not isinstance(current_feeds, dict):
        return False
    if set(base_feeds) != LEGACY_LEDGER_FEEDS or set(current_feeds) != TIER2_BOUND_LEDGER_FEEDS:
        return False
    for feed_name in LEGACY_LEDGER_FEEDS:
        if current_feeds.get(feed_name) != base_feeds.get(feed_name):
            return False
    return True


def is_rate_card_enrichment(base_record: dict, current_record: dict) -> bool:
    """Return true only for one-way Tier-2-bound -> rate-card-bound enrichment."""
    if base_record.get("generated_at") != current_record.get("generated_at"):
        return False
    if base_record.get("policy_version") != current_record.get("policy_version"):
        return False
    base_feeds = base_record.get("feeds")
    current_feeds = current_record.get("feeds")
    if not isinstance(base_feeds, dict) or not isinstance(current_feeds, dict):
        return False
    if set(base_feeds) != TIER2_BOUND_LEDGER_FEEDS or set(current_feeds) != RATE_CARD_BOUND_LEDGER_FEEDS:
        return False
    for feed_name in TIER2_BOUND_LEDGER_FEEDS:
        if current_feeds.get(feed_name) != base_feeds.get(feed_name):
            return False
    return True


def require_ledger_evolution(base: dict, current: dict) -> None:
    # SPEC-023 §3.7.8 activation: once a release is published with the
    # artifact-bound feed set the ledger is serialized as v3 forever, and every
    # NEW release row must itself be artifact-bound. A later ledger serialized as
    # v2, or a later release recorded without artifact_bindings, is a downgrade.
    if base.get("schema_version") == LEDGER_SCHEMA_V3 and current.get("schema_version") != LEDGER_SCHEMA_V3:
        fail(
            "release ledger: an artifact-bound ledger may not be downgraded from "
            f"{LEDGER_SCHEMA_V3} to {current.get('schema_version')}"
        )
    # Monotonicity over the COMPLETE current ledger in chronological order, not
    # only over rows the base already had: a single delta can introduce BOTH the
    # first artifact-bound activation row and a later four-feed row, and a
    # base-only verdict says "not activated yet" for both. Once any row is
    # artifact-bound, every chronologically later row must be too.
    ordered = sorted(
        current["releases"].items(),
        key=lambda item: release_order_key(item[0], item[1], "release ledger"),
    )
    seen_activation: str | None = None
    for release_id, record in ordered:
        if artifact_bound_row(record):
            if seen_activation is None:
                seen_activation = release_id
            continue
        if seen_activation is not None:
            fail(
                f"release ledger: release {release_id!r} reverts to "
                f"{sorted(set(record.get('feeds', {})))} after the artifact-bound activation "
                f"release {seen_activation!r}; {sorted(ARTIFACT_BOUND_LEDGER_FEEDS)} is "
                "mandatory from that release forward"
            )
    activated = any(
        set(record.get("feeds", {})) == ARTIFACT_BOUND_LEDGER_FEEDS
        for record in base["releases"].values()
    )
    for release_id, base_record in base["releases"].items():
        if release_id not in current["releases"]:
            fail(f"release ledger: published release {release_id!r} was removed")
        if (
            current["releases"][release_id] != base_record
            and not is_tier2_enrichment(base_record, current["releases"][release_id])
            and not is_rate_card_enrichment(base_record, current["releases"][release_id])
        ):
            fail(f"release ledger: published release {release_id!r} was rebound to different content")
    for release_id, base_tombstone in base["tombstones"].items():
        if release_id not in current["tombstones"]:
            fail(f"release ledger: tombstone {release_id!r} was removed")
        if current["tombstones"][release_id] != base_tombstone:
            fail(f"release ledger: tombstone {release_id!r} was changed")
    for release_id, current_record in current["releases"].items():
        if release_id in base["releases"]:
            continue
        feed_names = set(current_record["feeds"])
        if activated and feed_names != ARTIFACT_BOUND_LEDGER_FEEDS:
            fail(
                f"release ledger: new release {release_id!r} reverts to "
                f"{sorted(feed_names)} after the artifact-bound activation release; "
                f"{sorted(ARTIFACT_BOUND_LEDGER_FEEDS)} is mandatory from that release forward"
            )
        if feed_names not in (RATE_CARD_BOUND_LEDGER_FEEDS, ARTIFACT_BOUND_LEDGER_FEEDS):
            fail(
                f"release ledger: new release {release_id!r} is missing mandatory "
                f"{sorted(RATE_CARD_BOUND_LEDGER_FEEDS)} feed membership"
            )


def base_release_ledger() -> dict[str, dict]:
    base_ref = os.environ.get("CATALOG_RELEASE_BASE_REF", "origin/main")
    relative_path = LEDGER_PATH.relative_to(ROOT).as_posix()
    resolve = subprocess.run(
        ["git", "rev-parse", "--verify", f"{base_ref}^{{commit}}"],
        cwd=ROOT,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if resolve.returncode != 0:
        fail(f"release ledger base ref is unavailable: {base_ref}")
    probe = subprocess.run(
        ["git", "cat-file", "-e", f"{base_ref}:{relative_path}"],
        cwd=ROOT,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if probe.returncode != 0:
        return empty_release_ledger()
    result = subprocess.run(
        ["git", "show", f"{base_ref}:{relative_path}"],
        cwd=ROOT,
        check=True,
        capture_output=True,
    )
    return validate_release_ledger(result.stdout, f"release ledger at {base_ref}")


def highest_claimed_autotune_rows(candidate_obj: dict) -> dict[str, tuple[str, dict]]:
    """Return model_id(lower) -> (catalog_key, row) matching Go HighestClaimedTier."""
    rows = candidate_obj["rows"]
    by_model: dict[str, list[tuple[str, dict]]] = {}
    for key, row in rows.items():
        normalized = row["model_id"].lower().strip()
        by_model.setdefault(normalized, []).append((key, row))
    best: dict[str, tuple[str, dict]] = {}
    for normalized, entries in by_model.items():
        # Go checks rowsByKey[normalizedModelID] first, even when that key's
        # row declares a different model_id. validate_candidate rejects that
        # shadowing shape, so the direct hit here is always consistent.
        if normalized in rows:
            best[normalized] = (normalized, rows[normalized])
            continue
        best_key, best_row = entries[0]
        for key, row in entries[1:]:
            if row["min_ram_gb"] > best_row["min_ram_gb"] or (
                row["min_ram_gb"] == best_row["min_ram_gb"] and key < best_key
            ):
                best_key, best_row = key, row
        best[normalized] = (best_key, best_row)
    return best


def derive_tier2_identity_binding(candidate: bytes, candidate_obj: dict) -> bytes:
    """Deterministic unsigned Tier-2 identity rows derived from autotune (#608)."""
    models = []
    for normalized, (key, row) in sorted(highest_claimed_autotune_rows(candidate_obj).items()):
        artifact_hash = row.get("model_sha256")
        if not isinstance(artifact_hash, str) or not artifact_hash:
            continue
        entry = {
            "catalog_key": key,
            "min_ram_gb": row["min_ram_gb"],
            "model_id": row["model_id"],
            "model_revision": row.get("model_revision"),
            "sha256": artifact_hash,
        }
        models.append(entry)
    if not models:
        fail("tier2 identity binding: no autotune rows with model_sha256")
    # Detect conflicting hashes under the same model_id across autotune keys.
    by_model: dict[str, str] = {}
    for key, row in candidate_obj["rows"].items():
        artifact_hash = row.get("model_sha256")
        if not isinstance(artifact_hash, str) or not artifact_hash:
            continue
        normalized = row["model_id"].lower().strip()
        prior = by_model.get(normalized)
        if prior is not None and prior != artifact_hash:
            fail(
                f"tier2 identity binding: autotune model_id {row['model_id']!r} "
                f"has conflicting model_sha256 values across catalog keys"
            )
        by_model[normalized] = artifact_hash
    binding = {
        "schema_version": TIER2_BINDING_SCHEMA,
        "release_id": candidate_obj["version"],
        "generated_at": candidate_obj["generated_at"],
        "policy_version": candidate_obj["policy_version"],
        "autotune_candidates_sha256": sha256(candidate),
        "models": models,
    }
    return json.dumps(binding, indent=2, sort_keys=True).encode("utf-8") + b"\n"


def validate_tier2_identity_binding(data: bytes, candidate: bytes, candidate_obj: dict) -> dict:
    value = strict_json(data, "tier2 identity binding")
    exact_keys(
        value,
        {
            "schema_version",
            "release_id",
            "generated_at",
            "policy_version",
            "autotune_candidates_sha256",
            "models",
        },
        {
            "schema_version",
            "release_id",
            "generated_at",
            "policy_version",
            "autotune_candidates_sha256",
            "models",
        },
        "tier2 identity binding",
    )
    if value["schema_version"] != TIER2_BINDING_SCHEMA:
        fail("tier2 identity binding: unsupported schema_version")
    if value["release_id"] != candidate_obj["version"]:
        fail("tier2 identity binding: release_id does not match autotune release")
    if value["generated_at"] != candidate_obj["generated_at"]:
        fail("tier2 identity binding: generated_at does not match autotune release")
    if value["policy_version"] != candidate_obj["policy_version"]:
        fail("tier2 identity binding: policy_version does not match autotune release")
    if value["autotune_candidates_sha256"] != sha256(candidate):
        fail("tier2 identity binding: autotune_candidates_sha256 drift")
    if data != derive_tier2_identity_binding(candidate, candidate_obj):
        fail("tier2 identity binding: generated drift from autotune candidates")
    return value


def validate_tier2_catalog(data: bytes) -> dict:
    """Structural validation of a signed Tier-2 catalog (scripts/sign-catalog.go shape).

    This locks the JSON shape (fields, hash format, signature envelope) so
    `generate`/`verify` can safely record `signer_key_id` + digest as a
    release-ledger feed member (#608 Partial: ledger feed membership).
    It does not authenticate the Ed25519 signature bytes —
    every caller that trusts the catalog as "signed" (`generate`, `verify`,
    `verify_directory`) MUST also call `verify_tier2_signature` on the same
    bytes before recording `signer_key_id` anywhere. Cross-catalog identity
    agreement is enforced separately by `check_tier2_binding`.
    """
    value = strict_json(data, "tier2-catalog")
    top = {"catalog_id", "issued_at", "expires_at", "models", "signature", "version"}
    exact_keys(value, top, top, "tier2-catalog")
    if not isinstance(value["catalog_id"], str) or not value["catalog_id"].strip():
        fail("tier2-catalog: catalog_id required")
    parse_time(value["issued_at"], "tier2-catalog issued_at")
    parse_time(value["expires_at"], "tier2-catalog expires_at")
    issued = datetime.fromisoformat(value["issued_at"].replace("Z", "+00:00"))
    expires = datetime.fromisoformat(value["expires_at"].replace("Z", "+00:00"))
    if issued >= expires:
        fail("tier2-catalog: issued_at must be before expires_at")
    if datetime.now(timezone.utc) >= expires:
        fail("tier2-catalog: expires_at must be in the future (catalog has expired)")
    version = value["version"]
    if not isinstance(version, int) or isinstance(version, bool) or version != 1:
        fail("tier2-catalog: version must be 1")
    models = value["models"]
    if not isinstance(models, list) or not models:
        fail("tier2-catalog: models required")
    seen_models: set[str] = set()
    model_fields = {"artifact_kind", "hash_scope", "model_id", "min_ram_gb", "notes", "sha256", "source"}
    model_required = {"artifact_kind", "hash_scope", "model_id", "sha256", "source"}
    for idx, entry in enumerate(models):
        if not isinstance(entry, dict):
            fail(f"tier2-catalog: models[{idx}] must be an object")
        exact_keys(entry, model_fields, model_required, f"tier2-catalog models[{idx}]")
        if entry["artifact_kind"] != "mlx_weight_file":
            fail(f"tier2-catalog models[{idx}]: unsupported artifact_kind")
        if not isinstance(entry["hash_scope"], str) or entry["hash_scope"] not in TIER2_HASH_SCOPES:
            fail(f"tier2-catalog models[{idx}]: unsupported hash_scope")
        model_id = entry["model_id"]
        if not isinstance(model_id, str) or not model_id.strip():
            fail(f"tier2-catalog models[{idx}]: model_id required")
        normalized = model_id.lower().strip()
        if normalized in seen_models:
            fail(f"tier2-catalog models[{idx}]: duplicate model_id {model_id!r}")
        seen_models.add(normalized)
        if not isinstance(entry["sha256"], str) or not HEX64.fullmatch(entry["sha256"]):
            fail(f"tier2-catalog models[{idx}]: sha256 must be lowercase 64-hex")
        if not isinstance(entry["source"], str) or not entry["source"].strip():
            fail(f"tier2-catalog models[{idx}]: source required")
        min_ram = entry.get("min_ram_gb")
        if min_ram is not None and (not isinstance(min_ram, int) or isinstance(min_ram, bool) or min_ram < 1):
            fail(f"tier2-catalog models[{idx}]: min_ram_gb must be a positive integer")
        notes = entry.get("notes")
        if notes is not None and not isinstance(notes, str):
            fail(f"tier2-catalog models[{idx}]: notes must be a string")
    signature = value["signature"]
    if not isinstance(signature, dict):
        fail("tier2-catalog: signature must be an object")
    exact_keys(signature, {"alg", "key_id", "sig"}, {"alg", "key_id", "sig"}, "tier2-catalog signature")
    if signature["alg"] != "Ed25519":
        fail("tier2-catalog: signature.alg must be Ed25519")
    if not isinstance(signature["key_id"], str) or not signature["key_id"].strip():
        fail("tier2-catalog: signature.key_id required")
    if not isinstance(signature["sig"], str) or not signature["sig"].strip():
        fail("tier2-catalog: signature.sig required")
    if not TIER2_SIG_PATTERN.fullmatch(signature["sig"]):
        fail(
            "tier2-catalog: signature.sig must be exactly 86 unpadded base64url "
            "characters ([A-Za-z0-9_-]), matching Go's ed25519+RawURLEncoding output"
        )
    canonical_urlsafe_b64_decode(signature["sig"], 64, "tier2-catalog: signature.sig")
    return value


def _yaml_block_value(text: str, block: str, key: str) -> str | None:
    """Read `block.key` from a simple flat YAML mapping.

    Mirrors `yaml_block_value` in phase4-coordinator/dist/deploy-pearl-vps.sh
    so both tools agree on the same coordinator.yaml without adding a PyYAML
    dependency to this script.
    """
    block_start = re.compile(r"^[ \t]*" + re.escape(block) + r":[ \t]*$")
    top_level = re.compile(r"^[^\s#][^:]*:")
    key_line = re.compile(r"^[ \t]*" + re.escape(key) + r":[ \t]*(.*)$")
    in_block = False
    for raw_line in text.splitlines():
        line = re.sub(r"[ \t]+#.*$", "", raw_line)
        if not in_block:
            if block_start.match(line):
                in_block = True
            continue
        if top_level.match(line):
            break
        match = key_line.match(line)
        if match:
            return match.group(1).strip().strip("\"'")
    return None


def canonical_urlsafe_b64_decode(value: str, expected_len: int, label: str) -> bytes:
    """Decode unpadded base64url and reject any input that is not itself the
    canonical encoding of the decoded bytes.

    Plain `base64.urlsafe_b64decode` tolerates trailing-character
    malleability: the last symbol's unused low bits are ignored, so e.g. two
    distinct 86-character strings can decode to the same 64-byte Ed25519
    signature, or a non-canonical string can still decode to a valid-length
    key. Re-encoding the decoded bytes and requiring an exact match pins the
    accepted alphabet to exactly what Go's `RawURLEncoding` would emit
    (#608 audit).
    """
    padded = value + "=" * (-len(value) % 4)
    try:
        decoded = base64.urlsafe_b64decode(padded)
    except (ValueError, TypeError) as exc:
        fail(f"{label} is not valid base64url: {exc}")
    if len(decoded) != expected_len:
        fail(f"{label} must decode to exactly {expected_len} bytes")
    if base64.urlsafe_b64encode(decoded).rstrip(b"=").decode("ascii") != value:
        fail(f"{label} is not canonically encoded (non-canonical base64url padding bits)")
    return decoded


def require_trusted_regular_input(path: pathlib.Path, label: str, max_bytes: int) -> None:
    """Reject link/substitution hazards on files used as trust authority."""
    if not path.is_absolute() or ".." in path.parts:
        fail(f"{label} must use an absolute normalized path")
    try:
        metadata = path.lstat()
    except OSError as exc:
        fail(f"{label} cannot be inspected: {exc}")
    if (
        path.is_symlink()
        or not stat.S_ISREG(metadata.st_mode)
        or metadata.st_nlink != 1
        or metadata.st_size <= 0
        or metadata.st_size > max_bytes
    ):
        fail(f"{label} must be a bounded regular non-symlink single-link file")
    if os.geteuid() != 0:
        return
    current = pathlib.Path(path.anchor)
    for part in path.parts[1:]:
        current /= part
        try:
            component = current.lstat()
        except OSError as exc:
            fail(f"{label} path component {current} cannot be inspected: {exc}")
        if component.st_uid != 0 or stat.S_ISLNK(component.st_mode):
            fail(f"{label} path must be root-owned and symlink-free when privileged: {current}")
        writable = component.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
        sticky_root_directory = stat.S_ISDIR(component.st_mode) and component.st_mode & stat.S_ISVTX
        if writable and not sticky_root_directory:
            fail(f"{label} path is group/world-writable when privileged: {current}")


def load_tier2_trusted_public_key(
    public_key_path: pathlib.Path | None = None,
    coordinator_config_path: pathlib.Path | None = None,
) -> str:
    """Resolve the trusted Tier-2 Ed25519 public key used to authenticate a
    signed `tier2-catalog.json` before it can be trusted as a release feed
    member.

    Reads `tier2.catalog_public_key` from the same committed
    `phase4-coordinator/dist/coordinator.yaml` that `deploy-pearl-vps.sh`
    pins before upload, so `catalog-release.py` and the deploy pipeline
    agree on one trusted key. Deliberately no environment-variable override:
    an ambient env var would let anything that can set process environment
    (not just a reviewed PR touching the committed trust root) swap the
    trusted key. Tests instead monkeypatch the module-level
    `COORDINATOR_YAML_PATH` constant, the same pattern already used for
    `TIER2_CATALOG_PATH`.
    """
    if public_key_path is not None and coordinator_config_path is not None:
        fail("tier2-catalog: specify only one explicit Tier-2 trust-root source")
    explicit_path = public_key_path or coordinator_config_path
    if explicit_path is not None:
        source = str(explicit_path)
        size_limit = 1024 if public_key_path is not None else 1024 * 1024
        require_trusted_regular_input(
            explicit_path,
            f"tier2-catalog: trusted Tier-2 public key source {source}",
            size_limit,
        )
        text = explicit_path.read_text()
        candidate = (
            text.strip()
            if public_key_path is not None
            else (_yaml_block_value(text, "tier2", "catalog_public_key") or "").strip()
        )
        if not candidate:
            fail(f"tier2-catalog: tier2.catalog_public_key is empty in {source}")
        canonical_urlsafe_b64_decode(candidate, 32, f"tier2-catalog: trusted public key in {source}")
        return candidate
    source = str(COORDINATOR_YAML_PATH)
    require_trusted_regular_input(
        COORDINATOR_YAML_PATH,
        f"tier2-catalog: configured Tier-2 public key source {source}",
        1024 * 1024,
    )
    candidate = (_yaml_block_value(COORDINATOR_YAML_PATH.read_text(), "tier2", "catalog_public_key") or "").strip()
    if not candidate:
        fail(f"tier2-catalog: tier2.catalog_public_key is empty in {source}; cannot authenticate signed Tier-2 catalogs")
    canonical_urlsafe_b64_decode(candidate, 32, f"tier2-catalog: trusted public key in {source}")
    return candidate


def go_executable() -> str:
    """Locate a trusted Go toolchain executable for `verify_tier2_signature`.

    Mirrors `openssl_executable()`'s hardening where it matters for Tier-2:
    no environment override, no PATH-selected binary, a fixed absolute
    candidate list, a root-ownership check when running privileged, and a
    version probe before trusting the binary. Tier-2 authenticity must not
    depend on ambient process environment.
    """
    sealed_requirement = os.environ.get(REQUIRE_SEALED_GO_ENV)
    if sealed_requirement not in (None, "1"):
        fail(f"{REQUIRE_SEALED_GO_ENV} must be unset or exactly 1")
    require_sealed = sealed_requirement == "1"

    candidates = [
        candidate
        for candidate in FIXED_GO_EXECUTABLES
        if candidate in ALWAYS_ROOT_TRUSTED_GO_EXECUTABLES
    ] + [
        candidate
        for candidate in FIXED_GO_EXECUTABLES
        if candidate not in ALWAYS_ROOT_TRUSTED_GO_EXECUTABLES
    ]

    checked: list[str] = []
    for candidate in candidates:
        if not candidate or candidate in checked:
            continue
        checked.append(candidate)
        sealed_candidate = candidate in ALWAYS_ROOT_TRUSTED_GO_EXECUTABLES
        if sealed_candidate:
            if not os.path.lexists(candidate):
                if require_sealed:
                    fail(f"required sealed Go verifier toolchain is missing: {candidate}")
                continue
            if not root_trusted_executable(candidate):
                fail(f"sealed Go verifier toolchain is not root-trusted: {candidate}")
        elif os.geteuid() == 0 and not root_trusted_executable(candidate):
            continue
        try:
            result = subprocess.run(
                [candidate, "version"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=GO_PROBE_TIMEOUT_SECONDS,
            )
        except (OSError, subprocess.TimeoutExpired):
            if sealed_candidate:
                fail(f"sealed Go verifier toolchain cannot execute: {candidate}")
            continue
        if result.returncode == 0 and re.match(r"^go version go\d", result.stdout):
            return candidate
        if sealed_candidate:
            fail(f"sealed Go verifier toolchain failed its version probe: {candidate}")

    fail("a Go toolchain is required to authenticate the signed Tier-2 catalog's Ed25519 signature")


def require_trusted_verifier_source(path: pathlib.Path) -> None:
    """Reject substituted verifier source before treating `go run` as proof."""
    require_trusted_regular_input(
        path,
        f"tier2-catalog: signature verifier source {path}",
        1024 * 1024,
    )


def tier2_trusted_key_fingerprint(public_key_b64: str) -> str:
    """Stable identifier for a trusted Tier-2 Ed25519 public key.

    Used as `signer_key_id` in the manifest/ledger instead of the catalog's
    own `signature.key_id` claim: `sign-catalog.go`'s canonical signed body
    excludes the entire `signature` object (see `canonicalCatalogJSON`), so
    `key_id` is unauthenticated metadata alongside the signature, not part
    of what Ed25519 actually covers. Recording it verbatim would let anyone
    who can produce a validly-signed catalog choose an arbitrary
    `signer_key_id` for the immutable ledger (#608 audit). Fingerprinting the
    trusted key itself ties the recorded identity to what was cryptographically
    proven, and changes only if the trusted key configuration changes.
    """
    padded = public_key_b64 + "=" * (-len(public_key_b64) % 4)
    raw_key = base64.urlsafe_b64decode(padded)
    return "tier2-coordinator-key:" + hashlib.sha256(raw_key).hexdigest()[:16]


def verify_tier2_signature(
    raw: bytes,
    public_key_path: pathlib.Path | None = None,
    coordinator_config_path: pathlib.Path | None = None,
) -> str:
    """Authenticate a Tier-2 catalog's Ed25519 signature before any caller
    may trust it as "signed" (#608 Partial: ledger feed membership).

    Delegates to `sign-catalog.go verify`, the same canonicalization and
    verification `deploy-pearl-vps.sh` already runs before upload, instead
    of reimplementing Go's exact struct-field JSON encoding in Python.
    `validate_tier2_catalog` alone only locks the JSON shape; it does not
    prove authenticity. Returns the authenticated signer's key fingerprint
    for the caller to bind into `manifest()` as `tier2_signer_key_id`.
    """
    go_bin = go_executable()
    require_trusted_verifier_source(SIGN_CATALOG_GO_PATH)
    public_key = load_tier2_trusted_public_key(public_key_path, coordinator_config_path)
    with tempfile.TemporaryDirectory(prefix="macprovider-tier2-verify-") as tmp:
        tmpdir = pathlib.Path(tmp)
        catalog_path = tmpdir / "tier2-catalog.json"
        pubkey_path = tmpdir / "tier2-catalog.pub"
        catalog_path.write_bytes(raw)
        pubkey_path.write_text(public_key + "\n")
        try:
            result = subprocess.run(
                [go_bin, "run", str(SIGN_CATALOG_GO_PATH), "verify", "-public-key", str(pubkey_path), str(catalog_path)],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=TIER2_SIGN_VERIFY_TIMEOUT_SECONDS,
                cwd=str(ROOT),
            )
        except subprocess.TimeoutExpired:
            fail("tier2-catalog: signature verification timed out")
    if result.returncode != 0:
        detail = (result.stderr.strip() or result.stdout.strip() or "unknown error")
        fail(f"tier2-catalog: signature verification failed: {detail}")
    return tier2_trusted_key_fingerprint(public_key)


def load_tier2_models(tier2_data: bytes) -> dict[str, str]:
    value = strict_json(tier2_data, "tier2-catalog")
    models = value.get("models")
    if not isinstance(models, list) or not models:
        fail("tier2-catalog: models required")
    out: dict[str, str] = {}
    for idx, entry in enumerate(models):
        if not isinstance(entry, dict):
            fail(f"tier2-catalog: models[{idx}] must be an object")
        model_id = entry.get("model_id")
        sha = entry.get("sha256")
        if not isinstance(model_id, str) or not model_id.strip():
            fail(f"tier2-catalog: models[{idx}] model_id required")
        if not isinstance(sha, str) or not HEX64.fullmatch(sha):
            fail(f"tier2-catalog: models[{idx}] sha256 must be lowercase 64-hex")
        normalized = model_id.lower().strip()
        if normalized in out and out[normalized] != sha:
            fail(f"tier2-catalog: duplicate model_id {model_id!r} with conflicting sha256")
        out[normalized] = sha
    return out


def check_tier2_binding(candidate_data: bytes, tier2_data: bytes) -> None:
    """Fail closed when Tier-2 and autotune disagree on overlapping model hashes."""
    candidate_obj = validate_candidate(candidate_data)
    tier2_models = load_tier2_models(tier2_data)
    claimed = highest_claimed_autotune_rows(candidate_obj)
    conflicts = []
    for normalized, (key, row) in sorted(claimed.items()):
        auto_hash = row.get("model_sha256")
        if not isinstance(auto_hash, str) or not auto_hash:
            continue
        tier2_hash = tier2_models.get(normalized)
        if tier2_hash is None:
            continue
        if tier2_hash != auto_hash:
            conflicts.append(
                f"model_id {row['model_id']!r} autotune({candidate_obj['version']}/{key})={auto_hash} "
                f"conflicts with tier2={tier2_hash}"
            )
    if conflicts:
        fail(f"autotune/tier2 identity conflict on {len(conflicts)} model(s): " + "; ".join(conflicts))


def load_tier2_republish_template(data: bytes) -> dict:
    """Parse an operator-reviewed Tier-2 catalog body used as a republish
    template for `stage-tier2-republish` (#608). Accepts either the unsigned
    body shape or the full signed shape (an optional `signature` object is
    ignored; the staged output is always unsigned)."""
    value = strict_json(data, "tier2 republish template")
    allowed = {"catalog_id", "expires_at", "issued_at", "models", "version", "signature"}
    required = {"catalog_id", "expires_at", "issued_at", "models", "version"}
    exact_keys(value, allowed, required, "tier2 republish template")
    if value["version"] != 1:
        fail("tier2 republish template: version must be 1")
    if not isinstance(value["catalog_id"], str) or not value["catalog_id"].strip():
        fail("tier2 republish template: catalog_id must be a non-empty string")
    if not isinstance(value["issued_at"], str) or not value["issued_at"].strip():
        fail("tier2 republish template: issued_at must be a non-empty string")
    if not isinstance(value["expires_at"], str) or not value["expires_at"].strip():
        fail("tier2 republish template: expires_at must be a non-empty string")
    models = value["models"]
    if not isinstance(models, list) or not models:
        fail("tier2 republish template: models must be a non-empty array")
    allowed_entry = {"artifact_kind", "hash_scope", "model_id", "min_ram_gb", "notes", "sha256", "source"}
    required_entry = {"artifact_kind", "hash_scope", "model_id", "sha256", "source"}
    seen: set[str] = set()
    for idx, entry in enumerate(models):
        label = f"tier2 republish template models[{idx}]"
        if not isinstance(entry, dict):
            fail(f"{label}: must be an object")
        exact_keys(entry, allowed_entry, required_entry, label)
        if entry["artifact_kind"] != "mlx_weight_file":
            fail(f"{label}: artifact_kind must be mlx_weight_file")
        if entry["hash_scope"] not in TIER2_HASH_SCOPES:
            fail(f"{label}: unsupported hash_scope")
        if not isinstance(entry["model_id"], str) or not entry["model_id"].strip():
            fail(f"{label}: model_id must be a non-empty string")
        if not isinstance(entry["sha256"], str) or not HEX64.fullmatch(entry["sha256"]):
            fail(f"{label}: sha256 must be lowercase 64-hex")
        if not isinstance(entry["source"], str) or not entry["source"].strip():
            fail(f"{label}: source must be a non-empty string")
        if "min_ram_gb" in entry and entry["min_ram_gb"] is not None and (
            not isinstance(entry["min_ram_gb"], int)
            or isinstance(entry["min_ram_gb"], bool)
            or entry["min_ram_gb"] < 1
        ):
            fail(f"{label}: min_ram_gb must be a positive integer")
        if "notes" in entry and entry["notes"] is not None and not isinstance(entry["notes"], str):
            fail(f"{label}: notes must be a string")
        normalized = entry["model_id"].strip().lower()
        if normalized in seen:
            fail(f"{label}: duplicate model_id {entry['model_id']!r}")
        seen.add(normalized)
    return value


def stage_tier2_republish(template_obj: dict, binding_obj: dict) -> tuple[bytes, list[str]]:
    """Project autotune-derived hashes from a validated
    `tier2-identity-binding.json` object onto an operator-reviewed Tier-2
    republish template, changing only `sha256` for model_ids that overlap.

    This is deliberately NOT `derive_tier2_unsigned_body`: it never invents
    `hash_scope`, `artifact_kind`, `min_ram_gb`, `notes`, or `source` — those
    stay exactly as the operator wrote them in the template. It only closes
    autotune/Tier-2 identity drift (#608) so the result can be reviewed and
    handed to `scripts/sign-catalog.go sign`. It is not a second identity
    authority: the caller must still run `check-tier2-binding` (this
    function calls it internally) before treating the output as republish-
    ready, and Pearl upload still goes through the reviewed sign + deploy
    path, never this script alone.
    """
    binding_by_model: dict[str, str] = {}
    for entry in binding_obj["models"]:
        binding_by_model[entry["model_id"].strip().lower()] = entry["sha256"]
    changed: list[str] = []
    updated_models = []
    for entry in template_obj["models"]:
        normalized = entry["model_id"].strip().lower()
        autotune_hash = binding_by_model.get(normalized)
        new_entry = dict(entry)
        if autotune_hash is not None and autotune_hash != entry["sha256"]:
            changed.append(f"{entry['model_id']}: {entry['sha256']} -> {autotune_hash}")
            new_entry["sha256"] = autotune_hash
        updated_models.append(new_entry)
    body = {
        "catalog_id": template_obj["catalog_id"],
        "expires_at": template_obj["expires_at"],
        "issued_at": template_obj["issued_at"],
        "models": updated_models,
        "version": template_obj["version"],
    }
    return json.dumps(body, indent=2, sort_keys=True).encode("utf-8") + b"\n", changed


def derive_tier2_unsigned_body(
    candidate_obj: dict,
    *,
    catalog_id: str,
    issued_at: str,
    expires_at: str,
) -> bytes:
    """Disabled until Tier-2 gains an explicit snapshot-manifest hash_scope.

    Autotune `model_sha256` is `macprovider.snapshot-manifest.v1`. Existing
    Tier-2 `hash_scope` enums (`primary_weight_file`, `artifact_manifest`,
    `coordinator_endorsed_incremental`) mean different byte algorithms
    (SPEC-008). Emitting a signable body under any of those scopes would
    mislabel identity (#608 audit HIGH). Use `tier2-identity-binding.json`
    from `generate` plus `check-tier2-binding` against an operator-reviewed
    signed catalog until the schema follow-up lands.
    """
    del candidate_obj, catalog_id, issued_at, expires_at
    fail(
        "derive-tier2 is disabled until Tier-2 supports an explicit "
        "macprovider.snapshot-manifest.v1 hash_scope (#608 follow-up). "
        "Use tier2-identity-binding.json from `generate` and "
        "`check-tier2-binding` against an operator-reviewed signed Tier-2 catalog."
    )


def require_tier2_catalog() -> tuple[bytes, dict, str]:
    """Bind signed Tier-2 bytes as a release feed member when `generate` runs.

    Historical release-ledger rows generated before this capability existed
    keep their original 2-feed shape (`validate_release_ledger` accepts both
    shapes), but Step B makes every current/new release bind a canonical
    `tier2-catalog.json` feed member. Absence is fail-closed.
    """
    if not TIER2_CATALOG_PATH.exists():
        fail(
            "generate: tier2-catalog.json is missing. Every current catalog "
            "release must bind a signed Tier-2 catalog as a release-ledger "
            f"feed member; place it at {TIER2_CATALOG_PATH}."
        )
    tier2 = TIER2_CATALOG_PATH.read_bytes()
    tier2_obj = validate_tier2_catalog(tier2)
    tier2_signer_key_id = verify_tier2_signature(tier2)
    return tier2, tier2_obj, tier2_signer_key_id


def updated_release_ledger(
    manifest_bytes: bytes,
    bindings: list[dict] | None = None,
    intake_decision_sha256: str | None = None,
) -> bytes:
    current = validate_release_ledger(LEDGER_PATH.read_bytes()) if LEDGER_PATH.exists() else empty_release_ledger()
    require_ledger_evolution(base_release_ledger(), current)
    release_id, record = release_record(manifest_bytes, bindings, intake_decision_sha256)
    if release_id in current["tombstones"]:
        fail(f"release ledger: release ID {release_id!r} is permanently rejected")
    existing = current["releases"].get(release_id)
    if existing is not None and existing != record and not is_tier2_enrichment(existing, record) and not is_rate_card_enrichment(existing, record):
        fail(f"release ledger: release ID {release_id!r} is already bound to different content")
    schema_version = current["schema_version"]
    if bindings is not None:
        schema_version = LEDGER_SCHEMA_V3
    updated = {
        "schema_version": schema_version,
        "releases": dict(current["releases"]),
        "tombstones": dict(current["tombstones"]),
    }
    updated["releases"][release_id] = record
    require_ledger_evolution(current, updated)
    return ledger_bytes(updated)


def resolve_artifact_feed(candidate: bytes, candidate_obj: dict) -> tuple[bytes | None, dict | None]:
    """Materialise the release's artifact feed from the operator-authored source.

    Absence of `autotune-artifacts-source.json` is the pre-activation state: no
    artifact feed is generated, the release keeps the rate-card-bound four-feed
    set, and v0.1 behaviour is unchanged (§3.7.6 rule 6). Committing the source
    alone does not activate anything either — activation is the operator release
    cut that publishes the generated feed and records the artifact-bound ledger
    row (§3.7.8 Stage A).
    """
    if not ARTIFACT_SOURCE_PATH.exists():
        return None, None
    source_obj = validate_artifact_source(ARTIFACT_SOURCE_PATH.read_bytes(), candidate_obj)
    artifacts = build_artifact_feed(source_obj, candidate, candidate_obj)
    return artifacts, validate_artifact_feed(artifacts, candidate, candidate_obj)


def published_artifact_feed(
    candidate: bytes,
    candidate_obj: dict,
    feed_path: pathlib.Path,
) -> tuple[bytes | None, dict | None]:
    """Re-derive the artifact feed for a release that has already published one.

    Pre-activation the published feed is absent while the operator-authored source
    may already be committed. That state is valid and leaves v0.1 behaviour
    untouched, so the source is only STRUCTURALLY checked here; the measured-size,
    candidate-consistency, and signing requirements bite at `generate`, which is
    the operator release cut.
    """
    if not feed_path.exists():
        if ARTIFACT_SOURCE_PATH.exists():
            validate_artifact_source(ARTIFACT_SOURCE_PATH.read_bytes())
        return None, None
    if not ARTIFACT_SOURCE_PATH.exists():
        fail(
            f"generated drift: {feed_path} is published but {ARTIFACT_SOURCE_PATH.name} is "
            "missing; the published feed must be reproducible from named release inputs"
        )
    return resolve_artifact_feed(candidate, candidate_obj)


def published_feed_rate_classes(feed_path: pathlib.Path) -> dict[str, str] | None:
    """The `rate_class` map bound by the PUBLISHED artifact feed, read from its
    committed bytes — not re-derived from the source, which is the only way a
    source-vs-published comparison can observe a disagreement.

    Only the document's own structure is checked here: release binding
    (`candidate_catalog_sha256`, `version`, `generated_at`) is `verify`'s job and
    is legitimately stale between `restamp` and the `generate` that rewrites the
    feed, which is exactly when `emit-coordinator-rate-card` is run.
    """
    if not feed_path.exists():
        return None
    label = feed_path.name
    value = strict_json(feed_path.read_bytes(), label)
    top = {
        "version", "generated_at", "policy_version", "source", "release_id",
        "candidate_catalog_sha256", "models",
    }
    exact_keys(value, top, top, label)
    validate_artifact_models(value["models"], label, allow_unmeasured_size=False)
    return artifact_rate_classes(value)


def authoring_rate_classes() -> dict[str, str]:
    """The §3.3.1 `rate_class` map for AUTHORING-time projections of the rate card.

    `rate_class` is authored on `autotune-artifacts-source.json` and only reaches
    the published feed at the activation release cut. Reading the classes through
    the PUBLISHED feed alone therefore deadlocks the first activation: a model key
    priced solely by class expands to no published row before the feed exists, so
    `emit-coordinator-rate-card` cannot emit the coordinator fallback row that
    rule-9 parity requires before `generate --activate-artifact-feed` will publish
    that same feed. The published bytes are the right authority for VERIFYING a
    release; they are the wrong authority for projecting the config a not-yet-cut
    release needs.

    So: published feed when one exists, the authored source when none does, and
    an equality between the two when both exist. The published side is read from
    the committed feed BYTES: re-deriving it from the source would compare the
    source with itself and could never see the source drift away from what the
    release actually binds.
    """
    published = published_feed_rate_classes(ARTIFACT_FEED_PATH)
    if not ARTIFACT_SOURCE_PATH.exists():
        if published is not None:
            fail(
                f"generated drift: {ARTIFACT_FEED_NAME} is published but {ARTIFACT_SOURCE_PATH.name} is "
                "missing; the published feed must be reproducible from named release inputs"
            )
        return {}
    source_obj = validate_artifact_source(ARTIFACT_SOURCE_PATH.read_bytes())
    authored = artifact_rate_classes({"models": source_obj["models"]})
    if published is None:
        return authored
    if authored != published:
        fail(
            f"rate-card: {ARTIFACT_SOURCE_PATH.name} declares rate classes {authored} but the "
            f"published {ARTIFACT_FEED_NAME} binds {published}; the authoring source and the "
            "published feed must agree before either can price a release"
        )
    return published


def resolve_rate_card(rate_classes: dict[str, str], candidate_obj: dict) -> bytes:
    """Materialise the published rate card, from `rate-card-source.json` when the
    operator has adopted the §3.3.1 authoring source and from the committed
    published feed otherwise."""
    if RATE_CARD_SOURCE_PATH.exists():
        source_obj = validate_rate_card_source(RATE_CARD_SOURCE_PATH.read_bytes())
        if source_obj["policy_version"] != candidate_obj["policy_version"]:
            fail("rate-card-source: policy_version must match the atomic release")
        return expand_rate_card(source_obj, rate_classes, candidate_obj)
    if rate_classes:
        fail(
            "rate-card: the artifact feed declares rate classes but "
            f"{RATE_CARD_SOURCE_PATH.name} is absent; class expansion needs its authoring source"
        )
    rate_card_obj = validate_rate_card((CATALOG_DIR / RATE_CARD_FEED_NAME).read_bytes())
    require_recommendable_rate_rows(candidate_obj, rate_card_obj)
    return canonical_bytes(rate_card_obj)


def intake_decision_digest() -> str | None:
    """§3.7.8 `intake_decision_sha256`: the digest of the release's committed
    §16.8 intake-decision manifest, or `null` for a release that adds no `listed`
    row and promotes no row to `recommendable`. The §16.8 manifest schema and the
    tier-change completeness rule (AC-CAT-21) are owned by the listed-tier intake
    slice; this slice records the digest the ledger row is required to carry, and
    `require_intake_decision` below decides when `null` is permitted."""
    if INTAKE_DECISION_PATH.exists():
        return sha256(INTAKE_DECISION_PATH.read_bytes())
    return None


# SPEC-023 §3.7.8 speaks of a row being "added as listed" or "promoted to
# recommendable". The §3.2 candidate-catalog spelling of the pre-admission states
# is `candidate` / `blocked`; ranking them lets one comparison cover all three
# named transitions (absent → listed/recommendable, pre-admission → listed/
# recommendable, listed → recommendable) while a DEMOTION, which needs no intake
# decision, is not mistaken for one.
CANDIDATE_ADMISSION_TIER = {"blocked": 0, "candidate": 0, "listed": 1, "recommendable": 2}


def candidate_admission_tiers(candidate_obj: dict) -> dict[str, int]:
    return {
        key: CANDIDATE_ADMISSION_TIER[row["runtime_status"]]
        for key, row in candidate_obj["rows"].items()
    }


def latest_release(releases: dict[str, dict]) -> tuple[str, dict] | None:
    """The most recently generated recorded release, chronologically then by id."""
    if not releases:
        return None
    _, release_id, record = max(
        (
            (release_order_key(release_id, record), release_id, record)
            for release_id, record in releases.items()
        ),
        key=lambda row: row[0],
    )
    return release_id, record


def previous_candidate_admission(
    candidate_obj: dict,
    history: dict[str, dict],
    previous_release: dict | None,
) -> dict[str, int] | None:
    """The previous release's per-key admission tiers, or `None` when unknown.

    Two named release inputs can supply it:

    1. `--previous-release-dir`, whose candidate catalog is authenticated against
       the trusted keyring and the ledger row (`load_previous_release`).
    2. For the ACTIVATION release, where no previous release directory is
       required, the ledger's own `autotune-candidates.json` digest for the
       preceding release. A freshness-style release re-stamps only `version` and
       `generated_at`, so re-stamping the current catalog with the preceding
       release's values and canonicalising reproduces its exact bytes when — and
       only when — nothing else changed. Digest equality is therefore a PROOF
       that the candidate rows, and so every admission tier, are unchanged.

    Any other state returns `None`: prior admission is unavailable and the caller
    fails closed rather than assuming no transition occurred.
    """
    if previous_release is not None:
        return candidate_admission_tiers(previous_release["candidate_obj"])
    latest = latest_release(history)
    if latest is None:
        return None
    release_id, record = latest
    binding = record["feeds"].get("autotune-candidates.json")
    if not isinstance(binding, dict):
        return None
    restamped = dict(candidate_obj)
    restamped["version"] = release_id
    restamped["generated_at"] = record["generated_at"]
    if sha256(canonical_bytes(restamped)) != binding["sha256"]:
        return None
    return candidate_admission_tiers(candidate_obj)


def intake_transitions(previous_tiers: dict[str, int], current_tiers: dict[str, int]) -> list[str]:
    """Keys this release adds as `listed`/`recommendable` or promotes upward."""
    changed = []
    for key in sorted(current_tiers):
        tier = current_tiers[key]
        if tier < 1:
            continue
        previous = previous_tiers.get(key)
        if previous is None or tier > previous:
            changed.append(key)
    return changed


def require_intake_decision(
    candidate_obj: dict,
    previous_tiers: dict[str, int] | None,
    digest: str | None,
    *,
    activation: bool,
) -> None:
    """SPEC-023 §3.7.8: `intake_decision_sha256` is `null` ONLY for a release that
    adds no `listed` row and promotes no row to `recommendable`.

    Hashing `intake-decision.json` when it happens to exist is not that rule — it
    lets a signed, settlement-adjacent catalog admit or promote a model with no
    release-bound record of the decision that admitted it. The comparison needs
    the previous release's candidate statuses, which the ledger does not carry
    (it carries their digest), so this is a GENERATION-time gate on named release
    inputs rather than a document validator.
    """
    if previous_tiers is None:
        if not activation:
            fail(
                "release ledger: the previous release's candidate admission state is "
                "unavailable, so this release cannot prove it adds no listed row and "
                "promotes no row to recommendable; pass --previous-release-dir"
            )
        if digest is None:
            fail(
                "release ledger: the activation release's candidate catalog differs from the "
                f"preceding release's, so intake_decision_sha256 may not be null; commit "
                f"{INTAKE_DECISION_PATH.name} recording the §16.8 intake decision"
            )
        return
    changed = intake_transitions(previous_tiers, candidate_admission_tiers(candidate_obj))
    if changed and digest is None:
        fail(
            "release ledger: intake_decision_sha256 is null but this release admits or "
            f"promotes {changed}; SPEC-023 §3.7.8 requires the §16.8 intake-decision digest "
            f"for every added listed row and every promotion to recommendable"
        )


def artifact_feed_activation_state(
    candidate_obj: dict,
    ledger: dict[str, dict],
    *,
    activate: bool,
) -> str:
    """Decide whether THIS generation builds an artifact feed (§3.7.8 Stage A).

    Activation is a deliberate operator release cut, never a side effect of a
    file being committed. Committing `autotune-artifacts-source.json` — which is
    seeded with unmeasured `size_bytes` on purpose — must leave `generate`,
    `resign-autotune-static.sh`, and the scheduled freshness renewal producing the
    same four-feed release they produce today.

    The state is read from the release ledger, the published feed, and one
    explicit flag:

    * `pre_activation` — no earlier artifact-bound row, no artifact-bound row for
      this release, no published feed, and no `--activate-artifact-feed`. The
      source is schema-validated (unmeasured sizes allowed) and nothing is built.
    * `activation` — `--activate-artifact-feed` on a release_id no earlier
      release row already claims, or the idempotent re-run of that same release
      after its row exists. No previous release directory is required.
    * `post_activation` — an EARLIER release row is artifact-bound. The feed is
      mandatory and `--previous-release-dir` is a required rebinding input.
    """
    release_id = candidate_obj["version"]
    history = release_history(ledger, release_id)
    history_activated = latest_artifact_bound_release(history) is not None
    self_row = ledger["releases"].get(release_id)
    if history_activated:
        if activate:
            previous_id, _ = latest_artifact_bound_release(history)
            fail(
                f"--activate-artifact-feed applies only to the FIRST artifact-bound release; "
                f"release {previous_id!r} already activated the feed, so this release is a "
                "normal artifact-bound cut (pass --previous-release-dir instead)"
            )
        return "post_activation"
    if artifact_bound_row(self_row):
        return "activation"
    if activate:
        if self_row is not None:
            fail(
                f"--activate-artifact-feed requires a NEW release_id: {release_id!r} is already "
                "recorded in the release ledger without the artifact-bound feed set, and an "
                "already-published release may not be enriched with an artifact feed"
            )
        return "activation"
    if ARTIFACT_FEED_PATH.exists():
        fail(
            f"{ARTIFACT_FEED_PATH.name} is published but no release-ledger row binds it. "
            "Re-run with --activate-artifact-feed to cut the activation release, or remove "
            "the stale generated feed; generation never activates the feed implicitly"
        )
    return "pre_activation"


# Distribution surfaces slices 2b/2c own. Stage A is not servable until each is
# done, so `status` names them explicitly rather than letting a green generator
# read as "ready to publish".
PENDING_DISTRIBUTION_SURFACES = (
    ("CLI release payload", "phase3-binary/dist/package.sh (~196): copy autotune-artifacts.json + .sig"),
    ("GitHub release assets", ".github/workflows/release.yml (~1385, ~1418): publish both artifact files"),
    ("live release gate", "scripts/verify-live-coordinator-release-gate.py (~17): add the signed feed"),
    ("coordinator serving", "phase4-coordinator/internal/buyer/server.go: /v1/catalog-artifacts + .sig routes; internal/buyer/autotune_feeds.go: load + validate the pair with the base feeds (signer equality, release binding); internal/config/config.go + dist/coordinator.yaml: catalog_artifacts_path/_sig_path; dist/nginx-coordinator.malibu.tech.conf: exact allow-through blocks before the /v1/ catch-all"),
    ("scheduled renewal", ".github/workflows/renew-autotune-static-feed-signed.yml: supply AUTOTUNE_PREVIOUS_RELEASE_DIR (the previous signed release directory) or the monthly freshness renewal fails closed at generate after activation"),
)
# Requirements this slice records but does not enforce; each is owned by a
# later slice and named here so `status` never reads as complete.
DEFERRED_REQUIREMENTS = (
    ("§16.8 intake-decision manifest schema (AC-CAT-21)", "intake_decision_digest() records the digest only; closed-schema validation and tier-change completeness are owned by the listed-tier intake slice (SPEC-023-R006, epic #1453 slice 5)"),
)


def artifact_activation_prerequisites(candidate_obj: dict, ledger: dict[str, dict]) -> list[tuple[bool, str]]:
    """Generator-side prerequisites for `--activate-artifact-feed`, each with its
    satisfied/unmet verdict. `status` prints them; activation refuses on any unmet
    one so the operator sees the whole list instead of one failure at a time."""
    checks: list[tuple[bool, str]] = []
    release_id = candidate_obj["version"]
    if not ARTIFACT_SOURCE_PATH.exists():
        return [(False, f"{ARTIFACT_SOURCE_PATH.name} is committed")]
    checks.append((True, f"{ARTIFACT_SOURCE_PATH.name} is committed"))
    try:
        source_obj = validate_artifact_source(ARTIFACT_SOURCE_PATH.read_bytes(), candidate_obj)
    except CatalogError as exc:
        return checks + [(False, f"{ARTIFACT_SOURCE_PATH.name} validates against the candidate catalog: {exc}")]
    checks.append((True, f"{ARTIFACT_SOURCE_PATH.name} validates against the candidate catalog"))
    unmeasured = sorted(
        f"{model_key}/{artifact_id}"
        for model_key, model in source_obj["models"].items()
        for artifact_id, artifact in model["artifacts"].items()
        if artifact.get("size_bytes") is None
    )
    checks.append((
        not unmeasured,
        "every artifact size_bytes is measured"
        + (f" (unmeasured: {', '.join(unmeasured)})" if unmeasured else ""),
    ))
    checks.append((RATE_CARD_SOURCE_PATH.exists(), f"{RATE_CARD_SOURCE_PATH.name} is committed"))
    if RATE_CARD_SOURCE_PATH.exists():
        try:
            rate_source = validate_rate_card_source(RATE_CARD_SOURCE_PATH.read_bytes())
            expand_rate_card(rate_source, artifact_rate_classes({"models": source_obj["models"]}), candidate_obj)
            checks.append((True, "every declared rate_class resolves to an explicit row or class rates"))
        except CatalogError as exc:
            checks.append((False, f"every declared rate_class resolves: {exc}"))
    self_row = ledger["releases"].get(release_id)
    checks.append((
        self_row is None or artifact_bound_row(self_row),
        f"release_id {release_id!r} is new (an already-published release may not be enriched)",
    ))
    checks.append((
        latest_artifact_bound_release(release_history(ledger, release_id)) is None,
        "no earlier release has already activated the artifact feed",
    ))
    return checks


def require_rate_card_unchanged_at_activation(rate_card_obj: dict, history: dict[str, dict]) -> None:
    """SPEC-023 §3.3.1 rule 8 / AC-CAT-10 as a GENERATION gate, not a fact about
    today's seed data.

    Pre-activation the artifact feed is unpublished, so the class map that
    reaches `expand_rate_card` is empty and only explicit rows are published.
    The activation release is therefore the first release at which class
    expansion can add or change a row — exactly the release rule 8 governs and
    §3.7.8 makes irreversible. The ledger already records each release's
    rate-card projection `version` (`rate_card_projection_hash`: rows +
    release globals + usd_per_million_credits), so equality with the latest
    recorded release IS the byte-identity check. It is slightly stronger than
    rule 8 (it covers the globals too), which is what the rule's own last
    sentence asks for: an intended price change is a separate reviewed release.
    """
    latest = latest_release(history)
    if latest is None:
        # No preceding recorded release: rule 8 is vacuous (there is no rows
        # map to be identical to). Reachable only on a bootstrapped ledger.
        return
    previous_id, record = latest
    previous = (record.get("feeds") or {}).get(RATE_CARD_FEED_NAME, {}).get("version")
    if previous is None:
        # A money-path gate must not fail open on an unknown prior: a legacy
        # two- or three-feed row cannot prove byte identity either way.
        fail(
            f"SPEC-023 §3.3.1 rule 8: the preceding release {previous_id!r} records no rate-card "
            "feed, so the activation release's rate card cannot be proven byte-identical to it"
        )
    if previous != rate_card_obj["version"]:
        fail(
            "SPEC-023 §3.3.1 rule 8: the activation release must publish rate-card rows "
            f"byte-identical to the preceding release {previous_id!r} (projection {previous} != "
            f"{rate_card_obj['version']}); class expansion is not a repricing event — reprice in "
            "a separate reviewed release, before or after activation"
        )


def generate(
    signer_key_id: str | None = None,
    previous_release_dir: pathlib.Path | None = None,
    activate_artifact_feed: bool = False,
) -> None:
    candidate_path = CATALOG_DIR / "autotune-candidates.json"
    demand_path = CATALOG_DIR / "demand-rank.json"
    rate_card_path = CATALOG_DIR / RATE_CARD_FEED_NAME
    candidate_obj = validate_candidate(candidate_path.read_bytes(), require_provenance=True)
    demand_obj = validate_demand(demand_path.read_bytes())
    candidate = canonical_bytes(candidate_obj)
    demand = canonical_bytes(demand_obj)
    ledger_before = validate_release_ledger(LEDGER_PATH.read_bytes()) if LEDGER_PATH.exists() else empty_release_ledger()
    state = artifact_feed_activation_state(candidate_obj, ledger_before, activate=activate_artifact_feed)
    if state == "activation":
        unmet = [detail for satisfied, detail in artifact_activation_prerequisites(candidate_obj, ledger_before) if not satisfied]
        if unmet:
            fail(
                "--activate-artifact-feed refused: the artifact feed is not activatable yet. "
                "Unmet prerequisites: " + "; ".join(unmet)
                + ". Run `catalog-release.py status` for the full activation checklist."
            )
    if state == "pre_activation":
        artifacts, artifact_obj = None, None
        if ARTIFACT_SOURCE_PATH.exists():
            # Structural only: the committed source may still carry unmeasured
            # `size_bytes` and may lag a candidate-catalog change, and a
            # pre-activation release must keep producing the rate-card-bound
            # four-feed set unchanged. Candidate consistency is an activation-time
            # prerequisite (`status`), not a gate on the four-feed train.
            validate_artifact_source(ARTIFACT_SOURCE_PATH.read_bytes())
    else:
        if not ARTIFACT_SOURCE_PATH.exists():
            fail(
                f"generate: this release is artifact-bound but {ARTIFACT_SOURCE_PATH.name} is missing; "
                "the published feed must be reproducible from named release inputs"
            )
        artifacts, artifact_obj = resolve_artifact_feed(candidate, candidate_obj)
    rate_classes = artifact_rate_classes(artifact_obj) if artifact_obj is not None else {}
    rate_card = resolve_rate_card(rate_classes, candidate_obj)
    rate_card_obj = validate_rate_card(rate_card)
    if state == "activation":
        require_rate_card_unchanged_at_activation(rate_card_obj, release_history(ledger_before, candidate_obj["version"]))
    validate_release_inputs(candidate_obj, demand_obj, rate_card_obj)
    check_rate_card_parity(rate_card_obj, COORDINATOR_YAML_PATH.read_text())
    if signer_key_id is not None and signer_key_id not in keyring():
        fail(f"cannot generate for unknown or retired signer key ID: {signer_key_id}")
    tier2, tier2_obj, tier2_signer_key_id = require_tier2_catalog()
    check_tier2_binding(candidate, tier2)
    # Compute every derived artifact before mutating on-disk release state so a
    # binding/derivation failure cannot leave a partially updated ledger.
    manifest_bytes = manifest(
        candidate, demand, rate_card, candidate_obj, demand_obj, rate_card_obj,
        signer_key_id=signer_key_id, tier2=tier2, tier2_obj=tier2_obj,
        tier2_signer_key_id=tier2_signer_key_id, artifacts=artifacts, artifact_obj=artifact_obj,
    )
    bindings = None
    intake_digest = intake_decision_digest()
    if artifact_obj is not None:
        history = release_history(ledger_before, candidate_obj["version"])
        previous_release = None
        if previous_release_dir is not None:
            previous_release = load_previous_release(previous_release_dir, history)
        require_no_artifact_rebinding(artifact_obj, history, previous_release)
        require_intake_decision(
            candidate_obj,
            previous_candidate_admission(candidate_obj, history, previous_release),
            intake_digest,
            activation=state == "activation",
        )
        bindings = artifact_bindings(artifact_obj)
    binding_bytes = derive_tier2_identity_binding(candidate, candidate_obj)
    swift_text = generated_swift(candidate, demand, rate_card, signer_key_id)
    next_ledger = updated_release_ledger(manifest_bytes, bindings, intake_digest)
    rejected_go = generated_rejected_releases_go(validate_release_ledger(next_ledger))
    CATALOG_DIR.mkdir(parents=True, exist_ok=True)
    STATIC_DIR.mkdir(parents=True, exist_ok=True)
    candidate_path.write_bytes(candidate)
    demand_path.write_bytes(demand)
    rate_card_path.write_bytes(rate_card)
    (STATIC_DIR / "autotune-candidates.json").write_bytes(candidate)
    (STATIC_DIR / "demand-rank.json").write_bytes(demand)
    (STATIC_DIR / RATE_CARD_FEED_NAME).write_bytes(rate_card)
    if artifacts is not None:
        ARTIFACT_FEED_PATH.write_bytes(artifacts)
        (STATIC_DIR / ARTIFACT_FEED_NAME).write_bytes(artifacts)
    SWIFT_GENERATED.write_text(swift_text)
    MANIFEST_PATH.write_bytes(manifest_bytes)
    LEDGER_PATH.write_bytes(next_ledger)
    TIER2_BINDING_PATH.write_bytes(binding_bytes)
    GO_REJECTED_RELEASES_GENERATED.write_text(rejected_go)
    artifact_note = f" artifacts={sha256(artifacts)}" if artifacts is not None else ""
    print(
        f"generated catalog release {candidate_obj['version']} "
        f"candidate={sha256(candidate)} demand={sha256(demand)} rate_card={sha256(rate_card)} "
        f"tier2_binding={sha256(binding_bytes)} tier2_catalog={sha256(tier2)}{artifact_note}"
    )


def migrate_swift_source() -> None:
    source = SWIFT_SOURCE.read_text()
    if "static let bakedCandidateCatalogJSON" not in source:
        return
    pattern = r"extension AutotuneStaticInputs \{\n.*?(?=    static let bakedRateCardJSON)"
    replacement = (
        "extension AutotuneStaticInputs {\n"
        "    // Rate card remains an independently refreshed coordinator projection.\n"
    )
    updated, count = re.subn(pattern, replacement, source, count=1, flags=re.S)
    if count != 1:
        fail("could not migrate baked candidate/demand constants out of AutotuneRecommend.swift")
    SWIFT_SOURCE.write_text(updated)


def restamp(release_id: str, generated_at: str) -> None:
    """Re-date the release's SOURCE OF TRUTH inputs for a freshness-only renewal.

    The signed feed carries a 30-day client freshness horizon
    (`AutotuneRecommend.loadSignedStatic`), so a scheduled job re-stamps and
    re-signs the same content every month. Content is otherwise byte-identical:
    the candidate and demand feeds take the new `version` + `generated_at`, and
    the rate card takes the date only — its `version` is a rows-projection hash
    that a freshness renewal MUST NOT change.

    The rate card is re-dated at its SOURCE. Since the §3.3.1 authoring source was
    adopted, `rate-card.json` is a GENERATED file: `generate` materialises it from
    `rate-card-source.json` on every run. Re-dating the generated file directly
    would be silently reverted by the very next `generate`, and the atomic-release
    check (`validate_release_inputs`) would then abort the renewal on a rate-card
    `generated_at` that no longer matches the re-stamped candidate catalog. So the
    source is re-dated when it exists, and only a checkout that predates the
    source falls back to re-dating the published file.
    """
    parse_timestamp(generated_at, "restamp --generated-at")
    if not release_id or release_id.strip() != release_id:
        fail("restamp: --release-id must be a non-empty unpadded release ID")
    for name in ("autotune-candidates.json", "demand-rank.json"):
        path = CATALOG_DIR / name
        if not path.exists():
            fail(f"restamp: {path} is missing")
        value = strict_json(path.read_bytes(), name)
        value["version"] = release_id
        value["generated_at"] = generated_at
        path.write_bytes(canonical_bytes(value))
    if RATE_CARD_SOURCE_PATH.exists():
        source = strict_json(RATE_CARD_SOURCE_PATH.read_bytes(), RATE_CARD_SOURCE_PATH.name)
        source["generated_at"] = generated_at
        RATE_CARD_SOURCE_PATH.write_text(json.dumps(source, indent=2, sort_keys=True) + "\n")
        restamped_rate_card = RATE_CARD_SOURCE_PATH.name
    else:
        rate_card_path = CATALOG_DIR / RATE_CARD_FEED_NAME
        if not rate_card_path.exists():
            fail(f"restamp: {rate_card_path} is missing")
        value = strict_json(rate_card_path.read_bytes(), RATE_CARD_FEED_NAME)
        value["generated_at"] = generated_at
        rate_card_path.write_bytes(canonical_bytes(value))
        restamped_rate_card = RATE_CARD_FEED_NAME
    print(
        f"catalog-release: re-stamped candidate/demand version={release_id} "
        f"generated_at={generated_at} ({restamped_rate_card} date only)"
    )


def bootstrap(release_id: str, generated_at: str, policy_version: str) -> None:
    candidate = extract_baked("bakedCandidateCatalogJSON")
    demand = extract_baked("bakedDemandRankJSON")
    for value in (candidate, demand):
        value["version"] = release_id
        value["generated_at"] = generated_at
        value["policy_version"] = policy_version
    CATALOG_DIR.mkdir(parents=True, exist_ok=True)
    (CATALOG_DIR / "autotune-candidates.json").write_bytes(canonical_bytes(candidate))
    (CATALOG_DIR / "demand-rank.json").write_bytes(canonical_bytes(demand))
    if not KEYS_PATH.exists():
        keys = {
            "schema_version": "macprovider.autotune-keys.v1",
            "keys": {
                "streamvc-autotune-static-v4": {
                    "public_key_base64": "zTKDIdMmKKkO1Cgf5OdTzMOytVqW7U8SGsJ9XrzAltU=",
                    "status": "active",
                },
                "streamvc-autotune-static-v5": {
                    "public_key_base64": "vpTgWfvvrnbc1QhdTAxULFisoDU7jQ4mB1yZIHIGjBA=",
                    "status": "bridge",
                }
            },
        }
        KEYS_PATH.write_text(json.dumps(keys, indent=2, sort_keys=True) + "\n")
    generate()
    migrate_swift_source()


def verify(previous_release_dir: pathlib.Path | None = None) -> None:
    candidate_path = CATALOG_DIR / "autotune-candidates.json"
    demand_path = CATALOG_DIR / "demand-rank.json"
    rate_card_path = CATALOG_DIR / RATE_CARD_FEED_NAME
    candidate = candidate_path.read_bytes()
    demand = demand_path.read_bytes()
    rate_card = rate_card_path.read_bytes()
    candidate_obj = validate_candidate(candidate)
    demand_obj = validate_demand(demand)
    rate_card_obj = validate_rate_card(rate_card)
    validate_release_inputs(candidate_obj, demand_obj, rate_card_obj)
    if candidate != canonical_bytes(candidate_obj) or demand != canonical_bytes(demand_obj) or rate_card != canonical_bytes(rate_card_obj):
        fail("canonical feed files must use deterministic compact JSON with no trailing newline")
    artifacts, artifact_obj = published_artifact_feed(candidate, candidate_obj, ARTIFACT_FEED_PATH)
    if artifacts is not None and ARTIFACT_FEED_PATH.read_bytes() != artifacts:
        fail(f"generated drift: {ARTIFACT_FEED_PATH}")
    rate_classes = artifact_rate_classes(artifact_obj) if artifact_obj is not None else {}
    if resolve_rate_card(rate_classes, candidate_obj) != rate_card:
        fail(f"generated drift: {rate_card_path} does not match its authoring source")
    check_rate_card_parity(rate_card_obj, COORDINATOR_YAML_PATH.read_text())
    expected = {
        STATIC_DIR / "autotune-candidates.json": candidate,
        STATIC_DIR / "demand-rank.json": demand,
        STATIC_DIR / RATE_CARD_FEED_NAME: rate_card,
    }
    if artifacts is not None:
        expected[STATIC_DIR / ARTIFACT_FEED_NAME] = artifacts
    else:
        # Artifact-feed presence must AGREE across the catalog directory,
        # dist/static, release.json, and the ledger. The manifest and ledger sides
        # are equalities below; dist/static is not, because a pre-activation
        # release simply omits the feed from `expected`. A body or sidecar left
        # under dist/static would then be signed by `resign-autotune-static.sh`,
        # published as a release asset, and bound by nothing — a feed the fleet
        # could fetch that no release, ledger row, or signature set accounts for.
        orphaned = [
            path
            for path in (STATIC_DIR / ARTIFACT_FEED_NAME, STATIC_DIR / f"{ARTIFACT_FEED_NAME}.sig")
            if path.exists()
        ]
        if orphaned:
            fail(
                f"{', '.join(str(path) for path in orphaned)} exists but this release publishes no "
                f"artifact feed ({ARTIFACT_FEED_PATH.name} is absent from the catalog directory and "
                "no ledger row binds it); remove the stale static file or cut the activation release"
            )
    for path, body in expected.items():
        if path.read_bytes() != body:
            fail(f"generated drift: {path}")
    if SWIFT_GENERATED.read_text() != generated_swift(candidate, demand, rate_card):
        fail(f"generated drift: {SWIFT_GENERATED}")
    tier2, tier2_obj, tier2_signer_key_id = require_tier2_catalog()
    check_tier2_binding(candidate, tier2)
    expected_manifest = manifest(
        candidate, demand, rate_card, candidate_obj, demand_obj, rate_card_obj,
        tier2=tier2, tier2_obj=tier2_obj, tier2_signer_key_id=tier2_signer_key_id,
        artifacts=artifacts, artifact_obj=artifact_obj,
    )
    if MANIFEST_PATH.read_bytes() != expected_manifest:
        fail(f"generated drift: {MANIFEST_PATH}")
    ledger = validate_release_ledger(LEDGER_PATH.read_bytes())
    require_ledger_evolution(base_release_ledger(), ledger)
    # Rule 8 is re-derived here, not only at `generate`: `verify` is the gate
    # CI runs on the committed bytes, so an activation release cut by a stale
    # generator is still caught while it is head. The release is the ACTIVATION
    # release exactly when it publishes the feed and no earlier row is bound.
    verify_history = release_history(ledger, candidate_obj["version"])
    if artifact_obj is not None and not any(artifact_bound_row(row) for row in verify_history.values()):
        require_rate_card_unchanged_at_activation(rate_card_obj, verify_history)
    release_id, record = release_record(
        expected_manifest,
        artifact_bindings(artifact_obj) if artifact_obj is not None else None,
        intake_decision_digest(),
    )
    if release_id in ledger["tombstones"]:
        fail(f"release ledger permanently rejects current release {release_id!r}")
    if ledger["releases"].get(release_id) != record:
        fail(f"release ledger does not bind current release {release_id!r} to the manifest")
    if LEDGER_PATH.read_bytes() != ledger_bytes(ledger):
        fail(f"generated drift: {LEDGER_PATH}")
    if GO_REJECTED_RELEASES_GENERATED.read_text() != generated_rejected_releases_go(ledger):
        fail(f"generated drift: {GO_REJECTED_RELEASES_GENERATED}")
    if not TIER2_BINDING_PATH.exists():
        fail(f"missing tier2 identity binding: {TIER2_BINDING_PATH}")
    validate_tier2_identity_binding(TIER2_BINDING_PATH.read_bytes(), candidate, candidate_obj)
    # SPEC-023 §3.7.8: `intake_decision_sha256` may be null ONLY for a release
    # that adds no `listed` row and promotes no row to `recommendable`. That is a
    # TRANSITION rule, so deciding it needs the previous release's candidate
    # admission state — which the ledger does not carry, only the digest of. With
    # `--previous-release-dir` this re-derives the same verdict `generate` reached
    # from the same authenticated input. Without it the verdict is not
    # reconstructible, and `verify` says so instead of passing silently: a
    # hand-assembled artifact-bound release that admits or promotes a row while
    # recording `null` is exactly what a silent pass would bless.
    if artifact_obj is not None:
        history = release_history(ledger, release_id)
        if previous_release_dir is not None:
            previous_release = load_previous_release(previous_release_dir, history)
            require_intake_decision(
                candidate_obj,
                previous_candidate_admission(candidate_obj, history, previous_release),
                intake_decision_digest(),
                activation=latest_artifact_bound_release(history) is None,
            )
            print(
                f"verified intake-decision transitions for {release_id} against "
                f"{previous_release['release_id']}"
            )
        else:
            print(
                f"verify: NOTICE: release {release_id} is artifact-bound and its "
                "intake_decision_sha256 transition rule (SPEC-023 §3.7.8) was NOT re-derived; "
                "pass --previous-release-dir <previous signed release directory> to check it"
            )
    keys = keyring()
    for path, body in expected.items():
        sidecar_path = pathlib.Path(str(path) + ".sig")
        key_id, signature = parse_sidecar(sidecar_path.read_bytes(), sidecar_path.name)
        public_key = keys.get(key_id)
        if public_key is None:
            fail(f"{sidecar_path.name}: unknown or retired key_id {key_id}")
        verify_ed25519(public_key, signature, body, sidecar_path.name)
    print(
        f"verified catalog release {candidate_obj['version']} "
        f"candidate={sha256(candidate)} demand={sha256(demand)} rate_card={sha256(rate_card)} "
        f"tier2_binding={sha256(TIER2_BINDING_PATH.read_bytes())} tier2_catalog={sha256(tier2)}"
    )


def verify_directory(
    directory: pathlib.Path,
    tier2_public_key_file: pathlib.Path | None = None,
    tier2_coordinator_config: pathlib.Path | None = None,
) -> None:
    candidate_path = directory / "autotune-candidates.json"
    demand_path = directory / "demand-rank.json"
    rate_card_path = directory / RATE_CARD_FEED_NAME
    for path in (candidate_path, demand_path, rate_card_path):
        if not path.exists():
            fail(f"release directory is missing required {path.name} feed")
    candidate = candidate_path.read_bytes()
    demand = demand_path.read_bytes()
    rate_card = rate_card_path.read_bytes()
    candidate_obj = validate_candidate(candidate)
    demand_obj = validate_demand(demand)
    rate_card_obj = validate_rate_card(rate_card)
    validate_release_inputs(candidate_obj, demand_obj, rate_card_obj)
    if candidate != canonical_bytes(candidate_obj) or demand != canonical_bytes(demand_obj) or rate_card != canonical_bytes(rate_card_obj):
        fail("release directory feeds are not deterministic canonical bytes")
    tier2_path = directory / "tier2-catalog.json"
    if not tier2_path.exists():
        fail("release directory is missing required tier2-catalog.json feed")
    tier2 = tier2_path.read_bytes()
    tier2_obj = validate_tier2_catalog(tier2)
    tier2_signer_key_id = verify_tier2_signature(tier2, tier2_public_key_file, tier2_coordinator_config)
    check_tier2_binding(candidate, tier2)
    artifact_path = directory / ARTIFACT_FEED_NAME
    artifacts = artifact_obj = None
    signed_feeds = [(candidate_path, candidate), (demand_path, demand), (rate_card_path, rate_card)]
    if artifact_path.exists():
        artifacts = artifact_path.read_bytes()
        artifact_obj = validate_artifact_feed(artifacts, candidate, candidate_obj)
        if artifacts != canonical_sorted_bytes(artifact_obj):
            fail("release directory artifact feed is not deterministic canonical bytes")
        require_recommendable_rate_rows(candidate_obj, rate_card_obj)
        signed_feeds.append((artifact_path, artifacts))
    expected_manifest = manifest(
        candidate, demand, rate_card, candidate_obj, demand_obj, rate_card_obj, directory,
        tier2=tier2, tier2_obj=tier2_obj, tier2_signer_key_id=tier2_signer_key_id,
        artifacts=artifacts, artifact_obj=artifact_obj,
    )
    if (directory / "release.json").read_bytes() != expected_manifest:
        fail("release directory manifest does not bind the feed bytes")
    keys = keyring(directory / "trusted-keys.json")
    for path, body in signed_feeds:
        sidecar_path = pathlib.Path(str(path) + ".sig")
        key_id, signature = parse_sidecar(sidecar_path.read_bytes(), sidecar_path.name)
        public_key = keys.get(key_id)
        if public_key is None:
            fail(f"{sidecar_path.name}: unknown or retired key_id {key_id}")
        verify_ed25519(public_key, signature, body, sidecar_path.name)
    binding_path = directory / "tier2-identity-binding.json"
    if binding_path.exists():
        validate_tier2_identity_binding(binding_path.read_bytes(), candidate, candidate_obj)
        print(f"verified repo-local tier2 identity binding for {candidate_obj['version']}")
    print(f"verified tier2 catalog {tier2_obj['catalog_id']} feed membership against release {candidate_obj['version']}")
    print(f"verified release directory {candidate_obj['version']} candidate={sha256(candidate)} demand={sha256(demand)} rate_card={sha256(rate_card)}")


def cmd_emit_coordinator_rate_card(output_path: pathlib.Path | None, from_source: bool = False) -> None:
    """Emit the `rewards.rate_card:` block that the release's published rate card
    requires of `phase4-coordinator/dist/coordinator.yaml` (SPEC-023 §3.3.1 rule 4).

    The generator emits rather than rewrites: coordinator.yaml carries reviewed
    money-path provenance comments, so the operator pastes the changed rows into
    the reviewed config and the rule-9 parity gate (`check_rate_card_parity`,
    enforced by `generate` and `verify`) then refuses to cut a release until the
    two sides agree row-for-row.

    The `rate_class` map comes from `authoring_rate_classes`, so a class-only row
    projects its coordinator fallback BEFORE the activation release publishes the
    artifact feed. Emitting is a projection of reviewed authoring inputs, not a
    verification of published bytes: requiring the published feed here would make
    the first activation circular, since the release that publishes it will not be
    cut until parity already holds.
    """
    candidate_obj = validate_candidate((CATALOG_DIR / "autotune-candidates.json").read_bytes())
    if from_source:
        # Post-activation the source and the published feed legitimately
        # disagree while a class change is being authored, and the next cut
        # needs the coordinator rows BEFORE it can publish the feed that would
        # make them agree. `--from-source` projects the AUTHORED classes and
        # says so; it never touches published bytes.
        source_obj = validate_artifact_source(ARTIFACT_SOURCE_PATH.read_bytes())
        rate_classes = artifact_rate_classes({"models": source_obj["models"]})
        print(
            "emit-coordinator-rate-card: NOTICE: projecting rate classes from "
            f"{ARTIFACT_SOURCE_PATH.name} (authoring input), not from the published feed",
            file=sys.stderr,
        )
    else:
        rate_classes = authoring_rate_classes()
    rate_card_obj = validate_rate_card(resolve_rate_card(rate_classes, candidate_obj))
    block = coordinator_rate_card_yaml(rate_card_obj)
    if output_path is not None:
        output_path.write_text(block)
        print(f"emit-coordinator-rate-card: wrote {len(rate_card_obj['rows'])} rows to {output_path}")
    else:
        print(block, end="")


RENEWAL_CONTINUITY_FEEDS = ("autotune-candidates.json", "demand-rank.json", RATE_CARD_FEED_NAME)
# The artifact feed carries its release binding in four fields; everything else
# (`source`, `policy_version`, `models`) is catalog CONTENT a freshness renewal
# must not change. `candidate_catalog_sha256` follows the restamped candidate
# bytes, so it is release-derived too.
RENEWAL_ARTIFACT_RELEASE_FIELDS = ("version", "release_id", "generated_at", "candidate_catalog_sha256")


def feed_continuity_drift(incoming: pathlib.Path, live: pathlib.Path) -> list[str]:
    """Freshness-only guard for `renew-autotune-static-feed.sh` (dates-only delta).

    Returns the names of feeds whose CONTENT differs between the staged release
    and the live one once release-derived fields are stripped. The artifact feed
    is compared by presence AND content: a renewal may neither add, drop, nor
    rewrite it — the first artifact-bound release and every model change are
    deliberate catalog release cuts (`docs/runbooks/catalog-artifact-feed-release.md`),
    never the scheduled freshness path. The under-lock recheck on Pearl mirrors
    these rules inline (it has no checkout); keep the two in step.
    """
    drift: list[str] = []

    def stripped(path: pathlib.Path, fields: tuple[str, ...]) -> str:
        obj = strict_json(path.read_bytes(), str(path))
        for field in fields:
            obj.pop(field, None)
        return json.dumps(obj, sort_keys=True)

    for name in RENEWAL_CONTINUITY_FEEDS:
        if stripped(incoming / name, ("version", "generated_at")) != stripped(live / name, ("version", "generated_at")):
            drift.append(name)
    incoming_feed = incoming / ARTIFACT_FEED_NAME
    live_feed = live / ARTIFACT_FEED_NAME
    if incoming_feed.exists() != live_feed.exists():
        drift.append(ARTIFACT_FEED_NAME)
    elif incoming_feed.exists() and stripped(incoming_feed, RENEWAL_ARTIFACT_RELEASE_FIELDS) != stripped(
        live_feed, RENEWAL_ARTIFACT_RELEASE_FIELDS
    ):
        drift.append(ARTIFACT_FEED_NAME)
    return drift


def cmd_continuity_check(incoming: pathlib.Path, live: pathlib.Path) -> None:
    drift = feed_continuity_drift(incoming, live)
    if drift:
        fail(
            "content drift vs live feed in " + ", ".join(drift)
            + " — renewal is freshness-only; a content change needs a reviewed catalog release"
        )
    print("continuity-check: dates-only delta confirmed")


def cmd_status() -> None:
    """Print the artifact-feed activation state and its outstanding prerequisites.

    Stage A is not shippable from this slice alone: the generator can produce and
    bind the feed, but nothing packages, publishes, serves, or live-verifies it
    yet. Printing an explicit "not activatable yet" state — rather than letting a
    green `verify` imply readiness — is what keeps the operator from cutting a
    release whose fifth feed no consumer can fetch.
    """
    candidate_obj = validate_candidate((CATALOG_DIR / "autotune-candidates.json").read_bytes())
    ledger = validate_release_ledger(LEDGER_PATH.read_bytes()) if LEDGER_PATH.exists() else empty_release_ledger()
    release_id = candidate_obj["version"]
    history = release_history(ledger, release_id)
    activated = latest_artifact_bound_release(history)
    published = ARTIFACT_FEED_PATH.exists()
    if activated is not None:
        state = "post-activation"
    elif artifact_bound_row(ledger["releases"].get(release_id)) or published:
        state = "activation (this release)"
    else:
        state = "pre-activation"
    print(f"catalog release      : {release_id}")
    print(f"ledger schema        : {ledger['schema_version']}")
    print(f"artifact-feed state  : {state}")
    print(f"published feed       : {'yes' if published else 'no'} ({ARTIFACT_FEED_PATH})")
    if activated is not None:
        print(f"activated by release : {activated[0]}")
        print("previous release     : --previous-release-dir is REQUIRED for the next cut")
    else:
        print("previous release     : not required (this would be the activation release)")
    print("")
    print("Generator-side activation prerequisites (--activate-artifact-feed refuses on any unmet):")
    prerequisites = artifact_activation_prerequisites(candidate_obj, ledger)
    for satisfied, detail in prerequisites:
        print(f"  [{'x' if satisfied else ' '}] {detail}")
    print("")
    print("Deferred requirements (recorded, not enforced by this slice):")
    for requirement, detail in DEFERRED_REQUIREMENTS:
        print(f"  [ ] {requirement}: {detail}")
    print("")
    print("Distribution surfaces still pending (BYOM v0.2 slices 2b/2c — NOT in this slice):")
    for surface, detail in PENDING_DISTRIBUTION_SURFACES:
        print(f"  [ ] {surface}: {detail}")
    print("")
    if any(not satisfied for satisfied, _ in prerequisites):
        print("NOT ACTIVATABLE: generator-side prerequisites are unmet.")
    elif activated is not None:
        print("ACTIVATED: cut artifact-bound releases with --previous-release-dir.")
    else:
        print(
            "Generator prerequisites are met. Activation additionally requires every "
            "distribution surface above; see docs/runbooks/catalog-artifact-feed-release.md."
        )


def cmd_check_tier2_binding(candidate_path: pathlib.Path, tier2_path: pathlib.Path) -> None:
    check_tier2_binding(candidate_path.read_bytes(), tier2_path.read_bytes())
    print(f"tier2 binding ok: {tier2_path} agrees with {candidate_path}")


def cmd_derive_tier2(
    candidate_path: pathlib.Path,
    output_path: pathlib.Path,
    *,
    catalog_id: str,
    issued_at: str,
    expires_at: str,
) -> None:
    candidate = candidate_path.read_bytes()
    candidate_obj = validate_candidate(candidate)
    # Intentionally fail closed: do not write a mislabeled unsigned body.
    derive_tier2_unsigned_body(
        candidate_obj,
        catalog_id=catalog_id,
        issued_at=issued_at,
        expires_at=expires_at,
    )
    del output_path


def cmd_stage_tier2_republish(
    candidate_path: pathlib.Path,
    binding_path: pathlib.Path,
    template_path: pathlib.Path,
    output_path: pathlib.Path,
) -> None:
    """Stage an UNSIGNED Tier-2 republish body that resolves autotune/Tier-2
    identity drift (#608) for a reviewed `template_path` catalog, using the
    already-generated `tier2-identity-binding.json` as the autotune hash
    source. Fails closed (does not write `output_path`) unless the staged
    result agrees with `candidate_path` on every overlapping model_id, so a
    caller cannot accidentally ship a body that still conflicts."""
    candidate = candidate_path.read_bytes()
    candidate_obj = validate_candidate(candidate)
    binding_data = binding_path.read_bytes()
    validate_tier2_identity_binding(binding_data, candidate, candidate_obj)
    binding_obj = strict_json(binding_data, "tier2 identity binding")
    template_obj = load_tier2_republish_template(template_path.read_bytes())
    staged, changed = stage_tier2_republish(template_obj, binding_obj)
    check_tier2_binding(candidate, staged)
    output_path.write_bytes(staged)
    if changed:
        print("stage-tier2-republish: updated sha256 for " + "; ".join(changed))
    else:
        print("stage-tier2-republish: template already agrees with autotune; no sha256 changes")
    print(
        f"stage-tier2-republish: wrote unsigned body to {output_path} "
        f"(autotune release={candidate_obj['version']!r}, models={len(template_obj['models'])}). "
        "Review the diff, then sign with scripts/sign-catalog.go and republish "
        "through the reviewed deploy path. This output is not a second identity "
        "authority; check-tier2-binding already passed against the pinned candidate."
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    bootstrap_parser = sub.add_parser("bootstrap")
    bootstrap_parser.add_argument("--release-id", required=True)
    bootstrap_parser.add_argument("--generated-at", required=True)
    bootstrap_parser.add_argument("--policy-version", default="autotune-policy-v1")
    restamp_parser = sub.add_parser(
        "restamp",
        help=(
            "re-date the release SOURCE inputs for a freshness-only renewal "
            "(candidate/demand version + generated_at, rate-card source date); "
            "run `generate` afterwards to materialise the published feeds"
        ),
    )
    restamp_parser.add_argument("--release-id", required=True)
    restamp_parser.add_argument("--generated-at", required=True)
    generate_parser = sub.add_parser("generate")
    generate_parser.add_argument("--signer-key-id")
    generate_parser.add_argument(
        "--previous-release-dir",
        type=pathlib.Path,
        help=(
            "previous artifact-bound release directory (release.json + feeds + sidecars); "
            "authenticated against the trusted keyring and the release ledger, and a REQUIRED "
            "input once an EARLIER release has been recorded with the artifact-bound feed set "
            "(SPEC-023 §3.7.4)"
        ),
    )
    generate_parser.add_argument(
        "--activate-artifact-feed",
        action="store_true",
        help=(
            "cut the FIRST artifact-bound release (SPEC-023 §3.7.8 Stage A). Required: "
            "committing autotune-artifacts-source.json never activates the feed on its own. "
            "Refused while any generator-side prerequisite is unmet; see `status`."
        ),
    )
    verify_parser = sub.add_parser("verify")
    verify_parser.add_argument(
        "--previous-release-dir",
        type=pathlib.Path,
        help=(
            "previous artifact-bound release directory, authenticated exactly as `generate` "
            "authenticates it. Supplying it re-derives the SPEC-023 §3.7.8 intake-decision "
            "transition rule (whether intake_decision_sha256 may be null) from the previous "
            "release's candidate admission state. Without it, an artifact-bound release is "
            "verified in every other respect and `verify` prints a NOTICE that the transition "
            "rule was not re-derived"
        ),
    )
    sub.add_parser(
        "status",
        help="print the artifact-feed activation state and its outstanding prerequisites",
    )
    continuity_parser = sub.add_parser(
        "continuity-check",
        help=(
            "freshness-renewal guard: fail unless the staged release differs from the live "
            "release only in release-derived fields (dates, release id, candidate digest); "
            "the artifact feed must match by presence and content"
        ),
    )
    continuity_parser.add_argument("--incoming", type=pathlib.Path, required=True)
    continuity_parser.add_argument("--live", type=pathlib.Path, required=True)
    coordinator_parser = sub.add_parser(
        "emit-coordinator-rate-card",
        help="print the rewards.rate_card: block the published rate card requires",
    )
    coordinator_parser.add_argument("--output", type=pathlib.Path)
    coordinator_parser.add_argument(
        "--from-source",
        action="store_true",
        help=(
            "project rate classes from autotune-artifacts-source.json instead of the published "
            "feed; needed post-activation while a class change is being authored, since the next "
            "cut requires the coordinator rows before it can publish the feed"
        ),
    )
    directory_parser = sub.add_parser(
        "verify-directory",
        help=(
            "verify a staged release directory's feeds, manifest bindings, and signatures. "
            "It has no release ledger and no previous release, so the SPEC-023 §3.7.8 "
            "intake-decision TRANSITION rule is NOT checked here: a hand-assembled release is "
            "checked for transitions only by `verify --previous-release-dir` in the repository "
            "that holds the ledger"
        ),
    )
    directory_parser.add_argument("--directory", required=True, type=pathlib.Path)
    directory_parser.add_argument("--tier2-public-key-file", type=pathlib.Path)
    directory_parser.add_argument("--tier2-coordinator-config", type=pathlib.Path)
    check_parser = sub.add_parser("check-tier2-binding")
    check_parser.add_argument(
        "--candidate",
        type=pathlib.Path,
        default=CATALOG_DIR / "autotune-candidates.json",
        help="autotune-candidates.json path",
    )
    check_parser.add_argument("--tier2", required=True, type=pathlib.Path, help="signed or unsigned tier2-catalog.json")
    derive_parser = sub.add_parser("derive-tier2")
    derive_parser.add_argument(
        "--candidate",
        type=pathlib.Path,
        default=CATALOG_DIR / "autotune-candidates.json",
        help="autotune-candidates.json path",
    )
    derive_parser.add_argument("--output", required=True, type=pathlib.Path)
    derive_parser.add_argument("--catalog-id", required=True)
    derive_parser.add_argument("--issued-at", required=True)
    derive_parser.add_argument("--expires-at", required=True)
    stage_parser = sub.add_parser("stage-tier2-republish")
    stage_parser.add_argument(
        "--candidate",
        type=pathlib.Path,
        default=CATALOG_DIR / "autotune-candidates.json",
        help="autotune-candidates.json path",
    )
    stage_parser.add_argument(
        "--binding",
        type=pathlib.Path,
        default=TIER2_BINDING_PATH,
        help="tier2-identity-binding.json path (must match --candidate)",
    )
    stage_parser.add_argument(
        "--template",
        required=True,
        type=pathlib.Path,
        help="operator-reviewed Tier-2 catalog (signed or unsigned) to project autotune hashes into",
    )
    stage_parser.add_argument("--output", required=True, type=pathlib.Path)
    args = parser.parse_args()
    try:
        if args.command == "bootstrap":
            bootstrap(args.release_id, args.generated_at, args.policy_version)
        elif args.command == "restamp":
            restamp(args.release_id, args.generated_at)
        elif args.command == "generate":
            generate(args.signer_key_id, args.previous_release_dir, args.activate_artifact_feed)
        elif args.command == "verify":
            verify(args.previous_release_dir)
        elif args.command == "status":
            cmd_status()
        elif args.command == "continuity-check":
            cmd_continuity_check(args.incoming, args.live)
        elif args.command == "emit-coordinator-rate-card":
            cmd_emit_coordinator_rate_card(args.output, from_source=args.from_source)
        elif args.command == "verify-directory":
            verify_directory(args.directory, args.tier2_public_key_file, args.tier2_coordinator_config)
        elif args.command == "check-tier2-binding":
            cmd_check_tier2_binding(args.candidate, args.tier2)
        elif args.command == "derive-tier2":
            cmd_derive_tier2(
                args.candidate,
                args.output,
                catalog_id=args.catalog_id,
                issued_at=args.issued_at,
                expires_at=args.expires_at,
            )
        elif args.command == "stage-tier2-republish":
            cmd_stage_tier2_republish(args.candidate, args.binding, args.template, args.output)
        else:
            fail(f"unknown command {args.command!r}")
    except (CatalogError, OSError, subprocess.SubprocessError) as exc:
        print(f"catalog-release: ERROR: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
