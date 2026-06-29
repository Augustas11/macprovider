#!/usr/bin/env python3
from pathlib import Path

root = Path(__file__).parent

for stem in [
    "rendered_messages",
    "qwen3_rendered_messages",
    "llama33_rendered_messages",
    "tool_history_rendered_messages",
]:
    non_streaming = (root / f"non_streaming_{stem}.json").read_bytes()
    streaming = (root / f"streaming_{stem}.json").read_bytes()
    assert streaming == non_streaming, stem

assert (root / "tools.json").read_text()
assert (root / "response_format.json").read_text()
tool_history = (root / "tool_history_request_body.json").read_text()
assert '"tools"' in tool_history
assert '"tool_calls"' in tool_history
