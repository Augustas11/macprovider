# SPEC-018 v0.2 Implementation Notes

Date: 2026-06-28
Branch: `impl/spec-018-v0-2`

## Deliverable Summary

- Deliverable #1, multi-turn provider acceptance (AC-25 through AC-29): phase3 now preserves assistant-history `tool_calls[]` and `role:"tool"` messages in `ChatCompletionRequest`, validates the in-request graph, renders Qwen/Llama-family native tool history via `ToolPromptRenderer`, and binds prompt hashes to tool-call IDs and tool results.
- Deliverable #4, token-incremental streaming (AC-40 through AC-45c): phase3 emits OpenAI-shaped incremental `tool_calls[].function.arguments` deltas; coordinator final-close validation splits buyer-visible streaming commit from money-path settlement commit; streaming mode is surfaced with `X-MacProvider-Streaming-Mode`; per-(buyer, provider) downgrade is tuple-scoped.
- Deliverable #6, request-side validation (AC-30 through AC-34): Swift and Go paths reject malformed, duplicate, missing, out-of-order, or orphaned `tool_call_id` values and enforce linear caps before inference.
- Deliverable #7, byte caps (AC-35 through AC-39): parser/coordinator limits are raised to 1 MiB per tool call and 2 MiB aggregate, counted over decoded UTF-8 bytes, with streaming cap-cross paths producing terminal SSE errors.
- Supporting AC-25a: `test/integration/cline_session/` contains a pinned, CI-amenable Cline transcript harness. It is a skeleton/replay contract, not a full VS Code launch. Full live Cline automation remains a release-gate manual smoke until CI can provision VS Code/Cline.
- Supporting AC-44: `phase4-coordinator/internal/buyer/streaming_timing.go` records provider-open, coordinator-first-forward, and gateway-first-byte evidence when headers are present, skips samples with provider/gateway skew above 100 ms, and exposes Prometheus-style text at `/metrics/streaming`.
- Supporting AC-46: `usage.macprovider_model_hash_observed` is emitted in non-streaming responses, streaming final usage chunks, and relay zero-usage terminal frames. It remains additive and outside output canonicalization.
- Supporting AC-48a/b: `test/integration/streaming_terminal_error/` covers terminal SSE error behavior for `openai==2.44.0` and Cline's Vercel AI SDK path through `@ai-sdk/openai-compatible@2.0.38`.

## Fixture Locations

- Swift multi-turn/request/hash tests: `phase3-binary/Tests/macprovider-cliTests/MultiTurnTests.swift`, `PromptCanonicalizerTests.swift`, `OutputCanonicalizerTests.swift`, `PromptOutputCanonicalizerParityTests.swift`, `HTTPServerReceiptTests.swift`, `InferenceRelayTests.swift`.
- Go coordinator streaming/request tests: `phase4-coordinator/internal/buyer/multi_turn_test.go`, `streaming_test.go`, `streaming_timing.go`, `streaming_timing_test.go`.
- Cline AC-25a harness: `test/integration/cline_session/run-cline-session.sh`, `run_fixture.py`, `fixture_config.json`.
- AC-48 terminal-error harnesses: `test/integration/streaming_terminal_error/run-ac48a.sh` and `run-ac48b.sh`.
- Cline transcript evidence path: `test/integration/cline_session/output/transcript-<timestamp>.json`.

## Money-Path Trace Evidence

- WS streaming final-close failure writes terminal SSE error and marks `FaultBreakerQualifying`: `phase4-coordinator/internal/buyer/server.go:2254`.
- WS streaming provider error/disconnect/timeout after commit returns `FaultBreakerQualifying`: `phase4-coordinator/internal/buyer/server.go:2266`, `server.go:2287`, `server.go:2301`, `server.go:2324`.
- Direct HTTP streaming pre-commit malformed/cap/timeout/disconnect paths mark `FaultBreakerQualifying`: `phase4-coordinator/internal/buyer/server.go:2474`.
- Direct HTTP streaming post-incremental-open malformed/final-close/transport failure paths mark `FaultBreakerQualifying`: `phase4-coordinator/internal/buyer/server.go:2528`, `server.go:2551`, `server.go:2572`.
- Billing formula preserves zero provider-positive credits when the row carries `FaultBreakerQualifying`: `phase4-coordinator/internal/billing/formula.go:112`.
- Billing recorder carries the fault flag into hot-path settlement input: `phase4-coordinator/internal/buyer/billing_recorder.go:181`.

## Interpretation Calls

- Section 3.8 chat-template rendering: v0.2 keys the input render profile by model-family/modelID match. Hash-keyed registry enforcement remains deferred to v0.3 per the locked spec amendments.
- Section 10d.0 error envelope: v0.2 thick error envelope fields apply consistently to old and new provider errors. The loading-state fixture now expects `retryable`, `request_id`, `inference_ran`, and `settlement_ran`.
- AC-25a Cline fixture: this implementation lands an executable transcript/schema/assertion harness with deterministic fixture data. It does not claim full VS Code extension automation in CI.
- AC-46 model hash observation: `macprovider_model_hash_observed` is response metadata only. It is not included in `OutputCanonicalizer.canonicalOutputObject`, prompt/output hashes, receipt output binding, parser selection, or settlement decisions.
- AC-48 split: openai-python behavior is tested separately from the Cline/Vercel AI SDK accumulator boundary because Cline v4.0.0 uses `@ai-sdk/openai-compatible`, not openai-python.

## Verification Commands

```bash
cd phase3-binary && swift test
cd ../phase4-coordinator && go vet ./... && go test -count=1 ./internal/buyer
cd ../test/integration/cline_session && ./run-cline-session.sh
cd ../streaming_terminal_error && ./run-ac48a.sh && ./run-ac48b.sh
cd ../.. && git diff --check
```
