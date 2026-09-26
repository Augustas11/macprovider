#!/usr/bin/env python3
"""Steady-state batched decode: R concurrent requests with ~L-token prompts and
long outputs; records every streamed token's arrival time and reports the
aggregate token rate only over the window where ALL rows are decoding
[max(first token), min(end)], i.e. excluding admission/prefill stalls."""
import concurrent.futures as cf, http.client, json, sys, time, uuid
PORT, L, R, BATCHED = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]), sys.argv[4] == "batched"
FILLER = "The quick brown fox jumps over the lazy dog while the orchestra tunes its instruments and the river keeps flowing past the old stone bridge. "
def one(_):
    p = f"[{uuid.uuid4().hex}] " + FILLER * max(0, L // 24 - 2) + "Now count from 1 to 600 separated by commas."
    h = {"Content-Type": "application/json"}
    if BATCHED: h["X-Request-ID"] = "sd-" + uuid.uuid4().hex[:16]
    c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=3600)
    c.request("POST", "/v1/chat/completions", json.dumps({"model": "qwen/qwen3.6-27b", "messages": [{"role": "user", "content": p}],
              "max_tokens": 768, "temperature": 0, "stream": True}), h)
    r = c.getresponse(); ts = []
    while True:
        line = r.readline()
        if not line: break
        if line.startswith(b"data:") and b'"content"' in line:
            try:
                j = json.loads(line[5:])
            except Exception:
                continue
            for ch in j.get("choices", []):
                if (ch.get("delta") or {}).get("content"): ts.append(time.monotonic())
    return ts
with cf.ThreadPoolExecutor(R) as ex:
    all_ts = list(ex.map(one, range(R)))
all_ts = [t for t in all_ts if t]
start = max(t[0] for t in all_ts); stop = min(t[-1] for t in all_ts)
n = sum(sum(1 for x in t if start <= x <= stop) for t in all_ts)
print(json.dumps({"L": L, "rows": R, "mode": "batched" if BATCHED else "serial", "steady_window_s": round(stop - start, 1),
                  "steady_aggregate_chunks_per_s": round(n / (stop - start), 1) if stop > start else None,
                  "chunks_per_request": [len(t) for t in all_ts]}))
