# SPEC-018 v0.2.4 IMPL - Security r3 Audit

**Verdict:** FIX REQUIRED
**Tally:** C/H/M/m/Q = 0/1/0/0/0

## Closures verified

1. **AC-25a runtime crash:** CLOSED. `run_fixture.py` now calls `max(...)` with `key=lambda call: call.get("result", {}).get("bytes_written", 0)` at `test/integration/cline_session/run_fixture.py:224-232`. I ran `python3 run_fixture.py --self-test` from `test/integration/cline_session`; it completed and wrote `output/transcript-20260628T142055Z.json`.

2. **AC-44 timestamp placement:** PARTIALLY CLOSED, but see fresh HIGH finding. The old `X-MacProvider-Provider-ToolCallOpen-Unix-Ms` header is no longer in `writer.startSSE(...)`; only `X-MacProvider-Provider-Unix-Ms` remains at `phase3-binary/Sources/macprovider-cli/HTTPServer.swift:460-462`. The new `macprovider_tool_call_open` event is emitted inside the `modelRuntime.stream(...)` closure only in `case .toolCallDelta`, gated by `toolCallOpenEmitted.setIfUnset()` at `HTTPServer.swift:474-493`, so it fires on first observed tool-call delta rather than SSE start. `streaming_timing.go` parses the event via `toolCallOpenFromSSELine` at `phase4-coordinator/internal/buyer/streaming_timing.go:110-130`.

3. **NTP skew honesty:** CLOSED. The gateway no longer sets fake `X-MacProvider-NTP-Skew-Ms: 0` on the upstream request or buyer response; the relevant header writes now stop at gateway first-byte / SSE headers at `phase5-gateway/internal/router/chat_proxy.go:200-211` and `:358-362`. The deploy doc explicitly marks `X-MacProvider-NTP-Skew-Ms` as "DEFERRED TO v0.3" and says v0.2 relies on OS-level NTP sync without runtime skew verification at `docs/operations/spec-018-v0.2-deploy.md:100-105`.

4. **AC-46 mismatch logging:** CLOSED. `validObservedModelHash` logs non-empty malformed length and non-hex values before returning nil at `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:795-807`. The new test exercises the known-but-malformed path at `phase3-binary/Tests/macprovider-cliTests/ToolCallParserTests.swift:6-10`. `swift test` also showed the expected `AC-46: validObservedModelHash rejected malformed value: not-a-hex-string...` log and passed.

5. **Sendable warnings:** CLOSED. `streamedAnyToolCallDelta` and `toolCallOpenEmitted` are captured as `StreamedFlag` reference objects in `HTTPServer.swift:474-495`, and `InferenceRelay.swift` uses the same state wrapper for stream/fallback coordination at `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:425-468`. `StreamedFlag` protects the flag state itself with `NSLock`, including atomic `setIfUnset()`, at `ModelRuntime.swift:1216-1240`. `swift test` passed: 578 tests, 0 failures, 7 skipped.

Money-path posture was also rechecked. The same `FaultBreakerQualifying` classifications remain on relay timeouts/disconnects, malformed tool-call stream failures, final-close failures, buffered downgrade failures, and pre-commit failures in `phase4-coordinator/internal/buyer/server.go:2128-2134`, `:2279-2300`, `:2320-2356`, `:2377-2413`, `:2471`, `:2597-2617`, and `:2658-2727`.

## Fresh findings

### HIGH - `macprovider_tool_call_open` escapes the telemetry boundary and breaks gateway streaming

The new provider timing event is emitted as a normal SSE `data:` frame, then phase4 stores it in `preCommit` and writes `preCommit.Bytes()` to the downstream buyer/gateway once the first commit-worthy OpenAI chunk arrives (`phase4-coordinator/internal/buyer/server.go:2548-2582`, `:2625-2638`). That means the timing event is not coordinator-internal telemetry; it is buyer-visible stream data.

Phase5's streaming gateway does not skip unknown JSON SSE data. For every non-`[DONE]` `data:` line it calls `streamingCompletionDeltaBytes(data)` and, if the parsed payload has neither `choices` nor `usage`, writes `stream_malformed`, cancels upstream, and settles via the gateway-estimated malformed-stream path (`phase5-gateway/internal/router/chat_proxy.go:409-457`). A payload such as `{"type":"macprovider_tool_call_open","unix_ms":...}` unmarshals successfully but has no `choices`, so `streamingCompletionDeltaBytes` returns `hasChoices=false, parseOK=true` at `chat_proxy.go:682-702`; `usageFromJSON` also returns no usage at `chat_proxy.go:861-867`. The gateway therefore deterministically treats this new event as malformed.

Security impact: this is not just a timing side-channel. It turns the AC-44 telemetry event into buyer-visible wire data that can terminate tool-call streams at the gateway and route settlement through the `stream_malformed` path before the actual tool-call delta reaches the buyer. Direct coordinator clients also receive an internal provider timing signal that is not receipt-bearing and not needed for buyer settlement. The event should be consumed/stripped at phase4, moved to a non-buyer-visible channel, or made explicitly understood and ignored by every downstream streaming parser before merge.

## Verdict justification

FIX REQUIRED. Four fixes close mechanically, and the timestamp is now captured at the intended provider-side moment. The remaining blocker is containment: `macprovider_tool_call_open` is emitted in-band, forwarded to buyers/gateway, and phase5 rejects it as malformed SSE. That is a HIGH release blocker for security/money-path posture because it can force gateway error settlement on normal tool-call streams and exposes internal provider timing outside the telemetry boundary.

Verification run:

- `python3 run_fixture.py --self-test` from `test/integration/cline_session` - pass.
- `cd phase3-binary && swift test` - 578 tests, 0 failures, 7 skipped.
- `cd phase4-coordinator && go test -count=1 ./internal/buyer -run 'TestStreaming|Test.*SSE|Test.*Retryable|TestChatCompletions.*Streaming'` - pass.
- `cd phase5-gateway && go test -count=1 ./internal/router -run 'Test.*Streaming|Test.*SSE|TestChatCompletions'` - pass, but current tests do not cover the new cross-hop unknown SSE event.
