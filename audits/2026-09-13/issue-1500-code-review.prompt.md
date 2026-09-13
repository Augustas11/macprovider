# Code Review Audit: Issue #1500 SPEC-038 Increment 4

Review the full landing diff for branch `codex/1500-spec038-inc4-production-observation` against `origin/main`.

Scope files:
- `phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift`
- `phase3-binary/Sources/macprovider-cli/HTTPServer.swift`
- `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift`
- `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift`
- `phase3-binary/Sources/macprovider-cli/PagedKVCache.swift`
- `phase3-binary/Sources/macprovider-cli/RecommendationEmitter.swift`
- `phase3-binary/Tests/macprovider-cliTests/PagedKVRuntimeBridgeTests.swift`

Task intent:
- Build production `.runtimeMeasurement` identity from live measurement only.
- Build hardware sizing proof from that measured tuple plus live `PagedKVConfig`.
- Install continuous-batch scheduler backend only when attach succeeds.
- Replace always-claim replay authority with durable request-id + fingerprint claims.
- Keep continuous batching default-off and keep keyed rollout blocked.

Adversarial questions:
- Did production copy advertised descriptor fields into observed identity?
- Can attach succeed with `source` other than `.runtimeMeasurement`?
- Can attach succeed without a real packaged `default.metallib` SHA?
- Is `hardwareSizingProof` merely a twin of an advertised descriptor instead of measurement/config?
- Does production still always-claim replay or recreate authority per scheduler cache?
- Does scheduler replay use stable relay/HTTP request identity rather than a retry-local UUID?
- Did this enable `continuous_batching: canary`/`on` or lift keyed rollout?
- Can a worktree without metallib start serving batched?
- Are warm-swap and rebuild paths using stale measurement/proof/backend-installed state?

Return findings by severity: CRITICAL, HIGH, MEDIUM, LOW, INFO. Include file and line references. The merge bar is 0 CRITICAL / 0 HIGH / 0 MEDIUM.
