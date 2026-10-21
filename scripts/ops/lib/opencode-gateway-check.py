#!/usr/bin/env python3
"""Bounded live-gateway acceptance recorder for OpenCode 1.17.9.

The loopback proxy deliberately buffers complete gateway responses.  Model
bytes are released to OpenCode only after every tool call is proven to be the
single permitted marker-file read.
"""

from __future__ import annotations

import argparse
import http.client
import http.server
import json
import os
import re
import secrets
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


GATEWAY_HOST = "api.malibu.tech"
GATEWAY_PORT = 443
CLIENT_VERSION = "1.17.9"
MAX_REQUESTS = 6
MAX_BODY_BYTES = 1 << 20
MAX_RESPONSE_BYTES = 1 << 20
MAX_OUTPUT_TOKENS = 1024
MIN_CONTEXT_TOKENS = 16384
RUN_TIMEOUT_SECONDS = 150
HTTP_TIMEOUT_SECONDS = 90
MODEL_BINDINGS = {
    "qwen3-coder-30b-a3b-instruct": "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
    "qwen3-30b-a3b-instruct-2507": "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit",
}
MODELS = tuple(MODEL_BINDINGS)
QWEN_PLUGIN_SOURCE = (Path(__file__).resolve().parents[3] /
                      "phase3-binary/app/Sources/Malibu/Resources/malibu-qwen-system.mjs")
SAFE_CALL_ID = re.compile(r"^[A-Za-z0-9_-]{1,128}$")


class CheckError(Exception):
    """An expected fail-closed rejection with a non-sensitive code."""

    def __init__(self, code: str):
        super().__init__(code)
        self.code = code
        self.evidence: dict[str, Any] = {}


def _is_uuid4(value: str) -> bool:
    try:
        parsed = uuid.UUID(value)
    except (ValueError, AttributeError):
        return False
    return parsed.version == 4 and str(parsed) == value.lower()


def _strict_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise CheckError("duplicate_json_key")
        result[key] = value
    return result


def strict_json(data: bytes | str) -> Any:
    try:
        return json.loads(data, object_pairs_hook=_strict_object)
    except CheckError:
        raise
    except (json.JSONDecodeError, UnicodeDecodeError, TypeError) as exc:
        raise CheckError("invalid_json") from exc


def _guard_credentials(value: Any, *credentials: str) -> None:
    """Reject credential-bearing metadata before retention or evidence output."""
    if isinstance(value, str):
        if any(credential and credential in value for credential in credentials):
            raise CheckError("credential_echo")
    elif isinstance(value, dict):
        for key, item in value.items():
            _guard_credentials(key, *credentials)
            _guard_credentials(item, *credentials)
    elif isinstance(value, list):
        for item in value:
            _guard_credentials(item, *credentials)


def _usage(value: Any) -> dict[str, int] | None:
    if not isinstance(value, dict):
        return None
    names = ("prompt_tokens", "completion_tokens", "total_tokens")
    if not all(type(value.get(name)) is int and value[name] >= 0 for name in names):
        return None
    return {name: value[name] for name in names}


def _safe_read_arguments(raw: str, marker_path: str) -> bool:
    try:
        value = strict_json(raw)
    except CheckError:
        return False
    if not isinstance(value, dict) or set(value) - {"filePath", "offset", "limit"}:
        return False
    if value.get("filePath") != marker_path:
        return False
    for name, maximum in (("offset", 1), ("limit", 100)):
        if name in value and (type(value[name]) is not int or not 0 <= value[name] <= maximum):
            return False
    return True


@dataclass
class ResponseMetadata:
    stream_id: str
    status: int
    usage: dict[str, int] | None
    tool_calls: list[dict[str, Any]]


