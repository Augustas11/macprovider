#!/usr/bin/env python3
"""finish_reason at explicit max_tokens edges: serial vs batched must match."""
import http.client, json, sys, uuid
PORT = int(sys.argv[1])
SCHEMA = {"type": "json_schema", "json_schema": {"name": "person", "strict": True, "schema": {"type": "object",
          "properties": {"name": {"type": "string"}, "age": {"type": "integer"}}, "required": ["name", "age"], "additionalProperties": False}}}
def call(mt, stream, batched):
    b = {"model": "qwen/qwen3.6-27b", "temperature": 0, "max_tokens": mt, "stream": stream, "response_format": SCHEMA,
         "messages": [{"role": "user", "content": "Invent a fictional person living in Paris. Reply as JSON with name and age."}]}
    if stream: b["stream_options"] = {"include_usage": True}
    h = {"Content-Type": "application/json"}
    if batched: h["X-Request-ID"] = "edge-" + uuid.uuid4().hex[:16]
    c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=600); c.request("POST", "/v1/chat/completions", json.dumps(b), h); r = c.getresponse()
    if not stream:
        d = json.loads(r.read()); ch = (d.get("choices") or [{}])[0]
        return r.status, ch.get("finish_reason"), (d.get("usage") or {}).get("completion_tokens"), (d.get("error") or {}).get("code") if isinstance(d.get("error"), dict) else None
    fin, use, err = None, None, None
    for line in r:
        line = line.strip()
        if not line.startswith(b"data:") or line[5:].strip() == b"[DONE]": continue
        j = json.loads(line[5:])
        if j.get("usage"): use = j["usage"].get("completion_tokens")
        if isinstance(j.get("error"), dict): err = j["error"].get("code")
        for ch in j.get("choices", []):
            if ch.get("finish_reason"): fin = ch["finish_reason"]
    return r.status, fin, use, err
ok = True
for mt in (21, 22, 23, 24):
    for stream in (False, True):
        s = call(mt, stream, False); b = call(mt, stream, True)
        same = s == b; ok &= same
        print(json.dumps({"max_tokens": mt, "stream": stream, "serial": s, "batched": b, "same": same}), flush=True)
print("FINISH_EDGE", "PASS" if ok else "FAIL")
