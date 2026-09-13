# Security Review Audit: Issue #1500 SPEC-038 Increment 4

Review the full landing diff for branch `codex/1500-spec038-inc4-production-observation` against `origin/main`.

Scope files:
- `phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift`
- `phase3-binary/Sources/macprovider-cli/HTTPServer.swift`
- `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift`
- `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift`
- `phase3-binary/Sources/macprovider-cli/PagedKVCache.swift`
- `phase3-binary/Sources/macprovider-cli/RecommendationEmitter.swift`
- `phase3-binary/Tests/macprovider-cliTests/PagedKVRuntimeBridgeTests.swift`

Security and billing-sensitive intent:
- Runtime identity must be measured locally, not self-asserted or copied from descriptor/admission inputs.
- Missing/incomplete metallib, kernel, parity, hardware, model hash, or sizing proof must fail closed.
- Durable replay authority must prevent double settlement-eligible execution for duplicate request identity.
- No schema/API changes, no buyer-routing enablement, no canary/on rollout, no keyed rollout.

Adversarial questions:
- Can an attacker or malformed local config synthesize an observed identity that opens attach?
- Can a stale measurement survive model swap and authorize a different model/hash/tokenizer/template?
- Can duplicate request id + different fingerprint execute as a fresh claim?
- Can replay claims be bypassed because relay/HTTP request identity is not carried into scheduler admission?
- Can duplicate same request bypass the authority because the authority lifetime is too short?
- Does missing packaged metallib or empty file still close attach?
- Is any secret/key material introduced, logged, persisted, or committed?
- Are concurrency choices around replay claims data-race safe?

Return findings by severity: CRITICAL, HIGH, MEDIUM, LOW, INFO. Include file and line references. The merge bar is 0 CRITICAL / 0 HIGH / 0 MEDIUM.
