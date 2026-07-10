You are auditing the COMPLETE SPEC-004 IMPL — bundled PR #263 — from
a CODE lens. This is R2 of the FULL-IMPL audit fleet. R1 lanes found
2 HIGH + 4 MEDIUM total (some shared between lanes); all have been
absorbed. Goal: 0 CRITICAL / HIGH / MEDIUM.

# Repository context

- Branch `feat/spec-004-pillar-b`, HEAD `15f6323` (pre-R2 fix-pass).
- R1 absorbed via two commits:
  - `cf35879` FULL-IMPL fix-pass: sticky.Map wiring, epsilon
    delegation, §7 log threading, purgeStickyAccount("") guard.
  - `15f6323` pre-R2 fix-pass: AccountID-mismatch refusal on
    Update refresh, defense-in-depth PurgeAccount("") in primitive,
    audit-result artifact files.
- SPEC-004 v0.3.1 LOCKED. SPEC-002 v1.5.2, SPEC-005 v0.4,
  SPEC-006 v0.9.1 on origin/main.

# R1 absorbed findings to verify

- CODE-FULL-M1: server.go local `withinRelativeEpsilon` NaN/Inf
  bypass → DELETED inline; `inEpsilonCohort` now delegates to
  `routing.InEpsilonCohort` (epsilon.go:50-53 guard now on hot
  path).
- CODE-FULL-M2: SPEC-004 §7 log was half-empty → new
  `logRoutingDecisionFull` helper + `routeKeyedFilterCounts`
  adapter; main selectProviderExcluding call site threads
  `len(providers)` + `result.Counts`.
- adversarial-H1+H2 / SEC-FULL-H: sticky.Map dead code → server.go
  now uses `*sticky.Map` field; stickyLookup/stickyStore/
  purgeStickyAccount delegate to sticky.Map methods. Refresh-at-cap
  bug fixed in production by the wiring.
- adversarial-M5: sticky.Map.Update silent AccountID overwrite →
  Update now returns mismatch bool + refuses refresh when
  AccountID differs. server.go logs `sticky_account_mismatch`.
- adversarial-M7: purgeStickyAccount("") wipes empty-AccountID
  entries → server.go guard + primitive-level guard added.

# Audit scope (CODE lens) — R2 verification

For the HEAD state:

- **Verify sticky.Map wiring is correct end-to-end.** server.go's
  stickyLookup, stickyStore, purgeStickyAccount delegate cleanly.
  NewServer initializes sticky.Map post-options with configured
  TTL/MaxEntries/now. Any path that bypasses the Map (e.g.,
  direct access to a leftover stickyEntry type or stickyMu field)
  is a regression.
- **Verify inEpsilonCohort delegation is correct.** server.go
  inEpsilonCohort builds the routing.Objective + Weights +
  optional balancedScoreFn closure correctly. The `default`/`fast`/
  `accurate`/`balanced` dispatch produces the same results as the
  pre-refactor inline switch under every objective.
- **Verify logRoutingDecisionFull threading.** The main call site
  passes `len(providers)` (the FULL pool snapshot, not the
  post-filter slice) AND `routeKeyedFilterCounts(result.Counts)`.
  Sticky-path and retry-path callers continue to use
  logRoutingDecision (which delegates with 0/nil for the new
  fields). Verify `routeKeyedFilterCounts` covers every
  routing.RejectionReason variant (Excluded, ModelMismatch,
  ContextTooSmall, Tier2HashMismatch, Tier2HashRequired,
  Tier2EncryptedLeg, Tier2Attestation, QuotaBlocked) with
  SPEC-004 §7-compatible string keys.
- **Verify AccountID-mismatch guard semantics.** Update returns
  mismatch=true ONLY when BOTH sides non-empty AND differ. Both-
  empty / one-side-empty cases are allowed (legacy upgrade or
  default install).
- **Verify primitive-level PurgeAccount("") guard.** Returns 0
  without taking the mutex or iterating.
- **Float-arithmetic post-fix.** Verify no other call site
  produces NaN/±Inf into sort comparators or score formulas
  (BalancedScores has SlotsTotal=0 guard but
  ThroughputTPSEstimate could still be ±Inf from a buggy
  heartbeat — does it propagate into the comparator order?).
- **Test coverage for the new guards.** TestMap_UpdateRejectsAccountIDMismatchOnRefresh,
  TestMap_UpdateAllowsRefreshWhenExistingAccountIDIsEmpty,
  TestMap_PurgeAccountEmptyAccountReturnsZero are the three new
  guards; verify they exercise the right contracts.

# Severity vocabulary

CRITICAL = money-path bug; HIGH = implementer-likely-misimplement;
MEDIUM = precision improvement materially helping production safety
or maintainer cognition; LOW = wording.

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
`internal/buyer/server.go` (selectProviderExcluding, eligibilityCtx,
logRoutingDecisionFull, logRoutingDecision, inEpsilonCohort,
stickyLookup, stickyStore, purgeStickyAccount, seedForRequest) +
the audit-result artifact files in specs/SPEC-004-* + relevant
origin/main code. Do not speculate; cite quotes.
