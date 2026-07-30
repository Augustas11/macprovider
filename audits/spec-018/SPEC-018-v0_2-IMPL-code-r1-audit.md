# SPEC-018 v0.2.4 IMPL — Code r1 Audit

**Date:** 2026-06-28
**Reviewer:** codex code
**Verdict:** FIX REQUIRED

## Tally: C/H/M/m/Q

0 / 2 / 2 / 0 / 1

## Findings

### CRITICAL findings

None.

### HIGH findings

#### H-1. Streaming downgrade / kill-switch modes are header-only; they do not switch behavior to buffered-to-end

SPEC-018 requires operator-forced buffering and per-(buyer, provider) auto-downgrade to "buffered-to-end" behavior, not just a diagnostic label: `specs/SPEC-018-agentic-tool-calling.md:836-838`. The implementation computes a mode string in `phase4-coordinator/internal/buyer/streaming_downgrade.go:89-97`, but the forwarding paths always execute the same incremental pass-through code. `forwardStreaming` sets `X-MacProvider-Streaming-Mode` at `phase4-coordinator/internal/buyer/server.go:2412-2419`, then immediately writes the pre-commit bytes and continues line-by-line forwarding at `phase4-coordinator/internal/buyer/server.go:2505-2583`. `forwardWSStreaming` has the same pattern at `phase4-coordinator/internal/buyer/server.go:2135-2150` and `:2186-2195`.

The AC-45c test misses this by asserting only the downgraded header for buyer A, then asserting buyer B still sees streamed `tool_calls`: `phase4-coordinator/internal/buyer/streaming_test.go:21-52`. It never asserts that buyer A's downgraded response was actually buffered or withheld until final-close. A malformed provider will still stream incrementally to a downgraded buyer; only the header changes.

Fix: branch on `streamingModeBufferedKillSwitch` and `streamingModeBufferedProviderDowngrade` before buyer-visible commit, buffer tool-call SSE until final-close succeeds, then emit the completed OpenAI-shaped tool call response. Add tests that downgraded/kill-switch responses do not expose incremental `tool_calls[].function.arguments` fragments before final-close.

#### H-2. AC-48b is not anchored to the Cline-locked dependency or SDK stream behavior

The local pin claims `@ai-sdk/openai-compatible==2.0.38` in `tools/version-pins/cline-vercel-ai-sdk-openai-compatible-v0_2_4.txt:1`, and the test fixture installs exact `2.0.38` in `test/integration/streaming_terminal_error/package.json:7-10`. The named upstream Cline commit does not actually lock that version. At `cline/cline@92806c60`, `sdk/packages/llms/package.json` declares `@ai-sdk/openai-compatible: "^2.0.38"`, while `bun.lock` resolves `@ai-sdk/openai-compatible@2.0.51`. The vendor file does import `createOpenAICompatible` from that package at `sdk/packages/llms/src/providers/vendors/openai-compatible.ts`.

The local AC-48b test also does not drive the SDK's streaming parser or Cline's provider wrapper. It instantiates `createOpenAICompatible(...)` only as a truthy import check, then feeds a hard-coded SSE transcript into a custom `accumulateAtAgentRuntimeBoundary` function: `test/integration/streaming_terminal_error/ac48b_openai_compatible_terminal_error.test.ts:19-67`. That proves the local helper marks terminal errors non-dispatchable; it does not prove the Cline/Vercel AI SDK path does.

Fix: update the pin artifact and fixture to the resolved Cline lock version for `92806c60` (`2.0.51`), or explicitly justify testing the lower semver floor separately. Then run a mocked fetch/HTTP stream through `createOpenAICompatible` and the same wrapper shape Cline uses, asserting the SDK/runtime boundary does not surface dispatchable tool calls after the terminal SSE error.

### MEDIUM findings

#### M-1. Coordinator streaming validators do not enforce provider-emitted `tool_call_id` regex

