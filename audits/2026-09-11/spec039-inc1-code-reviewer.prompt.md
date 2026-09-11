# Code review lane: SPEC-039 Phase-2 Increment 1 attach (#1474)

Review the current working tree diff against `origin/main` in this MacProvider
worktree. Do not edit files. Do not inspect `d-inference` / `Layr-Labs/*`.

Scope:
- Implements issue #1474 from
  `audits/_prompts/BUILD_SPEC_039_PHASE2_INCREMENT1_ATTACH_IMPL_PROMPT.md`.
- Must not implement #887 / FR-PKV10 sticky or contiguous cache reattach.
- Changed files are expected under `phase3-binary/Sources/MacProviderCore`,
  `phase3-binary/Sources/macprovider-cli`, and matching Swift tests.

Commands you may use:
- `git status -sb`
- `git diff --stat origin/main`
- `git diff origin/main -- phase3-binary/Sources/MacProviderCore/PagedKVEngine.swift phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift phase3-binary/Sources/macprovider-cli/ModelRuntime.swift phase3-binary/Sources/macprovider-cli/PagedKVCache.swift phase3-binary/Sources/macprovider-cli/PagedKVRuntimeBridge.swift phase3-binary/Tests/MacProviderCoreTests/PagedKVEngineTests.swift phase3-binary/Tests/macprovider-cliTests/ContinuousBatchSchedulerTests.swift phase3-binary/Tests/macprovider-cliTests/KVConversationColdTierTests.swift phase3-binary/Tests/macprovider-cliTests/PagedKVRuntimeBridgeTests.swift phase3-binary/Tests/macprovider-cliTests/ServingKnobsConfigTests.swift`
- Prefer targeted `rg` and `sed -n` reads over pasting whole files when
  checking concrete locations.

Adversarial questions:
- Can attach activate without a real measured observed identity match?
- Can advertised descriptor fields masquerade as observed fields?
- Does shared-forward decode preserve per-row token, stop, usage, and sampler
  isolation?
- Does production serve remain inert/fail-closed when observation is nil?
- Did the patch accidentally implement sticky/cross-turn cache reattach (#887)?

Return:
- Verdict: PASS or FAIL.
- Findings grouped by CRITICAL/HIGH/MEDIUM/LOW/INFO.
- Each finding must include concrete file/line evidence and a minimal fix.
- Bar for this PR is 0 CRITICAL, 0 HIGH, 0 MEDIUM.
