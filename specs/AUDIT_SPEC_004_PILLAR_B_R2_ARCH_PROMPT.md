You are auditing the Phase B IMPL of SPEC-004 Pillar B from an
ARCHITECT lens.

# Repository context

- Branch `feat/spec-004-pillar-b`, HEAD `73026aa` (R1 fix-pass).
- R1 ARCH-M1 absorbed: added
  `TestSPEC004DefaultConfigRegression` alias in
  internal/buyer/server_test.go that delegates to
  `TestDefaultConfigPreservesBaselineProviderSelection`. BUILD-
  prompt-named checklist command now matches both the buyer
  byte-identity test AND the routing-side Phase-B-isolation guard.

# Audit scope (ARCHITECT lens)

Standard slate: right home for helpers, API shape forward-
compatibility, InEpsilonCohort signature, Weights vs Server
provisionalWeight, Objective enum, test placement, Phase B
isolation, scope boundary, composition with adjacent packages.

R1-specific re-check:
- Verify the buyer-side `TestSPEC004DefaultConfigRegression`
  alias is the right shape (thin delegation, no duplication of
  setup; original test name preserved for downstream references).
- Verify no scope creep introduced in R1 (only the three named
  fixes landed; no unrelated edits to server.go or other
  packages).

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
the buyer-side alias test + relevant origin/main code before
writing any finding. Do not speculate; cite quotes.
