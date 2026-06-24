#!/usr/bin/env python3
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        return

    def do_POST(self):
        length = int(self.headers.get("content-length", "0"))
        body = self.rfile.read(length)
        try:
            req = json.loads(body or b"{}")
        except json.JSONDecodeError:
            self.send_error(400)
            return
        if self.path != "/v1/chat/completions":
            self.send_error(404)
            return
        if req.get("stream") is True:
            chunks = [
                'data: {"id":"chatcmpl_spec015_stream","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":null}]}\n\n',
                'data: {"id":"chatcmpl_spec015_stream","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\n',
                'data: [DONE]\n\n',
            ]
            payload = ''.join(chunks).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        payload = json.dumps({
            "id": "chatcmpl_spec015_nonstream",
            "object": "chat.completion",
            "created": 1800000000,
            "model": req.get("model", "llama-3.2-3b-instruct"),
            "choices": [{"index": 0, "message": {"role": "assistant", "content": "ok"}, "finish_reason": "stop"}],
            "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
        }).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("X-MacProvider-Receipt", "tuple.signature")
        self.end_headers()
        self.wfile.write(payload)

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(f"http://127.0.0.1:{server.server_address[1]}", flush=True)
try:
    server.serve_forever()
except KeyboardInterrupt:
    pass
