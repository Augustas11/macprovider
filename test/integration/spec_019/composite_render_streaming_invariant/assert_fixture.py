#!/usr/bin/env python3
from pathlib import Path

root = Path(__file__).parent
non_streaming = (root / "non_streaming_rendered_messages.json").read_bytes()
streaming = (root / "streaming_rendered_messages.json").read_bytes()
assert streaming == non_streaming
assert (root / "tools.json").read_text()
assert (root / "response_format.json").read_text()
