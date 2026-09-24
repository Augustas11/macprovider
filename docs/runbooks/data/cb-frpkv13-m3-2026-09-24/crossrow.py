#!/usr/bin/env python3
"""Cross-row correctness under concurrent batching (lab, direct HTTP).

For N distinct greedy prompts: serial output of each (no X-Request-ID), then all
N concurrently with fresh X-Request-IDs. Reports, per prompt, whether batched
equals serial, the first differing character, and whether the batched output
shares a longer prefix with some OTHER prompt's serial output (cross-row
leakage signal). Records hashes/lengths/positions, not content.
"""
import hashlib, http.client, json, sys, threading, uuid

PORT, N, MAX_TOKENS = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
PROMPTS = [
    "What is the capital of France? Answer in one sentence.",
    "List the first ten prime numbers separated by commas.",
    "Write a Python function that returns the factorial of n.",
    "Name the planets of the solar system in order from the sun.",
    "Explain in two sentences why the sky is blue.",
    "Translate 'good morning' into Spanish, French and German.",
    "Give three tips for writing clean code.",
    "What is 17 multiplied by 23? Show the arithmetic.",
][:N]


def gen(prompt, rid):
    c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=600)
    h = {"Content-Type": "application/json"}
    if rid:
        h["X-Request-ID"] = rid
    c.request("POST", "/v1/chat/completions", json.dumps({"model": "qwen3-coder-30b-a3b-instruct",
              "messages": [{"role": "user", "content": prompt}], "max_tokens": MAX_TOKENS, "temperature": 0}), h)
    r = c.getresponse(); j = json.loads(r.read())
    if r.status != 200:
        return None, (j.get("error") or {}).get("code")
    return j["choices"][0]["message"]["content"], None


def common_prefix(a, b):
    n = 0
    for x, y in zip(a, b):
        if x != y:
            break
        n += 1
    return n


serial = [gen(p, None)[0] for p in PROMPTS]
batched = [None] * len(PROMPTS)
errors = [None] * len(PROMPTS)


def run(i):
    batched[i], errors[i] = gen(PROMPTS[i], "xr-" + uuid.uuid4().hex[:10])


ts = [threading.Thread(target=run, args=(i,)) for i in range(len(PROMPTS))]
for t in ts: t.start()
for t in ts: t.join()

rows = []
for i, (s, b) in enumerate(zip(serial, batched)):
    if b is None:
        rows.append({"i": i, "error": errors[i]}); continue
    own = common_prefix(s, b)
    other = max((common_prefix(serial[j], b) for j in range(len(PROMPTS)) if j != i), default=0)
    rows.append({"i": i, "exact": s == b, "first_diff_char": own if s != b else None,
                 "serial_len": len(s), "batched_len": len(b), "best_other_prefix": other,
                 "leak_signal": other > own, "batched_sha": hashlib.sha256(b.encode()).hexdigest()[:12]})
print(json.dumps({"n": len(PROMPTS), "max_tokens": MAX_TOKENS, "rows": rows}))
