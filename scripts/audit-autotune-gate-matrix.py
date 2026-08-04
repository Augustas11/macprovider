#!/usr/bin/env python3
"""Audit trusted post-#745 autotune evidence before catalog gate refresh.

This command is intentionally read-only.  It verifies that an operator export
claims enough trusted hardware evidence to *consider* re-deriving every
recommendable catalog row; it never authenticates the export or writes new
threshold values. The export must come from an authenticated verifier/DB path.
"""

from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import hashlib
import importlib.util
import io
import json
import math
import os
import posixpath
import pathlib
import re
import stat
import sys
from typing import Any

SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
CATALOG_RELEASE_PATH = SCRIPT_DIR / "catalog-release.py"
_catalog_spec = importlib.util.spec_from_file_location("catalog_release", CATALOG_RELEASE_PATH)
if _catalog_spec is None or _catalog_spec.loader is None:  # pragma: no cover - packaging failure
    raise ImportError(f"cannot load {CATALOG_RELEASE_PATH}")
catalog_release = importlib.util.module_from_spec(_catalog_spec)
_catalog_spec.loader.exec_module(catalog_release)


MATRIX_SCHEMA = "macprovider.autotune-gate-matrix.v1"
AUDIT_SCHEMA = "macprovider.autotune-gate-audit.v1"
VERIFIED_DECISION_REASON = "hardware-verifier.v2:verified_trusted_hardware"
MIN_PROVIDERS = 3
MIN_HARDWARE_CLASSES = 2
ACTIVE_STATUSES = {"candidate", "listed", "recommendable"}
HARDWARE_TIERS = {"A", "B", "C", "S"}
TIER_RANK = {"C": 0, "B": 1, "A": 2, "S": 3}
SAFETY_MARGIN_GB = 4
POST_745_CUTOFF = dt.datetime(2026, 7, 25, 18, 5, tzinfo=dt.timezone.utc)
MAX_MATRIX_BYTES = 16 * 1024 * 1024
MAX_PROVIDERS = 256
MAX_BENCHMARKS_PER_PROVIDER = 64
MAX_TOTAL_BENCHMARKS = 64 * 1024
MAX_ARTIFACT_PATH_BYTES = 4096


class AuditError(RuntimeError):
    pass


def fail(message: str) -> None:
    raise AuditError(message)


def exact_keys(value: dict[str, Any], allowed: set[str], required: set[str], label: str) -> None:
    keys = set(value)
    missing = required - keys
    unknown = keys - allowed
    if missing:
        fail(f"{label}: missing fields {sorted(missing)}")
    if unknown:
        fail(f"{label}: unknown fields {sorted(unknown)}")


def parse_time(raw: object, label: str) -> dt.datetime:
    if not isinstance(raw, str) or not catalog_release.RFC3339.fullmatch(raw):
        fail(f"{label}: expected RFC3339 timestamp with timezone")
    try:
        parsed = dt.datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError as exc:
        fail(f"{label}: invalid RFC3339 timestamp: {exc}")
    if parsed.tzinfo is None:
        fail(f"{label}: timestamp must include timezone")
    return parsed.astimezone(dt.timezone.utc)


def non_empty_string(value: object, label: str) -> str:
    if not isinstance(value, str) or not value.strip():
        fail(f"{label}: expected a non-empty string")
    return value


def is_sha256(value: object) -> bool:
    return isinstance(value, str) and catalog_release.HEX64.fullmatch(value) is not None


def row_identity(row_key: str, row: dict[str, Any], policy_version: str) -> str:
    """Mirror the current Swift/Go identity for rows without policy profiles.

    Policy-bearing rows deliberately fail closed here until the audit exporter
    can share the repository's RFC 8785 implementation rather than creating a
    third identity implementation.
    """

    if row.get("draft_candidates") is not None or row.get("workload_profiles") is not None:
        fail(f"candidate row {row_key}: policy-bearing row identity requires the verifier exporter")
    fields = [
        policy_version,
        row_key,
        row["model_id"],
        row.get("model_revision") or "",
        row.get("model_sha256") or "",
        str(row["min_ram_gb"]),
        row["min_bandwidth_tier"],
        f"{row['bench_gate']['min_sustained_tps']:.6f}",
        str(row["bench_gate"]["max_4k_ttft_ms"]),
        row["runtime_status"],
    ]
    framed = "|".join(f"{len(field.encode('utf-8'))}:{field}" for field in fields)
    return hashlib.sha256(framed.encode("utf-8")).hexdigest()


