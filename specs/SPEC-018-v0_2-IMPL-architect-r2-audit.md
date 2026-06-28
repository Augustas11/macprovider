# SPEC-018 v0.2.4 IMPL - Architect r2 Audit

**Date:** 2026-06-28
**Reviewer:** codex architect
**Commit audited:** `42476b7` on `impl/spec-018-v0-2`
**Verdict:** FIX REQUIRED

## Tally: C/H/M/m/Q

0/2/0/1/0

## Closure Status Per r1 Finding

### Architect r1 HIGH-1 - Provider streaming is post-generation fragmenting

**Status: CLOSED.**

The provider streaming architecture now has a real `StreamChunk` protocol boundary. `ModelRuntimeServing.stream` accepts `onChunk: @Sendable (StreamChunk) -> Void`, `StreamChunk` carries `.content` or `.toolCallDelta`, and `StreamToolCallDelta.openAIDeltaDict()` converts the provider-side event into OpenAI SSE shape (`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:16`, `:23`, `:28`, `:37`).

The real runtime instantiates `NativeToolCallStreamEmitter` before generation and calls `toolStreamer.observe(candidate.text)` from inside the generation callback, emitting `.toolCallDelta` chunks before final completion (`ModelRuntime.swift:553`, `:556`, `:566`, `:567`). The emitter tracks native delimiters and emits the first delta with `id`/`type`/`function.name`, then additive `function.arguments` fragments (`ModelRuntime.swift:974`, `:995`, `:1008`, `:1016`). `HTTPServer` and `InferenceRelay` both consume those chunks directly (`phase3-binary/Sources/macprovider-cli/HTTPServer.swift:475`, `:488`; `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:425`, `:436`).

Residual note: the implementation still carries a Swift 6 strict-concurrency risk around closure-captured `streamedAnyToolCallDelta`, documented in `IMPL-NOTES.md`; current Swift 5 test mode passes.

### Architect r1 HIGH-2 - Buffered kill-switch and downgrade modes are header-only

**Status: CLOSED at coordinator, with a fresh gateway-surface finding below.**

The coordinator now branches on `streamingMode != incremental` before incremental forwarding in both WS and direct HTTP streaming (`phase4-coordinator/internal/buyer/server.go:2159`, `:2164`; `:2476`, `:2488`). The buffered WS path accumulates the provider stream, validates final-close, consolidates tool calls, and only writes to the buyer after success (`server.go:2361`, `:2402`, `:2408`, `:2415`). The direct HTTP path mirrors that behavior (`server.go:2702`, `:2709`, `:2716`, `:2723`).

### Architect r1 HIGH-3 - AC-25a harness validates a fabricated transcript

**Status: NOT CLOSED. See HIGH-1.**

The harness is improved because it launches a separate mock provider process and issues real HTTP requests to it (`test/integration/cline_session/run_fixture.py:33`, `:96`, `:101`, `:239`). It is no longer only validating a same-process in-memory object. However, the release-gate harness currently fails before producing a transcript, so it is not usable evidence.

### Architect r1 MEDIUM-1 - IMPL notes overstate completed architecture

**Status: MOSTLY CLOSED.**

`IMPL-NOTES.md` now states the StreamChunk boundary and explicitly calls out the AC-25a skeleton/full-Cline split plus in-memory downgrade-state limits (`specs/SPEC-018-v0_2-IMPL-NOTES.md:166`, `:176`, `:200`, `:203`). The remaining mismatch is covered by fresh findings: the public gateway does not preserve the buyer-visible diagnostic headers, and AC-25a does not pass.

### Architect r1 Q-1 - In-process downgrade state and production topology

**Status: CLOSED AS DOCUMENTED LIMITATION.**

The deploy runbook explicitly says downgrade state is in-memory, process-local, does not survive restart, and does not propagate across multi-coordinator deployments; it limits v0.2 acceptance to the single Pearl coordinator deployment (`docs/operations/spec-018-v0.2-deploy.md:193`).

## Fresh Findings

### HIGH-1 - AC-25a release-gate harness fails at runtime

`run-cline-session.sh` fails on this checkout:

```text
TypeError: '>' not supported between instances of 'dict' and 'dict'
```

The failing code is `max(call for call in transcript["tool_calls"] ...)` in `validate()` (`test/integration/cline_session/run_fixture.py:224`). The fixture appends many large `write_to_file` calls to meet the `tool_calls` minimum (`run_fixture.py:130`), so Python tries to compare multiple dicts and aborts.

