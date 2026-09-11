# Security review lane: SPEC-039 Phase-2 Increment 1 attach (#1474)

Review the current working tree diff against `origin/main` in this MacProvider
worktree. Do not edit files. Do not inspect `d-inference` / `Layr-Labs/*`.

Security-critical scope:
- Runtime attach must require a trusted descriptor and a separately measured
  observed runtime identity. Self-asserted or advertised-as-observed provenance
  must fail closed.
- Empty/partial identity fields must not be admitted.
- Production serve path must not manufacture a real observation; nil
  observation must keep `engineBridgeAvailable` and `schedulerBackendAvailable`
  false.
- MoE dispatch proof must remain separate from advertised support.
- Cross-request batched forward must not leak sampler, stop, state, cache, or
  block-table data between requests.
- #887 / FR-PKV10 sticky or contiguous reattach must remain unimplemented.

Commands you may use:
- `git status -sb`
- `git diff --stat origin/main`
- `git diff origin/main -- phase3-binary/Sources/MacProviderCore/PagedKVEngine.swift phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift phase3-binary/Sources/macprovider-cli/ModelRuntime.swift phase3-binary/Sources/macprovider-cli/PagedKVCache.swift phase3-binary/Sources/macprovider-cli/PagedKVRuntimeBridge.swift phase3-binary/Tests/MacProviderCoreTests/PagedKVEngineTests.swift phase3-binary/Tests/macprovider-cliTests/ContinuousBatchSchedulerTests.swift phase3-binary/Tests/macprovider-cliTests/KVConversationColdTierTests.swift phase3-binary/Tests/macprovider-cliTests/PagedKVRuntimeBridgeTests.swift phase3-binary/Tests/macprovider-cliTests/ServingKnobsConfigTests.swift`

Return:
- Verdict: PASS or FAIL.
- Findings grouped by CRITICAL/HIGH/MEDIUM/LOW/INFO.
- Each finding must include concrete file/line evidence and a minimal fix.
- Bar for this PR is 0 CRITICAL, 0 HIGH, 0 MEDIUM.
