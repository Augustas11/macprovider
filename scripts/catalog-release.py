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
from datetime import datetime


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
HEX64 = re.compile(r"^[0-9a-f]{64}$")
HEX40 = re.compile(r"^[0-9a-f]{40}$")
MODEL_KEY = re.compile(r"^[a-z0-9][a-z0-9._/-]{0,127}$")
MODEL_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$")
RFC3339 = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$")
INT64_MIN = -(2**63)
INT64_MAX = 2**63 - 1
OPENSSL_PROBE_TIMEOUT_SECONDS = 5
OPENSSL_VERIFY_TIMEOUT_SECONDS = 15


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


def validate_candidate(data: bytes) -> dict:
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
        exact_keys(gate, {"min_sustained_tps", "max_4k_ttft_ms"}, {"min_sustained_tps", "max_4k_ttft_ms"}, f"candidate row {key} bench_gate")
        if not isinstance(gate["min_sustained_tps"], (int, float)) or isinstance(gate["min_sustained_tps"], bool) or not math.isfinite(gate["min_sustained_tps"]) or gate["min_sustained_tps"] < 0:
            fail(f"candidate row {key}: invalid min_sustained_tps")
        if not isinstance(gate["max_4k_ttft_ms"], int) or isinstance(gate["max_4k_ttft_ms"], bool) or gate["max_4k_ttft_ms"] < 0:
            fail(f"candidate row {key}: invalid max_4k_ttft_ms")
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
    value = {
        "schema_version": "macprovider.autotune-release.v1",
        "release_id": candidate_obj["version"],
        "generated_at": candidate_obj["generated_at"],
        "policy_version": candidate_obj["policy_version"],
        "feeds": {
            "autotune-candidates.json": {
                "sha256": sha256(candidate), "bytes": len(candidate), "version": candidate_obj["version"],
                "signer_key_id": signer_ids.get("autotune-candidates.json"),
            },
            "demand-rank.json": {
                "sha256": sha256(demand), "bytes": len(demand), "version": demand_obj["version"],
                "signer_key_id": signer_ids.get("demand-rank.json"),
            },
        },
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
        expected_feeds = {"autotune-candidates.json", "demand-rank.json"}
        exact_keys(record["feeds"], expected_feeds, expected_feeds, f"{label} release {release_id} feeds")
        for feed_name, feed in record["feeds"].items():
            validate_ledger_feed(feed, f"{label} release {release_id} {feed_name}")
            if feed["version"] != release_id:
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


def require_ledger_evolution(base: dict[str, dict], current: dict[str, dict]) -> None:
    for release_id, base_record in base["releases"].items():
        if release_id not in current["releases"]:
            fail(f"release ledger: published release {release_id!r} was removed")
        if current["releases"][release_id] != base_record:
            fail(f"release ledger: published release {release_id!r} was rebound to different content")
    for release_id, base_tombstone in base["tombstones"].items():
        if release_id not in current["tombstones"]:
            fail(f"release ledger: tombstone {release_id!r} was removed")
        if current["tombstones"][release_id] != base_tombstone:
            fail(f"release ledger: tombstone {release_id!r} was changed")


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


def updated_release_ledger(manifest_bytes: bytes) -> bytes:
    current = validate_release_ledger(LEDGER_PATH.read_bytes()) if LEDGER_PATH.exists() else {"releases": {}, "tombstones": {}}
    require_ledger_evolution(base_release_ledger(), current)
    release_id, record = release_record(manifest_bytes)
    if release_id in current["tombstones"]:
        fail(f"release ledger: release ID {release_id!r} is permanently rejected")
    existing = current["releases"].get(release_id)
    if existing is not None and existing != record:
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
    candidate_obj = validate_candidate(candidate_path.read_bytes())
    demand_obj = validate_demand(demand_path.read_bytes())
    validate_pair(candidate_obj, demand_obj)
    candidate = canonical_bytes(candidate_obj)
    demand = canonical_bytes(demand_obj)
    if signer_key_id is not None and signer_key_id not in keyring():
        fail(f"cannot generate for unknown or retired signer key ID: {signer_key_id}")
    # Compute every derived artifact before mutating on-disk release state so a
    # binding/derivation failure cannot leave a partially updated ledger.
    manifest_bytes = manifest(candidate, demand, candidate_obj, demand_obj, signer_key_id=signer_key_id)
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
        f"tier2_binding={sha256(binding_bytes)}"
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
    expected_manifest = manifest(candidate, demand, candidate_obj, demand_obj)
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
        f"tier2_binding={sha256(TIER2_BINDING_PATH.read_bytes())}"
    )


def verify_directory(directory: pathlib.Path) -> None:
    candidate_path = directory / "autotune-candidates.json"
    demand_path = directory / "demand-rank.json"
    candidate = candidate_path.read_bytes()
    demand = demand_path.read_bytes()
    candidate_obj = validate_candidate(candidate)
    demand_obj = validate_demand(demand)
    validate_pair(candidate_obj, demand_obj)
    if candidate != canonical_bytes(candidate_obj) or demand != canonical_bytes(demand_obj):
        fail("release directory feeds are not deterministic canonical bytes")
    expected_manifest = manifest(candidate, demand, candidate_obj, demand_obj, directory)
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
    tier2_path = directory / "tier2-catalog.json"
    if tier2_path.exists():
        # Digest overlap check only — this does not replace sign-catalog.go verify.
        check_tier2_binding(candidate, tier2_path.read_bytes())
        print(f"verified tier2 digest binding against release {candidate_obj['version']}")
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
    args = parser.parse_args()
    try:
        if args.command == "bootstrap":
            bootstrap(args.release_id, args.generated_at, args.policy_version)
        elif args.command == "generate":
            generate(args.signer_key_id)
        elif args.command == "verify":
            verify()
        elif args.command == "verify-directory":
            verify_directory(args.directory)
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
        else:
            fail(f"unknown command {args.command!r}")
    except (CatalogError, OSError, subprocess.SubprocessError) as exc:
        print(f"catalog-release: ERROR: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