def normalize_chip(chip: str) -> str:
    normalized = " ".join(chip.strip().lower().split())
    return normalized.removeprefix("apple ")


def derive_bandwidth_tier(chip: str) -> str:
    normalized = normalize_chip(chip)
    generation_match = re.search(r"m([0-9]+)", normalized)
    generation = int(generation_match.group(1)) if generation_match else None
    if "ultra" in normalized:
        if generation is not None:
            return "S" if generation >= 3 else "A"
        if "m3" in normalized or "m4" in normalized:
            return "S"
        if "m1" in normalized or "m2" in normalized:
            return "A"
        return "S"
    if "max" in normalized:
        if generation is not None:
            return "A" if generation >= 3 else "B"
        return "A"
    if "pro" in normalized:
        return "B"
    return "C"


def load_candidate(path: pathlib.Path) -> tuple[bytes, dict[str, Any], str]:
    expected_path = (catalog_release.CATALOG_DIR / "autotune-candidates.json").resolve()
    if path.resolve() != expected_path:
        fail("candidate catalog must be the repository's current release candidate")
    raw = path.read_bytes()
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            catalog_release.verify()
    except (catalog_release.CatalogError, OSError, ValueError) as exc:
        fail(f"candidate catalog release authentication failed: {exc}")
    sidecar_path = catalog_release.STATIC_DIR / "autotune-candidates.json.sig"
    key_id, signature = catalog_release.parse_sidecar(sidecar_path.read_bytes(), sidecar_path.name)
    public_key = catalog_release.keyring().get(key_id)
    if public_key is None:
        fail(f"{sidecar_path.name}: unknown or retired key_id {key_id}")
    catalog_release.verify_ed25519(public_key, signature, raw, sidecar_path.name)
    value = catalog_release.validate_candidate(raw, require_provenance=True)
    canonical = catalog_release.canonical_bytes(value)
    if raw != canonical:
        fail(f"candidate catalog is not deterministic canonical JSON: {path}")
    return raw, value, hashlib.sha256(raw).hexdigest()


def validate_hardware(value: object, label: str) -> tuple[str, int, str, str, str]:
    if not isinstance(value, dict):
        fail(f"{label}: expected object")
    exact_keys(
        value,
        {"chip", "memory_gb", "bandwidth_tier", "detected", "os_version", "binary_version", "hardware_identity_hash", "executable_sha256"},
        {"chip", "memory_gb", "bandwidth_tier", "detected", "os_version", "binary_version", "hardware_identity_hash", "executable_sha256"},
        label,
    )
    chip = non_empty_string(value["chip"], f"{label}.chip")
    os_version = non_empty_string(value["os_version"], f"{label}.os_version")
    binary_version = non_empty_string(value["binary_version"], f"{label}.binary_version")
    if not isinstance(value["memory_gb"], int) or isinstance(value["memory_gb"], bool) or not 0 < value["memory_gb"] <= 4096:
        fail(f"{label}.memory_gb: expected an integer from 1 through 4096")
    if value["bandwidth_tier"] not in HARDWARE_TIERS:
        fail(f"{label}.bandwidth_tier: invalid tier")
    derived_tier = derive_bandwidth_tier(chip)
    if value["bandwidth_tier"] != derived_tier:
        fail(f"{label}.bandwidth_tier: {value['bandwidth_tier']!r} does not match chip-derived tier {derived_tier!r}")
    if value["detected"] is not True:
        fail(f"{label}.detected: trusted matrix requires detected hardware")
    if not is_sha256(value["hardware_identity_hash"]):
        fail(f"{label}.hardware_identity_hash: expected lowercase SHA-256")
    if not is_sha256(value["executable_sha256"]):
        fail(f"{label}.executable_sha256: expected lowercase SHA-256")
    hardware_class = f"{normalize_chip(chip)}:{value['memory_gb']}gb:{value['bandwidth_tier']}"
    return hardware_class, value["memory_gb"], value["bandwidth_tier"], binary_version, value["hardware_identity_hash"]


