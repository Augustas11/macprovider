# Round-2 disposition

Fixed in 7398c746b:
- **Claude N1 MEDIUM (depth-key precedence):** the depth key applies only when the legacy key is absent or 8. Test: `testLegacyMaxConcurrencyOverrideChangedAfterDepthWins`.
- **Codex code MEDIUM (streamed relay receipts sign `ttft_ms: 0`):** pre-existing on main, but it defeated the TTFT fix. `processStreaming` now signs `completion.ttftMilliseconds ?? 0`, and the same for cancel.
- **Claude N2 LOW:** the one-shot flag resets when a new wait starts. Test: `TestNewOccupancyWaitRestartsTheOneShotLowerReportIgnore`.
- **Codex architecture LOW:** the SPEC-023-R011 rationale now states the served hard cap of 32.

Accepted, not defects:
- **HIGH (all three Codex lanes): the signed CB policy doesn't bind scheduler revision, ragged prefill or the 2048 budget.** Operator decision on 2026-10-09 and AGENTS.md rule 11 ("Proven changes ship on"): ragged prefill ships enabled with the 2× offset-spread cap as the in-code bound. Evidence: `docs/research/issue-1906/prefill-2026-10-09/`.
- **MEDIUM (Codex code and security): calibrated depth above 8 is clamped by the coordinator's default `pool.max_concurrency_ceiling` of 8.** This is by design and documented in SPEC-023 §9.2 and the R009 rationale. Raising served slots means raising the coordinator ceiling for that provider cohort through `scripts/ops/` (#1906 step 7). Over-admission is impossible.
- **MEDIUM (Codex architecture): replay-owner TTFT.** Terminal replays are non-settling (`ContinuousBatchScheduler.swift:2402`, `InferenceRelay.swift:1243`). The only remaining case is an active-decode duplicate that becomes the owner; it measures TTFT from its own request start. Downgraded to LOW.
- **LOW: retry telemetry counts internal queue waits.**

Test evidence:
- Go: coordinator buyer and pool, gateway router, all passing.
- Swift: built with Xcode XCTest on the Studio. 703 tests across the affected suites; one failure in the pre-existing `testLongPrefillIsActuallyChunkedAndDecodeRunsBetweenChunks` under mixed-suite load. The scheduler suite then passed 15/15.
