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
}
QWEN_ARTIFACT_FIELDS = {
    "diagnostic_cli", "diagnostic_metallib", "fixture_config", "fixture_index",
}
JOB_KINDS = ("diagnostic-legacy", "profiler-only", "qualification", "qwen-qualification")
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
    if kind != "qwen-qualification":
        inputs["glmbench_tree_oid"] = git_value(
            source, "HEAD:scripts/lab/cb-studio/glm53-bench", "GLMBench tree"
        )
    if kind == "profiler-only":
        inputs["reuse"] = archived_reuse(source, artifacts, phase3_tree)
    elif kind == "qualification":
        policy, policy_sha = read_safe_object(source / POLICY_RELATIVE, "qualification policy")
        validate_policy(policy)
        projected = projection_tuple(source)
        if any(policy.get(key) != projected[key] for key in ("target_sha256", "mtp_sha256", "tokenizer_sha256")):
            raise Refusal("qualification policy fixture identity differs from projection")
        if git_value(source, f"{policy['provider_commit']}:phase3-binary", "policy phase3 tree") != phase3_tree:
            raise Refusal("qualification policy provider commit has different phase3 source")
        inputs["qualification_policy_sha256"] = policy_sha
        inputs["qualification_provider_commit"] = policy["provider_commit"]
        inputs["qualification_cells"] = list(QUALIFICATION_CELLS)
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
        inputs["qualification_cells"] = list(QWEN_QUALIFICATION_CELLS)
        inputs["artifact_projection_sha256"] = projection_sha
        inputs["artifact_projection"] = projected
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
    artifact_fields = QWEN_ARTIFACT_FIELDS if kind == "qwen-qualification" else ARTIFACT_FIELDS
    artifacts = {name: source / ARTIFACT_RELATIVES[name] for name in artifact_fields}
    result: dict[str, dict[str, str]] = {}
    for name, path in artifacts.items():
        target = safe_artifact(path, executable=name in {"diagnostic_cli", "glmbench"})
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
    artifact_fields = (
        QWEN_ARTIFACT_FIELDS
        if isinstance(job, dict) and job.get("kind") == "qwen-qualification"
        else ARTIFACT_FIELDS
    )
    artifacts = source.get("artifacts")
    if not isinstance(artifacts, dict) or set(artifacts) != artifact_fields:
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
        43200 if job is not None and job["kind"] in QUALIFICATION_KINDS else 3600,
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
    expected_inputs = {
        "phase3_tree_oid", "lab_script_sha256", "job_helper_sha256", "artifact_sha256",
    }
    if job["kind"] != "qwen-qualification":
        expected_inputs.add("glmbench_tree_oid")
    if job["kind"] == "profiler-only":
        expected_inputs.add("reuse")
    elif job["kind"] == "qualification":
        expected_inputs |= {
            "qualification_policy_sha256", "qualification_provider_commit",
            "qualification_cells",
        }
    else:
        expected_inputs |= {
            "qualification_policy_sha256", "qualification_provider_commit",
            "qualification_cells", "artifact_projection_sha256", "artifact_projection",
        }
    if set(inputs) != expected_inputs:
        raise Refusal("job immutable input schema is invalid")
    for key in ("phase3_tree_oid",):
        if not isinstance(inputs.get(key), str) or not SHA40.fullmatch(inputs[key]):
            raise Refusal(f"job {key} is invalid")
    if job["kind"] != "qwen-qualification" and (
        not isinstance(inputs.get("glmbench_tree_oid"), str)
        or not SHA40.fullmatch(inputs["glmbench_tree_oid"])
    ):
        raise Refusal("job glmbench_tree_oid is invalid")
    for key in ("lab_script_sha256", "job_helper_sha256"):
        require_sha(inputs.get(key), f"job {key}")
    artifacts = inputs.get("artifact_sha256")
    artifact_fields = QWEN_ARTIFACT_FIELDS if job["kind"] == "qwen-qualification" else ARTIFACT_FIELDS
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
    if job["kind"] == "qualification":
        require_sha(inputs.get("qualification_policy_sha256"), "qualification policy sha256")
        if (
            not isinstance(inputs.get("qualification_provider_commit"), str)
            or not SHA40.fullmatch(inputs["qualification_provider_commit"])
            or inputs.get("qualification_cells") != list(QUALIFICATION_CELLS)
        ):
            raise Refusal("qualification immutable input schema is invalid")
    if job["kind"] == "qwen-qualification":
        require_sha(inputs.get("qualification_policy_sha256"), "Qwen qualification policy sha256")
        require_sha(inputs.get("artifact_projection_sha256"), "Qwen artifact projection sha256")
        projection = inputs.get("artifact_projection")
        if (
            not isinstance(inputs.get("qualification_provider_commit"), str)
            or not SHA40.fullmatch(inputs["qualification_provider_commit"])
            or inputs.get("qualification_cells") != list(QWEN_QUALIFICATION_CELLS)
            or not isinstance(projection, dict)
            or set(projection) != {
                "target_sha256", "mtp_sha256", "tokenizer_sha256", "mtp_manifest_sha256"
            }
        ):
            raise Refusal("Qwen qualification immutable input schema is invalid")
        for key, value in projection.items():
            require_sha(value, f"Qwen artifact projection {key}")
        if projection["target_sha256"] == projection["mtp_sha256"]:
            raise Refusal("Qwen qualification embeds MTP in the target")
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
    if job["kind"] != "qwen-qualification" and (
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
    artifact_fields = QWEN_ARTIFACT_FIELDS if job["kind"] == "qwen-qualification" else ARTIFACT_FIELDS
    for key in artifact_fields:
        item = artifacts.get(key)
        if not isinstance(item, dict) or artifact_hashes.get(key) != item.get("sha256"):
            raise Refusal(f"job artifact manifest mismatch: {key}")
        # Keep the lexical fixed path while allowing the normal SwiftPM and
        # fixture symlinks. safe_artifact authenticates the resolved target.
        path = Path(str(item.get("path", "")))
        expected = source / ARTIFACT_RELATIVES[key]
        if not path.is_absolute() or path != expected:
            raise Refusal(f"job artifact path is not fixed: {key}")
        actual = file_sha256(safe_artifact(path, executable=key in {"diagnostic_cli", "glmbench"}))
        if actual != artifact_hashes[key]:
            raise Refusal(f"job artifact drifted: {key}")
    if job["kind"] == "profiler-only":
        current_reuse = archived_reuse(source, artifacts, str(inputs["phase3_tree_oid"]))
        if inputs.get("reuse") != current_reuse:
            raise Refusal("archived journey reuse inputs drifted")
    elif job["kind"] == "qualification":
        policy, policy_sha = read_safe_object(source / POLICY_RELATIVE, "qualification policy")
        validate_policy(policy)
        projected = projection_tuple(source)
        if (
            inputs.get("qualification_policy_sha256") != policy_sha
            or inputs.get("qualification_provider_commit") != policy.get("provider_commit")
            or inputs.get("qualification_cells") != list(QUALIFICATION_CELLS)
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
            or inputs.get("qualification_cells") != list(QWEN_QUALIFICATION_CELLS)
            or inputs.get("artifact_projection_sha256") != projection_sha
            or inputs.get("artifact_projection") != projected
            or any(
                policy.get(key) != projected[key]
                for key in ("target_sha256", "mtp_sha256", "tokenizer_sha256")
            )
        ):
            raise Refusal("Qwen qualification policy or projection identity drifted")
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
    paths = {
        "diagnostic_cli": root / "provider/macprovider-cli",
        "diagnostic_metallib": root / "provider/mlx.metallib",
    }
    if job["kind"] != "qwen-qualification":
        paths.update({
            "glmbench": root / "bench/GLMBench",
            "glmbench_metallib": root / "bench/mlx.metallib",
        })
    if job["kind"] in QUALIFICATION_KINDS:
        paths["qualification_policy"] = root / "qualification-policy.json"
    if job["kind"] == "qwen-qualification":
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
    create_result_dir(root / "provider")
    if job["kind"] != "qwen-qualification":
        create_result_dir(root / "bench")
    source_artifacts = manifest["artifacts"]
    expected = job["immutable_inputs"]["artifact_sha256"]
    artifact_keys = (
        ("diagnostic_cli", "diagnostic_metallib")
        if job["kind"] == "qwen-qualification"
        else ("diagnostic_cli", "diagnostic_metallib", "glmbench", "glmbench_metallib")
    )
    for key in artifact_keys:
        copy_authenticated(
            Path(source_artifacts[key]["path"]), paths[key], expected[key],
            executable=key in {"diagnostic_cli", "glmbench"},
        )
    if job["kind"] in QUALIFICATION_KINDS:
        copy_authenticated(
            Path(manifest["lab_source_dir"]) / POLICY_RELATIVE,
            paths["qualification_policy"],
            job["immutable_inputs"]["qualification_policy_sha256"],
            executable=False,
        )
    if job["kind"] == "qwen-qualification":
        copy_authenticated(
            Path(manifest["lab_source_dir"]) / QWEN_PROJECTION_RELATIVE,
            paths["artifact_projection"],
            job["immutable_inputs"]["artifact_projection_sha256"],
            executable=False,
        )
    directories = [root / "provider"]
    if job["kind"] != "qwen-qualification":
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
    directories = [preflight_path(manifest), root, root / "provider"]
    if job["kind"] != "qwen-qualification":
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
    target = Path(manifest["lab_source_dir"]) / ".lab-window/fixture/target"
    mtp = Path(manifest["lab_source_dir"]) / ".lab-window/fixture/mtp"
    expected = receipt.get("expected")
    qwen = job["kind"] == "qwen-qualification"
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
    target = source / ".lab-window/fixture/target"
    qwen = job["kind"] == "qwen-qualification"
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
        cells = QWEN_QUALIFICATION_CELLS if qwen else QUALIFICATION_CELLS
        sustained_cell = "s8-p1536-o512" if qwen else "s4-p1536-o512"
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
    else:
        evidence = result / "qualification.jsonl"
        base = qualification_base(manifest, evidence)
        cells = (
            QWEN_QUALIFICATION_CELLS
            if job["kind"] == "qwen-qualification" else QUALIFICATION_CELLS
        )
        for index, cell in enumerate(cells, 1):
            log = result / f"matrix-{index:02d}-{cell}.log"
            validate_execution_inputs(manifest, job)
            run_checked(base + ["--only-cell", cell, "--phase", "matrix"], log)
            outputs.append(log)
        sustained = result / "sustained.log"
        validate_execution_inputs(manifest, job)
        run_checked(base + ["--phase", "sustained"], sustained)
        outputs.extend((sustained, evidence))
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
                if job["kind"] == "qwen-qualification"
                else projection_tuple(source)["target_sha256"]
            ),
        },
        "outputs": {item.name: file_sha256(safe_artifact(item)) for item in outputs},
    }
    if job["kind"] == "qwen-qualification":
        receipt["executed_inputs"]["fixture_mtp_sha256"] = (
            job["immutable_inputs"]["artifact_projection"]["mtp_sha256"]
        )
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
