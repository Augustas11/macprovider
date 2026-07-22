#!/usr/bin/env python3
"""Bounded, no-retry evidence harness for issue #540 AEAD rekey gates."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import fcntl
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import shlex
import sqlite3
import stat
import subprocess
import sys
import threading
import time
from typing import Any
from urllib.parse import urlsplit


HARNESS_VERSION = "1.1.0"
BUYER_TOKEN_ENV = "MACPROVIDER_REKEY_BUYER_TOKEN"
OPERATOR_TOKEN_ENV = "MACPROVIDER_REKEY_OPERATOR_TOKEN"
MAX_REQUESTS = 100
MAX_SECONDS = 300
MAX_CONCURRENCY = 8
MAX_TOKENS = 128
MAX_RESPONSE_BYTES = 2 * 1024 * 1024
MAX_SENTINEL_TOKENS = 128
ALLOWED_PROVIDER_STATES = {"ready", "busy"}
REKEY_EVENTS = {
    "aead_rekey",
    "aead_rekey_committed",
    "aead_rekey_failed",
    "encrypted_leg_session_closed",
}
FORBIDDEN_MESSAGES = {
    "provider websocket closing",
    "provider websocket disconnected",
    "provider removed after disconnect grace period",
}


class HarnessError(RuntimeError):
    pass


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")


def parse_utc(value: Any) -> float | None:
    if not isinstance(value, str) or not value:
        return None
    candidate = value.strip()
    if candidate.endswith("Z"):
        candidate = candidate[:-1] + "+00:00"
    try:
        return datetime.fromisoformat(candidate).timestamp()
    except ValueError:
        return None


def regular_file(path_text: str, label: str) -> Path:
    candidate = Path(path_text).expanduser()
    try:
        mode = candidate.lstat().st_mode
    except FileNotFoundError as exc:
        raise HarnessError(f"{label} does not exist: {candidate}") from exc
    if stat.S_ISLNK(mode) or not stat.S_ISREG(mode):
        raise HarnessError(f"{label} must be a regular non-symlink file: {candidate}")
    return candidate.resolve()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def normalized_sha256(value: str, label: str) -> str:
    normalized = value.strip().lower()
    if not re.fullmatch(r"[0-9a-f]{64}", normalized):
        raise HarnessError(f"{label} must be exactly 64 hexadecimal characters")
    return normalized


def parse_yaml_scalars(path: Path) -> dict[str, str]:
    """Parse only ordinary nested scalar keys; sufficient for safety preflight."""
    result: dict[str, str] = {}
    stack: list[tuple[int, str]] = []
    key_pattern = re.compile(r"^([A-Za-z0-9_]+):(?:\s*(.*))?$")
    for line_number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if "\t" in raw[: len(raw) - len(raw.lstrip())]:
            raise HarnessError(f"tabs are not allowed in YAML indentation: {path}:{line_number}")
        stripped_comment = raw.split("#", 1)[0].rstrip()
        if not stripped_comment.strip() or stripped_comment.lstrip().startswith("-"):
            continue
        indent = len(stripped_comment) - len(stripped_comment.lstrip(" "))
        match = key_pattern.match(stripped_comment.strip())
        if not match:
            continue
        key, value = match.groups()
        while stack and stack[-1][0] >= indent:
            stack.pop()
        prefix = [item[1] for item in stack]
        full_key = ".".join(prefix + [key])
        if value is None or value == "":
            stack.append((indent, key))
            continue
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {'"', "'"}:
            value = value[1:-1]
        result[full_key] = value
    return result


def scalar_bool(values: dict[str, str], key: str) -> bool:
    value = values.get(key, "").lower()
    if value not in {"true", "false"}:
        raise HarnessError(f"{key} must be explicitly true or false")
    return value == "true"


def scalar_int(values: dict[str, str], key: str) -> int:
    try:
        return int(values[key])
    except (KeyError, ValueError) as exc:
        raise HarnessError(f"{key} must be an explicit integer") from exc


def validate_config(
    base_path: Path,
    overlay_path: Path,
    gate: str,
    max_requests: int,
    max_seconds: int,
) -> dict[str, Any]:
    merged = parse_yaml_scalars(base_path)
    merged.update(parse_yaml_scalars(overlay_path))
    bind_address = merged.get("listen.bind_address", "")
    if bind_address not in {"127.0.0.1", "::1"}:
        raise HarnessError("isolated coordinator listen.bind_address must be loopback")
    if not scalar_bool(merged, "coordinator.require_gateway_context"):
        raise HarnessError("coordinator.require_gateway_context must stay true")
    if scalar_int(merged, "routing.max_retries") != 0:
        raise HarnessError("routing.max_retries must be 0 for the no-retry drill")
    if not scalar_bool(merged, "tier2.require_encrypted_leg"):
        raise HarnessError("tier2.require_encrypted_leg must be true")

    after_requests = scalar_int(merged, "tier2.encrypted_leg_rekey_after_requests")
    after_seconds = scalar_int(merged, "tier2.encrypted_leg_rekey_after_seconds")
    if after_requests <= 0 or after_seconds <= 0:
        raise HarnessError("both startup-only rekey thresholds must be > 0")
    if gate == "request_threshold":
        if after_requests >= max_requests:
            raise HarnessError("request threshold must be below the one-shot request cap")
        if after_seconds <= max_seconds:
            raise HarnessError("age threshold must exceed the request-gate wall-clock cap")
    else:
        if after_seconds >= max_seconds:
            raise HarnessError("age threshold must be below the one-shot wall-clock cap")
        if after_requests <= max_requests:
            raise HarnessError("request threshold must exceed the age-gate request cap")

    db_path_text = merged.get("storage.db_path", "")
    if not db_path_text or not Path(db_path_text).is_absolute():
        raise HarnessError("storage.db_path must be an absolute isolated SQLite path")

    return {
        "base_path": str(base_path),
        "base_sha256": sha256_file(base_path),
        "overlay_path": str(overlay_path),
        "overlay_sha256": sha256_file(overlay_path),
        "listen_bind_address": bind_address,
        "require_gateway_context": True,
        "routing_max_retries": 0,
        "require_encrypted_leg": True,
        "encrypted_leg_rekey_after_requests": after_requests,
        "encrypted_leg_rekey_after_seconds": after_seconds,
        "buyer_port": scalar_int(merged, "listen.buyer_port"),
        "provider_port": scalar_int(merged, "listen.provider_port"),
        "db_path": str(Path(db_path_text).resolve()),
    }


def validate_gateway_config(
    path: Path,
    buyer_url: str,
    poolz_url: str,
    coordinator_config: dict[str, Any],
) -> dict[str, Any]:
    values = parse_yaml_scalars(path)
    bind_address = values.get("listen.bind_address", "")
    if bind_address not in {"127.0.0.1", "::1"}:
        raise HarnessError("isolated gateway listen.bind_address must be numeric loopback")
    if scalar_bool(values, "retry_503.enabled"):
        raise HarnessError("gateway retry_503.enabled must be false for the no-retry drill")

    buyer = urlsplit(buyer_url)
    poolz = urlsplit(poolz_url)
    upstream_buyer_text = values.get("coordinator.buyer_url", "")
    upstream_operator_text = values.get("coordinator.operator_url", "")
    upstream_buyer = urlsplit(validate_loopback_url(upstream_buyer_text, "gateway coordinator buyer URL"))
    upstream_operator = urlsplit(validate_loopback_url(upstream_operator_text, "gateway coordinator operator URL"))
    gateway_port = scalar_int(values, "listen.port")
    if buyer.port != gateway_port:
        raise HarnessError("buyer URL port does not match the running gateway config")
    if upstream_buyer.port != coordinator_config["buyer_port"]:
        raise HarnessError("gateway coordinator.buyer_url does not match isolated coordinator buyer_port")
    if upstream_operator.port != coordinator_config["provider_port"] or poolz.port != upstream_operator.port:
        raise HarnessError("poolz URL and gateway coordinator.operator_url must match isolated provider_port")
    return {
        "path": str(path),
        "sha256": sha256_file(path),
        "listen_bind_address": bind_address,
        "listen_port": gateway_port,
        "coordinator_buyer_url": upstream_buyer_text,
        "coordinator_operator_url": upstream_operator_text,
        "retry_503_enabled": False,
    }


def validate_loopback_url(value: str, label: str, expected_path: str | None = None) -> str:
    parsed = urlsplit(value)
    if parsed.scheme not in {"http", "https"}:
        raise HarnessError(f"{label} must use http or https")
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise HarnessError(f"{label} must not contain credentials, query, or fragment")
    if parsed.hostname not in {"127.0.0.1", "::1"}:
        raise HarnessError(f"{label} must target a numeric loopback address")
    if parsed.port is None:
        raise HarnessError(f"{label} must include an explicit isolated port")
    if expected_path is not None and parsed.path != expected_path:
        raise HarnessError(f"{label} path must be exactly {expected_path}")
    return value


def http_once(
    url: str,
    method: str,
    headers: dict[str, str],
    body: bytes | None,
    timeout_seconds: float,
) -> tuple[int, dict[str, str], bytes]:
    """Issue exactly one request: no redirect handling and no retry loop."""
    parsed = urlsplit(url)
    port = parsed.port or (443 if parsed.scheme == "https" else 80)
    connection_cls = http.client.HTTPSConnection if parsed.scheme == "https" else http.client.HTTPConnection
    connection = connection_cls(parsed.hostname, port, timeout=timeout_seconds)
    path = parsed.path or "/"
    deadline = time.monotonic() + timeout_seconds

    def apply_remaining_timeout() -> None:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError(f"{method} {path} exceeded its total timeout")
        if connection.sock is not None:
            connection.sock.settimeout(remaining)

    try:
        connection.request(method, path, body=body, headers=headers)
        apply_remaining_timeout()
        response = connection.getresponse()
        chunks: list[bytes] = []
        bytes_read = 0
        while True:
            apply_remaining_timeout()
            chunk = response.read1(min(65536, MAX_RESPONSE_BYTES + 1 - bytes_read))
            if not chunk:
                break
            chunks.append(chunk)
            bytes_read += len(chunk)
            if bytes_read > MAX_RESPONSE_BYTES:
                raise HarnessError(f"{method} {path} response exceeded {MAX_RESPONSE_BYTES} bytes")
        payload = b"".join(chunks)
        return response.status, {key.lower(): value for key, value in response.getheaders()}, payload
    finally:
        connection.close()


def fetch_json_once(url: str, token: str, timeout_seconds: float) -> dict[str, Any]:
    status, _, body = http_once(
        url,
        "GET",
        {"Accept": "application/json", "Authorization": f"Bearer {token}"},
        None,
        timeout_seconds,
    )
    if status != 200:
        raise HarnessError(f"GET {urlsplit(url).path} returned HTTP {status}")
    try:
        payload = json.loads(body)
    except json.JSONDecodeError as exc:
        raise HarnessError(f"GET {urlsplit(url).path} returned invalid JSON") from exc
    if not isinstance(payload, dict):
        raise HarnessError(f"GET {urlsplit(url).path} returned a non-object JSON value")
    return payload


def flag_value(argv: list[str], flag: str) -> str:
    values: list[str] = []
    for index, item in enumerate(argv):
        if item == flag:
            if index + 1 >= len(argv):
                raise HarnessError(f"process argv has {flag} without a value")
            values.append(argv[index + 1])
        elif item.startswith(flag + "="):
            values.append(item.split("=", 1)[1])
    if len(values) != 1:
        raise HarnessError(f"process argv must contain exactly one {flag}")
    return values[0]


def pid_listens_on(pid: int, ports: list[int], label: str) -> None:
    proc_ports: set[int] = set()
    proc_fd_dir = Path(f"/proc/{pid}/fd")
    if proc_fd_dir.is_dir():
        socket_inodes: set[str] = set()
        for descriptor in proc_fd_dir.iterdir():
            try:
                target = os.readlink(descriptor)
            except OSError:
                continue
            match = re.fullmatch(r"socket:\[(\d+)\]", target)
            if match:
                socket_inodes.add(match.group(1))
        for table in (Path("/proc/net/tcp"), Path("/proc/net/tcp6")):
            if not table.is_file():
                continue
            for line in table.read_text(encoding="ascii", errors="replace").splitlines()[1:]:
                fields = line.split()
                if len(fields) > 9 and fields[3] == "0A" and fields[9] in socket_inodes:
                    try:
                        proc_ports.add(int(fields[1].rsplit(":", 1)[1], 16))
                    except (IndexError, ValueError):
                        pass
    for port in ports:
        if port in proc_ports:
            continue
        try:
            completed = subprocess.run(
                ["lsof", "-nP", "-a", "-p", str(pid), f"-iTCP:{port}", "-sTCP:LISTEN"],
                check=False,
                capture_output=True,
                text=True,
                timeout=3,
            )
        except (FileNotFoundError, subprocess.TimeoutExpired) as exc:
            raise HarnessError(f"cannot inspect {label} PID {pid} listener ownership") from exc
        if completed.returncode != 0 or f":{port} " not in completed.stdout:
            raise HarnessError(f"{label} PID {pid} is not the TCP listener on port {port}")


def process_evidence(
    label: str,
    pid: int,
    required_flags: dict[str, Path],
    listen_ports: list[int],
    required_log: Path | None = None,
) -> dict[str, Any]:
    if pid <= 1:
        raise HarnessError(f"{label} PID must be greater than 1")
    proc_cmdline = Path(f"/proc/{pid}/cmdline")
    if proc_cmdline.is_file():
        argv = [part.decode("utf-8", "replace") for part in proc_cmdline.read_bytes().split(b"\0") if part]
    else:
        completed = subprocess.run(
            ["ps", "-ww", "-p", str(pid), "-o", "command="],
            check=False,
            capture_output=True,
            text=True,
            timeout=3,
        )
        if completed.returncode != 0 or not completed.stdout.strip():
            raise HarnessError(f"cannot inspect {label} process {pid}")
        argv = shlex.split(completed.stdout.strip())
    bindings: dict[str, str] = {}
    for flag, required_path in required_flags.items():
        actual = Path(flag_value(argv, flag)).expanduser().resolve()
        if actual != required_path:
            raise HarnessError(
                f"{label} PID {pid} {flag} resolves to {actual}, expected {required_path}"
            )
        bindings[flag] = str(actual)
    pid_listens_on(pid, listen_ports, label)
    if required_log is not None:
        log_bound = False
        for descriptor in (1, 2):
            proc_fd = Path(f"/proc/{pid}/fd/{descriptor}")
            try:
                if proc_fd.resolve(strict=True) == required_log:
                    log_bound = True
            except OSError:
                pass
        if not log_bound:
            try:
                completed = subprocess.run(
                    ["lsof", "-Fn", "-a", "-p", str(pid), "-d1,2"],
                    check=False,
                    capture_output=True,
                    text=True,
                    timeout=3,
                )
            except (FileNotFoundError, subprocess.TimeoutExpired) as exc:
                raise HarnessError(f"cannot inspect {label} PID {pid} log ownership") from exc
            for line in completed.stdout.splitlines():
                if line.startswith("n"):
                    try:
                        if Path(line[1:]).resolve() == required_log:
                            log_bound = True
                    except OSError:
                        pass
        if not log_bound:
            raise HarnessError(f"{label} PID {pid} stdout/stderr is not bound to {required_log}")

    executable = ""
    proc_exe = Path(f"/proc/{pid}/exe")
    try:
        executable = str(proc_exe.resolve(strict=True))
    except (FileNotFoundError, OSError):
        if argv:
            candidate = Path(argv[0]).expanduser()
            if candidate.is_file():
                executable = str(candidate.resolve())
    binary_sha256 = ""
    if executable:
        binary_path = Path(executable)
        if binary_path.is_file():
            binary_sha256 = sha256_file(binary_path)
    if not executable or not binary_sha256:
        raise HarnessError(f"cannot bind {label} PID {pid} to a hashable executable")
    return {
        "pid": pid,
        "argv": argv,
        "executable": executable,
        "executable_sha256": binary_sha256,
        "exact_flag_bindings": bindings,
        "listen_ports": listen_ports,
        "required_log_bound": required_log is not None,
    }


def validate_approval_ref(value: str) -> str:
    parsed = urlsplit(value.strip())
    if (
        parsed.scheme != "https"
        or parsed.hostname != "github.com"
        or parsed.path.rstrip("/") != "/Augustas11/macprovider/issues/540"
        or not parsed.fragment.startswith("issuecomment-")
    ):
        raise HarnessError("--operator-approval-ref must be a specific #540 GitHub issue comment URL")
    return value.strip()


def consume_approval_once(
    ledger_path_text: str,
    gate: str,
    approval_ref: str,
    provider_id: str,
    overlay_sha256: str,
) -> str:
    ledger = Path(ledger_path_text).expanduser()
    ledger.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    flags = os.O_RDWR | os.O_CREAT
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        fd = os.open(ledger, flags, 0o600)
    except OSError as exc:
        raise HarnessError(f"cannot open approval ledger safely: {ledger}") from exc
    attempt_material = "\0".join((gate, approval_ref, provider_id, overlay_sha256))
    attempt_key = hashlib.sha256(attempt_material.encode("utf-8")).hexdigest()
    try:
        handle = os.fdopen(fd, "r+", encoding="utf-8", closefd=True)
    except Exception:
        os.close(fd)
        raise
    with handle:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
            mode = os.fstat(handle.fileno()).st_mode
            if not stat.S_ISREG(mode) or mode & 0o077:
                raise HarnessError("approval ledger must be a regular file with mode 0600")
            for line in handle:
                try:
                    record = json.loads(line)
                except json.JSONDecodeError as exc:
                    raise HarnessError("approval ledger contains malformed JSON") from exc
                if isinstance(record, dict) and record.get("attempt_key") == attempt_key:
                    raise HarnessError("this operator approval has already been consumed for the same gate/provider/overlay")
            handle.seek(0, os.SEEK_END)
            handle.write(
                json.dumps(
                    {
                        "attempt_key": attempt_key,
                        "consumed_at": utc_now(),
                        "gate": gate,
                        "operator_approval_ref": approval_ref,
                        "provider_id": provider_id,
                        "overlay_sha256": overlay_sha256,
                    },
                    sort_keys=True,
                    separators=(",", ":"),
                )
                + "\n"
            )
            handle.flush()
            os.fsync(handle.fileno())
    return attempt_key


def read_request_log(db_path: Path, external_ids: list[str]) -> list[dict[str, Any]]:
    if not external_ids:
        return []
    placeholders = ",".join("?" for _ in external_ids)
    uri = f"file:{db_path}?mode=ro"
    try:
        connection = sqlite3.connect(uri, uri=True, timeout=2)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA query_only=ON")
        rows = connection.execute(
            f"""
            SELECT ts_utc, request_id, external_request_id, provider_assigned_id,
                   latency_ms, queue_wait_ms, status, error_code, retried, attempt_n
              FROM request_log
             WHERE external_request_id IN ({placeholders})
             ORDER BY id
            """,
            external_ids,
        ).fetchall()
    except sqlite3.Error as exc:
        raise HarnessError(f"cannot read isolated coordinator request_log: {exc}") from exc
    finally:
        if "connection" in locals():
            connection.close()
    return [dict(row) for row in rows]


def event_time(event: dict[str, Any]) -> float | None:
    for key in ("time", "timestamp", "ts", "_observed_at"):
        parsed = parse_utc(event.get(key))
        if parsed is not None:
            return parsed
    return None


def target_from_sample(sample: dict[str, Any], provider_id: str) -> dict[str, Any] | None:
    payload = sample.get("poolz")
    if not isinstance(payload, dict):
        return None
    pool = payload.get("pool")
    if not isinstance(pool, list):
        return None
    matches = [item for item in pool if isinstance(item, dict) and item.get("provider_id") == provider_id]
    return matches[0] if len(matches) == 1 else None


def add_reason(reasons: list[str], reason: str) -> None:
    if reason not in reasons:
        reasons.append(reason)


def evaluate_capture(capture: dict[str, Any]) -> dict[str, Any]:
    reasons: list[str] = []
    gate = capture.get("gate")
    expected_reason = gate if gate in {"request_threshold", "age_threshold"} else ""
    provider_id = str(capture.get("expected_provider_id", ""))
    expected_pool_size = int(capture.get("expected_pool_size", 1))
    requests = capture.get("requests") if isinstance(capture.get("requests"), list) else []
    samples = capture.get("pool_samples") if isinstance(capture.get("pool_samples"), list) else []
    events = capture.get("events") if isinstance(capture.get("events"), list) else []
    runtime_failures = capture.get("runtime_failures") if isinstance(capture.get("runtime_failures"), list) else []
    for failure in runtime_failures:
        add_reason(reasons, f"runtime failure: {failure}")

    if not requests:
        add_reason(reasons, "no buyer requests were recorded")
    successful_requests = 0
    for request in requests:
        if not isinstance(request, dict):
            add_reason(reasons, "malformed buyer request record")
            continue
        status = request.get("http_status")
        outcome = request.get("outcome")
        detail = str(request.get("response_excerpt", "")) + " " + str(request.get("error", ""))
        if status == 503:
            add_reason(reasons, "buyer observed HTTP 503")
        if "no_provider_available" in detail:
            add_reason(reasons, "buyer observed no_provider_available")
        if status != 200 or outcome != "ok":
            add_reason(reasons, f"buyer request {request.get('request_index', '?')} failed")
        else:
            successful_requests += 1

    identities: list[tuple[str, str, str, str, str]] = []
    pool_states: list[str] = []
    first_provider: dict[str, Any] | None = None
    final_provider: dict[str, Any] | None = None
    for sample in samples:
        if not isinstance(sample, dict) or sample.get("error"):
            add_reason(reasons, "poolz monitoring failed")
            continue
        poolz = sample.get("poolz")
        pool = poolz.get("pool") if isinstance(poolz, dict) else None
        if not isinstance(pool, list) or len(pool) != expected_pool_size:
            add_reason(reasons, "isolated pool size changed")
            continue
        provider = target_from_sample(sample, provider_id)
        if provider is None:
            add_reason(reasons, "dedicated provider disappeared or was duplicated")
            continue
        if first_provider is None:
            first_provider = provider
        final_provider = provider
        safety = provider.get("safety_telemetry")
        compatibility_set = str(safety.get("compatibility_set_id", "")) if isinstance(safety, dict) else ""
        identity = (
            str(provider.get("provider_id", "")),
            str(provider.get("assigned_id", "")),
            str(provider.get("connected_at", "")),
            str(provider.get("binary_version", "")),
            compatibility_set,
        )
        identities.append(identity)
        state = str(provider.get("state", ""))
        pool_states.append(state)
        if state not in ALLOWED_PROVIDER_STATES:
            add_reason(reasons, f"provider entered forbidden pool state {state or '<missing>'}")
        if provider.get("encrypted_leg") is not True:
            add_reason(reasons, "provider lost encrypted_leg=true")
    if not samples:
        add_reason(reasons, "no poolz samples were recorded")
    if not identities or any(identity != identities[0] for identity in identities):
        add_reason(reasons, "provider identity changed (provider_id, assigned_id, connected_at, CLI version, or compatibility set)")
    assigned_id = identities[0][1] if identities else ""
    connected_at = identities[0][2] if identities else ""
    if not assigned_id or not connected_at or not identities or not identities[0][3] or not identities[0][4]:
        add_reason(reasons, "poolz identity evidence is incomplete")
    approved_identity = capture.get("approved_identity") if isinstance(capture.get("approved_identity"), dict) else {}
    if approved_identity and identities:
        if identities[0][3] != str(approved_identity.get("provider_cli_version", "")):
            add_reason(reasons, "provider CLI version did not match approved identity throughout")
        if identities[0][4] != str(approved_identity.get("provider_compatibility_set_id", "")):
            add_reason(reasons, "provider compatibility-set ID did not match approved identity throughout")
    if final_provider is None or final_provider.get("state") != "ready" or final_provider.get("routing_eligible") is not True:
        add_reason(reasons, "provider was not Ready and routing-eligible at postflight")

    relevant_events = [
        event
        for event in events
        if isinstance(event, dict)
        and (
            event.get("provider_id") == provider_id
            or (not event.get("provider_id") and str(event.get("message", "")) in FORBIDDEN_MESSAGES)
        )
    ]
    starts = [event for event in relevant_events if event.get("event") == "aead_rekey" and event.get("reason") == expected_reason]
    commits = [event for event in relevant_events if event.get("event") == "aead_rekey_committed" and event.get("reason") == expected_reason]
    if len(starts) != 1:
        add_reason(reasons, f"expected exactly one {expected_reason} aead_rekey event")
    if len(commits) != 1:
        add_reason(reasons, f"expected exactly one {expected_reason} aead_rekey_committed event")

    for event in relevant_events:
        message = str(event.get("message", ""))
        if event.get("event") in {"aead_rekey_failed", "encrypted_leg_session_closed"}:
            add_reason(reasons, f"forbidden coordinator event {event.get('event')}")
        if message in FORBIDDEN_MESSAGES:
            add_reason(reasons, f"forbidden coordinator close/reconnect evidence: {message}")
        if event.get("event") == "aead_rekey" and event.get("decision") != "rotate_in_band":
            add_reason(reasons, "aead_rekey did not select rotate_in_band")
        if event.get("event") in {"aead_rekey", "aead_rekey_committed"} and event.get("reason") != expected_reason:
            add_reason(reasons, f"unexpected rekey reason {event.get('reason', '<missing>')}")

    old_kid = ""
    new_kid = ""
    rekey_id = ""
    start_time = None
    commit_time = None
    if len(starts) == 1 and len(commits) == 1:
        start = starts[0]
        commit = commits[0]
        old_kid = str(commit.get("old_kid", ""))
        new_kid = str(commit.get("new_kid", ""))
        rekey_id = str(commit.get("rekey_id", ""))
        if start.get("decision") != "rotate_in_band":
            add_reason(reasons, "aead_rekey decision was not rotate_in_band")
        if commit.get("decision") != "continue_same_session":
            add_reason(reasons, "commit decision was not continue_same_session")
        if start.get("assigned_id") != assigned_id or commit.get("assigned_id") != assigned_id:
            add_reason(reasons, "rekey event assigned_id did not match poolz")
        if start.get("request_id") != commit.get("request_id"):
            add_reason(reasons, "rekey start/commit request_id did not correlate")
        if not old_kid or not new_kid or not rekey_id:
            add_reason(reasons, "missing old_kid, new_kid, or rekey_id evidence")
        if old_kid == new_kid:
            add_reason(reasons, "old_kid and new_kid were not cryptographically distinct")
        if start.get("kid") != old_kid:
            add_reason(reasons, "aead_rekey old KID did not match committed old_kid")
        start_time = event_time(start)
        commit_time = event_time(commit)
        if start_time is None or commit_time is None or commit_time < start_time:
            add_reason(reasons, "rekey event timestamps are missing or out of order")

    overlapping_requests = 0
    successful_after_commit = 0
    trigger_request_id = ""
    sentinel_request_id = ""
    admitted_old_epoch_survived = False
    sentinel_busy_before_trigger = False
    bounds = capture.get("bounds") if isinstance(capture.get("bounds"), dict) else {}
    required_post_commit = int(bounds.get("post_commit_successes", 1))
    if start_time is not None and commit_time is not None:
        for request in requests:
            if not isinstance(request, dict):
                continue
            request_start = parse_utc(request.get("started_at"))
            request_end = parse_utc(request.get("ended_at"))
            if request_start is None or request_end is None:
                continue
            if request_start <= commit_time and request_end >= start_time:
                overlapping_requests += 1
            if request_end >= commit_time and request.get("http_status") == 200 and request.get("outcome") == "ok":
                successful_after_commit += 1
        if overlapping_requests == 0:
            add_reason(reasons, "no buyer request overlapped the rekey window")
        if successful_after_commit < required_post_commit:
            add_reason(
                reasons,
                f"only {successful_after_commit} successful buyer request(s) completed after commit; "
                f"required {required_post_commit}",
            )

        request_rows = capture.get("request_log") if isinstance(capture.get("request_log"), list) else []
        rows_by_external: dict[str, list[dict[str, Any]]] = {}
        for row in request_rows:
            if not isinstance(row, dict):
                continue
            rows_by_external.setdefault(str(row.get("external_request_id", "")), []).append(row)
        harness_external_ids = [
            str(request.get("external_request_id", ""))
            for request in requests
            if isinstance(request, dict)
        ]
        if not harness_external_ids or any(not item for item in harness_external_ids):
            add_reason(reasons, "buyer request correlation IDs are missing")
        for external_id in harness_external_ids:
            matched = rows_by_external.get(external_id, [])
            if len(matched) != 1:
                add_reason(reasons, f"buyer request {external_id or '<missing>'} did not map to exactly one request_log row")
                continue
            row = matched[0]
            try:
                single_attempt = int(row.get("retried", -1)) == 0 and int(row.get("attempt_n", -1)) == 0
            except (TypeError, ValueError):
                single_attempt = False
            if row.get("status") != 200 or not single_attempt:
                add_reason(reasons, f"request_log row for {external_id} was not a single successful attempt")
            if str(row.get("provider_assigned_id", "")) != assigned_id:
                add_reason(reasons, f"request_log row for {external_id} used another assigned_id")

        trigger_requests = [request for request in requests if isinstance(request, dict) and request.get("role") == "trigger"]
        sentinel_requests = [request for request in requests if isinstance(request, dict) and request.get("role") == "sentinel"]
        if len(trigger_requests) != 1 or len(sentinel_requests) != 1:
            add_reason(reasons, "capture must contain exactly one trigger and one sentinel request")
        else:
            trigger_external = str(trigger_requests[0].get("external_request_id", ""))
            sentinel_external = str(sentinel_requests[0].get("external_request_id", ""))
            trigger_http_start = parse_utc(trigger_requests[0].get("started_at"))
            trigger_http_end = parse_utc(trigger_requests[0].get("ended_at"))
            sentinel_http_start = parse_utc(sentinel_requests[0].get("started_at"))
            if (
                trigger_http_start is None
                or trigger_http_end is None
                or trigger_http_start > start_time
                or trigger_http_end < commit_time
            ):
                add_reason(reasons, "trigger buyer request did not remain outstanding across the rekey commit")
            for sample in samples:
                if not isinstance(sample, dict):
                    continue
                observed = parse_utc(sample.get("observed_at"))
                provider = target_from_sample(sample, provider_id)
                if (
                    observed is not None
                    and sentinel_http_start is not None
                    and trigger_http_start is not None
                    and sentinel_http_start <= observed <= trigger_http_start
                    and provider is not None
                    and provider.get("state") == "busy"
                ):
                    sentinel_busy_before_trigger = True
                    break
            if not sentinel_busy_before_trigger:
                add_reason(reasons, "provider Busy was not recorded after sentinel admission and before trigger dispatch")
            trigger_rows = rows_by_external.get(trigger_external, [])
            sentinel_rows = rows_by_external.get(sentinel_external, [])
            if len(trigger_rows) == 1:
                trigger_request_id = str(trigger_rows[0].get("request_id", ""))
                if len(starts) == 1 and trigger_request_id != str(starts[0].get("request_id", "")):
                    add_reason(reasons, "rekey event request_id did not map to the harness trigger request")
            if len(sentinel_rows) == 1:
                sentinel = sentinel_rows[0]
                sentinel_request_id = str(sentinel.get("request_id", ""))
                sentinel_end = parse_utc(sentinel.get("ts_utc"))
                try:
                    sentinel_start = sentinel_end - float(sentinel.get("latency_ms", 0)) / 1000.0 if sentinel_end else None
                except (TypeError, ValueError):
                    sentinel_start = None
                if (
                    sentinel_start is not None
                    and sentinel_end is not None
                    and sentinel_start <= start_time <= sentinel_end
                    and sentinel.get("status") == 200
                    and sentinel_request_id != trigger_request_id
                ):
                    admitted_old_epoch_survived = True
                else:
                    add_reason(reasons, "sentinel did not prove admitted old-epoch work survived the rekey barrier")

    health_initial = capture.get("health_initial")
    health_final = capture.get("health_final")
    coordinator_version = ""
    if isinstance(health_initial, dict):
        coordinator_version = str(health_initial.get("version", ""))
    if not coordinator_version:
        add_reason(reasons, "coordinator version evidence is missing")
    if not isinstance(health_final, dict) or health_final.get("status") != "ok":
        add_reason(reasons, "coordinator postflight health is not ok")
    elif int(health_final.get("pool_degraded", 0)) or int(health_final.get("pool_draining", 0)) or int(health_final.get("pool_unavailable", 0)):
        add_reason(reasons, "coordinator postflight reports a non-serving provider state")
    cli_version = str(first_provider.get("binary_version", "")) if first_provider else ""
    safety_telemetry = first_provider.get("safety_telemetry") if first_provider else None
    compatibility_set_id = (
        str(safety_telemetry.get("compatibility_set_id", ""))
        if isinstance(safety_telemetry, dict)
        else ""
    )
    if not cli_version:
        add_reason(reasons, "provider CLI version evidence is missing")
    if not compatibility_set_id:
        add_reason(reasons, "provider compatibility-set identity evidence is missing")

    request_statuses = [request.get("http_status") for request in requests if isinstance(request, dict)]
    verdict = "PASS" if not reasons else "FAIL"
    return {
        "verdict": verdict,
        "gate": gate,
        "reasons": reasons,
        "metrics": {
            "requests_total": len(requests),
            "requests_successful": successful_requests,
            "buyer_success_percent": round(100.0 * successful_requests / len(requests), 3) if requests else 0.0,
            "http_statuses": request_statuses,
            "rekey_window_overlapping_requests": overlapping_requests,
            "successful_requests_completed_after_commit": successful_after_commit,
            "admitted_old_epoch_survived": admitted_old_epoch_survived,
            "sentinel_busy_before_trigger": sentinel_busy_before_trigger,
            "pool_samples": len(samples),
            "pool_states_observed": sorted(set(pool_states)),
        },
        "identity": {
            "provider_id": provider_id,
            "assigned_id": assigned_id,
            "connected_at": connected_at,
            "provider_cli_version": cli_version,
            "provider_compatibility_set_id": compatibility_set_id,
            "coordinator_version": coordinator_version,
        },
        "rekey": {
            "reason": expected_reason,
            "rekey_id": rekey_id,
            "old_kid": old_kid,
            "new_kid": new_kid,
            "event_types": [event.get("event") for event in relevant_events if event.get("event")],
            "trigger_request_id": trigger_request_id,
            "sentinel_request_id": sentinel_request_id,
        },
        "assertions": {
            "no_retry": True,
            "all_buyer_http_200": bool(requests) and successful_requests == len(requests),
            "zero_no_provider_available": not any("no_provider_available" in reason for reason in reasons),
            "same_provider_and_assigned_id": bool(identities) and all(identity == identities[0] for identity in identities),
            "same_connection": bool(identities) and all(identity[2] == identities[0][2] for identity in identities),
            "fresh_kid": bool(old_kid and new_kid and old_kid != new_kid),
            "ready_or_busy_throughout": bool(pool_states) and all(state in ALLOWED_PROVIDER_STATES for state in pool_states),
            "trigger_bound_to_rekey": bool(trigger_request_id and len(starts) == 1 and trigger_request_id == starts[0].get("request_id")),
            "admitted_old_epoch_survived": admitted_old_epoch_survived,
        },
    }


def issue_markdown(capture: dict[str, Any], result: dict[str, Any]) -> str:
    gate_label = "G-req" if result.get("gate") == "request_threshold" else "G-age"
    identity = result["identity"]
    rekey = result["rekey"]
    metrics = result["metrics"]
    reason_text = "none" if not result["reasons"] else "; ".join(result["reasons"])
    return f"""# Issue #540 one-shot AEAD rekey evidence

