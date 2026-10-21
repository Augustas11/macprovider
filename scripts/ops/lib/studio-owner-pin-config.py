#!/usr/bin/env python3
"""Durable, scoped removal/restoration of the Studio concurrency owner pin.

The full config may contain credentials, so only the protected backup contains
its bytes.  The journal contains hashes and the two non-secret owned values.
Every mutation holds the same advisory lock as the released CLI and replaces
the config atomically without round-tripping unrelated YAML.
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import re
import stat
import tempfile
from pathlib import Path


SCHEMA = "macprovider.studio_owner_pin.v1"
OWNED = ("max_concurrency_override", "max_concurrency_source")
TOP_LEVEL = re.compile(r"^([A-Za-z0-9_]+):(?:[ \t]*(.*?))?[ \t]*(?:\r?\n)?$")


class Refusal(RuntimeError):
    pass


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def safe_regular(path: Path, *, must_exist: bool = True) -> os.stat_result | None:
    try:
        info = path.lstat()
    except FileNotFoundError:
        if must_exist:
            raise Refusal(f"missing file: {path}")
        return None
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.getuid():
        raise Refusal(f"unsafe file: {path}")
    return info


def fsync_dir(path: Path) -> None:
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def atomic_write(path: Path, data: bytes, mode: int = 0o600) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    tmp = Path(tmp_name)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb", closefd=True) as out:
            out.write(data)
            out.flush()
            os.fsync(out.fileno())
        os.replace(tmp, path)
        fsync_dir(path.parent)
    finally:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass


def scalar(value: str) -> str:
    value = value.strip()
    if " #" in value:
        raise Refusal("owned concurrency values may not use inline comments")
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
        raise Refusal("owned concurrency values must use the approved plain scalar form")
    return value


def fields(data: bytes) -> tuple[dict[str, tuple[int, str, bytes]], list[bytes]]:
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise Refusal("config is not UTF-8") from exc
    lines = text.splitlines(keepends=True)
    found: dict[str, tuple[int, str, bytes]] = {}
    for index, line in enumerate(lines):
        if line[:1].isspace() or line.lstrip().startswith("#"):
            continue
        match = TOP_LEVEL.fullmatch(line)
        if not match:
            if any(key in line for key in OWNED):
                raise Refusal("unsupported YAML syntax for an owned concurrency key")
            continue
        key = match.group(1)
        if key not in OWNED:
            continue
        if key in found:
            raise Refusal(f"duplicate top-level key: {key}")
        found[key] = (index, scalar(match.group(2) or ""), line.encode("utf-8"))
    return found, [line.encode("utf-8") for line in lines]


def without_owned(data: bytes) -> bytes:
    found, lines = fields(data)
    drop = {item[0] for item in found.values()}
    return b"".join(line for index, line in enumerate(lines) if index not in drop)


def owned_state(data: bytes) -> dict[str, str | None]:
    found, _ = fields(data)
    return {key: (found[key][1] if key in found else None) for key in OWNED}


def lock_path(config: Path) -> Path:
    return config.parent / f".{config.name}.lock"


class ConfigLock:
    def __init__(self, config: Path):
        self.path = lock_path(config)
        self.fd = -1

    def __enter__(self) -> "ConfigLock":
        flags = os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0)
        self.fd = os.open(self.path, flags, 0o600)
        os.fchmod(self.fd, 0o600)
        fcntl.flock(self.fd, fcntl.LOCK_EX)
        return self

    def __exit__(self, *_: object) -> None:
        fcntl.flock(self.fd, fcntl.LOCK_UN)
        os.close(self.fd)


def read_journal(path: Path) -> dict:
    safe_regular(path)
    try:
        value = json.loads(path.read_text())
    except (OSError, ValueError) as exc:
        raise Refusal("journal is unreadable") from exc
    if value.get("schema_version") != SCHEMA:
        raise Refusal("journal schema mismatch")
    required = (
        "config_path", "backup_path", "baseline_sha256", "baseline_unowned_sha256",
        "version", "provider_id_sha256", "model", "policy_sha256",
        "policy_release_id", "policy_tuple_sha256", "binary_sha256", "team_id",
        "signing_identifier", "cdhash", "executable_path",
    )
    if not all(isinstance(value.get(key), str) and value[key] for key in required):
        raise Refusal("journal metadata is incomplete")
    if value.get("phase") not in {"prepared", "applied", "accepted", "config_restored"}:
        raise Refusal("journal phase is invalid")
    if value.get("baseline_owned") != {OWNED[0]: "4", OWNED[1]: "owner"} or value.get(
        "intended_owned"
    ) != {OWNED[0]: None, OWNED[1]: None}:
        raise Refusal("journal owned-field contract mismatch")
    if value["phase"] == "accepted":
        if (
            not isinstance(value.get("accepted_pid"), int)
            or isinstance(value.get("accepted_pid"), bool)
            or value["accepted_pid"] <= 0
            or not isinstance(value.get("accepted_process_start_us"), int)
            or isinstance(value.get("accepted_process_start_us"), bool)
            or value["accepted_process_start_us"] <= 0
            or value.get("accepted_executable_path") != value["executable_path"]
        ):
            raise Refusal("journal accepted process identity is invalid")
    return value


def write_journal(path: Path, value: dict) -> None:
    atomic_write(path, (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode())


def validate_paths(config: Path, journal: Path, backup: Path | None = None) -> None:
    if not config.is_absolute() or not journal.is_absolute() or (backup and not backup.is_absolute()):
        raise Refusal("paths must be absolute")
    safe_regular(config)
    if config.is_symlink() or config.resolve() != config:
        raise Refusal("config may not resolve through a symlink")
    if backup and (
        backup.parent.resolve() != config.parent.resolve()
        or not backup.name.startswith(f"{config.name}.bak-owner-pin-")
    ):
        raise Refusal("backup path is outside the scoped owner-pin namespace")


def prepare(args: argparse.Namespace) -> None:
    config, journal, backup = map(Path, (args.config, args.journal, args.backup))
    validate_paths(config, journal, backup)
    if journal.exists() or backup.exists():
        raise Refusal("journal or backup already exists")
    with ConfigLock(config):
        data = config.read_bytes()
        state = owned_state(data)
        if state != {OWNED[0]: "4", OWNED[1]: "owner"}:
            raise Refusal("config does not hold the exact 4/owner pin")
        fd = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
        try:
            os.fchmod(fd, 0o600)
            with os.fdopen(fd, "wb", closefd=True) as out:
                out.write(data)
                out.flush()
                os.fsync(out.fileno())
            fsync_dir(backup.parent)
        except Exception:
            try:
                backup.unlink()
            except FileNotFoundError:
                pass
            raise
        record = {
            "schema_version": SCHEMA,
            "phase": "prepared",
            "config_path": str(config),
            "backup_path": str(backup),
            "baseline_sha256": sha(data),
            "baseline_unowned_sha256": sha(without_owned(data)),
            "baseline_owned": {OWNED[0]: "4", OWNED[1]: "owner"},
            "intended_owned": {OWNED[0]: None, OWNED[1]: None},
            "version": args.version,
            "provider_id_sha256": args.provider_id_sha256,
            "model": args.model,
            "policy_sha256": args.policy_sha256,
            "policy_release_id": args.policy_release_id,
            "policy_tuple_sha256": args.policy_tuple_sha256,
            "binary_sha256": args.binary_sha256,
            "team_id": args.team_id,
            "signing_identifier": args.signing_identifier,
            "cdhash": args.cdhash,
            "executable_path": args.executable_path,
        }
        try:
            write_journal(journal, record)
        except Exception:
            try:
                backup.unlink()
                fsync_dir(backup.parent)
            except FileNotFoundError:
                pass
            raise
    print(json.dumps({"phase": "prepared", "baseline_sha256": record["baseline_sha256"]}))


def apply(args: argparse.Namespace) -> None:
    config, journal = Path(args.config), Path(args.journal)
    validate_paths(config, journal)
    record = read_journal(journal)
    if record["config_path"] != str(config) or record["phase"] != "prepared":
        raise Refusal("journal is not prepared for this config")
    with ConfigLock(config):
        data = config.read_bytes()
        if sha(data) != record["baseline_sha256"]:
            raise Refusal("config changed after prepare")
        if owned_state(data) != record["baseline_owned"]:
            raise Refusal("owned pin changed after prepare")
        updated = without_owned(data)
        atomic_write(config, updated)
        record["phase"] = "applied"
        record["applied_sha256"] = sha(updated)
        write_journal(journal, record)
    print(json.dumps({"phase": "applied", "config_sha256": record["applied_sha256"]}))


def restore(args: argparse.Namespace) -> None:
    config, journal = Path(args.config), Path(args.journal)
    validate_paths(config, journal)
    record = read_journal(journal)
    if record["config_path"] != str(config):
        raise Refusal("journal belongs to another config")
    with ConfigLock(config):
        data = config.read_bytes()
        current = owned_state(data)
        baseline = record["baseline_owned"]
        if current == baseline:
            restored = data
        elif current == record["intended_owned"]:
            suffix = b"" if not data or data.endswith(b"\n") else b"\n"
            restored = data + suffix + b"max_concurrency_override: 4\nmax_concurrency_source: owner\n"
            atomic_write(config, restored)
        else:
            raise Refusal("owned concurrency fields changed externally; refusing to overwrite them")
        record["phase"] = "config_restored"
        record["restored_sha256"] = sha(restored)
        write_journal(journal, record)
    print(json.dumps({"phase": "config_restored", "config_sha256": record["restored_sha256"]}))


def accept(args: argparse.Namespace) -> None:
    config, journal = Path(args.config), Path(args.journal)
    validate_paths(config, journal)
    try:
        pid = int(args.pid)
        process_start_us = int(args.process_start_us)
    except ValueError as exc:
        raise Refusal("accepted process identity is not numeric") from exc
    if pid <= 0 or process_start_us <= 0 or args.executable_path == "":
        raise Refusal("accepted process identity is invalid")
    with ConfigLock(config):
        record = read_journal(journal)
        if record["phase"] != "applied" or owned_state(config.read_bytes()) != record["intended_owned"]:
            raise Refusal("config/journal is not ready to accept a serving process")
        if args.executable_path != record["executable_path"]:
            raise Refusal("accepted executable differs from the signed executable")
        record["phase"] = "accepted"
        record["accepted_pid"] = pid
        record["accepted_process_start_us"] = process_start_us
        record["accepted_executable_path"] = args.executable_path
        write_journal(journal, record)
    print(json.dumps({"phase": "accepted", "pid": pid, "process_start_us": process_start_us}))


def finish(args: argparse.Namespace) -> None:
    config, journal = Path(args.config), Path(args.journal)
    validate_paths(config, journal)
    record = read_journal(journal)
    wanted = record["baseline_owned"] if args.restored else record["intended_owned"]
    expected_phase = "config_restored" if args.restored else "accepted"
    with ConfigLock(config):
        record = read_journal(journal)
        if record["phase"] != expected_phase or owned_state(config.read_bytes()) != wanted:
            raise Refusal("config/journal is not in the expected final state")
        backup = Path(record["backup_path"])
        validate_paths(config, journal, backup)
        info = safe_regular(backup, must_exist=False)
        if info is not None:
            if stat.S_IMODE(info.st_mode) != 0o600:
                raise Refusal("backup permissions are unsafe")
            if sha(backup.read_bytes()) != record["baseline_sha256"]:
                raise Refusal("backup bytes differ from the recorded baseline")
            backup.unlink()
            fsync_dir(backup.parent)
        journal.unlink()
        fsync_dir(journal.parent)
    print(json.dumps({"phase": "serving_restored" if args.restored else "complete"}))


def inspect(args: argparse.Namespace) -> None:
    journal = Path(args.journal)
    if not journal.exists():
        print(json.dumps({"journal": "absent"}))
        return
    record = read_journal(journal)
    config = Path(record["config_path"])
    safe_regular(config)
    print(json.dumps({
        "journal": "present",
        "phase": record["phase"],
        "version": record["version"],
        "owned": owned_state(config.read_bytes()),
    }, sort_keys=True))


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    sub = result.add_subparsers(dest="command", required=True)
    prep = sub.add_parser("prepare")
    for name in (
        "config", "journal", "backup", "version", "provider-id-sha256", "model",
        "policy-sha256", "policy-release-id", "policy-tuple-sha256", "binary-sha256",
        "team-id", "signing-identifier", "cdhash", "executable-path",
    ):
        prep.add_argument(f"--{name}", required=True)
    for command in ("apply", "restore"):
        child = sub.add_parser(command)
        child.add_argument("--config", required=True)
        child.add_argument("--journal", required=True)
    accepted = sub.add_parser("accept")
    accepted.add_argument("--config", required=True)
    accepted.add_argument("--journal", required=True)
    accepted.add_argument("--pid", required=True)
    accepted.add_argument("--process-start-us", required=True)
    accepted.add_argument("--executable-path", required=True)
    done = sub.add_parser("finish")
    done.add_argument("--config", required=True)
    done.add_argument("--journal", required=True)
    done.add_argument("--restored", action="store_true")
    view = sub.add_parser("inspect")
    view.add_argument("--journal", required=True)
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        globals()[args.command.replace("-", "_")](args)
        return 0
    except (OSError, KeyError, Refusal, ValueError) as exc:
        print(f"REFUSED: {exc}", file=os.sys.stderr)
        return 3


if __name__ == "__main__":
    raise SystemExit(main())
