codex
Audit result: no CRITICAL, HIGH, or MEDIUM findings.

- Isolation: `ConversationCache.begin` restores only the largest checkpoint within the exact LCP (`ConversationCache.swift:268-346`). Shared auto-prefix entries therefore share only identical prompt-prefix state. Batched recurrent state is keyed by request ID (`PagedKVRuntimeBridge.swift:662-678`), preventing row cross-contamination.
- Billing: `cachedPromptTokens` is the selected checkpoint length and is clamped to the incoming prompt (`ConversationCache.swift:323-346`). Batched-origin entries are cut to the materialized token count before commit (`ModelRuntime.swift:4160-4174`), while both paths use the same completion/receipt usage construction.
- Timing: faster hits can reveal reuse within the account-scoped cache-key boundary, but no cross-account timing path was introduced.
- Memory: residency is bounded by the configured conversation-count/token caps and lazy TTL/LRU eviction (`ConversationCache.swift:117-120, 553-578`). The default eight-entry limit bounds the target Studio deployment; TTL’s lazy physical retention is documented existing behavior.
- Fail-closed: missing snapshots produce no reusable entry (`ContinuousBatchScheduler.swift:2543-2547`); materialization failures return no serial cache (`ContinuousBatchScheduler.swift:2977-2993`); failed/cancelled rows do not commit. Hybrid entries are also rejected by the disk tier (`KVConversationColdTierAdapter.swift:321-339`).

Validation:

- Existing focused tests: 119 passed, 8 skipped, 0 failures.
- Skips were MLX-metallib-dependent runtime tests unavailable on this host.
- `git diff --check` passed.
- No source changes made.

VERDICT: PASS
