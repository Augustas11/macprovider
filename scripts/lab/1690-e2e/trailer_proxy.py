#!/usr/bin/env python3
"""Fault proxy between the lab gateway and the lab coordinator buyer port.

  trailer_proxy.py LISTEN_PORT UPSTREAM_PORT MODE_FILE LOG_JSONL

Relays HTTP/1.1 byte-for-byte (one request per connection; it answers with
Connection: close) and, for /v1/chat/completions, applies the mode named in
MODE_FILE (re-read per request; missing file = pass):

  pass               relay unchanged
  strip_capability   drop X-MacProvider-Internal-Settlement-Trailers from the
                     request, so the coordinator never negotiates
  strip_trailers     keep the Trailer declaration, drop every trailer field
  strip_decl         drop the Trailer declaration header and every trailer
                     field (a proxy that does not forward trailers)
  strip_mac          drop only the X-MacProvider-Settlement-Finality-Mac
                     field (trailer or header) and its declaration
  tamper_mac         flip one hex digit of the finality MAC (trailer or header)
  tamper_outcome     rewrite X-MacProvider-Settlement-Outcome (trailer or
                     header) to "refunded" and leave the MAC as sent

It logs, per chat request, the mode, status, the Trailer declaration, the
names of the settlement fields seen in headers and trailers, and what it
changed. It never logs values (the MAC is keyed by the service token).
Binds 127.0.0.1 only; lab ports only.
"""
import json
import os
import socket
import sys
import threading
import time

LISTEN, UPSTREAM, MODE_FILE, LOG = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3], sys.argv[4]
for port in (LISTEN, UPSTREAM):
    if not 19100 <= port <= 19199:
        sys.exit(f"refusing non-lab port {port}")
LOCK = threading.Lock()
CAP = b"x-macprovider-internal-settlement-trailers"
MAC = b"x-macprovider-settlement-finality-mac"
OUTCOME = b"x-macprovider-settlement-outcome"
PREFIX = b"x-macprovider-settlement-"


def mode():
    try:
        return open(MODE_FILE).read().strip() or "pass"
    except OSError:
        return "pass"


def log(entry):
    with LOCK, open(LOG, "a") as f:
        f.write(json.dumps(entry, sort_keys=True) + "\n")


class Reader:
    def __init__(self, sock):
        self.sock, self.buf = sock, b""

    def fill(self):
        data = self.sock.recv(65536)
        if not data:
            raise EOFError
        self.buf += data

    def line(self):
        while b"\r\n" not in self.buf:
            self.fill()
        i = self.buf.index(b"\r\n")
        out, self.buf = self.buf[:i], self.buf[i + 2:]
        return out

    def exact(self, n):
        while len(self.buf) < n:
            self.fill()
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def rest(self):
        out, self.buf = self.buf, b""
        try:
            while True:
                data = self.sock.recv(65536)
                if not data:
                    return out
                out += data
        except OSError:
            return out


def read_head(r):
    first = r.line()
    headers = []
    while True:
        line = r.line()
        if not line:
            return first, headers
        k, _, v = line.partition(b":")
        headers.append([k.strip(), v.strip()])


def hget(headers, name):
    return [v for k, v in headers if k.lower() == name]


def hdrop(headers, pred):
    return [[k, v] for k, v in headers if not pred(k.lower())]


def flip(v):
    if not v:
        return v
    c = v[-1:]
    return v[:-1] + (b"0" if c != b"0" else b"1")


def mutate_fields(fields, m, changed, where):
    """Apply a mutation to settlement fields in a header or trailer list."""
    out = []
    for k, v in fields:
        lk = k.lower()
        if m == "strip_mac" and lk == MAC:
            changed.append(f"{where}:drop_mac")
            continue
        if m == "tamper_mac" and lk == MAC:
            changed.append(f"{where}:flip_mac")
            v = flip(v)
        if m == "tamper_outcome" and lk == OUTCOME:
            changed.append(f"{where}:outcome_refunded")
            v = b"refunded"
        out.append([k, v])
    return out


def send_head(sock, first, headers):
    sock.sendall(first + b"\r\n" + b"".join(k + b": " + v + b"\r\n" for k, v in headers) + b"\r\n")


