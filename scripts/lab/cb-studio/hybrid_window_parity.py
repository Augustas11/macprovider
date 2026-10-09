#!/usr/bin/env python3
"""Greedy output capture for #1906 hybrid decode-window parity.

Sends a fixed, deterministic set of prompts (mixed lengths crossing the
512-token prefill chunk) concurrently with temperature 0 and writes each
completion. Run once per serve configuration, then compare the files.

usage: hybrid_window_parity.py <port> <out.json> [concurrency]
"""
import concurrent.futures as cf
import http.client
import json
import sys
import uuid

PORT, OUT = int(sys.argv[1]), sys.argv[2]
CONC = int(sys.argv[3]) if len(sys.argv) > 3 else 16
LENGTHS = [300, 480, 520, 700, 900, 1024, 1100, 1300, 1536, 1600, 1800, 2000, 2100, 2300, 2400, 2500]
FILLER = ("The quick brown fox jumps over the lazy dog while the orchestra tunes its "
          "instruments and the river keeps flowing past the old stone bridge. ")


def prompt(i, target):
    n = max(0, target // 24 - 2)
    return f"[case {i}] " + FILLER * n + f"Write a short story about lighthouse number {i}, then list its keepers."


def one(i):
    body = json.dumps({"model": "qwen/qwen3.6-35b-a3b",
                       "messages": [{"role": "user", "content": prompt(i, LENGTHS[i % len(LENGTHS)])}],
                       "max_tokens": 256, "temperature": 0, "stream": False})
    c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=1800)
    c.request("POST", "/v1/chat/completions", body,
              {"Content-Type": "application/json", "X-Request-ID": "parity-" + uuid.uuid4().hex[:16]})
    j = json.loads(c.getresponse().read())
    ch = j["choices"][0]["message"]
    return i, {"content": ch.get("content"), "reasoning": ch.get("reasoning_content") or ch.get("reasoning"),
               "usage": j.get("usage")}


with cf.ThreadPoolExecutor(CONC) as ex:
    results = dict(ex.map(one, range(len(LENGTHS))))
json.dump({str(k): v for k, v in sorted(results.items())}, open(OUT, "w"), indent=1)
print("wrote", OUT, len(results))
