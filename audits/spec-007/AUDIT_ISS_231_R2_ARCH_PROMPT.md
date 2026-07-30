# Audit: ISS-231 R2 architect lens — verify R1 fixes

R1 returned 0/0/3/2 (arch). R2 verifies on `0d96a03`.

## R1 arch findings to verify

- **MEDIUM-1**: SPEC-007 lacks central event authority. Deferred
  with explicit note in v0.4 change-log (filed as follow-up — not
  blocking this PR).
- **MEDIUM-2**: v0.5 break not owned. Fix: filed issue #245 with
  concrete trigger conditions; SPEC §6.4 + §5.6 link to it.
- **MEDIUM-3**: near-cap 409 not auditable. Deferred per change-log
  note (revisit at v0.5).
- **LOW-1**: omitempty drift. Fix: dropped.
- **LOW-2**: cap=10 authority. Fix: SPEC explicitly says
  "security invariant, not an operator-tunable knob".

## What I want (R2 arch lens)

- v0.5 break issue #245 — actionable trigger conditions present?
- SPEC v0.4 change-log entry honest about R1 deferrals
  (centralized event table + channel asymmetry + near-cap audit)?
- The new `forensic_cap=100` magic number — should it ALSO be
  documented as security invariant alongside cap=10?
- `MatchedAccountIDsUntrimmed` field name — does it still match the
  new bounded-forensic shape, or should it be renamed
  `MatchedAccountIDsForensicSample` to reflect that it's now a
  bounded sample, not a "full" untrimmed list?

End with `## Convergence X/X/X/X → DECISION`.
