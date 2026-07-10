# Issue #266 Tranche 3 — audit results

Three-lane codex audit on PR for issue #266 Tranche 3 (BalancedScores caching + AC-SR-1 + sticky integ test + 2 audit-deferred follow-ups).

## R1 — 2026-06-30

Commit audited: `17bdb47` (initial T3 implementation).

| Lane | C | H | M | L | Status |
|------|---|---|---|---|--------|
| CODE | 0 | 0 | 0 | 3 | ✅ ACCEPT |
| SECURITY | 0 | 0 | 0 | 1 | ✅ ACCEPT |
| ARCHITECT | 0 | 0 | 0 | 4 | ✅ ACCEPT |

**All three lanes at C/H/M = 0 first round. Merge bar met.**

### R1 findings — fixed

**CODE-L1** — Sticky-path log emissions (`sticky_miss_*` / `sticky_outside_epsilon` / `sticky_hit` / `sticky_miss_provider_not_candidate`) still delegated through `s.logRoutingDecision` which recomputed `KeyedBalancedScores`. Fix: new `logRoutingDecisionWithCache` wrapper; all 4 sticky log emitters in `applySticky` now thread the `balancedCache` parameter. Closes the perf-cache integration gap for balanced+sticky enabled routing.

**CODE-L2** — AC-SR-1 tests (empty pool, all-capacity-zero, context-too-small) asserted only HTTP status, not the OpenAI error `code` + `type`. Fix: all three tests now call `assertOpenAIErrorEnvelope` with the expected code/type pair (model_not_found/invalid_request_error, no_provider_available/service_unavailable, context_exceeds_capacity/invalid_request_error).

**CODE-L3 / ARCH-L4** — Empty-pool test docstring contradicted the assertion (claimed 503 no_provider_available, asserted 404 model_not_found). Fix: rewrote docstring to describe the upstream `pool.ModelKnown` gate firing before the smart-router pipeline, with the canonical "model exists but no candidate passes filtering" 503 case handled by the AllReadyButCapacityZero test below.

**ARCH-L2** — Cache-lifecycle invariant under-documented. Fix: added a paragraph in `selectProviderExcluding` stating that after `EligibleCandidates` returns, no code path adds/removes candidates from the slice — only the order changes — and the cache keys by `pool.Provider.SortKey()` which is stable across reordering.

### R1 findings — accepted with rationale (no code change)

**ARCH-L1** (cache trust by callers): the cache is constructed immediately from the same eligible set in `selectProviderExcluding`; no external caller exists today. Accepted; if a second caller appears, prefer a typed/private cache or key-coverage validation.

**ARCH-L3** (benchmark cleanliness): the NoCache vs WithCache benchmark mutates the candidate slice across iterations. Accepted with rationale — the absolute numbers (3841ns vs 2108ns) are directional evidence; a future bench can clone candidates per iteration for tighter numbers if needed.

**SEC-L1** (ProviderID validation inconsistency in WS self-serve registration): pre-existing condition the auditor noticed — configured pinned providers reject `/` via `config.providerIDPattern` but `ParseHello` / `IssueToken` accept any non-empty string. `pool.Provider.SortKey()` could theoretically collide if a hostile provider registers a ProviderID containing `/`, though current coordinator-issued AssignedID values are UUIDs and prevent practical collision. **Filed as a separate follow-up issue** for cross-path ProviderID validator consolidation; explicitly NOT a T3 regression per the auditor.

## Convergence

R1 absorbed 4 LOWs and accepted 4 LOWs with rationale. All three lanes locked at C/H/M = 0 on the first round. Per [[feedback-skip-accepted-audit-lanes]] no R2 is needed: the fix-pass touches sticky log call sites + 3 test envelope assertions + 2 docstrings, no new semantics.

Ready for PR + merge. After this lands, issue #266 closes (10/10 deferred items completed).
