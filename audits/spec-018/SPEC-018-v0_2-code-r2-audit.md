# SPEC-018 v0.2.1 — Code Lane r2 Audit

**Date:** 2026-06-27
**Reviewer:** codex code lane
**Verdict:** FIX REQUIRED

## Tally: C/H/M/m/Q

C=0 CRITICAL / H=1 HIGH / M=2 MEDIUM / m=0 minor / Q=0 questions

## Prior r1 Finding Closure

### H-1 — §3.8 family renderer byte-specifiability: CLOSED
- v0.2.1 location: `specs/SPEC-018-agentic-tool-calling.md:219-288`; AC-26/AC-27 at `:562-567`.
- Evidence: §3.8.1 now supplies a common OpenAI `messages[]` fixture and Qwen3/Llama-3.3 renderer structures, with a required upstream tokenizer-config commit or artifact digest when the SPEC does not pin byte-exact output directly.
- Code-lens result: This is sufficient for implementation gating: byte-exact where upstream templates are byte-stable, structural plus pinned upstream artifact where they are not. No remaining r1 H-1 blocker.

### H-2 — Missing `tool_call_id` two-code mismatch: CLOSED
- v0.2.1 location: failure table at `specs/SPEC-018-agentic-tool-calling.md:721-735`; §10d.6 codes at `:855-858`; AC-32 at `:546-548`.
- Evidence: missing `role:"tool".tool_call_id` now maps to HTTP 400 `invalid_tool_call_id` with `param:"messages[i].tool_call_id"` at `:727`, matching §10d.6 and AC-32.
- Code-lens result: The request-validation code contract is now single-valued. No remaining r1 H-2 blocker.

### H-3 — Code-citation drift: NOT CLOSED
- v0.2.1 fixed the r1-named citations:
  - `ModelRuntime.swift:353` and `:403` are the two `validateToolCallingV1Scope` call sites.
  - `server.go:2103` is `forwardWSStreaming`; `server.go:2149` is the buyer byte write.
  - `server.go:1241-1245` preserves `ToolCallID` and `ToolCalls`.
- Residual blocker: §10a still cites `phase4-coordinator/internal/buyer/server.go:3743-3764` as "hash-verification routing eligibility" at `specs/SPEC-018-agentic-tool-calling.md:610`, but live code at `server.go:3743-3764` is `modelClassMembers` plus `hasInternalRoutingHeader`, not hash routing. The live hash-routing exclusion path is around `server.go:3291-3324` and helper predicates at `server.go:3873-3913`.
- Code-lens result: The explicit r1 anchors are fixed, but the required "all other live-repo paths cited in v0.2 sections" sweep found a stale N>5 citation in the v0.2 target section. H-3 remains open.

### H-4 — AC-25 / AC-44 / AC-45 reproducibility: CLOSED
- v0.2.1 location: AC-25a/AC-25b at `specs/SPEC-018-agentic-tool-calling.md:552-558`; AC-44/AC-45 at `:591-593`; §10d.4 header enum at `:745-747`.
- Evidence: AC-25 is split into CI fixture plus manual smoke, with pinned Cline extension/version, pinned repo/prompt, machine-readable transcript schema, minimum turn/tool/edit/shell criteria, and failure conditions. AC-44 names three timestamps plus p95 targets. AC-45 requires fixtures for all three `X-MacProvider-Streaming-Mode` values.
- Code-lens result: The ACs are now independently implementable from the SPEC text. No remaining r1 H-4 blocker.

### M-1 — §10d.4 SSE example concrete ID: CLOSED
- v0.2.1 location: `specs/SPEC-018-agentic-tool-calling.md:751-767`.
- Evidence: The example now uses `call_0123456789abcdef0123456789abcdef`, which matches the provider-emitted regex `^call_[a-f0-9]{32}$`.
- Code-lens result: No remaining r1 M-1 blocker.

### M-2 — AC-39 vs AC-43 success/error scope: CLOSED
- v0.2.1 location: AC-39 at `specs/SPEC-018-agentic-tool-calling.md:581`; AC-43 at `:589`; §8.4.3 at `:479-483`.
- Evidence: AC-39 now allows OpenAI SDKs to surface terminal SSE errors as exceptions/failed streams. AC-43 explicitly scopes no-parse-error to successful streams.
- Code-lens result: Error-path SDK exceptions no longer conflict with successful-stream accumulation. No remaining r1 M-2 blocker.

### Q-1 — Final-close requires `finish_reason:"tool_calls"`: CLOSED
- v0.2.1 location: §8.4.2 at `specs/SPEC-018-agentic-tool-calling.md:459-475`; §10d.4 at `:769-773`; AC-47/AC-48 at `:597-599`.
- Evidence: Final-close now requires accumulated terminal argument state, JSON object/depth/byte caps, `finish_reason:"tool_calls"`, normal transport completion marker, and no post-open disconnect/timeout/relay/auth/truncation failure. Failure is `FaultBreakerQualifying`, zero provider-positive credits, no receipt, no sticky-route success write.
- Live-code consistency: `server.go:2239-2255` records WS post-commit disconnect/timeout faults; `server.go:2476-2487` records direct-HTTP post-commit disconnect faults; `server.go:2469-2471` currently treats direct HTTP EOF as clean success and is correctly named as the behavior v0.2 must narrow.
- Code-lens result: Security C-1 and Code Q-1 converge cleanly. No remaining r1 Q-1 blocker.

