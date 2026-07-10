You are auditing SPEC-005 v0.4 (issue #169 — manual quarantine
resolution admin surface) from an ARCHITECT lens, ROUND 3.

# Repository context

- `specs/SPEC-005-billing.md` on branch `spec/005-v0-4-quarantine-resolution`,
  commit `c54e834`.
- R3 — R2 produced findings; R2 fix-pass is in the current commit.
- R2 ARCHITECT findings:
  - A2-H1: Pre-payout deferral had no safe correction path (closed
    by §11.6.6.5 SPEC-016 503 gate)
  - A2-H2: Launch gate was advisory not enforced (closed by §11.5
    MUST + per-endpoint config flag)
  - A2-M1: Late-resolution settlement wording conflicted (closed
    by §11.6.6.1 + §11.6.6.2 unification)

# Audit scope (ARCHITECT lens)

Same scope as R1/R2. ALSO verify:
- The §11.6.6.5 SPEC-016 503 gate is architecturally sound — does
  it create a new coupling between SPEC-005 and SPEC-016 that
  v0.5 needs to unwind?
- The two per-endpoint config flags are appropriate granularity —
  could one combined flag suffice? Could three (separate enable +
  separate SPEC-016 gate) be needed?
- The "force-void NOT gated by SPEC-016" carve-out: is it
  defensible (force-void is money-out-safe) or does it create an
  asymmetry an operator will misinterpret?
- The deferral rationale for v0.5 pre-payout hold: now that v0.4
  has the SPEC-016 gate as a real primitive, is the deferral
  still acceptable, or should v0.4 ship the hold itself?

# Severity

- **CRITICAL** = fundamental design defect.
- **HIGH** = architectural gap.
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

If an R2 finding is closed, do NOT re-list. Audit the R3 text AS
WRITTEN.
