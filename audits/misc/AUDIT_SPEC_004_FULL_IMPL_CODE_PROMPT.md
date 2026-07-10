You are auditing the COMPLETE SPEC-004 IMPL — all four BUILD-prompt
pillars (B + C + D + A) bundled into PR #263 — from a CODE lens.

THIS IS THE FINAL PRE-MERGE AUDIT. Per-pillar audit-loops already
converged 0/0/0/0 × 3 lanes; this round verifies the IMPL is
internally coherent ACROSS pillar boundaries (no inter-pillar
regressions introduced as later phases landed, no contracts
weakened by later refactors, etc.).

# Repository context

- Branch `feat/spec-004-pillar-b` in `Augustas11/macprovider`,
  HEAD `34f459b` (CI integration regression fix on top of the
  bundled 4-pillar IMPL).
- Per-pillar audit-loop history: Pillar B converged R2, Pillar C
  converged R3, Pillar D+A converged R2.
- SPEC-004 v0.3.1 is LOCKED (`specs/SPEC-004-smart-router.md`).
  SPEC-002 v1.5.2, SPEC-005 v0.4, SPEC-006 v0.9.1 on origin/main.
- Driven by `specs/BUILD_SPEC_004_PILLARS_BCDA_PROMPT.md` (PR #260
  / commit `e9ae2de`, closes #170).

# Files added/changed in this PR (vs origin/main)

NEW package: `phase4-coordinator/internal/routing/`
- `candidate.go` — Candidate, Weights, EffectiveThroughput
- `epsilon.go` — Objective, WithinRelativeEpsilon, InEpsilonCohort
- `exclusion.go` — Excluded set
- `filter.go` — EligibilityChecker, EligibleCandidates, FilterResult
- `class.go` — BalancedScores (FR-SR-8 normative formula)
- `log.go` — Decision, CandidateLogEntry, LogRoutingDecision,
  ProviderToCandidateLogEntry

NEW subpackage: `phase4-coordinator/internal/routing/sticky/`
- `sticky.go` — Map (TTL+LRU+mutex), Lookup, Update, PurgeAccount,
  InvalidateClass, Len

CHANGED: `phase4-coordinator/internal/buyer/server.go`
- selectProviderExcluding refactored to filter→sort→tiebreak→preflight
  delegating to routing.EligibleCandidates
- eligibilityCtx adapter implementing routing.EligibilityChecker
- logRoutingDecision delegates to routing.LogRoutingDecision with
  Decision struct
- balancedScores delegates to routing.BalancedScores
- seedForRequest uses seedForRequestWithKey + defaultDailyKey (UTC)
- TestSPEC004DefaultConfigRegression alias for the byte-identity
  test

CHANGED: `phase4-coordinator/internal/buyer/server_test.go`
- TestSPEC004DefaultConfigRegression delegating wrapper

NEW: `phase4-coordinator/internal/buyer/seed_for_request_test.go`
- 4 daily-key reproducibility tests

# Audit scope (CODE lens) — holistic cross-pillar review

For the FULL implementation (not just one pillar):

- **Cross-pillar contract coherence.** Phase B's helpers
  (EffectiveThroughput, WithinRelativeEpsilon, InEpsilonCohort) are
  CALLED by Phase C's filter / sort path? Phase D's log? Phase A's
  sticky promotion logic? Verify the helpers' contracts hold under
  every caller's assumptions.
- **AC-SR-1 byte-identity preserved end-to-end.** With every
  SPEC-004 key at its default (sticky off, retries off, randomize
  off, no model classes), provider selection MUST be byte-identical
  to origin/main. TestDefaultConfigPreservesBaselineProviderSelection
  + its alias pass — verify no edge case the test doesn't cover
  could regress (e.g., a provider with empty tier, a zero-throughput
  candidate, a class entry that matches concrete model exactly).
- **Composition gate ordering FR-SR-18 enforced.** Filter →
  sort → tiebreak → preflight. Verify the refactored
  selectProviderExcluding cannot be re-ordered by accident
  (e.g., a future commit calling sort before filter). The
  EligibilityChecker boundary helps, but server.go's pipeline
  ordering is enforced only by code-review.
- **F-4 + retry exclusion threading FR-SR-19.** Excluded.Add /
  Has is the primitive; verify every code path that produces a
  fault adds to the SAME Excluded instance (no parallel exclusion
  sets).
- **Log strict-superset preservation.** Every pre-Phase-D log
  field (candidate_count, epsilon, seed, draw, reason,
  slots_free, slots_total, throughput_tps, metric) is still
  emitted. New SPEC-004 §7 fields added alongside. Verify NO
  field was dropped or renamed without a legacy alias.
- **Hostile-body invariant FR-SR-7a.** Duplicate / non-canonical
  case variants of `model` rejected BEFORE routing. Verify the
  rejection path lives at validateChatRequest entry (NOT only at
  dispatch time, which would be too late per SPEC FR-SR-7a).
- **request_log.retried write contract FR-SR-14.** Explicit
  X-MacProvider-Retry increments the column; F-4 one-shot
  failover does NOT. Verify the retry path doesn't accidentally
  share counter plumbing with F-4.
- **Sticky source authority FR-SR-2.** The X-MacProvider-
  Internal-Conv header MUST NEVER be accepted from direct buyer
  traffic — only from the gateway-authenticated internal path.
  Verify the buyer-side check still rejects direct-buyer
  internal-conv headers.
- **Sticky AccountID source authority.** Update calls in
  server.go MUST pass accountID from the gateway-authenticated
  X-MacProvider-Account header only. (The Update wiring is
  DEFERRED to a follow-up; the existing inline
  stickyStore in server.go still does this. Verify the
  inline implementation hasn't drifted.)
- **SPEC-005 v0.4 quarantine surface untouched.** No writes to
  ledger_quarantine_resolutions from any code path added by
  this PR. No force-void route changes. No
  billing_config_flag_changed audits.
- **Float-arithmetic stability under hostile inputs.**
  WithinRelativeEpsilon fails closed on NaN/±Inf. Verify no
  upstream caller accidentally feeds the helper raw provider
  values that could be Inf (e.g., a buggy heartbeat with Inf
  throughput).
- **Concurrency safety.** sticky.Map covers all six operations
  under one mutex (race-clean test). server.go's
  selectProviderExcluding doesn't share mutable state across
  goroutines that would race.
- **Test discipline.** AC-named tests where the BUILD prompt
  required them. FR-SR-7a body-assertion discipline still
  honored (existing test coverage).

# Severity vocabulary

- CRITICAL = money-path-corrupting bug in the final pre-merge
  state.
- HIGH = a bug an implementer reviewing this PR would catch
  but the pillar-loops missed.
- MEDIUM = precision improvement that would help future
  maintainers OR a documented-but-unimplemented contract.
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
`internal/routing/sticky/` + the changed sections of
`internal/buyer/server.go` (selectProviderExcluding,
eligibilityCtx, logRoutingDecision, balancedScores, seedForRequest)
+ relevant origin/main code. Do not speculate; cite quotes.
