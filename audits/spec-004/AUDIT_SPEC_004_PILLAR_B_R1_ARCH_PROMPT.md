You are auditing the Phase B IMPL of SPEC-004 Pillar B (smart-router
weighting + deterministic tiebreak scaffolding) from an ARCHITECT
lens.

# Repository context

- Branch `feat/spec-004-pillar-b`, HEAD `fd4b08a`, based on
  `origin/main` `e9ae2de`.
- Phase B is the FIRST of four pillar PRs (B → C → D → A) driven by
  `specs/BUILD_SPEC_004_PILLARS_BCDA_PROMPT.md`. Phase B is
  intentionally scaffolding-only: the new `internal/routing/`
  package exists but is NOT yet wired; Phase C/D refactor server.go
  to delegate.

# Audit scope (ARCHITECT lens)

- **Right home for the helpers.** `internal/routing/` (package
  `routing`) is the home BUILD prompt names. Verify nothing about
  the structure forces an awkward Phase C/D refactor (e.g.,
  helpers don't take pointers to Server, don't depend on
  buyer-only types, don't import buyer back).
- **API shape forward-compatibility.** The `Candidate` struct
  intentionally minimal (Provider only). Phase C will add
  eligibility state; Phase D will add score caches. Verify the
  current shape allows those additions without breaking the
  `routing` package boundary.
- **`InEpsilonCohort` signature.** Takes `balancedScore func(...)`
  rather than a `map[string]float64` of pre-computed scores.
  Verify this choice composes cleanly with Phase D's score-formula
  wiring (function is more flexible for caching strategies; map
  is rigid).
- **`Weights` struct vs Server's `provisionalWeight` field.** The
  package decouples weight-from-config — Phase C/D will need to
  thread the operator-configured provisional weight through.
  Verify the decoupling is correct (no implicit DefaultWeights()
  fallback that could mask config misconfiguration when Phase C/D
  wires production).
- **Objective enum.** String-typed `Objective` matches existing
  server.go string usage. Verify no drift (server.go uses lowercase
  strings; package uses same).
- **Test placement.** Tests in `package routing_test` (external)
  vs `package routing` — verify the test package boundary forces
  the public-API contract.
- **Phase B isolation invariant test
  (`spec004_regression_test.go`).** Verify the test correctly
  asserts what BUILD prompt's Pillar-completion checklist requires
  (named `TestSPEC004DefaultConfigRegression`, fails loudly on
  premature wiring).
- **Scope boundary.** Phase B explicitly does NOT add: random
  selection, sticky map, model classes, retry loop, dispatch
  rewrite. Verify the PR's diff is strictly within the named scope
  (no scope creep beyond the helpers + tests).
- **Composition with adjacent packages.** New package imports
  `internal/pool` only. Verify no upward import (e.g., to
  `internal/buyer`) creates a future cycle.

# Severity vocabulary

- **CRITICAL** = structural defect making Phase C/D refactor
  impossible.
- **HIGH** = scope/sequencing ambiguity forcing mid-Phase-C rewrite.
- **MEDIUM** = precision improvement that materially helps later
  phases.
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
+ relevant origin/main code before writing any finding. Do not
speculate; cite quotes.
