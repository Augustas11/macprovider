#!/usr/bin/env python3
"""Send lab buyer requests through the lab gateway (127.0.0.1:19110).

  buyer.py [--pool NAME] [--stream] [--n N] [--concurrency C] [--max-tokens M]

--pool NAME selects LAB/pools/NAME via X-MacProvider-Pool-Select; without it
the request is a global route. Prints one sanitized JSON line per request:
HTTP status, error code, content length and sha256 (never the text), the
usage the buyer saw, and for streams whether the chunk sequence was intact.
"""
import argparse
import concurrent.futures
import hashlib
import json
import os
import pathlib
import time
import uuid
import urllib.error
import urllib.request

LAB = pathlib.Path(os.environ.get("LAB", "/Users/a1/lab-1690-m6"))
MODEL = "mlx-community/Qwen2.5-0.5B-Instruct-4bit"
PROMPTS = ["Name three colors.", "Count from one to five in words.", "Say hello in French.", "List two fruits.",
           "What is two plus two? Answer in one word.", "Name a planet.", "Give one synonym for happy.", "Name a month."]


def one(i, a):
    key = (LAB / "keys" / "buyer-key-acct-lab-1690-buyer").read_text().strip()
    headers = {"Authorization": f"Bearer {key}", "Content-Type": "application/json"}
    if a.pool:
        headers["X-MacProvider-Pool-Select"] = (LAB / "pools" / a.pool / "pool_id").read_text().strip()
    body = {"model": MODEL, "messages": [{"role": "user", "content": f"{PROMPTS[i % len(PROMPTS)]} (lab ref {uuid.uuid4().hex[:8]})"}], "max_tokens": a.max_tokens}
    if a.stream:
        body["stream"] = True
        body["stream_options"] = {"include_usage": True}
    req = urllib.request.Request("http://127.0.0.1:19110/v1/chat/completions", data=json.dumps(body).encode(), headers=headers)
    out = {"i": i, "pool": a.pool, "stream": a.stream}
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=600) as resp:
            out["status"] = resp.status
            out["provider"] = resp.headers.get("X-Provider-Id")
            raw = resp.read()
    except urllib.error.HTTPError as err:
        out["status"] = err.code
        raw = err.read()
    out["elapsed_s"] = round(time.time() - t0, 2)
    text, usage, intact, finish = "", None, None, None
    if out["status"] == 200 and a.stream:
        chunks, done = 0, False
        for line in raw.decode().splitlines():
            if line == "data: [DONE]":
                done = True
            elif line.startswith("data: "):
                c = json.loads(line[6:])
                chunks += 1
                for ch in c.get("choices") or []:
                    text += (ch.get("delta") or {}).get("content") or ""
                    finish = ch.get("finish_reason") or finish
                if c.get("usage"):
                    usage = c["usage"]
        intact = done and finish is not None
        out["chunks"] = chunks
    elif out["status"] == 200:
        doc = json.loads(raw)
        text = doc["choices"][0]["message"].get("content") or ""
        finish = doc["choices"][0].get("finish_reason")
        usage = doc.get("usage")
    else:
        try:
            out["error"] = (json.loads(raw).get("error") or {}).get("code")
        except ValueError:
            out["error"] = raw[:120].decode(errors="replace")
    out.update({"finish_reason": finish, "stream_intact": intact, "content_len": len(text),
                "content_sha256": hashlib.sha256(text.encode()).hexdigest()[:16] if text else None,
                "usage": {k: usage.get(k) for k in ("prompt_tokens", "completion_tokens")} if usage else None})
    return out


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--pool")
    p.add_argument("--stream", action="store_true")
    p.add_argument("--n", type=int, default=1)
    p.add_argument("--concurrency", type=int, default=1)
    p.add_argument("--max-tokens", type=int, default=32)
    a = p.parse_args()
    with concurrent.futures.ThreadPoolExecutor(a.concurrency) as ex:
        for r in ex.map(lambda i: one(i, a), range(a.n)):
            print(json.dumps(r, sort_keys=True), flush=True)


if __name__ == "__main__":
    main()
