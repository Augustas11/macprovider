I've completed a thorough trace of the SPEC-024 implementation against the spec, build prompt, and all six named prior findings. Evidence summary:

**Prior findings — all verified fixed:**

1. **Admin reconciliation cache pricing** — `endpoints.go:497` selects `rl.cached_prompt_tokens`; `buyerEquivalentCredits` threads `cachedP` into `ComputeCreditsWithCache(pp, cachedP, cp, ...)` at `endpoints.go:560`, so the admin `/admin/ledger/reconcile` buyer-equivalent total applies the cached/uncached split.

2. **Complete gateway usage synthesis for absent usage w/o coordinator partial usage** — coordinator only injects into an *existing* usage object (`chatResponseWithCachedPromptTokens`, verified non-synthesizing by `TestChatResponseWithCachedPromptTokensPreservesAbsentUsage`); gateway `forwardNonStreamingChat` synthesizes `{PromptTokens: promptEstimate, CachedPromptTokens: 0,…}` when `!ok` (`chat_proxy.go:398`), and `usageBodyWithTokenUsage:1518-1541` builds a full flat usage object with `cached_prompt_tokens`.

3. **Explicit-null invalid quarantine** — `cachedPromptTokensPointer` maps `null`/non-integer to `-1` sentinel (`server.go:5557-5566`); `normalizeCachedPromptTokens:211-214` and `requestLogCacheRecoveryFields:5626` both quarantine `cached < 0` as `invalid_cached_prompt_tokens` (test at `cache_recovery_internal_test.go:30`).

4. **Recovery compares ledger cached provenance vs request_log/hot-path** — `request_log.cached_prompt_tokens`+`cache_quarantine_reason` written from `requestLogCacheRecoveryFields`, which is byte-equivalent to the ledger's `normalizeCachedPromptTokens`; `reconcileExistingCreditTx:451` includes `!nullInt64MatchesPtr(cached, input.CachedPromptTokens)` in the mismatch predicate, and the cache-quarantine reason short-circuits at `recovery.go:187`.

5. **Coordinator does not emit partial usage after adding cached** — `chatResponseHasIncompleteUsage` returns false for absent usage (`server.go:5657`), routing absent-usage bodies to the non-synthesizing `chatResponseWithCachedPromptTokens`; only genuinely-present-but-incomplete usage is rewritten.

6. **Gateway streaming drops malformed usage frames** — on invalid stream usage, `chat_proxy.go:642-645` sets `invalidReportedUsage = true; reported = nil; line = nil`, and `len(line)==0 → return true` (`:663`) suppresses the frame; subsequent valid usage frames are ignored via the `!invalidReportedUsage` guard, and settlement falls back to gateway estimate.

**Additional design checks (all pass):** formula overflow-guarded cached/uncached split with `usage_source='null_error'` guard preserved (`formula.go:206-257`); rate-card `EffectivePromptCacheHitCreditsPerMtok` correctly defaults omitted config to the prompt rate while honoring explicit `0` via `promptCacheHitRateSet` (`config.go:402-491`), with `Validate` rejecting `cacheRate > promptRate` (`config.go:1137`); snapshot JSON round-trips the effective rate; gateway independently re-clamps `cached>prompt→0` (`sanitizedCachedPromptTokens:1507`) as defense-in-depth; request_log/ledger cached normalization stays consistent across the attempt-`n` realignment because divergence only arises on rows that quarantine as `ambiguous_attempt_n`, where recovery short-circuits on `quarantined=1`.

The only latent imperfection is cosmetic and non-buyer-visible: the coordinator's incomplete-usage rewrite hardcodes `prompt_tokens=0` while injecting a positive `effective_cached`, which could momentarily present `cached > prompt` — but this is fully re-sanitized to `0` by the gateway (`sanitizedCachedPromptTokens`) on the standard buyer path and never affects ledger/credit arithmetic. Below the C/H/M bar.

0 C/H/M findings
