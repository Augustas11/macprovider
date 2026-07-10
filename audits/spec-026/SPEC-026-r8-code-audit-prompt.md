# SPEC-026 R8 — CODE audit lane

You are re-auditing SPEC-026 v0.8 after the R7 cleanup. Read
`SPEC-026-r{1,2,3,4,5,6,7}-audit.md` first. Do NOT re-flag
anything already fixed OR anything moved to SPEC-027 / SPEC-028 /
SPEC-016 §3 addendum.

## Files in scope

- `specs/SPEC-026-browserless-provider-onboarding.md` (v0.8)
- `beta/DECISION_CRITERIA.md` Entry 102

## Focus for R8

1. **§4.1 rotate-on-duplicate uses bearer-based proof.** Verify
   the two-path proof mechanism (Authorization header OR body
   field) is clean; hashing + compare against `token_hash` is
   implementable.
2. **§4.1 SQLite `BEGIN IMMEDIATE` transaction lock.** Verify
   coordinator's SQLite version supports partial unique index
   syntax and BEGIN IMMEDIATE semantics used here.
3. **§4.3 JSON example `"version": 2`.** Verify int type.
4. **AC-026-06 rescoped.** Verify no dangling references to
   `notification_email` etc.
5. **§7.3 `malibu-app://` block deleted.** Verify grep for
   `malibu-app://` returns only Entry-102 pointer and
   change-log mentions.
6. **§6.2 pending-swap UI defer.** Verify no residual
   contradiction with §9.3.
7. **§10 step 8 MALIBU gate.** Verify wording is enforceable
   as a deploy check.
8. **AC-026-15 (§8.4 import dialog).** Verify shape matches
   §8.4 prose.
9. **Entry 102.** Verify accuracy against v0.8.
10. **Residual references sweep.** Grep for
    `notification_email`, `provider_email_change_requests`,
    `EmailChangeAuthorization`, `provider_wallet_swaps`,
    `wallet_daily_malibu_emission`, `withdrawal_hold_reason`,
    `provider_emission_state`. Each surviving mention should
    be a pointer or change-log entry.

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
