#!/usr/bin/env python3
"""Return a secret-free snapshot for the Studio owner-pin transaction."""

from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
import plistlib
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


def regular_bytes(path: Path, maximum: int) -> bytes:
    regular(path)
    before = path.lstat()
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        opened = os.fstat(fd)
        if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
            raise RuntimeError(f"file changed while opening: {path.name}")
        data = os.read(fd, maximum + 1)
    finally:
        os.close(fd)
    if len(data) > maximum or len(data) != before.st_size:
        raise RuntimeError(f"unsafe file size: {path.name}")
    return data


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
    subprocess.run(
        ["codesign", "--verify", "--strict", "--verbose=2", str(binary)],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=True,
    )
    proc = subprocess.run(
        ["codesign", "-d", "--arch", "arm64", "-vvv", str(binary)],
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


class ProcBsdInfo(ctypes.Structure):
    _fields_ = [
        ("pbi_flags", ctypes.c_uint32), ("pbi_status", ctypes.c_uint32),
        ("pbi_xstatus", ctypes.c_uint32), ("pbi_pid", ctypes.c_uint32),
        ("pbi_ppid", ctypes.c_uint32), ("pbi_uid", ctypes.c_uint32),
        ("pbi_gid", ctypes.c_uint32), ("pbi_ruid", ctypes.c_uint32),
        ("pbi_rgid", ctypes.c_uint32), ("pbi_svuid", ctypes.c_uint32),
        ("pbi_svgid", ctypes.c_uint32), ("rfu_1", ctypes.c_uint32),
        ("pbi_comm", ctypes.c_char * 16), ("pbi_name", ctypes.c_char * 32),
        ("pbi_nfiles", ctypes.c_uint32), ("pbi_pgid", ctypes.c_uint32),
        ("pbi_pjobc", ctypes.c_uint32), ("pbi_e_tdev", ctypes.c_uint32),
        ("pbi_e_tpgid", ctypes.c_uint32), ("pbi_nice", ctypes.c_int32),
        ("pbi_start_tvsec", ctypes.c_uint64), ("pbi_start_tvusec", ctypes.c_uint64),
    ]


def process_identity(pid: int) -> dict[str, object]:
    libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
    proc_pidinfo = libproc.proc_pidinfo
    proc_pidinfo.argtypes = [
        ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int
    ]
    proc_pidinfo.restype = ctypes.c_int
    info = ProcBsdInfo()
    if proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info)) != ctypes.sizeof(info):
        raise RuntimeError("could not read provider process identity")
    path_buffer = ctypes.create_string_buffer(4096)
    proc_pidpath = libproc.proc_pidpath
    proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    proc_pidpath.restype = ctypes.c_int
    if proc_pidpath(pid, path_buffer, ctypes.sizeof(path_buffer)) <= 0:
        raise RuntimeError("could not read provider process executable")
    start_us = int(info.pbi_start_tvsec) * 1_000_000 + int(info.pbi_start_tvusec)
    executable = path_buffer.value.decode("utf-8", "surrogateescape")
    if start_us <= 0 or not executable.startswith("/"):
        raise RuntimeError("provider process identity is invalid")
    return {
        "pid": pid,
        "process_start_us": start_us,
        "uid": int(info.pbi_uid),
        "ruid": int(info.pbi_ruid),
        "executable_path": os.path.realpath(executable),
    }


