# Architecture review lane: SPEC-039 Phase-2 Increment 1 attach (#1474)

Review the current working tree diff against `origin/main` in this MacProvider
worktree. Do not edit files. Do not inspect `d-inference` / `Layr-Labs/*`.

Architecture scope:
- The implementation should consume the merged SPEC-039 engine and SPEC-038
  scheduler without redefining storage layout, allocator internals, descriptor
  schema, or scheduler lifecycle.
- Attach must be a preflight observed-identity match against a trusted
  descriptor; no advertised-field copying into observation.
- Runtime bridge should be default-off / production-inert until a future
  measured observation is wired.
- Shared-forward backend should be a narrow `[B,1]` decode bridge, leaving
  admission, block-table lifecycle, cancellation, and per-request isolation in
  the existing scheduler.
- Sticky/cross-turn reattach (#887 / FR-PKV10) must remain out of scope.

Commands you may use:
- `git status -sb`
- `git diff --stat origin/main`
- `git diff origin/main -- phase3-binary/Sources/MacProviderCore/PagedKVEngine.swift phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift phase3-binary/Sources/macprovider-cli/ModelRuntime.swift phase3-binary/Sources/macprovider-cli/PagedKVCache.swift phase3-binary/Sources/macprovider-cli/PagedKVRuntimeBridge.swift phase3-binary/Tests/MacProviderCoreTests/PagedKVEngineTests.swift phase3-binary/Tests/macprovider-cliTests/ContinuousBatchSchedulerTests.swift phase3-binary/Tests/macprovider-cliTests/KVConversationColdTierTests.swift phase3-binary/Tests/macprovider-cliTests/PagedKVRuntimeBridgeTests.swift phase3-binary/Tests/macprovider-cliTests/ServingKnobsConfigTests.swift`

Return:
- Verdict: PASS or FAIL.
- Findings grouped by CRITICAL/HIGH/MEDIUM/LOW/INFO.
- Each finding must include concrete file/line evidence and a minimal fix.
- Bar for this PR is 0 CRITICAL, 0 HIGH, 0 MEDIUM.
