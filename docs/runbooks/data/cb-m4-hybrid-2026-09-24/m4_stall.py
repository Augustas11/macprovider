#!/usr/bin/env python3
"""Measure how long a keyed hybrid turn's terminal materialize stalls other
batched rows. A keyless background stream (direct :18090, X-Request-ID) runs
400 tokens while a keyed ~8k-token turn goes through the relay and finishes.
Reports the background stream's inter-token gaps and the keyed turn timings."""
import http.client, json, statistics, threading, time, uuid
MODEL = "qwen/qwen3.6-27b"
BIG = "You are a careful assistant. " + " ".join(f"Guideline {i}: be precise about item {i} and cite section {i}." for i in range(1, 700))
gaps = []
def background():
    c = http.client.HTTPConnection("127.0.0.1", 18090, timeout=600)
    c.request("POST", "/v1/chat/completions", json.dumps({"model": MODEL, "messages": [{"role": "user", "content": "Count from 1 to 300 separated by commas."}],
              "max_tokens": 400, "temperature": 0, "stream": True}), {"Content-Type": "application/json", "X-Request-ID": "bg-" + uuid.uuid4().hex[:12]})
    r = c.getresponse(); last = None
    while True:
        line = r.readline()
        if not line: break
        if line.startswith(b"data:") and b"content" in line:
            now = time.monotonic()
            if last is not None: gaps.append(now - last)
            last = now
def keyed(messages, key):
    c = http.client.HTTPConnection("127.0.0.1", 19080, timeout=600)
    t0 = time.monotonic()
    c.request("POST", "/v1/chat/completions", json.dumps({"model": MODEL, "messages": messages, "max_tokens": 16, "temperature": 0}),
              {"Content-Type": "application/json", "Authorization": "Bearer ac25-rig-service-token-local-only",
               "X-MacProvider-Account": "acct-ac25-rig", "X-MacProvider-Internal-Conv-Cache": key})
    j = json.loads(c.getresponse().read())
    return {"s": round(time.monotonic() - t0, 2), "usage": j.get("usage")}
k = "conv:" + uuid.uuid4().hex
bg = threading.Thread(target=background); bg.start(); time.sleep(3)
first = keyed([{"role": "system", "content": BIG}, {"role": "user", "content": "Summarize guideline 5."}], k)
bg.join()
follow = keyed([{"role": "system", "content": BIG}, {"role": "user", "content": "Summarize guideline 5."},
                {"role": "assistant", "content": "Guideline 5 asks for precision about item 5."}, {"role": "user", "content": "And guideline 6?"}], k)
g = sorted(gaps)
print(json.dumps({"keyed_first_turn": first, "keyed_follow_up": follow,
                  "background_gaps_ms": {"n": len(g), "median": round(statistics.median(g) * 1000, 1) if g else None,
                                         "p99": round(g[int(len(g) * 0.99) - 1] * 1000, 1) if g else None,
                                         "max": round(g[-1] * 1000, 1) if g else None}}, indent=1))
