# SPEC-026 R8 — SECURITY audit lane

You are re-auditing SPEC-026 v0.8 after the R7 cleanup. Read
`SPEC-026-r{1,2,3,4,5,6,7}-audit.md` first. Do NOT re-flag
anything already fixed OR moved to SPEC-027 / SPEC-028 /
SPEC-016 §3 addendum.

## Files in scope

- `specs/SPEC-026-browserless-provider-onboarding.md` (v0.8)
- `beta/DECISION_CRITERIA.md` Entry 102

## Focus for R8

1. **§4.1 duplicate-register bearer proof.** Verify: attacker
   with only identity signing but not the current token bearer
   cannot force revocation of the honest live session. Any
   subtle attack path?
2. **§10 step 8 MALIBU gate.** Verify: an operator who ships
   the App-side flag flip without SPEC-028 AND without a hold
   mode is in violation of the gate. Fail-loud on this?
3. **§11 prerequisite qualifier.** Verify: readers of §11
   understand that the sybil narrative is prose-only until the
   §10 step 8 gate is satisfied.
4. **§9.3 accepted-risk pointer.** Verify: operators understand
   that between SPEC-026 merge and SPEC-027 merge, App-track
   wallet-swap coercion is an accepted risk.
5. **Residual R6/R7 threats** on the moved-out surface.
   Confirm: these threats now live against SPEC-027 / SPEC-028,
   not SPEC-026. Any threat that survives the split
   specifically because SPEC-026's own surface still enables
   it?

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
