# SPEC-018 v0.2.4 IMPL — Security r2 Audit

**Date:** 2026-06-28
**Reviewer:** codex security
**Commit audited:** `42476b7` on `impl/spec-018-v0-2`
**Verdict:** FIX REQUIRED

## Tally: C/H/M/m/Q

0/1/2/0/0

## Closure status per r1 finding

- **C-1 AC-48b false-positive Cline money-path test:** CLOSED. The r2 test now serves terminal-error SSE over HTTP, constructs `createOpenAICompatible`, passes `provider.chatModel(...)` into `streamText`, and iterates `result.fullStream` (`test/integration/streaming_terminal_error/ac48b_openai_compatible_terminal_error.test.ts:68-130`). Local run passed: `npm test -- --run ac48b_openai_compatible_terminal_error.test.ts`.
- **H-1 downgrade/kill-switch header-only behavior:** CLOSED for behavior. `forwardWSStreaming` and HTTP `forwardStreaming` now branch to buffered implementations when `streamingMode != incremental` (`phase4-coordinator/internal/buyer/server.go:2164-2165`, `:2488-2489`), and the buffered paths validate final-close before emitting a consolidated tool-call SSE (`:2361-2425`, `:2702-2733`).
- **M-1 AC-45 fixture coverage:** OPEN. The r2 tests still cover tuple isolation/recovery and provider-downgrade headers, but I found no kill-switch fixture for `COORDINATOR_STREAMING_FORCE_BUFFERED` / `buffered_kill_switch` and no request-log correlation assertion (`phase4-coordinator/internal/buyer/streaming_test.go:21-53`, `:154-174`).
- **M-2 AC-25a SPEC self-read coverage:** CLOSED relative to r1. The fixture now asserts a `read_file` call against `SPEC-018-agentic-tool-calling.md` (`test/integration/cline_session/run_fixture.py:218-223`). It remains a simulated-provider release fixture, but the runbook now explicitly lists the full live Cline automation as v0.3 work (`docs/operations/spec-018-v0.2-deploy.md:184-186`).
- **Q-1 process-local downgrade state:** CLOSED as documented. The deploy runbook states the downgrade map is in-memory, restart-local, and not multi-coordinator shared, with single-instance Pearl acceptable for v0.2 (`docs/operations/spec-018-v0.2-deploy.md:193-196`).

## Fresh findings

### HIGH findings

#### H-1 — Terminal SSE final-close errors still bypass the SPEC §10d.0 stable-code table

SPEC §10d.0 defines the buyer-visible HTTP/SSE error envelope codes and retryability table; `malformed_tool_call_final_json` is retryable=true, and `provider_stream_downgraded` is retryable=true (`specs/SPEC-018-agentic-tool-calling.md:755-776`). The r2 lookup table correctly encodes those table entries (`phase4-coordinator/internal/buyer/server.go:52-68`), but committed terminal SSE paths still emit non-table codes:

- `malformed_tool_call` after committed malformed stream validation (`phase4-coordinator/internal/buyer/server.go:2643-2652`)
- `tool_call_final_close_failed` when EOF arrives before final-close success (`phase4-coordinator/internal/buyer/server.go:2666-2676`)

Because `writeSSEError` computes `retryable` with `spec018Retryable(code)` and falls back to type `server_error` for unknown codes (`phase4-coordinator/internal/buyer/server.go:4831-4868`), these terminal Cline-relevant errors are buyer-visible with `retryable:false` and a type outside the §10d.0 allowed set. The AC-48b fixture also bakes `tool_call_final_close_failed` / `server_error` into the mocked terminal error (`test/integration/streaming_terminal_error/ac48b_openai_compatible_terminal_error.test.ts:45-55`), so the SDK gate proves fail-closed dispatch behavior but not SPEC envelope conformance.

Security impact: a final-close failure is exactly the case where Cline must not dispatch partial tool calls and should receive the documented retry signal. The stream now fails closed at the SDK boundary, but the buyer-visible retry contract still diverges from SPEC and can drive retry-vs-abandon policy incorrectly.

