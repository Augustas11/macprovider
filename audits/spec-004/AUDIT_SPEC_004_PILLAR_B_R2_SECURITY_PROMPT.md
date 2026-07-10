You are auditing the Phase B IMPL of SPEC-004 Pillar B from a
SECURITY lens.

# Repository context

- Branch `feat/spec-004-pillar-b`, HEAD `73026aa` (R1 fix-pass).
- R1 SEC-M1 absorbed: `WithinRelativeEpsilon` now fails closed on
  NaN / ±Inf in any of top, candidate, epsilon. Regression test
  `TestWithinRelativeEpsilon_FailsClosedOnNonFinite` covers 10
  cases.

# Audit scope (SECURITY lens)

Standard slate: selection-result integrity, float-arithmetic edge
cases, tier-weight authority, Phase B isolation, caller-supplied
balanced score conservative handling, no new buyer-input paths.

R1-specific re-check:
- Verify the finite-value guard in `WithinRelativeEpsilon` is
  fully fail-closed AND short-circuits BEFORE any arithmetic that
  could panic / propagate non-finite values further.
- Verify no other helper (`EffectiveThroughput`, `InEpsilonCohort`)
  has an analogous non-finite admission risk (e.g., a candidate
  with +Inf ThroughputTPSEstimate passed through
  EffectiveThroughput then into WithinRelativeEpsilon — does the
  composition still fail-closed?).
- Verify the test coverage for fail-closed cases is exhaustive
  (top/candidate/epsilon × NaN/±Inf + composite cases).

# Severity vocabulary

CRITICAL / HIGH / MEDIUM / LOW per R1.

# Output format

```
Location: <file:line or symbol>
Concern: <what is wrong>
Evidence: <quote>
Fix: <one-sentence proposed change>
```

End with `Tally: C/H/M/L`. Goal: 0/0/0/0. Any HIGH or MEDIUM blocks
merge.

Read the BUILD prompt §Phase B + 5 files in `internal/routing/` +
relevant origin/main code before writing any finding. Do not
speculate; cite quotes.
