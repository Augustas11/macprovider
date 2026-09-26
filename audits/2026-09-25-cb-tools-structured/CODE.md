## Lane: CODE

Check:
- Serial/batched equality of the SSE and JSON shapes: tool_calls, tool-call deltas, `finish_reason`, and structured-validation errors.
- Row-stop truncation and token accounting (usage `completion_tokens` must match what was emitted and billed).
- Byte caps; streaming idle state; cancellation during a stopped row; stop sequences combined with tool turns.
- The regression risk to the serial path from the extraction refactor. Diff the old and new serial behaviour.
- Tests that would fail on a real regression.