def hardware_fits_row(row: dict[str, Any], memory_gb: int, bandwidth_tier: str) -> bool:
    return (
        row["min_ram_gb"] <= memory_gb - SAFETY_MARGIN_GB
        and TIER_RANK[bandwidth_tier] >= TIER_RANK[row["min_bandwidth_tier"]]
    )


def validate_benchmark(
    benchmark: object,
    *,
    label: str,
    evidence_catalog_sha: str,
    binary_version: str,
    hardware_identity_hash: str,
    min_generated_at: dt.datetime,
    max_generated_at: dt.datetime,
    candidate: dict[str, Any],
) -> tuple[str, float, int]:
    if not isinstance(benchmark, dict):
        fail(f"{label}: expected object")
    exact_keys(
        benchmark,
        {
            "model_key",
            "model_id",
            "model_artifact_path",
            "sustained_tps",
            "ttft_ms",
            "swap_detected",
            "thermal_throttle_detected",
            "artifact_sha256",
            "candidate_catalog_sha256",
            "candidate_row_identity",
            "benchmark_id",
            "generated_at",
            "binary_version",
            "hardware_identity_hash",
        },
        {
            "model_key",
            "model_id",
            "sustained_tps",
            "ttft_ms",
            "swap_detected",
            "thermal_throttle_detected",
            "artifact_sha256",
            "candidate_catalog_sha256",
            "generated_at",
            "binary_version",
            "hardware_identity_hash",
            "candidate_row_identity",
            "model_artifact_path",
        },
        label,
    )
    model_key = non_empty_string(benchmark["model_key"], f"{label}.model_key")
    row = candidate["rows"].get(model_key)
    if row is None:
        fail(f"{label}: model_key {model_key!r} is absent from the candidate catalog")
    if benchmark["model_id"] != row["model_id"]:
        fail(f"{label}: model_id does not match catalog row {model_key!r}")
    if not isinstance(benchmark["sustained_tps"], (int, float)) or isinstance(benchmark["sustained_tps"], bool) or not math.isfinite(benchmark["sustained_tps"]) or benchmark["sustained_tps"] <= 0:
        fail(f"{label}.sustained_tps: expected a finite positive number")
    if not isinstance(benchmark["ttft_ms"], int) or isinstance(benchmark["ttft_ms"], bool) or benchmark["ttft_ms"] <= 0:
        fail(f"{label}.ttft_ms: expected a positive integer")
    if benchmark["swap_detected"] is not False or benchmark["thermal_throttle_detected"] is not False:
        fail(f"{label}: swap/thermal evidence cannot promote a catalog gate")
    if benchmark["artifact_sha256"] != row.get("model_sha256") or not is_sha256(benchmark["artifact_sha256"]):
        fail(f"{label}: artifact_sha256 does not match the catalog row")
    if benchmark["candidate_catalog_sha256"] != evidence_catalog_sha:
        fail(f"{label}: candidate_catalog_sha256 does not match the matrix catalog")
    if benchmark["binary_version"] != binary_version:
        fail(f"{label}: binary_version does not match the hardware envelope")
    if benchmark["hardware_identity_hash"] != hardware_identity_hash:
        fail(f"{label}: hardware_identity_hash does not match the hardware envelope")
    if not is_sha256(benchmark["candidate_row_identity"]):
        fail(f"{label}.candidate_row_identity: expected lowercase SHA-256")
    artifact_path = non_empty_string(benchmark["model_artifact_path"], f"{label}.model_artifact_path")
    if len(artifact_path.encode("utf-8")) > MAX_ARTIFACT_PATH_BYTES or artifact_path == "/" or "\x00" in artifact_path or artifact_path.startswith("//") or not artifact_path.startswith("/") or posixpath.normpath(artifact_path) != artifact_path:
        fail(f"{label}.model_artifact_path: expected an absolute normalized local path")
    if "benchmark_id" in benchmark:
        non_empty_string(benchmark["benchmark_id"], f"{label}.benchmark_id")
    expected_identity = row_identity(model_key, row, candidate["policy_version"])
    if benchmark["candidate_row_identity"] != expected_identity:
        fail(f"{label}: candidate_row_identity does not match the current catalog row")
    generated_at = parse_time(benchmark["generated_at"], f"{label}.generated_at")
    if generated_at < min_generated_at:
        fail(f"{label}: benchmark predates the post-#745 cutoff")
    if generated_at > max_generated_at:
        fail(f"{label}: benchmark is newer than its enclosing evidence export")
    return model_key, float(benchmark["sustained_tps"]), int(benchmark["ttft_ms"])