## Fresh Findings

### H-3 residual — Stale hash-routing citation remains in a v0.2 section
- SPEC location: `specs/SPEC-018-agentic-tool-calling.md:610`
- Code location: cited `phase4-coordinator/internal/buyer/server.go:3743-3764`; live relevant paths are `server.go:3291-3324`, `server.go:3873-3913`
- Issue: The cited range no longer describes hash-verification routing eligibility. It points to model-class/header helper code.
- Risk: The v0.2 model-hash narrative is already load-bearing because v0.2.1 explicitly amends registry timing. A stale citation in that paragraph sends implementers to the wrong routing predicate when validating the deferral/observation path.
- Fix: Replace `server.go:3743-3764` with the current hash exclusion/eligibility ranges, or remove the live-code citation from the historical §10a paragraph and point readers to §10d.0.1 / AC-46 for v0.2.1.

### M-1 — AC-46 has conflicting known-vs-every-response semantics
- SPEC location: `specs/SPEC-018-agentic-tool-calling.md:695-697`, `:595`
- Issue: §10d.0.1 says every v0.2 provider response includes `usage.macprovider_model_hash_observed` **when the served model hash is known**. AC-46 says **every provider response** includes `usage.macprovider_model_hash_observed: "<hex>"`, then only makes non-hex a fail condition "when a model hash is known."
- Risk: The unknown-hash branch is not mechanically testable. Implementers cannot tell whether the field should be absent, `null`, an empty string, or a sentinel when the provider has no known hash. This matters because AC-46 is the explicit v0.2 mitigation replacing registry enforcement.
- Fix: Define one exact unknown-hash behavior and add AC-46 fixtures for both known and unknown hash cases. If the field is mandatory, specify a JSON type such as `null | "^[a-f0-9]{64}$"`; if not mandatory, make absence compliant only when hash evidence is unavailable.

### M-2 — Aggregate request caps and O(N) validation lack AC coverage
- SPEC location: `specs/SPEC-018-agentic-tool-calling.md:711-719`
- Issue: v0.2.1 adds concrete aggregate limits (4 MiB raw request, 1 MiB total tool content, 2 MiB total assistant-history arguments, 256 messages, 128 assistant-history tool calls) and an O(messages + tool_calls) validation requirement, but AC-28/AC-31/AC-32 only cover per-message/per-ID behavior and consistency rules.
- Risk: A compliant-looking implementation can pass the named ACs while missing aggregate decoded caps or using repeated O(N^2) scans. That reopens the request-side DoS class that item 19 was meant to close.
- Fix: Add AC coverage for each aggregate cap and a large adversarial transcript fixture that proves validation remains linear, for example by asserting bounded runtime/operation counters on 256 messages and 128 tool calls with duplicate/unknown/out-of-order failures.

## Verified Citations And Checks

- Verified r1-updated call sites: `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:353`, `:403`; mapping losses at `:374`, `:428`, `:513`; current rejects at `:924`, `:931`.
- Verified request parsing preservation claim: `phase4-coordinator/internal/buyer/server.go:1241-1245` defines `ToolCallID` and `ToolCalls`.
- Verified streaming pass-through citations: `forwardWSStreaming` starts at `server.go:2103`; buyer write is `:2149`; `forwardStreaming` starts at `:2278` with upstream URL at `:2279`.
- Verified §8.4.2 live behavior citations: WS post-commit disconnect/timeout fault paths at `server.go:2239-2255`; direct HTTP post-commit disconnect path at `:2476-2487`; direct HTTP clean EOF success/sticky write at `:2469-2471`.
- Verified current complete-JSON validator incompatibility claim: `isCommitWorthyToolCallDelta` at `server.go:2673-2705` requires complete metadata and `validToolCallArgumentsObject`, so it cannot accept OpenAI incremental argument fragments as final-close state.
- Verified money-path citations: `billing_recorder.go:176` constructs `billing.HotPathInput`; `formula.go:112` short-circuits provider-positive settlement when `FaultFlag == FaultBreakerQualifying`.
- Verified SPEC-006 citations used by v0.2.1 aggregate streaming budget: per-account concurrency default appears in `specs/SPEC-006-buyer-api.md:365-370` and `:1580-1587`; request body default appears at `:2384-2388`.

## Verdict

FIX REQUIRED

## Verdict Justification

The Security C-1 / §8.4.2 lock-blocker is closed from the code lens, and most r1 code findings are absorbed. The remaining bar is not met because H-3 still has a stale live-code citation in a v0.2 section, and v0.2.1 introduced two medium mechanical-verifiability gaps around AC-46 and aggregate/O(N) request validation. Current result is 0 CRITICAL, 1 HIGH, 2 MEDIUM, so v0.2.1 is **not READY TO LOCK** from code lane yet.
