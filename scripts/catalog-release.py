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
LEGACY_LEDGER_FEEDS = frozenset({"autotune-candidates.json", "demand-rank.json"})
TIER2_BOUND_LEDGER_FEEDS = LEGACY_LEDGER_FEEDS | {TIER2_CATALOG_FEED_NAME}
HEX64 = re.compile(r"^[0-9a-f]{64}$")
HEX40 = re.compile(r"^[0-9a-f]{40}$")
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


def parse_time(raw: object, label: str) -> None:
    if not isinstance(raw, str) or not RFC3339.fullmatch(raw):
        fail(f"{label}: generated_at must be RFC3339 with an explicit timezone")
    try:
        parsed = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError as exc:
        fail(f"{label}: generated_at must be RFC3339: {exc}")
    if parsed.utcoffset() is None:
        fail(f"{label}: generated_at must include a timezone")


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


def generated_swift(candidate: bytes, demand: bytes, signer_key_id: str | None = None) -> str:
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


def manifest(
    candidate: bytes,
    demand: bytes,
    candidate_obj: dict,
    demand_obj: dict,
    sidecar_directory: pathlib.Path = STATIC_DIR,
    signer_key_id: str | None = None,
    tier2: bytes | None = None,
    tier2_obj: dict | None = None,
    tier2_signer_key_id: str | None = None,
) -> bytes:
    signer_ids = {}
    if signer_key_id is not None:
        signer_ids = {
            "autotune-candidates.json": signer_key_id,
            "demand-rank.json": signer_key_id,
        }
    else:
        for name in ("autotune-candidates.json", "demand-rank.json"):
            sidecar_path = sidecar_directory / f"{name}.sig"
            if sidecar_path.exists():
                signer_ids[name] = parse_sidecar(sidecar_path.read_bytes(), sidecar_path.name)[0]
    feeds = {
        "autotune-candidates.json": {
            "sha256": sha256(candidate), "bytes": len(candidate), "version": candidate_obj["version"],
            "signer_key_id": signer_ids.get("autotune-candidates.json"),
        },
        "demand-rank.json": {
            "sha256": sha256(demand), "bytes": len(demand), "version": demand_obj["version"],
            "signer_key_id": signer_ids.get("demand-rank.json"),
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
    value = {
        "schema_version": "macprovider.autotune-release.v1",
        "release_id": candidate_obj["version"],
        "generated_at": candidate_obj["generated_at"],
        "policy_version": candidate_obj["policy_version"],
        "feeds": feeds,
    }
    return json.dumps(value, indent=2, sort_keys=True).encode("utf-8") + b"\n"


def release_record(manifest_bytes: bytes) -> tuple[str, dict]:
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
    return release_id, record


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
    elif schema_version == "macprovider.autotune-release-ledger.v2":
        exact_keys(value, {"schema_version", "releases", "tombstones"}, {"schema_version", "releases", "tombstones"}, label)
    else:
        fail(f"{label}: invalid schema")
    if not isinstance(value["releases"], dict) or not isinstance(value["tombstones"], dict):
        fail(f"{label}: releases and tombstones must be objects")
    overlapping_release_ids = set(value["releases"]).intersection(value["tombstones"])
    if overlapping_release_ids:
        release_id = sorted(overlapping_release_ids)[0]
        fail(f"{label}: release ID {release_id!r} cannot be both published and tombstoned")
    for release_id, record in value["releases"].items():
        if not isinstance(release_id, str) or not release_id or not isinstance(record, dict):
            fail(f"{label}: invalid release entry {release_id!r}")
        exact_keys(record, {"generated_at", "policy_version", "feeds"}, {"generated_at", "policy_version", "feeds"}, f"{label} release {release_id}")
        if not isinstance(record["generated_at"], str) or (record["policy_version"] is not None and not isinstance(record["policy_version"], str)) or not isinstance(record["feeds"], dict):
            fail(f"{label}: invalid release entry {release_id!r}")
        parse_time(record["generated_at"], f"{label} release {release_id}")
        feed_names = set(record["feeds"])
        # Historical-safe: releases published before #608 Tier-2 ledger
        # membership keep their original 2-feed shape. Only the 3-feed shape
        # (with tier2-catalog.json bound) is accepted for anything new.
        if feed_names not in (LEGACY_LEDGER_FEEDS, TIER2_BOUND_LEDGER_FEEDS):
            fail(
                f"{label}: release {release_id!r} feeds must be exactly "
                f"{sorted(LEGACY_LEDGER_FEEDS)} (historical) or "
                f"{sorted(TIER2_BOUND_LEDGER_FEEDS)} (Tier-2 bound)"
            )
        for feed_name, feed in record["feeds"].items():
            validate_ledger_feed(feed, f"{label} release {release_id} {feed_name}")
            # tier2-catalog.json is versioned by its own catalog_id, not the
            # autotune release train (see manifest()).
            if feed_name != TIER2_CATALOG_FEED_NAME and feed["version"] != release_id:
                fail(f"{label}: feed version does not match release ID {release_id!r}")
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
    return {"releases": value["releases"], "tombstones": value["tombstones"]}


def ledger_bytes(ledger: dict[str, dict]) -> bytes:
    value = {
        "schema_version": "macprovider.autotune-release-ledger.v2",
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


def require_ledger_evolution(base: dict[str, dict], current: dict[str, dict]) -> None:
    for release_id, base_record in base["releases"].items():
        if release_id not in current["releases"]:
            fail(f"release ledger: published release {release_id!r} was removed")
        if current["releases"][release_id] != base_record and not is_tier2_enrichment(base_record, current["releases"][release_id]):
            fail(f"release ledger: published release {release_id!r} was rebound to different content")
    for release_id, base_tombstone in base["tombstones"].items():
        if release_id not in current["tombstones"]:
            fail(f"release ledger: tombstone {release_id!r} was removed")
        if current["tombstones"][release_id] != base_tombstone:
            fail(f"release ledger: tombstone {release_id!r} was changed")
    for release_id, current_record in current["releases"].items():
        if set(current_record["feeds"]) == LEGACY_LEDGER_FEEDS and current_record != base["releases"].get(release_id):
            fail(
                f"release ledger: new release {release_id!r} is missing mandatory "
                f"{TIER2_CATALOG_FEED_NAME!r} feed membership"
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
        return {"releases": {}, "tombstones": {}}
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


def updated_release_ledger(manifest_bytes: bytes) -> bytes:
    current = validate_release_ledger(LEDGER_PATH.read_bytes()) if LEDGER_PATH.exists() else {"releases": {}, "tombstones": {}}
    require_ledger_evolution(base_release_ledger(), current)
    release_id, record = release_record(manifest_bytes)
    if release_id in current["tombstones"]:
        fail(f"release ledger: release ID {release_id!r} is permanently rejected")
    existing = current["releases"].get(release_id)
    if existing is not None and existing != record and not is_tier2_enrichment(existing, record):
        fail(f"release ledger: release ID {release_id!r} is already bound to different content")
    updated = {
        "releases": dict(current["releases"]),
        "tombstones": dict(current["tombstones"]),
    }
    updated["releases"][release_id] = record
    require_ledger_evolution(current, updated)
    return ledger_bytes(updated)


def generate(signer_key_id: str | None = None) -> None:
    candidate_path = CATALOG_DIR / "autotune-candidates.json"
    demand_path = CATALOG_DIR / "demand-rank.json"
    candidate_obj = validate_candidate(candidate_path.read_bytes(), require_provenance=True)
    demand_obj = validate_demand(demand_path.read_bytes())
    validate_pair(candidate_obj, demand_obj)
    candidate = canonical_bytes(candidate_obj)
    demand = canonical_bytes(demand_obj)
    if signer_key_id is not None and signer_key_id not in keyring():
        fail(f"cannot generate for unknown or retired signer key ID: {signer_key_id}")
    tier2, tier2_obj, tier2_signer_key_id = require_tier2_catalog()
    check_tier2_binding(candidate, tier2)
    # Compute every derived artifact before mutating on-disk release state so a
    # binding/derivation failure cannot leave a partially updated ledger.
    manifest_bytes = manifest(
        candidate, demand, candidate_obj, demand_obj,
        signer_key_id=signer_key_id, tier2=tier2, tier2_obj=tier2_obj,
        tier2_signer_key_id=tier2_signer_key_id,
    )
    binding_bytes = derive_tier2_identity_binding(candidate, candidate_obj)
    swift_text = generated_swift(candidate, demand, signer_key_id)
    next_ledger = updated_release_ledger(manifest_bytes)
    rejected_go = generated_rejected_releases_go(validate_release_ledger(next_ledger))
    CATALOG_DIR.mkdir(parents=True, exist_ok=True)
    STATIC_DIR.mkdir(parents=True, exist_ok=True)
    candidate_path.write_bytes(candidate)
    demand_path.write_bytes(demand)
    (STATIC_DIR / "autotune-candidates.json").write_bytes(candidate)
    (STATIC_DIR / "demand-rank.json").write_bytes(demand)
    SWIFT_GENERATED.write_text(swift_text)
    MANIFEST_PATH.write_bytes(manifest_bytes)
    LEDGER_PATH.write_bytes(next_ledger)
    TIER2_BINDING_PATH.write_bytes(binding_bytes)
    GO_REJECTED_RELEASES_GENERATED.write_text(rejected_go)
    print(
        f"generated catalog release {candidate_obj['version']} "
        f"candidate={sha256(candidate)} demand={sha256(demand)} "
        f"tier2_binding={sha256(binding_bytes)} tier2_catalog={sha256(tier2)}"
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


def verify() -> None:
    candidate_path = CATALOG_DIR / "autotune-candidates.json"
    demand_path = CATALOG_DIR / "demand-rank.json"
    candidate = candidate_path.read_bytes()
    demand = demand_path.read_bytes()
    candidate_obj = validate_candidate(candidate)
    demand_obj = validate_demand(demand)
    validate_pair(candidate_obj, demand_obj)
    if candidate != canonical_bytes(candidate_obj) or demand != canonical_bytes(demand_obj):
        fail("canonical feed files must use deterministic compact JSON with no trailing newline")
    expected = {
        STATIC_DIR / "autotune-candidates.json": candidate,
        STATIC_DIR / "demand-rank.json": demand,
    }
    for path, body in expected.items():
        if path.read_bytes() != body:
            fail(f"generated drift: {path}")
    if SWIFT_GENERATED.read_text() != generated_swift(candidate, demand):
        fail(f"generated drift: {SWIFT_GENERATED}")
    tier2, tier2_obj, tier2_signer_key_id = require_tier2_catalog()
    check_tier2_binding(candidate, tier2)
    expected_manifest = manifest(
        candidate, demand, candidate_obj, demand_obj,
        tier2=tier2, tier2_obj=tier2_obj, tier2_signer_key_id=tier2_signer_key_id,
    )
    if MANIFEST_PATH.read_bytes() != expected_manifest:
        fail(f"generated drift: {MANIFEST_PATH}")
    ledger = validate_release_ledger(LEDGER_PATH.read_bytes())
    require_ledger_evolution(base_release_ledger(), ledger)
    release_id, record = release_record(expected_manifest)
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
        f"candidate={sha256(candidate)} demand={sha256(demand)} "
        f"tier2_binding={sha256(TIER2_BINDING_PATH.read_bytes())} tier2_catalog={sha256(tier2)}"
    )


def verify_directory(
    directory: pathlib.Path,
    tier2_public_key_file: pathlib.Path | None = None,
    tier2_coordinator_config: pathlib.Path | None = None,
) -> None:
    candidate_path = directory / "autotune-candidates.json"
    demand_path = directory / "demand-rank.json"
    candidate = candidate_path.read_bytes()
    demand = demand_path.read_bytes()
    candidate_obj = validate_candidate(candidate)
    demand_obj = validate_demand(demand)
    validate_pair(candidate_obj, demand_obj)
    if candidate != canonical_bytes(candidate_obj) or demand != canonical_bytes(demand_obj):
        fail("release directory feeds are not deterministic canonical bytes")
    tier2_path = directory / "tier2-catalog.json"
    if not tier2_path.exists():
        fail("release directory is missing required tier2-catalog.json feed")
    tier2 = tier2_path.read_bytes()
    tier2_obj = validate_tier2_catalog(tier2)
    tier2_signer_key_id = verify_tier2_signature(tier2, tier2_public_key_file, tier2_coordinator_config)
    check_tier2_binding(candidate, tier2)
    expected_manifest = manifest(
        candidate, demand, candidate_obj, demand_obj, directory,
        tier2=tier2, tier2_obj=tier2_obj, tier2_signer_key_id=tier2_signer_key_id,
    )
    if (directory / "release.json").read_bytes() != expected_manifest:
        fail("release directory manifest does not bind the feed bytes")
    keys = keyring(directory / "trusted-keys.json")
    for path, body in ((candidate_path, candidate), (demand_path, demand)):
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
    print(f"verified release directory {candidate_obj['version']} candidate={sha256(candidate)} demand={sha256(demand)}")


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
    generate_parser = sub.add_parser("generate")
    generate_parser.add_argument("--signer-key-id")
    sub.add_parser("verify")
    directory_parser = sub.add_parser("verify-directory")
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
        elif args.command == "generate":
            generate(args.signer_key_id)
        elif args.command == "verify":
            verify()
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