def validate_tool_stream(
    body: bytes, marker_path: str, status: int = 200, expected_model: str | None = None
) -> ResponseMetadata:
    """Validate a complete OpenAI Chat Completions SSE response."""
    if status != 200:
        raise CheckError("gateway_status")
    if len(body) > MAX_RESPONSE_BYTES:
        raise CheckError("response_too_large")
    try:
        text = body.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise CheckError("response_not_utf8") from exc

    done = False
    finished = False
    stream_id = ""
    call_id = ""
    call_name = ""
    call_arguments = ""
    usage = None
    has_call = False
    for raw_line in text.replace("\r\n", "\n").split("\n"):
        if not raw_line or raw_line.startswith(":"):
            continue
        if done or not raw_line.startswith("data:"):
            raise CheckError("malformed_sse")
        data = raw_line[5:].strip()
        if data == "[DONE]":
            done = True
            continue
        frame = strict_json(data)
        if not isinstance(frame, dict) or frame.get("error") is not None:
            raise CheckError("invalid_stream_frame")
        frame_id = frame.get("id")
        if frame_id is not None:
            if not isinstance(frame_id, str) or not frame_id or (stream_id and frame_id != stream_id):
                raise CheckError("inconsistent_stream_id")
            stream_id = frame_id
        frame_model = frame.get("model")
        if expected_model is not None and frame_model != expected_model:
            raise CheckError("response_model_mismatch")
        found_usage = _usage(frame.get("usage"))
        if found_usage is not None:
            usage = found_usage
        choices = frame.get("choices", [])
        if not isinstance(choices, list) or len(choices) > 1:
            raise CheckError("invalid_stream_choices")
        for choice in choices:
            if finished or not isinstance(choice, dict) or choice.get("index") != 0:
                raise CheckError("invalid_stream_choice")
            delta = choice.get("delta", {})
            if not isinstance(delta, dict) or "function_call" in delta:
                raise CheckError("legacy_or_invalid_tool_call")
            calls = delta.get("tool_calls", [])
            if not isinstance(calls, list) or len(calls) > 1:
                raise CheckError("parallel_tool_call")
            for call in calls:
                if not isinstance(call, dict) or call.get("index") != 0:
                    raise CheckError("invalid_tool_call")
                if call.get("type") not in (None, "function"):
                    raise CheckError("invalid_tool_type")
                fragment_id = call.get("id", "")
                if fragment_id:
                    if (not isinstance(fragment_id, str) or not SAFE_CALL_ID.fullmatch(fragment_id)
                            or (call_id and call_id != fragment_id)):
                        raise CheckError("invalid_tool_call_id")
                    call_id = fragment_id
                function = call.get("function", {})
                if not isinstance(function, dict):
                    raise CheckError("invalid_tool_function")
                name_fragment = function.get("name", "")
                args_fragment = function.get("arguments", "")
                if not isinstance(name_fragment, str) or not isinstance(args_fragment, str):
                    raise CheckError("invalid_tool_fragment")
                call_name += name_fragment
                call_arguments += args_fragment
                has_call = True
            reason = choice.get("finish_reason")
            if reason is not None:
                expected = "tool_calls" if has_call else "stop"
                if reason != expected:
                    raise CheckError("invalid_finish_reason")
                finished = True
    if not done or not finished or not stream_id:
        raise CheckError("incomplete_stream")
    calls_metadata: list[dict[str, Any]] = []
    if has_call:
        if not call_id or call_name != "read" or not _safe_read_arguments(call_arguments, marker_path):
            raise CheckError("unsafe_tool_call")
        calls_metadata.append({"name": "read", "call_id": call_id, "marker_path_match": True})
    return ResponseMetadata(stream_id, status, usage, calls_metadata)


