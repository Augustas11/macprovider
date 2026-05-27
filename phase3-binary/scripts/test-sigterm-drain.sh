#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

PORT="${MACPROVIDER_PORT:-18095}"
WS_PORT="${MACPROVIDER_COORDINATOR_PORT:-18122}"
build_binary

PRODUCTS_DIR="$PRODUCTS_DIR" BINARY="$BINARY" MODEL="$MODEL" PORT="$PORT" WS_PORT="$WS_PORT" python3 - <<'PY'
import asyncio
import base64
import hashlib
import json
import os
import signal
import struct
import subprocess
import threading
import time
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


def stream_request(results, index):
    body = json.dumps({
        "model": MODEL,
        "stream": True,
        "messages": [{"role": "user", "content": "Count from 1 to 40, one number per line."}],
        "max_tokens": 80,
    }).encode()
    req = urllib.request.Request(f"http://127.0.0.1:{PORT}/v1/chat/completions", data=body, headers={"content-type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=120) as response:
            text = response.read().decode()
        results[index] = response.status == 200 and "data: [DONE]" in text
    except Exception:
        results[index] = False


async def handle(reader, writer):
    request = await reader.readuntil(b"\r\n\r\n")
    headers = {}
    for line in request.decode().split("\r\n")[1:]:
        if ":" in line:
            k, v = line.split(":", 1)
            headers[k.lower()] = v.strip()
    accept = base64.b64encode(hashlib.sha1((headers["sec-websocket-key"] + GUID).encode()).digest()).decode()
    writer.write(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                  f"Sec-WebSocket-Accept: {accept}\r\n\r\n").encode())
    await writer.drain()
    await read_frame(reader)
    await send(writer, {"type": "hello_ack", "coordinator_version": 1, "assigned_id": "mock-provider", "heartbeat_interval_s": 1})
    while True:
        message = await asyncio.wait_for(read_frame(reader), timeout=30)
        if message["type"] == "heartbeat":
            break
    results = [None, None, None]
    threads = [threading.Thread(target=stream_request, args=(results, i)) for i in range(3)]
    for thread in threads:
        thread.start()
    time.sleep(1)
    os.kill(PROCESS.pid, signal.SIGTERM)
    phases = []
    while "complete" not in phases:
        message = await asyncio.wait_for(read_frame(reader), timeout=40)
        if message["type"] == "drain_status":
            phases.append(message["phase"])
    for thread in threads:
        thread.join(timeout=130)
    assert all(results), results
    print(json.dumps({"ok": True, "phases": phases, "streams_completed": results}))
    writer.close()
    await writer.wait_closed()
    asyncio.get_running_loop().stop()


async def main():
    global PROCESS
    server = await asyncio.start_server(handle, "127.0.0.1", WS_PORT)
    env = os.environ.copy()
    env["DYLD_FRAMEWORK_PATH"] = f"{PRODUCTS}/PackageFrameworks:{PRODUCTS}"
    PROCESS = subprocess.Popen([BINARY, "--port", PORT, "--model", MODEL, "--coordinator", f"ws://127.0.0.1:{WS_PORT}"], cwd="/private/tmp", env=env)
    async with server:
        await server.serve_forever()
    if PROCESS.wait(timeout=10) != 0:
        raise SystemExit("provider exited nonzero")


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except RuntimeError as exc:
        if "Event loop stopped" not in str(exc):
            raise
PY
