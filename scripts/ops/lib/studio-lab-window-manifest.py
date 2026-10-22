#!/usr/bin/env python3
"""Build the fixed Studio lab-window manifest and source artifact snapshot."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import time
from pathlib import Path


SCHEMA = "macprovider.studio_lab_window_manifest.v1"
SAFE_TOKEN = re.compile(r"^[A-Za-z0-9._-]+$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
SHA40 = re.compile(r"^[0-9a-f]{40}$")
ARTIFACT_FIELDS = {
    "diagnostic_cli", "glmbench", "diagnostic_metallib", "glmbench_metallib",
    "fixture_config", "fixture_index",
}
ARTIFACT_RELATIVES = {
    "diagnostic_cli": "phase3-binary/.build/release/macprovider-cli",
    "glmbench": "scripts/lab/cb-studio/glm53-bench/.build/release/GLMBench",
    "diagnostic_metallib": "phase3-binary/.build/release/mlx.metallib",
    "glmbench_metallib": "scripts/lab/cb-studio/glm53-bench/.build/release/mlx.metallib",
    "fixture_config": ".lab-window/fixture/target/config.json",
    "fixture_index": ".lab-window/fixture/target/model.safetensors.index.json",
    "reference_python": ".lab-window/dsv4-venv/bin/python3",
    "reference_script": "scripts/lab/dsv4/dsv4_reference_bench.py",
    "dsv4_fixture_config": ".lab-window/fixture/dsv4-target/config.json",
    "dsv4_fixture_index": ".lab-window/fixture/dsv4-target/model.safetensors.index.json",
}
QWEN_ARTIFACT_FIELDS = {
    "diagnostic_cli", "diagnostic_metallib", "fixture_config", "fixture_index",
}
EXECUTABLE_ARTIFACTS = {"diagnostic_cli", "glmbench", "reference_python"}
JOB_KINDS = (
    "diagnostic-legacy", "profiler-only", "qualification", "qwen-qualification", "qwen-journey", "glm-prefill",
    "glm-parity-prefill512", "dsv4-reference", "glm-parity-prefill512-then-dsv4-reference",
)
JOB_SCHEMA = "macprovider.studio_lab_window_job.v1"
JOB_RESULT_SCHEMA = "macprovider.studio_lab_window_job_result.v1"
PREFLIGHT_SCHEMA = "macprovider.studio_lab_window_job_preflight.v1"
REUSE_RELATIVE = Path(".lab-window/reuse")
POLICY_RELATIVE = Path(".lab-window/qualification-policy.json")
PROJECTION_RELATIVE = Path("phase3-binary/dist/static/native-mtp-artifact-manifest.json")
QWEN_PROJECTION_RELATIVE = Path(".lab-window/qwen-artifact-manifest.json")
QUALIFICATION_CELLS = tuple(
    f"s{slots}-p{prompt}-o{output}"
    for slots in range(1, 5)
    for prompt in (1536, 4096)
    for output in (128, 512)
)
QWEN_QUALIFICATION_CELLS = (
    "s1-p1536-o128", "s1-p1536-o512", "s1-p4096-o128", "s1-p4096-o512",
    "s2-p1536-o512", "s8-p1536-o512",
)
QUALIFICATION_KINDS = ("qualification", "qwen-qualification")
QWEN_JOB_KINDS = ("qwen-qualification", "qwen-journey")
CLI_ONLY_JOB_KINDS = (*QWEN_JOB_KINDS, "glm-prefill")
QWEN_JOURNEY_PROFILE = {
    "model_id": "qwen/qwen3.6-35b-a3b",
    "qualified_slots": 8,
    "max_native_active_rows": 1,
    "max_prompt_tokens": 4096,
    "request_feature_profile": "native_mtp_sampled_text_v1",
}
SNAPSHOT_FIELDS = (
    "config_sha256", "provider_plist_sha256", "watchdog_plist_sha256",
    "compatibility_set_sha256", "provider_id_sha256", "coordinator_origin",
    "compatibility_set_id", "binary_version", "model", "model_loaded",
    "network_state", "requests_in_flight", "coordinator_connected",
    "operator_paused", "pid", "process_start_us", "executable_path",
)


class Refusal(RuntimeError):
    pass


def canonical_path(value: str, name: str) -> Path:
    path = Path(value)
    if not path.is_absolute() or path.resolve() != path:
        raise Refusal(f"{name} must be an absolute canonical path")
    return path


def safe_directory(path: Path) -> None:
    info = path.lstat()
    if (
        not stat.S_ISDIR(info.st_mode)
        or info.st_uid != os.getuid()
        or stat.S_IMODE(info.st_mode) & 0o022
        or path.is_symlink()
        or path.resolve() != path
    ):
        raise Refusal(f"unsafe source directory: {path}")


def safe_artifact(path: Path, *, executable: bool = False) -> Path:
    """Return the safe canonical target while retaining the fixed lexical path."""
    target = path.resolve(strict=True)
    info = target.lstat()
    if (
        not stat.S_ISREG(info.st_mode)
        or info.st_uid != os.getuid()
        or info.st_nlink != 1
        or stat.S_IMODE(info.st_mode) & 0o022
        or target.is_symlink()
        or target.resolve() != target
    ):
        raise Refusal(f"unsafe artifact: {path}")
    if executable and not os.access(target, os.X_OK):
        raise Refusal(f"artifact is not executable: {path}")
    return target


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    before = path.lstat()
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        opened = os.fstat(fd)
        if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
            raise Refusal(f"artifact changed while opening: {path}")
        for block in iter(lambda: os.read(fd, 1024 * 1024), b""):
            digest.update(block)
    finally:
        os.close(fd)
    return digest.hexdigest()


def canonical_digest(value: object) -> str:
    data = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(data).hexdigest()


def git_value(source: Path, value: str, name: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(source), "rev-parse", value],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    if not SHA40.fullmatch(result):
        raise Refusal(f"invalid git identity: {name}")
    return result


def require_sha(value: object, name: str) -> str:
    if not isinstance(value, str) or not SHA256.fullmatch(value):
        raise Refusal(f"{name} must be a lowercase SHA-256")
    return value


def artifact_fields(kind: str) -> set[str]:
    if kind in STAGED_JOB_KINDS:
        return set().union(*(STAGED_COMPONENT_FIELDS[item] for item in STAGED_JOB_KINDS[kind]))
    return QWEN_ARTIFACT_FIELDS if kind in CLI_ONLY_JOB_KINDS else ARTIFACT_FIELDS


def read_safe_object(path: Path, name: str) -> tuple[dict, str]:
    target = safe_artifact(path)
    try:
        value = json.loads(target.read_bytes())
    except ValueError as exc:
        raise Refusal(f"{name} is invalid JSON") from exc
    if not isinstance(value, dict):
        raise Refusal(f"{name} is not a JSON object")
    return value, file_sha256(target)


def projection_tuple(source: Path) -> dict[str, str]:
    projection, _ = read_safe_object(source / PROJECTION_RELATIVE, "artifact projection")
    artifacts = projection.get("artifacts")
    if projection.get("schema_version") != "macprovider.native-mtp-artifact-projection.v1" or not isinstance(artifacts, dict):
        raise Refusal("artifact projection schema is invalid")
    result: dict[str, str] = {}
    for source_key, result_key in (
        ("target", "target_sha256"), ("mtp", "mtp_sha256"),
        ("tokenizer", "tokenizer_sha256"), ("manifest", "mtp_manifest_sha256"),
    ):
        item = artifacts.get(source_key)
        if not isinstance(item, dict):
            raise Refusal(f"artifact projection is missing {source_key}")
        result[result_key] = require_sha(item.get("sha256"), f"artifact projection {source_key}")
    if result["target_sha256"] != result["mtp_sha256"]:
        raise Refusal("artifact projection is not the embedded MTP tuple")
    return result


def qwen_projection_tuple(source: Path) -> tuple[dict[str, str], str]:
    projection, projection_sha = read_safe_object(
        source / QWEN_PROJECTION_RELATIVE, "Qwen artifact projection"
    )
    artifacts = projection.get("artifacts")
    if set(projection) != {"schema_version", "artifacts"} or (
        projection.get("schema_version") != "macprovider.native-mtp-artifact-projection.v1"
        or not isinstance(artifacts, dict)
        or set(artifacts) != {"target", "mtp", "tokenizer", "manifest"}
    ):
        raise Refusal("Qwen artifact projection schema is invalid")
    expected_paths = {
        "target": "target", "mtp": "mtp",
        "tokenizer": "target/tokenizer.json", "manifest": "mtp/config.json",
    }
    result: dict[str, str] = {}
    for source_key, result_key in (
        ("target", "target_sha256"), ("mtp", "mtp_sha256"),
        ("tokenizer", "tokenizer_sha256"), ("manifest", "mtp_manifest_sha256"),
    ):
        item = artifacts.get(source_key)
        if not isinstance(item, dict) or set(item) != {"path", "sha256"}:
            raise Refusal(f"Qwen artifact projection is missing strict {source_key} identity")
        if item.get("path") != expected_paths[source_key]:
            raise Refusal(f"Qwen artifact projection {source_key} path is invalid")
        result[result_key] = require_sha(
            item.get("sha256"), f"Qwen artifact projection {source_key}"
        )
    if result["target_sha256"] == result["mtp_sha256"]:
        raise Refusal("Qwen artifact projection embeds MTP in the target")
    return result, projection_sha


def validate_journey(value: dict) -> dict[str, str]:
    if (
        value.get("schema") != "macprovider.native-mtp-journey-hardware-result.v1"
        or value.get("model_id") != "zai-org/glm-5.3-flash"
        or value.get("qualified_slots") != 4
        or value.get("lab_max_native_active_rows") != 4
        or value.get("signed_max_native_active_rows") != 1
        or value.get("qualification") is not False
    ):
        raise Refusal("archived journey tuple is not the reviewed bound-four diagnostic")
    expected = {
        "step-04-serial-token-oracle": "pass",
        "step-05-cache-state-boundary": "pass",
        "step-06-streaming-stop": "pass",
        "step-07-08-mixed-multirow-capacity": "pass",
        "step-09-cancellation": "pass",
        "step-10-warm-swap": "pass",
        "step-12-native-selftest": "partial",
    }
    steps = value.get("steps")
    if not isinstance(steps, list) or len(steps) != len(expected) or {
        item.get("step_id"): item.get("status")
        for item in steps if isinstance(item, dict)
    } != expected:
        raise Refusal("archived journey steps do not match the reviewed diagnostic")
    if any(
        not isinstance(item.get("checks"), dict)
        or not item["checks"]
        or any(check is not True for check in item["checks"].values())
        for item in steps
    ):
        raise Refusal("archived journey contains a failed or missing check")
    identities = {
        "target_sha256": value.get("target_sha256"),
        "mtp_sha256": value.get("mtp_sha256"),
        "tokenizer_sha256": value.get("tokenizer_sha256"),
        "mtp_manifest_sha256": value.get("mtp_manifest_sha256"),
    }
    if any(not isinstance(item, str) or not SHA256.fullmatch(item) for item in identities.values()):
        raise Refusal("archived journey fixture identity is incomplete")
    if identities["target_sha256"] != identities["mtp_sha256"]:
        raise Refusal("archived embedded MTP identity differs from target")
    return identities


def validate_policy(value: dict) -> None:
    exact = {
        "schema": "macprovider.native-mtp-r015-policy.v1",
        "slots": [1, 2, 3, 4],
        "prompt_tokens": [1536, 4096],
        "max_tokens": [128, 512],
        "gated_cells": [],
        "qualified_slots": 4,
        "maximum_prompt_tokens": 4096,
        "sustained_seconds": 1800,
        "sustained_cell_id": "s4-p1536-o512",
        "warmup_runs": 1,
        "blocks": 10,
        "quantization": "4bit",
        "cache_mode": "paged_kv_mixed",
        "proposal_depth": 1,
        "run_order": "seeded_random_counterbalanced",
        "prompt_corpus": "deterministic_synthetic_unique_v2",
        "exclusion_rules": "none",
        "confidence_method": "paired_block_bootstrap_holm_v1",
    }
    if any(value.get(key) != expected for key, expected in exact.items()):
        raise Refusal("qualification policy is not the approved bound-four R015 contract")
    for key in ("qualified_slots", "maximum_prompt_tokens", "sustained_seconds", "warmup_runs", "blocks", "proposal_depth"):
        if type(value.get(key)) is not int:
            raise Refusal(f"qualification policy {key} must be an integer")
    for key in ("slots", "prompt_tokens", "max_tokens"):
        if not isinstance(value.get(key), list) or any(type(item) is not int for item in value[key]):
            raise Refusal(f"qualification policy {key} must contain integers")
    provider_commit = value.get("provider_commit")
    if not isinstance(provider_commit, str) or not SHA40.fullmatch(provider_commit):
        raise Refusal("qualification policy provider_commit is invalid")
    # Production authorization remains independently signed at one row.  A
    # reviewed laboratory declaration may raise only this offline job's bound.
    effective_bound = value.get(
        "laboratory_max_native_active_rows", value.get("max_native_active_rows")
    )
    if type(effective_bound) is not int or effective_bound != 4:
        raise Refusal("qualification policy does not declare laboratory bound four")
    if "laboratory_max_native_active_rows" in value and (
        type(value.get("max_native_active_rows")) is not int
        or value.get("max_native_active_rows") != 1
    ):
        raise Refusal("qualification policy must preserve production bound one")


def glm_prefill_cells(policy: dict) -> list[str]:
    return [f"s{slots}-p{prompt}-o128" for slots in (1, 2, 4) for prompt in policy["prompt_tokens"]]


def validate_glm_prefill_policy(value: dict) -> None:
    # This is a measurement-only job: it cannot change native-row admission or
    # produce R015 qualification evidence. Reuse the existing exploratory CLI.
    exact = {
        "schema": "macprovider.native-mtp-exploratory-policy.v1",
        "model_id": "zai-org/glm-5.3-flash",
        "slots": [1, 2, 4], "max_tokens": [128], "gated_cells": [],
        "qualified_slots": 4, "max_native_active_rows": 1,
        "maximum_prompt_tokens": 16384, "arrival_interval_ms": 250,
        "temperature": 0, "warmup_runs": 1, "blocks": 10,
        "sustained_seconds": 0, "sustained_cell_id": "s4-p16384-o128",
        "quantization": "4bit", "cache_mode": "paged_kv_mixed", "proposal_depth": 1,
        "run_order": "seeded_random_counterbalanced",
        "prompt_corpus": "deterministic_synthetic_unique_v2",
        "exclusion_rules": "none", "confidence_method": "paired_block_bootstrap_holm_v1",
    }
    if any(value.get(key) != expected for key, expected in exact.items()):
        raise Refusal("GLM prefill policy is not the fixed exploratory measurement contract")
    if value.get("prompt_tokens") not in ([16384], [4096, 16384]):
        raise Refusal("GLM prefill prompts must be the missing 16k baseline or the 4k/16k comparison")
    for key, expected in exact.items():
        if isinstance(expected, int) and type(value.get(key)) is not int:
            raise Refusal(f"GLM prefill policy {key} must be an integer")
        if isinstance(expected, list) and any(type(item) is not int for item in value[key]):
            raise Refusal(f"GLM prefill policy {key} must contain integers")
    if any(type(item) is not int for item in value["prompt_tokens"]):
        raise Refusal("GLM prefill prompt tokens must contain integers")
    if any(key.startswith(("laboratory_", "exploratory")) for key in value):
        raise Refusal("GLM prefill policy cannot contain admission overrides")
    if not isinstance(value.get("provider_commit"), str) or not SHA40.fullmatch(value["provider_commit"]):
        raise Refusal("GLM prefill provider commit is invalid")
    thresholds = {
        "throughput_lower_bound_min": 0.15, "ttft_p95_upper_bound_max": 0.1,
        "tpot_p95_upper_bound_max": 0.0, "chunk_gap_p99_upper_bound_max": 1.0,
        "rejection_increase_max_pp": 1.0, "min_available_memory_fraction": 0.1,
        "bootstrap_draws": 10000, "alpha": 0.05,
        "gated_throughput_lower_bound_min": -0.05,
        "gated_ttft_p95_upper_bound_max": 0.05, "gated_tpot_p95_upper_bound_max": 0.05,
    }
    if value.get("thresholds") != thresholds or any(
        (type(value["thresholds"].get(key)) is not int if key == "bootstrap_draws"
         else type(value["thresholds"].get(key)) not in (int, float))
        for key, expected in thresholds.items()
    ):
        raise Refusal("GLM prefill thresholds must retain the existing gates")


def validate_qwen_policy(value: dict) -> None:
    exact = {
        "schema": "macprovider.native-mtp-r015-policy.v1",
        "model_id": "qwen/qwen3.6-35b-a3b",
        "qualified_slots": 8,
        "max_native_active_rows": 1,
        "arrival_interval_ms": 250,
        "slots": [1],
        "maximum_prompt_tokens": 4096,
        "prompt_tokens": [1536, 4096],
        "max_tokens": [128, 512],
        "gated_cells": ["s2-p1536-o512", "s8-p1536-o512"],
        "warmup_runs": 1,
        "blocks": 10,
        "sustained_seconds": 1800,
        "sustained_cell_id": "s8-p1536-o512",
        "quantization": "4bit",
        "cache_mode": "paged_kv_mixed",
        "proposal_depth": 1,
        "run_order": "seeded_random_counterbalanced",
        "prompt_corpus": "deterministic_synthetic_unique_v2",
        "exclusion_rules": "none",
        "confidence_method": "paired_block_bootstrap_holm_v1",
    }
    if any(value.get(key) != expected for key, expected in exact.items()):
        raise Refusal("Qwen qualification policy is not the approved R015 contract")
    expected_thresholds = {
        "throughput_lower_bound_min": 0.15,
        "ttft_p95_upper_bound_max": 0.1,
        "tpot_p95_upper_bound_max": 0.0,
        "chunk_gap_p99_upper_bound_max": 1.0,
        "rejection_increase_max_pp": 1.0,
        "min_available_memory_fraction": 0.1,
        "bootstrap_draws": 10000,
        "alpha": 0.05,
        "gated_throughput_lower_bound_min": -0.05,
        "gated_ttft_p95_upper_bound_max": 0.05,
        "gated_tpot_p95_upper_bound_max": 0.05,
    }
    if value.get("thresholds") != expected_thresholds:
        raise Refusal("Qwen qualification policy thresholds are not the approved gates")
    if any(
        type(value["thresholds"].get(key)) is not type(expected)
        for key, expected in expected_thresholds.items()
    ):
        raise Refusal("Qwen qualification policy threshold types are invalid")
    if value.get("exploratory", False) is not False or any(
        key.startswith(("exploratory", "laboratory_")) for key in value
    ):
        raise Refusal("Qwen qualification policy contains an exploratory or laboratory override")
    for key in (
        "qualified_slots", "max_native_active_rows", "arrival_interval_ms",
        "maximum_prompt_tokens", "warmup_runs", "blocks", "sustained_seconds", "proposal_depth",
    ):
        if type(value.get(key)) is not int:
            raise Refusal(f"Qwen qualification policy {key} must be an integer")
    for key in ("slots", "prompt_tokens", "max_tokens"):
        if not isinstance(value.get(key), list) or any(type(item) is not int for item in value[key]):
            raise Refusal(f"Qwen qualification policy {key} must contain integers")
    provider_commit = value.get("provider_commit")
    if not isinstance(provider_commit, str) or not SHA40.fullmatch(provider_commit):
        raise Refusal("Qwen qualification policy provider_commit is invalid")
    for key in ("target_sha256", "mtp_sha256", "tokenizer_sha256"):
        require_sha(value.get(key), f"Qwen qualification policy {key}")
    if value["target_sha256"] == value["mtp_sha256"]:
        raise Refusal("Qwen qualification policy embeds MTP in the target")


def archived_reuse(source: Path, artifacts: dict[str, dict[str, str]], phase3_tree: str) -> dict[str, str]:
    root = source / REUSE_RELATIVE
    manifest, manifest_sha = read_safe_object(root / "manifest.json", "archived manifest")
    completed, completed_sha = read_safe_object(root / "completed.json", "archived completion")
    journey, journey_sha = read_safe_object(root / "journey.json", "archived journey")
    if (
        manifest.get("schema_version") != SCHEMA
        or completed.get("manifest_sha256") != manifest_sha
        or completed.get("lab_exit_code") != 0
        or completed.get("nonce") != manifest.get("nonce")
        or completed.get("lab_git_head") != manifest.get("lab_git_head")
    ):
        raise Refusal("archived journey completion is not bound to its manifest")
    archived_head = manifest.get("lab_git_head")
    if not isinstance(archived_head, str) or not SHA40.fullmatch(archived_head):
        raise Refusal("archived manifest git head is invalid")
    if git_value(source, f"{archived_head}:phase3-binary", "archived phase3 tree") != phase3_tree:
        raise Refusal("archived and current phase3 source trees differ")
    archived_artifacts = manifest.get("artifacts")
    for key in ("diagnostic_cli", "diagnostic_metallib", "fixture_config", "fixture_index"):
        if (
            not isinstance(archived_artifacts, dict)
            or not isinstance(archived_artifacts.get(key), dict)
            or archived_artifacts[key].get("sha256") != artifacts[key]["sha256"]
        ):
            raise Refusal(f"archived journey input differs: {key}")
    identities = validate_journey(journey)
    if identities != projection_tuple(source):
        raise Refusal("archived journey identity differs from checked-in projection")
    return {
        "archived_manifest_sha256": manifest_sha,
        "archived_completion_sha256": completed_sha,
        "archived_journey_sha256": journey_sha,
        # Honest provenance boundary: the old completion bound exit 0 to its
        # manifest, but did not include the journey byte digest.
        "archive_binding": "protected_import_not_historically_receipt_bound",
        **identities,
    }


def build_job(args: argparse.Namespace, source: Path, artifacts: dict[str, dict[str, str]]) -> dict | None:
    kind = getattr(args, "job_kind", "diagnostic-legacy")
    if kind == "diagnostic-legacy":
        return None
    script_sha = require_sha(getattr(args, "lab_script_sha256", None), "lab script sha256")
    helper_sha = require_sha(getattr(args, "job_helper_sha256", None), "job helper sha256")
    phase3_tree = git_value(source, "HEAD:phase3-binary", "phase3 tree")
    inputs: dict[str, object] = {
        "phase3_tree_oid": phase3_tree,
        "lab_script_sha256": script_sha,
        "job_helper_sha256": helper_sha,
        "artifact_sha256": {key: item["sha256"] for key, item in sorted(artifacts.items())},
    }
    if kind in STAGED_JOB_KINDS:
        inputs.update(staged_inputs(kind, source))
        return {
            "schema_version": JOB_SCHEMA,
            "kind": kind,
            "identity_sha256": canonical_digest({"kind": kind, "immutable_inputs": inputs}),
            "immutable_inputs": inputs,
        }
    if kind not in CLI_ONLY_JOB_KINDS:
        inputs["glmbench_tree_oid"] = git_value(
            source, "HEAD:scripts/lab/cb-studio/glm53-bench", "GLMBench tree"
        )
    if kind == "profiler-only":
        inputs["reuse"] = archived_reuse(source, artifacts, phase3_tree)
    elif kind in ("qualification", "glm-prefill"):
        policy, policy_sha = read_safe_object(source / POLICY_RELATIVE, "qualification policy")
        (validate_glm_prefill_policy if kind == "glm-prefill" else validate_policy)(policy)
        projected = projection_tuple(source)
        if any(policy.get(key) != projected[key] for key in ("target_sha256", "mtp_sha256", "tokenizer_sha256")):
            raise Refusal("qualification policy fixture identity differs from projection")
        if git_value(source, f"{policy['provider_commit']}:phase3-binary", "policy phase3 tree") != phase3_tree:
            raise Refusal("qualification policy provider commit has different phase3 source")
        inputs["qualification_policy_sha256"] = policy_sha
        inputs["qualification_provider_commit"] = policy["provider_commit"]
        inputs["qualification_cells"] = glm_prefill_cells(policy) if kind == "glm-prefill" else list(QUALIFICATION_CELLS)
    else:
        policy, policy_sha = read_safe_object(source / POLICY_RELATIVE, "Qwen qualification policy")
        validate_qwen_policy(policy)
        projected, projection_sha = qwen_projection_tuple(source)
        if any(
            policy.get(key) != projected[key]
            for key in ("target_sha256", "mtp_sha256", "tokenizer_sha256")
        ):
            raise Refusal("Qwen qualification policy fixture identity differs from projection")
        if (
            git_value(source, f"{policy['provider_commit']}:phase3-binary", "Qwen policy phase3 tree")
            != phase3_tree
        ):
            raise Refusal("Qwen qualification policy provider commit has different phase3 source")
        inputs["qualification_policy_sha256"] = policy_sha
        inputs["qualification_provider_commit"] = policy["provider_commit"]
        inputs["artifact_projection_sha256"] = projection_sha
        inputs["artifact_projection"] = projected
        if kind == "qwen-qualification":
            inputs["qualification_cells"] = list(QWEN_QUALIFICATION_CELLS)
        else:
            inputs["journey_profile"] = dict(QWEN_JOURNEY_PROFILE)
    identity = canonical_digest({"kind": kind, "immutable_inputs": inputs})
    return {
        "schema_version": JOB_SCHEMA,
        "kind": kind,
        "identity_sha256": identity,
        "immutable_inputs": inputs,
    }


def source_snapshot(args: argparse.Namespace) -> dict[str, object]:
    source = canonical_path(args.source_dir, "source directory")
    if not SHA40.fullmatch(args.git_head):
        raise Refusal("lab git head must be a lowercase 40-character SHA")
    if not SAFE_TOKEN.fullmatch(args.provider_label):
        raise Refusal("provider label is invalid")
    safe_directory(source)
    head = git_value(source, "HEAD", "lab head")
    if head != args.git_head:
        raise Refusal("lab source git head mismatch")
    dirty = subprocess.run(
        ["git", "-C", str(source), "status", "--porcelain", "--untracked-files=no"],
        capture_output=True, text=True, check=True,
    ).stdout
    if dirty:
        raise Refusal("lab source has tracked modifications")
    kind = getattr(args, "job_kind", "diagnostic-legacy")
    artifacts = {name: source / ARTIFACT_RELATIVES[name] for name in artifact_fields(kind)}
    result: dict[str, dict[str, str]] = {}
    for name, path in artifacts.items():
        target = safe_artifact(path, executable=name in EXECUTABLE_ARTIFACTS)
        result[name] = {"path": str(path), "sha256": file_sha256(target)}
    launch_agents = Path.home().resolve() / "Library" / "LaunchAgents"
    snapshot: dict[str, object] = {
        "artifacts": result,
        "provider_plist": str(launch_agents / f"{args.provider_label}.plist"),
        "watchdog_plist": str(launch_agents / f"{args.provider_label}-watchdog.plist"),
    }
    job = build_job(args, source, result)
    if job is not None:
        snapshot["job"] = job
    return snapshot


def positive(value: str, name: str, maximum: int = 86400) -> int:
    try:
        parsed = int(value)
    except ValueError as exc:
        raise Refusal(f"{name} must be a positive integer") from exc
    if parsed < 1 or parsed > maximum:
        raise Refusal(f"{name} is outside its allowed bound")
    return parsed


def readiness_timeout(value: str) -> int:
    parsed = positive(value, "ready timeout", 1200)
    if parsed < 120:
        raise Refusal("ready timeout is outside its allowed bound")
    return parsed


def read_object(path: str, name: str) -> dict:
    value = json.loads(Path(path).read_bytes())
    if not isinstance(value, dict):
        raise Refusal(f"{name} is not a JSON object")
    return value


def build_manifest(args: argparse.Namespace) -> dict[str, object]:
    if not SAFE_TOKEN.fullmatch(args.nonce) or not SHA40.fullmatch(args.git_head):
        raise Refusal("nonce or lab git head is invalid")
    probe = read_object(args.probe_json, "probe")
    source = read_object(args.source_snapshot_json, "source snapshot")
    snapshot = probe.get("snapshot")
    installed = probe.get("installed")
    if not isinstance(snapshot, dict) or not isinstance(installed, dict):
        raise Refusal("probe snapshot or installed identity is missing")
    if any(field not in snapshot for field in SNAPSHOT_FIELDS):
        raise Refusal("probe serving snapshot is incomplete")
    if (
        probe.get("hardware_model") != "Mac15,14"
        or snapshot.get("model_loaded") is not True
        or snapshot.get("network_state") != "buyer_serving"
        or snapshot.get("coordinator_connected") is not True
        or snapshot.get("operator_paused") is not False
    ):
        raise Refusal("probe is not a buyer-serving Studio baseline")
    hashes = {
        "binary_sha256": installed.get("binary_sha256"),
        "config_sha256": snapshot.get("config_sha256"),
        "provider_plist_sha256": snapshot.get("provider_plist_sha256"),
        "watchdog_plist_sha256": snapshot.get("watchdog_plist_sha256"),
        "compatibility_set_sha256": snapshot.get("compatibility_set_sha256"),
        "probe_sha256": args.probe_sha256,
        "lab_script_sha256": args.lab_script_sha256,
    }
    if any(not isinstance(value, str) or not SHA256.fullmatch(value) for value in hashes.values()):
        raise Refusal("baseline hashes are incomplete")
    job = source.get("job")
    if job is not None:
        validate_job_object(job)
    expected_fields = artifact_fields(job["kind"] if isinstance(job, dict) else "diagnostic-legacy")
    artifacts = source.get("artifacts")
    if not isinstance(artifacts, dict) or set(artifacts) != expected_fields:
        raise Refusal("source artifact snapshot is incomplete")
    for name, item in artifacts.items():
        if (
            not isinstance(item, dict)
            or not isinstance(item.get("path"), str)
            or not Path(item["path"]).is_absolute()
            or not isinstance(item.get("sha256"), str)
            or not SHA256.fullmatch(item["sha256"])
        ):
            raise Refusal(f"source artifact snapshot is invalid: {name}")
    if job is not None:
        if job["immutable_inputs"]["lab_script_sha256"] != args.lab_script_sha256:
            raise Refusal("job lab script hash differs from the manifest baseline")
    paths = {
        name: str(canonical_path(getattr(args, name), name))
        for name in (
            "install_dir", "config_path", "ctl_socket", "probe_path",
            "owner_pin_journal", "lab_source_dir", "lab_script_path", "log_path",
        )
    }
    provider_plist = canonical_path(str(source.get("provider_plist", "")), "provider plist")
    watchdog_plist = canonical_path(str(source.get("watchdog_plist", "")), "watchdog plist")
    compatibility = canonical_path(
        str(Path(paths["install_dir"]) / "compatibility-set.json"), "compatibility path"
    )
    if snapshot.get("executable_path") != str(Path(paths["install_dir"]) / "macprovider-cli"):
        raise Refusal("probe executable does not match install directory")
    lab_timeout = positive(
        args.lab_timeout_s, "lab timeout",
        STAGED_WINDOW_TIMEOUTS[job["kind"]] if job is not None and job["kind"] in STAGED_JOB_KINDS else
        43200 if job is not None and job["kind"] in QUALIFICATION_KINDS else (
            21600 if job is not None and job["kind"] == "glm-prefill" else (
                7200 if job is not None and job["kind"] == "qwen-journey" else 3600
            )
        ),
    )
    result: dict[str, object] = {
        "schema_version": SCHEMA,
        "nonce": args.nonce,
        "install_dir": paths["install_dir"],
        "config_path": paths["config_path"],
        "provider_plist": str(provider_plist),
        "watchdog_plist": str(watchdog_plist),
        "compatibility_path": str(compatibility),
        "ctl_socket": paths["ctl_socket"],
        "provider_label": args.provider_label,
        "watchdog_label": f"{args.provider_label}-watchdog",
        "status_port": positive(args.status_port, "status port", 65535),
        "probe_path": paths["probe_path"],
        "owner_pin_journal": paths["owner_pin_journal"],
        "lab_source_dir": paths["lab_source_dir"],
        "lab_script_path": paths["lab_script_path"],
        "lab_git_head": args.git_head,
        "log_path": paths["log_path"],
        "drain_timeout_s": positive(args.drain_timeout_s, "drain timeout"),
        "lab_timeout_s": lab_timeout,
        "ready_timeout_s": readiness_timeout(args.ready_timeout_s),
        "poll_s": positive(args.poll_s, "poll interval", 60),
        "baseline": {**hashes, "snapshot": {field: snapshot[field] for field in SNAPSHOT_FIELDS}},
        "artifacts": artifacts,
    }
    if job is not None:
        helper_path = Path(paths["lab_script_path"]).with_name("manifest.py")
        result["job_helper_path"] = str(helper_path)
        result["job"] = job
        baseline = result["baseline"]
        assert isinstance(baseline, dict)
        baseline["job_helper_sha256"] = job["immutable_inputs"]["job_helper_sha256"]
    return result


def validate_job_object(job: object) -> dict:
    if not isinstance(job, dict) or set(job) != {
        "schema_version", "kind", "identity_sha256", "immutable_inputs"
    }:
        raise Refusal("job object is invalid")
    if job.get("schema_version") != JOB_SCHEMA or job.get("kind") not in JOB_KINDS[1:]:
        raise Refusal("job schema or kind is invalid")
    inputs = job.get("immutable_inputs")
    if not isinstance(inputs, dict):
        raise Refusal("job immutable inputs are missing")
    if job["kind"] in STAGED_JOB_KINDS:
        validate_staged_inputs(job["kind"], inputs)
        if job.get("identity_sha256") != canonical_digest({"kind": job["kind"], "immutable_inputs": inputs}):
            raise Refusal("job identity digest mismatch")
        return job
    expected_inputs = {
        "phase3_tree_oid", "lab_script_sha256", "job_helper_sha256", "artifact_sha256",
    }
    if job["kind"] not in CLI_ONLY_JOB_KINDS:
        expected_inputs.add("glmbench_tree_oid")
    if job["kind"] == "profiler-only":
        expected_inputs.add("reuse")
    elif job["kind"] in ("qualification", "glm-prefill"):
        expected_inputs |= {
            "qualification_policy_sha256", "qualification_provider_commit",
            "qualification_cells",
        }
    elif job["kind"] == "qwen-qualification":
        expected_inputs |= {
            "qualification_policy_sha256", "qualification_provider_commit",
            "qualification_cells", "artifact_projection_sha256", "artifact_projection",
        }
    else:
        expected_inputs |= {
            "qualification_policy_sha256", "qualification_provider_commit",
            "artifact_projection_sha256", "artifact_projection", "journey_profile",
        }
    if set(inputs) != expected_inputs:
        raise Refusal("job immutable input schema is invalid")
    for key in ("phase3_tree_oid",):
        if not isinstance(inputs.get(key), str) or not SHA40.fullmatch(inputs[key]):
            raise Refusal(f"job {key} is invalid")
    if job["kind"] not in CLI_ONLY_JOB_KINDS and (
        not isinstance(inputs.get("glmbench_tree_oid"), str)
        or not SHA40.fullmatch(inputs["glmbench_tree_oid"])
    ):
        raise Refusal("job glmbench_tree_oid is invalid")
    for key in ("lab_script_sha256", "job_helper_sha256"):
        require_sha(inputs.get(key), f"job {key}")
    artifacts = inputs.get("artifact_sha256")
    artifact_fields = QWEN_ARTIFACT_FIELDS if job["kind"] in CLI_ONLY_JOB_KINDS else ARTIFACT_FIELDS
    if not isinstance(artifacts, dict) or set(artifacts) != artifact_fields:
        raise Refusal("job artifact hash schema is invalid")
    for key, value in artifacts.items():
        require_sha(value, f"job artifact {key}")
    if job["kind"] == "profiler-only":
        reuse = inputs.get("reuse")
        if not isinstance(reuse, dict) or set(reuse) != {
            "archived_manifest_sha256", "archived_completion_sha256",
            "archived_journey_sha256", "archive_binding", "target_sha256",
            "mtp_sha256", "tokenizer_sha256", "mtp_manifest_sha256",
        }:
            raise Refusal("job reuse schema is invalid")
        for key in (
            "archived_manifest_sha256", "archived_completion_sha256", "archived_journey_sha256",
            "target_sha256", "mtp_sha256", "tokenizer_sha256", "mtp_manifest_sha256",
        ):
            require_sha(reuse.get(key), f"job reuse {key}")
        if reuse.get("archive_binding") != "protected_import_not_historically_receipt_bound":
            raise Refusal("job archive binding is invalid")
    if job["kind"] in ("qualification", "glm-prefill"):
        require_sha(inputs.get("qualification_policy_sha256"), "qualification policy sha256")
        if (
            not isinstance(inputs.get("qualification_provider_commit"), str)
            or not SHA40.fullmatch(inputs["qualification_provider_commit"])
            or (
                inputs.get("qualification_cells") != list(QUALIFICATION_CELLS)
                if job["kind"] == "qualification" else inputs.get("qualification_cells") not in (
                    glm_prefill_cells({"prompt_tokens": [16384]}),
                    glm_prefill_cells({"prompt_tokens": [4096, 16384]}),
                )
            )
        ):
            raise Refusal("qualification immutable input schema is invalid")
    if job["kind"] in QWEN_JOB_KINDS:
        require_sha(inputs.get("qualification_policy_sha256"), "Qwen qualification policy sha256")
        require_sha(inputs.get("artifact_projection_sha256"), "Qwen artifact projection sha256")
        projection = inputs.get("artifact_projection")
        if (
            not isinstance(inputs.get("qualification_provider_commit"), str)
            or not SHA40.fullmatch(inputs["qualification_provider_commit"])
            or not isinstance(projection, dict)
            or set(projection) != {
                "target_sha256", "mtp_sha256", "tokenizer_sha256", "mtp_manifest_sha256"
            }
        ):
            raise Refusal("Qwen immutable input schema is invalid")
        for key, value in projection.items():
            require_sha(value, f"Qwen artifact projection {key}")
        if projection["target_sha256"] == projection["mtp_sha256"]:
            raise Refusal("Qwen job embeds MTP in the target")
        if job["kind"] == "qwen-qualification":
            if inputs.get("qualification_cells") != list(QWEN_QUALIFICATION_CELLS):
                raise Refusal("Qwen qualification cells are invalid")
        elif inputs.get("journey_profile") != QWEN_JOURNEY_PROFILE:
            raise Refusal("Qwen journey profile is invalid")
    expected = canonical_digest({"kind": job["kind"], "immutable_inputs": inputs})
    if job.get("identity_sha256") != expected:
        raise Refusal("job identity digest mismatch")
    return job


def load_job_manifest(path_value: str) -> tuple[dict, dict]:
    path = canonical_path(path_value, "manifest")
    manifest, _ = read_safe_object(path, "manifest")
    if manifest.get("schema_version") != SCHEMA:
        raise Refusal("manifest schema mismatch")
    job = validate_job_object(manifest.get("job"))
    source = canonical_path(str(manifest.get("lab_source_dir", "")), "lab source directory")
    if path.parent != canonical_path(str(manifest.get("job_helper_path", "")), "job helper").parent:
        raise Refusal("manifest and job helper must share the protected stage directory")
    expected_result = source / ".lab-window" / f"result-{manifest.get('nonce', '')}"
    if not SAFE_TOKEN.fullmatch(str(manifest.get("nonce", ""))):
        raise Refusal("manifest nonce is invalid")
    manifest["_manifest_path"] = str(path)
    manifest["_result_dir"] = str(expected_result)
    return manifest, job


def validate_current_job_inputs(manifest: dict, job: dict) -> None:
    source = canonical_path(manifest["lab_source_dir"], "lab source directory")
    safe_directory(source)
    inputs = job["immutable_inputs"]
    if git_value(source, "HEAD:phase3-binary", "phase3 tree") != inputs.get("phase3_tree_oid"):
        raise Refusal("job phase3 source tree drifted")
    if job["kind"] not in CLI_ONLY_JOB_KINDS and job["kind"] not in STAGED_JOB_KINDS and (
        git_value(source, "HEAD:scripts/lab/cb-studio/glm53-bench", "GLMBench tree")
        != inputs.get("glmbench_tree_oid")
    ):
        raise Refusal("job GLMBench source tree drifted")
    helper = canonical_path(manifest["job_helper_path"], "job helper")
    script = canonical_path(manifest["lab_script_path"], "lab script")
    if file_sha256(safe_artifact(helper)) != inputs.get("job_helper_sha256"):
        raise Refusal("job helper bytes drifted")
    if file_sha256(safe_artifact(script, executable=True)) != inputs.get("lab_script_sha256"):
        raise Refusal("lab script bytes drifted")
    artifact_hashes = inputs.get("artifact_sha256")
    artifacts = manifest.get("artifacts")
    if not isinstance(artifact_hashes, dict) or not isinstance(artifacts, dict):
        raise Refusal("job artifact identities are missing")
    for key in artifact_fields(job["kind"]):
        item = artifacts.get(key)
        if not isinstance(item, dict) or artifact_hashes.get(key) != item.get("sha256"):
            raise Refusal(f"job artifact manifest mismatch: {key}")
        # Keep the lexical fixed path while allowing the normal SwiftPM and
        # fixture symlinks. safe_artifact authenticates the resolved target.
        path = Path(str(item.get("path", "")))
        expected = source / ARTIFACT_RELATIVES[key]
        if not path.is_absolute() or path != expected:
            raise Refusal(f"job artifact path is not fixed: {key}")
        actual = file_sha256(safe_artifact(path, executable=key in EXECUTABLE_ARTIFACTS))
        if actual != artifact_hashes[key]:
            raise Refusal(f"job artifact drifted: {key}")
    if job["kind"] in STAGED_JOB_KINDS:
        current = staged_inputs(job["kind"], source)
        if any(inputs.get(key) != value for key, value in current.items()):
            raise Refusal("staged job policy, oracle or script inputs drifted")
    elif job["kind"] == "profiler-only":
        current_reuse = archived_reuse(source, artifacts, str(inputs["phase3_tree_oid"]))
        if inputs.get("reuse") != current_reuse:
            raise Refusal("archived journey reuse inputs drifted")
    elif job["kind"] in ("qualification", "glm-prefill"):
        policy, policy_sha = read_safe_object(source / POLICY_RELATIVE, "qualification policy")
        (validate_glm_prefill_policy if job["kind"] == "glm-prefill" else validate_policy)(policy)
        projected = projection_tuple(source)
        if (
            inputs.get("qualification_policy_sha256") != policy_sha
            or inputs.get("qualification_provider_commit") != policy.get("provider_commit")
            or inputs.get("qualification_cells") != (
                glm_prefill_cells(policy) if job["kind"] == "glm-prefill" else list(QUALIFICATION_CELLS)
            )
            or any(policy.get(key) != projected[key] for key in ("target_sha256", "mtp_sha256", "tokenizer_sha256"))
        ):
            raise Refusal("qualification policy identity drifted")
        if git_value(source, f"{policy['provider_commit']}:phase3-binary", "policy phase3 tree") != inputs.get("phase3_tree_oid"):
            raise Refusal("qualification policy provider source drifted")
    else:
        policy, policy_sha = read_safe_object(source / POLICY_RELATIVE, "Qwen qualification policy")
        validate_qwen_policy(policy)
        projected, projection_sha = qwen_projection_tuple(source)
        if (
            inputs.get("qualification_policy_sha256") != policy_sha
            or inputs.get("qualification_provider_commit") != policy.get("provider_commit")
            or inputs.get("artifact_projection_sha256") != projection_sha
            or inputs.get("artifact_projection") != projected
            or any(
                policy.get(key) != projected[key]
                for key in ("target_sha256", "mtp_sha256", "tokenizer_sha256")
            )
        ):
            raise Refusal("Qwen qualification policy or projection identity drifted")
        if job["kind"] == "qwen-qualification":
            if inputs.get("qualification_cells") != list(QWEN_QUALIFICATION_CELLS):
                raise Refusal("Qwen qualification cells drifted")
        elif inputs.get("journey_profile") != QWEN_JOURNEY_PROFILE:
            raise Refusal("Qwen journey profile drifted")
        if (
            git_value(source, f"{policy['provider_commit']}:phase3-binary", "Qwen policy phase3 tree")
            != inputs.get("phase3_tree_oid")
        ):
            raise Refusal("Qwen qualification policy provider source drifted")


def controlled_environment() -> dict[str, str]:
    return {
        "HOME": str(Path.home()),
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin",
        "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
        "DEVELOPER_DIR": str(Path.home() / "Applications/Xcode.app/Contents/Developer"),
        "MACPROVIDER_LAB_OFFLINE": "1",
        "MACPROVIDER_NATIVE_MTP_E2E": "1",
    }


def snapshot_stamps(root: Path, maximum: int = 100_000) -> list[dict[str, int | str]]:
    root = root.resolve(strict=True)
    if not root.is_dir():
        raise Refusal("fixture target is not a directory")
    stamps: list[dict[str, int | str]] = []
    stack = [root]
    while stack:
        directory = stack.pop()
        for entry in os.scandir(directory):
            path = Path(entry.path)
            info = path.lstat()
            if stat.S_ISDIR(info.st_mode):
                stack.append(path)
                continue
            if not stat.S_ISREG(info.st_mode) or info.st_nlink > 1:
                raise Refusal("fixture contains a symlink, hardlink, or non-regular file")
            relative = path.relative_to(root).as_posix()
            try:
                relative.encode("ascii")
            except UnicodeEncodeError as exc:
                raise Refusal("fixture contains a non-ASCII relative path") from exc
            if not relative or "\n" in relative or "\r" in relative:
                raise Refusal("fixture contains an unsafe relative path")
            if len(stamps) >= maximum:
                raise Refusal("fixture contains too many files")
            stamps.append({
                "path": relative, "size": info.st_size, "device": info.st_dev,
                "inode": info.st_ino, "mtime_ns": info.st_mtime_ns,
                "ctime_ns": info.st_ctime_ns,
            })
    return sorted(stamps, key=lambda item: str(item["path"]))


def snapshot_identity(root: Path) -> tuple[str, list[dict[str, int | str]]]:
    root = root.resolve(strict=True)
    before = snapshot_stamps(root)
    manifest = hashlib.sha256()
    for stamp_value in before:
        path = root / str(stamp_value["path"])
        digest = hashlib.sha256()
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        try:
            opened = os.fstat(fd)
            current = {
                "path": stamp_value["path"], "size": opened.st_size,
                "device": opened.st_dev, "inode": opened.st_ino,
                "mtime_ns": opened.st_mtime_ns, "ctime_ns": opened.st_ctime_ns,
            }
            if current != stamp_value or not stat.S_ISREG(opened.st_mode) or opened.st_nlink > 1:
                raise Refusal("fixture changed while hashing")
            for block in iter(lambda: os.read(fd, 4 * 1024 * 1024), b""):
                digest.update(block)
            after = os.fstat(fd)
            if (
                after.st_size, after.st_dev, after.st_ino, after.st_mtime_ns, after.st_ctime_ns
            ) != (
                opened.st_size, opened.st_dev, opened.st_ino,
                opened.st_mtime_ns, opened.st_ctime_ns,
            ):
                raise Refusal("fixture changed while hashing")
        finally:
            os.close(fd)
        manifest.update(
            f"{stamp_value['path']}\n{stamp_value['size']}\n{digest.hexdigest()}\n".encode()
        )
    if snapshot_stamps(root, len(before) + 1) != before:
        raise Refusal("fixture changed while hashing")
    return manifest.hexdigest(), before


def preflight_path(manifest: dict) -> Path:
    return Path(manifest["_manifest_path"]).parent / f"preflight-{manifest['nonce']}"


def private_artifact_paths(manifest: dict, job: dict) -> dict[str, Path]:
    root = preflight_path(manifest) / "artifacts"
    if job["kind"] in STAGED_JOB_KINDS:
        return staged_private_paths(root, job["kind"])
    paths = {
        "diagnostic_cli": root / "provider/macprovider-cli",
        "diagnostic_metallib": root / "provider/mlx.metallib",
    }
    if job["kind"] not in CLI_ONLY_JOB_KINDS:
        paths.update({
            "glmbench": root / "bench/GLMBench",
            "glmbench_metallib": root / "bench/mlx.metallib",
        })
    if job["kind"] in QUALIFICATION_KINDS or job["kind"] in ("qwen-journey", "glm-prefill"):
        paths["qualification_policy"] = root / "qualification-policy.json"
    if job["kind"] in QWEN_JOB_KINDS:
        paths["artifact_projection"] = root / "qwen-artifact-manifest.json"
    return paths


def copy_authenticated(source: Path, destination: Path, expected_sha: str, *, executable: bool) -> None:
    source = safe_artifact(source, executable=executable)
    before = source.lstat()
    source_fd = os.open(
        source, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    )
    destination_fd = -1
    digest = hashlib.sha256()
    try:
        opened = os.fstat(source_fd)
        if (
            (opened.st_dev, opened.st_ino, opened.st_size, opened.st_mtime_ns, opened.st_ctime_ns)
            != (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns)
        ):
            raise Refusal("bound artifact changed while opening")
        destination_fd = os.open(
            destination,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
            0o700 if executable else 0o600,
        )
        for block in iter(lambda: os.read(source_fd, 1024 * 1024), b""):
            digest.update(block)
            view = memoryview(block)
            while view:
                written = os.write(destination_fd, view)
                if written <= 0:
                    raise Refusal("bound artifact copy made no progress")
                view = view[written:]
        after = os.fstat(source_fd)
        if (
            (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns)
            != (opened.st_dev, opened.st_ino, opened.st_size, opened.st_mtime_ns, opened.st_ctime_ns)
            or digest.hexdigest() != expected_sha
        ):
            raise Refusal("bound artifact changed or has the wrong digest")
        os.fsync(destination_fd)
    finally:
        os.close(source_fd)
        if destination_fd >= 0:
            os.close(destination_fd)
    if file_sha256(safe_artifact(destination, executable=executable)) != expected_sha:
        raise Refusal("private artifact copy verification failed")


def prepare_private_artifacts(manifest: dict, job: dict) -> None:
    paths = private_artifact_paths(manifest, job)
    root = preflight_path(manifest) / "artifacts"
    create_result_dir(root)
    if job["kind"] in STAGED_JOB_KINDS:
        staged_prepare_private(manifest, job, root, paths)
        return
    create_result_dir(root / "provider")
    if job["kind"] not in CLI_ONLY_JOB_KINDS:
        create_result_dir(root / "bench")
    source_artifacts = manifest["artifacts"]
    expected = job["immutable_inputs"]["artifact_sha256"]
    artifact_keys = (
        ("diagnostic_cli", "diagnostic_metallib")
        if job["kind"] in CLI_ONLY_JOB_KINDS
        else ("diagnostic_cli", "diagnostic_metallib", "glmbench", "glmbench_metallib")
    )
    for key in artifact_keys:
        copy_authenticated(
            Path(source_artifacts[key]["path"]), paths[key], expected[key],
            executable=key in {"diagnostic_cli", "glmbench"},
        )
    if job["kind"] in QUALIFICATION_KINDS or job["kind"] in ("qwen-journey", "glm-prefill"):
        copy_authenticated(
            Path(manifest["lab_source_dir"]) / POLICY_RELATIVE,
            paths["qualification_policy"],
            job["immutable_inputs"]["qualification_policy_sha256"],
            executable=False,
        )
    if job["kind"] in QWEN_JOB_KINDS:
        copy_authenticated(
            Path(manifest["lab_source_dir"]) / QWEN_PROJECTION_RELATIVE,
            paths["artifact_projection"],
            job["immutable_inputs"]["artifact_projection_sha256"],
            executable=False,
        )
    directories = [root / "provider"]
    if job["kind"] not in CLI_ONLY_JOB_KINDS:
        directories.append(root / "bench")
    directories.append(root)
    for directory in directories:
        fd = os.open(directory, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(fd)
        finally:
            os.close(fd)


def validate_private_artifacts(manifest: dict, job: dict) -> dict[str, str]:
    expected = job["immutable_inputs"]["artifact_sha256"]
    result: dict[str, str] = {}
    root = preflight_path(manifest) / "artifacts"
    if job["kind"] in STAGED_JOB_KINDS:
        return staged_validate_private(manifest, job, root)
    directories = [preflight_path(manifest), root, root / "provider"]
    if job["kind"] not in CLI_ONLY_JOB_KINDS:
        directories.append(root / "bench")
    for directory in directories:
        safe_directory(directory)
    for key, path in private_artifact_paths(manifest, job).items():
        if key == "qualification_policy":
            expected_sha = job["immutable_inputs"]["qualification_policy_sha256"]
        elif key == "artifact_projection":
            expected_sha = job["immutable_inputs"]["artifact_projection_sha256"]
        else:
            expected_sha = expected[key]
        actual = file_sha256(safe_artifact(path, executable=key in {"diagnostic_cli", "glmbench"}))
        if actual != expected_sha:
            raise Refusal(f"private job artifact drifted: {key}")
        result[key] = actual
    return result


def valid_stamp_list(value: object) -> bool:
    keys = {"path", "size", "device", "inode", "mtime_ns", "ctime_ns"}
    return (
        isinstance(value, list)
        and len(value) <= 100_000
        and all(
            isinstance(item, dict)
            and set(item) == keys
            and isinstance(item["path"], str)
            and item["path"].isascii()
            and item["path"]
            and all(type(item[key]) is int for key in keys - {"path"})
            for item in value
        )
    )


def validate_preflight_receipt(manifest: dict, job: dict) -> None:
    safe_directory(preflight_path(manifest))
    receipt, _ = read_safe_object(preflight_path(manifest) / "identity.json", "job preflight")
    if job["kind"] in STAGED_JOB_KINDS:
        staged_validate_receipt(manifest, job, receipt)
        return
    target = Path(manifest["lab_source_dir"]) / ".lab-window/fixture/target"
    mtp = Path(manifest["lab_source_dir"]) / ".lab-window/fixture/mtp"
    expected = receipt.get("expected")
    qwen = job["kind"] in QWEN_JOB_KINDS
    current_expected = (
        job["immutable_inputs"]["artifact_projection"]
        if qwen else projection_tuple(Path(manifest["lab_source_dir"]))
    )
    if (
        receipt.get("schema_version") != PREFLIGHT_SCHEMA
        or receipt.get("nonce") != manifest["nonce"]
        or receipt.get("job_identity_sha256") != job["identity_sha256"]
        or receipt.get("algorithm") != "macprovider.snapshot-manifest.v1"
        or receipt.get("canonical_target_root") != str(target.resolve(strict=True))
        or not isinstance(expected, dict)
        or expected != current_expected
        or receipt.get("observed_target_sha256") != expected.get("target_sha256")
        or not valid_stamp_list(receipt.get("target_stamps"))
    ):
        raise Refusal("job preflight identity is invalid")
    if snapshot_stamps(target, len(receipt["target_stamps"]) + 1) != receipt["target_stamps"]:
        raise Refusal("fixture changed after job preflight")
    if qwen and (
        receipt.get("canonical_mtp_root") != str(mtp.resolve(strict=True))
        or receipt.get("observed_mtp_sha256") != expected.get("mtp_sha256")
        or not valid_stamp_list(receipt.get("mtp_stamps"))
    ):
        raise Refusal("Qwen MTP preflight identity is invalid")
    if qwen and snapshot_stamps(mtp, len(receipt["mtp_stamps"]) + 1) != receipt["mtp_stamps"]:
        raise Refusal("MTP fixture changed after job preflight")


def validate_execution_inputs(manifest: dict, job: dict) -> dict[str, str]:
    validate_current_job_inputs(manifest, job)
    private_hashes = validate_private_artifacts(manifest, job)
    validate_preflight_receipt(manifest, job)
    return private_hashes


def qualification_base(manifest: dict, output: Path) -> list[str]:
    inputs = manifest["job"]["immutable_inputs"]
    private = private_artifact_paths(manifest, manifest["job"])
    source = Path(manifest["lab_source_dir"])
    model_id = (
        "qwen/qwen3.6-35b-a3b"
        if manifest["job"]["kind"] == "qwen-qualification"
        else "zai-org/glm-5.3-flash"
    )
    return [
        str(private["diagnostic_cli"]),
        "native-mtp-bench", "--root", str(source / ".lab-window/fixture"),
        "--model-id", model_id,
        "--policy", str(private["qualification_policy"]),
        "--out", str(output),
        "--provider-commit", str(inputs["qualification_provider_commit"]),
    ]


def run_checked(argv: list[str], output: Path, *, timeout: int = 3600) -> None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(output, flags, 0o600)
    try:
        with os.fdopen(fd, "wb", closefd=True) as stream:
            result = subprocess.run(
                ["/usr/bin/nice", "-n", "19", *argv],
                stdin=subprocess.DEVNULL, stdout=stream, stderr=subprocess.STDOUT,
                env=controlled_environment(), timeout=timeout,
            )
            stream.flush()
            os.fsync(stream.fileno())
    except subprocess.TimeoutExpired as exc:
        raise Refusal(
            f"fixed job command timed out: {Path(argv[0]).name}; private log: {output}"
        ) from exc
    if result.returncode != 0:
        raise Refusal(
            f"fixed job command failed: {Path(argv[0]).name}; private log: {output}"
        )


def validate_qwen_journey_result(path: Path, job: dict) -> None:
    try:
        path = safe_artifact(path)
        if path.stat().st_size > 32 * 1024 * 1024:
            raise Refusal(f"Qwen journey result is too large; private log: {path}")
        lines = path.read_bytes().splitlines()
        document = json.loads(lines[-1])
    except (IndexError, ValueError) as exc:
        raise Refusal(f"Qwen journey result is invalid; private log: {path}") from exc
    profile = job["immutable_inputs"]["journey_profile"]
    projection = job["immutable_inputs"]["artifact_projection"]
    expected_steps = {
        "step-04-serial-token-oracle": ("pass", []),
        "step-05-cache-state-boundary": ("pass", []),
        "step-06-streaming-stop": ("pass", []),
        "step-07-08-mixed-multirow-capacity": ("pass", []),
        "step-09-cancellation": ("pass", []),
        "step-10-warm-swap": ("pass", []),
        "step-12-native-selftest": (
            "partial",
            ["coordinator-issued SPEC-031-R033 canary and its negative outcomes"],
        ),
    }
    expected_covered = [
        "step-04-serial-token-oracle",
        "step-05-cache-state-boundary",
        "step-06-streaming-stop",
        "step-07-mixed-multirow",
        "step-08-capacity-and-depth-zero",
        "step-09-cancellation",
        "step-10-warm-swap",
        "step-12-native-canary (provider-local self-test half)",
    ]
    expected_pending = [
        "step-01-bind-tuple",
        "step-02-capability-negatives",
        "step-03-artifact-security-negatives",
        "step-11-accounting",
        "step-12-native-canary (coordinator SPEC-031-R033 half)",
        "step-14-studio-and-tier-benchmark",
        "step-15-redaction-review",
    ]
    if (
        not isinstance(document, dict)
        or document.get("schema") != "macprovider.native-mtp-journey-hardware-result.v1"
        or document.get("journey_complete") is not False
        or document.get("executed_steps_status") != "partial"
        or document.get("evidence_class") != "lab_isolated_no_join"
        or document.get("covered_steps") != expected_covered
        or document.get("pending_steps") != expected_pending
        or any(document.get(key) != profile[key] for key in (
            "model_id", "qualified_slots", "max_native_active_rows",
            "max_prompt_tokens", "request_feature_profile",
        ))
        or any(document.get(key) != projection[key] for key in (
            "target_sha256", "mtp_sha256", "tokenizer_sha256", "mtp_manifest_sha256",
        ))
    ):
        raise Refusal(f"Qwen journey identity or coverage mismatch; private log: {path}")
    steps = document.get("steps")
    if not isinstance(steps, list) or len(steps) != len(expected_steps):
        raise Refusal(f"Qwen journey step set is invalid; private log: {path}")
    observed: set[str] = set()
    for step in steps:
        if not isinstance(step, dict) or set(step) != {
            "step_id", "status", "uncovered_contract", "checks", "details",
        }:
            raise Refusal(f"Qwen journey step is invalid; private log: {path}")
        step_id = step.get("step_id")
        checks = step.get("checks")
        expected_step = expected_steps.get(step_id)
        if (
            expected_step is None
            or step_id in observed
            or step.get("status") != expected_step[0]
            or step.get("uncovered_contract") != expected_step[1]
            or not isinstance(step.get("details"), dict)
            or not isinstance(checks, dict)
            or not checks
            or any(value is not True for value in checks.values())
        ):
            raise Refusal(f"Qwen journey hardware check failed; private log: {path}")
        observed.add(step_id)
    if observed != set(expected_steps):
        raise Refusal(f"Qwen journey step set is invalid; private log: {path}")


def validate_job(args: argparse.Namespace) -> dict[str, object]:
    manifest, job = load_job_manifest(args.manifest)
    validate_current_job_inputs(manifest, job)
    source = Path(manifest["lab_source_dir"])
    preflight = preflight_path(manifest)
    if preflight.exists():
        validate_preflight_receipt(manifest, job)
        validate_private_artifacts(manifest, job)
        return {"kind": job["kind"], "identity_sha256": job["identity_sha256"], "validated": True}
    create_result_dir(preflight)
    prepare_private_artifacts(manifest, job)
    if job["kind"] in STAGED_JOB_KINDS:
        write_result(preflight / "identity.json", staged_preflight(manifest, job, preflight))
        validate_execution_inputs(manifest, job)
        return {"kind": job["kind"], "identity_sha256": job["identity_sha256"], "validated": True}
    target = source / ".lab-window/fixture/target"
    qwen = job["kind"] in QWEN_JOB_KINDS
    expected = job["immutable_inputs"]["artifact_projection"] if qwen else projection_tuple(source)
    mtp = source / ".lab-window/fixture/mtp"
    mtp_stamps = None
    if job["kind"] == "profiler-only":
        target_digest, target_stamps = snapshot_identity(target)
        reuse = job["immutable_inputs"]["reuse"]
        if target_digest != reuse["target_sha256"]:
            raise Refusal("profiler fixture identity differs from archived journey")
        tokenizer = target / "tokenizer.json"
        if file_sha256(safe_artifact(tokenizer)) != reuse["tokenizer_sha256"]:
            raise Refusal("profiler tokenizer identity differs from archived journey")
        config = target / "config.json"
        if file_sha256(safe_artifact(config)) != reuse["mtp_manifest_sha256"]:
            raise Refusal("profiler MTP manifest identity differs from archived journey")
    elif job["kind"] == "qwen-journey":
        target_digest, target_stamps = snapshot_identity(target)
        mtp_digest, mtp_stamps = snapshot_identity(mtp)
        if (
            target_digest != expected["target_sha256"]
            or mtp_digest != expected["mtp_sha256"]
            or file_sha256(safe_artifact(target / "tokenizer.json"))
            != expected["tokenizer_sha256"]
            or file_sha256(safe_artifact(mtp / "config.json"))
            != expected["mtp_manifest_sha256"]
        ):
            raise Refusal("Qwen journey fixture projection identity mismatch")
    else:
        target_stamps = snapshot_stamps(target)
        if qwen:
            mtp_stamps = snapshot_stamps(mtp)
        # Swift's preflight creates the evidence parent, so keep it distinct
        # from the create-exclusive result directory used after the pause.
        argv = qualification_base(manifest, preflight / "qualification.jsonl") + ["--validate-only"]
        run_checked(argv, preflight / "validate.log", timeout=600)
        if snapshot_stamps(target, len(target_stamps) + 1) != target_stamps:
            raise Refusal("fixture changed during qualification preflight")
        if qwen and snapshot_stamps(mtp, len(mtp_stamps or []) + 1) != mtp_stamps:
            raise Refusal("MTP fixture changed during qualification preflight")
        try:
            summary = json.loads((preflight / "validate.log").read_text().splitlines()[-1])
        except (IndexError, ValueError) as exc:
            raise Refusal(
                f"qualification preflight summary is invalid; private log: {preflight / 'validate.log'}"
            ) from exc
        target_digest = summary.get("target_sha256")
        cells = job["immutable_inputs"]["qualification_cells"]
        sustained_cell = (
            "s4-p16384-o128" if job["kind"] == "glm-prefill" else (
                "s8-p1536-o512" if qwen else "s4-p1536-o512"
            )
        )
        if (
            summary.get("validate_only") != "pass"
            or target_digest != expected["target_sha256"]
            or summary.get("mtp_sha256") != expected["mtp_sha256"]
            or summary.get("tokenizer_sha256") != expected["tokenizer_sha256"]
            or summary.get("policy_sha256") != job["immutable_inputs"]["qualification_policy_sha256"]
            or summary.get("cells") != list(cells)
            or summary.get("sustained_cell_id") != sustained_cell
            or summary.get("existing_records") is not False
        ):
            raise Refusal("qualification preflight fixture identity mismatch")
        if qwen:
            target_digest_local, verified_target_stamps = snapshot_identity(target)
            mtp_digest_local, verified_mtp_stamps = snapshot_identity(mtp)
            if (
                target_digest_local != expected["target_sha256"]
                or mtp_digest_local != expected["mtp_sha256"]
                or verified_target_stamps != target_stamps
                or verified_mtp_stamps != mtp_stamps
                or file_sha256(safe_artifact(target / "tokenizer.json"))
                != expected["tokenizer_sha256"]
                or file_sha256(safe_artifact(mtp / "config.json"))
                != expected["mtp_manifest_sha256"]
            ):
                raise Refusal("Qwen fixture projection identity mismatch")
    receipt = {
        "schema_version": PREFLIGHT_SCHEMA,
        "nonce": manifest["nonce"],
        "job_identity_sha256": job["identity_sha256"],
        "canonical_target_root": str(target.resolve(strict=True)),
        "algorithm": "macprovider.snapshot-manifest.v1",
        "expected": expected,
        "observed_target_sha256": target_digest,
        "target_stamps": target_stamps,
    }
    if qwen:
        receipt.update({
            "canonical_mtp_root": str(mtp.resolve(strict=True)),
            "observed_mtp_sha256": expected["mtp_sha256"],
            "mtp_stamps": mtp_stamps,
        })
    write_result(preflight / "identity.json", receipt)
    validate_execution_inputs(manifest, job)
    return {"kind": job["kind"], "identity_sha256": job["identity_sha256"], "validated": True}


def create_result_dir(path: Path) -> None:
    parent = path.parent
    safe_directory(parent)
    try:
        path.mkdir(mode=0o700)
    except FileExistsError as exc:
        raise Refusal("fixed job result directory already exists") from exc
    fsync = os.open(parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(fsync)
    finally:
        os.close(fsync)


def write_result(path: Path, value: dict) -> None:
    data = (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
    with os.fdopen(fd, "wb", closefd=True) as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())
    parent_fd = os.open(path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(parent_fd)
    finally:
        os.close(parent_fd)


def run_job(args: argparse.Namespace) -> dict[str, object]:
    manifest, job = load_job_manifest(args.manifest)
    private_hashes = validate_execution_inputs(manifest, job)
    source = Path(manifest["lab_source_dir"])
    result = Path(manifest["_result_dir"])
    create_result_dir(result)
    outputs: list[Path] = []
    if job["kind"] in STAGED_JOB_KINDS:
        return staged_run(manifest, job, result)
    if job["kind"] == "profiler-only":
        bench = str(private_artifact_paths(manifest, job)["glmbench"])
        target = str(source / ".lab-window/fixture/target")
        wall = result / "component-wall.log"
        census = result / "component-census.log"
        validate_execution_inputs(manifest, job)
        run_checked([
            bench, target, "--mtp-multirow-profile", "--mtp-multirow-measurement-mode",
            "wall-only", "--mtp-multirow-reps", "5",
        ], wall)
        validate_execution_inputs(manifest, job)
        run_checked([bench, target, "--mtp-multirow-profile", "--mtp-multirow-reps", "1"], census)
        outputs.extend((wall, census))
    elif job["kind"] == "qwen-journey":
        journey = result / "journey.log"
        profile = job["immutable_inputs"]["journey_profile"]
        validate_execution_inputs(manifest, job)
        run_checked([
            str(private_artifact_paths(manifest, job)["diagnostic_cli"]),
            "native-mtp-journey-e2e",
            "--root", str(source / ".lab-window/fixture"),
            "--model-id", str(profile["model_id"]),
            "--qualified-slots", str(profile["qualified_slots"]),
            "--max-native-active-rows", str(profile["max_native_active_rows"]),
            "--max-prompt-tokens", str(profile["max_prompt_tokens"]),
        ], journey, timeout=5400)
        validate_qwen_journey_result(journey, job)
        outputs.append(journey)
    else:
        evidence = result / "qualification.jsonl"
        base = qualification_base(manifest, evidence)
        cells = job["immutable_inputs"]["qualification_cells"]
        for index, cell in enumerate(cells, 1):
            log = result / f"matrix-{index:02d}-{cell}.log"
            validate_execution_inputs(manifest, job)
            run_checked(
                base + ["--only-cell", cell, "--phase", "matrix"], log,
                timeout=7200 if job["kind"] == "glm-prefill" else 3600,
            )
            outputs.append(log)
        if job["kind"] != "glm-prefill":
            sustained = result / "sustained.log"
            validate_execution_inputs(manifest, job)
            run_checked(base + ["--phase", "sustained"], sustained)
            outputs.append(sustained)
        outputs.append(evidence)
        if job["kind"] == "qwen-qualification":
            selftest = result / "selftest.log"
            validate_execution_inputs(manifest, job)
            run_checked([
                str(private_artifact_paths(manifest, job)["diagnostic_cli"]),
                "native-mtp-journey-e2e",
                "--root", str(source / ".lab-window/fixture"),
                "--model-id", "qwen/qwen3.6-35b-a3b",
                "--qualified-slots", "8",
                "--max-native-active-rows", "1",
                "--max-prompt-tokens", "4096",
                "--selftest-only",
            ], selftest)
            outputs.append(selftest)
    private_hashes = validate_execution_inputs(manifest, job)
    receipt = {
        "schema_version": JOB_RESULT_SCHEMA,
        "kind": job["kind"],
        "identity_sha256": job["identity_sha256"],
        "completed_unix": int(time.time()),
        "qualification_activated": False,
        "executed_inputs": {
            "private_artifact_sha256": private_hashes,
            "fixture_target_sha256": (
                job["immutable_inputs"]["artifact_projection"]["target_sha256"]
                if job["kind"] in QWEN_JOB_KINDS
                else projection_tuple(source)["target_sha256"]
            ),
        },
        "outputs": {item.name: file_sha256(safe_artifact(item)) for item in outputs},
    }
    if job["kind"] == "glm-prefill":
        receipt.update(exploratory=True, qualification=False, evidence_class="glm_prefill_measurement_only")
    if job["kind"] in QWEN_JOB_KINDS:
        receipt["executed_inputs"]["fixture_mtp_sha256"] = (
            job["immutable_inputs"]["artifact_projection"]["mtp_sha256"]
        )
    write_result(result / "result.json", receipt)
    return {**receipt, "result_path": str(result / "result.json")}


# ---------------------------------------------------------------------------
# Staged measurement jobs (#2100, #2111). Each component has a fixed policy,
# a hash-bound fixture and a fixed command. A sequence kind runs several
# components inside one provider pause; the supervisor restores the provider
# once, after the whole child exits. Nothing here qualifies or activates.

STAGED_JOB_KINDS = {
    "glm-parity-prefill512": ("glm-parity-prefill512",),
    "dsv4-reference": ("dsv4-reference",),
    "glm-parity-prefill512-then-dsv4-reference": ("glm-parity-prefill512", "dsv4-reference"),
}
STAGED_COMPONENT_FIELDS = {
    "glm-parity-prefill512": {"diagnostic_cli", "diagnostic_metallib", "fixture_config", "fixture_index"},
    "dsv4-reference": {"reference_python", "reference_script", "dsv4_fixture_config", "dsv4_fixture_index"},
}
STAGED_COMPONENT_ROOTS = {
    "glm-parity-prefill512": ".lab-window/fixture/target",
    "dsv4-reference": ".lab-window/fixture/dsv4-target",
}
# Per-command deadlines; the window ceiling covers the sum plus model loads.
STAGED_COMMAND_TIMEOUTS = {"glm-parity-prefill512": 2700, "dsv4-reference": 5400}
STAGED_WINDOW_TIMEOUTS = {
    "glm-parity-prefill512": 3600,
    "dsv4-reference": 7200,
    "glm-parity-prefill512-then-dsv4-reference": 9000,
}
STAGED_PREFLIGHT_SCHEMA = "macprovider.studio_lab_window_staged_preflight.v1"
DECODE_PATH_MARKER = re.compile(rb"macprovider\.decode-path-digest\.v1:([0-9a-f]{64})")

GLM_PARITY_POLICY_RELATIVE = Path(".lab-window/glm-parity-policy.json")
GLM_PARITY_ORACLE_RELATIVE = Path(".lab-window/glm-parity/oracle_8192.json")
GLM_PARITY_PROFILE = {"steps": 256, "prefill_step_size": 512, "mlx_cache_limit_mb": 4096}
GLM_PARITY_POLICY = {
    "schema": "macprovider.glm-parity-prefill512-policy.v1",
    "model_id": "zai-org/glm-5.3-flash",
    "oracle": "oracle_8192.json",
    "prompt_tokens": 8192,
    "evidence_class": "glm_parity_prefill512_measurement_only",
    **GLM_PARITY_PROFILE,
}
GLM_PARITY_POLICY_SHAS = ("target_sha256", "oracle_sha256", "decode_path_digest")

DSV4_POLICY_RELATIVE = Path(".lab-window/dsv4-reference-policy.json")
DSV4_TREE_RELATIVE = "scripts/lab/dsv4"
# Fixed reference run (#2111): the argv comes from this constant, never from a file.
DSV4_REFERENCE_PROFILE = {
    "oracle_contexts": [1024, 8192, 32768], "ttft_contexts": [4096, 32768],
    "rows": [1, 4], "row_prompt": 1024, "decode": 256,
}
DSV4_REFERENCE_POLICY = {
    "schema": "macprovider.dsv4-reference-policy.v1",
    "model_id": "deepseek-ai/deepseek-v4-flash-0731",
    "artifact_repo": "TensorFold/DeepSeek-V4-Flash-0731-MXFP4-MLX",
    "artifact_revision": "d6be051ae238b2021de56cf098d8f0206328754a",
    "environment": {"mlx": "0.32.4", "mlx-metal": "0.32.4", "mlx-vlm": "0.7.10"},
    "temperature": 0,
    "evidence_class": "dsv4_reference_measurement_only",
    **DSV4_REFERENCE_PROFILE,
}
# Reads installed distribution metadata only; it never imports mlx or loads a model.
DSV4_ENVIRONMENT_PROBE = (
    "import importlib.metadata as m, json, sys; "
    "print(json.dumps({p: m.version(p) for p in sys.argv[1:]}, sort_keys=True))"
)
STAGED_INPUT_KEYS = {
    "glm-parity-prefill512": {
        "glm_parity_policy_sha256", "glm_parity_target_sha256",
        "glm_parity_oracle_sha256", "glm_parity_decode_path_digest",
    },
    "dsv4-reference": {"reference_tree_oid", "reference_policy_sha256", "reference_target_sha256"},
}


STAGED_POLICY_MAX_BYTES = 64 * 1024
STAGED_REPORT_MAX_BYTES = 32 * 1024 * 1024
DECODE_MANIFEST_RELATIVE = "phase3-binary/decode-path-manifest.json"
DECODE_RESOLVED_RELATIVE = "phase3-binary/Package.resolved"


def read_bounded(path: Path, limit: int, name: str) -> bytes:
    target = safe_artifact(path)
    fd = os.open(target, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        if os.fstat(fd).st_size > limit:
            raise Refusal(f"{name} exceeds {limit} bytes: {path}")
        data = os.read(fd, limit + 1)
    finally:
        os.close(fd)
    if len(data) > limit:
        raise Refusal(f"{name} exceeds {limit} bytes: {path}")
    return data


def read_staged_policy(path: Path, name: str) -> tuple[dict, str]:
    data = read_bounded(path, STAGED_POLICY_MAX_BYTES, name)
    try:
        value = json.loads(data)
    except ValueError as exc:
        raise Refusal(f"{name} is invalid JSON") from exc
    if not isinstance(value, dict):
        raise Refusal(f"{name} is not a JSON object")
    return value, hashlib.sha256(data).hexdigest()


def source_decode_path_digest(source: Path) -> str:
    """scripts/decode_path_digest.py's algorithm over the tracked-clean source."""
    package = source / "phase3-binary"
    manifest, _ = read_staged_policy(source / DECODE_MANIFEST_RELATIVE, "decode-path manifest")
    files, dependencies = manifest.get("files"), manifest.get("dependencies")
    if (
        manifest.get("schema_version") != "macprovider.decode-path-manifest.v1"
        or not isinstance(files, list) or not isinstance(dependencies, list)
        or not files or not dependencies
        or any(not isinstance(item, str) or not item.startswith("Sources/") or ".." in item.split("/")
               for item in files)
    ):
        raise Refusal("decode-path manifest is invalid")
    resolved = json.loads(read_bounded(source / DECODE_RESOLVED_RELATIVE, 1024 * 1024, "Package.resolved"))
    revisions = {
        pin.get("identity"): (pin.get("state") or {}).get("revision")
        for pin in resolved.get("pins") or [] if isinstance(pin, dict)
    }
    lines = ["macprovider.decode-path-digest.v1"]
    for item in files:
        lines.append(f"file {item} {file_sha256(safe_artifact(package / item))}")
    for identity in dependencies:
        revision = revisions.get(identity)
        if not isinstance(revision, str) or not SHA40.fullmatch(revision):
            raise Refusal(f"Package.resolved has no revision for {identity}")
        lines.append(f"dependency {identity} {revision}")
    return hashlib.sha256(("\n".join(lines) + "\n").encode()).hexdigest()


