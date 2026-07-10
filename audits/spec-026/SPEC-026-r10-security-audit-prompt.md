# SPEC-026 R10 — SECURITY audit lane

You are re-auditing SPEC-026 v0.10 after the R9 targeted
wording pass. Read `SPEC-026-r{1..9}-audit.md` first. Do NOT
re-flag anything already fixed OR moved to SPEC-027 /
SPEC-028 / the SPEC-016 §3 addendum.

## Files in scope

- `specs/SPEC-026-browserless-provider-onboarding.md` (v0.10)
- `beta/DECISION_CRITERIA.md` Entry 102

## Focus for R10

Only the surfaces v0.10 touched:

1. **Entry 102 email-active wording purged.** Verify no
   remaining "REQUIRED out-of-band email channel" or "Wallet
   swap MUST fail closed on unverified email" or "HMAC-signed
   via LoadCredential" wording exists in Entry 102 as active
   claims. Every mention of those primitives should be a
   SPEC-027-will-own pointer.
2. **Entry 102 9-step deploy checklist enumeration.** Verify
   the summary now enumerates step 8 explicitly.
3. **§6.2 and §9.3 MUST NOT wording identical.** Verify both
   sections use the same normative sentence forbidding a
   Cancel affordance before SPEC-027 ships.
4. **Any subtle interaction** between v0.10 changes and
   earlier sections.

## Output format

```
Severity: CRITICAL | HIGH | MEDIUM | LOW | INFO
Where: <spec § or file:line>
Threat: <attacker capability + goal>
Attack: <concrete steps>
Fix: <spec-text change>
```

End:

```
TOTALS: C=<n> H=<n> M=<n> L=<n> I=<n>
```

Merge gate: **0 CRITICAL, 0 HIGH, 0 MEDIUM**.
