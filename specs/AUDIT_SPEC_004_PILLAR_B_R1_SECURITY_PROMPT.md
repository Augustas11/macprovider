You are auditing the Phase B IMPL of SPEC-004 Pillar B (smart-router
weighting + deterministic tiebreak scaffolding) from a SECURITY lens.

# Repository context

- Branch `feat/spec-004-pillar-b`, HEAD `fd4b08a`, based on
  `origin/main` `e9ae2de`.
- Phase B scope: NEW `internal/routing/` package with
  `EffectiveThroughput`, `WithinRelativeEpsilon`, `InEpsilonCohort`
  helpers; NOT yet wired into `internal/buyer/server.go` selection
  path.
- This is a money-path codebase. Selection-influencing helpers in
  the wrong shape directly affect provider payouts.

# Audit scope (SECURITY lens)

- **Selection-result integrity.** With default config
  (`tiebreak_epsilon=0`, `tiebreak_randomize=false`), the new
  helpers MUST be exact-tie-only AND MUST NOT inadvertently widen
  the cohort vs the existing server.go inline copies. A widened
  cohort would let a non-deterministic / unintended provider be
  selected.
- **Float-arithmetic edge cases.** `WithinRelativeEpsilon`'s |top|=0
  fallback MUST NOT admit unbounded candidates (e.g., when both
  top and candidate are 0, exact-tie branch handles it; when top=0
  and candidate is small, |candidate| <= epsilon — bounded). Verify
  no NaN/Inf paths slip through.
- **Tier-weight authority.** `EffectiveThroughput` MUST default to
  Pinned for any tier other than `pool.TierProvisional` — a
  hostile/unknown tier value must NOT inadvertently silently get a
  high or zero weight that boosts/suppresses it in selection.
- **Phase B isolation.** The scaffolding-only invariant
  (`server.go` does NOT import `internal/routing`) means Phase B
  ships ZERO selection-behavior change. Any code path that
  inadvertently makes routing affect selection is a HIGH/CRITICAL
  finding.
- **Caller-supplied balanced score.** `InEpsilonCohort`'s
  `balancedScore func(pool.Provider) float64` parameter MUST be
  conservatively handled when nil (return false) so a Phase D
  wiring bug doesn't silently default to "everything in cohort".
- **No new buyer-input paths.** Phase B introduces no new buyer
  headers / body fields / config keys. Verify no test or comment
  hints otherwise.

# Severity vocabulary

- **CRITICAL** = money-path security vulnerability (e.g., a buyer
  can game selection via a side-effect of the new helpers).
- **HIGH** = a vulnerability an implementer (Phase C/D refactor)
  would likely open by consuming these helpers.
- **MEDIUM** = precision improvement preventing unlikely-but-
  possible misimplementation.
- **LOW** = wording or framing.

# Output format

For each finding:

```
Location: <file:line or symbol>
Concern: <what is wrong>
Evidence: <quote>
Fix: <one-sentence proposed change>
```

End with `Tally: C/H/M/L`. Goal: 0/0/0/0. Any HIGH or MEDIUM blocks
merge.

Read the BUILD prompt §Phase B + 5 new files in `internal/routing/`
+ relevant origin/main `internal/buyer/server.go` and
`internal/pool/provider.go` before writing any finding. Do not
speculate; cite quotes.
