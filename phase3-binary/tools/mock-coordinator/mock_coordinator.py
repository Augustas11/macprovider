#!/usr/bin/env python3
import argparse
import asyncio
import json
import sys
import time

try:
    import websockets
except ImportError:
    print("SKIP: Python package 'websockets' is required for mock coordinator AC tests", file=sys.stderr)
    sys.exit(77)


def request_body(model, stream, prompt, max_tokens=24):
    return json.dumps(
        {
            "model": model,
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": max_tokens,
            "stream": stream,
        },
        separators=(",", ":"),
    )


async def recv_json(ws, timeout=120):
    raw = await asyncio.wait_for(ws.recv(), timeout=timeout)
    return json.loads(raw)


async def expect_hello(ws):
    hello = await recv_json(ws, timeout=30)
    if hello.get("type") != "hello":
        raise AssertionError(f"expected hello, got {hello}")
    await ws.send(
        json.dumps(
            {
                "type": "hello_ack",
                "coordinator_version": 1,
                "assigned_id": "mock-session",
                "heartbeat_interval_s": 1,
                "tier": "provisional",
                "recommended_binary_version": "1.2.1",
            }
        )
    )


async def collect_until_end(ws, request_ids, cancel_after_chunks=None):
    chunks = {request_id: [] for request_id in request_ids}
    ended = {}
    cancelled = False
    deadline = time.monotonic() + 180
    while set(ended) != set(request_ids):
        if time.monotonic() > deadline:
            raise AssertionError(f"timed out waiting for response_end; ended={ended}")
        message = await recv_json(ws, timeout=30)
        message_type = message.get("type")
        request_id = message.get("request_id")
        if message_type == "heartbeat" or message_type == "state_update":
            continue
        if message_type == "inference_response_chunk":
            chunks.setdefault(request_id, []).append(message)
            if cancel_after_chunks and not cancelled and len(chunks.get(request_id, [])) >= cancel_after_chunks:
                await ws.send(json.dumps({"type": "cancel_request", "request_id": request_id, "reason": "buyer_disconnected"}))
                cancelled = True
        elif message_type == "inference_response_end":
            ended[request_id] = message
        elif message_type == "nak":
            ended[request_id or "nak"] = message
        else:
            raise AssertionError(f"unexpected message: {message}")
    return chunks, ended


async def run_scenario(ws, scenario, model):
    await expect_hello(ws)
    if scenario == "nonstream":
        request_id = "req-ac11"
        await ws.send(json.dumps({"type": "inference_request", "request_id": request_id, "stream": False, "body": request_body(model, False, "Reply with one short sentence.")}))
        chunks, ended = await collect_until_end(ws, [request_id])
        assert len(chunks[request_id]) == 1, chunks
        assert ended[request_id].get("status") == "complete", ended
    elif scenario == "stream":
        request_id = "req-ac12"
        await ws.send(json.dumps({"type": "inference_request", "request_id": request_id, "stream": True, "body": request_body(model, True, "Count from one to five.", 32)}))
        chunks, ended = await collect_until_end(ws, [request_id])
        seqs = [chunk.get("seq") for chunk in chunks[request_id]]
        assert seqs == list(range(len(seqs))), seqs
        assert len(chunks[request_id]) >= 2, chunks
        assert ended[request_id].get("status") == "complete", ended
    elif scenario == "multiplex":
        ids = ["req-ac13-a", "req-ac13-b", "req-ac13-c"]
        for request_id in ids:
            await ws.send(json.dumps({"type": "inference_request", "request_id": request_id, "stream": True, "body": request_body(model, True, f"Say hello for {request_id}.", 16)}))
        chunks, ended = await collect_until_end(ws, ids)
        assert all(ended[request_id].get("status") == "complete" for request_id in ids), ended
        assert all(chunks[request_id] for request_id in ids), chunks
    elif scenario == "cancel":
        request_id = "req-ac14"
        await ws.send(json.dumps({"type": "inference_request", "request_id": request_id, "stream": True, "body": request_body(model, True, "Write a long paragraph slowly.", 128)}))
        _, ended = await collect_until_end(ws, [request_id], cancel_after_chunks=2)
        assert ended[request_id].get("status") == "cancelled", ended
    elif scenario == "nak":
        request_id = "req-ac15"
        await ws.send(json.dumps({"type": "inference_request", "request_id": request_id, "stream": False, "body": request_body(model, False, "Hello", 4)}))
        while True:
            message = await recv_json(ws, timeout=30)
            if message.get("type") in ("heartbeat", "state_update"):
                continue
            assert message.get("type") == "nak", message
            assert message.get("error", {}).get("code") == "unknown_message_type", message
            return
    else:
        raise AssertionError(f"unknown scenario {scenario}")


async def main_async(args):
    done = asyncio.Future()

    async def handler(ws):
        try:
            await run_scenario(ws, args.scenario, args.model)
            done.set_result(True)
        except Exception as exc:
            if not done.done():
                done.set_exception(exc)
            raise

    async with websockets.serve(handler, "127.0.0.1", args.port):
        await asyncio.wait_for(done, timeout=args.timeout)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--scenario", required=True, choices=["nonstream", "stream", "multiplex", "cancel", "nak"])
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--timeout", type=int, default=240)
    args = parser.parse_args()
    asyncio.run(main_async(args))


if __name__ == "__main__":
    main()