def launch_identity(binary: Path, config: Path, label: str, status_pid: object) -> dict[str, object]:
    if not isinstance(status_pid, int) or isinstance(status_pid, bool) or status_pid <= 0:
        raise RuntimeError("status has no valid provider pid")
    plist = Path.home() / "Library" / "LaunchAgents" / f"{label}.plist"
    document = plistlib.loads(regular_bytes(plist, 64 * 1024))
    if not isinstance(document, dict) or document.get("Label") != label:
        raise RuntimeError("provider LaunchAgent label mismatch")
    arguments = document.get("ProgramArguments")
    program = document.get("Program")
    if not isinstance(arguments, list) or len(arguments) != 4 or not all(
        isinstance(item, str) for item in arguments
    ):
        raise RuntimeError("provider LaunchAgent has no executable argument")
    expected = str(binary.resolve())
    config_flags = [index for index, item in enumerate(arguments) if item == "--config"]
    if os.path.realpath(arguments[0]) != expected or (
        program is not None and (not isinstance(program, str) or os.path.realpath(program) != expected)
    ) or arguments[1] != "serve" or len(config_flags) != 1 or config_flags[0] + 1 >= len(arguments) or (
        not os.path.isabs(arguments[config_flags[0] + 1])
        or os.path.realpath(arguments[config_flags[0] + 1]) != str(config.resolve())
    ):
        raise RuntimeError("provider LaunchAgent executable/config mismatch")
    launch = subprocess.run(
        ["launchctl", "print", f"gui/{os.getuid()}/{label}"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    match = re.search(r"(?m)^\s*pid\s*=\s*([0-9]+)\s*$", launch)
    if match is None or int(match.group(1)) != status_pid:
        raise RuntimeError("launchd and status provider pid mismatch")
    identity = process_identity(status_pid)
    if (
        identity["uid"] != os.getuid()
        or identity["ruid"] != os.getuid()
        or identity["executable_path"] != expected
    ):
        raise RuntimeError("running provider executable identity mismatch")
    return identity


def journal_fields(path: Path, expected_config: Path | None = None) -> dict[str, object]:
    if not path.exists():
        return {"state": "absent"}
    regular(path)
    value = json.loads(path.read_text())
    if value.get("schema_version") != "macprovider.studio_owner_pin.v1":
        raise RuntimeError("owner-pin journal schema mismatch")
    if expected_config is not None and value.get("config_path") != str(expected_config):
        raise RuntimeError("owner-pin journal belongs to another config")
    if value.get("phase") not in {"prepared", "applied", "accepted", "config_restored"}:
        raise RuntimeError("owner-pin journal phase is invalid")
    if value.get("baseline_owned") != {
        "max_concurrency_override": "4", "max_concurrency_source": "owner"
    } or value.get("intended_owned") != {
        "max_concurrency_override": None, "max_concurrency_source": None
    }:
        raise RuntimeError("owner-pin journal owned-field contract mismatch")
    allowed = (
        "phase", "version", "provider_id_sha256", "model", "policy_sha256",
        "policy_release_id", "policy_tuple_sha256", "binary_sha256", "team_id",
        "signing_identifier", "cdhash", "executable_path",
    )
    selected = {key: value.get(key) for key in allowed}
    if not all(isinstance(item, str) and item for item in selected.values()):
        raise RuntimeError("owner-pin journal metadata is incomplete")
    if value["phase"] == "accepted":
        for key in ("accepted_pid", "accepted_process_start_us", "accepted_executable_path"):
            selected[key] = value.get(key)
        if (
            not isinstance(selected["accepted_pid"], int)
            or isinstance(selected["accepted_pid"], bool)
            or selected["accepted_pid"] <= 0
            or not isinstance(selected["accepted_process_start_us"], int)
            or isinstance(selected["accepted_process_start_us"], bool)
            or selected["accepted_process_start_us"] <= 0
            or selected["accepted_executable_path"] != selected["executable_path"]
        ):
            raise RuntimeError("owner-pin journal accepted process identity is invalid")
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
    parser.add_argument("--label")
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
    if not all((args.install_dir, args.config, args.port, args.label)):
        parser.error("full probe requires --install-dir, --config, --port and --label")
    install = Path(args.install_dir)
    config = Path(args.config)
    for path in (install, config, journal):
        if not path.is_absolute() or home not in path.parents:
            raise RuntimeError("all transaction paths must be absolute and under HOME")
    if not install.is_dir() or install.is_symlink() or install.resolve() != install:
        raise RuntimeError("unsafe install directory")
    binary = install / "macprovider-cli"
    regular(binary)

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

    identity = code_identity(binary)
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
    launch = launch_identity(binary, config, args.label, selected["service_instance.pid"])
    print(json.dumps({
        "journal": journal_fields(journal, config),
        "config": config_fields(config),
        "installed": {
            "binary_version": version,
            "binary_sha256": digest(binary.read_bytes()),
            **identity,
        },
        "status": selected,
        "launch": {
            "pid": launch["pid"],
            "process_start_us": launch["process_start_us"],
            "executable_path": launch["executable_path"],
        },
        "status_error": status_error,
        "hardware_model": hardware_model(),
    }, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
