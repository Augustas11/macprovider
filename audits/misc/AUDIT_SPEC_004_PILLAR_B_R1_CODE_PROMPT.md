You are auditing the Phase B IMPL of SPEC-004 Pillar B (smart-router
weighting + deterministic tiebreak scaffolding) from a CODE lens.

# Repository context

- Branch `feat/spec-004-pillar-b` in `Augustas11/macprovider`, based
  on `origin/main` commit `e9ae2de` (SPEC-004 BUILD prompt landed in
  PR #260, closes #170).
- HEAD commit `fd4b08a`: 5 new files under
  `phase4-coordinator/internal/routing/` (candidate.go, candidate_test.go,
  epsilon.go, epsilon_test.go, spec004_regression_test.go).
- The Phase B BUILD prompt
  (`specs/BUILD_SPEC_004_PILLARS_BCDA_PROMPT.md` §Phase B) is the
  normative scope. Scope is intentionally narrow: NEW routing package
  with `Candidate`, `EffectiveThroughput`, `WithinRelativeEpsilon`,
  `InEpsilonCohort` helpers — NOT yet wired into
  `internal/buyer/server.go`'s selection path.
- SPEC-004 v0.3.1 is LOCKED (`specs/SPEC-004-smart-router.md`).
  SPEC-002 v1.5.2 + SPEC-005 v0.4 + SPEC-006 v0.9.1 on origin/main.

# Audit scope (CODE lens) — does this IMPL produce correct, deterministic, SPEC-compliant Phase B scaffolding?

For the NEW package (`phase4-coordinator/internal/routing/`):

- **SPEC compliance.** `EffectiveThroughput` MUST compute
  `throughput_tps_estimate * tier_weight` per SPEC-002 v1.1 §5
  Step 2.5 and SPEC-004 FR-SR-8 'fast' objective.
  `WithinRelativeEpsilon` MUST match SPEC-004 v0.2 §5 (relative
  fraction; epsilon=0 admits exact ties only). `InEpsilonCohort`
  MUST follow SPEC-004 FR-SR-16 per-objective rules:
  - default (utilization): `slots_free` equal to best AND throughput
    within epsilon;
  - fast: throughput within epsilon;
  - accurate: `model_params_b` within epsilon;
  - balanced: balanced score within epsilon (Phase B accepts caller-
    supplied score function).
- **Behavioral parity with `internal/buyer/server.go` inline copies.**
  The new helpers MUST be byte-identical in selection-relevant
  semantics to the existing `s.effectiveThroughput`,
  `withinRelativeEpsilon`, and `s.inEpsilonCohort` methods on
  `Server` (see `internal/buyer/server.go` lines 4664–4691, 4912–4918).
  Any divergence would block Phase C/D refactoring.
- **Tier handling.** `EffectiveThroughput` MUST apply the Pinned
  weight to any tier value other than `pool.TierProvisional`
  (matches origin/main's behavior where empty tier defaults to
  `pool.TierPinned` at provider construction in
  `internal/pool/provider.go:529`).
- **Float-arithmetic stability.** `WithinRelativeEpsilon`'s
  exact-tie short-circuit + epsilon<=0 guard + |top|=0 absolute
  fallback MUST be defensive against IEEE-754 quirks (e.g., 0.3
  weight imprecision when computing effective throughput).
- **Phase B isolation invariant.** `internal/buyer/server.go` MUST
  NOT import the new `internal/routing` package
  (per BUILD prompt §Phase B "NOT yet wired into the selection
  path"). The `spec004_regression_test.go` test pins this.
- **Test coverage.** Each helper SHOULD have direct tests for its
  contract (exact tie, epsilon boundary, tier-weight applied vs
  not, default-objective slots_free dependency, balanced-nil-score
  conservative default).
- **Naming + exports.** Public API (`Candidate`, `Weights`,
  `DefaultWeights`, `EffectiveThroughput`, `Objective`,
  `WithinRelativeEpsilon`, `InEpsilonCohort`, `ObjectiveDefault`,
  `ObjectiveFast`, `ObjectiveAccurate`, `ObjectiveBalanced`) is
  reasonable; nothing internal/* leaks.
- **Doc comments.** Each exported symbol carries a Go doc comment
  citing the SPEC source.

# Severity vocabulary

- **CRITICAL** = the IMPL would produce money-path-corrupting
  selection behavior or violate SPEC-002 default preservation.
- **HIGH** = an implementer or Phase C/D refactor consuming these
  helpers would arrive at the wrong selection result.
- **MEDIUM** = precision improvement materially affecting Phase
  C/D refactor or audit explainability.
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

Read the BUILD prompt §Phase B + the 5 new files in
`internal/routing/` + relevant origin/main code in `internal/buyer/`
+ `internal/pool/` before writing any finding. Do not speculate;
cite quotes.
