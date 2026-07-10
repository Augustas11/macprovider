# Issue #266 Tranche 3 — ARCHITECT audit prompt

You are an independent architecture auditor. Report findings with severities CRITICAL / HIGH / MEDIUM / LOW. **MEDIUM and above gate merge.**

## Context

Issue #266 Tranche 3 (this PR) closes the LAST 3 deferred items + the 2 audit-deferred follow-ups from T2 R1:

- **T3a**: `pool.Provider.SortKey()` consolidation (closes T2 R1 ARCH-L1)
- **T3b**: `routing.RetryHeaderLimit` strconv.Atoi tightening (closes T2 R1 ARCH-L9)
- **T3c**: BalancedScores compute caching threaded through SortCandidatesWithScores + ObjectiveScoresWithCache + logRoutingDecisionFullWithCache (closes T2 R1 ARCH-L2 + ARCH-L8)
- **T3d**: 3 new AC-SR-1 byte-identity scenarios
- **T3e**: HTTP-path integration test for sticky_account_mismatch warn

After this lands, issue #266 has 10/10 items closed (T1: 4, T2: 3, T3: 3 + 2 audit follow-ups).

## Changed files

(Compare against `origin/main` commit `118108f`.)

- `phase4-coordinator/internal/pool/provider.go` (T3a)
- `phase4-coordinator/internal/routing/objective.go` (T3c + T3a internal helper deletion)
- `phase4-coordinator/internal/routing/objective_cache_test.go` (NEW; T3c)
- `phase4-coordinator/internal/routing/retry.go` (T3b)
- `phase4-coordinator/internal/routing/retry_test.go` (T3b)
- `phase4-coordinator/internal/buyer/server.go` (T3a deletion + T3c cache threading)
- `phase4-coordinator/internal/buyer/server_test.go` (T3d 3 new + T3e 1 new)
- `phase4-coordinator/internal/buyer/forward_with_failover.go` (T3a migration)
- `phase4-coordinator/internal/buyer/iss266_t1_test.go` (T3c signature update)

## What to audit (ARCHITECT lens)

1. **`pool.Provider.SortKey()` as the right abstraction.** Pre-T3a both buyer and routing duplicated `ProviderID+/+AssignedID`. Should the method live on the pool type, or should there be a domain-level `RouteKey` type / interface? Value-receiver method on a value type is the simplest possible solution — defensible? Trade-off vs an exported `routing.SortKey(p)` free function (which would couple pool.Provider's identity story to the routing package).
2. **`SortCandidatesWithScores` vs `SortCandidates` ergonomics.** Two surfaces now — caller picks based on whether they need the cache. The deprecated-feel `SortCandidates(...) { SortCandidatesWithScores(..., nil) }` wrapper preserves backwards compat for callers that don't need the cache. Is this the right split, or should we just deprecate `SortCandidates` and have all callers use the WithScores variant?
3. **`ObjectiveScoresWithCache` is similar surface duplication.** Same pattern as SortCandidatesWithScores. Acceptable? Argue.
4. **`balancedCache map[string]float64` threaded as 5th parameter.** `applySticky`, `applyRandomTiebreak`, `inEpsilonCohort` all received a new map parameter. Trade-off: positional growth vs explicit-cache option struct. Acceptable for one new field; would a `selectionContext struct` be a better home if a future param is added?
5. **`logRoutingDecisionFullWithCache` vs `logRoutingDecisionFull` API split.** Same pattern. The retry-path logRoutingDecision wrapper still delegates to logRoutingDecisionFull (with 0/nil for new fields), and logRoutingDecisionFull delegates to logRoutingDecisionFullWithCache. Two-level delegation reads cleanly OR is one-too-many-wrappers?
6. **Cache lifecycle within selectProviderExcluding.** The cache is computed once after the EligibleCandidates filter pass + before applySticky. It's then read by applySticky / applyRandomTiebreak / logRoutingDecisionFullWithCache. The slice contents (candidate set) are stable across these calls — only the ORDER changes (sort, sticky-swap, tiebreak-swap). The cache keys by SortKey, so reordering is fine. Verify the design comment in selectProviderExcluding explains this invariant.
7. **T3c perf gain proportionality.** 16-provider balanced pipeline drops 3841ns → 2108ns (~45%). Is this worth the API churn (4 new exported functions in routing/, 1 new parameter on 3 buyer methods)? At realistic provider counts (typically 1-8 per coordinator), the absolute saving is ~1-2 microseconds per balanced request. Argue or defer caching to a higher-load future where balanced-classes scale matters more.
8. **T3d AC-SR-1 scenarios cover the right shapes.** Empty pool / all-capacity-zero / context-too-small are reasonable additions. Missing from the audit list: all-quota-blocked (would require AdmissionManager fixture — deferred?), tier2-hash-mismatch-with-multiple-mismatched, encrypted-leg-required. Is the T3d coverage sufficient, or is a follow-up needed for the quota / tier2 shapes?
9. **T3e integration test layering.** The test uses an in-process upstream httptest.NewServer + a zerolog buffer + a real buyer.Server with sticky_enabled=true. It IS an integration test. Should it live in test/integration/ instead of internal/buyer/server_test.go? Argue.
10. **Issue #266 closure completeness.** With T3 merged, every item in the issue #266 body is closed. Are there any items the audit missed that should be added before the issue closes?

## Output format

For each finding:
- **Severity**: CRITICAL / HIGH / MEDIUM / LOW
- **Location**: file:line OR "design-level"
- **Issue**: 1-2 sentences
- **Evidence**: quoted code, architectural trade-off
- **Fix sketch**: what would resolve it, OR "accepted with rationale"

Final line MUST be:
```
SUMMARY: CRITICAL=<n> HIGH=<n> MEDIUM=<n> LOW=<n>
```
