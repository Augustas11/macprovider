#!/usr/bin/env python3
"""M4 step 2 e2e: concurrent cached follow-up turns through the relay rig.
4 conversations (distinct scaffolds -> distinct keys): turn 1 each, then all 4
turn-2 requests concurrently. Reports per-request TTFT, cached tokens, aggregate
tok/s, and hit-vs-miss parity for one conversation."""
import concurrent.futures as cf, http.client, json, time, uuid
MODEL = "qwen/qwen3.6-27b"
H = {"Content-Type": "application/json", "Authorization": "Bearer ac25-rig-service-token-local-only",
     "X-MacProvider-Account": "acct-ac25-rig"}
TOPICS = ["databases", "networking", "compilers", "operating systems"]
def scaffold(t):
    return f"You are an expert tutor on {t}. " + " ".join(f"Principle {i} of {t}: explain clearly, give one example, and stay concise." for i in range(1, 70))
def chat(messages, key, max_tokens=96):
    h = dict(H); h["X-MacProvider-Internal-Conv-Cache"] = key
    c = http.client.HTTPConnection("127.0.0.1", 19080, timeout=900)
    t0 = time.monotonic()
    c.request("POST", "/v1/chat/completions", json.dumps({"model": MODEL, "messages": messages, "max_tokens": max_tokens,
              "temperature": 0, "stream": True, "stream_options": {"include_usage": True}}), h)
    r = c.getresponse(); ttft = None; text = ""; usage = None
    if r.status != 200: return {"status": r.status, "body": r.read()[:200].decode(errors="replace")}
    while True:
        line = r.readline()
        if not line: break
        line = line.strip()
        if not line.startswith(b"data:"): continue
        d = line[5:].strip()
        if d == b"[DONE]": break
        j = json.loads(d)
        if j.get("usage"): usage = j["usage"]
        for ch in j.get("choices", []):
            x = (ch.get("delta") or {}).get("content")
            if x:
                if ttft is None: ttft = time.monotonic() - t0
                text += x
    return {"status": 200, "ttft_s": round(ttft or -1, 2), "total_s": round(time.monotonic() - t0, 2), "text": text, "usage": usage}
keys = {t: "conv:" + uuid.uuid4().hex for t in TOPICS}
convs = {t: [{"role": "system", "content": scaffold(t)}, {"role": "user", "content": f"What is the most important idea in {t}?"}] for t in TOPICS}
for t in TOPICS:
    r1 = chat(convs[t], keys[t]); convs[t] = convs[t] + [{"role": "assistant", "content": r1["text"]}, {"role": "user", "content": "Give me one concrete example of that."}]
t0 = time.monotonic()
with cf.ThreadPoolExecutor(4) as ex:
    res = dict(zip(TOPICS, ex.map(lambda t: chat(convs[t], keys[t]), TOPICS)))
wall = time.monotonic() - t0
toks = sum((r.get("usage") or {}).get("completion_tokens", 0) for r in res.values())
miss = chat(convs[TOPICS[0]], "conv:" + uuid.uuid4().hex)
out = {"follow_ups": {t: {"ttft_s": r.get("ttft_s"), "total_s": r.get("total_s"),
                         "cached": ((r.get("usage") or {}).get("prompt_tokens_details") or {}).get("cached_tokens"),
                         "prompt": (r.get("usage") or {}).get("prompt_tokens")} for t, r in res.items()},
       "aggregate_tok_s": round(toks / wall, 1), "wall_s": round(wall, 2),
       "hit_equals_miss_conv0": res[TOPICS[0]].get("text") == miss.get("text"), "miss_ttft_s": miss.get("ttft_s")}
print(json.dumps(out, indent=1))
