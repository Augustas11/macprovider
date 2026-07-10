You are auditing the Phase C IMPL of SPEC-004 Pillar C from an
ARCHITECT lens.

# Repository context

- Branch `feat/spec-004-pillar-b` (bundled-PR mode), HEAD `761baaa`
  (Phase C step 2). Phase C extracted the candidate-filter loop
  out of buyer.Server's selectProviderExcluding into
  routing.EligibleCandidates + introduced eligibilityCtx adapter.

# Audit scope (ARCHITECT lens)

- **Interface shape.** EligibilityChecker has four methods
  (ProviderMatchesRequest, ProviderContextSufficient,
  Tier2Decision, QuotaPermits). Verify this is the right grain
  size — small enough that next-phase (D's class expansion, A's
  sticky read-back) can extend without breaking, large enough
  that the routing helper does meaningful work.
- **eligibilityCtx adapter.** Lives in buyer/server.go, binds
  per-request state. Verify the adapter pattern doesn't leak
  buyer-internal types into routing/, and the per-request closure
  semantics (each selectProviderExcluding call builds a fresh
  adapter) are correct.
- **FilterResult shape.** Eligible + Counts + HashMismatches +
  PreQuotaCount — verify each is necessary, none is
  underspecified, and the contract for "PreQuotaCount > 0 &&
  Counts[ReasonQuotaBlocked] == PreQuotaCount → 429" is
  internally consistent.
- **Excluded primitive forward-compatibility.** Phase D's retry
  loop will repeatedly Add() then re-run selectProviderExcluding.
  Verify the API (NewExcluded with capacity hint + Add/AddKey/
  Has/Len) supports this pattern; Len() is the FR-SR-14 per-
  request fault-cap counter Phase D wires.
- **Phase B → C composition.** Phase B helpers (Candidate,
  EffectiveThroughput, InEpsilonCohort) are still untouched by
  Phase C wiring — they remain available for Phase D to wire.
- **Phase-B-isolation guard retirement.** spec004_regression_test.go
  was deleted because Phase C intentionally wires server.go to
  routing. Verify AC-SR-1 byte-identity is still locked by the
  buyer-side alias (TestSPEC004DefaultConfigRegression delegating
  to TestDefaultConfigPreservesBaselineProviderSelection).
- **Scope cohesion.** Phase C should NOT touch: sort (Phase B-style
  ordering), sticky, random tiebreak, retry loop, dispatch
  rewrite, model classes. Verify the diff is strictly within the
  named scope (filter + exclusion extraction + error-envelope
  re-mapping).
- **Cross-phase ordering invariant.** B → C → D → A still
  enforceable. Phase C's filter helper is what Phase D's retry
  loop will repeatedly invoke; verify nothing in Phase C makes
  Phase D's wiring harder.

# Severity vocabulary

CRITICAL = structural defect making Phase D/A impossible.
HIGH = scope/sequencing ambiguity forcing rework.
MEDIUM = precision improvement materially helping later phases.
LOW = wording or framing.

# Output format

```
Location: <file:line or symbol>
Concern: <what is wrong>
Evidence: <quote>
Fix: <one-sentence proposed change>
```

End with `Tally: C/H/M/L`. Goal: 0/0/0/0. Any HIGH or MEDIUM blocks
merge.

Read the BUILD prompt §Phase C + 4 routing files + the refactored
server.go + relevant origin/main code before writing any finding.
Do not speculate; cite quotes.
