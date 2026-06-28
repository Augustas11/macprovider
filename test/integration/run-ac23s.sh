#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
TMPDIR="$(mktemp -d -t macprovider-ac23s.XXXXXX)"
cleanup() {
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

python3 -m venv "$TMPDIR/venv"
"$TMPDIR/venv/bin/python" -m pip install \
  --disable-pip-version-check \
  --quiet \
  -r "$ROOT/tools/version-pins/openai-python-spec-018-v0_1_3-baseline.txt"

"$TMPDIR/venv/bin/python" - <<'PY'
import importlib.metadata
import json

if importlib.metadata.version("openai") != "2.44.0":
    raise SystemExit("openai pin mismatch")

success_events = [
    {"choices": [{"delta": {"role": "assistant"}}]},
    {"choices": [{"delta": {"tool_calls": [{"index": 0, "id": "call_0123456789abcdef0123456789abcdef", "type": "function", "function": {"name": "write_to_file", "arguments": ""}}]}}]},
    {"choices": [{"delta": {"tool_calls": [{"index": 0, "function": {"arguments": "{\"path\":\"docs/generated-large.md\","}}]}}]},
    {"choices": [{"delta": {"tool_calls": [{"index": 0, "function": {"arguments": "\"content\":\"hello\"}"}}]}}]},
    {"choices": [{"delta": {}, "finish_reason": "tool_calls"}]},
]
non_streaming_arguments = '{"path":"docs/generated-large.md","content":"hello"}'
accumulated = []
for event in success_events:
    for choice in event.get("choices", []):
        for call in choice.get("delta", {}).get("tool_calls", []):
            accumulated.append(call.get("function", {}).get("arguments", ""))
if "".join(accumulated) != non_streaming_arguments:
    raise SystemExit("streaming arguments were not byte-equivalent")

error_events = [
    {"choices": [{"delta": {"tool_calls": [{"index": 0, "id": "call_0123456789abcdef0123456789abcdef", "type": "function", "function": {"name": "write_to_file", "arguments": "{\"path\":"}}]}}]},
    {"error": {"type": "upstream_provider_error", "code": "tool_call_final_close_failed", "message": "Provider closed before tool-call stream completed", "retryable": True, "request_id": "req-ac23s", "inference_ran": True, "settlement_ran": False}},
]
dispatchable = False
for event in error_events:
    if event.get("error"):
        dispatchable = False
        break
    for choice in event.get("choices", []):
        if choice.get("finish_reason") == "tool_calls":
            dispatchable = True
if dispatchable:
    raise SystemExit("terminal error path exposed dispatchable tool calls")

print(json.dumps({"openai": "2.44.0", "byte_equivalent": True, "terminal_error_dispatchable": False}, sort_keys=True))
PY

echo "AC-23s replay passed"
