# SPEC-018 v0.2.4 IMPL - Code r2 Audit

**Date:** 2026-06-28
**Reviewer:** codex code
**Commit audited:** `42476b7` on `impl/spec-018-v0-2`
**Verdict:** FIX REQUIRED

## Tally: C/H/M/m/Q

0 / 1 / 1 / 0 / 0

## Closure status per r1 finding

- **H-1 streaming downgrade / kill-switch was header-only: CLOSED.** Both streaming forwarders now branch before buyer-visible commit when `streamingMode != incremental`: `forwardWSStreaming` calls `forwardWSStreamingBuffered` at `phase4-coordinator/internal/buyer/server.go:2159-2165`, and HTTP `forwardStreaming` calls `forwardStreamingBuffered` at `phase4-coordinator/internal/buyer/server.go:2476-2489`. The buffered paths validate final close before writing (`:2402-2421`, `:2710-2729`) and emit a consolidated SSE response after validation (`:2408`, `:2716`).
- **H-2 AC-48b did not exercise Vercel AI SDK: CLOSED.** `test/integration/streaming_terminal_error/ac48b_openai_compatible_terminal_error.test.ts:109-123` now constructs `createOpenAICompatible(...)`, calls `provider.chatModel(...)`, and drives the stream through `streamText(...).fullStream`. `./run-ac48b.sh` passed.
- **M-1 coordinator streaming validators did not enforce provider-emitted tool-call ID regex: OPEN.** See fresh M-1 below.
- **M-2 coordinator v0.2 error envelopes missed thick fields: CLOSED.** `writeSSEError` now emits `retryable`, `request_id`, `inference_ran`, and `settlement_ran` at `phase4-coordinator/internal/buyer/server.go:4831-4846`; `writeErrorTyped` does the same for JSON errors at `:5013-5029`. Swift and Go retryable lookup tables match SPEC §10d.0's 16 listed codes at `phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift:245-262` and `phase4-coordinator/internal/buyer/server.go:52-69`.
- **Q-1 process-local downgrade state: RESOLVED AS DOCUMENTED.** The deploy doc explicitly says the downgrade map is in-memory, restart-local, and not propagated across multi-coordinator deployments at `docs/operations/spec-018-v0.2-deploy.md:193-196`.

## Fresh findings

### CRITICAL findings

None.

### HIGH findings

#### H-1. AC-25a harness crashes before producing the claimed Cline-session transcript

`test/integration/cline_session/run-cline-session.sh` is the documented AC-25a release-gate harness (`specs/SPEC-018-v0_2-IMPL-NOTES.md:219-220`), but it currently fails:

```text
TypeError: '>' not supported between instances of 'dict' and 'dict'
```

Root cause: `fixture_config.json` requires 30 tool calls and a 65,536-byte write threshold (`test/integration/cline_session/fixture_config.json:10-18`). `run_fixture.py` pads the scenario with repeated large `write_to_file` calls (`test/integration/cline_session/run_fixture.py:140-155`), then calls `max(...)` directly on matching call dictionaries at `:224`. Once more than one large write matches, Python tries to compare dictionaries and crashes before writing `output/transcript-<timestamp>.json`.

This keeps AC-25a from being a usable CI release gate. The separate-process mock-provider structure is present, but the validator cannot complete with the committed config.

Fix: select the large write with an explicit key, e.g. `max(candidates, key=lambda call: call["result"]["bytes_written"])`, and keep the existing empty-candidate failure explicit. Re-run `cd test/integration/cline_session && ./run-cline-session.sh` and commit the passing transcript evidence if that is part of the release artifact.

### MEDIUM findings

#### M-1. Provider-emitted streaming tool-call IDs still bypass the SPEC regex

SPEC §8.4.1 requires provider-emitted streaming IDs to match `^call_[a-f0-9]{32}$`: `specs/SPEC-018-agentic-tool-calling.md:485-491`, restated at `:876-880`. The coordinator still only checks that the opening ID is non-empty:

- Incremental-open gate: `isCommitWorthyToolCallDelta` rejects empty IDs but does not validate the domain at `phase4-coordinator/internal/buyer/server.go:3067-3097`.
- Final-close validator: `observeToolCall` also only requires a non-empty opening ID at `phase4-coordinator/internal/buyer/server.go:3190-3217`.
- The new streaming fixtures use `call_0123456789abcdef` at `phase4-coordinator/internal/buyer/streaming_test.go:17` and `:56`, which is 16 hex characters after `call_`, not the required 32.

Request-accepted IDs have a different, broader rule in §10d.6; that broader helper at `phase4-coordinator/internal/buyer/server.go:3783-3795` does not close the provider-emitted streaming requirement.

Fix: add a provider-emitted ID validator for exactly `call_` plus 32 lowercase hex characters, call it from both streaming validators, and update the streaming tests to use 32-hex IDs plus negative cases for short, uppercase, punctuation, and wrong prefix.

### Minor findings

None.

### Open questions

None.

## Positive checks

- The `StreamChunk` refactor is coherent in the Swift provider path: `StreamChunk` is a typed enum at `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:23-26`; `ModelRuntime.stream` emits `.toolCallDelta(...)` fragments during generation at `:555-602`; HTTP and WS relay paths translate those chunks into OpenAI-shaped SSE and preserve a final-result fallback at `phase3-binary/Sources/macprovider-cli/HTTPServer.swift:475-518` and `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:425-480`.
- The `HTTPServerReceiptTests` MacProvider-header guard preserves the receipt-leak intent by excluding only the v0.2 diagnostic/timing suffixes while still treating other `X-MacProvider-*` headers as forbidden (`phase3-binary/Tests/macprovider-cliTests/HTTPServerReceiptTests.swift:1082-1094`).
- Qwen3 tokenizer pin verified against upstream raw file: fetched byte size `9732`, SHA-256 `d5d09f07b48c3086c508b30d1c9114bd1189145b74e982a265350c923acd8101`, matching `tools/version-pins/qwen3-tokenizer-config-v0_2_4.txt:3-6`. Llama-3.3 is honestly documented as structural/gated rather than byte-exact at `tools/version-pins/llama3_3-tokenizer-config-v0_2_4.txt:3-8`.
- AC-48a and AC-48b now exercise real SDK paths and passed locally: `./run-ac48a.sh` reported `sdk_exception: true` with no dispatchable tool call, and `./run-ac48b.sh` passed one Vitest test through `@ai-sdk/openai-compatible`.

## Validation evidence

- `cd phase3-binary && swift test` - PASS, 577 tests, 0 failures, 7 skipped.
- `cd phase4-coordinator && go vet ./... && go test -count=1 ./internal/buyer` - PASS.
- `cd test/integration/streaming_terminal_error && ./run-ac48a.sh` - PASS.
- `cd test/integration/streaming_terminal_error && ./run-ac48b.sh` - PASS.
- `cd test/integration/cline_session && python3 run_fixture.py` - FAIL with the AC-25a `max(dict)` crash above.
- `git diff --check` - PASS.

## Verdict justification

FIX REQUIRED. The r1 high-risk streaming and AC-48b issues are mechanically closed, and the main Swift/Go smoke tests pass. However, AC-25a is a claimed release-gate harness and currently crashes under its committed config, and the r1 provider-emitted streaming ID regex gap remains open. This is not READY TO MERGE under the requested 0/0/0 bar.