Fix: map terminal final-close/malformed stream failures to the stable §10d.0 code that represents the condition, or amend the SPEC table before merge. Add AC-48a/b assertions for `error.code`, `error.type`, and `error.retryable`.

### MEDIUM findings

#### M-1 — AC-45 still lacks kill-switch and request-log correlation fixtures

AC-45 requires fixtures for all three `X-MacProvider-Streaming-Mode` values and correlation between the header, operator/provider/buyer tuple state, and request log (`specs/SPEC-018-agentic-tool-calling.md:633-635`). r2 added behavioral buffering, and tuple isolation is tested (`phase4-coordinator/internal/buyer/streaming_test.go:21-53`, `:154-174`), but there is still no test that sets `COORDINATOR_STREAMING_FORCE_BUFFERED=1` and asserts `buffered_kill_switch`, no assertion that the kill-switch path is buffered-to-end, and no request-log correlation assertion.

This is no longer the r1 security bug, because the implementation has buffered paths. It remains under-specified release coverage for an operator safety switch.

#### M-2 — AC-46 known-non-hex mismatch is not covered by the self-test evidence

The provider wire behavior is safe for buyers: invalid observed hashes are normalized to `null` by `validObservedModelHash` (`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:795-802`), and tests cover known lowercase hex plus unknown/null (`phase3-binary/Tests/macprovider-cliTests/HTTPServerReceiptTests.swift:55-84`). But I found no r2 test or fixture branch where the local model-hash subsystem reports a known non-hex value and the release gate fails it as a mismatch. The AC-25a mock fixture only asserts the presence of one known hex value and `None` (`test/integration/cline_session/run_fixture.py:228-229`).

Security impact is limited because `usage.macprovider_model_hash_observed` is observation-only in v0.2 and excluded from parser selection, settlement, and receipt binding. The remaining issue is release-gate evidence: AC-46’s provider-side self-test requirement is not mechanically proven for the known-but-invalid branch.

## Positive checks

- AC-48a passed through `openai-python`: `./run-ac48a.sh` returned `{"passed": true, "sdk_exception": true, "dispatchable_tool_call": false}`.
- AC-48b passed through Vercel AI SDK: `npm test -- --run ac48b_openai_compatible_terminal_error.test.ts`.
- Downgrade state is per-(buyer, provider), process-local caveat is documented, and tuple isolation/recovery tests pass.
- AC-44 timing headers do not expose receipt-bearing data; the receipt leak guard still rejects other `X-MacProvider-*` headers while allowing only the v0.2 diagnostic suffixes (`phase3-binary/Tests/macprovider-cliTests/HTTPServerReceiptTests.swift:1083-1103`).
- Qwen3 upstream tokenizer digest verified: fetched `https://huggingface.co/Qwen/Qwen3-32B/raw/main/tokenizer_config.json` hashes to `d5d09f07b48c3086c508b30d1c9114bd1189145b74e982a265350c923acd8101` and is 9732 bytes, matching the pin.

## Verification

- `cd phase3-binary && swift test` — 577 tests, 7 skipped, 0 failures.
- `cd phase4-coordinator && go vet ./...` — pass.
- `cd phase4-coordinator && go test -count=1 ./internal/buyer` — pass.
- `cd phase4-coordinator && go test -count=1 ./internal/buyer -run 'TestStreaming|Test.*SSE|Test.*Retryable|TestChatCompletions.*Streaming'` — pass.
- `cd test/integration/streaming_terminal_error && ./run-ac48a.sh` — pass.
- `cd test/integration/streaming_terminal_error && npm test -- --run ac48b_openai_compatible_terminal_error.test.ts` — pass.

## Verdict justification

FIX REQUIRED. The r2 absorption materially improved the security posture: AC-48b now uses the actual Vercel SDK path, downgrade/kill-switch behavior now buffers rather than only flipping headers, timing/receipt leakage looks contained, and the process-local downgrade caveat is documented. The remaining blocker is that terminal SSE final-close failures still do not conform to the stable §10d.0 error-code/retryability contract. AC-45 and AC-46 also retain release-gate coverage gaps, both medium severity.