This leaves AC-25a without a passing CI-amenable transcript harness. The harness design is acceptable as a v0.2 mock-provider bridge only if it actually runs and emits the machine-readable transcript. Current state is structurally unsound release evidence, not READY TO MERGE.

### HIGH-2 - Buyer-visible v0.2 diagnostic headers are stripped or absent at the public gateway

SPEC-018 says buyers get `X-MacProvider-Streaming-Mode` on every v0.2 response (`specs/SPEC-018-agentic-tool-calling.md:53`, `:633`) and AC-44/runbook text treats provider/coordinator/gateway timing headers as observable diagnostics. The coordinator sets `X-MacProvider-Streaming-Mode` only in streaming branches (`phase4-coordinator/internal/buyer/server.go:2176`, `:2420`, `:2532`, `:2728`), and non-streaming coordinator success paths do not set it (`server.go:1818`, `:1823`, `:1825`).

More importantly, the public gateway strips upstream MacProvider headers by default. `copyCleanHeadersWithReceipt` drops any `x-macprovider-*` header unless it is the receipt header (`phase5-gateway/internal/router/server.go:796`, `:801`). Streaming gateway forwarding calls `copyCleanHeaders` and then only adds gateway-local timing/skew headers (`phase5-gateway/internal/router/chat_proxy.go:359`, `:360`). Non-streaming forwarding calls `copyReceiptEligibleHeaders`, which has the same stripping behavior except for receipts (`chat_proxy.go:314`; `server.go:792`).

Result: through the normal gateway path, buyers do not receive the coordinator's streaming-mode header, and they also do not receive provider/coordinator timing headers. This violates the buyer-visible diagnostic contract and would make a real AC-25a Cline-through-gateway transcript fail the "missing `X-MacProvider-Streaming-Mode`" criterion.

Fix direction: define an explicit allowlist for v0.2 diagnostic headers at the gateway (`X-MacProvider-Streaming-Mode`, provider/coordinator/gateway timing/skew headers as intended) and set a sane value for non-streaming v0.2 responses if the SPEC keeps "every v0.2 response" literal. Add gateway-level tests for streaming and non-streaming responses.

### minor-1 - Runbook metric names drift from implementation

The runbook sample uses `macprovider_streaming_skew_skipped_total` and `macprovider_streaming_first_delta_latency_p95_ms` (`docs/operations/spec-018-v0.2-deploy.md:135`, `:139`), while the implementation emits `macprovider_streaming_timing_skew_skipped_total`, `macprovider_streaming_forward_lag_p95_ms`, and `macprovider_streaming_gateway_lag_p95_ms` (`phase4-coordinator/internal/buyer/streaming_timing.go:116`, `:118`, `:119`). This is operator-documentation drift, not a structural blocker by itself.

## Positive Evidence

- `cd phase3-binary && swift test` passed: 577 tests, 0 failures, 7 skipped.
- `cd phase4-coordinator && go vet ./... && go test -count=1 ./internal/buyer` passed.
- `cd test/integration/streaming_terminal_error && ./run-ac48b.sh` passed and the test invokes `createOpenAICompatible` directly (`test/integration/streaming_terminal_error/ac48b_openai_compatible_terminal_error.test.ts:109`).
- Qwen3 tokenizer pin is byte-exact: fetching `https://huggingface.co/Qwen/Qwen3-32B/raw/main/tokenizer_config.json` produced SHA-256 `d5d09f07b48c3086c508b30d1c9114bd1189145b74e982a265350c923acd8101` and byte size 9732, matching `tools/version-pins/qwen3-tokenizer-config-v0_2_4.txt:5`.
- Llama-3.3 pin is honest about being structural rather than byte-exact because the HuggingFace config is access-gated (`tools/version-pins/llama3_3-tokenizer-config-v0_2_4.txt:4`, `:7`).
- The receipt leak guard extension preserves receipt-bearing header protection while allowing the new v0.2 diagnostic suffixes only (`phase3-binary/Tests/macprovider-cliTests/HTTPServerReceiptTests.swift:1082`).

## Verdict Justification

The core StreamChunk refactor and coordinator buffering separation are architecturally coherent after r1 absorption. Provider streaming now has a proper incremental event boundary, and coordinator downgrade/kill-switch behavior now buffers instead of merely changing a header.

The implementation is not merge-ready because one release-gate harness currently fails at runtime, and the public gateway strips or omits the buyer-visible diagnostic headers that AC-45/AC-44 require. These are HIGH release-readiness gaps, so the architect lane verdict remains **FIX REQUIRED**.
