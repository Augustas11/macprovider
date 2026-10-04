#!/usr/bin/env python3
"""#1816 e2e: steady buyer traffic through nginx while something changes
underneath (an updater apply, a manifest rotation). One request at a time
every --interval seconds until --stop-file exists or --duration passes.
Writes loadgen-compatible JSON lines (rid, run, kind, status, t0, t1) so the
shared oracle can join them.
Usage: probe-loop.py --run RUN --out FILE --model M [--stream] [--header N:V]
                     [--interval S] [--duration S] [--stop-file F]"""
import argparse, http.client, json, os, ssl, time, uuid

ap = argparse.ArgumentParser()
ap.add_argument("--run", required=True)
ap.add_argument("--out", required=True)
ap.add_argument("--model", required=True)
ap.add_argument("--stream", action="store_true")
ap.add_argument("--header", action="append", default=[])
ap.add_argument("--interval", type=float, default=0.5)
ap.add_argument("--duration", type=float, default=3600)
ap.add_argument("--stop-file")
ap.add_argument("--key-file", default="/root/e2e/buyer-api-key")
a = ap.parse_args()
key = open(a.key_file).read().strip()
ctx = ssl.create_default_context()
extra = dict(h.split(":", 1) for h in a.header)
kind = "st" if a.stream else "ns"
end = time.time() + a.duration
with open(a.out, "a") as f:
    while time.time() < end and not (a.stop_file and os.path.exists(a.stop_file)):
        rid = str(uuid.uuid4())
        rec = {"rid": rid, "run": a.run, "kind": kind, "t0": time.time()}
        try:
            c = http.client.HTTPSConnection("api.malibu.tech", 443, timeout=60, context=ctx)
            body = json.dumps({"model": a.model, "stream": a.stream, "max_tokens": 64,
                               "messages": [{"role": "user", "content": "probe-loop %s" % rid}]}).encode()
            h = {"Authorization": "Bearer " + key, "Content-Type": "application/json", "X-Request-ID": rid}
            h.update(extra)
            c.request("POST", "/v1/chat/completions", body=body, headers=h)
            r = c.getresponse()
            data = r.read()
            rec["status"] = r.status
            if r.status != 200:
                rec["body"] = data[:200].decode("utf-8", "replace")
            elif a.stream:
                rec["done"] = b"[DONE]" in data
            c.close()
        except Exception as e:
            rec["error"] = "%s: %s" % (type(e).__name__, e)
        rec["t1"] = time.time()
        f.write(json.dumps(rec, sort_keys=True) + "\n")
        f.flush()
        time.sleep(a.interval)
