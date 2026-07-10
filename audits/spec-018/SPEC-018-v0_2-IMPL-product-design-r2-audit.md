# SPEC-018 v0.2.4 IMPL — Product-Design r2 Audit

**Date:** 2026-06-28
**Reviewer:** codex product-design
**Lane:** product-design
**Commit audited:** `42476b7` on `impl/spec-018-v0-2`
**Verdict:** FIX REQUIRED

## Tally: C/H/M/m/Q

1/1/1/1/0

## Verification Performed

- `cd phase3-binary && swift test` — PASS: 577 tests, 0 failures, 7 skipped, 37.418s.
- `cd phase4-coordinator && go vet ./... && go test -count=1 ./internal/buyer` — PASS.
- `cd test/integration/streaming_terminal_error && ./run-ac48b.sh` — PASS: Vitest ran the Vercel AI SDK path.
- `cd test/integration/cline_session && ./run-cline-session.sh` — FAIL: Python `TypeError` in AC-25a validation.

## Closure Status Per r1 Finding

### H-1 — AC-25a and AC-48b harnesses are synthetic

**Partially closed, still blocking.**

AC-48b is closed for the prior import-and-ignore defect. The test now constructs a provider with `createOpenAICompatible` and drives `streamText` over `result.fullStream` (`test/integration/streaming_terminal_error/ac48b_openai_compatible_terminal_error.test.ts:109`, `:119`, `:123`), and `./run-ac48b.sh` passes.

AC-25a is not closed. The CI fixture currently fails at runtime, and even after fixing that, it remains a Python mock endpoint rather than Cline through gateway -> coordinator -> v0.2 phase3 provider.

### M-1 — `X-MacProvider-Streaming-Mode` missing outside streaming paths

**Still open.**

SPEC AC-45 requires every v0.2 response to include the header (`specs/SPEC-018-agentic-tool-calling.md:633`). The real coordinator writes it in streaming/buffered streaming paths (`phase4-coordinator/internal/buyer/server.go:2176`, `:2420`, `:2532`, `:2728`), but the WS non-streaming success path writes JSON/provider/route/receipt headers and returns without setting it (`phase4-coordinator/internal/buyer/server.go:2113`-`:2118`).

### M-2 — Deploy checklist not operator-friendly enough

**Closed with one minor doc drift.**

The deploy runbook now covers NTP prerequisites, the kill switch, buyer-visible streaming-mode semantics, downgrade scope/recovery, `/metrics/streaming`, rollback, and v0.3 limitations (`docs/operations/spec-018-v0.2-deploy.md:9`, `:41`, `:68`, `:106`, `:126`, `:166`, `:181`). The one remaining issue is metric-name drift in the sample output, listed as minor below.

### m-1 — Cline fixture pin lacks repo URL/commit and prompt SHA

**Still open, subsumed by H-1.**

The fixture config still records `"target_repo": "spec018-ci-fixture"` and raw prompt text, not a public repo URL/commit plus prompt SHA (`test/integration/cline_session/fixture_config.json:7`-`:8`). This is not counted separately because the AC-25a harness is currently a higher-severity blocker.

### Q-1 — AC-25b evidence merge vs release timing

**Resolved for this audit.**

The notes and runbook clearly treat full live Cline automation/manual evidence as release evidence and v0.3 CI work (`specs/SPEC-018-v0_2-IMPL-NOTES.md:22`, `:166`, `:200`; `docs/operations/spec-018-v0.2-deploy.md:183`). No separate open question remains in this lane.

## Fresh Findings

### C-1 — AC-25a release-gate script fails, so the claimed CI-amenable Cline transcript evidence is not available

SPEC AC-25a is a release gate and says any missing criterion or invalid transcript schema is a fail condition (`specs/SPEC-018-agentic-tool-calling.md:589`). The implementation notes list `run-cline-session.sh` as the AC-25a verification command (`specs/SPEC-018-v0_2-IMPL-NOTES.md:219`-`:220`).

Actual command result:

```text
cd test/integration/cline_session && ./run-cline-session.sh
TypeError: '>' not supported between instances of 'dict' and 'dict'
```

The crash is in `validate()` while selecting a large write with `max(...)` over matching call dictionaries and no key function (`test/integration/cline_session/run_fixture.py:224`). Because the script exits non-zero before writing a fresh passing transcript, AC-25a evidence is absent. Under the provided severity bar, this is CRITICAL: a release-gate test claim is wrong.

