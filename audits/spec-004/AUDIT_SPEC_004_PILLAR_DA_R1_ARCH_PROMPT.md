You are auditing the combined Phase D + Phase A IMPL slice of
SPEC-004 from an ARCHITECT lens.

# Repository context

- Branch `feat/spec-004-pillar-b`, HEAD `59f4184`. Recent commits:
  - `05cdd9a` Phase D log.go SPEC-004 §7
  - `c2d7e73` Phase D server.go log delegation + class.go
    BalancedScores
  - `59f4184` Phase A sticky package
- This audit reviews the structural shape of the new code +
  identifies the deferred work the next session needs to do.

# Audit scope (ARCHITECT lens)

- **Per-pillar BUILD-prompt scope coverage.**
  Phase D BUILD prompt names 5 NEW files (class.go, objective.go,
  dispatch.go, retry.go, log.go). This slice ships log.go + class.go;
  objective.go + dispatch.go + retry.go are DEFERRED. The existing
  server.go inline logic continues to work because the SPEC-004
  smart router was already partly built in pre-BUILD-prompt PRs.
  Verify the deferral list is correct (which extractions are
  truly deferred vs already-effectively-extracted-in-place).
- **Sticky package wiring deferred.** Phase A package exists with
  full primitive surface + tests, but server.go still uses its
  inline map[string]stickyEntry. Verify the deferral is safe —
  the new package is purely additive; nothing breaks until
  wiring lands.
- **Routing package surface cohesion.** Files now in routing/:
  candidate.go, epsilon.go, exclusion.go, filter.go, class.go,
  log.go, sticky/sticky.go. Verify they cohere — naming,
  dependencies, no circular references, no buyer-internal type
  leaks.
- **log.go Decision struct extensibility.** Decision has 24
  fields; some unused in current call sites (CandidateSet entries
  carry only objective_metric, missing per-attempt
  attempt_index/retry_count threading). Verify the shape can
  accept future additions without breaking call sites.
- **Sticky.Map API surface.** Lookup/Update/PurgeAccount/
  InvalidateClass/Len. Verify the signature
  Update(conversationKey, accountID, providerID, modelScope) is
  the right grain — Phase D may add a sixth field (e.g.,
  resolved-class for FR-SR-5 InvalidateClass scope check). The
  current InvalidateClass uses ModelScope as the class-match
  field, which is what Update stores. Verify this is consistent.
- **Deferred-work documentation.** Each deferred piece needs a
  pointer in commit messages / file doc comments so the next
  session can resume cold. Verify the audit commits AND the file
  docs make the deferral list explicit.
- **Two-pass eviction design.** sticky.Map.Update's TTL-pass-then-
  LRU-pass design is correct (avoids needless LRU when TTL
  expiry already freed space). Verify no edge case where the
  map can exceed cap (e.g., Update of an existing key vs new key
  at cap).
- **balancedScores buyer-adapter shape.** server.go's balancedScores
  helper takes []pool.Provider and returns map[string]float64
  keyed by routeKey. The new routing.BalancedScores returns an
  indexed slice. The buyer adapts to keyed map. Verify nothing
  in the buyer relies on the OLD inline norm() function being
  package-private.
- **No cross-pillar contamination.** Phase D + A changes should
  not affect Pillar B's scaffolding-only invariant (helpers
  exist, server.go uses them where appropriate) or Pillar C's
  filter + exclusion contract.

# Severity vocabulary

- CRITICAL = structural defect making the next session's wiring
  work impossible.
- HIGH = scope/sequencing ambiguity forcing rework in next
  session.
- MEDIUM = precision improvement materially helping the next
  session's deferred wiring.
- LOW = wording or framing.

# Output format

```
Location: <file:line or symbol>
Concern: <what is wrong>
Evidence: <quote>
Fix: <one-sentence proposed change>
```

End with `Tally: C/H/M/L`. Goal: 0/0/0/0. Any HIGH or MEDIUM
blocks merge.

Read the BUILD prompt §Phase D + §Phase A + the new routing files
+ their tests + the refactored server.go + relevant origin/main
code before writing any finding. Do not speculate; cite quotes.