def safe_fixture_tree(root: Path) -> None:
    # Every directory and file must be the operator's and not writable by
    # group or other, so no other account can change weights after preflight.
    root = root.resolve(strict=True)
    stack = [root]
    while stack:
        directory = stack.pop()
        info = directory.lstat()
        if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o022:
            raise Refusal(f"fixture directory is not operator-only writable: {directory}")
        with os.scandir(directory) as entries:
            children = [Path(entry.path) for entry in entries]
        for path in children:
            entry_info = path.lstat()
            if stat.S_ISDIR(entry_info.st_mode):
                stack.append(path)
            elif entry_info.st_uid != os.getuid() or stat.S_IMODE(entry_info.st_mode) & 0o022:
                raise Refusal(f"fixture file is not operator-only writable: {path}")


def validate_fixed_policy(value: dict, fixed: dict, shas: tuple[str, ...], name: str) -> None:
    if set(value) != set(fixed) | set(shas):
        raise Refusal(f"{name} policy fields are not the fixed contract")
    for key, expected in fixed.items():
        actual = value.get(key)
        if actual != expected or type(actual) is not type(expected) or (
            isinstance(expected, list) and any(type(item) is not int for item in actual)
        ):
            raise Refusal(f"{name} policy {key} is not the fixed contract")
    for key in shas:
        require_sha(value.get(key), f"{name} policy {key}")


