You are auditing the Phase C IMPL of SPEC-004 Pillar C (breaker
composition + recovery gating: filter helper + exclusion set, with
server.go's selectProvider refactored to `filter → sort → tiebreak
→ preflight`) from a CODE lens.

# Repository context

- Branch `feat/spec-004-pillar-b` (intentionally bundling all four
  pillars per the user's 2026-06-30 decision; see PR #263 comment).
- HEAD commit `761baaa` (Phase C step 2: server.go refactor +
  Phase-B-guard retirement). Step 1 (`66bac41`) added the
  Excluded + EligibleCandidates primitives + 11 tests.
- Phase B + R1 fix-pass already landed; this is a bundled PR with
  per-pillar audit-loops layered on top.
- SPEC-004 v0.3.1 LOCKED. SPEC-002 v1.5.2, SPEC-005 v0.4,
  SPEC-006 v0.9.1 on origin/main.

# Phase C BUILD prompt scope

Per `specs/BUILD_SPEC_004_PILLARS_BCDA_PROMPT.md` §Phase C:
- NEW `internal/routing/filter.go` — `EligibleCandidates` returns
  candidate set AFTER all SPEC-002 composition gates
- NEW `internal/routing/exclusion.go` — `Excluded` set threading
  for F-4 + retry composition
- `internal/buyer/server.go` — `selectProvider` becomes
  `filter → sort → tiebreak → preflight`
- SPEC-004 rules implemented: FR-SR-18 (composition with FR-P5 +
  FR-P8a + FR-P11a — filter ORDER), FR-SR-19 (F-4 composition:
  same dead provider not selected twice)
- ACs: AC-SR-14 leg-2 (composition gates — filter helper + FR-P11a
  recovery-gating composition), FR-SR-18 + FR-SR-19 ordering
  assertions, breaker-held provider explicit-exclude regression

# Audit scope (CODE lens)

For the NEW + REFACTORED code:

- **Byte-identity preservation (AC-SR-1).** server.go's refactored
  `selectProviderExcluding` MUST produce byte-identical selection
  results under default config vs origin/main. Verify the order
  of checks in `eligibilityCtx` exactly matches the pre-Phase-C
  inline loop: excluded → match+state (combined per
  ProviderMatchesRequest) → context → tier2 (hash → encrypted →
  attestation) → quota (second pass). The buyer-side
  TestDefaultConfigPreservesBaselineProviderSelection /
  TestSPEC004DefaultConfigRegression covers this — verify no edge
  case slips.
- **Error-envelope mapping fidelity.** server.go now maps
  FilterResult.Counts to error envelopes in this order: 429 (quota
  if PreQuotaCount > 0 && ReasonQuotaBlocked == PreQuotaCount) →
  413 context → 503 hash_verified_required → 503 hash_mismatch →
  503 encrypted_leg_required → 503 attestation_required → 503
  no_provider_available. The pre-Phase-C version had quota AFTER
  the 503 family; the new order is provably equivalent (see
  commit message) but verify there is no input that produces a
  different envelope.
- **Excluded set semantics.** routing.Excluded uses a keyer
  callback to derive the dedup key, with zero-value safety
  (nil-map Add/Has/Len are no-ops). Verify the conversion from
  the old `map[string]struct{} keyed by routeKey(p)` is exact —
  same keys, same membership.
- **Logging side effects.** tier2.LogHashRequiredProviderExcluded
  and tier2.LogEncryptedLegRequiredMissing MUST fire from the
  same condition branches as pre-Phase-C (now inside
  eligibilityCtx.Tier2Decision). Verify the log emission isn't
  duplicated or dropped.
- **Quota second-pass semantics.** Quota was a separate loop in
  pre-Phase-C; now it's the second pass inside EligibleCandidates.
  Verify the new contract — Eligible == 0 && PreQuotaCount > 0 &&
  Counts[ReasonQuotaBlocked] == PreQuotaCount → 429 — is exactly
  equivalent to pre-Phase-C `quotaBlocked == len(preQuotaCandidates)`.
- **FR-SR-18 ordering test.** Phase C BUILD prompt says
  "FR-SR-18 + FR-SR-19 ordering assertions, breaker-held provider
  explicit-exclude regression". The new filter_test.go covers
  composition order via stubChecker; verify the test coverage is
  sufficient to prove ordering.
- **FR-SR-19 F-4 + retry exclusion.** Excluded set is the
  primitive Phase D's retry loop will use; Phase C should
  demonstrate it is correctly threaded through
  selectProviderExcluding (the existing `excluded map` parameter
  is converted to routing.Excluded). Verify nothing relies on the
  old map[string]struct{} shape elsewhere.
- **Test placement.** routing tests in `package routing_test`;
  buyer tests in `package buyer`. Verify the package boundary is
  correct.
- **Doc comments.** All new exported symbols (Excluded, NewExcluded,
  EligibleCandidates, RejectionReason, ReasonExcluded etc.,
  EligibilityChecker, RejectedProvider, FilterResult, PreQuotaCount)
  carry SPEC-citing doc comments.

# Severity vocabulary

- CRITICAL = money-path-corrupting selection or composition gate
  violation.
- HIGH = implementer / next-phase wiring would arrive at wrong
  selection result.
- MEDIUM = precision improvement materially affecting Phase D/A or
  audit explainability.
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

Read the BUILD prompt §Phase C + 4 routing files (candidate.go,
epsilon.go, exclusion.go, filter.go + their tests) + the refactored
selectProviderExcluding in internal/buyer/server.go + relevant
origin/main code before writing any finding. Do not speculate;
cite quotes.
