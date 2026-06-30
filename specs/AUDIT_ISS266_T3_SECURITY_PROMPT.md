# Issue #266 Tranche 3 — SECURITY audit prompt

You are an independent security auditor. Report findings with severities CRITICAL / HIGH / MEDIUM / LOW. **MEDIUM and above gate merge.**

## Context

Issue #266 Tranche 3 (this PR) closes:

- **T3a**: new `pool.Provider.SortKey()` method consolidates `ProviderID+/+AssignedID` derivation (13 call sites migrated; buyer.routeKey + routing.providerSortKey deleted)
- **T3b**: `routing.RetryHeaderLimit` switched from `fmt.Sscanf` to `strconv.Atoi` ("3abc" → 0 instead of 3)
- **T3c**: BalancedScores compute caching threaded through buyer pipeline (~45% perf win on balanced routing hot path)
- **T3d**: 3 new AC-SR-1 byte-identity scenarios (empty pool, all-capacity-zero, context-too-small)
- **T3e**: HTTP integration test for sticky_account_mismatch warn emission

REFACTOR + PERF + TESTS — no new functional behaviour at any flag setting.

## Changed files

- `phase4-coordinator/internal/pool/provider.go`
- `phase4-coordinator/internal/routing/objective.go`
- `phase4-coordinator/internal/routing/objective_cache_test.go`
- `phase4-coordinator/internal/routing/retry.go`
- `phase4-coordinator/internal/routing/retry_test.go`
- `phase4-coordinator/internal/buyer/server.go`
- `phase4-coordinator/internal/buyer/server_test.go`
- `phase4-coordinator/internal/buyer/forward_with_failover.go`
- `phase4-coordinator/internal/buyer/iss266_t1_test.go`

Compare against `origin/main` commit `118108f`.

## What to audit (SECURITY lens)

1. **T3a `SortKey` injection surface.** ProviderID and AssignedID are operator/coordinator-issued at provider registration time, not buyer-controlled. The "/" separator could theoretically conflict if a ProviderID legitimately contained "/" but the pre-T3a derivation had the same property. Verify ProviderID validation rejects "/" (per registration path).
2. **T3a `pool.Provider.SortKey` is a value-receiver method.** Calling it on a zero-value `pool.Provider{}` returns "/" (empty/empty). Could a code path receive a zero-value provider and use SortKey as a map key, colliding with a legitimate "" provider? (No — every map keyed by SortKey is populated from a real provider snapshot. But verify.)
3. **T3b `strconv.Atoi` overflow handling.** On 32-bit Go `strconv.Atoi` parses into `int`, so "9999999999" overflows MaxInt32 and returns an error → 0. Same on 64-bit with larger values. Verify the buyer-header path can't be exploited to set N to MaxInt64 via "9223372036854775807" (technically legitimate but practically equivalent to "true"). This isn't a regression — pre-T3b Sscanf had identical overflow semantics. Verify.
4. **T3b "true" sentinel still works.** Switching from Sscanf to Atoi removed the `Sscanf("%d")` parse attempt; the `EqualFold("true")` check now happens first AND still returns math.MaxInt. Verify "TRUE", "True", "  true  " (after trim) all return MaxInt.
5. **T3c cache as attack surface.** The balanced-score cache is internal to selectProviderExcluding — not exposed via any external surface. But the cache map is keyed by `pool.Provider.SortKey()` (operator-controlled string). Could a hostile provider with carefully-crafted ProviderID + AssignedID inject a key that collides with another provider's cache entry? Only if there's a duplicate SortKey across distinct providers — and SessionManager guarantees unique (ProviderID, AssignedID) tuples per registration.
6. **T3c stale cache in retry path.** The cache is computed BEFORE applySticky / applyRandomTiebreak, both of which can reorder the candidate slice. If a NEW provider enters the candidate slice between the cache computation and a downstream consumer, the consumer reads `cache[newProvider.SortKey()]` and gets 0 (Go map default). Verify: no code path mutates `candidates` between the cache compute and the last cache lookup. (The slice is reordered by sort/sticky/tiebreak, but the SET stays constant.)
7. **T3c cache returned to caller doesn't escape per-request scope.** `selectProviderExcluding` returns the provider; the cache local goes out of scope. Verify no field on Server retains the cache (it does not — verified above; cache stays on the stack).
8. **T3e log-buffer test assertions.** The integration test counts log occurrences via `strings.Count(logOut, "sticky_account_mismatch")`. Could a benign log row containing that string elsewhere (e.g., as a substring of another event's message) inflate the count and mask a regression? Inspect the assertion + log emitter wording.
9. **T3e two-request mismatch — entry resurrection.** After the second request triggers cross-account refusal, the original entry MUST remain attributed to acct_alice. The test doesn't assert this directly (only the warn count + provider/scope fields). Should it? Argue.
10. **Default-OFF posture preserved.** No new code path activates new behaviour at default config. The cache is only computed when balanced objective is in effect (operator-set classes). The strconv.Atoi tightening only changes parsing of malformed buyer-sent headers (which the buyer should never have sent).

## Output format

For each finding:
- **Severity**: CRITICAL / HIGH / MEDIUM / LOW
- **Location**: file:line
- **Issue**: 1-2 sentences
- **Evidence**: quoted code or attack scenario
- **Fix sketch**: what would resolve it

Final line MUST be:
```
SUMMARY: CRITICAL=<n> HIGH=<n> MEDIUM=<n> LOW=<n>
```
