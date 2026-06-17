#!/usr/bin/env python3
"""
Local mock LLM server for smoke-testing sweep.py.

Serves /v1/chat/completions with fake SSE streaming. Does NOT forward to any
remote host — safe to hammer repeatedly without network impact.

Usage:
    python beta/mock_llm_server.py [--port 18080] [--error-rate 0.0]

--error-rate 0.25 causes 25% of requests to return HTTP 500, which exercises
the sweep gate's "red path" (n_err > 0 -> feasible=0).

The server echoes a short canned response and includes usage counts derived
from the prompt length so TTFT/throughput metrics are populated realistically.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import random
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

# Approximate tokens: 4 chars per token heuristic (good enough for smoke-tests)
def _approx_tokens(text: str) -> int:
    return max(1, len(text) // 4)


CANNED_REPLY = (
    "The colony scouts returned with reports. The seasonal rhythm continues "
    "as documented. Humidity levels are nominal in the fungus gardens."
)


class Handler(BaseHTTPRequestHandler):
    error_rate: float = 0.0

    def log_message(self, fmt, *args):
        sys.stderr.write("[mock-llm] " + fmt % args + "\n")

    def do_GET(self):
        if self.path == "/v1/models":
            body = json.dumps({
                "object": "list",
                "data": [{"id": "mlx-community/Llama-3.2-3B-Instruct-4bit", "object": "model"}],
            }).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        if self.path != "/v1/chat/completions":
            self.send_response(404)
            self.end_headers()
            return

        length = int(self.headers.get("Content-Length", "0"))
        try:
            req = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            self.send_response(400)
            self.end_headers()
            return

        # Simulate errors at configured rate
        if random.random() < self.error_rate:
            body = b'{"error": "simulated server error"}'
            self.send_response(500)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        messages = req.get("messages", [])
        prompt_text = " ".join(
            m.get("content", "") for m in messages if isinstance(m.get("content"), str)
        )
        prompt_tokens = _approx_tokens(prompt_text)
        max_tokens = req.get("max_tokens", 64)
        # Reply tokens: min(max_tokens, len(canned reply) / 4)
        completion_tokens = min(max_tokens, _approx_tokens(CANNED_REPLY))
        model = req.get("model", "mlx-community/Llama-3.2-3B-Instruct-4bit")

        is_stream = req.get("stream", False)

        if is_stream:
            self._respond_stream(model, prompt_tokens, completion_tokens, max_tokens)
        else:
            self._respond_nonstream(model, prompt_tokens, completion_tokens)

    def _respond_stream(self, model: str, prompt_tokens: int, completion_tokens: int, max_tokens: int) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        # Do NOT set Transfer-Encoding: chunked — BaseHTTPRequestHandler is not a
        # true chunked encoder; setting the header but not encoding the body causes
        # InvalidChunkLength on the client side. SSE works fine without it.
        self.end_headers()

        # Emit a small TTFT delay to simulate real prefill
        time.sleep(0.05)

        words = CANNED_REPLY.split()
        words_to_emit = words[:completion_tokens]

        for i, word in enumerate(words_to_emit):
            piece = word + (" " if i < len(words_to_emit) - 1 else "")
            chunk = {
                "id": "mock-1",
                "object": "chat.completion.chunk",
                "model": model,
                "choices": [{"index": 0, "delta": {"content": piece}, "finish_reason": None}],
            }
            line = "data: " + json.dumps(chunk) + "\n\n"
            try:
                self.wfile.write(line.encode())
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                return

        # Usage chunk (mlx_lm.server sends usage in the final chunk)
        usage_chunk = {
            "id": "mock-1",
            "object": "chat.completion.chunk",
            "model": model,
            "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
            "usage": {
                "prompt_tokens": prompt_tokens,
                "completion_tokens": completion_tokens,
                "total_tokens": prompt_tokens + completion_tokens,
            },
        }
        try:
            self.wfile.write(("data: " + json.dumps(usage_chunk) + "\n\n").encode())
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _respond_nonstream(self, model: str, prompt_tokens: int, completion_tokens: int) -> None:
        body = json.dumps({
            "id": "mock-1",
            "object": "chat.completion",
            "model": model,
            "choices": [{
                "index": 0,
                "message": {"role": "assistant", "content": CANNED_REPLY},
                "finish_reason": "stop",
            }],
            "usage": {
                "prompt_tokens": prompt_tokens,
                "completion_tokens": completion_tokens,
                "total_tokens": prompt_tokens + completion_tokens,
            },
        }).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main() -> None:
    ap = argparse.ArgumentParser(description="Local mock LLM server for sweep smoke-tests")
    ap.add_argument("--port", type=int, default=18080)
    ap.add_argument(
        "--error-rate", type=float, default=0.0,
        help="Fraction of requests that return HTTP 500 (0.0–1.0). Use >0 to exercise the red path.",
    )
    args = ap.parse_args()

    Handler.error_rate = args.error_rate

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"[mock-llm] listening on http://127.0.0.1:{args.port}")
    print(f"[mock-llm] error_rate={args.error_rate:.0%}")
    print("[mock-llm] Ctrl+C to stop")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.shutdown()


if __name__ == "__main__":
    main()
