#!/usr/bin/env python3
"""M4 step 1 e2e: hybrid (Qwen3.6) conversation-cache reuse through the relay rig.
Buyer -> loopback coordinator :19080 -> rig provider. Greedy, streaming (TTFT)."""
import http.client, json, sys, time, uuid
MODEL = "qwen/qwen3.6-27b"
H = {"Content-Type": "application/json", "Authorization": "Bearer ac25-rig-service-token-local-only",
     "X-MacProvider-Account": "acct-ac25-rig"}
SYSTEM = ("You are a meticulous senior software engineer. " +
          " ".join(f"Rule {i}: always explain the reasoning behind rule {i} briefly, keep answers short, "
                   f"and prefer standard library solutions over dependencies." for i in range(1, 60)))
def chat(messages, key, max_tokens=48):
    h = dict(H); h["X-MacProvider-Internal-Conv-Cache"] = key
    c = http.client.HTTPConnection("127.0.0.1", 19080, timeout=600)
    t0 = time.monotonic()
    c.request("POST", "/v1/chat/completions", json.dumps({"model": MODEL, "messages": messages, "max_tokens": max_tokens,
              "temperature": 0, "stream": True, "stream_options": {"include_usage": True}}), h)
    r = c.getresponse(); ttft = None; text = ""; usage = None
    if r.status != 200:
        return {"status": r.status, "body": r.read()[:300].decode(errors="replace")}
    buf = b""
    while True:
        line = r.readline()
        if not line: break
        line = line.strip()
        if not line.startswith(b"data:"): continue
        data = line[5:].strip()
        if data == b"[DONE]": break
        j = json.loads(data)
        if j.get("usage"): usage = j["usage"]
        for ch in j.get("choices", []):
            d = (ch.get("delta") or {}).get("content")
            if d:
                if ttft is None: ttft = time.monotonic() - t0
                text += d
    return {"status": 200, "ttft_s": round(ttft or -1, 3), "total_s": round(time.monotonic() - t0, 2), "text": text,
            "usage": usage}
def key(): return "conv:" + uuid.uuid4().hex
out = {}
KA = key()
u1 = [{"role": "system", "content": SYSTEM}, {"role": "user", "content": "How do I read a file line by line in Python?"}]
t1 = chat(u1, KA); out["A_turn1"] = {k: v for k, v in t1.items() if k != "text"}
u2 = u1 + [{"role": "assistant", "content": t1["text"]}, {"role": "user", "content": "And how do I count the lines?"}]
hit = chat(u2, KA); miss = chat(u2, key())
out["A_turn2_hit"] = {k: v for k, v in hit.items() if k != "text"}
out["A_turn2_miss"] = {k: v for k, v in miss.items() if k != "text"}
out["A_turn2_hit_equals_miss"] = hit.get("text") == miss.get("text")
b1 = [{"role": "system", "content": SYSTEM}, {"role": "user", "content": "What is a Python generator?"}]
bh = chat(b1, KA); bm = chat(b1, key())
out["B_scaffold_hit"] = {k: v for k, v in bh.items() if k != "text"}
out["B_scaffold_miss"] = {k: v for k, v in bm.items() if k != "text"}
out["B_hit_equals_miss"] = bh.get("text") == bm.get("text")
u3 = u2 + [{"role": "assistant", "content": hit.get("text", "")}, {"role": "user", "content": "Thanks. Now in one line?"}]
t3 = chat(u3, KA); t3m = chat(u3, key())
out["A_turn3_hit"] = {k: v for k, v in t3.items() if k != "text"}
out["A_turn3_miss"] = {k: v for k, v in t3m.items() if k != "text"}
out["A_turn3_hit_equals_miss"] = t3.get("text") == t3m.get("text")
print(json.dumps(out, indent=1))
