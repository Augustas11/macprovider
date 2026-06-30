You are auditing SPEC-005 v0.4 (issue #169 — manual quarantine VOID
admin surface) for CODE-correctness concerns, ROUND 4.

# Repository context

- `specs/SPEC-005-billing.md` on branch `spec/005-v0-4-quarantine-resolution`,
  commit `355006f`.
- v0.4 underwent a SCOPE CUT between R3 and R4: force-credit is
  DEFERRED to v0.5 along with the pre-payout hold primitive. v0.4
  now ships force-VOID only.
- Prior rounds: R1 0/5/3/0 → R2 fixed → R3 0/5/0/0 → scope cut →
  R4 (this round).

# Audit scope (CODE lens)

Same scope as prior rounds. Specifically verify post-cut:

- §11.6 is internally consistent (force-void only, no
  vestigial force-credit references that would mislead an
  implementer).
- The §4.10 CHECK constraint `resolution_kind IN ('force_void')`
  matches the endpoint contract (no `/force-credit` route in v0.4).
- §11.6.5 reader-side correctly identifies that
  `INCLUDED_PREDICATE` is UNCHANGED from v0.3.3 (just
  `quarantined=0`), and only `quarantined_count` reads narrow.
- §11.3 reconcile `delta_gross_credits` semantics are consistent
  with the v0.3.3 predicate.
- The new AC-Q055 (force-credit schema rejection) is fixture-
  runnable.
- §13.2 audit event for config-flag flips is well-defined.

# Severity

- **CRITICAL** = SPEC defect that would corrupt the ledger or
  cause silent money loss.
- **HIGH** = SPEC defect that forces IMPL ambiguity.
- **MEDIUM** = clarity gap.
- **LOW** = wording.

# Output

```
[SEVERITY] <short title>

Location: <§ anchor or line range>
Concern: <what is wrong>
Evidence: <quote>
Fix: <one-sentence>
```

End: `Tally: <C>/<H>/<M>/<L>` or `Tally: 0/0/0/0 ACCEPT`.

Audit the R4 text AS WRITTEN.
