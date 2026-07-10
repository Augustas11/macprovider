## Lane: ARCHITECT

## Context

Auditing fix for issue [#232](https://github.com/Augustas11/macprovider/issues/232). Fix landed as commit `2f31941` on branch `fix/iss232-fallback-overbill-corroboration` in worktree `/Users/augstar/macprovider-iss232/`.

### History

- PR #229 R5: fallback pairs excluded from I1 overbill signal → false-fail fix on production #226 shape, but gateway outcome label becomes trust gate.
- PR #229 R6 SEC HIGH: trust shift flagged → tracked as #232.
- PR #286: same exclusion extended to gateway-vs-coordinator axis (trust gap now on both axes).
- PR #288 (Wave 0a): gateway switches to provider-usage-on-clean-streams → production fallback surface shrinks empirically.
- THIS PR: trust gap closed via `HarnessSawTerminator` corroboration.

### Issue #232 had proposed three fix shapes:

1. Harness-side evidence of truncation (chosen — this PR)
2. Suspicious-delta reference field (additive triage signal)
3. Per-outcome tolerance bound

## Your job

ARCHITECT LANE: focus on whether the design is well-bounded and whether option (1) was the right choice. Specifically:

- Is `SawTerminator` the right trust anchor, or is it too coarse / too brittle? What if the harness fails to capture it correctly (any reason it could be wrong-positive or wrong-negative)?
- Should this PR have ALSO added the option (2) reference field (`FallbackOverbillSuspiciousTokens`)? Or is the binary include/exclude rule sufficient now that corroboration gates it?
- The fix touches BOTH the gateway-vs-harness axis AND the gateway-vs-coordinator axis with the same suppression rule. Is that the right symmetry, or should the coord axis use a different anchor (since coord and gateway are both server-side, neither is the buyer)?
- The new helper `fallbackOverbillSuppressed` centralizes the rule. Does this make a future option (3) tolerance-based change cleaner, or does it lock in the binary decision?
- Any spec/doc that needs to change to reflect the new corroboration rule? (I1 docs, SPEC-006 §17.7 references, the harness README.)

Standard severity-graded findings.

## Files in scope

- `/Users/augstar/macprovider-iss232/test/network-harness/internal/reconcile/ledger.go`
- `/Users/augstar/macprovider-iss232/test/network-harness/internal/reconcile/ledger_test.go`
- `/Users/augstar/macprovider-iss232/test/network-harness/internal/buyer/result.go`
- `/Users/augstar/macprovider-iss232/test/network-harness/README.md`

Diff: `git -C /Users/augstar/macprovider-iss232 show HEAD`