def handle(client):
    up = None
    try:
        cr = Reader(client)
        first, headers = read_head(cr)
        path = first.split(b" ")[1] if b" " in first else b""
        chat = path.startswith(b"/v1/chat/completions")
        m = mode() if chat else "pass"
        entry = {"ts": time.time(), "path": path.decode(errors="replace"), "mode": m,
                 "request_id": (hget(headers, b"x-request-id") or [b""])[0].decode(),
                 "capability_sent": bool(hget(headers, CAP)), "changed": []}
        if m == "strip_capability" and hget(headers, CAP):
            headers = hdrop(headers, lambda k: k == CAP)
            entry["changed"].append("request:drop_capability")
        headers = hdrop(headers, lambda k: k in (b"connection", b"keep-alive")) + [[b"Connection", b"close"]]
        te = b"chunked" in b",".join(hget(headers, b"transfer-encoding")).lower()
        up = socket.create_connection(("127.0.0.1", UPSTREAM), timeout=600)
        send_head(up, first, headers)
        if te:
            while True:
                size_line = cr.line()
                size = int(size_line.split(b";")[0], 16)
                up.sendall(size_line + b"\r\n")
                if size == 0:
                    while True:
                        t = cr.line()
                        up.sendall(t + b"\r\n")
                        if not t:
                            break
                    break
                up.sendall(cr.exact(size + 2))
        else:
            n = int((hget(headers, b"content-length") or [b"0"])[0])
            if n:
                up.sendall(cr.exact(n))
        ur = Reader(up)
        status, rheaders = read_head(ur)
        entry["status"] = status.split(b" ")[1].decode() if b" " in status else ""
        decl = b",".join(hget(rheaders, b"trailer"))
        entry["trailer_declared"] = [x.strip().decode() for x in decl.split(b",") if x.strip()]
        entry["settlement_headers"] = sorted(k.decode() for k, _ in rheaders if k.lower().startswith(PREFIX))
        if chat:
            if m in ("strip_decl",):
                rheaders = hdrop(rheaders, lambda k: k == b"trailer")
                entry["changed"].append("header:drop_trailer_declaration")
            if m == "strip_mac":
                new = []
                for k, v in rheaders:
                    if k.lower() == b"trailer":
                        names = [x.strip() for x in v.split(b",") if x.strip() and x.strip().lower() != MAC]
                        if len(names) != len([x for x in v.split(b",") if x.strip()]):
                            entry["changed"].append("header:drop_mac_declaration")
                        if names:
                            new.append([k, b", ".join(names)])
                        continue
                    new.append([k, v])
                rheaders = new
            rheaders = mutate_fields(rheaders, m, entry["changed"], "header")
        rheaders = hdrop(rheaders, lambda k: k in (b"connection", b"keep-alive")) + [[b"Connection", b"close"]]
        chunked = b"chunked" in b",".join(hget(rheaders, b"transfer-encoding")).lower()
        send_head(client, status, rheaders)
        trailers_seen = []
        if chunked:
            while True:
                size_line = ur.line()
                size = int(size_line.split(b";")[0], 16)
                if size == 0:
                    trailers = []
                    while True:
                        t = ur.line()
                        if not t:
                            break
                        k, _, v = t.partition(b":")
                        trailers.append([k.strip(), v.strip()])
                    trailers_seen = sorted(k.decode() for k, _ in trailers)
                    if chat:
                        if m in ("strip_trailers", "strip_decl"):
                            if trailers:
                                entry["changed"].append("trailer:drop_all")
                            trailers = []
                        else:
                            trailers = mutate_fields(trailers, m, entry["changed"], "trailer")
                    client.sendall(b"0\r\n" + b"".join(k + b": " + v + b"\r\n" for k, v in trailers) + b"\r\n")
                    break
                client.sendall(size_line + b"\r\n" + ur.exact(size + 2))
        else:
            n = hget(rheaders, b"content-length")
            if n:
                client.sendall(ur.exact(int(n[0])))
            else:
                client.sendall(ur.rest())
        entry["trailers_seen"] = trailers_seen
        if chat:
            log(entry)
    except (EOFError, OSError, ValueError) as err:
        if "entry" in locals() and chat:
            entry["error"] = type(err).__name__
            log(entry)
    finally:
        for s in (client, up):
            if s is not None:
                try:
                    s.close()
                except OSError:
                    pass


def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", LISTEN))
    srv.listen(64)
    while True:
        c, _ = srv.accept()
        threading.Thread(target=handle, args=(c,), daemon=True).start()


if __name__ == "__main__":
    main()
