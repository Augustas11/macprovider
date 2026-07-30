You are auditing SPEC-005 v0.4 (issue #169 — manual quarantine VOID
admin surface) for SECURITY concerns, ROUND 4.

# Repository context

- `specs/SPEC-005-billing.md` on branch `spec/005-v0-4-quarantine-resolution`,
  commit `355006f`.
- v0.4 underwent a SCOPE CUT between R3 and R4: force-credit is
  DEFERRED to v0.5. v0.4 ships force-VOID only — no money-out
  surface remains.
- Prior rounds: R1 0/1/2/2 → R2 fixed → R3 0/1/2/0 → scope cut →
  R4 (this round).

# Audit scope (SECURITY lens)

Same scope as prior rounds. Specifically verify post-cut:

- The §11.6.6 threat-model section correctly drops the force-credit
  money-path-exposure threat. Force-void's only failure mode is
  "operator force-voids a legitimate row" — which loses
  `quarantined_count` accuracy but does NOT lose money.
- The §11.6.3 sanitizer (Unicode reject list) is complete enough
  for forensic audit fidelity.
- The §11.6.4 audit-log emit + operator_attribution payload field
  is sufficient given v0.4's narrower scope.
- The §13.2 route-flag flip audit event closes the prior
  "operator-flips-flag-and-back-to-hide-action" gap.

# Severity

- **CRITICAL** = exploitable, money loss or auth bypass.
- **HIGH** = significant security gap.
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

Audit the R4 text AS WRITTEN.