def validate_client_request(
    body: bytes, model: str, marker: str, marker_path: str | None = None
) -> dict[str, Any]:
    if len(body) > MAX_BODY_BYTES:
        raise CheckError("request_too_large")
    payload = strict_json(body)
    if not isinstance(payload, dict):
        raise CheckError("request_not_object")
    if payload.get("model") != model or payload.get("stream") is not True:
        raise CheckError("request_model_or_stream")
    if "tool_choice" in payload and payload["tool_choice"] != "auto":
        raise CheckError("tool_choice_not_auto")
    budget_fields = ("max_tokens", "max_completion_tokens", "max_output_tokens")
    budgets = [payload[name] for name in budget_fields if name in payload]
    if not budgets or any(type(value) is not int or not 1 <= value <= MAX_OUTPUT_TOKENS for value in budgets):
        raise CheckError("output_budget")
    messages = payload.get("messages")
    if not isinstance(messages, list):
        raise CheckError("messages_missing")
    tools = payload.get("tools")
    if not isinstance(tools, list) or not tools:
        raise CheckError("read_tool_missing")
    has_read = False
    for tool in tools:
        function = tool.get("function") if isinstance(tool, dict) else None
        if (not isinstance(function, dict) or tool.get("type") != "function"
                or not isinstance(function.get("name"), str)):
            raise CheckError("unexpected_request_tool")
        has_read = has_read or function["name"] == "read"
    if not has_read:
        raise CheckError("read_tool_missing")
    opened: set[str] = set()
    results: list[dict[str, Any]] = []
    for message in messages:
        if not isinstance(message, dict):
            raise CheckError("invalid_message")
        calls = message.get("tool_calls", [])
        if not isinstance(calls, list):
            raise CheckError("invalid_tool_history")
        for call in calls:
            if (not isinstance(call, dict) or not isinstance(call.get("id"), str)
                    or not SAFE_CALL_ID.fullmatch(call["id"])):
                raise CheckError("invalid_tool_history")
            function = call.get("function")
            if (call.get("type") != "function" or not isinstance(function, dict)
                    or function.get("name") != "read"
                    or not isinstance(function.get("arguments"), str)):
                raise CheckError("invalid_tool_history")
            if marker_path is not None and not _safe_read_arguments(function["arguments"], marker_path):
                raise CheckError("unsafe_tool_history")
            opened.add(call["id"])
        if message.get("role") == "tool":
            call_id = message.get("tool_call_id")
            content = message.get("content")
            if not isinstance(call_id, str) or call_id not in opened:
                raise CheckError("unlinked_tool_result")
            matched = isinstance(content, str) and marker in content
            if not matched:
                raise CheckError("mismatched_tool_result")
            results.append({"call_id": call_id, "marker_match": True})
    return {"tool_results": results, "output_budget": max(budgets), "tool_choice_auto": True}


def parse_opencode_events(output: bytes, marker_path: str, marker: str) -> dict[str, Any]:
    if len(output) > MAX_RESPONSE_BYTES:
        raise CheckError("client_output_too_large")
    completed: list[dict[str, Any]] = []
    final_text = ""
    for line in output.splitlines():
        if not line.strip():
            continue
        try:
            event = strict_json(line)
        except CheckError:
            continue
        if not isinstance(event, dict):
            continue
        event_type = event.get("type")
        part = event.get("part")
        if event_type == "text" and isinstance(part, dict) and isinstance(part.get("text"), str):
            final_text = part["text"]
        if event_type != "tool_use" or not isinstance(part, dict):
            continue
        state = part.get("state")
        if part.get("tool") != "read" or not isinstance(state, dict) or state.get("status") != "completed":
            continue
        args = state.get("input")
        call_id = part.get("callID")
        output_text = state.get("output")
        if not isinstance(args, dict) or not isinstance(call_id, str) or not SAFE_CALL_ID.fullmatch(call_id):
            continue
        if set(args) - {"filePath", "offset", "limit"} or args.get("filePath") != marker_path:
            continue
        completed.append({"name": "read", "call_id": call_id, "marker_path_match": True,
                          "marker_result_match": isinstance(output_text, str) and marker in output_text})
    matching = [item for item in completed if item["marker_result_match"]]
    if not matching:
        raise CheckError("completed_tool_event_missing")
    if final_text.strip() != marker:
        raise CheckError("final_marker_mismatch")
    return {"completed_tool_events": matching, "final_marker_match": True}


@dataclass
class RecorderState:
    model: str
    marker_path: str
    marker: str
    key: str
    proxy_token: str
    lock: threading.Lock = field(default_factory=threading.Lock)
    requests: list[dict[str, Any]] = field(default_factory=list)
    inbound_count: int = 0
    error_code: str | None = None

    def fail(self, code: str) -> None:
        with self.lock:
            if self.error_code is None:
                self.error_code = code

    def claim_request(self) -> bool:
        with self.lock:
            self.inbound_count += 1
            return self.inbound_count <= MAX_REQUESTS

    def record_response(self, request_id: str, status: int) -> dict[str, Any]:
        record = {"id": request_id, "status": status}
        with self.lock:
            self.requests.append(record)
        return record


