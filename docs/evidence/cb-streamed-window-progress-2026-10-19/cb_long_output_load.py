#!/usr/bin/env python3
"""Long-output CB acceptance load against a loopback lab serve.

Cases: a = 4 concurrent (prompts ~1000/2000/3000/3000 tokens, max_tokens 4096),
b = 1 request max_tokens 2048, c = 1 streaming request max_tokens 2048.
Writes one JSON line per request to stdout and a summary line per case.
Usage: cb_long_output_load.py PORT CASES(e.g. abc) [MODEL]
"""
import concurrent.futures as cf
import http.client
import json
import sys
import time

PORT = int(sys.argv[1])
CASES = sys.argv[2]
MODEL = sys.argv[3] if len(sys.argv) > 3 else "zai-org/glm-5.3-flash"
FILLER = ("The quick brown fox jumps over the lazy dog while the orchestra tunes its "
          "instruments and the river keeps flowing past the old stone bridge. ")
TASK = ("Ignore the text above. Write every integer from 1 to 2000 in English words, "
        "one per line, in order, without skipping, abbreviating or adding any other text.")


def prompt(tokens, tag):
    # ~24 tokens per filler sentence; deterministic per tag.
    return f"[{tag}] " + FILLER * max(0, tokens // 24) + TASK


def run(tag, prompt_tokens, max_tokens, stream):
    body = {"model": MODEL, "messages": [{"role": "user", "content": prompt(prompt_tokens, tag)}],
            "max_tokens": max_tokens, "temperature": 0, "stream": stream}
    if stream:
        body["stream_options"] = {"include_usage": True}
    headers = {"Content-Type": "application/json", "X-Request-ID": f"cbnoprog-{tag}-{int(time.time())}"}
    t0 = time.monotonic()
    conn = http.client.HTTPConnection("127.0.0.1", PORT, timeout=3600)
    conn.request("POST", "/v1/chat/completions", json.dumps(body), headers)
    resp = conn.getresponse()
    out = {"tag": tag, "prompt_tokens_target": prompt_tokens, "max_tokens": max_tokens,
           "stream": stream, "http_status": resp.status}
    if not stream:
        raw = resp.read()
        out["seconds"] = round(time.monotonic() - t0, 1)
        try:
            j = json.loads(raw)
        except Exception:
            out["body"] = raw[:400].decode(errors="replace")
            return out
        usage = j.get("usage") or {}
        out["prompt_tokens"] = usage.get("prompt_tokens")
        out["completion_tokens"] = usage.get("completion_tokens")
        ch = (j.get("choices") or [{}])[0]
        out["finish_reason"] = ch.get("finish_reason")
        if "error" in j:
            out["error"] = j["error"]
        return out
    chunks, done, usage, finish, first, err = 0, False, None, None, None, None
    while True:
        line = resp.readline()
        if not line:
            break
        line = line.strip()
        if not line.startswith(b"data:"):
            continue
        data = line[5:].strip()
        if data == b"[DONE]":
            done = True
            continue
        try:
            j = json.loads(data)
        except Exception:
            continue
        if "error" in j:
            err = j["error"]
        if j.get("usage"):
            usage = j["usage"]
        for ch in j.get("choices") or []:
            d = ch.get("delta") or {}
            if d.get("content") or d.get("reasoning_content") or d.get("reasoning"):
                chunks += 1
                first = first or time.monotonic()
            if ch.get("finish_reason"):
                finish = ch["finish_reason"]
    out.update({"seconds": round(time.monotonic() - t0, 1),
                "ttft_s": round(first - t0, 2) if first else None,
                "content_chunks": chunks, "done": done, "finish_reason": finish,
                "completion_tokens": (usage or {}).get("completion_tokens"),
                "prompt_tokens": (usage or {}).get("prompt_tokens")})
    if err:
        out["error"] = err
    return out


def emit(case, results, t0):
    for r in results:
        print(json.dumps({"case": case, **r}), flush=True)
    ok = all(r.get("http_status") == 200 and (r.get("completion_tokens") or r.get("content_chunks") or 0) > 1100
             and (not r["stream"] or r.get("done")) and "error" not in r for r in results)
    print(json.dumps({"case": case, "summary": "PASS" if ok else "FAIL",
                      "wall_s": round(time.monotonic() - t0, 1),
                      "completion_tokens": [r.get("completion_tokens") for r in results]}), flush=True)


if "a" in CASES:
    t0 = time.monotonic()
    shapes = [("a1", 1000), ("a2", 2000), ("a3", 3000), ("a4", 3000)]
    with cf.ThreadPoolExecutor(4) as ex:
        res = list(ex.map(lambda s: run(s[0], s[1], 4096, False), shapes))
    emit("a", res, t0)
if "b" in CASES:
    t0 = time.monotonic()
    emit("b", [run("b1", 500, 2048, False)], t0)
if "c" in CASES:
    t0 = time.monotonic()
    emit("c", [run("c1", 500, 2048, True)], t0)
