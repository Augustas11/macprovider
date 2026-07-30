# SPEC-018 AC-48 Terminal Streaming Error Fixtures

This directory contains executable fixtures for the v0.2.4 terminal SSE error split.

- `run-ac48a.sh` installs `openai==2.44.0` from `tools/version-pins/openai-python-spec-018-v0_1_3-baseline.txt` and verifies the Python streaming reader never yields a successful dispatchable `tool_calls[]` message after a terminal `data: {"error": ...}` frame.
- `run-ac48b.sh` installs `@ai-sdk/openai-compatible@2.0.38`, matching Cline `main@92806c60`'s OpenAI-compatible provider dependency floor, and runs a Vitest accumulator-boundary fixture.

Both fixtures replay a stream that opens a tool call incrementally, emits partial arguments, then terminates with a final error event and `[DONE]`.
