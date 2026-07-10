# SPEC-026 R7 — ARCHITECT audit lane

You are re-auditing SPEC-026 v0.7 after the R6 SCOPE-REDUCTION
pass. Read `SPEC-026-r{1,2,3,4,5,6}-audit.md` first. The R6
ARCH HIGH-2 explicitly said the v0.6 spec was too big; v0.7
splits it. Your primary job in R7 is to verify the split is
coherent.

## Files in scope

- `specs/SPEC-026-browserless-provider-onboarding.md` (v0.7)
- `beta/DECISION_CRITERIA.md` Entry 102

## What to check in R7

Rank findings CRITICAL / HIGH / MEDIUM / LOW / INFO.

1. **Split coherence.** Verify:
   - What SPEC-026 keeps is a well-scoped App-track onboarding
     + identity + register + auth-policy spec.
   - Each follow-up (SPEC-016 §3 addendum, SPEC-027, SPEC-028)
     is well-boundaried from SPEC-026 and from each other.
   - The forward-pointers in §4.5, §5.1, and §9.3 are
     sufficient to know what the follow-up needs to cover.
2. **Cross-spec ordering.** Verify:
   - SPEC-026 can merge without SPEC-027 or SPEC-028.
   - SPEC-026's §4.1 `/register` and §4.3 auth-policy ship
     usefully by themselves.
   - Where in the follow-up chain each moved-out surface
     lands.
3. **Deferred enforcement gaps.** Verify:
   - Provisional MALIBU non-withdrawability is not enforceable
     until SPEC-028 — is §5.1 clear about what the operational
     stance can be in the intervening period?
   - Wallet-swap coercion defense (App-track UI) is not
     enforceable until SPEC-027 — is §9.3 clear about what
     protection remains?
4. **SPEC-027 and SPEC-028 are named but not written.** Any
   normative statement in SPEC-026 v0.7 that will conflict
   with the natural design of those follow-ups?
5. **Entry 102** correctly captures v0.7 and the split. Verify.
6. **AC subset** for what remains in SPEC-026. Verify the
   AC-026-XX list doesn't reference wallet-swap notification
   flow that moved out.
7. **§10 deploy checklist** matches the new smaller scope.
8. **Overall design integrity.** Is v0.7 a coherent spec by
   itself, or does the reduction leave the reader confused
   about what SPEC-026 actually does?

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
