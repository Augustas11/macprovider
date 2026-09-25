codex
Architecture audit complete for `git diff 3ef0825f..HEAD -- ':!docs' ':!audits'`.

No Critical, High, or Medium findings.

The implementation conforms to the reviewed contracts:

- SPEC-024 FR-CI2: exact LCP, ≥32 threshold, checkpoint selection, attention trimming, recurrent-state restore, and fail-safe misses are implemented in `ConversationCache.swift:268-331` and `499-523`.
- Non-ChatML/hybrid safety: absent markers or unsupported role tokenization produce no checkpoints; exact token LCP and model identity checks still gate reuse.
- SPEC-038 FR-CB4: scheduler-owned checkpoint splitting and row-local snapshots occur in `ContinuousBatchScheduler.swift:2437-2558`; materialization happens before release at `2972-2990`, using the FR-PKV10 bridge in `PagedKVRuntimeBridge.swift:682-718`.
- AC-26 remains fenced: positive cached hits serial-route in `ModelRuntime.swift:3950-3960`.
- SPEC-037 hybrid disk exclusion is enforced by the `KVCacheSimple` serialization allowlist in `KVConversationColdTierAdapter.swift:321-339`.
- Continuous batching remains default-off and tuple-gated (`MacProviderCLI.swift:393`, `ContinuousBatching.swift:320-337`). CONFORMANCE and the spec index remain correctly unreconciled/not-deployed.

Validation:

- `ConversationCacheTests`: 32 passed, 1 skipped.
- `ContinuousBatchSchedulerTests`: 84 passed, 4 skipped.
- `ContinuousBatchStopTokenTests`: 1 passed.
- `PagedKVRuntimeMixedCacheTests`: 3 skipped because the host lacks the MLX default metallib.
- Spec index check and lint passed.
- `git diff --check` passed.

The skipped MLX tests are a local coverage limitation, not a source finding; the supplied Studio relay evidence covers the runtime path.

VERDICT: PASS
