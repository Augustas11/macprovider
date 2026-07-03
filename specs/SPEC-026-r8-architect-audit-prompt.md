# SPEC-026 R8 — ARCHITECT audit lane

You are re-auditing SPEC-026 v0.8 after the R7 cleanup. Read
`SPEC-026-r{1,2,3,4,5,6,7}-audit.md` first. Do NOT re-flag
anything already fixed OR moved to follow-up specs.

## Files in scope

- `specs/SPEC-026-browserless-provider-onboarding.md` (v0.8)
- `beta/DECISION_CRITERIA.md` Entry 102

## Focus for R8

1. **Split coherence after R7 cleanup.** Verify SPEC-026 v0.8
   is now a self-contained App-track onboarding spec with
   clear pointers to SPEC-027 / SPEC-028 / SPEC-016 addendum.
2. **§10 step 8 gate placement.** Is the MALIBU gate at the
   right layer (SPEC-026's deploy checklist), or does it belong
   in SPEC-028's cutover checklist?
3. **§4.5 / §6.2 / §9.3 pointer sections.** Verify each is a
   coherent forward reference; no dangling normative
   requirements.
4. **§1.2 wallet-signing non-goal wording.** Verify the "during
   onboarding" qualifier resolves the earlier ambiguity.
5. **AC-026-06 + AC-026-15 alignment with what SPEC-026 owns.**
6. **Cross-spec ordering after v0.8.** SPEC-026 merges first,
   then SPEC-016 §3 addendum + SPEC-027 + SPEC-028 in some
   order. Does the ordering hold?
7. **Entry 102 v0.8 correctness.**

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