def validate_dsv4_reference_policy(value: dict) -> None:
    validate_fixed_policy(value, DSV4_REFERENCE_POLICY, ("target_sha256",), "DeepSeek V4 reference")


def validate_glm_parity_policy(value: dict) -> None:
    validate_fixed_policy(value, GLM_PARITY_POLICY, GLM_PARITY_POLICY_SHAS, "GLM parity prefill512")


def component_inputs(component: str, source: Path) -> dict[str, str]:
    if component == "glm-parity-prefill512":
        policy, policy_sha = read_staged_policy(source / GLM_PARITY_POLICY_RELATIVE, "GLM parity policy")
        validate_glm_parity_policy(policy)
        oracle = file_sha256(safe_artifact(source / GLM_PARITY_ORACLE_RELATIVE))
        if oracle != policy["oracle_sha256"]:
            raise Refusal("GLM parity oracle differs from its policy")
        return {
            "glm_parity_policy_sha256": policy_sha,
            "glm_parity_target_sha256": policy["target_sha256"],
            "glm_parity_oracle_sha256": oracle,
            "glm_parity_decode_path_digest": policy["decode_path_digest"],
        }
    policy, policy_sha = read_staged_policy(source / DSV4_POLICY_RELATIVE, "DeepSeek V4 reference policy")
    validate_dsv4_reference_policy(policy)
    return {
        "reference_tree_oid": git_value(source, f"HEAD:{DSV4_TREE_RELATIVE}", "reference script tree"),
        "reference_policy_sha256": policy_sha,
        "reference_target_sha256": policy["target_sha256"],
    }


