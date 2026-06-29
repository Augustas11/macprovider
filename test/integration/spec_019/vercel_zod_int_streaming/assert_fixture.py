#!/usr/bin/env python3
import json
from pathlib import Path

body = json.loads((Path(__file__).parent / "captured_request_body.json").read_text())
assert body["stream"] is True
schema = body["response_format"]["json_schema"]["schema"]
assert "$schema" in schema
age = schema["properties"]["age"]
assert age == {
    "type": "integer",
    "minimum": -9007199254740991,
    "maximum": 9007199254740991,
}
assert body["response_format"]["json_schema"]["strict"] is True
