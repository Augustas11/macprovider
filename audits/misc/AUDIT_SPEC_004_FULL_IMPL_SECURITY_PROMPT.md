You are auditing the COMPLETE SPEC-004 IMPL — all four BUILD-prompt
pillars (B + C + D + A) bundled into PR #263 — from a SECURITY lens.

THIS IS THE FINAL PRE-MERGE AUDIT. Look for any security regression
that pillar-level audits could have missed when only seeing one
pillar at a time.

# Repository context

- Branch `feat/spec-004-pillar-b` in `Augustas11/macprovider`,
  HEAD `34f459b`.
- Per-pillar audit-loop history: B converged R2, C converged R3,
  D+A converged R2. CI fix landed at HEAD.
- SPEC-004 v0.3.1 LOCKED. SPEC-002 v1.5.2, SPEC-005 v0.4,
  SPEC-006 v0.9.1 on origin/main.
- Money-path codebase (provider billing, payouts, routing).

# Audit scope (SECURITY lens) — money-path threat model

For the full implementation, walk these threats end-to-end:

- **Sticky-key theft / forge.** A hostile buyer crafts an
  X-MacProvider-Internal-Conv: conv:<opaque> header on a direct-
  buyer request (no gateway auth-frame). Can it populate the
  sticky map? Can it cause a sticky hit on a subsequent request?
  Verify the buyer-side check (validateChatRequest +
  hasInternalRoutingHeader + internalBearerAuthorized) still
  rejects this; the sticky package itself trusts AccountID
  blindly.
- **Cross-account sticky purge.** PurgeAccount(accountID) is the
  primitive for SPEC-006 DELETE /v1/sticky. The handler MUST
  authenticate the caller's account_id before invoking. Verify
  origin/main's handleInternalStickyDelete still does that
  (Phase A primitive ships but server.go wiring is DEFERRED;
  meanwhile origin/main's inline purgeStickyAccount continues
  to be used).
- **Selection of breaker-held / state-ineligible provider.**
  routing.EligibleCandidates calls eligibilityCtx.
  ProviderMatchesRequest which combines model/class match +
  RoutingEligible() (SPEC-002 FR-P5 state check). Verify no
  path lets a NOT_READY / BREAKER_HELD / RECOVERING provider
  enter the result.
- **Quota-bypass via filter re-ordering.** Quota is the SECOND
  pass per SPEC-002 soft-filter contract. Verify no code path
  could let a quota-blocked provider into the eligible list
  if state/model/context checks passed.
- **Tier-2 hash-mismatch bypass.** Tier2Decision returns
  ReasonTier2HashMismatch / ReasonTier2HashRequired and the
  filter drops the provider. Verify NO path admits a
  hash-mismatched provider (e.g., if effectiveHashStatus
  returns OK but the verifier disagrees later).
- **FR-SR-17 reproducibility-but-unpredictable seed.**
  seedForRequest now uses request_id + UTC daily key. Verify
  the daily-key derivation doesn't leak across timezone
  changes / DST / clock skew (UTC isolates this) AND that the
  delimiter prevents (key+req) concat collision class.
- **Log-injection / leak.** The new SPEC-004 §7 fields include
  buyer-supplied x_request_id (untrusted) and requested_model
  (untrusted). Verify zerolog escapes these; verify no field
  exposes a secret (provider auth tokens, operator keys).
- **DoS via sticky map growth.** sticky.Map MaxEntries cap is
  the bound. Verify no path under concurrent buyer traffic can
  grow the map past MaxEntries (the test asserts
  maxObserved ≤ cap; verify the test conditions cover the
  real production load shape).
- **DoS via routing helper compute.** BalancedScores is O(N²)
  in the worst case? Actually O(N) per candidate × len(candidates)
  = O(N²). With N up to a few hundred providers, this is
  fine. Verify no quadratic-blowup path under realistic load.
- **Side-channel through filtered_counts log field.** The new
  log emits per-reason rejection counts. Could a hostile
  buyer infer pool composition by reading the routing-decision
  log? (The log is operator-only; this isn't a buyer side-
  channel. But verify the log isn't accidentally shipped to
  buyers via a header / error message.)
- **F-4 + retry exclusion bypass.** Two distinct admissions of
  the same peer have different routeKey (provider_id +
  assigned_id). Verify the Excluded set doesn't collapse them
  (which would let the SAME peer be retried under a different
  admission), OR if it intentionally distinguishes, verify
  that doesn't open a fault-cap bypass.
- **SPEC-005 v0.4 quarantine preservation.** No writes to
  ledger_quarantine_resolutions from any code path added in
  this PR. No force-void route changes. No
  billing_config_flag_changed audits.

# Severity vocabulary

- CRITICAL = money-path security vulnerability (sticky theft,
  retry budget bypass, double-emit, hash bypass, quota bypass).
- HIGH = vulnerability an implementer would likely open.
- MEDIUM = precision improvement preventing unlikely
  misimplementation.
- LOW = wording or framing.

# Output format

```
Location: <file:line or symbol>
Concern: <what is wrong>
Evidence: <quote>
Fix: <one-sentence proposed change>
```

End with `Tally: C/H/M/L`. Goal: 0/0/0/0 ready for merge.

Read every file in `internal/routing/` and `internal/routing/sticky/`
+ the changed sections of `internal/buyer/server.go` + SPEC-004 +
SPEC-005 v0.4 + SPEC-006 v0.9.1 + relevant origin/main code. Do
not speculate; cite quotes.
