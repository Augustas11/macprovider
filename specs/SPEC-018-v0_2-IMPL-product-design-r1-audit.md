# SPEC-018 v0.2.4 IMPL — Product-Design r1 Audit

**Date:** 2026-06-28
**Reviewer:** codex product-design
**Verdict:** FIX REQUIRED

## Tally: C/H/M/m/Q

0/1/2/1/1

## Findings

### CRITICAL findings

None.

### HIGH findings

#### H-1 — AC-25a and AC-48b harnesses are synthetic, so the Cline release gate can pass without exercising Cline or macprovider

Evidence:
- AC-25a requires a headless Cline fixture that runs through gateway -> coordinator -> v0.2 phase3 provider and emits real transcript evidence including request/response hashes, streaming mode headers, and `usage.macprovider_model_hash_observed` per response (`specs/SPEC-018-agentic-tool-calling.md:589`).
- AC-48b requires the Cline/OpenAI-compatible path to prove terminal final-close errors do not deliver dispatchable tool calls to Cline's AgentRuntime boundary (`specs/SPEC-018-agentic-tool-calling.md:641`).
- The landed Cline README explicitly says the fixture validates a "Cline-shaped transcript without launching VS Code" (`test/integration/cline_session/README.md:3`).
- `run_fixture.py` creates all turns, request IDs, timings, SSE hashes, tool calls, edits, command failures, history echoes, and the AC-48b result in-process (`test/integration/cline_session/run_fixture.py:28`, `test/integration/cline_session/run_fixture.py:103`, `test/integration/cline_session/run_fixture.py:128`), then validates that same generated transcript (`test/integration/cline_session/run_fixture.py:154`).
- The generated transcript lacks the required per-response `usage.macprovider_model_hash_observed` field; the only model-hash references are in Swift/unit tests and IMPL notes, not the AC-25a transcript harness.
- The AC-48b Vitest imports `@ai-sdk/openai-compatible`, but it does not drive the SDK stream or Cline runtime. It parses a hard-coded `terminalErrorStream` with a local accumulator (`test/integration/streaming_terminal_error/ac48b_openai_compatible_terminal_error.test.ts:12`, `test/integration/streaming_terminal_error/ac48b_openai_compatible_terminal_error.test.ts:19`).

Why this matters:
This is a release-gate hole, not just fixture polish. The harness can pass even if real Cline cannot complete a multi-turn session, ignores or mishandles the additive model-hash field, misses `X-MacProvider-Streaming-Mode`, or dispatches partial tool calls after a terminal final-close error. The IMPL notes are honest that this is a skeleton/replay contract (`specs/SPEC-018-v0_2-IMPL-NOTES.md:12`, `specs/SPEC-018-v0_2-IMPL-NOTES.md:38`), but AC-25a is stricter than "self-generated fixture data".

Recommended fix:
Make `run_fixture.py` validate an externally captured/headless Cline transcript instead of fabricating success. For AC-48b, mock `fetch` under `createOpenAICompatible` and drive the actual Vercel AI SDK streaming path to the same boundary Cline consumes, then assert no dispatchable tool call is emitted after terminal SSE error. Keep AC-25b as manual recorded smoke, but AC-25a must fail when real or recorded Cline evidence is absent or schema-incomplete.

### MEDIUM findings

#### M-1 — `X-MacProvider-Streaming-Mode` is only attached on streaming coordinator paths, despite the AC saying every v0.2 response carries it

Evidence:
- AC-45 says every v0.2 response includes `X-MacProvider-Streaming-Mode` and makes absence a fail condition (`specs/SPEC-018-agentic-tool-calling.md:633`).
- The coordinator sets the header in WS/direct streaming commits (`phase4-coordinator/internal/buyer/server.go:2144`, `phase4-coordinator/internal/buyer/server.go:2412`).
- The non-streaming HTTP success path writes provider/route/content headers and the body without setting the streaming-mode header (`phase4-coordinator/internal/buyer/server.go:1794`).

Impact:
Buyers and release evidence cannot uniformly distinguish default incremental behavior from operator kill-switch or downgrade state on non-streaming/fallback-compatible requests. This weakens the product observability contract and makes AC-45 evidence ambiguous outside streaming happy paths.

Recommended fix:
Set the diagnostic header centrally for all v0.2 chat-completions responses, including non-streaming success and request/provider error envelopes. For non-streaming requests, use the same state-derived value so buyers see whether streaming would have been incremental, kill-switched, or downgraded.

#### M-2 — Deploy checklist is not operator-friendly enough to run or audit the v0.2 release evidence

Evidence:
- The deploy doc only covers NTP/skew prerequisites and the skew-corrected formula (`docs/operations/spec-018-v0.2-deploy.md:1`).
- The actual kill-switch environment variable exists in code as `COORDINATOR_STREAMING_FORCE_BUFFERED=1` (`phase4-coordinator/internal/buyer/streaming_downgrade.go:89`), but the deploy doc does not name it.
- The metrics endpoint exists at `/metrics/streaming` (`phase4-coordinator/internal/buyer/server.go:456`), but the deploy doc does not tell operators to scrape it or what counters prove AC-44 sampling/skew skipping.
- The doc omits the AC-25b manual Cline smoke steps, expected artifacts, `X-MacProvider-Streaming-Mode` interpretation, and `usage.macprovider_model_hash_observed` evidence capture.

Impact:
An operator cannot use the committed deploy doc alone to collect AC-25b/AC-44/AC-45 evidence or debug "Cline feels buffered" reports. That is a product-readiness gap for the first release whose core promise is Cline streaming usability.

Recommended fix:
Expand the doc with a short release-evidence runbook: NTP check commands, kill-switch enable/disable commands, required header values, `/metrics/streaming` scrape expectations, AC-25b artifact checklist, and model-hash/header fields to capture per turn.

### Minor findings

#### m-1 — Cline fixture pin is not a repo URL + commit, and transcript records prompt text rather than prompt SHA

AC-25a asks for a pinned public test repo commit and prompt SHA in the transcript (`specs/SPEC-018-agentic-tool-calling.md:589`). The fixture config stores only `"target_repo": "spec018-ci-fixture"` and a prompt string (`test/integration/cline_session/fixture_config.json:7`). This is minor relative to H-1 because the harness must first stop fabricating its own transcript.

### Open questions

#### Q-1 — Is real AC-25b evidence required before merge, or only before release?

The IMPL notes say full live Cline automation remains manual smoke until CI can provision VS Code/Cline (`specs/SPEC-018-v0_2-IMPL-NOTES.md:12`). If the PR can merge before AC-25b evidence exists, the PR description should explicitly mark AC-25b as a release-blocking external artifact and name where that artifact will live.

## Verdict justification

FIX REQUIRED. The implementation appears to have the right buyer-facing intent, and two blind-spot checks passed: `OutputCanonicalizer.canonicalOutputObject` still has only `content`, `tool_calls`, and `finish_reason` (`phase3-binary/Sources/macprovider-cli/OutputCanonicalizer.swift:67`), and Cline `92806c60` really declares `@ai-sdk/openai-compatible` `^2.0.38` while importing `createOpenAICompatible` from that package. But the product-design gate cannot approve while AC-25a/AC-48b can pass on fabricated data and while streaming-mode/operator evidence is incomplete.
