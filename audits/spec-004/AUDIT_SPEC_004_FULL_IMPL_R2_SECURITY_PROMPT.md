You are auditing the COMPLETE SPEC-004 IMPL — bundled PR #263 — from
a SECURITY lens. R2 of the FULL-IMPL audit fleet.

# Repository context

- Branch `feat/spec-004-pillar-b`, HEAD `15f6323`.
- R1 absorbed:
  - SEC-FULL-H: sticky refresh-at-cap in production → fixed by
    wiring server.go to sticky.Map.
  - adversarial-H3 / CODE-FULL-M1: NaN/Inf bypass on hot path →
    fixed by delegating inEpsilonCohort to routing.
  - adversarial-M5: AccountID overwrite on Update refresh →
    fixed by mismatch-refusal in Update.
  - adversarial-M7: PurgeAccount("") wipes → fixed at both buyer
    handler AND primitive.

# R2 audit scope (SECURITY lens)

Threat-model walkthrough at HEAD:

- **Sticky-key theft/forge.** A hostile buyer sends X-MacProvider-
  Internal-Conv on a direct-buyer request (no gateway auth-frame).
  Does the buyer-side check still reject this? Has anything in
  the routing/sticky package changed that lets a direct-buyer
  request reach sticky.Map.Update?
- **Cross-account sticky purge.** Verify both buyer handler AND
  sticky.Map.PurgeAccount("") guards trip. Verify PurgeAccount
  with a valid accountID purges ONLY that account's entries.
- **AccountID-mismatch refresh attempt.** A hostile buyer reuses
  another buyer's conversationKey with a different accountID.
  sticky.Map.Update now returns mismatch=true and refuses.
  Verify: (1) the existing entry's attribution is preserved
  byte-identically; (2) the mismatch log fires for ops visibility;
  (3) no other path lets the attacker bypass this (e.g., by
  triggering the insert path with the existing key first, which
  is impossible since Lookup is read-only).
- **Hot-path epsilon NaN/Inf guard.** Verify routing.WithinRelativeEpsilon
  fails closed on every non-finite input. Verify no code path
  uses an alternative epsilon helper that bypasses the guard.
- **BalancedScores money-path stability.** Verify the formula
  doesn't introduce NaN under hostile inputs (e.g., all-zero
  ThroughputTPSEstimate across the cohort — minMaxNorm returns
  1.0 per FR-SR-8 last paragraph, no divide-by-zero).
- **SPEC-005 v0.4 quarantine surface untouched.** Verify NO
  writes to ledger_quarantine_resolutions from any code path
  added in this PR. NO force-void route changes. NO
  billing_config_flag_changed audits.
- **Log-injection / leak.** New SPEC-004 §7 log emits x_request_id
  (buyer-untrusted) and requested_model (buyer-untrusted) and
  the new sticky_account_mismatch warn event (provider_id is
  server-derived, model_scope is config-derived — both trusted).
  Verify zerolog escapes correctly; no secret in any field.
- **DoS via mismatch-refusal log spam.** If an attacker repeatedly
  attempts cross-account refresh, the buyer logs a warn line per
  attempt. Could this drive log-disk exhaustion? Rate-limited
  upstream by the buyer endpoint's existing limits? Verify the
  attacker's gain (one log line per request that they already
  paid for via the buyer port) is bounded.
- **seedForRequest mid-request stability.** Adversarial R1
  flagged this as MEDIUM (deferred). For R2: confirm the
  deferred status is acceptable given default-OFF posture, OR
  call out that operators enabling Phase 2 are exposed.
- **filtered_counts side-channel.** §7 routing-decision log
  emits per-reason rejection counts. Verify this is operator-
  only (not shipped to buyers via headers/error messages).

# Severity vocabulary

CRITICAL = money-path security vulnerability; HIGH = vulnerability
likely to be opened by an implementer; MEDIUM = precision improvement
preventing unlikely misimplementation; LOW = wording.

# Output format

```
Location: <file:line or symbol>
Concern: <what is wrong>
Evidence: <quote>
Fix: <one-sentence proposed change>
```

End with `Tally: C/H/M/L`. Goal: **0/0/0/0 ready for merge**.

Read every file in `internal/routing/` and `internal/routing/sticky/`
+ the changed sections of `internal/buyer/server.go` + SPEC-004 +
SPEC-005 v0.4 + SPEC-006 v0.9.1 + relevant origin/main code. Cite
quotes.
