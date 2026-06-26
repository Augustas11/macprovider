CLOSURE on round-1 findings:
  M1: PASS — `buyerEquivalentCredits` now carries raw `tsText` through the first pass and skips 503 rows before `time.Parse`, while non-503 malformed timestamps still return a hard error.

NEW FINDINGS (round 2):
CRITICAL (0):
  (none)

HIGH (0):
  (none)

MEDIUM (0):
  (none)

LOW (0):
  (none)

QUESTIONS (0):
  (none)

Validation:
  - Reviewed `git diff origin/main -- phase4-coordinator/`.
  - Spot-checked `buyerEquivalentCredits`, `rebuildLegacyConfigSnapshots`, providers handler, and `RecoverLedger` / `snapshotAtTx` for r1->r2 drift.
  - Ran `go test ./internal/billing ./internal/requestlog` from `phase4-coordinator`: PASS.

VERDICT: READY TO MERGE arc-3 nested-query unwind
