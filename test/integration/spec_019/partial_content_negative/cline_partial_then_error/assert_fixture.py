#!/usr/bin/env python3
import json
from pathlib import Path

content = ""
terminal_error = None
for line in (Path(__file__).parent / "sample_stream.sse").read_text().splitlines():
    if not line.startswith("data: "):
        continue
    data = json.loads(line.removeprefix("data: "))
    if "error" in data:
        terminal_error = data["error"]
        continue
    content += data["choices"][0]["delta"].get("content", "")

assert terminal_error["code"] == "json_schema_validation_failed"
assert terminal_error["settlement_ran"] is True
try:
    json.loads(content)
    raise AssertionError("partial content parsed as final JSON")
except json.JSONDecodeError:
    pass
