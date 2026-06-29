You are auditing SPEC-005 v0.4 (issue #169 — manual quarantine VOID
admin surface) from an ARCHITECT lens, ROUND 4.

# Repository context

- `specs/SPEC-005-billing.md` on branch `spec/005-v0-4-quarantine-resolution`,
  commit `355006f`.
- v0.4 underwent a SCOPE CUT between R3 and R4: force-credit is
  DEFERRED to v0.5 along with the pre-payout hold primitive.
- Prior rounds: R1 0/2/4/1 → R2 fixed → R3 0/1/0/0 → scope cut →
  R4 (this round).

# Audit scope (ARCHITECT lens)

Verify the v0.4 scope cut is architecturally defensible:

1. **Is force-void alone operationally useful?** v0.4 ships only
   the void-arm of §OQ-5. Does this actually solve the operator
   problem (clearing false-positive quarantines from
   `quarantined_count`) or is it a half-measure that requires
   v0.5 to be useful in practice?
2. **Is the v0.5 deferral list complete and coherent?** Force-
   credit + pre-payout hold + UNIQUE-relaxation for corrective
   resolutions + first-class open-quarantine list endpoint —
   does this set hang together as one coordinated v0.5 design,
   or does it have internal contradictions?
3. **Are the v0.4 schema choices forward-compatible with v0.5?**
   The `CHECK(resolution_kind IN ('force_void'))` constraint and
   the `UNIQUE(request_credit_id)` constraint both need to lift
   in v0.5. Is this clean (ALTER TABLE + CHECK rewrite) or messy?
4. **Does v0.4 force-void create any operator workflow that
   becomes unsafe when v0.5 lands?** E.g., an operator habit
   formed under v0.4 that becomes wrong under v0.5.
5. **Production launch gate (§11.5 item 10).** Is the
   default-disabled-at-route-layer posture for force-void alone
   defensible, or is force-void safe enough to ship enabled?

# Severity

- **CRITICAL** = fundamental design defect; v0.4 should not ship.
- **HIGH** = architectural gap compounding with v0.5.
- **MEDIUM** = scoping question.
- **LOW** = framing.

# Output

```
[SEVERITY] <short title>

Location: <§ or topic>
Concern: <architectural question>
Evidence: <quote>
Fix: <one-sentence>
```

End: `Tally: <C>/<H>/<M>/<L>` or `Tally: 0/0/0/0 ACCEPT`.

Audit the R4 text AS WRITTEN. The scope cut itself is a deliberate
decision; do not relitigate it unless you spot a hidden cost.
