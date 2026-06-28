# SPEC-018 v0.2.4 IMPL — Security r1 Audit

**Date:** 2026-06-28
**Reviewer:** codex security
**Verdict:** FIX REQUIRED

## Tally: C/H/M/m/Q

1/1/2/0/1

## Findings

### CRITICAL findings

#### C-1 — AC-48b is a false-positive Cline money-path test

`test/integration/streaming_terminal_error/ac48b_openai_compatible_terminal_error.test.ts` claims to cover the Cline/Vercel terminal-error path, but it does not route the mocked stream through Vercel AI SDK or Cline's `AgentRuntime` boundary. It imports `createOpenAICompatible` and instantiates a provider (`:1-2`, `:54-61`), then ignores that provider. The actual pass/fail logic is a handwritten local parser over a static string array (`:12-17`, `:19-52`, `:63-66`).

That does not satisfy AC-48b, which requires a Cline v4.0.0 OpenAI-compatible provider-path fixture proving terminal final-close failure does not deliver dispatchable `tool_calls[]` to Cline's runtime boundary (`specs/SPEC-018-agentic-tool-calling.md:639-641`). The dependency pin itself matches Cline's declared floor: Cline `92806c60` declares `@ai-sdk/openai-compatible: ^2.0.38` in [`sdk/packages/llms/package.json`](https://raw.githubusercontent.com/cline/cline/92806c60/sdk/packages/llms/package.json), and imports `createOpenAICompatible` in [`sdk/packages/llms/src/providers/vendors/openai-compatible.ts`](https://raw.githubusercontent.com/cline/cline/92806c60/sdk/packages/llms/src/providers/vendors/openai-compatible.ts); the local fixture pins exact `2.0.38` (`tools/version-pins/cline-vercel-ai-sdk-openai-compatible-v0_2_4.txt:1`, `test/integration/streaming_terminal_error/package.json:8-10`). But the test never exercises the package behavior on the terminal-error stream.

Security impact: this is the Cline-specific money-path gate for "buyer may have seen partial tool deltas, but settlement must fail and Cline must not execute them." A passing test can currently coexist with a broken SDK/runtime integration.

Fix: serve the terminal-error SSE over a mocked HTTP endpoint and consume it through the same Vercel AI SDK path Cline uses, or through a thin extracted Cline runtime adapter. The assertion must fail if the SDK/runtime yields or executes a successful assistant tool call after the error frame.

### HIGH findings

#### H-1 — Streaming kill switch and per-buyer downgrade are header-only, not buffered-to-end behavior

AC-45 and §10d.4 require the operator kill switch and tuple downgrade to force buffered-to-end behavior (`specs/SPEC-018-agentic-tool-calling.md:633`, `:836-838`). The implementation computes the mode in `streamingMode()` (`phase4-coordinator/internal/buyer/streaming_downgrade.go:89-97`), but the mode is only used for response headers and timing labels (`phase4-coordinator/internal/buyer/server.go:2135-2149`, `:2365-2418`, `:2511-2515`).

The streaming dispatch still sends the original `stream:true` body to the upstream provider: `forwardStreamSequence` calls `dispatchBodyForProvider` and then `forwardWS(..., stream=true, ...)` or `forwardStreaming(...)` (`phase4-coordinator/internal/buyer/server.go:1463-1479`). `dispatchBodyForProvider` returns `req.raw` unchanged except for a model replacement (`phase4-coordinator/internal/buyer/server.go:3196-3257`); it never flips `stream` to false and no caller switches to the non-streaming forwarding path.

The current AC-45c test proves only that buyer A receives `X-MacProvider-Streaming-Mode: buffered_provider_downgrade` and buyer B receives `incremental`; it does not assert buyer A is actually buffered (`phase4-coordinator/internal/buyer/streaming_test.go:21-52`). I ran the targeted tests and they pass:

```bash
cd phase4-coordinator && go test -count=1 ./internal/buyer -run 'TestStreamingModeHeaderAdversarialBuyerDoesNotDowngradeOtherBuyer|TestAutoDowngradeIsScopedPerBuyerProvider'
```

Security impact: the protective fallback promised after malformed streams is not enforced. A bad provider/buyer tuple can keep receiving incremental streamed tool-call deltas while the coordinator merely labels the response as downgraded.

Fix: before dispatching a streaming request, if `streamingMode != incremental`, either rewrite the upstream request to `stream:false` and forward through the non-streaming path, or buffer the upstream stream internally and release only after final-close success. Add tests that assert `buffered_kill_switch` and `buffered_provider_downgrade` do not expose incremental SSE chunks to the buyer.

### MEDIUM findings

#### M-1 — AC-45 coverage omits kill-switch and request-log correlation requirements

AC-45 requires fixtures for all three header values and correlation between header, operator/provider/buyer tuple state, and request log (`specs/SPEC-018-agentic-tool-calling.md:633`). The added tests cover `incremental` and `buffered_provider_downgrade`, but `rg` finds no test for `COORDINATOR_STREAMING_FORCE_BUFFERED` / `buffered_kill_switch` outside implementation constants. The existing test also does not inspect request-log state.

This is partly a test gap behind H-1: a real behavioral assertion would have caught the header-only implementation.

#### M-2 — AC-25a SPEC self-read coverage is only file-existence, not a Cline `read_file` case

The Cline fixture copies `specs/SPEC-018-agentic-tool-calling.md` into a generated workspace (`test/integration/cline_session/run_fixture.py:20-25`) and validates only that the file exists (`:150-151`). No transcript turn actually calls `read_file` on that file, and no follow-up tool call proves self-reading did not break the session. AC-25a's fail condition explicitly includes "SPEC-018 self-reading breaks a legitimate follow-up tool call" (`specs/SPEC-018-agentic-tool-calling.md:589`).

Because v0.2 deletes the prompt-echo guard, this is not an immediate self-DoS implementation bug. It is still under-specified release evidence for the Cline/security regression that motivated the deletion.

### Minor findings

None.

### Open questions

#### Q-1 — Is per-(buyer, provider) downgrade intentionally process-local?

The downgrade store is an in-memory map on `Server` (`phase4-coordinator/internal/buyer/streaming_downgrade.go:19-63`). It survives multiple HTTP requests handled by the same process, but not coordinator restart and not a horizontally scaled/distributed coordinator deployment. The SPEC says "future requests" but does not explicitly require durable or shared state (`specs/SPEC-018-agentic-tool-calling.md:633`, `:836`). Clarify whether v0.2 deployment is single-process-only for this protection, or persist/share the tuple state.

## Verdict justification

FIX REQUIRED. The positive security checks are meaningful: `OutputCanonicalizer.canonicalOutputObject` excludes `usage.macprovider_model_hash_observed` (`phase3-binary/Sources/macprovider-cli/OutputCanonicalizer.swift:59-71`), the response `usage` helpers emit the field outside canonical scope (`phase3-binary/Sources/macprovider-cli/HTTPServer.swift:858-864`, `InferenceRelay.swift:653-668`), terminal SSE errors do not carry `finish_reason:"tool_calls"` (`phase4-coordinator/internal/buyer/server.go:4537-4539`), and the audited final-close failure exits feed `FaultBreakerQualifying` into billing where it zeroes credits (`phase4-coordinator/internal/buyer/server.go:2254-2273`, `:2528-2583`; `phase4-coordinator/internal/buyer/billing_recorder.go:181-198`; `phase4-coordinator/internal/billing/formula.go:112-114`).

The merge blockers are independent of those passes: AC-48b does not actually test the Cline runtime path it claims to test, and AC-45's downgrade/kill-switch implementation only changes observability headers, not streaming behavior.
