#!/usr/bin/env python3
"""Controller for the privacy lab config-change checkpoint.

The controller owns only a prepared lab config replacement. It waits for the
signed CLI's checkpoint-ready frame, atomically swaps the lab config, and acks
the same nonce. It does not launch the CLI, force an outcome, touch production
configuration, or inspect secrets.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import select
import socket
import stat
import sys
import time
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1
READY_EVENT = "privacy_lab_config_change_checkpoint_ready"
ACK_EVENT = "privacy_lab_config_change_checkpoint_ack"
MAX_FRAME_BYTES = 4096
MAX_CONFIG_BYTES = 1 << 20
DEFAULT_TIMEOUT_SECONDS = 2.0


class CheckpointError(RuntimeError):
    pass


def _die(message: str) -> None:
    raise CheckpointError(message)


def _lexically_canonical(path: Path, label: str) -> Path:
    raw = os.fspath(path)
    if not raw.startswith("/") or raw == "/" or raw.endswith("/") or "//" in raw:
        _die(f"{label} must be an absolute lexical canonical path: {raw}")
    parts = raw.split("/")[1:]
    if any(part in {"", ".", ".."} for part in parts):
        _die(f"{label} must not contain empty, dot, or dot-dot components: {raw}")
    return Path(raw)


def _lstat_no_symlink(path: Path, label: str) -> os.stat_result:
    try:
        st = path.lstat()
    except FileNotFoundError:
        _die(f"{label} is absent: {path}")
    if stat.S_ISLNK(st.st_mode):
        _die(f"{label} must not be a symlink: {path}")
    return st


def _reject_symlink_components(path: Path, label: str) -> None:
    current = Path("/")
    for part in path.parts[1:]:
        current = current / part
        st = _lstat_no_symlink(current, label)
        if current != path and not stat.S_ISDIR(st.st_mode):
            _die(f"{label} parent component is not a directory: {current}")


def _require_private_lab_root(path: Path) -> Path:
    root = _lexically_canonical(path, "lab root")
    _reject_symlink_components(root, "lab root")
    st = _lstat_no_symlink(root, "lab root")
    if not stat.S_ISDIR(st.st_mode):
        _die(f"lab root must be a directory: {root}")
    if st.st_uid != os.getuid():
        _die(f"lab root must be owned by the current user: {root}")
    if stat.S_IMODE(st.st_mode) != 0o700:
        _die(f"lab root mode must be 0700: {root}")
    return root


def _require_direct_lab_child(path: Path, lab_root: Path, label: str) -> Path:
    candidate = _lexically_canonical(path, label)
    if os.path.commonpath([os.fspath(lab_root), os.fspath(candidate)]) != os.fspath(lab_root):
        _die(f"{label} must stay under lab root: {candidate}")
    if candidate.parent != lab_root:
        _die(f"{label} must be a direct child of lab root: {candidate}")
    _reject_symlink_components(candidate, label)
    return candidate


def _open_lab_root_dir(lab_root: Path) -> int:
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    try:
        fd = os.open(lab_root, flags)
    except OSError as exc:
        _die(f"lab root open failed: {exc.strerror}")
    try:
        st = os.fstat(fd)
        lst = lab_root.lstat()
        if (st.st_dev, st.st_ino) != (lst.st_dev, lst.st_ino):
            _die(f"lab root changed while opening: {lab_root}")
        if not stat.S_ISDIR(st.st_mode):
            _die(f"lab root must be a directory: {lab_root}")
        if st.st_uid != os.getuid():
            _die(f"lab root must be owned by the current user: {lab_root}")
        if stat.S_IMODE(st.st_mode) != 0o700:
            _die(f"lab root mode must be 0700: {lab_root}")
        return fd
    except Exception:
        os.close(fd)
        raise


def _open_private_regular_at(root_fd: int, name: str, label: str) -> int:
    if not name or "/" in name or name in {".", ".."}:
        _die(f"{label} must be addressed as a direct lab-root child")
    flags = os.O_RDONLY | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    try:
        fd = os.open(name, flags, dir_fd=root_fd)
    except OSError as exc:
        _die(f"{label} open failed: {exc.strerror}")
    try:
        st = os.fstat(fd)
        lst = os.stat(name, dir_fd=root_fd, follow_symlinks=False)
        if (st.st_dev, st.st_ino) != (lst.st_dev, lst.st_ino):
            _die(f"{label} changed while opening: {name}")
        if not stat.S_ISREG(st.st_mode):
            _die(f"{label} must be a regular file: {name}")
        if st.st_uid != os.getuid():
            _die(f"{label} must be owned by the current user: {name}")
        if stat.S_IMODE(st.st_mode) != 0o600:
            _die(f"{label} mode must be 0600: {name}")
        if st.st_nlink != 1:
            _die(f"{label} must not have hardlinks: {name}")
        if st.st_size > MAX_CONFIG_BYTES:
            _die(f"{label} exceeds size limit")
        return fd
    except Exception:
        os.close(fd)
        raise


def _sha256_fd(fd: int, label: str) -> str:
    st = os.fstat(fd)
    if st.st_size > MAX_CONFIG_BYTES:
        _die(f"{label} exceeds size limit")
    digest = hashlib.sha256()
    total = 0
    os.lseek(fd, 0, os.SEEK_SET)
    while True:
        chunk = os.read(fd, 65536)
        if not chunk:
            break
        total += len(chunk)
        if total > MAX_CONFIG_BYTES:
            _die(f"{label} exceeds size limit")
        digest.update(chunk)
    os.lseek(fd, 0, os.SEEK_SET)
    return digest.hexdigest()


def _root_digest(lab_root: Path) -> str:
    return hashlib.sha256(os.fspath(lab_root).encode()).hexdigest()


def _validate_socket_fd(fd: int) -> None:
    if fd < 3:
        _die("checkpoint fd must be an inherited descriptor >= 3")
    try:
        dup = os.dup(fd)
    except OSError as exc:
        _die(f"checkpoint fd duplicate failed: {exc.strerror}")
    try:
        probe = socket.socket(fileno=dup)
    except OSError as exc:
        os.close(dup)
        _die(f"checkpoint fd must be a socket: {exc.strerror}")
    try:
        if probe.family != socket.AF_UNIX:
            _die("checkpoint fd must be AF_UNIX")
        if probe.getsockopt(socket.SOL_SOCKET, socket.SO_TYPE) != socket.SOCK_STREAM:
            _die("checkpoint fd must be SOCK_STREAM")
        try:
            probe.getpeername()
        except OSError as exc:
            _die(f"checkpoint fd must be connected: {exc.strerror}")
    finally:
        probe.close()


def _remaining(deadline: float) -> float:
    value = deadline - time.monotonic()
    if value <= 0:
        _die("checkpoint timed out")
    return value


def _strict_json_object(data: bytes, label: str) -> dict[str, Any]:
    def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        obj: dict[str, Any] = {}
        for key, value in pairs:
            if key in obj:
                _die(f"{label} has duplicate key: {key}")
            obj[key] = value
        return obj

    try:
        value = json.loads(
            data.decode(),
            object_pairs_hook=reject_duplicate_keys,
            parse_constant=lambda constant: _die(f"{label} has non-finite value: {constant}"),
        )
    except CheckpointError:
        raise
    except Exception as exc:
        _die(f"{label} malformed: {exc}")
    if not isinstance(value, dict):
        _die(f"{label} must be an object")
    return value


def _read_ready_frame(fd: int, deadline: float) -> dict[str, Any]:
    poller = select.poll()
    poller.register(fd, select.POLLIN)
    data = bytearray()
    os.set_blocking(fd, False)
    while True:
        events = poller.poll(int(_remaining(deadline) * 1000))
        if not events:
            _die("checkpoint timed out")
        revents = events[0][1]
        if revents & select.POLLNVAL:
            _die("checkpoint fd became invalid")
        if revents & select.POLLIN:
            try:
                chunk = os.read(fd, 1)
            except BlockingIOError:
                continue
            except InterruptedError:
                continue
            if not chunk:
                _die("checkpoint closed before ready frame")
            if chunk == b"\n":
                break
            data.extend(chunk)
            if len(data) > MAX_FRAME_BYTES:
                _die("checkpoint ready frame exceeded size limit")
            continue
        if revents & select.POLLHUP:
            _die("checkpoint closed before ready frame")
        if revents & select.POLLERR:
            _die("checkpoint fd error before ready frame")
    return _strict_json_object(bytes(data), "checkpoint ready frame")


def _write_ack(fd: int, nonce: str, deadline: float) -> None:
    payload = json.dumps(
        {"event": ACK_EVENT, "nonce": nonce, "schema_version": SCHEMA_VERSION},
        sort_keys=True,
        separators=(",", ":"),
    ).encode() + b"\n"
    poller = select.poll()
    poller.register(fd, select.POLLOUT)
    written = 0
    while written < len(payload):
        events = poller.poll(int(_remaining(deadline) * 1000))
        if not events:
            _die("checkpoint timed out")
        revents = events[0][1]
        if revents & (select.POLLNVAL | select.POLLHUP | select.POLLERR):
            _die("checkpoint fd closed before ack")
        if not (revents & select.POLLOUT):
            continue
        try:
            count = os.write(fd, payload[written:])
        except BrokenPipeError:
            _die("checkpoint fd closed before ack")
        except BlockingIOError:
            continue
        except InterruptedError:
            continue
        if count <= 0:
            _die("checkpoint ack write failed")
        written += count


def _validate_ready_frame(frame: dict[str, Any], *, expected_pid: int, lab_root: Path) -> str:
    if set(frame) != {"event", "schema_version", "nonce", "pid", "root_digest"}:
        _die("checkpoint ready frame has unexpected schema")
    if frame.get("event") != READY_EVENT:
        _die("checkpoint ready frame has wrong event")
    schema_version = frame.get("schema_version")
    if type(schema_version) is not int or schema_version != SCHEMA_VERSION:
        _die("checkpoint ready frame has wrong schema version")
    pid = frame.get("pid")
    if type(pid) is not int or pid != expected_pid:
        _die("checkpoint ready frame has wrong pid")
    if frame.get("root_digest") != _root_digest(lab_root):
        _die("checkpoint ready frame has wrong lab root digest")
    nonce = frame.get("nonce")
    if not isinstance(nonce, str) or not nonce or len(nonce.encode()) > 256:
        _die("checkpoint ready frame has invalid nonce")
    return nonce


def run_checkpoint(
    *,
    fd: int,
    expected_pid: int,
    lab_root: Path,
    config_path: Path,
    replacement_path: Path,
    replacement_sha256: str,
    timeout_seconds: float = DEFAULT_TIMEOUT_SECONDS,
) -> dict[str, Any]:
    """Run the checkpoint controller once and return a small status object."""

    if type(expected_pid) is not int or expected_pid <= 0:
        _die("expected pid must be positive")
    if not math.isfinite(timeout_seconds) or timeout_seconds <= 0:
        _die("timeout seconds must be finite and positive")
    if not (len(replacement_sha256) == 64 and all(c in "0123456789abcdef" for c in replacement_sha256)):
        _die("replacement sha256 must be lowercase hex")
    deadline = time.monotonic() + timeout_seconds
    _validate_socket_fd(fd)
    lab_root = _require_private_lab_root(lab_root)
    config_path = _require_direct_lab_child(config_path, lab_root, "config")
    replacement_path = _require_direct_lab_child(replacement_path, lab_root, "replacement")
    root_fd = _open_lab_root_dir(lab_root)
    try:
        # Validate the prepared files before waiting, then re-open them via the
        # pinned root fd after the CLI declares readiness. The second pass is the
        # one that authorizes mutation; the first pass is only an early fail-fast.
        for name, label in ((config_path.name, "config"), (replacement_path.name, "replacement")):
            candidate_fd = _open_private_regular_at(root_fd, name, label)
            try:
                if label == "replacement" and _sha256_fd(candidate_fd, label) != replacement_sha256:
                    _die("replacement sha256 mismatch")
            finally:
                os.close(candidate_fd)

        frame = _read_ready_frame(fd, deadline)
        nonce = _validate_ready_frame(frame, expected_pid=expected_pid, lab_root=lab_root)
        _remaining(deadline)

        config_fd = _open_private_regular_at(root_fd, config_path.name, "config")
        try:
            replacement_fd = _open_private_regular_at(root_fd, replacement_path.name, "replacement")
            try:
                if _sha256_fd(replacement_fd, "replacement") != replacement_sha256:
                    _die("replacement sha256 mismatch")
            finally:
                os.close(replacement_fd)
        finally:
            os.close(config_fd)

        _remaining(deadline)
        os.replace(replacement_path.name, config_path.name, src_dir_fd=root_fd, dst_dir_fd=root_fd)
        _write_ack(fd, nonce, deadline)
        return {"event": "privacy_lab_config_change_checkpoint_replaced", "pid": expected_pid, "root_digest": _root_digest(lab_root)}
    finally:
        os.close(root_fd)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fd", type=int, required=True)
    parser.add_argument("--expected-pid", type=int, required=True)
    parser.add_argument("--lab-root", type=Path, required=True)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--replacement", type=Path, required=True)
    parser.add_argument("--replacement-sha256", required=True)
    parser.add_argument("--timeout-seconds", type=float, default=DEFAULT_TIMEOUT_SECONDS)
    args = parser.parse_args(argv)
    try:
        result = run_checkpoint(
            fd=args.fd,
            expected_pid=args.expected_pid,
            lab_root=args.lab_root,
            config_path=args.config,
            replacement_path=args.replacement,
            replacement_sha256=args.replacement_sha256,
            timeout_seconds=args.timeout_seconds,
        )
    except CheckpointError as exc:
        print(f"FATAL privacy_lab_config_change_checkpoint_failed reason={exc}", file=sys.stderr)
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
