# Issue #266 Tranche 2 — ARCHITECT audit prompt

You are an independent architecture auditor. Report findings with severities CRITICAL / HIGH / MEDIUM / LOW. **MEDIUM and above gate merge.**

## Context

Issue #266 Tranche 2 (this PR) extracts three refactor-only items into the `internal/routing/` package:

1. **`internal/routing/objective.go`** — `SortCandidates(candidates, objective, weights)` + `ObjectiveScores` + `KeyedBalancedScores`
2. **`internal/routing/dispatch.go`** — `RewriteModel(rawBody, requestedModel, providerModelID)` + `jsonValueStart`
3. **`internal/routing/retry.go`** — `RetryHeaderLimit(value)` + `ShouldRetry(ShouldRetryInput)` + `ShouldRetryInput` struct

REFACTOR-ONLY — no new functional behaviour at any flag setting. Buyer methods become thin delegators; helpers `effectiveThroughput`, `balancedScores`, `retryHeaderLimit` deleted.

This advances the SPEC-004 architecture goal of `internal/routing/` owning the canonical routing logic (filter, sort, tiebreak, dispatch, retry policy) so the buyer package focuses on transport orchestration. PR #263 extracted candidate/epsilon/exclusion/filter/log/class; this PR adds the remaining three of the Phase D deferred set.

## Changed files

- `phase4-coordinator/internal/routing/objective.go` (NEW)
- `phase4-coordinator/internal/routing/dispatch.go` (NEW)
- `phase4-coordinator/internal/routing/retry.go` (NEW)
- `phase4-coordinator/internal/routing/{objective,dispatch,retry}_test.go` (NEW)
- `phase4-coordinator/internal/buyer/server.go` (modified — delegations + helper deletions)

Compare against `origin/main` commit `798e57b`.

## What to audit (ARCHITECT lens)

1. **`providerSortKey` duplication.** `routing.providerSortKey` is internal and produces `ProviderID+"/"+AssignedID`; `buyer.routeKey` produces the same string. Two implementations of the same key derivation is a latent divergence trap. Should `buyer.routeKey` call into `routing.providerSortKey` (exported), or should both share a `pool.Provider.SortKey()` method on the pool type? Argue.
2. **`SortCandidates` ergonomics.** The signature is `(candidates, objective, weights)`. A caller that wants BOTH the sorted slice AND the per-candidate scores must call `SortCandidates` then `ObjectiveScores`, computing BalancedScores twice for balanced objective. Is this acceptable per the deferred #266 "BalancedScores compute caching" item, or should T2 land a `SortAndScore` helper that returns both in one pass?
3. **`ShouldRetryInput` struct vs positional args.** Pre-extraction signature: `shouldRetry(r, startedAt, explicit, faulted, status, err)` — 6 positional args. Post-extraction: a 13-field struct. Trade-off: explicit struct documents which inputs matter (good for unit tests) vs heavier call surface (every caller must populate every field, even ones it doesn't care about). Is the struct the right call?
4. **`buyer.Server.shouldRetry` wrapper stays.** Pre-extraction call sites of `s.shouldRetry(r, ...)` continue to work unchanged — the wrapper bundles Server state into `ShouldRetryInput` and calls `routing.ShouldRetry`. Should the wrapper STAY (keep call sites stable; deferred to a follow-up) or be INLINED at the four call sites (one fewer indirection; deeper diff)?
5. **`RewriteModel` returns []byte; downstream consumers may mutate.** The function copies the input slice in BOTH the match-skip path AND the rewrite path. Confirm callers (forwardStreamSequence / WS-non / HTTP) don't accidentally rely on the input being mutated in place — and confirm the copy isn't wasteful for the match-skip path (could it return the original slice + a "do not mutate" contract? Argue trade-off).
6. **routing package import-cycle hygiene.** `internal/routing/` imports `internal/pool` but NOT `internal/config` (which would create a cycle when config grows to reference routing types). Extracted code keeps this invariant?
7. **Test-coverage delta.** 26 new unit tests added; pre-extraction buyer tests covered the same surfaces. Is the test coverage net-additive (good — new tests at the new boundary), or are buyer tests now redundant duplicates of routing tests?
8. **Future T3 readiness.** Tranche 3 (the remaining #266 items) needs to add `BalancedScores` compute caching, more AC-SR-1 byte-identity scenarios, and an HTTP-path integration test. Does the T2 extraction set the stage cleanly for those — i.e., is `KeyedBalancedScores` the right caching target, or does T3 need to thread a cache through `SortCandidates` directly?

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
