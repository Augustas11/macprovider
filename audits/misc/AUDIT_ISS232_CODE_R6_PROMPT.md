## Lane: CODE — Round 6

## Context

R5: CODE 0/0/1/1 (multi-line + CR), SEC 0/2 (BOM + EOF dispatch), ARCH 0/0/2/2.

R5 fix-pass landed as commit `5d60114`:
1. Strip UTF-8 BOM at stream start.
2. Track `envelopeDispatched` (blank-line semantics).
3. `isSettlementComplete` accepts `provider_timeout`.
4. SPEC-019 4-code list.
5. SPEC-006 §17.7.1 mapping clarified (pass-through exclusion).

## Your job

CODE LANE round 6. Re-audit:

- `bomConsumed` flag pattern — any edge case (e.g. empty stream first chunk doesn't trigger the BOM check)?
- `envelopeDispatched` tracking — does it correctly reset when a non-envelope chunk follows the envelope before the blank line?
- Are the new R5 tests independent from each other?
- The 4-code list in `isSettlementComplete` — any other outcome value used by the gateway that's still missing?

Standard severity-graded findings.

## Files in scope

- `/Users/augstar/macprovider-iss232/test/network-harness/internal/buyer/loadgen.go`
- `/Users/augstar/macprovider-iss232/test/network-harness/internal/buyer/loadgen_iss232_test.go`
- `/Users/augstar/macprovider-iss232/test/network-harness/internal/reconcile/ledger.go`

R5→R6 diff: `git -C /Users/augstar/macprovider-iss232 show HEAD`