### H-1 — AC-25a still validates a generated mock transcript, not Cline through macprovider

The r1 absorption changed the harness to use a separate process, but that process is a local Python `ThreadingHTTPServer`, not gateway -> coordinator -> phase3 provider. It fabricates tool-call responses, request IDs, streaming mode, and `usage.macprovider_model_hash_observed` (`test/integration/cline_session/run_fixture.py:33`, `:50`, `:71`, `:77`, `:92`). The driver sends synthetic metadata to that mock endpoint (`test/integration/cline_session/run_fixture.py:103`-`:108`) and then records tool calls from the response it generated itself (`test/integration/cline_session/run_fixture.py:141`-`:183`).

The transcript also fabricates AC-44 timing evidence and the AC-48b result instead of deriving them from real streaming/Cline behavior (`test/integration/cline_session/run_fixture.py:176`-`:181`, `:200`-`:203`, `:224`-`:227`, `:230`). The README remains explicit that the fixture validates a "Cline-shaped transcript without launching VS Code" (`test/integration/cline_session/README.md:3`-`:4`).

This leaves the product-design risk from r1 intact: the harness can pass without proving Cline can complete the v0.2 workflow through macprovider, without proving a real large write streams incrementally, and without proving Cline ignores `usage.macprovider_model_hash_observed` in actual runtime behavior. This is HIGH because AC-25a remains structurally unsound as a Cline release gate.

### M-1 — `X-MacProvider-Streaming-Mode` is still absent from a real non-streaming success response

The docs and IMPL notes now state the header is on every v0.2 response (`docs/operations/spec-018-v0.2-deploy.md:70`; `specs/SPEC-018-v0_2-IMPL-NOTES.md:47`-`:49`, `:112`-`:113`), but the coordinator still has a successful non-streaming response path that sets `Content-Type`, provider, route, and receipt headers, then writes `200 OK` without `streamingModeHeader` (`phase4-coordinator/internal/buyer/server.go:2113`-`:2118`).

This is product-visible observability drift: a buyer or release-evidence collector cannot uniformly distinguish default incremental mode from kill-switch/downgrade state on all v0.2 responses. Severity remains MEDIUM.

### m-1 — Deploy runbook metric names do not match `/metrics/streaming`

The runbook sample advertises `macprovider_streaming_skew_skipped_total` and `macprovider_streaming_first_delta_latency_p95_ms` (`docs/operations/spec-018-v0.2-deploy.md:135`-`:141`). The implementation emits `macprovider_streaming_timing_skew_skipped_total`, `macprovider_streaming_forward_lag_p95_ms`, and `macprovider_streaming_gateway_lag_p95_ms` (`phase4-coordinator/internal/buyer/streaming_timing.go:116`-`:119`).

This is minor runbook drift, but it matters for the 3 AM operator path because copying the documented metric names into dashboards or alerts will miss the real series.

## Positive Checks

- The `retryable` envelope is now useful for retry-vs-abandon decisions: Swift and Go both include per-code lookup tables matching SPEC §10d.0 for v0.2 codes (`phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift:245`-`:261`; `phase4-coordinator/internal/buyer/server.go:52`-`:68`), and SSE errors carry the lookup result (`phase4-coordinator/internal/buyer/server.go:4836`-`:4846`).
- AC-48b now exercises the actual Vercel AI SDK entry point rather than a hand-rolled parser, and the local test passed.
- The expanded IMPL-NOTES are coherent for an IMPL reviewer: they map deliverables to ACs, state interpretation calls, and enumerate v0.3 deferrals (`specs/SPEC-018-v0_2-IMPL-NOTES.md:12`, `:157`, `:184`).
- The deploy doc is now broadly actionable for ops: it documents NTP, kill switch, downgrade behavior, rollback, and known limitations.

## Verdict Justification

FIX REQUIRED. Core Swift and Go smoke checks are green, AC-48b is materially improved, and the operator narrative is much stronger. Product-design cannot approve r2 because AC-25a currently fails to run and, once fixed, still does not validate the Cline/macprovider release path required by the SPEC. The streaming-mode header gap also remains on a real non-streaming coordinator success path. Current tally is not merge-ready: 1 CRITICAL, 1 HIGH, 1 MEDIUM.
