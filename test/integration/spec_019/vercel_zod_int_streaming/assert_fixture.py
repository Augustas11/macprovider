#!/usr/bin/env python3
import json
from pathlib import Path

root = Path(__file__).parent
pins = json.loads((root / "pinned_versions.json").read_text())
lock_text = ""
for lock_name in ["package-lock.json", "bun.lockb"]:
    lock_path = root / lock_name
    if lock_path.exists():
        lock_text += lock_path.read_text(errors="ignore")
assert lock_text
for value in pins.values():
    assert value in lock_text, value

body = json.loads((root / "captured_request_body.json").read_text())
assert body["stream"] is True
schema = body["response_format"]["json_schema"]["schema"]
assert "$schema" in schema
age = schema["properties"]["age"]
assert age == {
    "type": "integer",
    "minimum": -9007199254740991,
    "maximum": 9007199254740991,
}
assert schema["required"] == ["age"]
assert schema["additionalProperties"] is False
assert body["response_format"]["json_schema"]["strict"] is True
