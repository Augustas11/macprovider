You are auditing the COMPLETE SPEC-004 IMPL — bundled PR #263 — from
a CODE lens. R3 of the FULL-IMPL audit fleet.

# Repository context

- Branch `feat/spec-004-pillar-b`, HEAD `5b40e6a` (R2 fix-pass).
- R2 absorbed:
  - CODE-R2-M1: `sticky.Map.Update` now preserves existing
    AccountID when incoming accountID is empty (was: erased it).
  - CODE-R2-L1: `candidate.go` package doc rewritten to past
    tense for landed Phase D/A work + explicit deferred list.

# R3 audit scope (CODE lens) — verify R2 absorption + final pass

For the HEAD state:

- **Verify the empty-incoming AccountID preservation.** Confirm
  the guard:
  - Refuses cross-account refresh (both non-empty + differ → mismatch=true).
  - Allows AccountID upgrade (existing empty + incoming non-empty → write incoming).
  - Preserves existing AccountID when incoming is empty (existing non-empty + incoming empty → keep existing).
  - Allows both-empty (existing empty + incoming empty → write empty, no-op effectively).
  Regression tests `TestMap_UpdateRejectsAccountIDMismatchOnRefresh`,
  `TestMap_UpdateAllowsRefreshWhenExistingAccountIDIsEmpty`,
  `TestMap_UpdatePreservesExistingAccountIDWhenIncomingIsEmpty`
  exhaust the matrix.
- **Verify candidate.go package doc accuracy.** Names every landed
  component (Phase B/C/D/A) in past tense; lists genuinely-deferred
  items separately. No "future" claims about already-landed code.
- **Last sweep.** With the user's "0 C/H/M after R3" bar in mind,
  scan for any C/H/M that previous rounds missed because this is
  the final pre-merge gate.

# Severity vocabulary

CRITICAL / HIGH / MEDIUM / LOW per R1/R2.

# Output format

```
Location: <file:line or symbol>
Concern: <what is wrong>
Evidence: <quote>
Fix: <one-sentence proposed change>
```

End with `Tally: C/H/M/L`. Goal: **0/0/0/0 ready for merge**.

Read the BUILD prompt + every file in `internal/routing/` and
`internal/routing/sticky/` + the changed sections of
`internal/buyer/server.go` + the audit-result artifact files +
relevant origin/main code. Cite quotes.
