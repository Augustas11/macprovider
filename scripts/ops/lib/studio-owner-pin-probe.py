#!/usr/bin/env python3
"""Return a secret-free snapshot for the Studio owner-pin transaction."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import subprocess
from pathlib import Path


TOP_LEVEL = re.compile(r"^([A-Za-z0-9_]+):(?:[ \t]*(.*?))?[ \t]*(?:\r?\n)?$")
VISIBLE_CONFIG = {
    "max_concurrency_override",
    "max_concurrency_source",
    "continuous_batch_queue_limit",
    "draft_model",
}


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def regular(path: Path) -> None:
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.getuid():
        raise RuntimeError(f"unsafe file: {path.name}")


def scalar(value: str) -> str:
    value = value.strip()
    if " #" in value:
        raise RuntimeError("guarded config values may not use inline comments")
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
        raise RuntimeError("guarded config values must use plain scalar form")
    return value


def config_fields(path: Path) -> dict[str, str | None]:
    regular(path)
    values: dict[str, str | None] = {key: None for key in VISIBLE_CONFIG}
    seen: set[str] = set()
    for line in path.read_text().splitlines(keepends=True):
        if line[:1].isspace() or line.lstrip().startswith("#"):
            continue
        match = TOP_LEVEL.fullmatch(line)
        if not match:
            if any(key in line for key in VISIBLE_CONFIG):
                raise RuntimeError("unsupported YAML syntax for a guarded config key")
            continue
        if match.group(1) not in VISIBLE_CONFIG:
            continue
        key = match.group(1)
        if key in seen:
            raise RuntimeError(f"duplicate top-level config key: {key}")
        seen.add(key)
        values[key] = scalar(match.group(2) or "")
    return values


def nested(value: object, path: str) -> object | None:
    for part in path.split("."):
        value = value.get(part) if isinstance(value, dict) else None
    return value


def code_identity(binary: Path) -> dict[str, str]:
    proc = subprocess.run(
        ["codesign", "-d", "-vvv", str(binary)],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=True,
    )
    fields: dict[str, str] = {}
    for line in proc.stdout.splitlines():
        key, sep, value = line.partition("=")
        if sep and key in {"Identifier", "TeamIdentifier", "CDHash"}:
            fields[key] = value.strip()
    if set(fields) != {"Identifier", "TeamIdentifier", "CDHash"}:
        raise RuntimeError("installed CLI code identity is incomplete")
    return {
        "identifier": fields["Identifier"],
        "team_id": fields["TeamIdentifier"],
        "cdhash": fields["CDHash"].lower(),
    }


def journal_fields(path: Path, expected_config: Path | None = None) -> dict[str, object]:
    if not path.exists():
        return {"state": "absent"}
    regular(path)
    value = json.loads(path.read_text())
    if value.get("schema_version") != "macprovider.studio_owner_pin.v1":
        raise RuntimeError("owner-pin journal schema mismatch")
    if expected_config is not None and value.get("config_path") != str(expected_config):
        raise RuntimeError("owner-pin journal belongs to another config")
    if value.get("phase") not in {"prepared", "applied", "config_restored"}:
        raise RuntimeError("owner-pin journal phase is invalid")
    if value.get("baseline_owned") != {
        "max_concurrency_override": "4", "max_concurrency_source": "owner"
    } or value.get("intended_owned") != {
        "max_concurrency_override": None, "max_concurrency_source": None
    }:
        raise RuntimeError("owner-pin journal owned-field contract mismatch")
    allowed = (
        "phase", "version", "provider_id_sha256", "model", "policy_sha256",
        "policy_release_id", "policy_tuple_sha256",
    )
    selected = {key: value.get(key) for key in allowed}
    if not all(isinstance(item, str) and item for item in selected.values()):
        raise RuntimeError("owner-pin journal metadata is incomplete")
    return {"state": "present", **selected}


def hardware_model() -> str:
    return subprocess.run(
        ["sysctl", "-n", "hw.model"], capture_output=True, text=True, check=True
    ).stdout.strip()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--install-dir")
    parser.add_argument("--config")
    parser.add_argument("--journal", required=True)
    parser.add_argument("--port", type=int)
    parser.add_argument("--model")
    parser.add_argument("--journal-only", action="store_true")
    parser.add_argument("--expected-config")
    args = parser.parse_args()

    home = Path.home().resolve()
    journal = Path(args.journal)
    if args.journal_only:
        expected = Path(args.expected_config) if args.expected_config else None
        for path in (journal, expected):
            if path is not None and (not path.is_absolute() or home not in path.parents):
                raise RuntimeError("journal paths must be absolute and under HOME")
        print(json.dumps({
            "journal": journal_fields(journal, expected),
            "hardware_model": hardware_model(),
        }, sort_keys=True))
        return 0
    if not all((args.install_dir, args.config, args.port, args.model)):
        parser.error("full probe requires --install-dir, --config, --port and --model")
    install = Path(args.install_dir)
    config = Path(args.config)
    for path in (install, config, journal):
        if not path.is_absolute() or home not in path.parents:
            raise RuntimeError("all transaction paths must be absolute and under HOME")
    if not install.is_dir() or install.is_symlink() or install.resolve() != install:
        raise RuntimeError("unsafe install directory")
    binary = install / "macprovider-cli"
    policy_path = install / "catalog-release" / "continuous-batching-policy.json"
    regular(binary)
    regular(policy_path)

    status: dict[str, object] = {}
    status_error = ""
    try:
        response = subprocess.run(
            ["curl", "-fsS", "--max-time", "5", f"http://127.0.0.1:{args.port}/v1/status"],
            capture_output=True,
            check=True,
        )
        status = json.loads(response.stdout)
        if not isinstance(status, dict):
            raise RuntimeError("status is not an object")
    except Exception as exc:  # recovery must remain discoverable while down
        status_error = type(exc).__name__

    policy_bytes = policy_path.read_bytes()
    policy = json.loads(policy_bytes)
    matches = [entry for entry in policy.get("entries", []) if entry.get("model_key") == args.model]
    if len(matches) != 1:
        raise RuntimeError("installed policy has no unique target model entry")
    entry = matches[0]
    version = subprocess.run(
        [str(binary), "--version"], capture_output=True, text=True, check=True
    ).stdout.strip()
    provider_id = nested(status, "provider_id")
    selected = {
        path: nested(status, path)
        for path in (
            "binary_version", "model", "model_loaded", "network_state",
            "requests_in_flight", "service_instance.pid", "capacity.max_concurrency",
            "continuous_batching.active", "continuous_batching.policy.load_status",
            "continuous_batching.policy.authorized", "continuous_batching.policy.policy_sha256",
            "continuous_batching.policy.release_id", "continuous_batching.policy.tuple_sha256",
            "continuous_batching.self_check.served_slots",
            "continuous_batching.scheduler.slots_total", "coordinator.connected",
            "lifecycle.operator_paused",
        )
    }
    selected["provider_id_sha256"] = digest(str(provider_id).encode()) if provider_id else None
    print(json.dumps({
        "journal": journal_fields(journal, config),
        "config": config_fields(config),
        "installed": {
            "binary_version": version,
            "binary_sha256": digest(binary.read_bytes()),
            **code_identity(binary),
        },
        "policy": {
            "sha256": digest(policy_bytes),
            "release_id": policy.get("release_id"),
            "tuple_sha256": entry.get("tuple_sha256"),
            "max_served_slots": entry.get("max_served_slots"),
        },
        "status": selected,
        "status_error": status_error,
        "hardware_model": hardware_model(),
    }, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
