## Lane: CODE — Round 2

## Context

R1 audits returned: CODE PASS (0/0/0/0/0), SEC 0/2/0/0/0, ARCH 0/0/1/0/0.

R1 fix-pass landed as commit `9cffa7c` on branch `fix/iss232-fallback-overbill-corroboration`.

Changes since R1 (CODE already accepted but re-fire per [[feedback-skip-accepted-audit-lanes]] because R1 fix-pass touched scope):

1. **`buyer.Result.SawSSEErrorEvent`** added — set in `parseChunkTokens` when any chunk's `error` envelope has non-empty code.
2. **`MatchedPair.HarnessSawSSEErrorEvent`** replaces R0's `HarnessSawTerminator`.
3. **`fallbackOverbillSuppressed`** flipped: `return p.HarnessSawSSEErrorEvent` (suppress when buyer corroborated via gateway error envelope).
4. Tests revised + new benign-no-DONE test added.
5. README + I1 comment updated.

## Your job

CODE LANE round 2: re-audit the full diff.

- Is the `chunkPayload.Error *struct{...}` decode correct? Any nil-pointer hazard?
- Is the `code != ""` guard the right anti-malformed-envelope check?
- Are field renames consistent everywhere (no leftover `HarnessSawTerminator` references)?
- Any test still using `HarnessSawTerminator: ...` that would silently miss new behavior?
- Any path in `matchPairs` (pass 1 / pass 2) that constructs a `MatchedPair` without plumbing the new field?

Standard severity-graded findings. If everything clean, "(none)".

## Files in scope

- `/Users/augstar/macprovider-iss232/test/network-harness/internal/reconcile/ledger.go`
- `/Users/augstar/macprovider-iss232/test/network-harness/internal/reconcile/ledger_test.go`
- `/Users/augstar/macprovider-iss232/test/network-harness/internal/buyer/result.go`
- `/Users/augstar/macprovider-iss232/test/network-harness/internal/buyer/loadgen.go`

R1→R2 diff: `git -C /Users/augstar/macprovider-iss232 show HEAD`
R0→R2 cumulative: `git -C /Users/augstar/macprovider-iss232 diff HEAD~2 HEAD`
