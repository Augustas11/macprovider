#!/usr/bin/env python3
"""Fixed-latency TCP relay between the lab provider CLI and the lab
coordinator provider port (the provider WebSocket).

  latency_proxy.py LISTEN_PORT UPSTREAM_PORT ONE_WAY_MS LOG_JSONL

Every byte read from either side is written to the other side ONE_WAY_MS
later, in order, so the path has a round-trip time of 2 x ONE_WAY_MS with no
bandwidth limit. That reproduces the production provider<->coordinator RTT
(Studio <-> NYC, ~220 ms), under which a coordinator that retires a request
on buyer disconnect still has CLI chunks in flight. The lab RTT is ~0 without
it. It logs connection open/close and byte counts only, never payloads.
Binds 127.0.0.1; lab ports only.
"""
import asyncio
import json
import sys
import time

LISTEN, UPSTREAM, DELAY_MS, LOG = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
for port in (LISTEN, UPSTREAM):
    if not 19100 <= port <= 19199:
        sys.exit(f"refusing non-lab port {port}")
DELAY = DELAY_MS / 1000.0


def log(entry):
    entry["ts"] = time.time()
    with open(LOG, "a") as f:
        f.write(json.dumps(entry, sort_keys=True) + "\n")


async def pipe(reader, writer, counter, key):
    """Copy reader -> writer, delaying each read by DELAY, preserving order."""
    loop = asyncio.get_running_loop()
    queue = asyncio.Queue()

    async def pump():
        while True:
            item = await queue.get()
            if item is None:
                break
            due, data = item
            wait = due - loop.time()
            if wait > 0:
                await asyncio.sleep(wait)
            writer.write(data)
            await writer.drain()
        if writer.can_write_eof():
            writer.write_eof()

    task = asyncio.create_task(pump())
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            counter[key] += len(data)
            queue.put_nowait((loop.time() + DELAY, data))
    finally:
        queue.put_nowait(None)
        await task


async def handle(client_reader, client_writer):
    counter = {"up": 0, "down": 0}
    peer = client_writer.get_extra_info("peername")
    try:
        up_reader, up_writer = await asyncio.open_connection("127.0.0.1", UPSTREAM)
    except OSError as err:
        log({"event": "upstream_connect_failed", "error": str(err)})
        client_writer.close()
        return
    log({"event": "open", "peer_port": peer[1] if peer else None, "one_way_ms": DELAY_MS})
    try:
        await asyncio.gather(pipe(client_reader, up_writer, counter, "up"), pipe(up_reader, client_writer, counter, "down"))
    except (ConnectionError, OSError) as err:
        log({"event": "error", "error": type(err).__name__})
    finally:
        for w in (up_writer, client_writer):
            w.close()
        log({"event": "close", "peer_port": peer[1] if peer else None, "bytes": counter})


async def main():
    server = await asyncio.start_server(handle, "127.0.0.1", LISTEN)
    log({"event": "listen", "listen": LISTEN, "upstream": UPSTREAM, "one_way_ms": DELAY_MS})
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
