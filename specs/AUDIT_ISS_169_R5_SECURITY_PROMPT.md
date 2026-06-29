You are auditing SPEC-005 v0.4 (issue #169 — manual quarantine VOID
admin surface) for SECURITY concerns, ROUND 5.

# Repository context

- `specs/SPEC-005-billing.md` on branch `spec/005-v0-4-quarantine-resolution`.
- R4 tally was 0/0/1/0 (SECURITY) — Default_Ignorable_Code_Point
  reject list was incomplete.
- R4 fix-pass pinned Unicode 16.0 and enumerated the full DICP=Yes
  range list per `DerivedCoreProperties.txt`.
- Convergence target.

# Audit scope (SECURITY lens)

Verify the R4 fix actually closed the MEDIUM finding AND look for
NEW exposure introduced by the expanded reject list.

# Severity

- **CRITICAL** = exploitable.
- **HIGH** = significant gap.
- **MEDIUM** = hardening item.
- **LOW** = wording.

# Output

```
[SEVERITY] <short title>

Location: <§ anchor>
Concern: <what is wrong>
Evidence: <quote>
Fix: <one-sentence>
```

End: `Tally: <C>/<H>/<M>/<L>` or `Tally: 0/0/0/0 ACCEPT`.
