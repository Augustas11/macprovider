# Issue #266 Tranche 1 — ARCHITECT audit prompt

You are an independent architecture auditor. Read this prompt + the diff + the files referenced and report findings.

## Context

Issue #266 closes deferred follow-ups from PR #263 (SPEC-004 Pillars B/C/D/A bundled smart-router IMPL). Tranche 1 (this PR) lands four safety / correctness items:

1. **SIGHUP InvalidateClass wiring** — wires the previously-shipped `sticky.Map.InvalidateClass` primitive into the `reloadTier2Config` SIGHUP path. Detects `routing.model_classes` shape changes (added/removed/membership/objective differences) and invalidates sticky entries for every changed class. Per SPEC-004 FR-SR-5 paragraph 2 "invalidate on class reconfig".
2. **Per-attempt FR-SR-17 log threading** — populates `AttemptIndex / RetryCount / RetryReason / Retried / PreflightResult` in the routing-decision log emitted at each retry advance, across all three transport sequences (streaming, WS-non-streaming, HTTP). Pre-PR these fields were 0/empty on retries.
3. **Mid-request stable seed across UTC midnight** — snapshots `defaultDailyKey()` (UTC YYYY-MM-DD) into `forwardState.dailyKey` ONCE at request entry. Threads the value through `selectProvider*` / `failoverCandidate` / `applyRandomTiebreak` so retries past midnight reproduce the first-attempt seed.
4. **`sticky_account_mismatch` warn-log rate-limit** — adds a bounded LRU limiter (per-conversation_key, 1-minute window, MaxEntries=stickyMaxEntries) to throttle the warn-log emitted from `stickyStore` on cross-account refresh refusal.

All four flags ship default-OFF. Phase 2 operator green-light flips them ON.

## Changed files (read these in full)

- `phase4-coordinator/internal/buyer/server.go`
- `phase4-coordinator/internal/buyer/forward_state.go`
- `phase4-coordinator/internal/buyer/forward_with_failover.go`
- `phase4-coordinator/internal/buyer/sticky_mismatch_limiter.go`
- `phase4-coordinator/internal/buyer/iss266_t1_test.go`
- `phase4-coordinator/cmd/coordinator/main.go`

## What to audit (ARCHITECT lens)

Report severities CRITICAL / HIGH / MEDIUM / LOW. **MEDIUM and above gate merge.**

Focus on:

1. **Right abstraction boundaries.** SetRoutingClasses + diffModelClasses + modelClassEqual + stringSliceEqual live in `internal/buyer/server.go`. Should these belong in `internal/routing/` or `internal/config/` instead? Argue for the current placement OR propose a better one. Note: PR #263 already extracted routing primitives to `internal/routing/` but kept buyer-Server methods in buyer/. SetRoutingClasses is a Server method by necessity (it mutates s.modelClasses + calls s.stickyMap.InvalidateClass).
2. **forwardState.dailyKey is the right home for the snapshot.** Alternative designs considered: pass dailyKey via context.Value; embed in a per-request RoutingParams struct; store in the request log row. forwardState is the existing per-request state container — adding dailyKey there is the smallest-diff choice. Verify there's no better home (e.g., billingRecorder which also holds per-request state).
3. **applyRandomTiebreak signature evolution.** The function now takes a 4th `dailyKey string` arg. The empty-string fallback to `defaultDailyKey()` lets callers without forwardState still produce a non-zero seed. Audit-question: is the empty-string-as-sentinel an anti-pattern? Alternatives: a `*string` argument (explicit nil); a separate `applyRandomTiebreakWithKey` method; a routing.SeedSource interface. Trade off the cost of API churn vs. the readability win.
4. **logRoutingDecisionRetry vs logRoutingDecisionFull divergence.** Both emit `routing_decision` events but the retry variant emits CandidateCountBeforeFilters=CandidateCountAfterFilters=1 (since it's a single-provider slice post-advance), while the main-selection variant emits real pre-filter pool size + per-reason filtered_counts. Log consumers see two shapes of the same event. Acceptable per SPEC-004 §7's "Every routed request SHOULD produce a structured routing-decision log"? Or should the retry variant set the count fields to 0/omit so consumers can distinguish?
5. **Concurrency model for routingMu.** SetRoutingClasses uses `Lock`; resolveModelClass + snapshotModelClasses use `RLock`. The hot path takes RLock per call. Under sustained config-reload pressure (very rare), readers could starve writers (impossible since sync.RWMutex prefers writers in Go's impl) or vice versa. Note: model_classes reads are O(N_classes) where N_classes is operator-set, typically single digits. Acceptable contention model?
6. **Order of operations in SetRoutingClasses.** Swap-then-purge: write-lock → diff → swap s.modelClasses → unlock → InvalidateClass(name) for each changed class. Between unlock and InvalidateClass, a hot-path request could read the new modelClasses (correct map) but still hit a stale sticky entry the purge hasn't reached yet. Is this acceptable? (Argument: yes — the sticky entry still points to a provider that's IN the (new) class, since members[name] is the union; the next request hits the new config and the sticky entry either matches or fails the "provider in candidate" check via existing routing. But verify.)
7. **stickyMismatchLimiter sizing.** Default MaxEntries=10000 mirrors stickyMap. The limiter map is keyed by conversation_key (same key space as stickyMap). Under sustained pressure where every conv_key has at least one mismatch, the limiter map grows to roughly stickyMap.Len(). Memory cost: one `time.Time` (~24 bytes) + one string ref per key. Acceptable. Verify there isn't a better data structure (e.g., bloom filter — too lossy here).
8. **Reload-path dependency on cfg.Routing in reloadTier2Config.** The function name is "Tier2" but it now also reloads billing AND routing. Should it be renamed (reloadConfig) or split? Note: PR #263 already grew it with billing; this PR adds routing. The growth pattern is "anything driven by SIGHUP that's safe to hot-reload" — function name has become misleading.
9. **WS-non-streaming afterAdvance log added.** Pre-PR the WS-non-streaming retry path did NOT emit a routing-decision log on advance (only streaming + HTTP did). This PR adds the missing emission for parity. Is this the right call (audit-explainability uniformity) or a SPEC-004 §7 over-interpretation (the spec doesn't mandate per-transport)?
10. **Tracking-issue scope.** Tranche 1 lands 4 of the 10 items in #266. Tranche 2 (refactor-only extractions) and Tranche 3 (perf + tests) are deferred. Is this the right cut — i.e., do the four items in this PR cover the "operator green-light prerequisites" cleanly and is the deferred set genuinely safe at default-OFF?

## Output format

For each finding:
- **Severity**: CRITICAL / HIGH / MEDIUM / LOW
- **Location**: file:line OR "design-level"
- **Issue**: 1-2 sentences
- **Evidence**: quoted code, spec citation, or architectural trade-off
- **Fix sketch**: what would resolve it, OR "accepted with rationale"

Final line MUST be:
```
SUMMARY: CRITICAL=<n> HIGH=<n> MEDIUM=<n> LOW=<n>
```
