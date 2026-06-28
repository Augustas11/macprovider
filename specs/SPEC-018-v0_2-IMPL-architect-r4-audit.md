**Verdict:** READY TO MERGE
**Tally:** C/H/M/m/Q = 0/0/0/0/0

## Closure verified
The r3 architectural blocker is closed. `HTTPServer.swift` no longer emits a buyer-visible custom `data:` chunk for `macprovider_tool_call_open`; on first streamed `.toolCallDelta` it now writes the raw SSE comment `: macprovider_tool_call_open unix_ms=<N>\n\n` (`phase3-binary/Sources/macprovider-cli/HTTPServer.swift:488-492`). The new `writeRawSSE` path bypasses `writeRawSSEData`'s `data: ...\n\n` wrapper and writes the payload bytes directly (`phase3-binary/Sources/macprovider-cli/HTTPServer.swift:1049-1058`, `:1095-1104`), so the marker is not an OpenAI chat-completion chunk.

This is compatible with the SSE/EventSource model. The HTML Standard's server-sent event parsing algorithm treats lines starting with `:` as comments and ignores them (WHATWG HTML, server-sent events parsing: https://html.spec.whatwg.org/multipage/server-sent-events.html#parsing-an-event-stream). That means forwarding the comment inside the regular SSE response does not amend the buyer-visible OpenAI `data:` stream shape.

The coordinator still observes the timing internally. `toolCallOpenFromSSELine` recognizes only the comment prefix `: macprovider_tool_call_open unix_ms=`, parses the integer millisecond value, and returns a UTC `time.Time` (`phase4-coordinator/internal/buyer/streaming_timing.go:108-118`). `forwardStreaming` captures the first matching marker before commit inspection/forwarding (`phase4-coordinator/internal/buyer/server.go:2563-2571`) and passes it into `observeFromHeadersAndProviderOpen` for `/metrics/streaming` timing samples (`phase4-coordinator/internal/buyer/server.go:2636`). The comment is then forwarded byte-identically like any other SSE line, but EventSource-compliant readers ignore it.

AC-23/AC-43 forward compatibility still holds for the pinned Python baseline. I ran a local mock `/v1/chat/completions` stream against `openai==2.44.0` from `test/integration/streaming_terminal_error/.venv-ac48a`: the stream began with `: macprovider_tool_call_open unix_ms=1800000000000\n\n`, then normal tool-call delta chunks. The reader yielded exactly the three real chat chunks, did not yield the comment as a chunk, accumulated `{"path":"a.txt"}`, and finished with `tool_calls`.

The Cline/Vercel path is also no longer structurally exposed to the r3 failure mode. A direct probe against the pinned `@ai-sdk/openai-compatible@2.0.38` under `test/integration/streaming_terminal_error/node_modules/` produced normal `tool-input-*` / `tool-call` parts and no `error` part when the stream began with the same SSE comment line.

Validation evidence:
- `cd phase3-binary && swift test` -> 578 tests, 0 failures, 7 skipped.
- `cd phase4-coordinator && go test -count=1 ./internal/buyer` -> ok.
- Local `openai==2.44.0` SSE mock probe -> comment dropped, tool-call accumulation preserved.
- Local `@ai-sdk/openai-compatible@2.0.38` mock probe -> no `AI_TypeValidationError`, tool call parsed.

## Fresh findings
None.

## Verdict justification
The architectural invariant from SPEC-018 §10c remains intact: v0.2 streaming still uses OpenAI-compatible `data:` chat-completion chunks for buyer-visible semantic content, and the new timing marker is an SSE comment rather than a custom chunk. That closes the r3 wire-shape regression without changing settlement behavior, request acceptance, tool-call delta semantics, or product-facing Cline UX. AC-44 timing remains operator-internal through coordinator metrics, while AC-23/AC-43's `openai==2.44.0` forward-compat baseline continues to parse and accumulate the stream without raising.
