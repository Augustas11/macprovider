# SPEC-026 R9 — SECURITY audit lane

You are re-auditing SPEC-026 v0.9 after the R8 cleanup. Read
`SPEC-026-r{1,2,3,4,5,6,7,8}-audit.md` first. Do NOT re-flag
anything already fixed OR moved to SPEC-027 / SPEC-028 / the
SPEC-016 §3 addendum.

## Files in scope

- `specs/SPEC-026-browserless-provider-onboarding.md` (v0.9)
- `beta/DECISION_CRITERIA.md` Entry 102

## Focus for R9

Only the surfaces v0.9 touched:

1. **§4.1 duplicate-register bearer proof + AC-026-16.** Verify
   AC-026-16 covers the three scenarios correctly and matches
   §4.1 prose.
2. **§6.1 wallet field removed from launch window.** Verify no
   residual reference to a launch-window wallet input elsewhere.
3. **§9.3 Cancel-action removal.** Verify the "MUST NOT add a
   Cancel affordance before SPEC-027" language is unambiguous
   and doesn't accidentally re-open the door.
4. **§10 step 8 MALIBU gate.** Verify still enforceable.
5. **Entry 102 reformulated wording.** Verify no residual
   "email defense as active" claims.
6. **Any subtle interaction** between v0.9 changes and earlier
   sections.

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
