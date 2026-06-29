#!/usr/bin/env python3
import json
from pathlib import Path

root = Path(__file__).parent
body = json.loads((root / "fixture_request_body.json").read_text())
assert body["stream"] is True
assert body["response_format"]["type"] == "json_schema"
assert body["response_format"]["json_schema"]["strict"] is True

content = ""
for line in (root / "sample_chunks.jsonl").read_text().splitlines():
    chunk = json.loads(line)
    content += chunk["choices"][0]["delta"].get("content", "")
assert json.loads(content) == {"name": "Ada", "age": 37}
