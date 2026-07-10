## Lane: CODE

## Context

You are auditing a fix for issue [#232](https://github.com/Augustas11/macprovider/issues/232): the harness reconciler's R5 fallback-outcome exclusion made the gateway's outcome label a trust gate — a buggy/attacker-controlled gateway labeling a real overbill as `stream_truncated` would hide it from I1.

Fix landed as commit `2f31941` on branch `fix/iss232-fallback-overbill-corroboration` in worktree `/Users/augstar/macprovider-iss232/`.

### The fix

1. **New field `MatchedPair.HarnessSawTerminator`** carries `buyer.Result.SawTerminator` (true when the SSE stream ended with `data: [DONE]`) through both pass-1 (exact-id) and pass-2 (fuzzy) match construction sites.

2. **New helper `fallbackOverbillSuppressed(p MatchedPair) bool`**:
   - Returns false for `outcome == "ok"` (never suppress).
   - Returns `!p.HarnessSawTerminator` for fallback outcomes (suppress only when harness corroborates truncation).

3. **`computePerPairDrift`** switches both axes (`GatewayOverbillVsHarnessTokens` + `GatewayOverbillVsCoordinatorTokens` + `AbsGatewayCoordinatorMismatchTokens`) from `isGatewayOKOutcome(p.GatewayOutcome)` to `!fallbackOverbillSuppressed(p)`.

4. **Tests** — pre-existing R5 test still passes (uses default `SawTerminator=false`); two new tests cover the trust-gap scenario and the explicit legitimate-F-8 happy path.

## Your job

CODE LANE: focus on Go correctness — nil checks, slice/struct semantics, off-by-one, struct field-tag drift, JSON serialization compatibility, unused variables, error paths.

Re-read the FILES IN SCOPE then produce a finding list:

```
CRITICAL: <one-line title>
  file:line — <one-sentence problem statement>
  why it matters: <one sentence>
  suggested fix: <one to two sentences>

HIGH: <...>
MEDIUM: <...>
LOW: <...>
INFO: <...>
```

If a severity has no findings, write "(none)".

## Files in scope

- `/Users/augstar/macprovider-iss232/test/network-harness/internal/reconcile/ledger.go`
- `/Users/augstar/macprovider-iss232/test/network-harness/internal/reconcile/ledger_test.go`
- `/Users/augstar/macprovider-iss232/test/network-harness/internal/buyer/result.go` (reference)

Diff: `git -C /Users/augstar/macprovider-iss232 show HEAD`