class GatewayProxy(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = False

    def __init__(self, state: RecorderState):
        self.state = state
        super().__init__(("127.0.0.1", 0), GatewayProxyHandler)


class GatewayProxyHandler(http.server.BaseHTTPRequestHandler):
    server: GatewayProxy
    protocol_version = "HTTP/1.1"

    def log_message(self, _format: str, *_args: Any) -> None:
        return

    def _reject(self, code: str, status: int = 400) -> None:
        self.server.state.fail(code)
        self.send_response(status)
        self.send_header("Content-Length", "0")
        self.send_header("Connection", "close")
        self.end_headers()

    def do_POST(self) -> None:
        state = self.server.state
        if not state.claim_request():
            self._reject("request_budget", 429)
            return
        if self.path != "/v1/chat/completions":
            self._reject("unexpected_proxy_path", 404)
            return
        if self.headers.get("Authorization") != "Bearer " + state.proxy_token:
            self._reject("proxy_auth")
            return
        try:
            length = int(self.headers.get("Content-Length", "-1"))
        except ValueError:
            length = -1
        if not 0 <= length <= MAX_BODY_BYTES:
            self._reject("request_size")
            return
        body = self.rfile.read(length)
        try:
            request_metadata = validate_client_request(body, state.model, state.marker, state.marker_path)
            connection = http.client.HTTPSConnection(GATEWAY_HOST, GATEWAY_PORT, timeout=HTTP_TIMEOUT_SECONDS)
            headers = {"Authorization": "Bearer " + state.key,
                       "Content-Type": self.headers.get("Content-Type", "application/json"),
                       "Content-Length": str(len(body)), "Accept": self.headers.get("Accept", "*/*")}
            try:
                connection.request("POST", "/v1/chat/completions", body=body, headers=headers)
                response = connection.getresponse()
                response_body = response.read(MAX_RESPONSE_BYTES + 1)
                response_status = response.status
                response_headers = response.getheaders()
                request_id = response.getheader("X-Request-ID", "")
            finally:
                connection.close()
            if not _is_uuid4(request_id):
                raise CheckError("missing_request_id")
            record = state.record_response(request_id, response_status)
            if len(response_body) > MAX_RESPONSE_BYTES:
                raise CheckError("response_too_large")
            response_metadata = validate_tool_stream(
                response_body, state.marker_path, response_status,
                expected_model=MODEL_BINDINGS[state.model],
            )
            if response_metadata.usage is None:
                raise CheckError("response_usage_missing")
            candidate = {**record, "status": response_metadata.status, "usage": response_metadata.usage,
                           "tool_calls": response_metadata.tool_calls,
                           "tool_results": request_metadata["tool_results"],
                           "output_budget": request_metadata["output_budget"],
                           "tool_choice_auto": request_metadata["tool_choice_auto"]}
            _guard_credentials(candidate, state.key, state.proxy_token)
            record.update(candidate)
            self.send_response(response_status)
            for name, value in response_headers:
                if name.lower() not in {"authorization", "connection", "content-length", "transfer-encoding"}:
                    self.send_header(name, value)
            self.send_header("Content-Length", str(len(response_body)))
            self.end_headers()
            self.wfile.write(response_body)
        except CheckError as exc:
            self._reject(exc.code, 502)
        except Exception:
            self._reject("upstream_transport", 502)


def _bounded_https_get(
    path: str, key: str, timeout_seconds: float = HTTP_TIMEOUT_SECONDS,
    deadline: float | None = None,
) -> tuple[int, bytes]:
    if deadline is None:
        deadline = time.monotonic() + timeout_seconds
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise CheckError("upstream_transport")
    connection = http.client.HTTPSConnection(
        GATEWAY_HOST, GATEWAY_PORT, timeout=min(timeout_seconds, remaining)
    )

    def abort() -> None:
        active_socket = connection.sock
        if active_socket is not None:
            try:
                active_socket.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
        connection.close()

    watchdog = threading.Timer(remaining, abort)
    watchdog.daemon = True
    watchdog.start()

    def apply_remaining_timeout() -> None:
        operation_remaining = deadline - time.monotonic()
        if operation_remaining <= 0:
            raise CheckError("upstream_transport")
        if connection.sock is not None:
            connection.sock.settimeout(operation_remaining)

    try:
        connection.request("GET", path, headers={"Authorization": "Bearer " + key, "Accept": "application/json"})
        apply_remaining_timeout()
        response = connection.getresponse()
        body = bytearray()
        reader = getattr(response, "read1", response.read)
        while len(body) <= MAX_RESPONSE_BYTES:
            apply_remaining_timeout()
            chunk = reader(min(65536, MAX_RESPONSE_BYTES + 1 - len(body)))
            if not chunk:
                break
            body.extend(chunk)
        if len(body) > MAX_RESPONSE_BYTES:
            raise CheckError("response_too_large")
        return response.status, bytes(body)
    except CheckError:
        raise
    except Exception as exc:
        raise CheckError("upstream_transport") from exc
    finally:
        watchdog.cancel()
        connection.close()
        watchdog.join(timeout=1)


def validate_models(body: bytes, status: int, model: str) -> int:
    if status != 200:
        raise CheckError("models_status")
    payload = strict_json(body)
    rows = payload.get("data") if isinstance(payload, dict) else None
    if not isinstance(rows, list):
        raise CheckError("models_shape")
    matches = [row for row in rows if isinstance(row, dict) and row.get("id") == model]
    if len(matches) != 1:
        raise CheckError("model_not_exact")
    row = matches[0]
    candidates = (row.get("max_context_tokens"), row.get("context_window"), row.get("context_length"))
    context = next((value for value in candidates if type(value) is int), None)
    if context is None or context < MIN_CONTEXT_TOKENS:
        raise CheckError("model_context_too_small")
    return context


def validate_receipt(
    body: bytes, status: int, request_id: str, model: str, *,
    expected_provider_key_fingerprint: str, expected_model_hash: str, expected_catalog_id: str,
) -> dict[str, Any] | None:
    """Return minimal terminal metadata, or None while settlement is pending."""
    if status == 404:
        return None
    if status != 200:
        raise CheckError("receipt_status")
    payload = strict_json(body)
    if not isinstance(payload, dict) or payload.get("schema_version") != "macprovider.buyer-receipt-view.v1":
        raise CheckError("receipt_shape")
    if payload.get("request_id") != request_id or payload.get("surface") != "metadata":
        raise CheckError("receipt_request_mismatch")
    if payload.get("pending_quarantined_visible") is not True:
        raise CheckError("receipt_visibility")
    attempts = payload.get("attempts")
    if not isinstance(attempts, list):
        raise CheckError("receipt_shape")
    has_closed_negative = False
    verified = None
    for attempt in attempts:
        if not isinstance(attempt, dict) or type(attempt.get("attempt_n")) is not int or attempt["attempt_n"] < 1:
            raise CheckError("receipt_attempt_shape")
        if attempt.get("closed") is True:
            if (attempt.get("receipt_result") == "valid"
                    and attempt.get("settlement_outcome") == "verified"):
                for name, expected, code in (
                    ("model_id", model, "receipt_model_mismatch"),
                    ("provider_receipt_key_fingerprint", expected_provider_key_fingerprint,
                     "receipt_provider_mismatch"),
                    ("model_hash", expected_model_hash, "receipt_model_hash_mismatch"),
                    ("catalog_id", expected_catalog_id, "receipt_catalog_mismatch"),
                ):
                    if not expected or attempt.get(name) != expected:
                        raise CheckError(code)
                if verified is None:
                    verified = {"request_id": request_id, "attempt_n": attempt["attempt_n"],
                                "status": "verified"}
                continue
            has_closed_negative = True
    if verified is not None:
        return verified
    if has_closed_negative:
        raise CheckError("receipt_not_verified")
    return None


def poll_receipt(
    request_id: str, key: str, model: str, *, expected_provider_key_fingerprint: str,
    expected_model_hash: str, expected_catalog_id: str, timeout_seconds: float = 30.0,
) -> dict[str, Any]:
    expected_artifact_id = MODEL_BINDINGS[model]
    deadline = time.monotonic() + timeout_seconds
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise CheckError("receipt_pending_timeout")
        try:
            status, body = _bounded_https_get(
                "/v1/receipts/" + urllib.parse.quote(request_id, safe=""), key,
                timeout_seconds=min(HTTP_TIMEOUT_SECONDS, remaining),
                deadline=deadline,
            )
        except CheckError as exc:
            if exc.code == "upstream_transport" and time.monotonic() >= deadline:
                raise CheckError("receipt_pending_timeout") from exc
            raise
        result = validate_receipt(
            body, status, request_id, expected_artifact_id,
            expected_provider_key_fingerprint=expected_provider_key_fingerprint,
            expected_model_hash=expected_model_hash, expected_catalog_id=expected_catalog_id,
        )
        if result is not None:
            return result
        if time.monotonic() >= deadline:
            raise CheckError("receipt_pending_timeout")
        time.sleep(min(1.0, max(0.0, deadline - time.monotonic())))


def _decode_key(raw: bytes) -> str:
    if len(raw) > 8192:
        raise CheckError("key_file_too_large")
    try:
        key = raw.decode("utf-8").strip()
    except UnicodeDecodeError as exc:
        raise CheckError("key_file_encoding") from exc
    if not key or any(character.isspace() for character in key):
        raise CheckError("key_file_value")
    return key


def _read_key(path_value: str) -> str:
    path = Path(path_value)
    if not path.is_absolute():
        raise CheckError("key_path_not_absolute")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        raise CheckError("key_file_unavailable") from exc
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077:
            raise CheckError("key_file_permissions")
        raw = os.read(descriptor, 8193)
    finally:
        os.close(descriptor)
    return _decode_key(raw)


def _read_key_stdin(stream: Any | None = None) -> str:
    if stream is None:
        stream = sys.stdin.buffer
    try:
        raw = stream.read(8192)
        extra = stream.read(1)
    except (OSError, ValueError) as exc:
        raise CheckError("key_file_unavailable") from exc
    if not isinstance(raw, bytes) or not isinstance(extra, bytes):
        raise CheckError("key_file_encoding")
    if extra:
        raise CheckError("key_file_too_large")
    return _decode_key(raw)


def _opencode_version(binary: str, env: dict[str, str], cwd: str) -> None:
    try:
        result = subprocess.run([binary, "--version"], cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise CheckError("client_version_check") from exc
    if result.returncode != 0 or result.stdout.decode("utf-8", "replace").strip() != CLIENT_VERSION:
        raise CheckError("client_version_mismatch")


def _bounded_client_process(command: list[str], cwd: Path, env: dict[str, str],
                            prompt: bytes = b"") -> tuple[int, bytes]:
    if len(prompt) > MAX_BODY_BYTES:
        raise CheckError("client_input_too_large")
    # OpenCode 1.17.9 quotes positional arguments containing spaces. Its stdin
    # path preserves the task literally, as an interactive user would enter it.
    # A private temporary descriptor avoids blocking a pipe write before the
    # child timeout and never forwards the recorder's buyer-key stdin.
    with tempfile.TemporaryFile() as task_input:
        task_input.write(prompt)
        task_input.seek(0)
        process = subprocess.Popen(command, cwd=cwd, env=env, stdin=task_input,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    output = bytearray()
    total_bytes = 0
    lock = threading.Lock()
    overflow = threading.Event()

    def drain(pipe: Any, retain: bool) -> None:
        nonlocal total_bytes
        while True:
            chunk = pipe.read(8192)
            if not chunk:
                return
            with lock:
                total_bytes += len(chunk)
                if total_bytes > MAX_RESPONSE_BYTES:
                    overflow.set()
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    return
                if retain:
                    output.extend(chunk)

    threads = [threading.Thread(target=drain, args=(process.stdout, True), daemon=True),
               threading.Thread(target=drain, args=(process.stderr, False), daemon=True)]
    for thread in threads:
        thread.start()
    try:
        process.wait(timeout=RUN_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired as exc:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
        raise CheckError("client_timeout") from exc
    finally:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        for thread in threads:
            thread.join(timeout=5)
        process.stdout.close()
        process.stderr.close()
        process.wait()
    if overflow.is_set():
        raise CheckError("client_output_too_large")
    return process.returncode, bytes(output)


def _failure_evidence(
    state: RecorderState, key: str, model: str, *, expected_provider_key_fingerprint: str,
    expected_model_hash: str, expected_catalog_id: str,
) -> dict[str, Any]:
    with state.lock:
        requests = list(state.requests)
    receipts: list[dict[str, Any]] = []
    successful_ids = (request["id"] for request in requests if request["status"] == 200)
    for request_id in dict.fromkeys(successful_ids):
        try:
            receipts.append(poll_receipt(
                request_id, key, model, timeout_seconds=5.0,
                expected_provider_key_fingerprint=expected_provider_key_fingerprint,
                expected_model_hash=expected_model_hash, expected_catalog_id=expected_catalog_id,
            ))
        except CheckError as exc:
            status = "pending" if exc.code == "receipt_pending_timeout" else "not_verified"
            if exc.code in {"receipt_status", "upstream_transport", "response_too_large"}:
                status = "unavailable"
            receipts.append({"request_id": request_id, "status": status})
    receipt_status = "pending"
    if receipts and all(row["status"] == "verified" for row in receipts):
        receipt_status = "verified"
    elif any(row["status"] == "not_verified" for row in receipts):
        receipt_status = "failed"
    evidence = {"accepted": False,
            "model": {"gateway_id": model, "qualified_artifact_id": MODEL_BINDINGS[model]},
            "requests": requests,
            "receipt_validation": {"status": receipt_status, "receipts": receipts}}
    try:
        _guard_credentials(evidence, key, state.proxy_token)
    except CheckError:
        # Discard contaminated evidence even if an earlier retention guard regresses.
        return {"accepted": False,
                "receipt_validation": {"status": "pending", "receipts": []}}
    return evidence


def _config(model: str, context: int, base_url: str, plugin: Path | None = None) -> bytes:
    entry = {"name": model, "limit": {"context": context, "output": MAX_OUTPUT_TOKENS}}
    if model in MODEL_BINDINGS or model in MODEL_BINDINGS.values():
        # Match the app's model-scoped HTTP fields without replacing the stock agent.
        entry.update({"temperature": True, "options": {"temperature": 0.7, "top_p": 0.8}})
    value = {
        "model": "malibu/" + model,
        "small_model": "malibu/" + model,
        "provider": {"malibu": {"npm": "@ai-sdk/openai-compatible", "name": "Malibu",
                                  "options": {"baseURL": base_url, "apiKey": "{env:MALIBU_PROXY_TOKEN}",
                                              "timeout": HTTP_TIMEOUT_SECONDS * 1000},
                                  "models": {model: entry}}},
    }
    if plugin is not None:
        if not plugin.is_absolute() or model not in (*MODEL_BINDINGS, *MODEL_BINDINGS.values()):
            raise CheckError("client_plugin_binding")
        value["plugin"] = [plugin.as_uri()]
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def _install_plugin(root: Path, model: str) -> Path | None:
    if model not in MODEL_BINDINGS and model not in MODEL_BINDINGS.values():
        return None
    try:
        with QWEN_PLUGIN_SOURCE.open("rb") as source:
            data = source.read(MAX_BODY_BYTES + 1)
        if not data or len(data) > MAX_BODY_BYTES:
            raise CheckError("client_plugin_size")
        destination = root / QWEN_PLUGIN_SOURCE.name
        # The recorder owns its isolated temporary root and removes it on exit.
        descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "wb") as target:
            target.write(data)
        return destination
    except OSError as exc:
        raise CheckError("client_plugin_file") from exc


def _run(args: argparse.Namespace) -> dict[str, Any]:
    receipt_binding = {
        "expected_provider_key_fingerprint": args.expected_provider_key_fingerprint,
        "expected_model_hash": args.expected_model_hash,
        "expected_catalog_id": args.expected_catalog_id,
    }
    binary = Path(args.opencode)
    if not binary.is_absolute() or not binary.is_file() or not os.access(binary, os.X_OK):
        raise CheckError("client_path")
    key = _read_key(args.key_file) if args.key_file is not None else _read_key_stdin()
    qualified_artifact_id = MODEL_BINDINGS[args.model]
    models_status, models_body = _bounded_https_get("/v1/models", key)
    context = validate_models(models_body, models_status, args.model)

    root = Path(tempfile.mkdtemp(prefix="malibu-opencode-check-")).resolve()
    try:
        os.chmod(root, 0o700)
        directories = {name: root / name for name in
                       ("config", "data", "state", "cache", "tmp", "home", "workspace")}
        for directory in directories.values():
            directory.mkdir(mode=0o700)
        marker = "malibu-" + secrets.token_hex(16)
        marker_path = directories["workspace"] / "marker.txt"
        marker_path.write_text(marker + "\n", encoding="utf-8")
        os.chmod(marker_path, 0o600)
        state = RecorderState(args.model, str(marker_path), marker, key, "proxy-" + secrets.token_urlsafe(32))
        proxy = GatewayProxy(state)
        thread = threading.Thread(target=proxy.serve_forever, daemon=True)
        thread.start()
        try:
            config_path = root / "opencode.json"
            plugin = _install_plugin(root, args.model)
            config_path.write_bytes(_config(
                args.model, context, f"http://127.0.0.1:{proxy.server_address[1]}/v1", plugin
            ))
            os.chmod(config_path, 0o600)
            env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                   "XDG_CONFIG_HOME": str(directories["config"]), "XDG_DATA_HOME": str(directories["data"]),
                   "XDG_STATE_HOME": str(directories["state"]), "XDG_CACHE_HOME": str(directories["cache"]),
                   "TMPDIR": str(directories["tmp"]), "OPENCODE_CONFIG": str(config_path),
                   "OPENCODE_TEST_HOME": str(directories["home"]),
                   "OPENCODE_DISABLE_PROJECT_CONFIG": "1",
                   "OPENCODE_CONFIG_PROJECT_DISABLE": "1",
                   "OPENCODE_DISABLE_MODELS_FETCH": "1", "OPENCODE_DISABLE_AUTOUPDATE": "1",
                   "MALIBU_PROXY_TOKEN": state.proxy_token}
            _opencode_version(str(binary), env, str(directories["workspace"]))
            prompt = (f"Read only {marker_path} using the read tool. Do not inspect any other file, execute "
                      "a shell command, or use the network. Reply with exactly its contents and nothing else.")
            # --pure skips even explicit local plugins. Only omit it after the
            # shared managed plugin has been installed and configured above.
            command = [str(binary), "run"] + (["--pure"] if plugin is None else []) + [
                       "--format", "json", "--model", "malibu/" + args.model,
                       "--title", "Malibu automatic tool acceptance",
                       "--dir", str(directories["workspace"])]
            returncode, stdout = _bounded_client_process(command, directories["workspace"], env, prompt.encode("utf-8"))
            if returncode != 0:
                raise CheckError(state.error_code or "client_failed")
            if state.error_code:
                raise CheckError(state.error_code)
            event_metadata = parse_opencode_events(stdout, str(marker_path), marker)
            with state.lock:
                requests = list(state.requests)
            if not 2 <= len(requests) <= MAX_REQUESTS:
                raise CheckError("tool_round_trip_missing")
            call_ids = {call["call_id"] for request in requests for call in request["tool_calls"]}
            result_ids = {result["call_id"] for request in requests for result in request["tool_results"]}
            event_ids = {event["call_id"] for event in event_metadata["completed_tool_events"]}
            if (len(call_ids) != 1 or result_ids != call_ids or event_ids != call_ids
                    or len(event_metadata["completed_tool_events"]) != 1):
                raise CheckError("tool_call_linkage")
            receipts = []
            for request_id in dict.fromkeys(request["id"] for request in requests):
                receipts.append(poll_receipt(request_id, key, args.model, **receipt_binding))
            result = {"schema_version": "macprovider.opencode_gateway_check.v1", "status": "pass",
                    "accepted": True,
                    "client": {"name": "opencode", "version": CLIENT_VERSION},
                    "model": {"gateway_id": args.model,
                              "qualified_artifact_id": qualified_artifact_id,
                              "context_tokens": context}, "requests": requests,
                    "opencode": event_metadata,
                    "receipt_validation": {"status": "verified", "receipts": receipts}}
            _guard_credentials(result, key, state.proxy_token)
            return result
        except CheckError as exc:
            exc.evidence = _failure_evidence(state, key, args.model, **receipt_binding)
            raise
        finally:
            proxy.shutdown()
            proxy.server_close()
            thread.join(timeout=5)
    finally:
        shutil.rmtree(root, ignore_errors=True)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--opencode", required=True, help="absolute OpenCode 1.17.9 executable")
    parser.add_argument("--model", required=True, choices=MODELS)
    parser.add_argument("--expected-provider-key-fingerprint", required=True)
    parser.add_argument("--expected-model-hash", required=True)
    parser.add_argument("--expected-catalog-id", required=True)
    key_source = parser.add_mutually_exclusive_group(required=True)
    key_source.add_argument("--key-file", help="absolute owner-only regular file")
    key_source.add_argument("--key-stdin", action="store_true", help="read the buyer key from stdin")
    return parser


def main(argv: list[str] | None = None) -> int:
    try:
        result = _run(build_parser().parse_args(argv))
        print(json.dumps(result, sort_keys=True, separators=(",", ":")))
        return 0
    except CheckError as exc:
        result = {"schema_version": "macprovider.opencode_gateway_check.v1", "status": "fail",
                  "accepted": False, "error_code": exc.code,
                  "receipt_validation": {"status": "pending", "receipts": []}}
        result.update(exc.evidence)
        print(json.dumps(result, sort_keys=True, separators=(",", ":")))
        return 1
    except Exception:
        print(json.dumps({"schema_version": "macprovider.opencode_gateway_check.v1", "status": "fail",
                          "accepted": False, "error_code": "internal_error",
                          "receipt_validation": {"status": "pending", "receipts": []}},
                         sort_keys=True, separators=(",", ":")))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
