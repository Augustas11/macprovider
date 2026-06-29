# SPEC-018 v0.2.4 IMPL — Product-Design r3 Audit

**Verdict:** FIX REQUIRED
**Tally:** C/H/M/m/Q = 0/1/0/0/0

## Closures verified

1. **AC-25a runtime crash — CLOSED.** `run_fixture.py` now passes a `key=` function to `max()` when selecting the large `write_to_file` call (`test/integration/cline_session/run_fixture.py:224`-`:232`). `python3 test/integration/cline_session/run_fixture.py --self-test` completed and wrote a fresh transcript. Note: `run_fixture.py` has no explicit `--self-test` parser, so the flag is ignored and the normal validation path runs.

2. **AC-44 timestamp placement — IMPLEMENTED, but product-compatible delivery is not closed.** `HTTPServer.swift` no longer puts `X-MacProvider-Provider-ToolCallOpen-Unix-Ms` in `writer.startSSE(...)`; the only extra SSE-start header there is `X-MacProvider-Provider-Unix-Ms` (`phase3-binary/Sources/macprovider-cli/HTTPServer.swift:460`-`:462`). The tool-call-open timestamp is emitted inside the `modelRuntime.stream(...)` closure on first `.toolCallDelta`, guarded by `toolCallOpenEmitted.setIfUnset()` (`phase3-binary/Sources/macprovider-cli/HTTPServer.swift:474`-`:493`). The coordinator parser recognizes `data: {"type":"macprovider_tool_call_open","unix_ms":...}` (`phase4-coordinator/internal/buyer/streaming_timing.go:110`-`:129`).

3. **NTP skew honesty — CLOSED.** Gateway no longer writes hardcoded `X-MacProvider-NTP-Skew-Ms`; the forward path sets gateway first-byte timing only (`phase5-gateway/internal/router/chat_proxy.go:209`-`:211`, `:358`-`:362`). The deploy doc now says `X-MacProvider-NTP-Skew-Ms` is **DEFERRED TO v0.3** and explains that v0.2 relies on OS-level NTP sync without runtime skew verification (`docs/operations/spec-018-v0.2-deploy.md:100`-`:105`). That reads honest to ops.

4. **AC-46 mismatch logging — CLOSED.** `validObservedModelHash` logs to stderr for non-empty malformed length and non-hex values before returning nil (`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:795`-`:807`). The new `testAC46_KnownButMalformedHashReturnsNilAndLogs` covers the malformed-known path (`phase3-binary/Tests/macprovider-cliTests/ToolCallParserTests.swift:7`-`:10`), and `swift test` printed the AC-46 malformed-hash log line.

5. **Sendable warnings — CLOSED.** `StreamedFlag` stores the flag state behind an `NSLock`, including `setIfUnset()` for first-open emission and `get()` for fallback logic (`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:1216`-`:1240`). `HTTPServer.swift` captures `StreamedFlag` instances, not bare mutable booleans (`phase3-binary/Sources/macprovider-cli/HTTPServer.swift:474`-`:495`, `:512`), and `InferenceRelay.swift` does the same for streamed tool-call fallback (`phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:425`-`:468`). `cd phase3-binary && swift test` passed: 578 tests, 0 failures, 7 skipped.

Verification also run: `cd phase4-coordinator && go test -count=1 ./internal/buyer` passed.

## Fresh findings

### H-1 — Buyer-visible `macprovider_tool_call_open` SSE is not skipped cleanly by the pinned Vercel AI SDK parser

The new marker is emitted as a normal `data:` SSE object with only `type` and `unix_ms` (`phase3-binary/Sources/macprovider-cli/HTTPServer.swift:490`-`:493`). It is buyer-visible: the coordinator commits on the initial OpenAI-shaped role chunk, then forwards later lines byte-for-byte to the buyer (`phase4-coordinator/internal/buyer/server.go:2581`-`:2590`, `:2625`-`:2627`, `:2643`-`:2667`), and the gateway preserves SSE line bytes (`phase5-gateway/internal/router/server_test.go:2462`-`:2480`).

The pinned Cline-compatible package is `@ai-sdk/openai-compatible@2.0.38` (`test/integration/streaming_terminal_error/package.json:8`-`:10`; `test/integration/streaming_terminal_error/package-lock.json:66`-`:74`). After `npm install`, its stream handler parses every non-`[DONE]` event through the OpenAI-compatible chunk schema (`test/integration/streaming_terminal_error/node_modules/@ai-sdk/provider-utils/dist/index.mjs:2284`-`:2295`, `:2577`-`:2588`). That chunk schema requires `choices: [...]` (`test/integration/streaming_terminal_error/node_modules/@ai-sdk/openai-compatible/dist/index.mjs:925`-`:945`). On schema failure, the chat model emits a stream error part rather than skipping the chunk (`test/integration/streaming_terminal_error/node_modules/@ai-sdk/openai-compatible/dist/index.mjs:648`-`:656`).

So the Cline/Vercel SDK path is not proven forward-compatible with this event shape; by source inspection it treats the marker as an error-producing chunk, not an ignored unknown event. That is product-blocking for the "narrow Cline drop-in" lane because every streamed tool-call path can inject this marker before the actual `tool_calls` delta reaches Cline.

## Verdict justification

FIX REQUIRED. Four of the five r3 mechanical fixes are closed, and the timestamp is correctly moved from SSE-start to first `.toolCallDelta` in phase3. The product-design blocker is the chosen wire placement: the new timestamp marker is forwarded to buyers as a non-OpenAI chunk, and the pinned Vercel AI SDK parser does not skip that shape cleanly. Remove the buyer-visible marker, hide it from downstream clients, or encode timing in a way that does not enter the OpenAI-compatible data stream before merge.
