You are auditing a COMBINED Phase D + Phase A IMPL slice of SPEC-004
from a CODE lens. Phase D and Phase A primitives were both extracted
into internal/routing/ in the most recent commits.

# Repository context

- Branch `feat/spec-004-pillar-b` (bundled-PR mode), HEAD `59f4184`
  (Phase A sticky package). Recent commits in scope of this audit:
  - `05cdd9a` Phase D step 1: internal/routing/log.go SPEC-004 §7
    Decision struct + LogRoutingDecision + 5 tests
  - `c2d7e73` Phase D step 2: server.go logRoutingDecision delegates
    to routing pkg; routing.BalancedScores extracted + 5 tests
  - `59f4184` Phase A: internal/routing/sticky/ package with Map,
    Lookup, Update, PurgeAccount, InvalidateClass, Len + 10 tests
    (-race-clean)
- SPEC-004 v0.3.1 LOCKED. SPEC-002 v1.5.2, SPEC-005 v0.4,
  SPEC-006 v0.9.1 on origin/main.

# Phase D scope (per BUILD prompt §Phase D)

NEW files in routing pkg per the prompt: class.go (alias resolution
+ balanced score formula), objective.go (fast/accurate/balanced
sort comparator), dispatch.go (RewriteModel at every dispatch),
retry.go (retry loop with budget + exclusion + buyer-cancel
attribution), log.go (LogRoutingDecision with SPEC-004 §7 fields).

This audit's IMPL lands:
- ✅ log.go with full SPEC-004 §7 24-field Decision shape
- ✅ class.go BalancedScores normative formula + minMaxNorm
- ✅ server.go logRoutingDecision delegation
- ❌ objective.go (sort comparator) — DEFERRED, still inline in
  server.go::sortCandidates
- ❌ dispatch.go (RewriteModel) — DEFERRED, still inline in
  server.go::dispatchBodyForProvider (which IS already at every
  dispatch path per existing F-4 unified-loop helpers)
- ❌ retry.go (retry loop extraction) — DEFERRED, still inline in
  server.go forwardStreamSequence / forwardWSNonStreamSequence /
  forwardHTTPSequence

# Phase A scope (per BUILD prompt §Phase A)

NEW internal/routing/sticky/ package per the prompt:
- Map with TTL + LRU + mutex, bounded by MaxEntries (security/DoS
  boundary)
- Lookup(conversationKey)
- Update(conversationKey, accountID, providerID, modelScope)
- InvalidateClass(className) — primitive; SIGHUP wiring DEFERRED
- PurgeAccount(accountID) — SPEC-006 DELETE /v1/sticky primitive

This audit's IMPL lands the full sticky package + 10 race-clean
tests. server.go wiring (delegation from buyer.stickyEntry to
sticky.Map) is DEFERRED to a follow-up commit; the buyer still
uses its inline map[string]stickyEntry.

# Audit scope (CODE lens)

For the NEW code:

- **log.go SPEC-004 §7 field completeness.** Decision struct has
  every field SPEC-004 §7 names. LogRoutingDecision conditional
  omission ('Required fields where applicable') is correct.
  random_seed / random_draw guarded by TiebreakMode == 'random_epsilon'.
- **server.go logRoutingDecision delegation.** Wiring preserves
  the existing log shape (no field renames, no field drops) AND
  translates 'deterministic'/'randomized' reason strings to
  SPEC-004 §7 tiebreak_mode vocabulary verbatim.
- **BalancedScores normative formula.** The 0.4/0.3/0.2/0.1
  weight constants match SPEC-004 FR-SR-8 exactly. min-max norm
  fallback (all-identical → 1.0) matches FR-SR-8 last paragraph.
  SlotsTotal=0 division guard present.
- **sticky.Map Lookup/Update/PurgeAccount/InvalidateClass.** Mutex
  covers all five FR-SR-5 paragraph 2 operations. Bounded-map
  eviction at MaxEntries is two-pass (TTL drop then LRU evict).
  CreatedAt preserved on refresh per FR-SR-6.
- **Sticky AccountID source authority documentation.** Package
  doc explicitly says accountID MUST come from gateway-
  authenticated X-MacProvider-Account header; buyer-side caller
  is responsible for verifying. The package itself treats it as
  opaque.
- **Sticky package test coverage.** 10 race-clean tests cover:
  not-found / hit / TTL expiry / LRU refresh / bounded-map LRU
  evict / TTL-before-LRU two-pass / PurgeAccount account scope /
  PurgeAccount unknown / InvalidateClass scope / concurrent
  mixed ops (32 goroutines × 200 ops) / CreatedAt preserve.
- **Deferred work documentation.** Each deferred piece (objective
  comparator, dispatch RewriteModel, retry loop, sticky wiring,
  InvalidateClass SIGHUP trigger) is noted in commit messages
  AND/OR file doc comments so the next session can resume.
- **Byte-identity preservation.** server.go's
  TestDefaultConfigPreservesBaselineProviderSelection passes
  post-refactor (verified: full coordinator 19-package suite
  green).

# Severity vocabulary

- CRITICAL = money-path-corrupting selection or sticky storage
  corruption.
- HIGH = implementer / next-phase wiring would arrive at wrong
  result (e.g., missing §7 field, wrong eviction order, mutex
  gap).
- MEDIUM = precision improvement materially affecting next
  session.
- LOW = wording or framing.

# Output format

```
Location: <file:line or symbol>
Concern: <what is wrong>
Evidence: <quote>
Fix: <one-sentence proposed change>
```

End with `Tally: C/H/M/L`. Goal: 0/0/0/0. Any HIGH or MEDIUM blocks
merge.

Read the BUILD prompt §Phase D + §Phase A + the new routing files
(class.go, log.go, sticky/sticky.go) + their tests + the
refactored server.go::logRoutingDecision + relevant origin/main
code before writing any finding. Do not speculate; cite quotes.
