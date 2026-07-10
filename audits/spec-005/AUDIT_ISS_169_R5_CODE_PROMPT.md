You are auditing SPEC-005 v0.4 (issue #169 — manual quarantine VOID
admin surface) for CODE-correctness concerns, ROUND 5.

# Repository context

- `specs/SPEC-005-billing.md` on branch `spec/005-v0-4-quarantine-resolution`.
- R4 tally was 0/0/1/0 (CODE) — config-flag startup-semantics.
- R4 fix-pass narrowed `reload_source` enum to `{"sighup",
  "http_reload"}` and added the no-change suppression rule.
- This is convergence target — R5 should be `Tally: 0/0/0/0 ACCEPT`.

# Audit scope (CODE lens)

Same scope as prior rounds. Verify the R4 fix actually closed the
MEDIUM finding AND look for NEW defects.

# Severity

- **CRITICAL** = ledger corruption / silent money loss.
- **HIGH** = IMPL ambiguity.
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
