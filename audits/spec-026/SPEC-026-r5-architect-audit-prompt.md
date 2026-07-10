# SPEC-026 R5 — ARCHITECT audit lane

You are re-auditing SPEC-026 v0.5 after the R4 cleanup pass. Read
`SPEC-026-r{1,2,3,4}-audit.md` first. Do NOT re-flag anything
already fixed.

Your lens is ARCHITECT: cross-spec composition, layering, evolvability.

## Files in scope

- `specs/SPEC-026-browserless-provider-onboarding.md` (v0.5)
- `beta/DECISION_CRITERIA.md` Entry 102

## Adjacent SPECs

- SPEC-001 v1.6 §6.7
- SPEC-005 §11.4
- SPEC-015 §7.5, §12
- SPEC-016 §3
- SPEC-025 §3.4, §7

## What to check in R5

Rank findings CRITICAL / HIGH / MEDIUM / LOW / INFO.

1. **§4.6 SPEC-016 addendum requirement.** v0.5 says SPEC-016 §3
   MUST get an addendum defining `provider_wallet_swaps` state
   transitions. Verify:
   - SPEC-016 in the current tree does not already define these
     transitions (grep).
   - The addendum shape is coherent with SPEC-016's existing
     wallet-binding-history and hot-wallet-reconfirm semantics.
   - Is this really an addendum to SPEC-016, or a new SPEC?
2. **§9.3 EIP-712 email-change domain.** New EIP-712 use case
   (`EmailChangeAuthorization`). SPEC-016 already has an
   EIP-712 domain for wallet binding. Verify no naming
   collision.
3. **§4.5 deep-link URL scheme `malibu-app://`.** v0.4 §7.3
   said the `malibu://` scheme is retired. Introducing
   `malibu-app://` is a distinct scheme. Does that align with
   SPEC-025's URL-scheme registration guidance?
4. **§4.3 `provider_auth_policy` cross-track table.** Verify
   this is coordinator-owned and doesn't leak into
   phase3-binary state.
5. **§5.1 rewards ledger split (Postgres vs SQLite).** Verify
   the guidance doesn't create a two-DB consistency problem
   for readers who need to correlate rewards with billing
   ledger rows.
6. **§8.4 import flow atomicity.** Adds SPEC-025 §7
   equivalent. Should SPEC-025 §7 be updated to point at
   SPEC-026 §8.4, or is the duplication intentional?
7. **§10 Phase 1a / 1b split.** Any cross-spec ordering
   assumption v0.5 breaks?
8. **§9.3 three-path transfer** cross-spec compatibility.
   The "currently-bound-wallet EIP-712" path assumes
   SPEC-016 §3 wallet binding is already in place; if a
   provider has no bound wallet AND has an old email, only
   path 1 (old-email) works. Is that acceptable?
9. **§11 automated-defense stack after E3 excluded.** Argue:
   with E3 removed from the automated bound, is the residual
   sybil defense sufficient? (E1 100 receipts, E2 100 USDC
   time-weighted, provisional non-withdrawable, per-wallet
   cap.)
10. **Entry 102 v0.5 update.** Verify entry summary reflects
    v0.5 changes.

## Output format

```
Severity: CRITICAL | HIGH | MEDIUM | LOW | INFO
Where: <spec §>
Concern: <what breaks or drifts>
Blast radius: <who is affected>
Fix: <concrete change>
```

End:

```
TOTALS: C=<n> H=<n> M=<n> L=<n> I=<n>
```

Merge gate: **0 CRITICAL, 0 HIGH, 0 MEDIUM**.
