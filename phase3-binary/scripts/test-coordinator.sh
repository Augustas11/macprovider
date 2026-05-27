#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

PORT="${MACPROVIDER_PORT:-18093}"
WS_PORT="${MACPROVIDER_COORDINATOR_PORT:-18120}"
build_binary

PRODUCTS_DIR="$PRODUCTS_DIR" BINARY="$BINARY" MODEL="$MODEL" PORT="$PORT" WS_PORT="$WS_PORT" python3 - <<'PY'
import asyncio
import base64
import hashlib
import json
import os
import struct
import subprocess

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
PRODUCTS = os.environ["PRODUCTS_DIR"]
BINARY = os.environ["BINARY"]
MODEL = os.environ["MODEL"]
PORT = os.environ["PORT"]
WS_PORT = int(os.environ["WS_PORT"])


async def read_frame(reader):
    first = await reader.readexactly(2)
    b1, b2 = first
    opcode = b1 & 0x0F
    length = b2 & 0x7F
    if length == 126:
        length = struct.unpack("!H", await reader.readexactly(2))[0]
    elif length == 127:
        length = struct.unpack("!Q", await reader.readexactly(8))[0]
    mask = await reader.readexactly(4) if b2 & 0x80 else b""
    payload = await reader.readexactly(length)
    if mask:
        payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
    if opcode == 8:
        return {"type": "__close__"}
    if opcode != 1:
        return {"type": "__ignored__", "opcode": opcode}
    return json.loads(payload.decode())


def frame_text(payload):
    data = json.dumps(payload).encode()
    if len(data) < 126:
        header = bytes([0x81, len(data)])
    else:
        header = bytes([0x81, 126]) + struct.pack("!H", len(data))
    return header + data


async def send(writer, payload):
    writer.write(frame_text(payload))
    await writer.drain()


def require_fields(payload, names):
    missing = set(names) - set(payload)
    assert not missing, (missing, payload)


async def handle(reader, writer):
    request = await reader.readuntil(b"\r\n\r\n")
    headers = {}
    for line in request.decode().split("\r\n")[1:]:
        if ":" in line:
            key, value = line.split(":", 1)
            headers[key.lower()] = value.strip()
    accept = base64.b64encode(hashlib.sha1((headers["sec-websocket-key"] + GUID).encode()).digest()).decode()
    writer.write(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                  f"Sec-WebSocket-Accept: {accept}\r\n\r\n").encode())
    await writer.drain()

    hello = await read_frame(reader)
    require_fields(hello, ["type", "version", "tier", "provider_id", "hostname", "model_id", "model_params_b",
                           "ram_gb", "max_context_tokens", "max_concurrency", "throughput_tps_estimate",
                           "binary_version", "attestation"])
    assert hello["type"] == "hello", hello
    await send(writer, {"type": "hello_ack", "coordinator_version": 1, "assigned_id": "mock-provider", "heartbeat_interval_s": 1})

    seen = [hello["type"]]
    heartbeats = 0
    preflight_sent = False
    drain_sent = False
    while True:
        message = await asyncio.wait_for(read_frame(reader), timeout=20)
        seen.append(message["type"])
        if message["type"] == "heartbeat":
            heartbeats += 1
            require_fields(message, ["type", "status", "model_id", "model_params_b", "ram_gb", "max_context_tokens",
                                     "max_concurrency", "slots_free", "slots_total", "throughput_tps_estimate",
                                     "requests_served_since_last", "avg_latency_ms_since_last",
                                     "throughput_tps_since_last"])
            if heartbeats == 5 and not preflight_sent:
                await send(writer, {"type": "preflight", "request_id": "mock-preflight", "estimated_tokens": 128})
                preflight_sent = True
        elif message["type"] == "preflight_ack":
            assert message["request_id"] == "mock-preflight", message
            assert message["accepted"] is True, message
            await send(writer, {"type": "drain"})
            drain_sent = True
        elif message["type"] == "drain_status" and message.get("phase") == "complete":
            break

    assert heartbeats >= 5 and preflight_sent and drain_sent, seen
    print(json.dumps({"ok": True, "heartbeats": heartbeats, "seen": seen}))
    writer.close()
    await writer.wait_closed()
    asyncio.get_running_loop().stop()


async def main():
    server = await asyncio.start_server(handle, "127.0.0.1", WS_PORT)
    env = os.environ.copy()
    env["DYLD_FRAMEWORK_PATH"] = f"{PRODUCTS}/PackageFrameworks:{PRODUCTS}"
    process = subprocess.Popen(
        [BINARY, "--port", PORT, "--model", MODEL, "--coordinator", f"ws://127.0.0.1:{WS_PORT}"],
        cwd="/private/tmp",
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        async with server:
            await server.serve_forever()
    finally:
        if process.poll() is None:
            process.terminate()
    code = process.wait(timeout=10)
    if code != 0:
        stdout, stderr = process.communicate(timeout=1)
        raise SystemExit(f"provider exited {code}\nSTDOUT:\n{stdout}\nSTDERR:\n{stderr}")


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except RuntimeError as exc:
        if "Event loop stopped" not in str(exc):
            raise
PY
