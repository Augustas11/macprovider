# SPEC-026 R7 — CODE audit lane

You are re-auditing SPEC-026 v0.7 after the R6 SCOPE-REDUCTION
pass. Read `SPEC-026-r{1,2,3,4,5,6}-audit.md` first. Do NOT
re-flag anything already fixed OR anything now moved out to
SPEC-027 / SPEC-028 / the SPEC-016 §3 addendum (each of those
carries its own audit backlog; findings against those surfaces
are out of scope for this review).

## Files in scope

- `specs/SPEC-026-browserless-provider-onboarding.md` (v0.7)
- `beta/DECISION_CRITERIA.md` Entry 102

## What to check in R7

Rank findings CRITICAL / HIGH / MEDIUM / LOW / INFO.

Focus areas after the split:

1. **§4.5, §5.1 enforcement, §9.3 pointer sections.** Verify
   each is a coherent forward-pointer to the follow-up spec
   (SPEC-027 or SPEC-028), does not leave dangling normative
   requirements that only make sense with the moved-out
   surface.
2. **§4.3 `provider_auth_policy` DDL and pseudocode.** No
   change from v0.6. Verify still correct against SPEC-001
   v1.6 §6.7.
3. **§4.1 `/register` DDL and pseudocode.** No change from
   v0.6. Verify against `phase4-coordinator/internal/auth/tokens.go`.
4. **§10 deploy checklist.** Trimmed to Phase 1a
   identity + auth-policy schemas. Verify that no orphaned
   step still references moved-out schemas.
5. **§12 acceptance criteria.** Verify AC-026-06 (was about
   wallet-swap notification) has either been moved to
   SPEC-027 or explicitly rescoped. AC-026-11 (App Attest
   replay), AC-026-13 (JCS parity), AC-026-14 (wallet balance
   demote) stay.
6. **Entry 102 accuracy against v0.7.** Verify.
7. **Change-log for v0.7.** Verify the change log accurately
   summarizes the split.
8. **Any residual references to moved-out primitives.** Grep
   for `notification_email`, `provider_email_change_requests`,
   `provider_wallet_swaps`, `provider_rewards_ledger`,
   `wallet_daily_malibu_emission`, `provider_emission_state`,
   `provider_payout_addresses_projection`, `malibu-app://`,
   `EmailChangeAuthorization` — each surviving mention should
   be a pointer to the follow-up SPEC or explicitly
   deferred.

## Output format

```
Severity: CRITICAL | HIGH | MEDIUM | LOW | INFO
Where: <file:line or spec §>
Claim: <one-line summary>
Evidence: <what you found>
Fix: <concrete change>
```

End:

```
TOTALS: C=<n> H=<n> M=<n> L=<n> I=<n>
```

Merge gate: **0 CRITICAL, 0 HIGH, 0 MEDIUM**.
