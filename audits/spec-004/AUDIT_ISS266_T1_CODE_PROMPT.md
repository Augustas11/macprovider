# Issue #266 Tranche 1 — CODE audit prompt

You are an independent code auditor. Read this prompt + the diff + the files referenced and report findings.

## Context

Issue #266 is the consolidated tracking issue from PR #263 (SPEC-004 Pillars B/C/D/A bundled IMPL). This PR ("Tranche 1") lands the four safety / correctness items that block Phase 2 operator green-light to flip routing flags ON:

1. **SIGHUP InvalidateClass wiring** (FR-SR-5 paragraph 2 "invalidate on class reconfig"). Primitive `sticky.Map.InvalidateClass` shipped in PR #263 but had no caller; this PR wires the SIGHUP-driven config-reload path to call it for every `routing.model_classes` class whose membership shape changed.
2. **Per-attempt FR-SR-17 log threading**. Pre-PR the retry call sites emitted routing-decision logs with `AttemptIndex / RetryCount / RetryReason / Retried / PreflightResult = 0/empty`; this PR populates them.
3. **Mid-request stable seed across UTC midnight**. Pre-PR, `seedForRequest(requestID)` re-derived the UTC daily-key at each `applyRandomTiebreak` call, so a retry crossing 00:00 UTC got a different seed than the first attempt. This PR snapshots the daily-key into `forwardState.dailyKey` ONCE at request entry and threads it through.
4. **`sticky_account_mismatch` warn-log rate-limit**. Pre-PR every cross-account refresh refusal logged a Warn — a hostile gateway could drive arbitrary log volume. This PR adds a per-conversation_key bounded limiter (1 warn / minute / key, MaxEntries-bounded).

## Changed files (read these in full)

- `phase4-coordinator/internal/buyer/server.go` — main changes (struct fields, SetRoutingClasses, diffModelClasses, logRoutingDecisionRetry, dailyKey threading, mismatch-limiter wiring)
- `phase4-coordinator/internal/buyer/forward_state.go` — new dailyKey field
- `phase4-coordinator/internal/buyer/forward_with_failover.go` — failoverCandidate call updated to pass state.dailyKey
- `phase4-coordinator/internal/buyer/sticky_mismatch_limiter.go` — new file
- `phase4-coordinator/internal/buyer/iss266_t1_test.go` — new tests
- `phase4-coordinator/cmd/coordinator/main.go` — reloadTier2Config wires SetRoutingClasses

## What to audit (CODE lens)

Report severities CRITICAL / HIGH / MEDIUM / LOW. **MEDIUM and above gate merge.** LOWs noted but do not gate.

Focus on:

1. **Correctness of diffModelClasses.** Does the algorithm correctly detect: classes added; classes removed; classes whose Objective changed; classes whose Models or Members slice differs (including order-sensitivity — Models[a,b] vs [b,a] should be considered DIFFERENT here because the existing cloneModelClasses preserves order). Edge cases: nil prev, nil next, both nil, identical empty maps.
2. **Race-safety of routingMu.** SetRoutingClasses takes the write lock briefly to swap modelClasses, then drops it before calling stickyMap.InvalidateClass. Is there a missed-update window where a hot-path reader could see the new map but the sticky entries not yet purged? Is that window safe (the answer should be yes — purge-after-swap is the correct order so readers can never see stale model→provider mapping under the new config, but verify).
3. **logRoutingDecisionRetry field semantics.** AttemptIndex = state.explicitRetries+1; RetryCount = state.explicitRetries; Retried = state.explicitRetries. Are these correct per SPEC-004 §7's "AttemptIndex is 1-indexed attempt number" and "Retried is count of additional provider attempts beyond the first"? The pre-PR `state.explicitRetries` is incremented inside `advanceToNextProvider` BEFORE `afterAdvance` fires (see server.go:2036). So after the first advance, explicitRetries=1, meaning "this is the second attempt overall, the FIRST retry". AttemptIndex=2 (correct 1-indexed). RetryCount=1 (correct count of explicit retries). Retried=1 (correct count of additional attempts beyond first). Verify.
4. **dailyKey threading completeness.** `state.dailyKey` is set in `handleChatCompletions`. The three call sites pass it: `selectProvider`, `advanceToNextProvider→selectProviderExcluding`, `forwardWithFailover→failoverCandidate→selectProviderExcluding`. Are there any other entry points that hit applyRandomTiebreak via a path that does NOT have state? (Look for additional callers I might have missed.)
5. **Empty-dailyKey fallback in applyRandomTiebreak.** When dailyKey == "" the code falls back to `defaultDailyKey()`. This preserves pre-PR behavior for any not-yet-threaded caller. Is the fallback safe (no nil deref, no silent inconsistency)?
6. **stickyMismatchLimiter eviction algorithm.** Under sustained cap-bound pressure, evictOldestLocked first sweeps expired entries, then evicts oldest if still at cap. The first-loop is O(n) every time at cap. Acceptable for default MaxEntries=10000 (per-call cost ~tens of microseconds). Verify there's no pathological case (e.g., a hostile caller that drives 100% in-window pressure causing O(n) eviction on every single allow call).
7. **`stickyMismatchLimiter.allow` correctness for the "key seen before, in-window" branch.** The code updates `l.entries[key] = now` only on the past-window branch, not on the in-window-deny branch. This means a key that fires 60 times in a 30-second window doesn't have its lastWarnAt refreshed each time — it correctly stays anchored to the first emission, and the next allow fires exactly 60s after the FIRST emission. Confirm this matches "1 warn per window per key" semantics.
8. **Per-attempt FR-SR-17 — does logRoutingDecisionRetry duplicate fields the existing logRoutingDecisionFull emits?** Look at the routing.Decision struct field set produced by logRoutingDecisionRetry vs logRoutingDecisionFull. Are there shape inconsistencies that could break log-consumer parsers expecting a stable schema? In particular: the retry path emits CandidateCountBeforeFilters=CandidateCountAfterFilters=1, whereas the main-selection path emits the real pre-filter count + per-reason filtered_counts. Is this divergence audit-safe?
9. **forwardState.dailyKey staleness window.** If a coordinator runs across an extremely long-lived single request (e.g. 25 hours with retries spanning two midnight crossings), the snapshotted dailyKey is from start-of-request. Same-day reproducibility is preserved. Is that the correct semantic per SPEC-004 §7?
10. **Comment/code-doc accuracy.** Are the docstrings on SetRoutingClasses, snapshotModelClasses, retryDecisionAttrs, logRoutingDecisionRetry, stickyMismatchLimiter, forwardState.dailyKey accurate vs the actual behavior?

## Output format

For each finding:
- **Severity**: CRITICAL / HIGH / MEDIUM / LOW
- **Location**: file:line
- **Issue**: 1-2 sentences
- **Evidence**: quoted code or contradiction with SPEC-004 §7 / issue #266 body
- **Fix sketch**: what would resolve it

Final line MUST be:
```
SUMMARY: CRITICAL=<n> HIGH=<n> MEDIUM=<n> LOW=<n>
```

Issue any clarifying questions BEFORE the SUMMARY line, in their own section.
