#!/usr/bin/env python3
"""Loopback stand-in for the coordinator, gateway and provider status used by
scripts/ops/test-entrypoints.sh. Usage: fake_services.py STATE_DIR (prints the port).

Files in STATE_DIR steer it:
  healthz.json            coordinator/gateway /healthz body
  autotune-release.json   /v1/autotune-release body (404 when absent)
  status.json             provider /v1/status base body
  metrics.txt             coordinator /metrics body (404 when absent)
  mode                    gateway behaviour: move | stuck | serial-request |
                          no-request-id | no-provider-id | other-provider
  provider_id             X-Provider-Id the gateway reports (unless the mode drops it)
  served                  number of completions served (written here)
"""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

state = sys.argv[1]


def read(name, default=None):
    path = os.path.join(state, name)
    if not os.path.exists(path):
        return default
    return open(path).read().strip()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send(self, code, body, headers=None):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/healthz":
            return self.send(200, read("healthz.json", "{}"))
        if self.path == "/v1/autotune-release" and read("autotune-release.json"):
            return self.send(200, read("autotune-release.json"))
        if self.path == "/metrics" and read("metrics.txt") is not None:
            return self.send(200, read("metrics.txt") + "\n")
        if self.path == "/v1/status":
            d = json.loads(read("status.json", "{}"))
            served = int(read("served", "0"))
            mode = read("mode", "move")
            if mode in ("move", "other-provider", "no-provider-id"):
                d.setdefault("native_mtp", {})["mtp_forwards"] = d.get("native_mtp", {}).get("mtp_forwards", 0) + served
                d["requests_total"] = d.get("requests_total", 0) + served
                cb = d.setdefault("continuous_batching", {})
                scheduler = cb.setdefault("scheduler", {})
                scheduler["shared_forward_calls"] = scheduler.get("shared_forward_calls", 0) + served
            elif mode == "serial-request":
                d["requests_total"] = d.get("requests_total", 0) + served
            return self.send(200, json.dumps(d))
        return self.send(404, '{"error": "not_found"}')

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        self.rfile.read(length)
        if self.path != "/v1/chat/completions":
            return self.send(404, "{}")
        if self.headers.get("Authorization") != "Bearer test-buyer-token":
            return self.send(401, '{"error": "unauthorized"}')
        served = int(read("served", "0")) + 1
        open(os.path.join(state, "served"), "w").write(str(served))
        headers = {}
        mode = read("mode", "move")
        if mode != "no-request-id":
            headers["X-Request-ID"] = self.headers.get("X-Request-ID") or "gw-generated"
        if mode == "other-provider":
            headers["X-Provider-Id"] = "some-other-provider"
        elif mode != "no-provider-id":
            headers["X-Provider-Id"] = read("provider_id", "")
        body = {"id": "chatcmpl-test", "choices": [{"message": {"role": "assistant", "content": "ok"}}]}
        return self.send(200, json.dumps(body), headers)


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
open(os.path.join(state, "port"), "w").write(str(server.server_address[1]))
server.serve_forever()
