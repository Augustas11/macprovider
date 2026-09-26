#!/usr/bin/env python3
"""Qwen3.6 throughput decomposition on the Studio lab serve (direct HTTP).

For each prompt length L and row count R it separates:
  prefill rate    = prompt tokens / time to first token      (per request)
  decode rate     = (completion tokens - 1) / (end - first token)   (per request)
  aggregate decode = sum(completion tokens) / (last end - first first-token)
Serial = no X-Request-ID (serial route, one at a time); batched = fresh
X-Request-ID per request (scheduler). Greedy, keyless (no conversation cache),
each request gets a unique prompt so nothing is shared.

usage: perf_matrix.py <port> <out.jsonl> [lengths] [rows]
"""
import concurrent.futures as cf
import http.client
import json
import statistics
import sys
import time
import uuid

PORT, OUT = int(sys.argv[1]), sys.argv[2]
LENGTHS = [int(x) for x in (sys.argv[3] if len(sys.argv) > 3 else "32,512,1536,4096,8192").split(",")]
ROWS = [int(x) for x in (sys.argv[4] if len(sys.argv) > 4 else "1,2,4,8").split(",")]
MAX_TOKENS = 128
FILLER = ("The quick brown fox jumps over the lazy dog while the orchestra tunes its "
          "instruments and the river keeps flowing past the old stone bridge. ")


def prompt(target_tokens, salt):
    # ~24 tokens per filler sentence for this tokenizer; a unique salt up front
    # keeps every request's prefix distinct.
    n = max(0, target_tokens // 24 - 2)
    return f"[{salt}] " + FILLER * n + "Now count from 1 to 300 separated by commas."


def one(target, batched):
    body = json.dumps({"model": "qwen/qwen3.6-27b",
                       "messages": [{"role": "user", "content": prompt(target, uuid.uuid4().hex)}],
                       "max_tokens": MAX_TOKENS, "temperature": 0, "stream": True,
                       "stream_options": {"include_usage": True}})
    headers = {"Content-Type": "application/json"}
    if batched:
        headers["X-Request-ID"] = "perf-" + uuid.uuid4().hex[:16]
    c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=1800)
    t0 = time.monotonic()
    c.request("POST", "/v1/chat/completions", body, headers)
    r = c.getresponse()
    first = None
    usage = None
    while True:
        line = r.readline()
        if not line:
            break
        line = line.strip()
        if not line.startswith(b"data:"):
            continue
        data = line[5:].strip()
        if data == b"[DONE]":
            break
        j = json.loads(data)
        if j.get("usage"):
            usage = j["usage"]
        if first is None and any((ch.get("delta") or {}).get("content") for ch in j.get("choices", [])):
            first = time.monotonic()
    end = time.monotonic()
    u = usage or {}
    return {"t0": t0, "first": first or end, "end": end,
            "prompt": u.get("prompt_tokens", 0), "completion": u.get("completion_tokens", 0)}


def run(target, rows, batched):
    with cf.ThreadPoolExecutor(rows) as ex:
        res = list(ex.map(lambda _: one(target, batched), range(rows)))
    ttft = [r["first"] - r["t0"] for r in res]
    dec = [(r["completion"] - 1) / (r["end"] - r["first"]) for r in res if r["completion"] > 1 and r["end"] > r["first"]]
    span = max(r["end"] for r in res) - min(r["first"] for r in res)
    return {
        "L_target": target, "rows": rows, "mode": "batched" if batched else "serial",
        "prompt_tokens": statistics.median([r["prompt"] for r in res]),
        "completion_tokens": sum(r["completion"] for r in res),
        "ttft_median_s": round(statistics.median(ttft), 2), "ttft_max_s": round(max(ttft), 2),
        "prefill_tok_s_median": round(statistics.median([r["prompt"] / t for r, t in zip(res, ttft) if t > 0]), 1),
        "decode_tok_s_per_request_median": round(statistics.median(dec), 1) if dec else None,
        "aggregate_decode_tok_s": round(sum(r["completion"] for r in res) / span, 1) if span > 0 else None,
        "wall_s": round(max(r["end"] for r in res) - min(r["t0"] for r in res), 1),
    }


with open(OUT, "a") as f:
    for L in LENGTHS:
        row = run(L, 1, False)
        print(json.dumps(row), flush=True); f.write(json.dumps(row) + "\n"); f.flush()
        for R in ROWS:
            row = run(L, R, True)
            print(json.dumps(row), flush=True); f.write(json.dumps(row) + "\n"); f.flush()
