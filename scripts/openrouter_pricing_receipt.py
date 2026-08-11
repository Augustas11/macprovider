#!/usr/bin/env python3
"""Run and validate evidence-bound OpenRouter pricing research operations.

This operator tool has no apply mode. ``run`` executes fetch and compute from a
clean committed worktree, creates credential-redacted receipts, validates an
exact proposal replay, and copies byte-identical evidence into the archive.
``validate`` independently checks archived schema-v2 receipts and artifacts.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Mapping

import openrouter_pricing_engine as engine


RECEIPT_SCHEMA_VERSION = 2
SECRET_RE = re.compile(r"(?i)sk-or-[A-Za-z0-9_-]+")
AUTH_RE = re.compile(r"(?i)Authorization:\s*Bearer\s+\S+")
BEARER_RE = re.compile(r"(?i)Bearer\s+sk-or-\S+")
COMMON_KEYS = {
    "schema_version", "receipt_type", "started_at", "finished_at",
    "engine_commit", "execution", "command", "exit_status", "stdout",
    "stderr", "output_directory_listing", "evidence_digest",
}
FETCH_SUCCESS = "openrouter-pricing-fetch-success"
FETCH_FAILURE = "openrouter-pricing-fetch-failure"
COMPUTE_SUCCESS = "openrouter-pricing-compute-success"
COMPUTE_FAILURE = "openrouter-pricing-compute-failure"
RECEIPT_TYPES = {FETCH_SUCCESS, FETCH_FAILURE, COMPUTE_SUCCESS, COMPUTE_FAILURE}
ENGINE_PATH = "scripts/openrouter_pricing_engine.py"
RUNNER_PATH = "scripts/openrouter_pricing_receipt.py"


class ReceiptError(RuntimeError):
    """Receipt generation or validation failed closed."""


def canonical_json(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def sha256_bytes(value: bytes) -> str:
    return "sha256:" + hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return "sha256:" + digest.hexdigest()


def read_object(path: Path, description: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ReceiptError(f"cannot read {description} {path}: {error}") from error
    if not isinstance(value, dict):
        raise ReceiptError(f"{description} must be a JSON object")
    return value


def utc_now() -> datetime:
    return datetime.now(timezone.utc).replace(microsecond=0)


def rfc3339(value: datetime) -> str:
    return value.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def receipt_stamp(value: datetime) -> str:
    return value.astimezone(timezone.utc).strftime("%Y-%m-%dT%H-%M-%SZ")


def redact(text: str, api_key: str, temporary_directory: Path) -> str:
    result = text.replace(api_key, "<redacted>") if api_key else text
    result = result.replace(str(temporary_directory), "<temporary-artifact-directory>")
    result = AUTH_RE.sub("Authorization: Bearer <redacted>", result)
    result = BEARER_RE.sub("Bearer <redacted>", result)
    if SECRET_RE.search(result):
        raise ReceiptError("receipt redaction failed: OpenRouter credential remains")
    return result.strip()


def git(repo: Path, *arguments: str) -> str:
    completed = subprocess.run(
        ["git", *arguments], cwd=repo, text=True, encoding="utf-8",
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
    )
    if completed.returncode != 0:
        raise ReceiptError(f"git {' '.join(arguments)} failed: {completed.stderr.strip()}")
    return completed.stdout.strip()


def clean_commit(repo: Path) -> str:
    status = git(repo, "status", "--porcelain", "--untracked-files=all")
    if status:
        raise ReceiptError("execution worktree must be clean, including untracked files")
    commit = git(repo, "rev-parse", "HEAD")
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ReceiptError("git HEAD is not a full lowercase commit SHA")
    return commit


def inventory(path: Path) -> dict[str, Any]:
    return {"filename": path.name, "bytes": path.stat().st_size, "sha256": sha256_file(path)}


def evidence_digest(receipt: Mapping[str, Any]) -> str:
    payload = dict(receipt)
    payload.pop("evidence_digest", None)
    return sha256_bytes(canonical_json(payload))


def write_receipt(path: Path, receipt: dict[str, Any]) -> None:
    receipt["evidence_digest"] = evidence_digest(receipt)
    path.write_bytes(json.dumps(receipt, indent=2, ensure_ascii=False).encode("utf-8") + b"\n")


def parse_time(value: Any, field: str) -> datetime:
    if not isinstance(value, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", value):
        raise ReceiptError(f"{field} must be a whole-second UTC RFC 3339 timestamp")
    return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)


def reject_secrets(value: Any) -> None:
    if isinstance(value, str) and SECRET_RE.search(value):
        raise ReceiptError("receipt contains an OpenRouter credential")
    if isinstance(value, list):
        for item in value:
            reject_secrets(item)
    if isinstance(value, dict):
        for item in value.values():
            reject_secrets(item)


def resolve_repo_path(repo: Path, value: Any, field: str) -> Path:
    if not isinstance(value, str) or not value or Path(value).is_absolute():
        raise ReceiptError(f"{field} must be a non-empty repository-relative path")
    path = (repo / value).resolve()
    try:
        path.relative_to(repo.resolve())
    except ValueError as error:
        raise ReceiptError(f"{field} escapes the repository") from error
    return path


def git_bytes(repo: Path, *arguments: str) -> bytes:
    completed = subprocess.run(
        ["git", *arguments], cwd=repo, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, check=False,
    )
    if completed.returncode != 0:
        detail = completed.stderr.decode("utf-8", errors="replace").strip()
        raise ReceiptError(f"git {' '.join(arguments)} failed: {detail}")
    return completed.stdout


def validate_execution_binding(receipt: Mapping[str, Any], repo: Path, expected_command: list[str]) -> None:
    commit = receipt["engine_commit"]
    git_bytes(repo, "cat-file", "-e", f"{commit}^{{commit}}")
    ancestor = subprocess.run(
        ["git", "merge-base", "--is-ancestor", commit, "HEAD"], cwd=repo,
        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, check=False,
    )
    if ancestor.returncode != 0:
        raise ReceiptError("engine_commit must be an ancestor of the validator worktree HEAD")
    committed_engine = git_bytes(repo, "show", f"{commit}:{ENGINE_PATH}")
    committed_runner = git_bytes(repo, "show", f"{commit}:{RUNNER_PATH}")
    if not committed_runner:
        raise ReceiptError("engine_commit does not contain the receipt runner")
    if committed_engine != (repo / ENGINE_PATH).read_bytes():
        raise ReceiptError("current engine bytes differ from the engine bound by engine_commit")
    if receipt["command"] != expected_command:
        raise ReceiptError("receipt command does not match its type and bound inputs")


def expected_fetch_command(policy_path: str) -> list[str]:
    return [
        "python", ENGINE_PATH, "fetch", "--policy", policy_path,
        "--output-dir", "<temporary-artifact-directory>", "--top-n", "50",
        "--demand-window-days", "30", "--retries", "3",
        "--timeout-seconds", "20.0", "--generation-timeout-seconds", "900.0",
    ]


def expected_compute_command(inputs: Mapping[str, Any]) -> list[str]:
    return [
        "python", ENGINE_PATH, "compute", "--snapshot", inputs["snapshot_path"],
        "--policy", inputs["policy_path"], "--rate-card", inputs["rate_card_path"],
        "--output-dir", "<temporary-artifact-directory>",
    ]


def validate_inventory(
    receipt: Mapping[str, Any], archive: Path, success: bool, receipt_type: str | None = None,
) -> Path | None:
    listing = receipt.get("output_directory_listing")
    if not success:
        if listing != []:
            raise ReceiptError("failure receipt must have an empty artifact inventory")
        return None
    if not isinstance(listing, list) or len(listing) != 1 or not isinstance(listing[0], dict):
        raise ReceiptError("success receipt must inventory exactly one artifact")
    item = listing[0]
    if set(item) != {"filename", "bytes", "sha256"} or not isinstance(item["filename"], str):
        raise ReceiptError("receipt artifact inventory is malformed")
    filename = item["filename"]
    if not filename or Path(filename).name != filename:
        raise ReceiptError("receipt artifact filename must be a basename")
    if receipt_type == FETCH_SUCCESS:
        pattern = r"openrouter-pricing-snapshot-\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}Z-[0-9a-f]{16}\.json"
    elif receipt_type == COMPUTE_SUCCESS:
        pattern = r"openrouter-rate-card-proposal-\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}Z-[0-9a-f]{16}\.json"
    else:
        pattern = None
    if pattern is not None and not re.fullmatch(pattern, filename):
        raise ReceiptError("receipt artifact filename does not match its receipt type")
    artifact_path = archive / filename
    if artifact_path.is_symlink():
        raise ReceiptError("receipt artifact must be a regular file, not a symlink")
    artifact = artifact_path.resolve()
    if artifact.parent != archive.resolve():
        raise ReceiptError("receipt artifact escapes its receipt directory")
    if not artifact.is_file():
        raise ReceiptError(f"archived artifact is missing: {artifact.name}")
    if item["bytes"] != artifact.stat().st_size or item["sha256"] != sha256_file(artifact):
        raise ReceiptError(f"archived artifact bytes or SHA-256 do not match receipt: {artifact.name}")
    return artifact


def validate_receipt(receipt_path: Path, repo: Path) -> None:
    receipt = read_object(receipt_path, "receipt")
    if receipt.get("schema_version") != RECEIPT_SCHEMA_VERSION:
        raise ReceiptError("executable validator accepts schema-version 2 receipts")
    receipt_type = receipt.get("receipt_type")
    if receipt_type not in RECEIPT_TYPES:
        raise ReceiptError("receipt type is unsupported")
    type_field = "source" if receipt_type in {FETCH_SUCCESS, FETCH_FAILURE} else "inputs"
    if set(receipt) != COMMON_KEYS | {type_field}:
        raise ReceiptError("receipt has missing or unexpected top-level fields")
    success = receipt_type in {FETCH_SUCCESS, COMPUTE_SUCCESS}
    started = parse_time(receipt.get("started_at"), "started_at")
    finished = parse_time(receipt.get("finished_at"), "finished_at")
    if started > finished:
        raise ReceiptError("receipt started_at is after finished_at")
    if not re.fullmatch(r"[0-9a-f]{40}", str(receipt.get("engine_commit", ""))):
        raise ReceiptError("engine_commit must be a full lowercase commit SHA")
    execution = receipt.get("execution")
    if execution != {"worktree_clean": True}:
        raise ReceiptError("receipt must attest a clean execution worktree")
    command = receipt.get("command")
    if not isinstance(command, list) or not command or not all(isinstance(item, str) for item in command):
        raise ReceiptError("command must be a non-empty string array")
    exit_status = receipt.get("exit_status")
    if isinstance(exit_status, bool) or not isinstance(exit_status, int):
        raise ReceiptError("receipt exit_status must be an integer")
    if success != (exit_status == 0):
        raise ReceiptError("receipt type and exit_status disagree")
    if not isinstance(receipt.get("stdout"), str) or not isinstance(receipt.get("stderr"), str):
        raise ReceiptError("receipt must contain captured stdout and stderr")
    reject_secrets(receipt)
    if receipt.get("evidence_digest") != evidence_digest(receipt):
        raise ReceiptError("receipt evidence_digest mismatch")
    artifact = validate_inventory(receipt, receipt_path.parent, success, receipt_type)

    policy_path: Path
    if receipt_type in {FETCH_SUCCESS, FETCH_FAILURE}:
        source = receipt["source"]
        expected = {"rankings_url", "openrouter_api_key_configured", "policy_path", "policy_file_sha256"}
        if success:
            expected |= {
                "ranking_window_start_date", "ranking_window_end_date",
                "confirmed_empty_model_ids", "confirmation_request_count",
                "successful_source_count",
            }
        if not isinstance(source, dict) or set(source) != expected or source["openrouter_api_key_configured"] is not True:
            raise ReceiptError("fetch receipt source binding is malformed")
        policy_path = resolve_repo_path(repo, source["policy_path"], "source.policy_path")
        if sha256_file(policy_path) != source["policy_file_sha256"]:
            raise ReceiptError("fetch receipt policy bytes do not match")
        if source["rankings_url"] != engine.RANKINGS_URL:
            raise ReceiptError("fetch receipt rankings URL mismatch")
        validate_execution_binding(receipt, repo, expected_fetch_command(source["policy_path"]))
        if not success:
            return
        assert artifact is not None
        snapshot = read_object(artifact, "snapshot")
        try:
            engine.validate_snapshot(snapshot)
        except engine.EngineError as error:
            raise ReceiptError(f"snapshot validation failed: {error}") from error
        metadata = snapshot["source"]["fetch_metadata"]
        for key in ("ranking_window_start_date", "ranking_window_end_date", "successful_source_count"):
            if source[key] != metadata[key]:
                raise ReceiptError(f"fetch receipt {key} does not match snapshot")
        confirmed = sorted(
            row["source_model_id"] for row in snapshot["rows"]
            if row["pricing_status"] == "no_provider_endpoints"
        )
        confirmation_count = sum(
            row["source_metadata"]["endpoint_set_confirmation"] != "not_required"
            for row in snapshot["rows"]
        )
        if source["confirmed_empty_model_ids"] != confirmed or source["confirmation_request_count"] != confirmation_count:
            raise ReceiptError("fetch receipt endpoint confirmation claims do not match snapshot")
        return

    inputs = receipt["inputs"]
    expected = {
        "snapshot_path", "snapshot_content_digest", "snapshot_file_sha256",
        "policy_path", "policy_file_sha256", "rate_card_path", "rate_card_file_sha256",
    }
    if not isinstance(inputs, dict) or set(inputs) != expected:
        raise ReceiptError("compute receipt input binding is malformed")
    snapshot_path = resolve_repo_path(repo, inputs["snapshot_path"], "inputs.snapshot_path")
    policy_path = resolve_repo_path(repo, inputs["policy_path"], "inputs.policy_path")
    rate_card_path = resolve_repo_path(repo, inputs["rate_card_path"], "inputs.rate_card_path")
    for path, field in (
        (snapshot_path, "snapshot_file_sha256"), (policy_path, "policy_file_sha256"),
        (rate_card_path, "rate_card_file_sha256"),
    ):
        if sha256_file(path) != inputs[field]:
            raise ReceiptError(f"compute receipt {field} does not match exact input bytes")
    snapshot = read_object(snapshot_path, "snapshot")
    if snapshot.get("content_digest") != inputs["snapshot_content_digest"]:
        raise ReceiptError("compute receipt snapshot semantic digest mismatch")
    try:
        engine.validate_snapshot(snapshot)
    except engine.EngineError as error:
        raise ReceiptError(f"snapshot validation failed: {error}") from error
    validate_execution_binding(receipt, repo, expected_compute_command(inputs))
    if not success:
        return
    assert artifact is not None
    proposal = read_object(artifact, "proposal")
    generated_at = parse_time(proposal.get("generated_at"), "proposal.generated_at")
    try:
        replay = engine.build_proposal(
            snapshot, read_object(policy_path, "policy"), read_object(rate_card_path, "rate card"),
            now=generated_at,
        )
    except engine.EngineError as error:
        raise ReceiptError(f"proposal replay failed: {error}") from error
    if proposal != replay:
        raise ReceiptError("archived proposal does not exactly replay from bound inputs")


def run_child(repo: Path, arguments: list[str], api_key: str, temporary: Path) -> tuple[datetime, datetime, subprocess.CompletedProcess[str]]:
    started = utc_now()
    environment = os.environ.copy()
    environment["OPENROUTER_API_KEY"] = api_key
    completed = subprocess.run(
        [sys.executable, *arguments], cwd=repo, env=environment, text=True,
        encoding="utf-8", stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
    )
    finished = utc_now()
    return started, finished, completed


def unique_artifact(directory: Path, pattern: str) -> Path:
    matches = list(directory.glob(pattern))
    if len(matches) != 1:
        raise ReceiptError(f"expected exactly one {pattern} artifact, found {len(matches)}")
    return matches[0]


def require_empty_failure_output(directory: Path) -> None:
    if any(directory.iterdir()):
        raise ReceiptError("failed stage emitted unexpected output; refusing an empty-inventory receipt")


def rollback_published(
    published: list[tuple[Path, int, int]], archive: Path,
) -> list[Path]:
    preserved: list[Path] = []
    for target, device, inode in published:
        quarantine = archive / f".{target.name}.rollback-{uuid.uuid4().hex}"
        try:
            os.rename(target, quarantine)
        except FileNotFoundError:
            continue
        current = quarantine.stat(follow_symlinks=False)
        if (current.st_dev, current.st_ino) == (device, inode):
            quarantine.unlink()
            continue
        try:
            os.link(quarantine, target, follow_symlinks=False)
        except (FileExistsError, IsADirectoryError, PermissionError):
            preserved.append(quarantine)
        else:
            quarantine.unlink()
    return preserved


def archive_files(paths: tuple[Path, ...], archive: Path) -> tuple[Path, ...]:
    archive.mkdir(parents=True, exist_ok=True)
    targets = tuple(archive / path.name for path in paths)
    for target in targets:
        if target.exists():
            raise ReceiptError(f"refusing to overwrite archived evidence {target.name}")
    before = [(path.stat().st_size, sha256_file(path)) for path in paths]
    temporary_paths: list[Path] = []
    published: list[tuple[Path, int, int]] = []
    try:
        for source, target in zip(paths, targets):
            descriptor, temporary_name = tempfile.mkstemp(
                prefix=f".{target.name}.", suffix=".tmp", dir=archive,
            )
            os.close(descriptor)
            temporary_path = Path(temporary_name)
            temporary_paths.append(temporary_path)
            shutil.copyfile(source, temporary_path)
        staged = [(path.stat().st_size, sha256_file(path)) for path in temporary_paths]
        if before != staged:
            raise ReceiptError("staged archive evidence is not byte-identical to its validated source")
        for temporary_path, target in zip(temporary_paths, targets):
            staged_stat = temporary_path.stat(follow_symlinks=False)
            try:
                os.link(temporary_path, target)
            except FileExistsError as error:
                raise ReceiptError(f"refusing to overwrite concurrently created evidence {target.name}") from error
            published.append((target, staged_stat.st_dev, staged_stat.st_ino))
        after = [(path.stat().st_size, sha256_file(path)) for path in targets]
        if before != after:
            raise ReceiptError("archived evidence is not byte-identical to its validated source")
        return targets
    except BaseException as error:
        preserved = rollback_published(published, archive)
        if preserved:
            error.add_note(
                "concurrent replacement preserved at "
                + ", ".join(path.name for path in preserved)
            )
        raise
    finally:
        for temporary_path in temporary_paths:
            try:
                temporary_path.unlink()
            except FileNotFoundError:
                pass


def archive_pair(receipt_path: Path, artifact_path: Path, archive: Path) -> tuple[Path, Path]:
    archived = archive_files((receipt_path, artifact_path), archive)
    return archived[0], archived[1]


def archive_receipt(receipt_path: Path, archive: Path) -> Path:
    return archive_files((receipt_path,), archive)[0]


def command_validate(args: argparse.Namespace) -> int:
    repo = Path(args.repo).resolve()
    for value in args.receipt:
        validate_receipt(Path(value).resolve(), repo)
        print(f"validated {Path(value).resolve()}")
    return 0


def command_run(args: argparse.Namespace) -> int:
    repo = Path(args.repo).resolve()
    api_key_file = Path(args.api_key_file).resolve() if args.api_key_file else None
    if api_key_file:
        api_key = api_key_file.read_text(encoding="utf-8").strip()
    else:
        api_key = os.environ.get("OPENROUTER_API_KEY", "").strip()
    if not api_key or not SECRET_RE.fullmatch(api_key):
        raise ReceiptError("a valid OpenRouter API key is required via environment or --api-key-file")
    if (args.top_n, args.demand_window_days, args.retries, args.timeout_seconds, args.generation_timeout_seconds) != (50, 30, 3, 20.0, 900.0):
        raise ReceiptError("schema-version 2 receipts require the reviewed top-50/30-day/default-timeout run contract")
    commit = clean_commit(repo)
    archive = (repo / args.archive_dir).resolve()
    policy = (repo / args.policy).resolve()
    rate_card = (repo / args.rate_card).resolve()
    policy_relative = policy.relative_to(repo).as_posix()
    rate_card_relative = rate_card.relative_to(repo).as_posix()
    policy_hash = sha256_file(policy)
    rate_card_hash = sha256_file(rate_card)

    with tempfile.TemporaryDirectory(prefix="openrouter-pricing-run-") as temporary_name:
        temporary = Path(temporary_name)
        fetch_dir = temporary / "fetch"
        compute_dir = temporary / "compute"
        fetch_dir.mkdir()
        compute_dir.mkdir()
        fetch_args = [
            "scripts/openrouter_pricing_engine.py", "fetch", "--policy", policy_relative,
            "--output-dir", str(fetch_dir), "--top-n", str(args.top_n),
            "--demand-window-days", str(args.demand_window_days), "--retries", str(args.retries),
            "--timeout-seconds", str(args.timeout_seconds),
            "--generation-timeout-seconds", str(args.generation_timeout_seconds),
        ]
        fetch_started, fetch_finished, fetched = run_child(repo, fetch_args, api_key, temporary)
        if fetched.returncode != 0:
            require_empty_failure_output(fetch_dir)
            fetch_failure = {
                "schema_version": RECEIPT_SCHEMA_VERSION,
                "receipt_type": FETCH_FAILURE,
                "started_at": rfc3339(fetch_started), "finished_at": rfc3339(fetch_finished),
                "engine_commit": commit, "execution": {"worktree_clean": True},
                "command": expected_fetch_command(policy_relative),
                "source": {
                    "rankings_url": engine.RANKINGS_URL,
                    "openrouter_api_key_configured": True,
                    "policy_path": policy_relative, "policy_file_sha256": policy_hash,
                },
                "exit_status": fetched.returncode,
                "stdout": redact(fetched.stdout, api_key, temporary),
                "stderr": redact(fetched.stderr, api_key, temporary),
                "output_directory_listing": [],
            }
            failure_path = fetch_dir / f"openrouter-pricing-fetch-failure-{receipt_stamp(fetch_started)}.json"
            write_receipt(failure_path, fetch_failure)
            validate_receipt(failure_path, repo)
            archived_failure = archive_receipt(failure_path, archive)
            validate_receipt(archived_failure, repo)
            print(archived_failure)
            raise ReceiptError(f"authenticated fetch failed with exit {fetched.returncode}; archived redacted failure receipt")
        snapshot_path = unique_artifact(fetch_dir, "openrouter-pricing-snapshot-*.json")
        snapshot = read_object(snapshot_path, "snapshot")
        engine.validate_snapshot(snapshot)
        metadata = snapshot["source"]["fetch_metadata"]
        confirmed = sorted(row["source_model_id"] for row in snapshot["rows"] if row["pricing_status"] == "no_provider_endpoints")
        confirmation_count = sum(row["source_metadata"]["endpoint_set_confirmation"] != "not_required" for row in snapshot["rows"])
        fetch_receipt = {
            "schema_version": RECEIPT_SCHEMA_VERSION,
            "receipt_type": FETCH_SUCCESS,
            "started_at": rfc3339(fetch_started), "finished_at": rfc3339(fetch_finished),
            "engine_commit": commit, "execution": {"worktree_clean": True},
            "command": ["python", *["<temporary-artifact-directory>" if item == str(fetch_dir) else item for item in fetch_args]],
            "source": {
                "rankings_url": engine.RANKINGS_URL,
                "ranking_window_start_date": metadata["ranking_window_start_date"],
                "ranking_window_end_date": metadata["ranking_window_end_date"],
                "openrouter_api_key_configured": True,
                "confirmed_empty_model_ids": confirmed,
                "confirmation_request_count": confirmation_count,
                "successful_source_count": metadata["successful_source_count"],
                "policy_path": policy_relative, "policy_file_sha256": policy_hash,
            },
            "exit_status": fetched.returncode,
            "stdout": redact(fetched.stdout, api_key, temporary),
            "stderr": redact(fetched.stderr, api_key, temporary),
            "output_directory_listing": [inventory(snapshot_path)],
        }
        fetch_receipt_path = fetch_dir / f"openrouter-pricing-fetch-success-{receipt_stamp(fetch_started)}.json"
        write_receipt(fetch_receipt_path, fetch_receipt)

        validate_receipt(fetch_receipt_path, repo)
        archived_fetch, archived_snapshot = archive_pair(fetch_receipt_path, snapshot_path, archive)

        archive_relative = archive.relative_to(repo).as_posix()
        snapshot_relative = f"{archive_relative}/{snapshot_path.name}"
        compute_inputs = {
            "snapshot_path": snapshot_relative,
            "snapshot_content_digest": snapshot["content_digest"],
            "snapshot_file_sha256": sha256_file(snapshot_path),
            "policy_path": policy_relative, "policy_file_sha256": policy_hash,
            "rate_card_path": rate_card_relative, "rate_card_file_sha256": rate_card_hash,
        }
        compute_args = [
            ENGINE_PATH, "compute", "--snapshot", str(archived_snapshot),
            "--policy", policy_relative, "--rate-card", rate_card_relative,
            "--output-dir", str(compute_dir),
        ]
        compute_started, compute_finished, computed = run_child(repo, compute_args, api_key, temporary)
        if computed.returncode != 0:
            require_empty_failure_output(compute_dir)
            compute_failure = {
                "schema_version": RECEIPT_SCHEMA_VERSION,
                "receipt_type": COMPUTE_FAILURE,
                "started_at": rfc3339(compute_started), "finished_at": rfc3339(compute_finished),
                "engine_commit": commit, "execution": {"worktree_clean": True},
                "command": expected_compute_command(compute_inputs),
                "inputs": compute_inputs,
                "exit_status": computed.returncode,
                "stdout": redact(computed.stdout, api_key, temporary),
                "stderr": redact(computed.stderr, api_key, temporary),
                "output_directory_listing": [],
            }
            failure_path = compute_dir / f"openrouter-pricing-compute-failure-{receipt_stamp(compute_started)}.json"
            write_receipt(failure_path, compute_failure)
            validate_receipt(failure_path, repo)
            archived_failure = archive_receipt(failure_path, archive)
            validate_receipt(archived_failure, repo)
            print(archived_fetch)
            print(archived_snapshot)
            print(archived_failure)
            raise ReceiptError(f"compute failed with exit {computed.returncode}; archived redacted failure receipt")
        proposal_path = unique_artifact(compute_dir, "openrouter-rate-card-proposal-*.json")
        compute_receipt = {
            "schema_version": RECEIPT_SCHEMA_VERSION,
            "receipt_type": COMPUTE_SUCCESS,
            "started_at": rfc3339(compute_started), "finished_at": rfc3339(compute_finished),
            "engine_commit": commit, "execution": {"worktree_clean": True},
            "command": expected_compute_command(compute_inputs),
            "inputs": compute_inputs,
            "exit_status": computed.returncode,
            "stdout": redact(computed.stdout, api_key, temporary),
            "stderr": redact(computed.stderr, api_key, temporary),
            "output_directory_listing": [inventory(proposal_path)],
        }
        compute_receipt_path = compute_dir / f"openrouter-pricing-compute-success-{receipt_stamp(compute_started)}.json"
        write_receipt(compute_receipt_path, compute_receipt)
        validate_receipt(compute_receipt_path, repo)
        archived_compute, archived_proposal = archive_pair(compute_receipt_path, proposal_path, archive)
        validate_receipt(archived_fetch, repo)
        validate_receipt(archived_compute, repo)
        for path in (archived_fetch, archived_snapshot, archived_compute, archived_proposal):
            print(path)
    return 0


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    subcommands = result.add_subparsers(dest="command", required=True)
    validate = subcommands.add_parser("validate", help="validate archived schema-v2 receipts and exact artifacts")
    validate.add_argument("--repo", default=".")
    validate.add_argument("--receipt", action="append", required=True)
    validate.set_defaults(handler=command_validate)
    run = subcommands.add_parser("run", help="perform an authenticated clean-head fetch and compute with receipts")
    run.add_argument("--repo", default=".")
    run.add_argument("--archive-dir", default="docs/research/openrouter-snapshots")
    run.add_argument("--policy", default="scripts/openrouter_pricing_policy.json")
    run.add_argument("--rate-card", default="phase3-binary/catalog/autotune/rate-card.json")
    run.add_argument("--api-key-file", help=argparse.SUPPRESS)
    run.add_argument("--top-n", type=int, default=50)
    run.add_argument("--demand-window-days", type=int, default=30)
    run.add_argument("--retries", type=int, default=3)
    run.add_argument("--timeout-seconds", type=float, default=20.0)
    run.add_argument("--generation-timeout-seconds", type=float, default=900.0)
    run.set_defaults(handler=command_run)
    return result


def main(argv: list[str] | None = None) -> int:
    try:
        arguments = parser().parse_args(argv)
        return arguments.handler(arguments)
    except (ReceiptError, engine.EngineError, OSError, ValueError) as error:
        print(f"openrouter pricing receipt: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
