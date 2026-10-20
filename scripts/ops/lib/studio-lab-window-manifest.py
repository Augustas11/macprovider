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
from pathlib import Path


SCHEMA = "macprovider.studio_lab_window_manifest.v1"
SAFE_TOKEN = re.compile(r"^[A-Za-z0-9._-]+$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
SHA40 = re.compile(r"^[0-9a-f]{40}$")
ARTIFACT_FIELDS = {
    "diagnostic_cli", "glmbench", "diagnostic_metallib", "glmbench_metallib",
    "fixture_config", "fixture_index",
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


def source_snapshot(args: argparse.Namespace) -> dict[str, object]:
    source = canonical_path(args.source_dir, "source directory")
    if not SHA40.fullmatch(args.git_head):
        raise Refusal("lab git head must be a lowercase 40-character SHA")
    if not SAFE_TOKEN.fullmatch(args.provider_label):
        raise Refusal("provider label is invalid")
    safe_directory(source)
    head = subprocess.run(
        ["git", "-C", str(source), "rev-parse", "HEAD"],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    if head != args.git_head:
        raise Refusal("lab source git head mismatch")
    dirty = subprocess.run(
        ["git", "-C", str(source), "status", "--porcelain", "--untracked-files=no"],
        capture_output=True, text=True, check=True,
    ).stdout
    if dirty:
        raise Refusal("lab source has tracked modifications")
    artifacts = {
        "diagnostic_cli": source / "phase3-binary/.build/release/macprovider-cli",
        "glmbench": source / "scripts/lab/cb-studio/glm53-bench/.build/release/GLMBench",
        "diagnostic_metallib": source / "phase3-binary/.build/release/mlx.metallib",
        "glmbench_metallib": source / "scripts/lab/cb-studio/glm53-bench/.build/release/mlx.metallib",
        "fixture_config": source / ".lab-window/fixture/target/config.json",
        "fixture_index": source / ".lab-window/fixture/target/model.safetensors.index.json",
    }
    result: dict[str, dict[str, str]] = {}
    for name, path in artifacts.items():
        target = safe_artifact(path, executable=name in {"diagnostic_cli", "glmbench"})
        result[name] = {"path": str(path), "sha256": file_sha256(target)}
    launch_agents = Path.home().resolve() / "Library" / "LaunchAgents"
    return {
        "artifacts": result,
        "provider_plist": str(launch_agents / f"{args.provider_label}.plist"),
        "watchdog_plist": str(launch_agents / f"{args.provider_label}-watchdog.plist"),
    }


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
    artifacts = source.get("artifacts")
    if not isinstance(artifacts, dict) or set(artifacts) != ARTIFACT_FIELDS:
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
    return {
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
        "lab_timeout_s": positive(args.lab_timeout_s, "lab timeout", 3600),
        "ready_timeout_s": readiness_timeout(args.ready_timeout_s),
        "poll_s": positive(args.poll_s, "poll interval", 60),
        "baseline": {**hashes, "snapshot": {field: snapshot[field] for field in SNAPSHOT_FIELDS}},
        "artifacts": artifacts,
    }


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser()
    sub = root.add_subparsers(dest="command", required=True)
    snapshot = sub.add_parser("source-snapshot")
    snapshot.add_argument("--source-dir", required=True)
    snapshot.add_argument("--git-head", required=True)
    snapshot.add_argument("--provider-label", required=True)
    build = sub.add_parser("build")
    for name in (
        "nonce", "git-head", "probe-json", "source-snapshot-json", "probe-sha256",
        "lab-script-sha256",
        "install-dir", "config-path", "ctl-socket", "provider-label", "status-port",
        "probe-path", "owner-pin-journal", "lab-source-dir", "lab-script-path",
        "log-path", "drain-timeout-s", "lab-timeout-s", "ready-timeout-s", "poll-s",
    ):
        build.add_argument(f"--{name}", required=True)
    return root


def main() -> int:
    args = parser().parse_args()
    try:
        result = source_snapshot(args) if args.command == "source-snapshot" else build_manifest(args)
        print(json.dumps(result, sort_keys=True, separators=(",", ":")))
        return 0
    except (OSError, Refusal, subprocess.SubprocessError, ValueError) as exc:
        print(f"studio-lab-window-manifest: REFUSED: {exc}", file=sys.stderr)
        return 3


if __name__ == "__main__":
    raise SystemExit(main())
