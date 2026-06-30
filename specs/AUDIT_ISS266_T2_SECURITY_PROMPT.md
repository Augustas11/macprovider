# Issue #266 Tranche 2 — SECURITY audit prompt

You are an independent security auditor. Report findings with severities CRITICAL / HIGH / MEDIUM / LOW. **MEDIUM and above gate merge.**

## Context

Issue #266 Tranche 2 (this PR) extracts three refactor-only items into `internal/routing/`:

1. **`internal/routing/objective.go`** — `SortCandidates` / `ObjectiveScores` / `KeyedBalancedScores`
2. **`internal/routing/dispatch.go`** — `RewriteModel(rawBody, requestedModel, providerModelID)` + `jsonValueStart`
3. **`internal/routing/retry.go`** — `RetryHeaderLimit(value)` + `ShouldRetry(ShouldRetryInput)`

REFACTOR-ONLY — no new functional behaviour at any flag setting.

## Changed files

- `phase4-coordinator/internal/routing/objective.go` (NEW)
- `phase4-coordinator/internal/routing/dispatch.go` (NEW)
- `phase4-coordinator/internal/routing/retry.go` (NEW)
- `phase4-coordinator/internal/routing/{objective,dispatch,retry}_test.go` (NEW)
- `phase4-coordinator/internal/buyer/server.go` (modified — delegations + helper deletions)

Compare against `origin/main` commit `798e57b`.

## What to audit (SECURITY lens)

1. **`RewriteModel` attack surface.** The function decodes buyer-controlled JSON. Verify no new injection paths: the non-canonical-case rejection ("Model" vs "model") survives the extraction — it's the defence against header-smuggling where a downstream layer might match case-insensitively while routing matches case-sensitively. Verify the duplicate-model rejection survives (buyer can't sneak a second model field past the surgical rewrite).
2. **Empty / nil rawBody.** Does RewriteModel handle nil or empty input safely? The JSON decoder produces a defined error in both cases — verify no panic or silent acceptance.
3. **Oversized rawBody.** RewriteModel allocates a copy of the input twice (match-skip path: 1 copy; rewrite path: 1 source copy + 1 destination splice). The original buyer body size is operator-capped via `MaxChatRequestBodyBytes`. Verify the routing-package extraction doesn't accidentally bypass that cap (e.g., by being called from a code path that doesn't go through the limit reader).
4. **Integer overflow in RetryHeaderLimit.** `math.MaxInt` on 32-bit Go is smaller than on 64-bit. Could a buyer driving a header value past 64-bit MaxInt overflow? `fmt.Sscanf("%d", &n)` parses into a native `int`; on overflow it returns an error which the function maps to 0. Verify.
5. **ShouldRetry input untrustedness.** Fields are derived from a mix of operator config (MaxRetries) and buyer-controlled headers (RequestedRetries, HasPinnedRoute). Confirm the gate logic doesn't trust RequestedRetries to bound any allocation — it only gates a boolean.
6. **Removed `int(^uint(0)>>1)` → `math.MaxInt` substitution.** On 32-bit platforms, `^uint(0)>>1` produces `math.MaxInt32` (2^31 - 1), but on 64-bit it produces `math.MaxInt64`. `math.MaxInt` resolves to the same per-platform value. Bit-identical? Yes — confirm.
7. **`providerSortKey` vs `routeKey` divergence.** `routing.providerSortKey` returns `ProviderID+"/"+AssignedID`; `buyer.routeKey` does the same. Sticky-affinity correctness depends on these matching exactly — if they ever diverge, the sort uses one key and downstream lookups (e.g., sticky-affinity hit detection) use another, potentially leaking sticky attribution across accounts.
8. **Default-OFF posture preserved.** No new code path activates new behaviour at default config; verify the routing package's exported API is only consumed via the existing buyer delegators, not via any new entry point that bypasses default-OFF.

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
