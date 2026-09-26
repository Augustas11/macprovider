#!/usr/bin/env python3
"""Tier E2 buyer load + O2 sampler (runs on the VM, stdlib only).

  loadgen.py --key-file F --out DIR [--workers 4] [--sampler] [--duration S]

Workers send priced chat completions through the REAL gateway
(127.0.0.1:9443, buyer API key) back to back, alternating stream/non-stream.
With --sampler one extra thread repeats, every ~50 ms: GET the coordinator's
served /v1/rate-card, then one priced request with a unique X-Request-ID,
logging each as {"kind": "card"|"request", "t0", "t1", ...} to
DIR/sampler.jsonl (O2 in oracle.py). Stops at --duration or when DIR/stop
exists; writes DIR/summary.json (status counts per worker kind).
"""
import argparse
import hashlib
import json
import os
import threading
import time
import urllib.error
import urllib.request
import uuid

GATEWAY = "http://127.0.0.1:9443/v1/chat/completions"
CARD = "http://127.0.0.1:8443/v1/rate-card"
MODEL = os.environ.get("E2E_MODEL", "mlx-community/Llama-3.2-3B-Instruct-4bit")

ap = argparse.ArgumentParser()
ap.add_argument("--key-file", required=True)
ap.add_argument("--out", required=True)
ap.add_argument("--workers", type=int, default=4)
ap.add_argument("--sampler", action="store_true")
ap.add_argument("--duration", type=float, default=0)
args = ap.parse_args()
KEY = open(args.key_file).read().strip()
os.makedirs(args.out, exist_ok=True)
STOP = os.path.join(args.out, "stop")
lock = threading.Lock()
counts = {}
t_end = time.time() + args.duration if args.duration else None


def stopped():
    return os.path.exists(STOP) or (t_end is not None and time.time() >= t_end)


def bump(kind, status):
    with lock:
        counts.setdefault(kind, {}).setdefault(str(status), 0)
        counts[kind][str(status)] += 1


def chat(ext, stream):
    body = json.dumps({"model": MODEL, "max_tokens": 64, "stream": stream,
                       "messages": [{"role": "user", "content": "e2e pricing " + ext}]}).encode()
    req = urllib.request.Request(GATEWAY, data=body, method="POST", headers={
        "Authorization": "Bearer " + KEY, "Content-Type": "application/json", "X-Request-ID": ext})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            r.read()
            return r.status
    except urllib.error.HTTPError as exc:
        exc.read()
        return exc.code
    except Exception as exc:  # connection refused during restarts etc.
        return "err:" + type(exc).__name__


def worker(i):
    n = 0
    while not stopped():
        st = chat(str(uuid.uuid4()), n % 2 == 1)
        bump("load", st)
        n += 1
        if st != 200:
            time.sleep(0.5)


def sampler():
    log = open(os.path.join(args.out, "sampler.jsonl"), "a", buffering=1)
    while not stopped():
        t0 = time.time()
        try:
            with urllib.request.urlopen(CARD, timeout=10) as r:
                body = r.read()
            log.write(json.dumps({"kind": "card", "t0": t0, "t1": time.time(), "sha": hashlib.sha256(body).hexdigest()}) + "\n")
        except Exception as exc:
            bump("card", "err:" + type(exc).__name__)
        ext = str(uuid.uuid4())
        t0 = time.time()
        st = chat(ext, False)
        t1 = time.time()
        bump("sampler", st)
        if st == 200:
            log.write(json.dumps({"kind": "request", "t0": t0, "t1": t1, "external_id": ext}) + "\n")
        time.sleep(0.05)


threads = [threading.Thread(target=worker, args=(i,), daemon=True) for i in range(args.workers)]
if args.sampler:
    threads.append(threading.Thread(target=sampler, daemon=True))
for t in threads:
    t.start()
for t in threads:
    t.join()
json.dump(counts, open(os.path.join(args.out, "summary.json"), "w"), sort_keys=True)
print(json.dumps(counts, sort_keys=True))
