# Audit: ISS-165 R4 code lens — verify R3 keyset fix

R3 returned 0/0/1/2 (code). R4 verifies on commit `a8574cd`.
Tree: `spec/iss-165-spec-016-followups`. `git log --oneline -7`.

## R3 code findings to verify

- **MEDIUM**: unbounded materialization → keyset pagination.
- **LOW-1**: stale comments → rewritten.
- **LOW-2**: test gap for large prefix → new test
  `TestProduceStaleOutboxRows_LargeNonActionablePrefixDoesNotStarve`.

## What I want (code lens)

Verify the keyset migration is sound:

- Strict tuple ordering form
  `(updated_at_utc > ? OR (= AND payout_id > ?) OR (= AND = AND
  attempt_seq > ?))` — correct semantics, no off-by-one when
  consecutive rows share `updated_at_utc`?
- Cursor advance: `cursorUpdated = last.ReorgReactivated` —
  confirm `ReorgReactivated` IS the `updated_at_utc` column (the
  scan field). Look at `cand.ReorgReactivated` mapping.
- Empty/short/exact-chunk-boundary behavior — does the loop
  terminate cleanly in all three cases?
- `scannedAll` correctness across nested break and natural
  exhaustion.
- `total_scanned` counts chunk rows that were scanned but maybe
  skipped — does it overcount when production-cap break fires
  mid-chunk?
- `scan_ceiling_hit` exit path: do we still emit the gauge?
  Severity escalates to PAGE — correct?

Find code defects. Severity-headed findings. End with
`## Convergence X/X/X/X → DECISION`.
