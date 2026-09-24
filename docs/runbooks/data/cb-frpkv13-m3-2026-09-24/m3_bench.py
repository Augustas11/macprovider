#!/usr/bin/env python3
"""M3 / FR-PKV13 overhead bench on an isolated lab serve (direct HTTP).

Serial path: requests without X-Request-ID (canary serial-routes them).
Batched path: requests with a fresh X-Request-ID (enter the CB scheduler).
For concurrency N, fires N requests at once and measures wall time and the
sum of completion tokens. Greedy, fixed max_tokens with ignore of EOS is not
available, so prompts are chosen to run long; completion token counts are
recorded exactly. Records numbers only, never content.
"""
import http.client, json, statistics, sys, threading, time, uuid

PORT = int(sys.argv[1])
MAX_TOKENS = int(sys.argv[2]) if len(sys.argv) > 2 else 256
REPEATS = int(sys.argv[3]) if len(sys.argv) > 3 else 3
MODEL = "qwen3-coder-30b-a3b-instruct"
PROMPTS = [
    "Write a detailed Python tutorial on implementing a binary search tree with insertion, deletion, and traversal.",
    "Explain, step by step, how TCP congestion control works, including slow start and fast recovery.",
    "Describe the architecture of a modern web browser rendering engine in depth.",
    "Write a long essay on the history of the printing press and its effects on Europe.",
    "Explain how public key cryptography works, with worked examples of RSA key generation.",
    "Write a comprehensive guide to setting up a Kubernetes cluster from scratch.",
    "Explain the causes and consequences of the 2008 financial crisis in detail.",
    "Describe how a compiler turns source code into machine code, phase by phase.",
]


def one(prompt, batched, out, idx):
    body = {"model": MODEL, "messages": [{"role": "user", "content": prompt}],
            "max_tokens": MAX_TOKENS, "temperature": 0}
    headers = {"Content-Type": "application/json"}
    if batched:
        headers["X-Request-ID"] = "m3-" + uuid.uuid4().hex[:12]
    t0 = time.monotonic()
    c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=900)
    c.request("POST", "/v1/chat/completions", json.dumps(body), headers)
    r = c.getresponse()
    j = json.loads(r.read())
    elapsed = time.monotonic() - t0
    if r.status != 200 or "usage" not in j:
        out[idx] = {"status": r.status, "error": (j.get("error") or {}).get("code"), "elapsed_s": elapsed}
        return
    u = j["usage"]
    out[idx] = {"status": 200, "elapsed_s": elapsed, "prompt_tokens": u.get("prompt_tokens"),
                "completion_tokens": u.get("completion_tokens"),
                "generation_ms": u.get("macprovider_generation_ms")}


def run(n, batched):
    out = [None] * n
    ts = [threading.Thread(target=one, args=(PROMPTS[i % len(PROMPTS)], batched, out, i)) for i in range(n)]
    t0 = time.monotonic()
    for t in ts: t.start()
    for t in ts: t.join()
    wall = time.monotonic() - t0
    ok = [o for o in out if o and o.get("status") == 200]
    tokens = sum(o["completion_tokens"] for o in ok)
    return {"n": n, "batched": batched, "wall_s": round(wall, 3), "ok": len(ok),
            "errors": [o for o in out if not o or o.get("status") != 200],
            "completion_tokens": tokens, "agg_tps": round(tokens / wall, 2) if wall else None,
            "per_request_tps": [round(o["completion_tokens"] / o["elapsed_s"], 2) for o in ok]}


results = []
# Warm both paths once.
run(1, False); run(1, True)
for n in (1, 2, 4, 8):
    for batched in (False, True):
        reps = [run(n, batched) for _ in range(REPEATS)]
        med = statistics.median(r["agg_tps"] for r in reps if r["agg_tps"])
        results.append({"n": n, "batched": batched, "median_agg_tps": med, "reps": reps})
        print(json.dumps({"n": n, "batched": batched, "median_agg_tps": med,
                          "ok": [r["ok"] for r in reps], "tokens": [r["completion_tokens"] for r in reps],
                          "errors": sum(len(r["errors"]) for r in reps)}), flush=True)
print(json.dumps({"summary": [{k: r[k] for k in ("n", "batched", "median_agg_tps")} for r in results]}))
