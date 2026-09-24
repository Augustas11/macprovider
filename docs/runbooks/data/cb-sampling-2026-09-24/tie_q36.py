#!/usr/bin/env python3
"""Separate batched-numerics tie flips from sampler faults (SPEC-038 AC-6b).
4 concurrent rows, each compared with its own serial greedy output:
  greedy_batched  t=0            (known: may diverge late on near-ties)
  topp_batched    t=0.7 p=0.001  (sampler path, must behave like greedy)
  tinyT_batched   t=0.01 p=1     (sampler path, near-greedy)
Reports exact + first differing char. Repeats 2x."""
import concurrent.futures as cf, json, sys, urllib.request, uuid
PORT = int(sys.argv[1]); URL = f"http://127.0.0.1:{PORT}/v1/chat/completions"
TOPICS = ["the Pacific Ocean", "photosynthesis", "the Roman Empire", "volcanoes"]
def call(t, temp, p, batched):
    body = json.dumps({"model": "qwen/qwen3.6-27b", "messages": [{"role": "user", "content": f"Write two sentences about {t}."}],
                       "max_tokens": 48, "temperature": temp, "top_p": p}).encode()
    h = {"Content-Type": "application/json"}
    if batched: h["X-Request-ID"] = f"tie-{uuid.uuid4().hex[:16]}"
    return json.load(urllib.request.urlopen(urllib.request.Request(URL, body, h), timeout=600))["choices"][0]["message"]["content"] or ""
def first_diff(a, b):
    for i, (x, y) in enumerate(zip(a, b)):
        if x != y: return i
    return None if len(a) == len(b) else min(len(a), len(b))
serial = {t: call(t, 0, 1.0, False) for t in TOPICS}
serial2 = {t: call(t, 0, 1.0, False) for t in TOPICS}
print(json.dumps({"serial_self_consistent": [serial[t] == serial2[t] for t in TOPICS]}))
for rep in range(2):
    for name, temp, p in [("greedy_batched", 0, 1.0), ("topp_batched", 0.7, 0.001), ("tinyT_batched", 0.01, 1.0)]:
        with cf.ThreadPoolExecutor(4) as ex:
            got = list(ex.map(lambda t: call(t, temp, p, True), TOPICS))
        print(json.dumps({"rep": rep, "mode": name, "rows": [
            {"exact": g == serial[t], "first_diff": first_diff(g, serial[t]), "len": len(serial[t])} for t, g in zip(TOPICS, got)]}))
