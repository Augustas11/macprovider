# SPEC-018 v0.2.4 IMPL — Architect r3 Audit

**Verdict:** FIX REQUIRED
**Tally:** C/H/M/m/Q = 0/1/0/0/0

## Closures verified

1. **AC-25a fixture crash — CLOSED.** `test/integration/cline_session/run_fixture.py:224-232` now calls `max(..., key=lambda call: call.get("result", {}).get("bytes_written", 0))`, so dict comparison no longer triggers `TypeError`. Validation: `cd test/integration/cline_session && python3 run_fixture.py --self-test` completed and wrote a transcript path.

2. **AC-44 timestamp placement — PLACEMENT CLOSED, WIRE SHAPE NOT CLOSED.** `phase3-binary/Sources/macprovider-cli/HTTPServer.swift:460-462` no longer sends `X-MacProvider-Provider-ToolCallOpen-Unix-Ms` at SSE start. The new timestamp is emitted only inside the `modelRuntime.stream(...)` closure on first `.toolCallDelta`, gated by `toolCallOpenEmitted.setIfUnset()` at `HTTPServer.swift:474-494`. `phase4-coordinator/internal/buyer/streaming_timing.go:110-130` parses the `macprovider_tool_call_open` payload.

3. **NTP skew honesty — CLOSED.** The gateway call sites no longer set the fake `X-MacProvider-NTP-Skew-Ms: 0`: `phase5-gateway/internal/router/chat_proxy.go:200-211` sets request id and gateway-first-byte only, and `chat_proxy.go:358-362` sets response streaming headers without skew. `docs/operations/spec-018-v0.2-deploy.md:100-105` honestly marks `X-MacProvider-NTP-Skew-Ms` as deferred to v0.3.

4. **AC-46 malformed observed model hash logging — CLOSED.** `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:795-808` logs non-empty bad-length and non-hex values before returning `nil`. `phase3-binary/Tests/macprovider-cliTests/ToolCallParserTests.swift:7-10` covers the known-but-malformed path returning `nil` without fatal error.

5. **Sendable flag state — CLOSED.** `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:1216-1240` defines `StreamedFlag` as an `NSLock`-protected wrapper around the boolean state itself. `HTTPServer.swift:474-512` and `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:425-468` capture wrapper instances and mutate/read state through `set()`, `setIfUnset()`, and `get()`, so the closure captures the synchronized state holder, not just a lock.

## Fresh findings

### H-1 — `macprovider_tool_call_open` is buyer-visible as a non-OpenAI SSE chunk

`HTTPServer.swift:490-493` emits the timing marker through `writer.writeSSEJSON`, and `writeSSEJSON` always formats payloads as normal `data: <json>` SSE records via `writeRawSSEData` at `HTTPServer.swift:1032-1036` and `HTTPServer.swift:1091-1095`. The payload is:

```json
{"type":"macprovider_tool_call_open","unix_ms":...}
```

That is not an OpenAI chat-completion chunk: it has no `id`, `object`, `created`, `model`, or `choices`.

The coordinator does not consume-and-strip this instrumentation event. In the direct HTTP streaming path, `phase4-coordinator/internal/buyer/server.go:2567-2581` observes `toolCallOpenFromSSELine(line)` and then still appends the same line to `preCommit`; after the first commit-worthy tool-call delta, `server.go:2625-2628` writes `preCommit.Bytes()` to the buyer. For post-commit lines, `server.go:2644-2664` writes every line to the buyer as read.

This conflicts with the locked stream-shape contract. SPEC-018 says buyer-visible streaming responses MUST use OpenAI-style SSE chat-completion chunks (`specs/SPEC-018-agentic-tool-calling.md:344`), and §10c permits additive fields / SSE delta shapes only if existing parsing is not broken (`specs/SPEC-018-agentic-tool-calling.md:687-703`). A temporary local probe against the pinned `openai==2.44.0` streaming client showed the payload is not skipped: it is yielded as an extra `ChatCompletionChunk` with `choices = null` and the custom `type` / `unix_ms` fields. Normal OpenAI-compatible consumers that do `chunk.choices[0]...` can fail on this injected chunk, and Cline/Vercel AI SDK tolerance is not proven here.

Architectural fix direction: keep `t_tool_call_open_detected` out of the buyer-visible OpenAI stream. The coordinator can consume the provider-private timing marker and strip it before forwarding, or the timestamp can move to a provider/coordinator side channel/header that is not exposed as a chat-completions `data:` chunk. The public stream should contain only OpenAI-compatible chunks and `[DONE]`.

## Verdict justification

The r2 mechanical closures are mostly real: the crash fix executes, the timestamp no longer fires at SSE start, fake skew is removed, malformed model hashes now log, and the Swift flag state is synchronized. The implementation is still not ready to merge because the AC-44 repair introduces a new public SSE record outside the OpenAI chat-completions shape. That violates the v0.1.5/v0.2 forward-compatibility invariant and leaves the Cline drop-in stream contract structurally unsafe.
