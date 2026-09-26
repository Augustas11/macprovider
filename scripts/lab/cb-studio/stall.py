#!/usr/bin/env python3
"""Decode stall behind a long prefill. Row A (short prompt, long output)
decodes; after it is streaming, K rows with ~L-token prompts arrive. Reports
A's token rate and max inter-token gap while the long prompts prefill (from
their arrival until the last of them gets its first token), and their TTFTs."""
import http.client, json, sys, threading, time, uuid
PORT, L, K = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
FILLER = "The quick brown fox jumps over the lazy dog while the orchestra tunes its instruments and the river keeps flowing past the old stone bridge. "
def stream(prompt, max_tokens, ts, first_evt=None):
    h = {"Content-Type": "application/json", "X-Request-ID": "st-" + uuid.uuid4().hex[:16]}
    c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=3600)
    c.request("POST", "/v1/chat/completions", json.dumps({"model": "qwen/qwen3.6-27b", "messages": [{"role": "user", "content": prompt}],
              "max_tokens": max_tokens, "temperature": 0, "stream": True}), h)
    r = c.getresponse()
    while True:
        line = r.readline()
        if not line: break
        if line.startswith(b"data:") and (b'"content"' in line or b'"reasoning_content"' in line):
            try: j = json.loads(line[5:])
            except Exception: continue
            for ch in j.get("choices", []):
                d = ch.get("delta") or {}
                if d.get("content") or d.get("reasoning_content"):
                    ts.append(time.monotonic())
                    if first_evt and len(ts) == 1: first_evt.set()
a_ts = []; started = threading.Event()
ta = threading.Thread(target=stream, args=(f"[{uuid.uuid4().hex}] Count from 1 to 2000 separated by commas.", 1500, a_ts, started)); ta.start()
started.wait(); time.sleep(3)
arrive = time.monotonic(); longs = [[] for _ in range(K)]
tl = [threading.Thread(target=stream, args=(f"[{uuid.uuid4().hex}] " + FILLER * (L // 24) + "Say OK.", 4, longs[i])) for i in range(K)]
for t in tl: t.start()
for t in tl: t.join()
ta.join()
end = max(x[0] for x in longs if x)
win = [t for t in a_ts if arrive <= t <= end]
gaps = [b - a for a, b in zip(win, win[1:])] or [end - arrive]
print(json.dumps({"L": L, "K": K, "prefill_window_s": round(end - arrive, 1), "a_tokens_in_window": len(win),
                  "a_tok_s_in_window": round(len(win) / (end - arrive), 2), "a_max_gap_s": round(max(gaps), 2),
                  "long_ttft_s": sorted(round(x[0] - arrive, 1) for x in longs if x), "a_total_tokens": len(a_ts)}))
