#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

PORT="${MACPROVIDER_PORT:-18094}"
WS_PORT="${MACPROVIDER_COORDINATOR_PORT:-18121}"
build_binary

PRODUCTS_DIR="$PRODUCTS_DIR" BINARY="$BINARY" MODEL="$MODEL" PORT="$PORT" WS_PORT="$WS_PORT" python3 - <<'PY'
import asyncio
import base64
import hashlib
import json
import os
import struct
import subprocess
import urllib.request

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
    mask = await reader.readexactly(4) if b2 & 0x80 else b""
    payload = await reader.readexactly(length)
    if mask:
        payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
    return json.loads(payload.decode()) if opcode == 1 else {"type": "__ignored__"}


def frame_text(payload):
    data = json.dumps(payload).encode()
    return bytes([0x81, len(data)]) + data


async def send(writer, payload):
    writer.write(frame_text(payload))
    await writer.drain()


async def handle(reader, writer):
    request = await reader.readuntil(b"\r\n\r\n")
    headers = dict(line.split(": ", 1) for line in request.decode().split("\r\n")[1:] if ": " in line)
    accept = base64.b64encode(hashlib.sha1((headers["Sec-WebSocket-Key"] + GUID).encode()).digest()).decode()
    writer.write(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                  f"Sec-WebSocket-Accept: {accept}\r\n\r\n").encode())
    await writer.drain()
    await read_frame(reader)
    await send(writer, {"type": "hello_ack", "coordinator_version": 1, "assigned_id": "mock-provider", "heartbeat_interval_s": 1})
    while True:
        message = await asyncio.wait_for(read_frame(reader), timeout=20)
        if message["type"] == "state_update" and message["state"] == "ready":
            break
    await send(writer, {"type": "warm_up"})
    states = []
    while "degraded" not in states or states[-1] != "ready":
        message = await asyncio.wait_for(read_frame(reader), timeout=20)
        if message["type"] == "state_update":
            states.append(message["state"])
    body = json.dumps({"model": MODEL, "stream": False, "messages": [{"role": "user", "content": "Reply with ok."}], "max_tokens": 8}).encode()
    req = urllib.request.Request(f"http://127.0.0.1:{PORT}/v1/chat/completions", data=body, headers={"content-type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as response:
        data = json.loads(response.read().decode())
    assert response.status == 200, data
    await send(writer, {"type": "drain"})
    while True:
        message = await asyncio.wait_for(read_frame(reader), timeout=8)
        if message["type"] == "drain_status" and message.get("phase") == "complete":
            break
    print(json.dumps({"ok": True, "states": states}))
    writer.close()
    await writer.wait_closed()
    asyncio.get_running_loop().stop()


async def main():
    server = await asyncio.start_server(handle, "127.0.0.1", WS_PORT)
    env = os.environ.copy()
    env["DYLD_FRAMEWORK_PATH"] = f"{PRODUCTS}/PackageFrameworks:{PRODUCTS}"
    process = subprocess.Popen([BINARY, "--port", PORT, "--model", MODEL, "--coordinator", f"ws://127.0.0.1:{WS_PORT}"], cwd="/private/tmp", env=env)
    try:
        async with server:
            await server.serve_forever()
    finally:
        if process.poll() is None:
            process.terminate()
    if process.wait(timeout=10) != 0:
        raise SystemExit("provider exited nonzero")


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except RuntimeError as exc:
        if "Event loop stopped" not in str(exc):
            raise
PY
