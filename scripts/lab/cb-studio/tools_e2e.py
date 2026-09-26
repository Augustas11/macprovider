#!/usr/bin/env python3
"""SPEC-038 AC-6c hardware check: tool and structured-output rows, serial vs batched (greedy)."""
import concurrent.futures as cf, http.client, json, sys, uuid
PORT = int(sys.argv[1]); M = "qwen/qwen3.6-27b"
TOOLS = [{"type": "function", "function": {"name": "get_weather", "description": "Get current weather for a city",
          "parameters": {"type": "object", "properties": {"city": {"type": "string"}, "unit": {"type": "string", "enum": ["c", "f"]}}, "required": ["city"]}}},
         {"type": "function", "function": {"name": "get_time", "description": "Get local time for a city",
          "parameters": {"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}}}]
SCHEMA = {"type": "json_schema", "json_schema": {"name": "person", "strict": True, "schema": {"type": "object",
          "properties": {"name": {"type": "string"}, "age": {"type": "integer"}}, "required": ["name", "age"], "additionalProperties": False}}}
def body(kind, city, stream):
    b = {"model": M, "temperature": 0, "max_tokens": 400, "stream": stream}
    if kind == "tool":
        b["messages"] = [{"role": "user", "content": f"What's the weather in {city} in celsius? Use the tool."}]; b["tools"] = TOOLS
    elif kind == "json":
        b["messages"] = [{"role": "user", "content": f"Invent a fictional person living in {city}. Reply as JSON with name and age."}]; b["response_format"] = SCHEMA
    else:
        b["messages"] = [{"role": "user", "content": f"Name three landmarks in {city}, one line."}]
    if stream: b["stream_options"] = {"include_usage": True}
    return b
def call(kind, city, stream, batched):
    h = {"Content-Type": "application/json"}
    if batched: h["X-Request-ID"] = "ac6c-" + uuid.uuid4().hex[:16]
    c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=900)
    c.request("POST", "/v1/chat/completions", json.dumps(body(kind, city, stream)), h); r = c.getresponse()
    if not stream:
        d = json.loads(r.read()); ch = (d.get("choices") or [{}])[0]; msg = ch.get("message") or {}
        return {"status": r.status, "finish": ch.get("finish_reason"), "content": msg.get("content"),
                "tool_calls": [(t["function"]["name"], json.loads(t["function"]["arguments"])) for t in (msg.get("tool_calls") or [])],
                "usage": (d.get("usage") or {}).get("completion_tokens"), "error": d.get("error", {}).get("code") if isinstance(d.get("error"), dict) else None}
    content, calls, finish, usage = "", {}, None, None
    while True:
        line = r.readline()
        if not line: break
        line = line.strip()
        if not line.startswith(b"data:"): continue
        data = line[5:].strip()
        if data == b"[DONE]": break
        j = json.loads(data)
        if j.get("usage"): usage = j["usage"].get("completion_tokens")
        for ch in j.get("choices", []):
            d = ch.get("delta") or {}
            content += d.get("content") or ""
            for t in d.get("tool_calls") or []:
                e = calls.setdefault(t.get("index", 0), {"name": "", "args": ""})
                f = t.get("function") or {}; e["name"] += f.get("name") or ""; e["args"] += f.get("arguments") or ""
            if ch.get("finish_reason"): finish = ch["finish_reason"]
    tc = []
    for i in sorted(calls):
        try: tc.append((calls[i]["name"], json.loads(calls[i]["args"] or "{}")))
        except Exception: tc.append((calls[i]["name"], "UNPARSEABLE:" + calls[i]["args"][:80]))
    return {"status": r.status, "finish": finish, "content": content or None, "tool_calls": tc, "usage": usage}
results = {"pairs": [], "concurrent": None}
ok = True
for kind in ("tool", "json"):
    for stream in (False, True):
        for city in ("Paris", "Tokyo"):
            s = call(kind, city, stream, False); b = call(kind, city, stream, True)
            same = (s["tool_calls"] == b["tool_calls"] and s["finish"] == b["finish"] and (kind != "json" or s["content"] == b["content"]))
            json_ok = True
            if kind == "json":
                try: v = json.loads(b["content"] or ""); json_ok = isinstance(v.get("name"), str) and isinstance(v.get("age"), int)
                except Exception: json_ok = False
            ok &= same and json_ok and s["status"] == b["status"] == 200
            results["pairs"].append({"kind": kind, "stream": stream, "city": city, "same": same, "json_valid": json_ok,
                                     "serial": s, "batched": b})
            print(json.dumps({"kind": kind, "stream": stream, "city": city, "same": same, "json_valid": json_ok,
                              "finish": [s["finish"], b["finish"]], "tool_calls": b["tool_calls"], "usage": [s["usage"], b["usage"]]}), flush=True)
jobs = [("tool", "Berlin", True), ("json", "Rome", False), ("plain", "Madrid", True), ("tool", "Oslo", False),
        ("json", "Lima", True), ("plain", "Cairo", False), ("tool", "Seoul", True), ("json", "Quito", False)]
with cf.ThreadPoolExecutor(8) as ex:
    conc = list(ex.map(lambda j: call(j[0], j[1], j[2], True), jobs))
cok = all(r["status"] == 200 for r in conc) and all(r["tool_calls"] for r, j in zip(conc, jobs) if j[0] == "tool")
print(json.dumps({"concurrent8": [{"kind": j[0], "stream": j[2], "status": r["status"], "finish": r["finish"], "tool_calls": r["tool_calls"][:1]} for j, r in zip(jobs, conc)], "ok": cok}), flush=True)
print("AC6C_RESULT", "PASS" if ok and cok else "FAIL")
json.dump(results, open("/Users/a1/lab-cb-sampling/tools-e2e.json", "w"), indent=1)
