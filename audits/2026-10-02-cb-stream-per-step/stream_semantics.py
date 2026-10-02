#!/usr/bin/env python3
"""Batched-route semantics probe: greedy parity digests, stop mid-window,
client cancel mid-window, then a health request.
usage: stream_semantics.py PORT MODEL"""
import hashlib, http.client, json, sys, threading, uuid
PORT = int(sys.argv[1]); MODEL = sys.argv[2]
PARITY = ["Explain how tides work in detail.", "Describe the history of the printing press.",
          "Write a short story about a lighthouse keeper.", "List ten facts about octopuses and explain each."]

def stream(prompt, max_tokens, cancel_after=None):
    h = {"Content-Type": "application/json", "X-Request-ID": "sem-" + uuid.uuid4().hex[:16]}
    c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=600)
    c.request("POST", "/v1/chat/completions", json.dumps({
        "model": MODEL, "messages": [{"role": "user", "content": prompt}], "max_tokens": max_tokens,
        "temperature": 0, "stream": True, "stream_options": {"include_usage": True}}), h)
    r = c.getresponse(); text = []; usage = {}; finish = None; chunks = 0; err = None
    while True:
        line = r.readline()
        if not line: break
        if not line.startswith(b"data:"): continue
        d = line[5:].strip()
        if d == b"[DONE]": break
        j = json.loads(d)
        if j.get("error"): err = j["error"].get("code")
        if j.get("usage"): usage = j["usage"]
        for ch in j.get("choices") or []:
            if ch.get("finish_reason"): finish = ch["finish_reason"]
            t = (ch.get("delta") or {}).get("content")
            if t:
                text.append(t); chunks += 1
                if cancel_after and chunks >= cancel_after:
                    r.close(); c.close(); return {"cancelled_after": chunks, "status": r.status}
    return {"status": r.status, "finish": finish, "completion_tokens": usage.get("completion_tokens"),
            "chunks": chunks, "error": err, "sha": hashlib.sha256("".join(text).encode()).hexdigest()[:16]}

def concurrent(jobs):
    out = [None] * len(jobs)
    def run(i, j): out[i] = stream(*j)
    ts = [threading.Thread(target=run, args=(i, j)) for i, j in enumerate(jobs)]
    [t.start() for t in ts]; [t.join() for t in ts]
    return out

print(json.dumps({"probe": "parity_c4", "results": concurrent([(p, 160) for p in PARITY])}), flush=True)
print(json.dumps({"probe": "parity_c1", "results": [stream(p, 160) for p in PARITY]}), flush=True)
print(json.dumps({"probe": "stop_c4", "results": concurrent([("Reply with exactly the word OK and nothing else.", 64)] * 4)}), flush=True)
print(json.dumps({"probe": "cancel_c4", "results": concurrent([("Write a very long essay about rivers.", 512, 10)] * 4)}), flush=True)
print(json.dumps({"probe": "cancel_mixed", "results": concurrent([("Write a very long essay about rivers.", 512, 10),
      ("Write a long essay about mountains.", 200)])}), flush=True)
print(json.dumps({"probe": "health_after", "results": [stream("Say hello.", 32)]}), flush=True)
