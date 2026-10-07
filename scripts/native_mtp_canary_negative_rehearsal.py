#!/usr/bin/env python3
"""Loopback-only native-MTP canary diagnostic WebSocket fault relay.

LAB ONLY. This relay is a small RFC6455 pass-through intended to sit between the
lab provider and the isolated lab coordinator during the native-MTP enablement
rehearsal:

    provider -> ws://127.0.0.1:<listen_port>/ws/provider -> relay ->
    ws://127.0.0.1:<upstream_port>/ws/provider -> isolated coordinator

It never connects to production hosts, never opens non-loopback listeners, never
uses ports outside the 193xx lab block, and never persists raw frames, auth
headers, request bodies, or buyer data. It only inspects in-memory text frames
well enough to find `native_mtp_canary_result_v1` provider->coordinator frames
and apply one configured diagnostic fault.
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import hashlib
import json
import os
import secrets
import signal
import struct
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

LAB_PORT_MIN = 19300
LAB_PORT_MAX = 19399
FORBIDDEN_PORTS = {8080, 18120, 18122, 18130, 18140, 18150, 11435, 9444}
MAX_HEADER_BYTES = 16 * 1024
DEFAULT_MAX_FRAME_BYTES = 1_048_576
CANARY_RESULT_TYPE = "native_mtp_canary_result_v1"
VALID_FAULTS = {"wrong_digest", "malformed_digest", "actual_path", "fallback", "drop", "delay"}
PRODUCTION_HOSTS = {"coordinator.malibu.tech", "malibu.tech", "provider.malibu.tech"}
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


@dataclass
class RelayStats:
    started_at_unix: float = field(default_factory=time.time)
    downstream_connections: int = 0
    upstream_connections: int = 0
    frames_provider_to_coordinator: int = 0
    frames_coordinator_to_provider: int = 0
    canary_results_seen: int = 0
    canary_results_faulted: int = 0
    canary_results_dropped: int = 0
    bytes_provider_to_coordinator: int = 0
    bytes_coordinator_to_provider: int = 0
    last_fault: str | None = None
    last_error: str | None = None

    def sanitized(self) -> dict[str, Any]:
        return {
            "started_at_unix": self.started_at_unix,
            "downstream_connections": self.downstream_connections,
            "upstream_connections": self.upstream_connections,
            "frames_provider_to_coordinator": self.frames_provider_to_coordinator,
            "frames_coordinator_to_provider": self.frames_coordinator_to_provider,
            "canary_results_seen": self.canary_results_seen,
            "canary_results_faulted": self.canary_results_faulted,
            "canary_results_dropped": self.canary_results_dropped,
            "bytes_provider_to_coordinator": self.bytes_provider_to_coordinator,
            "bytes_coordinator_to_provider": self.bytes_coordinator_to_provider,
            "last_fault": self.last_fault,
            "last_error": self.last_error,
        }


@dataclass(frozen=True)
class RelayConfig:
    listen_host: str
    listen_port: int
    upstream_url: str
    fault: str
    delay_seconds: float = 0.0
    max_frame_bytes: int = DEFAULT_MAX_FRAME_BYTES
    once: bool = True
    status_path: Path | None = None

    @property
    def upstream(self):
        return urlparse(self.upstream_url)

    @property
    def upstream_host(self) -> str:
        return self.upstream.hostname or ""

    @property
    def upstream_port(self) -> int:
        if self.upstream.port is not None:
            return int(self.upstream.port)
        return 443 if self.upstream.scheme == "wss" else 80

    @property
    def upstream_path(self) -> str:
        path = self.upstream.path or "/ws/provider"
        if self.upstream.query:
            path += "?" + self.upstream.query
        return path


def validate_loopback_host(host: str) -> None:
    if host not in {"127.0.0.1", "localhost", "::1"}:
        raise ValueError(f"host {host!r} is not loopback")


def validate_lab_port(port: int) -> None:
    if port in FORBIDDEN_PORTS or not LAB_PORT_MIN <= port <= LAB_PORT_MAX:
        raise ValueError(f"port {port} is outside the isolated 193xx block")


def validate_config(cfg: RelayConfig) -> None:
    validate_loopback_host(cfg.listen_host)
    validate_lab_port(cfg.listen_port)
    parsed = cfg.upstream
    if parsed.scheme != "ws":
        raise ValueError("upstream_url must be ws:// loopback; TLS/live endpoints are refused")
    host = cfg.upstream_host
    validate_loopback_host(host)
    if host.rstrip(".").lower() in PRODUCTION_HOSTS:
        raise ValueError("production upstream host refused")
    validate_lab_port(cfg.upstream_port)
    if cfg.upstream_port == cfg.listen_port:
        raise ValueError("listen and upstream ports must differ")
    if cfg.fault not in VALID_FAULTS:
        raise ValueError(f"unsupported fault {cfg.fault!r}")
    if cfg.max_frame_bytes <= 0 or cfg.max_frame_bytes > DEFAULT_MAX_FRAME_BYTES:
        raise ValueError("max_frame_bytes must be between 1 and 1048576")
    if cfg.delay_seconds < 0 or cfg.delay_seconds > 900:
        raise ValueError("delay_seconds must be between 0 and 900")


def accept_key(client_key: str) -> str:
    digest = hashlib.sha1((client_key + GUID).encode("ascii")).digest()
    return base64.b64encode(digest).decode("ascii")


async def read_http_headers(reader: asyncio.StreamReader) -> tuple[bytes, dict[str, str]]:
    data = await reader.readuntil(b"\r\n\r\n")
    if len(data) > MAX_HEADER_BYTES:
        raise ValueError("websocket handshake headers too large")
    text = data.decode("iso-8859-1")
    lines = text.split("\r\n")
    headers: dict[str, str] = {":request-line": lines[0]}
    for line in lines[1:]:
        if not line:
            continue
        if ":" not in line:
            raise ValueError("malformed HTTP header")
        key, value = line.split(":", 1)
        headers[key.strip().lower()] = value.strip()
    return data, headers


async def write_server_handshake(writer: asyncio.StreamWriter, headers: dict[str, str]) -> None:
    key = headers.get("sec-websocket-key")
    if not key:
        raise ValueError("missing Sec-WebSocket-Key")
    response = (
        "HTTP/1.1 101 Switching Protocols\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Accept: {accept_key(key)}\r\n"
        "\r\n"
    ).encode("ascii")
    writer.write(response)
    await writer.drain()


async def write_client_handshake(reader: asyncio.StreamReader, writer: asyncio.StreamWriter, cfg: RelayConfig, downstream_headers: dict[str, str]) -> None:
    key = base64.b64encode(secrets.token_bytes(16)).decode("ascii")
    protocol = downstream_headers.get("sec-websocket-protocol")
    lines = [
        f"GET {cfg.upstream_path} HTTP/1.1",
        f"Host: {cfg.upstream_host}:{cfg.upstream_port}",
        "Upgrade: websocket",
        "Connection: Upgrade",
        f"Sec-WebSocket-Key: {key}",
        "Sec-WebSocket-Version: 13",
    ]
    if protocol:
        lines.append(f"Sec-WebSocket-Protocol: {protocol}")
    writer.write(("\r\n".join(lines) + "\r\n\r\n").encode("ascii"))
    await writer.drain()
    _, response_headers = await read_http_headers(reader)
    status = response_headers.get(":request-line", "")
    if not status.startswith("HTTP/1.1 101") and not status.startswith("HTTP/1.0 101"):
        raise ValueError("upstream websocket handshake failed")


@dataclass(frozen=True)
class Frame:
    fin: bool
    opcode: int
    masked: bool
    payload: bytes
    raw: bytes


async def read_exact(reader: asyncio.StreamReader, n: int) -> bytes:
    data = await reader.readexactly(n)
    return data


async def read_frame(reader: asyncio.StreamReader, max_frame_bytes: int) -> Frame:
    header = await read_exact(reader, 2)
    first, second = header[0], header[1]
    fin = bool(first & 0x80)
    opcode = first & 0x0F
    masked = bool(second & 0x80)
    length = second & 0x7F
    ext = b""
    if length == 126:
        ext = await read_exact(reader, 2)
        length = struct.unpack("!H", ext)[0]
    elif length == 127:
        ext = await read_exact(reader, 8)
        length = struct.unpack("!Q", ext)[0]
    if length > max_frame_bytes:
        raise ValueError("websocket frame exceeds configured max_frame_bytes")
    mask = b""
    if masked:
        mask = await read_exact(reader, 4)
    payload = await read_exact(reader, length)
    raw = header + ext + mask + payload
    if masked:
        payload = bytes(byte ^ mask[i % 4] for i, byte in enumerate(payload))
    return Frame(fin=fin, opcode=opcode, masked=masked, payload=payload, raw=raw)


def encode_frame(payload: bytes, *, opcode: int = 1, mask: bool, fin: bool = True) -> bytes:
    if len(payload) > DEFAULT_MAX_FRAME_BYTES:
        raise ValueError("payload too large")
    first = (0x80 if fin else 0) | (opcode & 0x0F)
    length = len(payload)
    if length < 126:
        header = bytes([first, (0x80 if mask else 0) | length])
    elif length <= 0xFFFF:
        header = bytes([first, (0x80 if mask else 0) | 126]) + struct.pack("!H", length)
    else:
        header = bytes([first, (0x80 if mask else 0) | 127]) + struct.pack("!Q", length)
    if not mask:
        return header + payload
    key = secrets.token_bytes(4)
    masked = bytes(byte ^ key[i % 4] for i, byte in enumerate(payload))
    return header + key + masked



def _jcs_string(value: Any) -> str:
    return json.dumps(str(value), separators=(",", ":"), ensure_ascii=False)


def _jcs_bool(value: Any) -> str:
    return "true" if bool(value) else "false"


def _jcs_uint(value: Any) -> str:
    if isinstance(value, bool):
        raise ValueError("boolean is not a uint")
    ivalue = int(value)
    if ivalue < 0:
        raise ValueError("negative uint")
    return str(ivalue)


def _native_mtp_counters_jcs(counters: dict[str, Any]) -> str:
    return (
        '{"accepted":' + _jcs_uint(counters.get("accepted", 0))
        + ',"bonus":' + _jcs_uint(counters.get("bonus", 0))
        + ',"committed":' + _jcs_uint(counters.get("committed", 0))
        + ',"rejected":' + _jcs_uint(counters.get("rejected", 0)) + '}'
    )


def _native_mtp_runtime_tuple_jcs(tuple_obj: dict[str, Any]) -> str:
    return (
        '{"artifact_digest":' + _jcs_string(tuple_obj.get("artifact_digest", ""))
        + ',"cache_namespace":' + _jcs_string(tuple_obj.get("cache_namespace", ""))
        + ',"manifest_digest":' + _jcs_string(tuple_obj.get("manifest_digest", ""))
        + ',"model_hash":' + _jcs_string(tuple_obj.get("model_hash", ""))
        + ',"model_hash_algorithm":' + _jcs_string(tuple_obj.get("model_hash_algorithm", ""))
        + ',"model_id":' + _jcs_string(tuple_obj.get("model_id", ""))
        + ',"proposal_depth":' + _jcs_uint(tuple_obj.get("proposal_depth", 0))
        + ',"provider_binary_sha256":' + _jcs_string(tuple_obj.get("provider_binary_sha256", ""))
        + ',"provider_revision":' + _jcs_string(tuple_obj.get("provider_revision", ""))
        + ',"runtime_cdhash":' + _jcs_string(tuple_obj.get("runtime_cdhash", ""))
        + ',"runtime_revision":' + _jcs_string(tuple_obj.get("runtime_revision", ""))
        + ',"sidecar_digest":' + _jcs_string(tuple_obj.get("sidecar_digest", ""))
        + ',"state_digest":' + _jcs_string(tuple_obj.get("state_digest", ""))
        + ',"tokenizer_digest":' + _jcs_string(tuple_obj.get("tokenizer_digest", "")) + '}'
    )


def native_mtp_canary_result_digest(obj: dict[str, Any]) -> str:
    canonical = (
        '{"actual_decode_path":' + _jcs_string(obj.get("actual_decode_path", ""))
        + ',"actual_token_id_sha256":' + _jcs_string(obj.get("actual_token_id_sha256", ""))
        + ',"assigned_id":' + _jcs_string(obj.get("assigned_id", ""))
        + ',"challenge_bank_sha256":' + _jcs_string(obj.get("challenge_bank_sha256", ""))
        + ',"challenge_id":' + _jcs_string(obj.get("challenge_id", ""))
        + ',"committed_state_sha256":' + _jcs_string(obj.get("committed_state_sha256", ""))
        + ',"counters":' + _native_mtp_counters_jcs(obj.get("counters") or {})
        + ',"diagnostic":' + _jcs_string(obj.get("diagnostic", ""))
        + ',"expected_token_id_sha256":' + _jcs_string(obj.get("expected_token_id_sha256", ""))
        + ',"fallback_used":' + _jcs_bool(obj.get("fallback_used", False))
        + ',"native_mtp_runtime_tuple_sha256":' + _jcs_string(obj.get("native_mtp_runtime_tuple_sha256", ""))
        + ',"nonce":' + _jcs_string(obj.get("nonce", ""))
        + ',"provider_id":' + _jcs_string(obj.get("provider_id", ""))
        + ',"provider_revision":' + _jcs_string(obj.get("provider_revision", ""))
        + ',"request_digest":' + _jcs_string(obj.get("request_digest", ""))
        + ',"request_id":' + _jcs_string(obj.get("request_id", ""))
        + ',"runtime_revision":' + _jcs_string(obj.get("runtime_revision", ""))
        + ',"runtime_tuple":' + _native_mtp_runtime_tuple_jcs(obj.get("runtime_tuple") or {})
        + ',"schema_version":"macprovider.native-mtp-canary-result.v1"'
        + ',"target_generation":' + _jcs_uint(obj.get("target_generation", 0))
        + ',"terminal_reason":' + _jcs_string(obj.get("terminal_reason", "")) + '}'
    )
    return hashlib.sha256(("macprovider.native-mtp-canary-result.v1\n" + canonical).encode()).hexdigest()


def _alternate_digest(current: Any) -> str:
    replacement = "0" * 64
    if str(current) == replacement:
        replacement = "1" * 64
    return replacement

def mutate_canary_result(payload: bytes, fault: str) -> tuple[bytes | None, bool]:
    try:
        obj = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return payload, False
    if not isinstance(obj, dict) or obj.get("type") != CANARY_RESULT_TYPE:
        return payload, False
    if fault == "drop":
        return None, True
    if fault == "wrong_digest":
        obj["actual_token_id_sha256"] = _alternate_digest(obj.get("actual_token_id_sha256"))
        obj["result_digest"] = native_mtp_canary_result_digest(obj)
    elif fault == "malformed_digest":
        obj["result_digest"] = _alternate_digest(obj.get("result_digest"))
    elif fault == "actual_path":
        obj["actual_decode_path"] = "ordinary"
        obj["result_digest"] = native_mtp_canary_result_digest(obj)
    elif fault == "fallback":
        obj["actual_decode_path"] = "ordinary"
        obj["fallback_used"] = True
        obj["result_digest"] = native_mtp_canary_result_digest(obj)
    elif fault == "delay":
        obj["result_digest"] = native_mtp_canary_result_digest(obj)
    else:
        raise ValueError(f"unsupported fault {fault!r}")
    return json.dumps(obj, separators=(",", ":"), sort_keys=True).encode("utf-8"), True


class NativeMTPCanaryFaultRelay:
    def __init__(self, cfg: RelayConfig):
        validate_config(cfg)
        self.cfg = cfg
        self.stats = RelayStats()
        self._fault_used = False
        self._server: asyncio.base_events.Server | None = None

    async def serve(self) -> None:
        self._server = await asyncio.start_server(self._handle, self.cfg.listen_host, self.cfg.listen_port)
        self._write_status()
        async with self._server:
            await self._server.serve_forever()

    async def _handle(self, downstream_reader: asyncio.StreamReader, downstream_writer: asyncio.StreamWriter) -> None:
        self.stats.downstream_connections += 1
        upstream_writer: asyncio.StreamWriter | None = None
        try:
            _, downstream_headers = await read_http_headers(downstream_reader)
            await write_server_handshake(downstream_writer, downstream_headers)
            upstream_reader, upstream_writer = await asyncio.open_connection(self.cfg.upstream_host, self.cfg.upstream_port)
            self.stats.upstream_connections += 1
            await write_client_handshake(upstream_reader, upstream_writer, self.cfg, downstream_headers)
            self._write_status()
            await asyncio.gather(
                self._relay_provider_to_coordinator(downstream_reader, upstream_writer),
                self._relay_coordinator_to_provider(upstream_reader, downstream_writer),
            )
        except (asyncio.IncompleteReadError, ConnectionError, OSError):
            pass
        except Exception as exc:  # status only, no secrets/raw frames
            self.stats.last_error = type(exc).__name__
            self._write_status()
        finally:
            if upstream_writer is not None:
                upstream_writer.close()
                await upstream_writer.wait_closed()
            downstream_writer.close()
            await downstream_writer.wait_closed()

    async def _relay_provider_to_coordinator(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        while True:
            frame = await read_frame(reader, self.cfg.max_frame_bytes)
            self.stats.frames_provider_to_coordinator += 1
            self.stats.bytes_provider_to_coordinator += len(frame.payload)
            raw = frame.raw
            if frame.fin and frame.opcode == 1 and (not self.cfg.once or not self._fault_used):
                mutated, matched = mutate_canary_result(frame.payload, self.cfg.fault)
                if matched:
                    self.stats.canary_results_seen += 1
                    self.stats.last_fault = self.cfg.fault
                    self._fault_used = True
                    if self.cfg.fault == "delay" and self.cfg.delay_seconds:
                        await asyncio.sleep(self.cfg.delay_seconds)
                    if mutated is None:
                        self.stats.canary_results_dropped += 1
                        self.stats.canary_results_faulted += 1
                        self._write_status()
                        continue
                    raw = encode_frame(mutated, opcode=frame.opcode, mask=True, fin=frame.fin)
                    self.stats.canary_results_faulted += 1
                    self._write_status()
            writer.write(raw)
            await writer.drain()

    async def _relay_coordinator_to_provider(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        while True:
            frame = await read_frame(reader, self.cfg.max_frame_bytes)
            self.stats.frames_coordinator_to_provider += 1
            self.stats.bytes_coordinator_to_provider += len(frame.payload)
            writer.write(frame.raw)
            await writer.drain()

    def _write_status(self) -> None:
        if not self.cfg.status_path:
            return
        data = json.dumps(self.stats.sanitized(), indent=2, sort_keys=True) + "\n"
        tmp = self.cfg.status_path.with_suffix(self.cfg.status_path.suffix + ".tmp")
        tmp.write_text(data)
        os.replace(tmp, self.cfg.status_path)


def parse_args(argv: list[str] | None = None) -> RelayConfig:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n", 1)[0])
    parser.add_argument("--listen-host", default="127.0.0.1")
    parser.add_argument("--listen-port", type=int, required=True)
    parser.add_argument("--upstream-url", required=True)
    parser.add_argument("--fault", choices=sorted(VALID_FAULTS), required=True)
    parser.add_argument("--delay-seconds", type=float, default=0.0)
    parser.add_argument("--max-frame-bytes", type=int, default=DEFAULT_MAX_FRAME_BYTES)
    parser.add_argument("--all", dest="once", action="store_false", help="fault every matching canary result instead of only the first")
    parser.add_argument("--status-path", type=Path)
    args = parser.parse_args(argv)
    cfg = RelayConfig(
        listen_host=args.listen_host,
        listen_port=args.listen_port,
        upstream_url=args.upstream_url,
        fault=args.fault,
        delay_seconds=args.delay_seconds,
        max_frame_bytes=args.max_frame_bytes,
        once=args.once,
        status_path=args.status_path,
    )
    validate_config(cfg)
    return cfg


async def amain(argv: list[str] | None = None) -> int:
    cfg = parse_args(argv)
    relay = NativeMTPCanaryFaultRelay(cfg)
    loop = asyncio.get_running_loop()
    stop = asyncio.Event()
    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, stop.set)
        except NotImplementedError:
            pass
    task = asyncio.create_task(relay.serve())
    await stop.wait()
    task.cancel()
    try:
        await task
    except asyncio.CancelledError:
        pass
    relay._write_status()
    return 0


def main(argv: list[str] | None = None) -> int:
    return asyncio.run(amain(argv))


if __name__ == "__main__":
    raise SystemExit(main())
