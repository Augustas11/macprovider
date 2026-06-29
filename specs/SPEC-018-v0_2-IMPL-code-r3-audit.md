# SPEC-018 v0.2.4 IMPL — Code r3 Audit

**Verdict:** FIX REQUIRED
**Tally:** C/H/M/m/Q = 0/1/0/0/0

## Closures verified

1. **AC-25a runtime crash: CLOSED.** `test/integration/cline_session/run_fixture.py:224-232` now calls `max(..., key=lambda call: call.get("result", {}).get("bytes_written", 0))`, so dict comparison is no longer used. `python3 test/integration/cline_session/run_fixture.py --self-test` completed and wrote `test/integration/cline_session/output/transcript-20260628T142004Z.json`. Note: `--self-test` is not an implemented flag; the script ignores argv and the real harness calls `python3 run_fixture.py` at `test/integration/cline_session/run-cline-session.sh:4`.

2. **AC-44 timestamp placement: PARTIALLY CLOSED.** The old `X-MacProvider-Provider-ToolCallOpen-Unix-Ms` header is removed from `writer.startSSE(...)`; only `X-MacProvider-Provider-Unix-Ms` remains at `phase3-binary/Sources/macprovider-cli/HTTPServer.swift:460-462`. The new timestamp fires inside the `modelRuntime.stream(...)` closure, gated by `toolCallOpenEmitted.setIfUnset()`, exactly on first `.toolCallDelta` at `HTTPServer.swift:474-493`. Coordinator parsing is present: `toolCallOpenFromSSELine` recognizes the event at `phase4-coordinator/internal/buyer/streaming_timing.go:110-129`, and `forwardStreaming` captures it before timing observation at `phase4-coordinator/internal/buyer/server.go:2567-2570` and `:2631-2636`. However, the new SSE frame is buyer-visible and breaks the SDK compatibility expectation; see fresh H-1.

3. **NTP skew honesty: CLOSED.** The gateway no longer emits fake `X-MacProvider-NTP-Skew-Ms: 0` in the upstream request or buyer response paths: `phase5-gateway/internal/router/chat_proxy.go:209-211` and `:358-361` now omit the header. The deploy doc honestly marks `X-MacProvider-NTP-Skew-Ms` as `DEFERRED TO v0.3` at `docs/operations/spec-018-v0.2-deploy.md:100-105`.

4. **AC-46 mismatch logging: CLOSED.** `ModelRuntime.validObservedModelHash` logs non-empty length failures and non-hex 64-byte failures before returning `nil` at `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:795-807`. `phase3-binary/Tests/macprovider-cliTests/ToolCallParserTests.swift:7-10` covers the known-but-malformed path. The full Swift test run emitted `AC-46: validObservedModelHash rejected malformed value: not-a-hex-string...` during that test and passed.

5. **Sendable warnings: CLOSED.** `streamedAnyToolCallDelta` is now a shared `StreamedFlag` reference in both `HTTPServer.swift:474-475` / `:495` / `:512` and `InferenceRelay.swift:425-437` / `:468`. `StreamedFlag` protects the flag state, not only the lock, with `NSLock` around `value` in `ModelRuntime.swift:1216-1240`; `setIfUnset()` is atomic for the first-tool-call-open gate. `cd phase3-binary && swift test` passed 578 tests with 0 failures and 7 skipped; grep of the build log found no Swift Sendable/non-sendable warnings, only expected runtime tool-parser warning messages.

## Fresh findings

### H-1. `macprovider_tool_call_open` is emitted as a buyer-visible OpenAI `data:` chunk, and openai-python does not skip it safely

`HTTPServer.swift:489-493` writes the telemetry marker with `writer.writeSSEJSON`, so the wire frame is a normal SSE `data: {"type":"macprovider_tool_call_open","unix_ms":...}` item. The coordinator parser observes it but does not strip it: the pre-commit loop records the timestamp at `phase4-coordinator/internal/buyer/server.go:2567-2570`, then still appends the same line to `preCommit` at `:2581` and forwards `preCommit.Bytes()` to the buyer at `:2627`.

I probed the repo's pinned `openai==2.44.0` environment (`test/integration/streaming_terminal_error/.venv-ac48a`) with a successful stream containing this extra frame. The SDK did not skip it; it yielded:

`ChatCompletionChunk(id=None, choices=None, created=None, model=None, object=None, ..., type='macprovider_tool_call_open', unix_ms=1710000000000)`

That is not a safe unknown chunk for normal consumers. The repo's own AC-48a-style loop iterates `for choice in chunk.choices` at `test/integration/streaming_terminal_error/ac48a_openai_python_terminal_error.py:98-102`, which raises `TypeError` on this emitted chunk. This violates the §10c forward-compatibility requirement that additive streaming changes not break existing parsing (`specs/SPEC-018-agentic-tool-calling.md:681-703`) and undermines AC-43's successful-stream compatibility target (`specs/SPEC-018-agentic-tool-calling.md:629`).

The timestamp-placement bug is fixed mechanically, but the chosen telemetry carrier is not merge-ready. The marker needs to be kept off the buyer-visible OpenAI chunk stream, or carried in a shape proven to be skipped by the pinned openai-python and Cline/Vercel AI SDK readers.

## Verdict justification

Four fixes are closed outright, and the AC-44 timing moment is now captured at the first `.toolCallDelta` rather than SSE start. The remaining blocker is the new carrier for that timestamp: it is forwarded to buyers as a normal OpenAI-compatible SSE data frame, and the pinned openai-python streaming reader yields a chunk with `choices=None` instead of skipping it. Under the requested 0/0/0 bar, this HIGH wire-compatibility regression keeps the IMPL at **FIX REQUIRED**.

Validation run:

- `python3 test/integration/cline_session/run_fixture.py --self-test` - pass, transcript written.
- `cd phase3-binary && swift test` - pass, 578 tests / 0 failures / 7 skipped.
- `cd phase4-coordinator && go test -count=1 ./internal/buyer` - pass.