def staged_inputs(kind: str, source: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for component in STAGED_JOB_KINDS[kind]:
        result.update(component_inputs(component, source))
    return result


def validate_staged_inputs(kind: str, inputs: dict) -> None:
    expected = {"phase3_tree_oid", "lab_script_sha256", "job_helper_sha256", "artifact_sha256"}
    for component in STAGED_JOB_KINDS[kind]:
        expected |= STAGED_INPUT_KEYS[component]
    if set(inputs) != expected:
        raise Refusal("job immutable input schema is invalid")
    for key in ("phase3_tree_oid", "reference_tree_oid"):
        if key in expected and (not isinstance(inputs.get(key), str) or not SHA40.fullmatch(inputs[key])):
            raise Refusal(f"job {key} is invalid")
    for key in expected - {"phase3_tree_oid", "reference_tree_oid", "artifact_sha256"}:
        require_sha(inputs.get(key), f"job {key}")
    artifacts = inputs.get("artifact_sha256")
    if not isinstance(artifacts, dict) or set(artifacts) != artifact_fields(kind):
        raise Refusal("job artifact hash schema is invalid")
    for key, value in artifacts.items():
        require_sha(value, f"job artifact {key}")


def staged_private_paths(root: Path, kind: str) -> dict[str, Path]:
    paths: dict[str, Path] = {}
    components = STAGED_JOB_KINDS[kind]
    if "glm-parity-prefill512" in components:
        paths.update({
            "diagnostic_cli": root / "provider/macprovider-cli",
            "diagnostic_metallib": root / "provider/mlx.metallib",
            "glm_parity_policy": root / "glm-parity/policy.json",
            "glm_parity_oracle": root / "glm-parity/oracle_8192.json",
        })
    if "dsv4-reference" in components:
        # The venv interpreter stays in place (a copied interpreter loses its
        # venv); it is hash-bound by the source snapshot instead.
        paths.update({
            "reference_script": root / "reference/dsv4_reference_bench.py",
            "reference_policy": root / "reference/policy.json",
        })
    return paths


def staged_private_sources(manifest: dict, job: dict) -> dict[str, tuple[Path, str]]:
    source = Path(manifest["lab_source_dir"])
    inputs = job["immutable_inputs"]
    artifacts = inputs["artifact_sha256"]
    known = {
        "diagnostic_cli": (Path(manifest["artifacts"].get("diagnostic_cli", {}).get("path", "/")), artifacts.get("diagnostic_cli")),
        "diagnostic_metallib": (Path(manifest["artifacts"].get("diagnostic_metallib", {}).get("path", "/")), artifacts.get("diagnostic_metallib")),
        "glm_parity_policy": (source / GLM_PARITY_POLICY_RELATIVE, inputs.get("glm_parity_policy_sha256")),
        "glm_parity_oracle": (source / GLM_PARITY_ORACLE_RELATIVE, inputs.get("glm_parity_oracle_sha256")),
        "reference_script": (Path(manifest["artifacts"].get("reference_script", {}).get("path", "/")), artifacts.get("reference_script")),
        "reference_policy": (source / DSV4_POLICY_RELATIVE, inputs.get("reference_policy_sha256")),
    }
    return {key: known[key] for key in staged_private_paths(Path("/"), job["kind"])}


def staged_prepare_private(manifest: dict, job: dict, root: Path, paths: dict[str, Path]) -> None:
    directories = sorted({path.parent for path in paths.values()})
    for directory in directories:
        create_result_dir(directory)
    for key, (origin, expected) in staged_private_sources(manifest, job).items():
        copy_authenticated(origin, paths[key], str(expected), executable=key == "diagnostic_cli")
    for directory in [*directories, root]:
        fd = os.open(directory, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(fd)
        finally:
            os.close(fd)


def staged_validate_private(manifest: dict, job: dict, root: Path) -> dict[str, str]:
    paths = staged_private_paths(root, job["kind"])
    for directory in [preflight_path(manifest), root, *sorted({path.parent for path in paths.values()})]:
        safe_directory(directory)
    result: dict[str, str] = {}
    for key, (_, expected) in staged_private_sources(manifest, job).items():
        actual = file_sha256(safe_artifact(paths[key], executable=key == "diagnostic_cli"))
        if actual != expected:
            raise Refusal(f"private job artifact drifted: {key}")
        result[key] = actual
    return result


def embedded_decode_path_digest(path: Path) -> str:
    # Streamed scan with an overlap longer than the marker, so memory stays bounded.
    found: set[bytes] = set()
    tail = b""
    fd = os.open(safe_artifact(path), os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        for block in iter(lambda: os.read(fd, 4 * 1024 * 1024), b""):
            window = tail + block
            found.update(DECODE_PATH_MARKER.findall(window))
            tail = window[-128:]
    finally:
        os.close(fd)
    if len(found) != 1:
        raise Refusal(f"binary does not embed exactly one decode-path digest: {path}")
    return found.pop().decode()


def check_glm_parity_decode_path(manifest: dict, job: dict) -> None:
    # The lab CLI carries glm-parity; the signed release does not. Both must
    # embed the policy's decode-path digest, so the measured prefill and
    # parity are those of the live release's decode path.
    # The lab CLI is the fixed release-mode build of this tracked-clean clone
    # (the same build provenance as every lab-CLI job); its source decode-path
    # digest is recomputed here rather than trusted from the binary marker.
    expected = job["immutable_inputs"]["glm_parity_decode_path_digest"]
    if source_decode_path_digest(Path(manifest["lab_source_dir"])) != expected:
        raise Refusal("lab source decode path differs from the GLM parity policy")
    lab = staged_private_paths(preflight_path(manifest) / "artifacts", job["kind"])["diagnostic_cli"]
    live = Path(manifest["install_dir"]) / "macprovider-cli"
    for name, path in (("lab CLI", lab), ("signed provider", live)):
        if embedded_decode_path_digest(path) != expected:
            raise Refusal(f"{name} decode path differs from the GLM parity policy")


def check_reference_environment(manifest: dict, output: Path) -> None:
    expected = DSV4_REFERENCE_POLICY["environment"]
    python = str(manifest["artifacts"]["reference_python"]["path"])
    run_checked([python, "-I", "-c", DSV4_ENVIRONMENT_PROBE, *sorted(expected)], output, timeout=120)
    try:
        observed = json.loads(read_bounded(output, STAGED_POLICY_MAX_BYTES, "environment probe").splitlines()[-1])
    except (IndexError, ValueError) as exc:
        raise Refusal(f"reference environment probe is invalid; private log: {output}") from exc
    if observed != expected:
        raise Refusal(f"reference environment differs from the fixed versions; private log: {output}")


def authenticate_interpreter(manifest: dict, job: dict) -> str:
    """Re-authenticate the venv interpreter immediately before it is launched.

    Every link in its lexical chain must be the operator's (or root's) and not
    writable by group or other, and the resolved target must still have the
    bound hash. Returns the lexical path to execute (venv semantics need it).
    """
    lexical = Path(manifest["artifacts"]["reference_python"]["path"])
    current = Path(os.path.abspath(lexical))
    for _ in range(64):
        link = None
        for part in [*reversed(current.parents), current]:
            info = part.lstat()
            if info.st_uid not in (os.getuid(), 0):
                raise Refusal(f"reference interpreter path has a foreign owner: {part}")
            if stat.S_ISLNK(info.st_mode):
                link = part
                break
            if stat.S_IMODE(info.st_mode) & 0o022 and not (stat.S_ISDIR(info.st_mode) and info.st_mode & stat.S_ISVTX):
                raise Refusal(f"reference interpreter path is writable by group or other: {part}")
        if link is None:
            break
        # Replace the first symlink component with its target and re-walk.
        current = Path(os.path.normpath(link.parent / os.readlink(link) / current.relative_to(link)))
    else:
        raise Refusal("reference interpreter symlink chain is too long")
    if file_sha256(safe_artifact(lexical, executable=True)) != job["immutable_inputs"]["artifact_sha256"]["reference_python"]:
        raise Refusal("reference interpreter drifted")
    return str(lexical)


def component_target(component: str, job: dict) -> str:
    inputs = job["immutable_inputs"]
    return inputs["glm_parity_target_sha256" if component == "glm-parity-prefill512" else "reference_target_sha256"]


def staged_preflight(manifest: dict, job: dict, preflight: Path) -> dict:
    source = Path(manifest["lab_source_dir"])
    components: dict[str, dict] = {}
    for component in STAGED_JOB_KINDS[job["kind"]]:
        root = source / STAGED_COMPONENT_ROOTS[component]
        safe_fixture_tree(root)
        digest, stamps = snapshot_identity(root)
        if digest != component_target(component, job):
            raise Refusal(f"{component} fixture identity differs from its policy")
        if component == "glm-parity-prefill512":
            check_glm_parity_decode_path(manifest, job)
        else:
            check_reference_environment(manifest, preflight / "environment.json")
        components[component] = {
            "canonical_root": str(root.resolve(strict=True)), "target_sha256": digest, "stamps": stamps,
        }
    return {
        "schema_version": STAGED_PREFLIGHT_SCHEMA,
        "nonce": manifest["nonce"],
        "job_identity_sha256": job["identity_sha256"],
        "algorithm": "macprovider.snapshot-manifest.v1",
        "components": components,
    }


def staged_validate_receipt(manifest: dict, job: dict, receipt: dict) -> None:
    source = Path(manifest["lab_source_dir"])
    components = receipt.get("components")
    expected = STAGED_JOB_KINDS[job["kind"]]
    if (
        receipt.get("schema_version") != STAGED_PREFLIGHT_SCHEMA
        or receipt.get("nonce") != manifest["nonce"]
        or receipt.get("job_identity_sha256") != job["identity_sha256"]
        or receipt.get("algorithm") != "macprovider.snapshot-manifest.v1"
        or not isinstance(components, dict)
        or set(components) != set(expected)
    ):
        raise Refusal("job preflight identity is invalid")
    for component in expected:
        item = components[component]
        root = source / STAGED_COMPONENT_ROOTS[component]
        if (
            not isinstance(item, dict)
            or item.get("canonical_root") != str(root.resolve(strict=True))
            or item.get("target_sha256") != component_target(component, job)
            or not valid_stamp_list(item.get("stamps"))
        ):
            raise Refusal("job preflight identity is invalid")
        if snapshot_stamps(root, len(item["stamps"]) + 1) != item["stamps"]:
            raise Refusal(f"{component} fixture changed after job preflight")
        safe_fixture_tree(root)


def glm_parity_summary(path: Path) -> dict:
    try:
        report = json.loads(read_bounded(path, STAGED_REPORT_MAX_BYTES, "GLM parity result"))
        runs = report["runs"]
        measured = runs[0]["measurement"]
        free = measured["free_running"]
        # Swift's synthesized Codable omits a nil optional: an absent
        # first_divergence means the free run matched every compared token.
        divergence = free.get("first_divergence")
        summary = {
            "prompt_tokens": measured["prompt_tokens"],
            "prefill_step_size": report["prefill_step_size"],
            "prefill_tokens_per_second": float(measured["prefill_tokens_per_second"]),
            "ttft_seconds": float(measured["ttft_seconds"]),
            "decode_tokens_per_second": float(measured["decode_tokens_per_second"]),
            "compared_tokens": int(free["compared_tokens"]),
            "matching_tokens": int(free["matching_tokens"]),
            "first_divergence": None if divergence is None else int(divergence),
            "top1_agreement": [int(free["top1_agreement"]), int(free["top1_compared"])],
        }
    except (AttributeError, KeyError, IndexError, TypeError, ValueError) as exc:
        raise Refusal(f"GLM parity result is invalid; private log: {path}") from exc
    if (
        report.get("schema") != "glm-parity-v1"
        or summary["prefill_step_size"] != GLM_PARITY_PROFILE["prefill_step_size"]
        or len(runs) != 1
        or summary["prompt_tokens"] != GLM_PARITY_POLICY["prompt_tokens"]
    ):
        raise Refusal(f"GLM parity result is not the fixed run; private log: {path}")
    summary["token_parity"] = (
        summary["first_divergence"] is None and summary["matching_tokens"] == summary["compared_tokens"]
    )
    return summary


def run_component(manifest: dict, job: dict, component: str, result: Path) -> tuple[list[Path], dict]:
    source = Path(manifest["lab_source_dir"])
    private = private_artifact_paths(manifest, job)
    validate_execution_inputs(manifest, job)
    if component == "glm-parity-prefill512":
        check_glm_parity_decode_path(manifest, job)
        report = result / "glm-parity.json"
        log = result / "glm-parity.log"
        profile = GLM_PARITY_PROFILE
        run_checked([
            str(private["diagnostic_cli"]), "glm-parity",
            "--model-dir", str(source / STAGED_COMPONENT_ROOTS[component]),
            "--oracle", str(private["glm_parity_oracle"]),
            "--steps", str(profile["steps"]),
            "--prefill-step-size", str(profile["prefill_step_size"]),
            "--mlx-cache-limit-mb", str(profile["mlx_cache_limit_mb"]),
            "--output", str(report),
        ], log, timeout=STAGED_COMMAND_TIMEOUTS[component])
        return [log, report], glm_parity_summary(report)
    environment = result / "environment.json"
    check_reference_environment(manifest, environment)
    validate_execution_inputs(manifest, job)
    interpreter = authenticate_interpreter(manifest, job)
    profile = DSV4_REFERENCE_PROFILE
    reference = result / "reference"
    log = result / "reference.log"
    joined = lambda values: ",".join(str(value) for value in values)
    run_checked([
        interpreter, "-I",
        str(private["reference_script"]),
        str(source / STAGED_COMPONENT_ROOTS[component]), str(reference),
        "--oracle-contexts", joined(profile["oracle_contexts"]),
        "--ttft-contexts", joined(profile["ttft_contexts"]),
        "--rows", joined(profile["rows"]),
        "--row-prompt", str(profile["row_prompt"]),
        "--decode", str(profile["decode"]),
    ], log, timeout=STAGED_COMMAND_TIMEOUTS[component])
    outputs = [environment, log, reference / "speed.json"]
    outputs.extend(reference / f"oracle_{ctx}.npz" for ctx in profile["oracle_contexts"])
    return outputs, {}


def staged_run(manifest: dict, job: dict, result: Path) -> dict[str, object]:
    # Run every component even if an earlier one fails, so one pause window
    # yields all the evidence it can; any failure still fails the job.
    outputs: list[Path] = []
    measurements: dict[str, dict] = {}
    status: dict[str, str] = {}
    for component in STAGED_JOB_KINDS[job["kind"]]:
        try:
            produced, summary = run_component(manifest, job, component, result)
        except (Refusal, OSError, ValueError, subprocess.SubprocessError) as exc:
            status[component] = f"failed: {type(exc).__name__}: {exc}"
            continue
        outputs.extend(produced)
        if summary:
            measurements[component] = summary
        status[component] = "completed"
    private_hashes = validate_execution_inputs(manifest, job)
    failed = [name for name, value in status.items() if value != "completed"]
    receipt = {
        "schema_version": JOB_RESULT_SCHEMA,
        "kind": job["kind"],
        "identity_sha256": job["identity_sha256"],
        "completed_unix": int(time.time()),
        "qualification_activated": False,
        "exploratory": True,
        "qualification": False,
        "evidence_class": "staged_measurement_only",
        "components": status,
        "measurements": measurements,
        "executed_inputs": {
            "private_artifact_sha256": private_hashes,
            "fixture_target_sha256": {
                component: component_target(component, job) for component in STAGED_JOB_KINDS[job["kind"]]
            },
        },
        "outputs": {str(item.relative_to(result)): file_sha256(safe_artifact(item)) for item in outputs},
    }
    if failed:
        write_result(result / "partial-result.json", receipt)
        raise Refusal("staged job components failed: " + ", ".join(failed))
    write_result(result / "result.json", receipt)
    return {**receipt, "result_path": str(result / "result.json")}


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser()
    sub = root.add_subparsers(dest="command", required=True)
    snapshot = sub.add_parser("source-snapshot")
    snapshot.add_argument("--source-dir", required=True)
    snapshot.add_argument("--git-head", required=True)
    snapshot.add_argument("--provider-label", required=True)
    snapshot.add_argument("--job-kind", choices=JOB_KINDS, default="diagnostic-legacy")
    snapshot.add_argument("--lab-script-sha256")
    snapshot.add_argument("--job-helper-sha256")
    build = sub.add_parser("build")
    for name in (
        "nonce", "git-head", "probe-json", "source-snapshot-json", "probe-sha256",
        "lab-script-sha256",
        "install-dir", "config-path", "ctl-socket", "provider-label", "status-port",
        "probe-path", "owner-pin-journal", "lab-source-dir", "lab-script-path",
        "log-path", "drain-timeout-s", "lab-timeout-s", "ready-timeout-s", "poll-s",
    ):
        build.add_argument(f"--{name}", required=True)
    validate = sub.add_parser("validate-job")
    validate.add_argument("--manifest", required=True)
    run = sub.add_parser("run-job")
    run.add_argument("--manifest", required=True)
    return root


def main() -> int:
    args = parser().parse_args()
    try:
        if args.command in {"validate-job", "run-job"}:
            os.nice(19)
        if args.command == "source-snapshot":
            result = source_snapshot(args)
        elif args.command == "build":
            result = build_manifest(args)
        elif args.command == "validate-job":
            result = validate_job(args)
        else:
            result = run_job(args)
        print(json.dumps(result, sort_keys=True, separators=(",", ":")))
        return 0
    except (OSError, Refusal, subprocess.SubprocessError, ValueError) as exc:
        print(f"studio-lab-window-manifest: REFUSED: {exc}", file=sys.stderr)
        return 3


if __name__ == "__main__":
    raise SystemExit(main())