> Harness `{HARNESS_VERSION}`. This artifact is evidence only; it does not close #540 or authorize Pearl changes.

| Gate | Environment | Result | Buyer success | Rekey overlap | Pool states |
|---|---|---:|---:|---:|---|
| {gate_label} | isolated production-equivalent coordinator + dedicated provider | **{result['verdict']}** | {metrics['requests_successful']}/{metrics['requests_total']} ({metrics['buyer_success_percent']}%) | {metrics['rekey_window_overlapping_requests']} request(s); admitted-old-epoch-survived={str(metrics['admitted_old_epoch_survived']).lower()} | {', '.join(metrics['pool_states_observed']) or 'missing'} |

| Evidence | Value |
|---|---|
| Harness version | `{HARNESS_VERSION}` |
| Coordinator version | `{identity['coordinator_version']}` |
| Coordinator SHA-256 (approved/observed) | `{capture.get('approved_identity', {}).get('coordinator_sha256', '')}` / `{capture.get('coordinator_process', {}).get('executable_sha256', '')}` |
| Gateway SHA-256 (approved/observed) | `{capture.get('approved_identity', {}).get('gateway_sha256', '')}` / `{capture.get('gateway_process', {}).get('executable_sha256', '')}` |
| Provider CLI version (approved/observed) | `{capture.get('approved_identity', {}).get('provider_cli_version', '')}` / `{identity['provider_cli_version']}` |
| Provider compatibility set (approved/observed) | `{capture.get('approved_identity', {}).get('provider_compatibility_set_id', '')}` / `{identity['provider_compatibility_set_id']}` |
| Provider ID | `{identity['provider_id']}` |
| Assigned ID | `{identity['assigned_id']}` |
| Connection admitted at | `{identity['connected_at']}` |
| Rekey reason | `{rekey['reason']}` |
| Rekey ID | `{rekey['rekey_id']}` |
| Old KID | `{rekey['old_kid']}` |
| New KID | `{rekey['new_kid']}` |
| Events | `{', '.join(rekey['event_types'])}` |
| Trigger request ID | `{rekey['trigger_request_id']}` |
| Old-epoch sentinel request ID | `{rekey['sentinel_request_id']}` |
| HTTP statuses | `{json.dumps(metrics['http_statuses'], separators=(',', ':'))}` |
| Failure reasons | {reason_text} |
| Operator approval | `{capture.get('operator_approval_ref', 'dry-run fixture')}` |

