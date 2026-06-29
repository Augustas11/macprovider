#!/usr/bin/env python3
import json
from pathlib import Path

root = Path(__file__).parent
body = json.loads((root / "captured_request_body.json").read_text())
assert body["stream"] is True
rf = body["response_format"]
assert rf["type"] == "json_schema"
assert rf["json_schema"]["name"] == "person-v1"
assert rf["json_schema"]["strict"] is True
schema = rf["json_schema"]["schema"]
assert schema["type"] == "object"
assert schema["properties"]["age"]["type"] == "integer"

content = ""
for line in (root / "sample_stream.sse").read_text().splitlines():
    if not line.startswith("data: ") or line == "data: [DONE]":
        continue
    chunk = json.loads(line.removeprefix("data: "))
    content += chunk["choices"][0]["delta"].get("content", "")
parsed = json.loads(content)
assert parsed == {"name": "Ada", "age": 37}

hashes = json.loads((root / "replayed_prompt_hashes.json").read_text())
assert len(hashes) == 2 and hashes[0] == hashes[1]
