codex
Result: FAIL — 2 HIGH, 1 MEDIUM.

1. **HIGH — FR-CB10 acceptance coverage is not an exact runtime-tuple match**

`phase3-binary/Sources/macprovider-cli/ContinuousBatching.swift:75-87,141-149` and `phase3-binary/Sources/MacProviderCore/Config.swift:33-47`

The requested tuple includes tokenizer/template hashes, metallib hash, kernel identifier, parity label, and pool epoch, but operator acceptance coverage matches only model ID/SHA, cache class, KV dtype, MoE flag, and hardware class.

Failure scenario: a signed candidate changes the metallib or kernel while the existing acceptance entry remains unchanged. The descriptor matches the new runtime identity and batching activates despite no real-serving evidence for that runtime revision.

Fix: bind acceptance evidence to every runtime-tuple field, preferably through a signed/full-tuple acceptance record.

2. **HIGH — SPEC-039 FR-PKV13 overhead ceiling is not enforced**

`phase3-binary/Sources/MacProviderCore/PagedKVEngine.swift:119-147,396-421`; `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:1540-1595`

The sizing proof records capacity and identity, but no gather/shared-forward overhead measurement or ceiling. Attach proceeds after parity, isolation, and capacity checks alone.

Failure scenario: paged attention is parity-correct but exceeds the recorded performance ceiling; the candidate still attaches the scheduler and can serve real canary traffic, contrary to SPEC-039 FR-PKV13.

Fix: record the measured overhead ceiling in the runtime proof/descriptor and fail paged/continuous-batch attach closed when it is exceeded.

3. **MEDIUM — `on` has no implemented Gate A5 promotion path**

`phase3-binary/Sources/macprovider-cli/ContinuousBatching.swift:200-227,302-304,345-357`; `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift:706-721`

The pre-model check always reports `.on` as lacking local capability because no runtime descriptor exists yet, so a valid post-A5 configuration cannot start. After runtime construction, `.on` and `.canary` use the same capability predicate and no A5 evidence is checked.

Failure scenario: switching the exact canary tuple to `on` either prevents startup outright or, if a future path bypasses this preflight, enables production-default batching without A5 evidence.

Fix: add an explicit persisted/signed A5 promotion gate and perform mode-aware runtime validation after the descriptor is available.

Hybrid first-turn isolation, lab-loopback waiver scoping, knob precedence, and `AUTHORITY.json` ownership are otherwise consistent. `CONFORMANCE.json` remains explicitly pending/unknown rather than falsely claiming completion.

Validation:

- `ServingKnobsConfigTests`: 96 passed, 1 skipped.
- `PagedKVEngineTests`: 36 passed.
- `ContinuousBatchSchedulerTests`: 78 passed, 4 skipped.
- `PagedKVRuntimeBridgeTests`: 31 passed, 15 skipped.
- `PagedKVRuntimeMixedCacheTests`: 2 skipped because MLX metallib is unavailable locally.
- `ProviderStatusTests`: 59 passed.
- Diff whitespace check passed.
- No malformed payloads were constructed.

For the intended rollout, use `canary`, `max_concurrency_override: 8`, paged KV enabled with exact `mixed`/fp16/model-SHA/hardware acceptance, `mlx_cache_limit_mb: 2048`, and a positive queue timeout. Roll back by restarting with `continuous_batching: off` and `paged_kv.enabled: false`.

VERDICT: FAIL (0 CRITICAL / 2 HIGH / 1 MEDIUM)
