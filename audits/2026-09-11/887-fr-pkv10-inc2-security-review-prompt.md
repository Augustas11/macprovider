# Issue 887 FR-PKV10 Increment 2 Security Review

Review the current working-tree diff in `/Users/augstar/.codex/worktrees/macprovider/887-spec039-phase2-inc2-pkv10` against `origin/main`.

Scope:
- `phase3-binary/Sources/MacProviderCore/PagedKVEngine.swift`
- `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift`
- `phase3-binary/Sources/macprovider-cli/PagedKVRuntimeBridge.swift`
- `phase3-binary/Tests/MacProviderCoreTests/PagedKVEngineTests.swift`
- `phase3-binary/Tests/macprovider-cliTests/PagedKVRuntimeBridgeTests.swift`

Intent:
- Implement SPEC-039 Phase 2 Increment 2 / FR-PKV10 runtime contiguous KVCache extraction for attached-only PagedKV scheduler paths.
- Keep canary off and sticky serving disabled/rejected.

Security focus:
- Cross-conversation cache isolation and retained-sequence reattach restrictions.
- Bounds, shape, dtype, overflow, stale handle, cancellation, and mismatch failure behavior.
- Whether recorded live KV bytes can leak, be replayed across handles, or survive row completion unexpectedly.
- Whether any rollout gate, canary, sticky serving, trust tier, or buyer-visible behavior is widened.

Report only actionable findings. Classify each as CRITICAL, HIGH, MEDIUM, LOW, or INFO with file/line evidence. The gate is 0 CRITICAL, 0 HIGH, and 0 MEDIUM findings.
