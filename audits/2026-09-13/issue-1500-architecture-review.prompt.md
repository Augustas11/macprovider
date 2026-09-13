# Architecture Review Audit: Issue #1500 SPEC-038 Increment 4

Review the full landing diff for branch `codex/1500-spec038-inc4-production-observation` against `origin/main`.

Scope files:
- `phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift`
- `phase3-binary/Sources/macprovider-cli/HTTPServer.swift`
- `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift`
- `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift`
- `phase3-binary/Sources/macprovider-cli/PagedKVCache.swift`
- `phase3-binary/Sources/macprovider-cli/RecommendationEmitter.swift`
- `phase3-binary/Tests/macprovider-cliTests/PagedKVRuntimeBridgeTests.swift`

Architectural intent:
- Consume SPEC-038/039 increments already on main without redefining storage layout, block semantics, FR-PKV10, or AC-19.
- Add a production measurement seam that is testable but fail-closed.
- Keep scheduler attach as a capability consequence of measured identity + sizing proof + backend installation.
- Carry ingress request identity into scheduler replay keys without changing external API/schema.
- Keep replay authority lifetime outside scheduler terminal result cache.
- Leave activation policy default-off and keyless-first.

Adversarial questions:
- Is the measurement seam too broad or too synthetic for production trust?
- Is backend-installed modeled consistently, or does the attach decision need a clearer two-phase abstraction?
- Are warm-swap, model adoption, and scheduler rebuild paths coherent with measurement lifecycle?
- Is process-local replay authority acceptable for the stated settlement replay horizon, or is the lifetime boundary misplaced?
- Does this change leak SPEC-024 cold-tier, keyed rollout, or canary enablement concerns into Increment 4?
- Are tests placed at the right layer to prevent #889/#894-style descriptor-copy regressions?

Return findings by severity: CRITICAL, HIGH, MEDIUM, LOW, INFO. Include file and line references. The merge bar is 0 CRITICAL / 0 HIGH / 0 MEDIUM.
