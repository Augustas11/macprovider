"""Lab probe: one streaming tool-call request straight to the lab coordinator
buyer port as the gateway sends it; prints each SSE data line with content and
tool arguments redacted."""
import json, os, pathlib, sys, uuid, urllib.request, urllib.error
LAB = pathlib.Path(os.environ["LAB"])
s = json.loads((LAB / "keys" / "secrets.json").read_text())
rid = str(uuid.uuid4())
h = {"Authorization": f"Bearer {s['gateway_service_token']}", "Content-Type": "application/json",
     "X-MacProvider-Account": "acct-lab-1690-buyer", "X-Request-ID": rid}
if len(sys.argv) > 1 and sys.argv[1]:
    h["X-MacProvider-Internal-Pool"] = (LAB / "pools" / sys.argv[1] / "pool_id").read_text().strip()
tools = [{"type": "function", "function": {"name": "get_weather", "description": "Get the current weather for a city.",
          "parameters": {"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}}}]
body = {"model": "mlx-community/Qwen2.5-0.5B-Instruct-4bit", "stream": True, "stream_options": {"include_usage": True}, "max_tokens": 96,
        "tools": tools, "messages": [{"role": "user", "content": f"What is the weather in Paris right now? Use the get_weather tool. (ref {rid[:8]})"}]}
try:
    resp = urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:19101/v1/chat/completions", data=json.dumps(body).encode(), headers=h))
except urllib.error.HTTPError as e:
    print("HTTP", e.code, e.read()[:400]); sys.exit(1)
print("status", resp.status, {k: v for k, v in resp.headers.items() if k.lower().startswith("x-macprovider") and "mac" not in k.lower()[14:]})
for line in resp.read().decode().splitlines():
    if not line.startswith("data: ") or line == "data: [DONE]":
        print(line[:80]); continue
    d = json.loads(line[6:])
    for ch in d.get("choices") or []:
        dl = ch.get("delta") or {}
        if dl.get("content"): dl["content"] = "<c>"
        for tc in dl.get("tool_calls") or []:
            if (tc.get("function") or {}).get("arguments"): tc["function"]["arguments"] = "<a>"
    print("data:", json.dumps({k: v for k, v in d.items() if k not in ("id", "created", "model", "system_fingerprint")}))
