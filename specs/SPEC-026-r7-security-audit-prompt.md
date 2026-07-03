# SPEC-026 R7 — SECURITY audit lane

You are re-auditing SPEC-026 v0.7 after the R6 SCOPE-REDUCTION
pass. Read `SPEC-026-r{1,2,3,4,5,6}-audit.md` first. Do NOT
re-flag anything already fixed OR anything moved out to
SPEC-027 / SPEC-028 / the SPEC-016 §3 addendum.

## Files in scope

- `specs/SPEC-026-browserless-provider-onboarding.md` (v0.7)
- `beta/DECISION_CRITERIA.md` Entry 102

## What to check in R7

Rank findings CRITICAL / HIGH / MEDIUM / LOW / INFO.

1. **Threat model with SPEC-027 / SPEC-028 deferred.**
   Between SPEC-026 shipping and SPEC-027 shipping, App-track
   providers have no verified-email out-of-band cancellation
   channel; the SPEC-016 §3 EIP-712 wallet proof-of-possession
   is the sole wallet-swap defense. Is that residual risk
   acceptable, and is it called out in §11?
2. **§4.1 `/register` remains OK.** Any new threat from the
   simplifications since v0.6? Verify.
3. **§4.3 auth-policy `provider_auth_policy` in isolation.**
   Verify the SPEC-026-owned pieces still hold without the
   deferred surfaces.
4. **§5.2 Trust unlock criteria with SPEC-028 deferred.** If
   the automated enforcement of "provisional MALIBU is
   non-withdrawable" doesn't ship until SPEC-028, does the §5.2
   unlock model still work correctly, or does it create a
   period where the sybil economics are open?
5. **§9.3 pointer** should explicitly state that operators
   accept the App-track wallet-swap-coercion risk between
   SPEC-026 and SPEC-027 merges. Verify.
6. **§11 sybil-defense narrative.** Verify still coherent with
   enforcement primitives deferred. If the narrative claims
   sybil defense that only works when SPEC-028's enforcement
   ships, the narrative should be qualified.
7. **Entry 102.** Verify security-relevant claims match v0.7
   scope.

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
