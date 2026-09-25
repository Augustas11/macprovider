codex
Result: no CRITICAL, HIGH, or MEDIUM findings.

- Isolation is enforced by account-scoped HMAC conversation keys (`chat_proxy.go:3102-3110`) and allocator conversation-key checks. Retained sequences cannot cross rows or accounts.
- Cached tokens remain exact: cache selection chooses checkpoint `C`; scheduler resumes at `C`; result usage preserves that value (`ConversationCache.swift:299-381`, `ContinuousBatchScheduler.swift:2374-2408`, `2721-2758`).
- Usage, receipt gating, settlement ownership, and replay handling preserve the existing owner/non-owner rules (`ContinuousBatchScheduler.swift:2878-2913`, `HTTPServer.swift:1520-1526`, `1766-1771`).
- Retained sequences are bounded by cache limits and released on eviction, cancellation, failed admission, replay, and capacity exhaustion (`ConversationCache.swift:488-504`, `591-611`).
- Missing, mismatched, or incomplete hybrid checkpoints fail closed (`PagedKVRuntimeBridge.swift:627-664`).

Existing tests passed:

- `ConversationCacheTests`: 34 passed, 1 skipped.
- `ContinuousBatchSchedulerTests`: 90 passed, 4 skipped.
- `ServingKnobsConfigTests`: 102 passed, 1 skipped.
- Gateway account-scope test passed.
- Coordinator buyer billing and SPEC-022 settlement tests passed.

The four mixed-cache runtime tests were skipped because this host lacks the MLX metallib; no malformed payloads were constructed. Packaged AC-26 receipt/settlement proof remains required before live enablement.

VERDICT: PASS
