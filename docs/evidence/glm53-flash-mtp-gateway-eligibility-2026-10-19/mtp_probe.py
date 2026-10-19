#!/usr/bin/env python3
"""Lab probe for GLM-5.3-Flash native-MTP eligibility. Loopback lab serve only.
Usage: mtp_probe.py PORT trace|validate|concurrency OUT_JSONL
Writes one JSON object per step: request shape, HTTP status, finish, tokens,
content SHA-256 (never the content), native_mtp counter deltas."""
import hashlib, json, sys, threading, time, urllib.request, uuid

PORT, MODE, OUT = int(sys.argv[1]), sys.argv[2], sys.argv[3]
MODEL = "zai-org/glm-5.3-flash"
BASE = f"http://127.0.0.1:{PORT}"
out = open(OUT, "a")

def emit(rec):
    rec["ts"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    out.write(json.dumps(rec, sort_keys=True) + "\n"); out.flush()
    print(json.dumps(rec, sort_keys=True), flush=True)

def status():
    with urllib.request.urlopen(BASE + "/v1/status", timeout=10) as r:
        return json.loads(r.read())

def nm():
    s = status().get("native_mtp") or {}
    return {k: s.get(k) for k in ("mtp_forwards", "target_forwards", "proposed_tokens", "accepted_tokens",
                                  "rejected_tokens", "requests_since_reset", "preoutput_fallbacks",
                                  "postoutput_failures", "capacity_rejections", "last_reason", "mode")}

def delta(a, b):
    return {k: (b[k] - a[k]) if isinstance(a.get(k), int) and isinstance(b.get(k), int) else b.get(k) for k in b}

def chat(body, headers=None, timeout=900):
    data = json.dumps(body).encode()
    req = urllib.request.Request(BASE + "/v1/chat/completions", data=data, method="POST",
                                 headers={"Content-Type": "application/json",
                                          "X-Request-ID": "lab-glm-mtp-elig-" + uuid.uuid4().hex, **(headers or {})})
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            code, raw = r.status, r.read()
    except urllib.error.HTTPError as e:
        code, raw = e.code, e.read()
    dt = time.time() - t0
    try:
        doc = json.loads(raw)
    except Exception:
        return {"http": code, "seconds": round(dt, 3), "error": raw[:200].decode(errors="replace")}
    if code != 200:
        return {"http": code, "seconds": round(dt, 3), "error": json.dumps(doc)[:300]}
    ch = doc["choices"][0]; msg = ch.get("message") or {}
    content = msg.get("content") or ""
    usage = doc.get("usage") or {}
    ct = usage.get("completion_tokens") or 0
    return {"http": code, "seconds": round(dt, 3), "finish": ch.get("finish_reason"),
            "prompt_tokens": usage.get("prompt_tokens"), "completion_tokens": ct,
            "tok_per_s": round(ct / dt, 2) if dt > 0 else None,
            "tool_calls": len(msg.get("tool_calls") or []),
            "content_sha256": hashlib.sha256(content.encode()).hexdigest(), "content_chars": len(content)}

def body(prompt, max_tokens=256, **extra):
    b = {"model": MODEL, "messages": [{"role": "user", "content": prompt}],
         "temperature": 0, "top_p": 1, "max_tokens": max_tokens, "stream": False}
    b.update(extra); return b

def step(name, b, headers=None, shape=None):
    a = nm(); r = chat(b, headers); z = nm()
    emit({"step": name, "shape": shape or name, "result": r, "native_mtp_delta": delta(a, z), "native_mtp_after": z})
    return r

def sticky():
    # The provider state a gateway request reaches once the fleet grant has
    # replaced its cache-only key: a keyed request whose marker is false.
    return {"X-MacProvider-Provider-Conversation": "conv:" + hashlib.sha256(uuid.uuid4().bytes).hexdigest()}

P1 = "Explain in four short paragraphs how a river delta forms."
P2 = "List the planets of the solar system in order from the Sun, one per line, with one sentence about each."
LONG = ["Write a detailed, multi-section technical essay of at least 2000 words on the history of {}.".format(t)
        for t in ("the steam engine", "printing", "radio", "the bicycle")]

emit({"step": "start", "mode": MODE, "binary_version": status().get("binary_version"), "native_mtp": nm()})
if MODE == "trace":
    step("keyless_plain", body(P1), shape="plain text, temperature 0, no key")
    step("post_grant_key_plain", body(P1), sticky(), shape="plain text, temperature 0, key present, cache_only=false")
elif MODE == "validate":
    for i, p in enumerate((P1, P2), 1):
        n = step(f"native_p{i}", body(p), shape="plain text, temperature 0, no key")
        o = step(f"ordinary_p{i}", body(p, metadata={"lab": "ordinary-control"}),
                 shape="same body plus an unadmitted top-level key (ordinary control)")
        emit({"step": f"token_match_p{i}", "match": n.get("content_sha256") == o.get("content_sha256")
              and n.get("completion_tokens") == o.get("completion_tokens")})
    tools = [{"type": "function", "function": {"name": "get_weather", "description": "Weather for a city",
              "parameters": {"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}}}]
    step("tools", body("What is the weather in Paris? Use the tool.", tools=tools), shape="tools present")
    step("post_grant_key_plain", body(P1), sticky(), shape="plain text, key present, cache_only=false")
if MODE in ("validate", "concurrency"):
    a = nm(); results = [None] * 4
    def run(i):
        results[i] = chat(body(LONG[i], max_tokens=1400))
    th = [threading.Thread(target=run, args=(i,)) for i in range(4)]
    t0 = time.time(); [t.start() for t in th]; [t.join() for t in th]; wall = time.time() - t0
    z = nm()
    tot = sum((r or {}).get("completion_tokens") or 0 for r in results)
    emit({"step": "cb4_long", "rows": results, "wall_seconds": round(wall, 2),
          "aggregate_tok_per_s": round(tot / wall, 2), "native_mtp_delta": delta(a, z)})
emit({"step": "end", "native_mtp": nm()})
