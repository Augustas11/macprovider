You are auditing the COMPLETE SPEC-004 IMPL — all four BUILD-prompt
pillars (B + C + D + A) bundled into PR #263 — from an ARCHITECT
lens.

THIS IS THE FINAL PRE-MERGE AUDIT. Step back from per-pillar
specifics; review the bundled implementation as a coherent unit.

# Repository context

- Branch `feat/spec-004-pillar-b`, HEAD `34f459b`.
- 16 commits implementing all four BUILD-prompt pillars + audit-
  loop fix-passes + CI integration fix.
- SPEC-004 v0.3.1 LOCKED.

# Audit scope (ARCHITECT lens) — bundled-PR review

- **Scope discipline.** The PR is bundled (4 pillars + audit
  prompts + tests). Verify the diff is strictly within
  SPEC-004 scope; no scope creep into SPEC-005 quarantine work,
  SPEC-008 hash, SPEC-010 cold-supported-model, or SPEC-002
  routing baseline changes.
- **Routing package boundary.** `internal/routing/` and
  `internal/routing/sticky/` are the canonical homes. Verify
  no buyer-internal types leak in (eligibilityCtx is buyer-
  side; the interface boundary lives in routing). Verify no
  package-import cycle.
- **Phase-completion vs deferred work.** The PR explicitly
  defers: objective.go (sort comparator), dispatch.go
  (RewriteModel), retry.go (retry loop), sticky-package
  wiring through server.go, InvalidateClass SIGHUP trigger,
  per-attempt FR-SR-17 log threading. Verify the deferral
  list is correct (no item that SHOULD have landed in this
  PR is on the deferred list), AND that each deferred item
  is tracked in commit messages or file doc comments so the
  next session can resume.
- **API stability.** The new public symbols
  (routing.Candidate, Weights, EffectiveThroughput, Objective,
  ObjectiveDefault/Fast/Accurate/Balanced, WithinRelativeEpsilon,
  InEpsilonCohort, Excluded, NewExcluded, EligibilityChecker,
  RejectionReason, EligibleCandidates, FilterResult,
  RejectedProvider, Decision, CandidateLogEntry,
  LogRoutingDecision, ProviderToCandidateLogEntry,
  BalancedScores, sticky.Entry, sticky.Map, sticky.NewMap,
  sticky.Options, sticky.LookupResult) form the routing
  package's surface. Verify the API shape is forward-
  compatible (Phase D step 3 can extend without breaking
  callers).
- **Pre-existing inline implementations vs new extracted ones.**
  server.go still has inline copies of: sort comparator
  (sortCandidates), random tiebreak (applyRandomTiebreak),
  sticky lookup/store (stickyLookup/stickyStore/
  purgeStickyAccount), retry loop, dispatch rewrite
  (dispatchBodyForProvider). These remain the production
  implementation; the new routing package extractions are
  for class.go (BalancedScores formula extracted, wired) +
  log.go (Decision struct + LogRoutingDecision wired). Verify
  the extracted bits are byte-identical to the inline source
  (BalancedScores tests prove this for the formula; log.go's
  legacy aliases prove field-shape parity).
- **Bundling-PR strategy.** Per the memory rule
  [[feedback-bundle-multi-phase-impl-prs]], all four pillars
  bundled. Verify the PR remains comprehensible at this size
  (16 commits, ~1500+ added lines). Squash-merge collapses
  to one commit on origin/main.
- **Audit-trail coverage.** Three-lane per-pillar audit
  prompts + results live in specs/AUDIT_SPEC_004_PILLAR_*.md.
  Verify the audit trail is sufficient for a future
  reviewer to reconstruct the convergence path.
- **Composition with money path.** Pillar D's retry / log
  changes touch the money-path. Verify the changes are
  additive (no semantic change at defaults; no quarantine-
  surface touch; no retried-counter-sharing with F-4).
- **Risk surface for production deploy.** Every pillar ships
  default-OFF; production binaries deploy safely without
  operator config changes. Verify nothing was accidentally
  enabled by default.

# Severity vocabulary

- CRITICAL = the bundled PR's structure makes the next phase
  impossible / blocks production.
- HIGH = scope/sequencing concern that would force a follow-up
  rewrite.
- MEDIUM = precision improvement materially helping the next
  session's continuation work.
- LOW = wording or framing.

# Output format

```
Location: <file:line or symbol>
Concern: <what is wrong>
Evidence: <quote>
Fix: <one-sentence proposed change>
```

End with `Tally: C/H/M/L`. Goal: 0/0/0/0 ready for merge.

Read the BUILD prompt + every file in `internal/routing/` and
`internal/routing/sticky/` + the changed server.go sections +
relevant origin/main code. Do not speculate; cite quotes.
