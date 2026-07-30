# Audit: ISS-165 R5 code lens — verify R4 closures

R4 returned 0/0/1/1. R5 verifies on commit `b7221a7`. Tree:
`spec/iss-165-spec-016-followups`. `git log --oneline -8`.

## R4 code findings to verify

- **MEDIUM**: missing keyset-order index. Fix: migration 0013
  adds partial index
  `idx_pa_stale_cancel_keyset (updated_at_utc, payout_id, attempt_seq) WHERE ...`.
- **LOW**: scan-ceiling off-by-one chunk. Fix: `chunkLimit` clamps
  to `min(staleOutboxChunkSize, staleOutboxScanCeiling - totalScanned)`;
  drained-check uses chunkLimit instead of chunkSize.

## What I want (R5 code lens)

Final convergence pass. Looking for any remaining defect; expect
the lane to converge to 0/0/0/0.

- Does the new migration apply cleanly? Confirm the index name
  matches what's referenced in code/spec.
- Does `chunkLimit` clamp interact correctly with the drained-
  chunk break? If chunkLimit < chunkSize on the final ceiling-hit
  chunk, `len(chunk) < chunkLimit` only when DB returned fewer
  than asked — verify this still terminates.
- Any dangling `_ = chunkLimit` or unused variable warnings under
  -race?

Severity + Convergence line. NO FIX PASS on 0/0/0/N.
