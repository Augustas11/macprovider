# Issue #266 Tranche 2 — CODE audit prompt

You are an independent code auditor. Report findings with severities CRITICAL / HIGH / MEDIUM / LOW. **MEDIUM and above gate merge.**

## Context

Issue #266 closes deferred follow-ups from PR #263. Tranche 2 (this PR) extracts three refactor-only items into the `internal/routing/` package, with ZERO behaviour change at any flag setting:

1. **`internal/routing/objective.go`** — `SortCandidates(candidates, objective, weights)` + `ObjectiveScores` + `KeyedBalancedScores`, extracted from `buyer.Server.sortCandidates` / `routingScores` / `balancedScores` on `origin/main` commit `798e57b`.
2. **`internal/routing/dispatch.go`** — `RewriteModel(rawBody, requestedModel, providerModelID)` + internal `jsonValueStart`, extracted from `buyer.dispatchBodyForProvider`.
3. **`internal/routing/retry.go`** — `RetryHeaderLimit(value)` + `ShouldRetry(in ShouldRetryInput)` extracted from `buyer.Server.shouldRetry` + `buyer.retryHeaderLimit`.

Buyer-side methods become thin delegators. Buyer helpers `effectiveThroughput`, `balancedScores`, `retryHeaderLimit` are DELETED — sole callers migrated to routing primitives.

**Audit question**: Does the extracted code produce byte-identical behaviour to the pre-extraction inline code at every input shape?

## Changed files

- `phase4-coordinator/internal/routing/objective.go` (NEW)
- `phase4-coordinator/internal/routing/objective_test.go` (NEW)
- `phase4-coordinator/internal/routing/dispatch.go` (NEW)
- `phase4-coordinator/internal/routing/dispatch_test.go` (NEW)
- `phase4-coordinator/internal/routing/retry.go` (NEW)
- `phase4-coordinator/internal/routing/retry_test.go` (NEW)
- `phase4-coordinator/internal/buyer/server.go` (modified — delegations + helper deletions)

Compare against `origin/main` commit `798e57b`.

## What to audit (CODE lens)

1. **Behaviour preservation per extraction.** For each of the three extractions, walk through the pre-extraction code and the new code side-by-side. Are the comparator branches identical? Is the JSON-rewrite byte-stream identical? Is the ShouldRetry gate sequence identical?
2. **`SortCandidates` vs pre-extraction `sortCandidates`** — verify the four objective branches map exactly (fast → tps desc + slots asc; accurate → params desc + tps desc + slots asc; balanced → balanced-score desc + slots asc; default → slots asc + tps desc). Verify `sort.SliceStable` is preserved everywhere (stable sort matters for sticky-affinity pre-sort ordering).
3. **`ObjectiveScores` vs pre-extraction `routingScores`** — verify the map keys (ProviderID+/+AssignedID) match what `buyer.routeKey` produces. Verify the per-objective value source is correct (fast→eff_tps, accurate→params, default→eff_tps, balanced→KeyedBalancedScores).
4. **`KeyedBalancedScores`** — verify it produces the same map shape that the pre-extraction `buyer.balancedScores` produced (indexed slice from `BalancedScores` mapped onto routeKey).
5. **`RewriteModel`** — diff against pre-extraction `dispatchBodyForProvider`. Verify: model-match-skip path (uses `strings.EqualFold`, mirroring pre-extraction `modelIDEqual`); JSON-decoder + jsonValueStart byte-position tracking; replacement-set accumulation; non-canonical-case rejection; duplicate / missing rejection; final byte splice. Argue byte-for-byte equivalence.
6. **`ShouldRetry`** — diff against pre-extraction `buyer.Server.shouldRetry`. Verify gate order matches exactly. Verify the `min(MaxRetries, RequestedRetries)` calculation matches pre-extraction. Verify the time-budget arithmetic preserves the inequality direction.
7. **`RetryHeaderLimit`** — diff against pre-extraction `buyer.retryHeaderLimit`. Note the change from `int(^uint(0)>>1)` to `math.MaxInt` — verify these are bit-identical.
8. **Wrapper completeness.** `buyer.Server.shouldRetry` wrapper bundles caller state into `ShouldRetryInput`. Confirm via grep that all pre-PR call sites of the wrapper continue to work without modification.
9. **Buyer-side helper deletions.** `effectiveThroughput`, `balancedScores`, `retryHeaderLimit` (buyer-side) were deleted. Confirm no remaining references via grep. Confirm imports stayed correct (`bytes`, `encoding/json`, `errors`, `fmt`, `sort`, `strings` are still needed by other code in server.go).

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
