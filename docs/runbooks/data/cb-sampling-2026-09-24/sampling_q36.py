#!/usr/bin/env python3
"""SPEC-038 AC-6b lab check for sampled batched rows (Qwen3.6, lab serve).

usage: sampling_q36.py <port> <out_dir>

1. near-deterministic: temperature 0.7 + top_p 0.001 keeps only the argmax, so a
   batched sampled row must equal the greedy serial output token for token, as
   a lone row and among concurrent rows.
2. isolation: 8 concurrent sampled rows (t=0.8, p=0.95) on distinct topics; no
   row's text may start with another row's serial greedy prefix (leak signal).
3. throughput: 8 concurrent sampled requests, batched vs serial, 3 repeats.
Serial = no X-Request-ID (serial route); batched = fresh X-Request-ID.
Numbers and hashes only; no content is written except short topic checks.
"""
import concurrent.futures as cf
import hashlib
import json
import os
import statistics
import sys
import time
import urllib.request
import uuid

PORT, OUT = int(sys.argv[1]), sys.argv[2]
URL = f"http://127.0.0.1:{PORT}/v1/chat/completions"
MODEL = "qwen/qwen3.6-27b"
TOPICS = ["the Pacific Ocean", "photosynthesis", "the Roman Empire", "volcanoes",
          "the human heart", "jazz music", "the moon landing", "honeybees"]


def call(prompt, max_tokens, temperature, top_p, batched):
    body = json.dumps({"model": MODEL, "messages": [{"role": "user", "content": prompt}],
                       "max_tokens": max_tokens, "temperature": temperature, "top_p": top_p}).encode()
    headers = {"Content-Type": "application/json"}
    if batched:
        headers["X-Request-ID"] = f"smp-{uuid.uuid4().hex[:16]}"
    t = time.time()
    r = json.load(urllib.request.urlopen(urllib.request.Request(URL, body, headers), timeout=600))
    c = r["choices"][0]
    return {"text": c["message"]["content"] or "", "finish": c["finish_reason"],
            "tokens": r["usage"]["completion_tokens"], "s": time.time() - t}


def prompt(topic):
    return f"Write two sentences about {topic}."


def near_deterministic():
    rows = []
    serial = {t: call(prompt(t), 48, 0, 1.0, False)["text"] for t in TOPICS[:4]}
    alone = call(prompt(TOPICS[0]), 48, 0.7, 0.001, True)["text"]
    rows.append({"scenario": "lone_row", "exact": alone == serial[TOPICS[0]]})
    with cf.ThreadPoolExecutor(4) as ex:
        got = list(ex.map(lambda t: call(prompt(t), 48, 0.7, 0.001, True)["text"], TOPICS[:4]))
    for t, g in zip(TOPICS[:4], got):
        rows.append({"scenario": "concurrent_x4", "topic": t, "exact": g == serial[t],
                     "sha": hashlib.sha256(g.encode()).hexdigest()[:12]})
    return rows


def isolation():
    refs = {t: call(prompt(t), 24, 0, 1.0, False)["text"][:40] for t in TOPICS}
    with cf.ThreadPoolExecutor(8) as ex:
        got = list(ex.map(lambda t: call(prompt(t), 64, 0.8, 0.95, True), TOPICS))
    out = []
    for t, g in zip(TOPICS, got):
        others = [refs[o] for o in TOPICS if o != t]
        leak = any(len(o) >= 20 and g["text"].startswith(o[:20]) for o in others)
        on_topic = t.split()[-1].lower().rstrip("s") in g["text"].lower()
        out.append({"topic": t, "finish": g["finish"], "tokens": g["tokens"],
                    "leak_signal": leak, "on_topic": on_topic})
    return out


def throughput(repeats=3):
    res = {}
    for batched in (False, True):
        agg = []
        for _ in range(repeats):
            t = time.time()
            with cf.ThreadPoolExecutor(8) as ex:
                got = list(ex.map(lambda tp: call(prompt(tp), 128, 0.7, 0.95, batched), TOPICS))
            agg.append(sum(g["tokens"] for g in got) / (time.time() - t))
        res["batched" if batched else "serial"] = {"median_tok_s": round(statistics.median(agg), 1),
                                                   "runs": [round(a, 1) for a in agg]}
    res["ratio"] = round(res["batched"]["median_tok_s"] / res["serial"]["median_tok_s"], 2)
    return res


os.makedirs(OUT, exist_ok=True)
result = {"near_deterministic": near_deterministic(), "isolation": isolation(), "throughput": throughput()}
json.dump(result, open(os.path.join(OUT, "sampling.json"), "w"), indent=1)
print(json.dumps(result))
