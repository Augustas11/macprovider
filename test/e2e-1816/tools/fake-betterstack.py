#!/usr/bin/env python3
"""#1816 e2e: stand-in for the Better Stack Uptime heartbeat API the Pearl
updater pauses and restores around an apply
(GET/PATCH https://uptime.betterstack.com/api/v2/heartbeats/<id>). nginx in
the VM terminates TLS for uptime.betterstack.com (test CA) and proxies here.
Every call is appended to the log so a scenario can show the pause/restore.
Usage: fake-betterstack.py PORT LOGFILE"""
import json, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT, LOG = int(sys.argv[1]), sys.argv[2]
state = {"paused": False, "paused_at": None}
lock = threading.Lock()


class H(BaseHTTPRequestHandler):
    def _send(self, code, doc):
        raw = json.dumps(doc).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _doc(self):
        return {"data": {"id": self.path.rsplit("/", 1)[-1], "type": "heartbeat",
                         "attributes": {"status": "paused" if state["paused"] else "up", "paused_at": state["paused_at"]}}}

    def _log(self, extra):
        with open(LOG, "a") as f:
            f.write(json.dumps({"ts": time.time(), "method": self.command, "path": self.path,
                                "auth": bool(self.headers.get("Authorization")), **extra}) + "\n")

    def do_GET(self):
        if not self.path.startswith("/api/v2/heartbeats/"):
            return self._send(404, {"errors": "not found"})
        with lock:
            self._log({"paused": state["paused"]})
            self._send(200, self._doc())

    def do_PATCH(self):
        if not self.path.startswith("/api/v2/heartbeats/"):
            return self._send(404, {"errors": "not found"})
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        with lock:
            if "paused" in body:
                state["paused"] = bool(body["paused"])
                state["paused_at"] = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime()) if state["paused"] else None
            self._log({"body": body})
            self._send(200, self._doc())

    def log_message(self, *_):
        pass


ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
