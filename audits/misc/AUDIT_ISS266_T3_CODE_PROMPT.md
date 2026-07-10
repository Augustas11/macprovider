# Issue #266 Tranche 3 — CODE audit prompt

You are an independent code auditor. Report findings with severities CRITICAL / HIGH / MEDIUM / LOW. **MEDIUM and above gate merge.**

## Context

Issue #266 Tranche 3 (this PR) closes the remaining 3 deferred items + 2 audit-deferred follow-ups from #266:

- **T3a — `pool.Provider.SortKey()`**: new method `func (p Provider) SortKey() string` returning `ProviderID+"/"+AssignedID`. Eliminates the duplicate derivation that lived in `buyer.routeKey`, `routing.providerSortKey`, and `startRecoveryProbe`'s inline concat. 13 call sites migrated.
- **T3b — `routing.RetryHeaderLimit`**: parser switched from `fmt.Sscanf("%d")` to `strconv.Atoi`. "3abc" now returns 0 (whole-string match required), where pre-T3b it returned 3.
- **T3c — BalancedScores compute caching**: new `routing.SortCandidatesWithScores` returns the balanced-score map; new `routing.ObjectiveScoresWithCache` accepts it; new `buyer.Server.logRoutingDecisionFullWithCache` threads it. The hot path computes the FR-SR-8 formula ONCE per request instead of O(N) times. Benchmark: 16-provider balanced pipeline 3841ns → 2108ns (~45% drop).
- **T3d — 3 new AC-SR-1 scenarios** in `buyer/server_test.go`: empty pool, all-capacity-zero, context-too-small.
- **T3e — HTTP integration test** for `sticky_account_mismatch` warn emission via zerolog buffer + two-request mismatch scenario.

REFACTOR + PERF + TESTS — no new functional behaviour at any flag setting. Default-OFF posture preserved.

## Changed files

- `phase4-coordinator/internal/pool/provider.go` — new `SortKey` method
- `phase4-coordinator/internal/routing/objective.go` — refactored to `SortCandidatesWithScores` + `ObjectiveScoresWithCache`; deleted internal `providerSortKey`
- `phase4-coordinator/internal/routing/objective_cache_test.go` — NEW
- `phase4-coordinator/internal/routing/retry.go` — Sscanf → strconv.Atoi
- `phase4-coordinator/internal/routing/retry_test.go` — 2 new test cases
- `phase4-coordinator/internal/buyer/server.go` — delegations + cache threading; deleted `routeKey`; migrated 4 call sites
- `phase4-coordinator/internal/buyer/forward_with_failover.go` — `routeKey(state.provider)` → `state.provider.SortKey()` (3 sites)
- `phase4-coordinator/internal/buyer/server_test.go` — 4 new tests (3 AC-SR-1 + 1 sticky_account_mismatch HTTP integration)
- `phase4-coordinator/internal/buyer/iss266_t1_test.go` — updated 3 `applyRandomTiebreak` call sites to pass nil cache

Compare against `origin/main` commit `118108f`.

## What to audit (CODE lens)

1. **Behaviour preservation for T3a.** `pool.Provider.SortKey()` returns exactly `ProviderID+"/"+AssignedID` — same string as the pre-T3a `buyer.routeKey` and `routing.providerSortKey`. Verify by inspection. Then walk every migrated call site (13 of them) and confirm: (a) the receiver value semantics match the pre-T3a `routeKey(p)` semantics (no nil-pointer issues since `pool.Provider` is a value type, not a pointer), (b) the `pool.Provider.SortKey` method-expression passed to `routing.EligibleCandidates` produces the same `func(pool.Provider) string` shape the keyer parameter expects.
2. **T3b `strconv.Atoi` regression risk.** Pre-T3b "3abc" → 3, "3" → 3. Post-T3b "3abc" → 0, "3" → 3. Are there any deployed buyer configs that rely on the trailing-junk lenient parse? (The buyer header is documented as integer-only; no known production caller sends garbage; this is a tightening, not a regression.)
3. **T3c cache contract correctness.**
   - `SortCandidatesWithScores` returns a non-nil map ONLY for ObjectiveBalanced (and only after computing it via KeyedBalancedScores OR reading from the supplied cache). nil for fast/accurate/default.
   - `ObjectiveScoresWithCache` returns the supplied cache verbatim for ObjectiveBalanced + non-nil cache; otherwise recomputes.
   - Verify: when the cache is supplied to SortCandidatesWithScores AND the supplied cache contains stale/wrong values, the sort respects the cache (intentional — caller owns cache lifecycle).
   - Verify: passing the SAME slice through SortCandidatesWithScores then ObjectiveScoresWithCache with the returned cache yields a map that, for every candidate, has the SAME value KeyedBalancedScores would have computed fresh.
4. **T3c integration with the buyer pipeline.**
   - `selectProviderExcluding` captures `balancedCache := s.sortCandidates(...)` then threads it to applySticky, applyRandomTiebreak, logRoutingDecisionFullWithCache.
   - `inEpsilonCohort` was extended with a `balancedCache map[string]float64` parameter; nil falls through to `routing.KeyedBalancedScores(candidates)`. Verify no caller passes a nil unexpectedly.
   - `applyRandomTiebreak` + `applySticky` both received the cache parameter. Verify their existing test callers were updated (iss266_t1_test.go).
   - Verify: the SPEC-004 §7 routing-decision log emitted by `logRoutingDecisionFullWithCache` contains the SAME `objective_metric` values per candidate as the pre-T3c log emitted via `logRoutingDecisionFull` + recompute.
5. **T3c balanced-objective sort stability.** `routing.SortCandidatesWithScores` uses `sort.SliceStable` everywhere. With a pre-supplied cache (T3c new path), does the comparator still produce a stable sort? (Yes — the cache map is read-only inside the comparator.)
6. **T3d AC-SR-1 scenario correctness.**
   - Empty pool: asserts 404 model_not_found. Verify the route is hit (line ~1424 model-known check returns early).
   - All-capacity-zero: asserts 503 no_provider_available. Verify ApplyStateUpdate with SlotsFree=0 takes effect immediately + the EligibleCandidates path drops these via the not_ready/no-capacity gate.
   - Context-too-small: asserts 413 context_exceeds_capacity. Verify the new prompt-token estimate vs MaxContextTokens gate path.
7. **T3e HTTP integration test correctness.**
   - First request lands the sticky entry (sticky_enabled=true, conv key with "conv:" prefix).
   - Second request with different account triggers `sticky.Map.Update` mismatch=true.
   - The buyer-side stickyStore wraps the warn through `stickyMismatchLimiter.allow(key)`; for a fresh key the limiter allows.
   - Assert: exactly ONE `sticky_account_mismatch` log row. Verify the count + the fields.
8. **Deletions are complete.** `routeKey` (buyer), `providerSortKey` (routing internal). Confirm no remaining references via grep.
9. **Imports stayed correct.** After deletions: buyer/server.go may have an unused import. routing/retry.go now uses `strconv` instead of `fmt`. Verify with `go vet` clean.

## Output format

For each finding:
- **Severity**: CRITICAL / HIGH / MEDIUM / LOW
- **Location**: file:line
- **Issue**: 1-2 sentences
- **Evidence**: quoted code or contradicting diff
- **Fix sketch**: what would resolve it

Final line MUST be:
```
SUMMARY: CRITICAL=<n> HIGH=<n> MEDIUM=<n> LOW=<n>
```
