#!/usr/bin/env python3
"""Loopback tap between the lab CLI and llama-server that records usage.

  usage_tap.py LISTEN_PORT UPSTREAM_PORT LOG_JSONL [STRIP_FLAG_FILE [SLOW_FLAG_FILE]]

Forwards every request byte-for-byte to 127.0.0.1:UPSTREAM_PORT and streams
the response back. For /v1/chat/completions it appends one JSON line to
LOG_JSONL with the upstream-reported `usage` (the final SSE chunk that
carries it, or the JSON body), whether the request asked for
`stream_options.include_usage`, and the upstream id. No prompt or completion
text is logged. While STRIP_FLAG_FILE exists, `usage` is removed from the
upstream response before the CLI sees it, to stage a runtime that omits usage.
Binds 127.0.0.1 only.
"""
import hashlib
import http.client
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LISTEN, UPSTREAM, LOG = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
STRIP = sys.argv[4] if len(sys.argv) > 4 else None
# While SLOW_FLAG_FILE exists each streamed line is delayed, to hold a request
# open across a staged policy-window boundary.
SLOW = sys.argv[5] if len(sys.argv) > 5 else None
LOCK = threading.Lock()
HOP = {"connection", "keep-alive", "transfer-encoding", "content-length", "proxy-connection", "upgrade", "te", "trailer"}


def record(entry):
    with LOCK, open(LOG, "a") as f:
        f.write(json.dumps(entry, sort_keys=True) + "\n")


class Tap(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _forward(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        chat = self.path.startswith("/v1/chat/completions")
        req = {}
        if chat and body:
            try:
                req = json.loads(body)
            except ValueError:
                req = {}
        strip = bool(STRIP and os.path.exists(STRIP))
        conn = http.client.HTTPConnection("127.0.0.1", UPSTREAM, timeout=600)
        headers = {k: v for k, v in self.headers.items() if k.lower() not in HOP and k.lower() != "host"}
        headers["Host"] = f"127.0.0.1:{UPSTREAM}"
        conn.request(self.command, self.path, body=body, headers=headers)
        resp = conn.getresponse()
        self.send_response(resp.status)
        for k, v in resp.getheaders():
            if k.lower() not in HOP:
                self.send_header(k, v)
        stream = "text/event-stream" in (resp.getheader("Content-Type") or "")
        usage, upstream_id, text = None, None, ""
        if stream:
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            while True:
                line = resp.fp.readline()
                if not line:
                    break
                if line.startswith(b"data: ") and line.strip() != b"data: [DONE]":
                    try:
                        chunk = json.loads(line[6:])
                        upstream_id = chunk.get("id", upstream_id)
                        for ch in chunk.get("choices") or []:
                            text += (ch.get("delta") or {}).get("content") or ""
                        if chunk.get("usage"):
                            usage = chunk["usage"]
                        if strip and "usage" in chunk:
                            chunk.pop("usage")
                            line = b"data: " + json.dumps(chunk).encode() + b"\n"
                    except ValueError:
                        pass
                if SLOW and os.path.exists(SLOW):
                    time.sleep(0.1)
                self.wfile.write(b"%x\r\n%s\r\n" % (len(line), line))
                self.wfile.flush()
            self.wfile.write(b"0\r\n\r\n")
        else:
            data = resp.read()
            if chat:
                try:
                    doc = json.loads(data)
                    usage, upstream_id = doc.get("usage"), doc.get("id")
                    text = ((doc.get("choices") or [{}])[0].get("message") or {}).get("content") or ""
                    if strip and "usage" in doc:
                        doc.pop("usage")
                        data = json.dumps(doc).encode()
                except ValueError:
                    pass
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        conn.close()
        if chat:
            record({"ts": time.time(), "status": resp.status, "stream": stream, "upstream_id": upstream_id,
                    "include_usage_requested": bool((req.get("stream_options") or {}).get("include_usage")),
                    "max_tokens": req.get("max_tokens"), "stripped": strip,
                    "content_sha256": hashlib.sha256(text.encode()).hexdigest()[:16] if text else None,
                    "usage": {k: usage.get(k) for k in ("prompt_tokens", "completion_tokens", "total_tokens")} if usage else None})

    do_GET = do_POST = _forward


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", LISTEN), Tap).serve_forever()
