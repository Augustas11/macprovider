"""
v0 "seeing is believing" web demo for the Phase 2 macprovider PoC.

Run:
    python beta/demo_server.py

Then open http://localhost:8765 in a browser.

Lets a user send a prompt to either M1 or M4 through the same Cloudflare
tunnel the harness already uses, and watch tokens stream back alongside a
receipt panel proving which Mac answered. No new endpoint required — this
proxies to /v1/chat/completions on the configured tunnel_url.

Why a proxy and not direct fetch from the browser:
mlx_lm.server doesn't ship with permissive CORS, so a browser hitting
m1.malibu.tech directly would be blocked. The proxy is server-to-server,
so the browser only ever talks to localhost.
"""

import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import requests
import yaml

BETA_DIR = Path(__file__).parent
HTML_PATH = BETA_DIR / "demo.html"

PROVIDERS: dict[str, dict] = {}
for tag, cfg_path in [("m1", BETA_DIR / "config-m1.yaml"), ("m4", BETA_DIR / "config-m4.yaml")]:
    with open(cfg_path) as f:
        cfg = yaml.safe_load(f)
    PROVIDERS[tag] = {
        "tunnel_url": cfg["tunnel_url"].rstrip("/"),
        "model": cfg["model"],
        "timeout_s": cfg.get("timeout_s", 180),
    }


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stderr.write("[demo] " + fmt % args + "\n")

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            html = HTML_PATH.read_bytes()
            self._send_bytes(200, "text/html; charset=utf-8", html)
        elif self.path == "/providers":
            body = json.dumps(PROVIDERS).encode()
            self._send_bytes(200, "application/json", body)
        else:
            self.send_response(404)
            self.end_headers()

    def _send_bytes(self, status: int, ctype: str, body: bytes) -> None:
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path != "/chat":
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

        provider = req.get("provider", "m1")
        prompt = (req.get("prompt") or "").strip()
        if provider not in PROVIDERS or not prompt:
            self.send_response(400)
            self.end_headers()
            return

        p = PROVIDERS[provider]
        url = p["tunnel_url"] + "/v1/chat/completions"
        payload = {
            "model": p["model"],
            "stream": True,
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": int(req.get("max_tokens", 512)),
            "temperature": float(req.get("temperature", 0.7)),
        }

        try:
            upstream = requests.post(url, json=payload, stream=True, timeout=p["timeout_s"])
        except requests.RequestException as e:
            self._send_bytes(502, "text/plain", f"upstream error: {e}".encode())
            return

        self.send_response(upstream.status_code)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("X-Provider", provider)
        self.send_header("X-Provider-Tunnel", p["tunnel_url"])
        self.send_header("X-Provider-Model", p["model"])
        self.end_headers()
        try:
            for chunk in upstream.iter_content(chunk_size=None):
                if not chunk:
                    continue
                self.wfile.write(chunk)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass


def main():
    host, port = "127.0.0.1", 8765
    server = ThreadingHTTPServer((host, port), Handler)
    print(f"\n  Demo running at http://{host}:{port}/")
    print(f"  Providers loaded:")
    for tag, p in PROVIDERS.items():
        print(f"    {tag}: {p['tunnel_url']} ({p['model']})")
    print("\n  Open the URL in a browser. Ctrl+C to stop.\n")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.shutdown()


if __name__ == "__main__":
    main()
