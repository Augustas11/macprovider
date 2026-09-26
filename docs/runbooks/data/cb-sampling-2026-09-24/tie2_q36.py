#!/usr/bin/env python3
"""Is the tiny-top_p divergence the serial sampler's own tie-break? Compare:
  serial_topp vs serial_greedy  (serial sampler vs argmax: same logits)
  batched_topp vs serial_topp   (batched sampler vs serial sampler)"""
import concurrent.futures as cf, json, sys, urllib.request, uuid
PORT = int(sys.argv[1]); URL = f"http://127.0.0.1:{PORT}/v1/chat/completions"
TOPICS = ["the Pacific Ocean", "photosynthesis", "the Roman Empire", "volcanoes"]
def call(t, temp, p, batched):
    body = json.dumps({"model": "qwen/qwen3.6-27b", "messages": [{"role": "user", "content": f"Write two sentences about {t}."}],
                       "max_tokens": 48, "temperature": temp, "top_p": p}).encode()
    h = {"Content-Type": "application/json"}
    if batched: h["X-Request-ID"] = f"tie2-{uuid.uuid4().hex[:16]}"
    return json.load(urllib.request.urlopen(urllib.request.Request(URL, body, h), timeout=600))["choices"][0]["message"]["content"] or ""
def fd(a, b):
    for i, (x, y) in enumerate(zip(a, b)):
        if x != y: return i
    return None if len(a) == len(b) else min(len(a), len(b))
sg = {t: call(t, 0, 1.0, False) for t in TOPICS}
st = {t: call(t, 0.7, 0.001, False) for t in TOPICS}
st2 = {t: call(t, 0.7, 0.001, False) for t in TOPICS}
print(json.dumps({"serial_topp_vs_serial_greedy": [fd(st[t], sg[t]) for t in TOPICS],
                  "serial_topp_self_consistent": [st[t] == st2[t] for t in TOPICS]}))
bl = {t: call(t, 0.7, 0.001, True) for t in TOPICS}
print(json.dumps({"batched_topp_lone_vs_serial_topp": [fd(bl[t], st[t]) for t in TOPICS]}))
for rep in range(2):
    with cf.ThreadPoolExecutor(4) as ex:
        got = list(ex.map(lambda t: call(t, 0.7, 0.001, True), TOPICS))
    print(json.dumps({"rep": rep, "batched_topp_x4_vs_serial_topp": [fd(g, st[t]) for t, g in zip(TOPICS, got)]}))