def audit_matrix(
    candidate_path: pathlib.Path,
    matrix_path: pathlib.Path,
    min_generated_at_raw: str,
    as_of_raw: str,
) -> dict[str, Any]:
    _, candidate, candidate_sha = load_candidate(candidate_path)
    min_generated_at = parse_time(min_generated_at_raw, "--min-generated-at")
    if min_generated_at < POST_745_CUTOFF:
        fail("--min-generated-at must not precede the canonical #745 merge cutoff")
    as_of = parse_time(as_of_raw, "--as-of")
    if as_of < min_generated_at:
        fail("--as-of must be at or after --min-generated-at")
    flags = os.O_RDONLY | os.O_NONBLOCK
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    file_descriptor: int | None = None
    try:
        file_descriptor = os.open(matrix_path, flags)
        metadata = os.fstat(file_descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            fail("gate matrix: input must be a regular file")
        if metadata.st_size > MAX_MATRIX_BYTES:
            fail(f"gate matrix: file exceeds {MAX_MATRIX_BYTES} byte limit")
        with os.fdopen(file_descriptor, "rb") as matrix_file:
            file_descriptor = None
            matrix_bytes = matrix_file.read(MAX_MATRIX_BYTES + 1)
        if len(matrix_bytes) > MAX_MATRIX_BYTES:
            fail(f"gate matrix: file exceeds {MAX_MATRIX_BYTES} byte limit")
    finally:
        if file_descriptor is not None:
            os.close(file_descriptor)
    matrix = catalog_release.strict_json(matrix_bytes, "gate matrix")
    exact_keys(matrix, {"schema_version", "source", "generated_at", "candidate_catalog_sha256", "providers"}, {"schema_version", "source", "generated_at", "candidate_catalog_sha256", "providers"}, "gate matrix")
    if matrix["schema_version"] != MATRIX_SCHEMA or matrix["source"] != "hardware_verifier_export":
        fail("gate matrix: unsupported schema or source")
    matrix_generated_at = parse_time(matrix["generated_at"], "gate matrix.generated_at")
    if matrix_generated_at < min_generated_at:
        fail("gate matrix.generated_at: export predates the post-#745 cutoff")
    if matrix_generated_at > as_of:
        fail("gate matrix.generated_at: export is newer than --as-of")
    if matrix["candidate_catalog_sha256"] != candidate_sha:
        fail("gate matrix: candidate_catalog_sha256 does not match the candidate catalog")
    providers = matrix["providers"]
    if not isinstance(providers, list) or not providers:
        fail("gate matrix.providers: expected a non-empty array")
    if len(providers) > MAX_PROVIDERS:
        fail(f"gate matrix.providers: exceeds {MAX_PROVIDERS} provider limit")

    seen_providers: set[str] = set()
    classes: set[str] = set()
    total_benchmarks = 0
    observations: dict[str, list[tuple[str, str, float, int]]] = {key: [] for key, row in candidate["rows"].items() if row["runtime_status"] in ACTIVE_STATUSES}
    ineligible_samples: dict[str, int] = {key: 0 for key in observations}
    for index, provider in enumerate(providers):
        label = f"gate matrix.providers[{index}]"
        if not isinstance(provider, dict):
            fail(f"{label}: expected object")
        exact_keys(provider, {"provider_id", "verification", "evidence"}, {"provider_id", "verification", "evidence"}, label)
        provider_id = non_empty_string(provider["provider_id"], f"{label}.provider_id")
        if provider_id in seen_providers:
            fail(f"{label}: duplicate provider_id {provider_id!r}")
        seen_providers.add(provider_id)
        verification = provider["verification"]
        if not isinstance(verification, dict):
            fail(f"{label}.verification: expected object")
        exact_keys(verification, {"status", "decision_reason"}, {"status", "decision_reason"}, f"{label}.verification")
        if verification["status"] != "verified" or verification["decision_reason"] != VERIFIED_DECISION_REASON:
            fail(f"{label}.verification: provider is not trusted hardware evidence")
        evidence = provider["evidence"]
        if not isinstance(evidence, dict):
            fail(f"{label}.evidence: expected object")
        exact_keys(evidence, {"schema_version", "provider_id", "generated_at", "hardware", "candidate_catalog_sha256", "recommended_model", "probe_protocol", "benchmarks"}, {"schema_version", "provider_id", "generated_at", "hardware", "candidate_catalog_sha256", "recommended_model", "probe_protocol", "benchmarks"}, f"{label}.evidence")
        if evidence["schema_version"] != "hardware_evidence.autotune.v2" or evidence["probe_protocol"] != "spec-023-harmony-stream.v2" or evidence["provider_id"] != provider_id:
            fail(f"{label}.evidence: unsupported schema or provider binding")
        evidence_generated_at = parse_time(evidence["generated_at"], f"{label}.evidence.generated_at")
        if evidence_generated_at < min_generated_at:
            fail(f"{label}.evidence: evidence predates the post-#745 cutoff")
        if evidence_generated_at > matrix_generated_at:
            fail(f"{label}.evidence: evidence is newer than the matrix export")
        if evidence["candidate_catalog_sha256"] != candidate_sha:
            fail(f"{label}.evidence: candidate_catalog_sha256 does not match the candidate catalog")
        non_empty_string(evidence["recommended_model"], f"{label}.evidence.recommended_model")
        hardware_class, memory_gb, bandwidth_tier, binary_version, hardware_identity_hash = validate_hardware(evidence["hardware"], f"{label}.evidence.hardware")
        classes.add(hardware_class)
        benchmarks = evidence["benchmarks"]
        if not isinstance(benchmarks, list) or not benchmarks:
            fail(f"{label}.evidence.benchmarks: expected a non-empty array")
        if len(benchmarks) > MAX_BENCHMARKS_PER_PROVIDER:
            fail(f"{label}.evidence.benchmarks: exceeds {MAX_BENCHMARKS_PER_PROVIDER} benchmark limit")
        total_benchmarks += len(benchmarks)
        if total_benchmarks > MAX_TOTAL_BENCHMARKS:
            fail(f"gate matrix: exceeds {MAX_TOTAL_BENCHMARKS} total benchmark limit")
        seen_models: set[str] = set()
        for benchmark_index, benchmark in enumerate(benchmarks):
            model_key, tps, ttft = validate_benchmark(
                benchmark,
                label=f"{label}.evidence.benchmarks[{benchmark_index}]",
                evidence_catalog_sha=candidate_sha,
                binary_version=binary_version,
                hardware_identity_hash=hardware_identity_hash,
                min_generated_at=min_generated_at,
                max_generated_at=evidence_generated_at,
                candidate=candidate,
            )
            if model_key in seen_models:
                fail(f"{label}.evidence: duplicate benchmark for model {model_key!r}")
            seen_models.add(model_key)
            if model_key in observations:
                if hardware_fits_row(candidate["rows"][model_key], memory_gb, bandwidth_tier):
                    observations[model_key].append((provider_id, hardware_class, tps, ttft))
                else:
                    ineligible_samples[model_key] += 1

    rows: dict[str, dict[str, Any]] = {}
    blockers: list[str] = []
    for model_key in sorted(observations):
        row = candidate["rows"][model_key]
        samples = observations[model_key]
        provider_count = len({sample[0] for sample in samples})
        class_count = len({sample[1] for sample in samples})
        row_blockers: list[str] = []
        if provider_count < MIN_PROVIDERS:
            row_blockers.append(f"provider_quorum:{provider_count}/{MIN_PROVIDERS}")
        if class_count < MIN_HARDWARE_CLASSES:
            row_blockers.append(f"hardware_class_quorum:{class_count}/{MIN_HARDWARE_CLASSES}")
        if not samples and not ineligible_samples[model_key]:
            row_blockers.append("no_post_745_benchmark")
        row_warnings: list[str] = []
        if ineligible_samples[model_key]:
            row_warnings.append(f"hardware_ineligible_samples:{ineligible_samples[model_key]}")
        if row_blockers:
            blockers.extend(f"{model_key}:{reason}" for reason in row_blockers)
        rows[model_key] = {
            "current_gate": row["bench_gate"],
            "sample_count": len(samples),
            "provider_count": provider_count,
            "hardware_class_count": class_count,
            "observed_min_sustained_tps": round(min((sample[2] for sample in samples), default=0.0), 6),
            "observed_max_ttft_ms": max((sample[3] for sample in samples), default=0),
            "ready_for_matrix_review": not row_blockers,
            "blockers": row_blockers,
            "warnings": row_warnings,
        }

    warnings = [
        f"{model_key}:{warning}"
        for model_key in sorted(observations)
        for warning in rows[model_key]["warnings"]
    ]
    if len(seen_providers) < MIN_PROVIDERS:
        blockers.insert(0, f"matrix_provider_quorum:{len(seen_providers)}/{MIN_PROVIDERS}")
    if len(classes) < MIN_HARDWARE_CLASSES:
        blockers.insert(0, f"matrix_hardware_class_quorum:{len(classes)}/{MIN_HARDWARE_CLASSES}")
    ready = not blockers
    return {
        "schema_version": AUDIT_SCHEMA,
        "candidate_catalog_sha256": candidate_sha,
        "candidate_signature_verified": True,
        "candidate_catalog_version": candidate["version"],
        "matrix_sha256": hashlib.sha256(matrix_bytes).hexdigest(),
        "matrix_generated_at": matrix["generated_at"],
        "matrix_authentication": "not_performed_export_contract_only",
        "as_of": as_of.isoformat().replace("+00:00", "Z"),
        "min_generated_at": min_generated_at.isoformat().replace("+00:00", "Z"),
        "required_providers": MIN_PROVIDERS,
        "required_hardware_classes": MIN_HARDWARE_CLASSES,
        "provider_count": len(seen_providers),
        "hardware_class_count": len(classes),
        "hardware_classes": sorted(classes),
        "ready_for_matrix_review": ready,
        "rederivation_authorized": False,
        "rederivation_blockers": [
            "observed_serving_cross_check_required",
            "separate_threshold_promotion_spec_and_audit_required",
        ],
        "numeric_gates_changed": False,
        "blockers": blockers,
        "warnings": warnings,
        "rows": rows,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[1] / "phase3-binary/catalog/autotune/autotune-candidates.json")
    parser.add_argument("--matrix", required=True, type=pathlib.Path, help="trusted hardware-verifier export")
    parser.add_argument("--min-generated-at", required=True, help="post-#745 RFC3339 evidence cutoff")
    parser.add_argument("--as-of", required=True, help="reproducible RFC3339 review time; future evidence is rejected")
    parser.add_argument("--pretty", action="store_true")
    args = parser.parse_args()
    try:
        report = audit_matrix(args.candidate, args.matrix, args.min_generated_at, args.as_of)
    except (AuditError, catalog_release.CatalogError, OSError, ValueError) as exc:
        print(f"autotune-gate-matrix: ERROR: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(report, indent=2 if args.pretty else None, sort_keys=True, separators=None if args.pretty else (",", ":")))
    return 0 if report["ready_for_matrix_review"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