SPEC-018 incremental-open requires provider-emitted IDs to match `^call_[a-f0-9]{32}$`: `specs/SPEC-018-agentic-tool-calling.md:481-491`, with the domain restated at `:876-880`. The Swift provider mints lowercase hyphenless UUID IDs in `phase3-binary/Sources/macprovider-cli/ToolCallParser.swift:91` and `:110`, but the coordinator accepts any non-empty opening ID. `isCommitWorthyToolCallDelta` checks only non-empty `id`, type, name, and argument presence at `phase4-coordinator/internal/buyer/server.go:2773-2803`; `streamToolCallFinalValidator.observeToolCall` repeats that shape check at `:2896-2923`.

Result: an HTTP/WS provider can stream `id:"not valid"` or a mixed-case/punctuated ID, pass commit/final-close validation, and settle if the final arguments parse. That violates the coordinator half of §8.4.1 and leaves buyers with non-SPEC tool call IDs.

Fix: add a `validProviderToolCallID` helper for `call_` plus exactly 32 lowercase hex bytes, call it in both incremental-open validators, and add negative tests for uppercase, short, long, punctuation, and non-`call_` prefixes.

#### M-2. Coordinator v0.2 error envelopes are missing the required thicker fields

SPEC-018 v0.2-introduced HTTP and terminal SSE errors require OpenAI-style envelopes with `retryable`, `request_id`, `inference_ran`, and `settlement_ran`: `specs/SPEC-018-agentic-tool-calling.md:734-753`. The Swift-side `APIError.envelope` includes those fields in `phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift:259-272`, but coordinator errors do not. `writeSSEError` emits only `message`, `type`, and `code`: `phase4-coordinator/internal/buyer/server.go:4537-4540`; `writeErrorTyped` emits only `message`, `type`, `param`, and `code`: `phase4-coordinator/internal/buyer/server.go:4684-4697`.

This affects v0.2 paths such as `tool_call_final_close_failed`, `malformed_tool_call`, `request_body_too_large`, and multi-turn validation errors. It also weakens Cline/operator actionability because `retryable` and settlement/inference state are absent exactly on the new terminal-stream failure modes.

Fix: route v0.2-introduced coordinator errors through a shared envelope builder that includes the required fields and request ID. For terminal SSE errors after incremental-open, set `inference_ran:true`, `settlement_ran:false`, and the code-specific retryability from the SPEC table.

### Minor findings

None.

### Open questions

#### Q-1. Downgrade state is process-local only

`streamingDowngradeStore` is an in-memory map on `Server`: `phase4-coordinator/internal/buyer/streaming_downgrade.go:19-31`. It survives ordinary HTTP requests in the same process, but not coordinator restart and not multiple coordinator replicas. The SPEC text requires per-(buyer, provider) attribution but does not explicitly state whether restart/distributed durability is required for v0.2. If production runs more than one coordinator process, the release notes should either scope this as best-effort per process or move the tuple state to shared storage.

## Verdict justification

FIX REQUIRED because the implementation has one behavioral miss in the streaming downgrade/kill-switch path and one structurally unsound Cline AC-48b fixture. Both sit on deliverable/supporting-work acceptance criteria that this IMPL claims to close.

Positive checks: `OutputCanonicalizer.canonicalOutputObject` excludes `macprovider_model_hash_observed`; `ToolPromptRenderer` does throw `unsupported_modelID_for_multi_turn` for multi-turn Qwen/Llama misses; request-side `tool_call_id` validation is map/set based and accepts `^call_[A-Za-z0-9]{16,64}$`; 1 MiB / 2 MiB byte caps are enforced over decoded UTF-8 strings in the Swift and Go request/streaming paths inspected.

Validation run: `cd phase4-coordinator && go test -count=1 ./internal/buyer` passed on 2026-06-28 (`ok`, 2.204s). This confirms the current tests pass while missing the findings above.