Safety: fixed request/time/token caps; first-error stop; no redirect or HTTP retry; no canary timer or enable-gate mutation; no Pearl threshold mutation.

Protocol boundary: this operational artifact proves identity, KID, event, buyer, and drain continuity. Non-secret sequence-0/sequence-1 and bidirectional AEAD correctness remain covered by the named hermetic Go and Swift tests in the runbook; this artifact is not a second protocol proof.
"""


def sanitized_capture(capture: dict[str, Any]) -> dict[str, Any]:
    def process_summary(value: Any) -> dict[str, Any]:
        if not isinstance(value, dict):
            return {}
        return {
            "pid": value.get("pid"),
            "executable_name": Path(str(value.get("executable", ""))).name,
            "executable_sha256": value.get("executable_sha256", ""),
            "exact_flag_bindings_verified": bool(value.get("exact_flag_bindings")),
            "listen_ports": value.get("listen_ports", []),
            "required_log_bound": bool(value.get("required_log_bound")),
        }

    config = capture.get("config") if isinstance(capture.get("config"), dict) else {}
    gateway = capture.get("gateway_config") if isinstance(capture.get("gateway_config"), dict) else {}
    requests = []
    for request in capture.get("requests", []):
        if not isinstance(request, dict):
            continue
        requests.append(
            {
                key: request.get(key)
                for key in (
                    "request_index",
                    "role",
                    "external_request_id",
                    "started_at",
                    "ended_at",
                    "http_status",
                    "outcome",
                    "error",
                )
                if key in request
            }
        )
    pool_samples = []
    provider_id = str(capture.get("expected_provider_id", ""))
    for sample in capture.get("pool_samples", []):
        if not isinstance(sample, dict):
            continue
        provider = target_from_sample(sample, provider_id)
        provider_evidence = None
        if provider:
            provider_evidence = {
                key: provider.get(key)
                for key in (
                    "provider_id",
                    "assigned_id",
                    "connected_at",
                    "binary_version",
                    "model_id",
                    "state",
                    "routing_eligible",
                    "encrypted_leg",
                )
            }
            safety = provider.get("safety_telemetry")
            provider_evidence["compatibility_set_id"] = (
                safety.get("compatibility_set_id", "") if isinstance(safety, dict) else ""
            )
        pool_samples.append(
            {
                "observed_at": sample.get("observed_at"),
                "error": sample.get("error", ""),
                "pool_size": len(sample.get("poolz", {}).get("pool", []))
                if isinstance(sample.get("poolz"), dict) and isinstance(sample.get("poolz", {}).get("pool"), list)
                else None,
                "provider": provider_evidence,
            }
        )
    event_keys = {
        "time",
        "timestamp",
        "ts",
        "_observed_at",
        "event",
        "message",
        "provider_id",
        "assigned_id",
        "request_id",
        "kid",
        "old_kid",
        "new_kid",
        "rekey_id",
        "reason",
        "decision",
    }
    return {
        "source": capture.get("source", "fixture"),
        "gate": capture.get("gate"),
        "started_at": capture.get("started_at"),
        "ended_at": capture.get("ended_at"),
        "expected_provider_id": provider_id,
        "expected_pool_size": capture.get("expected_pool_size"),
        "operator_approval_ref": capture.get("operator_approval_ref"),
        "approval_attempt_key": capture.get("approval_attempt_key"),
        "approved_identity": capture.get("approved_identity", {}),
        "bounds": capture.get("bounds", {}),
        "config": {
            key: config.get(key)
            for key in (
                "base_sha256",
                "overlay_sha256",
                "listen_bind_address",
                "require_gateway_context",
                "routing_max_retries",
                "require_encrypted_leg",
                "encrypted_leg_rekey_after_requests",
                "encrypted_leg_rekey_after_seconds",
                "buyer_port",
                "provider_port",
            )
        },
        "gateway_config": {
            key: gateway.get(key)
            for key in ("sha256", "listen_bind_address", "listen_port", "retry_503_enabled")
        },
        "coordinator_process": process_summary(capture.get("coordinator_process")),
        "gateway_process": process_summary(capture.get("gateway_process")),
        "health_initial": {
            key: capture.get("health_initial", {}).get(key)
            for key in ("status", "version", "pool_ready", "pool_busy", "pool_degraded", "pool_draining", "pool_unavailable")
        }
        if isinstance(capture.get("health_initial"), dict)
        else {},
        "health_final": {
            key: capture.get("health_final", {}).get(key)
            for key in ("status", "version", "pool_ready", "pool_busy", "pool_degraded", "pool_draining", "pool_unavailable")
        }
        if isinstance(capture.get("health_final"), dict)
        else {},
        "requests": requests,
        "request_log": capture.get("request_log", []),
        "pool_samples": pool_samples,
        "events": [
            {key: event.get(key) for key in event_keys if key in event}
            for event in capture.get("events", [])
            if isinstance(event, dict)
        ],
        "runtime_failures": capture.get("runtime_failures", []),
    }


def reserve_output_dir(output_dir_text: str) -> Path:
    output_dir = Path(output_dir_text).expanduser().resolve()
    if output_dir.exists():
        raise HarnessError(f"output directory already exists: {output_dir}")
    output_dir.mkdir(parents=True, mode=0o700)
    return output_dir


def write_evidence(output_dir: Path, capture: dict[str, Any], result: dict[str, Any]) -> Path:
    if not output_dir.is_dir() or any(output_dir.iterdir()):
        raise HarnessError(f"reserved output directory is missing or nonempty: {output_dir}")
    evidence = {
        "schema_version": 2,
        "harness_version": HARNESS_VERSION,
        "capture": sanitized_capture(capture),
        "result": result,
    }
    (output_dir / "evidence.json").write_text(
        json.dumps(evidence, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    (output_dir / "evidence.md").write_text(issue_markdown(capture, result), encoding="utf-8")
    os.chmod(output_dir / "evidence.json", 0o600)
    os.chmod(output_dir / "evidence.md", 0o600)
    return output_dir


class LiveState:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.dispatch_stop = threading.Event()
        self.watch_stop = threading.Event()
        self.requests: list[dict[str, Any]] = []
        self.pool_samples: list[dict[str, Any]] = []
        self.events: list[dict[str, Any]] = []
        self.fatal_errors: list[str] = []
        self.next_request = 0
        self.commit_observed = False
        self.commit_event = threading.Event()

    def fail(self, message: str) -> None:
        with self.lock:
            if message not in self.fatal_errors:
                self.fatal_errors.append(message)
        self.dispatch_stop.set()


def watch_log(path: Path, start_offset: int, provider_id: str, state: LiveState) -> None:
    with path.open("rb") as handle:
        handle.seek(start_offset)
        while not state.watch_stop.is_set():
            raw = handle.readline()
            if not raw:
                time.sleep(0.02)
                continue
            try:
                event = json.loads(raw.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                continue
            if not isinstance(event, dict):
                continue
            event_name = event.get("event")
            message = str(event.get("message", ""))
            if event.get("provider_id") != provider_id and not (
                not event.get("provider_id") and message in FORBIDDEN_MESSAGES
            ):
                continue
            if event_name not in REKEY_EVENTS and message not in FORBIDDEN_MESSAGES:
                continue
            event = dict(event)
            event["_observed_at"] = utc_now()
            with state.lock:
                state.events.append(event)
                if event_name == "aead_rekey_committed":
                    state.commit_observed = True
                    state.commit_event.set()
            if event_name in {"aead_rekey_failed", "encrypted_leg_session_closed"}:
                state.fail(f"coordinator emitted {event_name}")
            elif message in FORBIDDEN_MESSAGES:
                state.fail(f"coordinator emitted {message}")
            elif event_name == "aead_rekey" and event.get("decision") != "rotate_in_band":
                state.fail("coordinator selected a non-in-band rekey decision")


def watch_pool(
    poolz_url: str,
    token: str,
    provider_id: str,
    expected_pool_size: int,
    interval_seconds: float,
    state: LiveState,
) -> None:
    while not state.watch_stop.is_set():
        sample: dict[str, Any] = {"observed_at": utc_now()}
        try:
            payload = fetch_json_once(poolz_url, token, 3)
            sample["poolz"] = payload
            pool = payload.get("pool")
            provider = None
            if isinstance(pool, list):
                matches = [item for item in pool if isinstance(item, dict) and item.get("provider_id") == provider_id]
                if len(matches) == 1:
                    provider = matches[0]
            if not isinstance(pool, list) or len(pool) != expected_pool_size:
                state.fail("isolated pool size changed")
            elif provider is None:
                state.fail("dedicated provider disappeared or was duplicated")
            elif provider.get("state") not in ALLOWED_PROVIDER_STATES:
                state.fail(f"provider entered {provider.get('state', '<missing>')}")
            elif provider.get("encrypted_leg") is not True:
                state.fail("provider lost encrypted_leg=true")
        except Exception as exc:  # fail-closed monitor boundary
            sample["error"] = str(exc)
            state.fail(f"poolz monitor failed: {exc}")
        with state.lock:
            state.pool_samples.append(sample)
        state.watch_stop.wait(interval_seconds)


def issue_buyer_once(
    role: str,
    args: argparse.Namespace,
    token: str,
    deadline_monotonic: float,
    state: LiveState,
) -> None:
    if state.dispatch_stop.is_set() or time.monotonic() >= deadline_monotonic:
        state.fail("one-shot wall-clock cap reached before completion")
        return
    with state.lock:
        if state.next_request >= args.max_requests:
            state.fail("one-shot request cap reached before completion")
            return
        request_index = state.next_request
        state.next_request += 1
    external_request_id = f"rekey-oneshot-{os.getpid()}-{request_index}"
    record: dict[str, Any] = {
        "request_index": request_index,
        "role": role,
        "external_request_id": external_request_id,
        "started_at": utc_now(),
        "http_status": 0,
        "outcome": "transport_error",
    }
    sentinel = role == "sentinel"
    max_tokens = args.sentinel_max_tokens if sentinel else args.max_tokens
    instruction = (
        f"Produce exactly {max_tokens} short numbered words, without stopping early. "
        f"This is bounded sentinel request {request_index}."
        if sentinel
        else f"Reply briefly with the word REKEY and request number {request_index}."
    )
    body = json.dumps(
        {
            "model": args.model,
            "messages": [{"role": "user", "content": instruction}],
            "stream": False,
            "max_tokens": max_tokens,
        },
        separators=(",", ":"),
    ).encode("utf-8")
    try:
        remaining_run_seconds = deadline_monotonic - time.monotonic()
        if remaining_run_seconds <= 0:
            raise TimeoutError("one-shot wall-clock cap reached before buyer dispatch")
        status, _, response_body = http_once(
            args.buyer_url,
            "POST",
            {
                "Accept": "application/json",
                "Content-Type": "application/json",
                "Authorization": f"Bearer {token}",
                "X-Request-Id": external_request_id,
            },
            body,
            min(args.request_timeout_seconds, remaining_run_seconds),
        )
        record["http_status"] = status
        excerpt = response_body[:512].decode("utf-8", "replace")
        record["response_excerpt"] = excerpt
        if status != 200:
            record["outcome"] = "http_error"
            state.fail(f"buyer request {request_index} returned HTTP {status}")
        else:
            try:
                decoded = json.loads(response_body)
            except json.JSONDecodeError as exc:
                raise HarnessError("buyer returned invalid JSON") from exc
            if not isinstance(decoded, dict) or not isinstance(decoded.get("choices"), list) or not decoded["choices"]:
                raise HarnessError("buyer response lacked a non-empty choices array")
            record["outcome"] = "ok"
    except Exception as exc:  # one attempt only
        record["error"] = str(exc)
        state.fail(f"buyer request {request_index} failed: {exc}")
    finally:
        record["ended_at"] = utc_now()
        with state.lock:
            state.requests.append(record)


def wait_for_provider_busy(state: LiveState, deadline_monotonic: float) -> bool:
    while time.monotonic() < deadline_monotonic and not state.dispatch_stop.is_set():
        with state.lock:
            for sample in reversed(state.pool_samples):
                provider = target_from_sample(sample, str(sample.get("expected_provider_id", "")))
                if provider and provider.get("state") == "busy":
                    return True
            samples = list(state.pool_samples)
        for sample in reversed(samples):
            poolz = sample.get("poolz") if isinstance(sample, dict) else None
            pool = poolz.get("pool") if isinstance(poolz, dict) else None
            if isinstance(pool, list) and any(
                isinstance(item, dict) and item.get("state") == "busy" for item in pool
            ):
                return True
        time.sleep(0.02)
    state.fail("sentinel request was not observed Busy before the trigger")
    return False


def run_live(args: argparse.Namespace) -> tuple[dict[str, Any], dict[str, Any]]:
    approval_ref = validate_approval_ref(args.operator_approval_ref or "")
    buyer_token = os.environ.get(BUYER_TOKEN_ENV, "")
    operator_token = os.environ.get(OPERATOR_TOKEN_ENV, "")
    if not buyer_token or not operator_token:
        raise HarnessError(f"live mode requires {BUYER_TOKEN_ENV} and {OPERATOR_TOKEN_ENV}")

    base_path = regular_file(args.base_config, "base config")
    overlay_path = regular_file(args.config_overlay, "config overlay")
    gateway_config_path = regular_file(args.gateway_config, "gateway config")
    log_path = regular_file(args.coordinator_log, "coordinator log")
    db_path = regular_file(args.coordinator_db, "coordinator database")
    config_evidence = validate_config(base_path, overlay_path, args.gate, args.max_requests, args.max_seconds)
    if db_path != Path(config_evidence["db_path"]):
        raise HarnessError("--coordinator-db must exactly match isolated storage.db_path")
    if urlsplit(args.poolz_url).port != config_evidence["provider_port"]:
        raise HarnessError("poolz URL port must match isolated coordinator provider_port")
    gateway_config = validate_gateway_config(gateway_config_path, args.buyer_url, args.poolz_url, config_evidence)
    if args.coordinator_pid == args.gateway_pid:
        raise HarnessError("coordinator and gateway PIDs must be distinct")
    request_threshold = config_evidence["encrypted_leg_rekey_after_requests"]
    if args.gate == "request_threshold":
        required_requests = request_threshold + 1 + args.post_commit_successes
        if required_requests > args.max_requests:
            raise HarnessError(f"request gate needs at least {required_requests} requests under the configured cap")
        if request_threshold <= 1 + args.post_commit_successes:
            raise HarnessError("request threshold is too low to avoid a second rekey after post-commit proof")
    elif 2 + args.post_commit_successes > args.max_requests:
        raise HarnessError("age gate request cap is too low for sentinel, trigger, and post-commit proof")

    coordinator_process = process_evidence(
        "coordinator",
        args.coordinator_pid,
        {"--config": base_path, "--config-overlay": overlay_path},
        [config_evidence["buyer_port"], config_evidence["provider_port"]],
        log_path,
    )
    gateway_process = process_evidence(
        "gateway",
        args.gateway_pid,
        {"--config": gateway_config_path},
        [gateway_config["listen_port"]],
    )
    if coordinator_process["executable_sha256"] != args.expected_coordinator_sha256:
        raise HarnessError("running coordinator SHA-256 does not match the operator-approved digest")
    if gateway_process["executable_sha256"] != args.expected_gateway_sha256:
        raise HarnessError("running gateway SHA-256 does not match the operator-approved digest")
    health_initial = fetch_json_once(args.health_url, operator_token, 3)
    if health_initial.get("status") != "ok" or not health_initial.get("version"):
        raise HarnessError("isolated coordinator preflight health/version is not ok")
    if any(int(health_initial.get(key, 0)) for key in ("pool_degraded", "pool_draining", "pool_unavailable")):
        raise HarnessError("isolated coordinator preflight reports a non-serving provider state")
    initial_pool = fetch_json_once(args.poolz_url, operator_token, 3)
    initial_sample = {"observed_at": utc_now(), "poolz": initial_pool}
    initial_provider = target_from_sample(initial_sample, args.provider_id)
    if initial_provider is None:
        raise HarnessError("preflight did not find exactly one dedicated provider")
    if len(initial_pool.get("pool", [])) != args.expected_pool_size:
        raise HarnessError("preflight isolated pool size mismatch")
    if initial_provider.get("state") != "ready" or initial_provider.get("routing_eligible") is not True:
        raise HarnessError("dedicated provider must be Ready and routing-eligible before the one-shot")
    if initial_provider.get("encrypted_leg") is not True:
        raise HarnessError("dedicated provider must have encrypted_leg=true")
    if str(initial_provider.get("model_id", "")) != args.model:
        raise HarnessError("--model must exactly match the dedicated provider pool identity")
    provider_safety = initial_provider.get("safety_telemetry")
    observed_compatibility_set = (
        str(provider_safety.get("compatibility_set_id", ""))
        if isinstance(provider_safety, dict)
        else ""
    )
    if str(initial_provider.get("binary_version", "")) != args.expected_provider_cli_version:
        raise HarnessError("provider CLI version does not match the operator-approved identity")
    if observed_compatibility_set != args.expected_provider_compatibility_set_id:
        raise HarnessError("provider compatibility-set ID does not match the operator-approved identity")

    age_deadline_utc = None
    if args.gate == "age_threshold":
        connected_at = parse_utc(initial_provider.get("connected_at"))
        if connected_at is None:
            raise HarnessError("provider connected_at is required for the age gate")
        age_deadline_utc = connected_at + config_evidence["encrypted_leg_rekey_after_seconds"]
        if age_deadline_utc - time.time() <= args.sentinel_lead_seconds + 1:
            raise HarnessError("provider is too close to the age threshold; restart the isolated coordinator/provider")

    state = LiveState()
    state.pool_samples.append(initial_sample)
    log_offset = log_path.stat().st_size
    log_thread = threading.Thread(
        target=watch_log,
        args=(log_path, log_offset, args.provider_id, state),
        name="rekey-log-watcher",
        daemon=True,
    )
    pool_thread = threading.Thread(
        target=watch_pool,
        args=(
            args.poolz_url,
            operator_token,
            args.provider_id,
            args.expected_pool_size,
            args.pool_interval_ms / 1000.0,
            state,
        ),
        name="rekey-pool-watcher",
        daemon=True,
    )
    log_thread.start()
    pool_thread.start()

    deadline = time.monotonic() + args.max_seconds
    approval_attempt_key = consume_approval_once(
        args.attempt_ledger,
        args.gate,
        approval_ref,
        args.provider_id,
        config_evidence["overlay_sha256"],
    )
    if args.gate == "request_threshold":
        for _ in range(request_threshold - 1):
            issue_buyer_once("warmup", args, buyer_token, deadline, state)
            if state.dispatch_stop.is_set():
                break
    else:
        target_start = float(age_deadline_utc) - args.sentinel_lead_seconds
        remaining = target_start - time.time()
        if remaining > 0:
            state.dispatch_stop.wait(min(remaining, max(0.0, deadline - time.monotonic())))

    sentinel_thread = threading.Thread(
        target=issue_buyer_once,
        args=("sentinel", args, buyer_token, deadline, state),
        name="rekey-buyer-sentinel",
    )
    sentinel_thread.start()
    busy_deadline = deadline
    if age_deadline_utc is not None:
        busy_deadline = min(busy_deadline, time.monotonic() + max(0.0, age_deadline_utc - time.time()))
    wait_for_provider_busy(state, busy_deadline)
    if not sentinel_thread.is_alive():
        state.fail("sentinel completed before the rekey trigger was dispatched")
    if age_deadline_utc is not None:
        remaining = age_deadline_utc - time.time()
        if remaining > 0:
            state.dispatch_stop.wait(min(remaining, max(0.0, deadline - time.monotonic())))
        if not sentinel_thread.is_alive():
            state.fail("sentinel completed before the age threshold became due")

    trigger_thread = threading.Thread(
        target=issue_buyer_once,
        args=("trigger", args, buyer_token, deadline, state),
        name="rekey-buyer-trigger",
    )
    if not state.dispatch_stop.is_set():
        trigger_thread.start()
        sentinel_thread.join(max(0.0, deadline - time.monotonic()))
        trigger_thread.join(max(0.0, deadline - time.monotonic()))
        if sentinel_thread.is_alive() or trigger_thread.is_alive():
            state.fail("sentinel or trigger exceeded the one-shot wall-clock cap")
    else:
        sentinel_thread.join(max(0.0, deadline - time.monotonic()))

    if not state.dispatch_stop.is_set() and not state.commit_event.wait(min(2.0, max(0.0, deadline - time.monotonic()))):
        state.fail("aead_rekey_committed was not observed after the trigger")
    if not state.dispatch_stop.is_set():
        for _ in range(args.post_commit_successes):
            issue_buyer_once("post_commit", args, buyer_token, deadline, state)
            if state.dispatch_stop.is_set():
                break

    time.sleep(0.1)
    state.watch_stop.set()
    log_thread.join(2)
    pool_thread.join(2)

    health_final: dict[str, Any] | None = None
    final_sample: dict[str, Any] = {"observed_at": utc_now()}
    try:
        final_sample["poolz"] = fetch_json_once(args.poolz_url, operator_token, 3)
        health_final = fetch_json_once(args.health_url, operator_token, 3)
    except Exception as exc:
        final_sample["error"] = str(exc)
        state.fail(f"postflight failed: {exc}")
    state.pool_samples.append(final_sample)

    with state.lock:
        external_ids = [str(item.get("external_request_id", "")) for item in state.requests]
    try:
        request_log = read_request_log(db_path, external_ids)
    except HarnessError as exc:
        state.fail(str(exc))
        request_log = []

    with state.lock:
        capture = {
            "source": "live",
            "gate": args.gate,
            "started_at": initial_sample["observed_at"],
            "ended_at": utc_now(),
            "expected_provider_id": args.provider_id,
            "expected_pool_size": args.expected_pool_size,
            "operator_approval_ref": approval_ref,
            "approval_attempt_key": approval_attempt_key,
            "approved_identity": {
                "coordinator_sha256": args.expected_coordinator_sha256,
                "gateway_sha256": args.expected_gateway_sha256,
                "provider_cli_version": args.expected_provider_cli_version,
                "provider_compatibility_set_id": args.expected_provider_compatibility_set_id,
            },
            "bounds": {
                "max_requests": args.max_requests,
                "max_seconds": args.max_seconds,
                "concurrency": args.concurrency,
                "max_tokens_per_request": args.max_tokens,
                "sentinel_max_tokens": args.sentinel_max_tokens,
                "request_timeout_seconds": args.request_timeout_seconds,
                "post_commit_successes": args.post_commit_successes,
                "automatic_retries": 0,
            },
            "config": config_evidence,
            "gateway_config": gateway_config,
            "coordinator_process": coordinator_process,
            "gateway_process": gateway_process,
            "health_initial": health_initial,
            "health_final": health_final,
            "requests": sorted(state.requests, key=lambda item: item["request_index"]),
            "request_log": request_log,
            "pool_samples": list(state.pool_samples),
            "events": list(state.events),
            "runtime_failures": list(state.fatal_errors),
        }
    result = evaluate_capture(capture)
    return capture, result


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gate", required=True, choices=("request_threshold", "age_threshold"))
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--dry-run-fixture", help="evaluate a hermetic capture instead of making network calls")
    parser.add_argument("--operator-approval-ref")
    parser.add_argument("--buyer-url")
    parser.add_argument("--poolz-url")
    parser.add_argument("--health-url")
    parser.add_argument("--provider-id")
    parser.add_argument("--model")
    parser.add_argument("--base-config")
    parser.add_argument("--config-overlay")
    parser.add_argument("--gateway-config")
    parser.add_argument("--coordinator-log")
    parser.add_argument("--coordinator-db")
    parser.add_argument("--coordinator-pid", type=int)
    parser.add_argument("--gateway-pid", type=int)
    parser.add_argument("--attempt-ledger")
    parser.add_argument("--expected-coordinator-sha256")
    parser.add_argument("--expected-gateway-sha256")
    parser.add_argument("--expected-provider-cli-version")
    parser.add_argument("--expected-provider-compatibility-set-id")
    parser.add_argument("--expected-pool-size", type=int, default=1)
    parser.add_argument("--max-requests", type=int, default=20)
    parser.add_argument("--max-seconds", type=int, default=60)
    parser.add_argument("--concurrency", type=int, default=2)
    parser.add_argument("--max-tokens", type=int, default=16)
    parser.add_argument("--sentinel-max-tokens", type=int, default=128)
    parser.add_argument("--sentinel-lead-seconds", type=float, default=2.0)
    parser.add_argument("--request-timeout-seconds", type=int, default=30)
    parser.add_argument("--pool-interval-ms", type=int, default=100)
    parser.add_argument("--post-commit-successes", type=int, default=3)
    return parser


def validate_args(args: argparse.Namespace) -> None:
    if not 1 <= args.max_requests <= MAX_REQUESTS:
        raise HarnessError(f"--max-requests must be 1..{MAX_REQUESTS}")
    if not 1 <= args.max_seconds <= MAX_SECONDS:
        raise HarnessError(f"--max-seconds must be 1..{MAX_SECONDS}")
    if not 1 <= args.concurrency <= MAX_CONCURRENCY:
        raise HarnessError(f"--concurrency must be 1..{MAX_CONCURRENCY}")
    if not 1 <= args.max_tokens <= MAX_TOKENS:
        raise HarnessError(f"--max-tokens must be 1..{MAX_TOKENS}")
    if not 1 <= args.sentinel_max_tokens <= MAX_SENTINEL_TOKENS:
        raise HarnessError(f"--sentinel-max-tokens must be 1..{MAX_SENTINEL_TOKENS}")
    if not 0.5 <= args.sentinel_lead_seconds <= 10:
        raise HarnessError("--sentinel-lead-seconds must be 0.5..10")
    if not 1 <= args.request_timeout_seconds <= min(120, args.max_seconds):
        raise HarnessError("--request-timeout-seconds must be 1..min(120, --max-seconds)")
    if not 1 <= args.post_commit_successes < args.max_requests:
        raise HarnessError("--post-commit-successes must be positive and below --max-requests")
    if not 100 <= args.pool_interval_ms <= 1000:
        raise HarnessError("--pool-interval-ms must be 100..1000")
    if args.expected_pool_size != 1:
        raise HarnessError("this #540 harness requires exactly one dedicated provider")
    if args.concurrency != 2:
        raise HarnessError("this #540 harness fixes concurrency at 2 for sentinel + trigger proof")
    if args.dry_run_fixture:
        return
    required = (
        "buyer_url",
        "poolz_url",
        "provider_id",
        "model",
        "base_config",
        "config_overlay",
        "gateway_config",
        "coordinator_log",
        "coordinator_db",
        "coordinator_pid",
        "gateway_pid",
        "attempt_ledger",
        "operator_approval_ref",
        "expected_coordinator_sha256",
        "expected_gateway_sha256",
        "expected_provider_cli_version",
        "expected_provider_compatibility_set_id",
    )
    missing = [name for name in required if not getattr(args, name)]
    if missing:
        raise HarnessError("live mode missing: " + ", ".join("--" + name.replace("_", "-") for name in missing))
    if len(args.provider_id) > 256 or len(args.model) > 256:
        raise HarnessError("--provider-id and --model must be at most 256 characters")
    args.expected_coordinator_sha256 = normalized_sha256(
        args.expected_coordinator_sha256, "--expected-coordinator-sha256"
    )
    args.expected_gateway_sha256 = normalized_sha256(
        args.expected_gateway_sha256, "--expected-gateway-sha256"
    )
    if len(args.expected_provider_cli_version) > 64 or len(args.expected_provider_compatibility_set_id) > 256:
        raise HarnessError("approved provider version/set identity is too long")
    if args.operator_approval_ref and len(args.operator_approval_ref) > 2048:
        raise HarnessError("--operator-approval-ref must be at most 2048 characters")
    args.buyer_url = validate_loopback_url(args.buyer_url, "buyer URL", "/v1/chat/completions")
    args.poolz_url = validate_loopback_url(args.poolz_url, "poolz URL", "/poolz")
    if not args.health_url:
        parsed = urlsplit(args.poolz_url)
        host = f"[{parsed.hostname}]" if ":" in str(parsed.hostname) else parsed.hostname
        args.health_url = f"{parsed.scheme}://{host}:{parsed.port or (443 if parsed.scheme == 'https' else 80)}/healthz"
    args.health_url = validate_loopback_url(args.health_url, "health URL", "/healthz")


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        validate_args(args)
        if args.dry_run_fixture:
            fixture_path = regular_file(args.dry_run_fixture, "dry-run fixture")
            capture = json.loads(fixture_path.read_text(encoding="utf-8"))
            if not isinstance(capture, dict):
                raise HarnessError("dry-run fixture must contain a JSON object")
            if capture.get("gate") != args.gate:
                raise HarnessError("dry-run fixture gate does not match --gate")
            result = evaluate_capture(capture)
            if result["verdict"] == "PASS":
                result["verdict"] = "DRY-RUN-PASS"
            output_dir = reserve_output_dir(args.output_dir)
        else:
            output_dir = reserve_output_dir(args.output_dir)
            capture, result = run_live(args)
        output_dir = write_evidence(output_dir, capture, result)
        print(f"{result['verdict']}: evidence written to {output_dir}")
        for reason in result["reasons"]:
            print(f"- {reason}", file=sys.stderr)
        return 0 if result["verdict"] in {"PASS", "DRY-RUN-PASS"} else 1
    except (HarnessError, OSError, json.JSONDecodeError) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
