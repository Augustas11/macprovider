You are auditing SPEC-005 v0.4 (issue #169 — manual quarantine
resolution admin surface) for SECURITY concerns, ROUND 2.

# Repository context

- This is `specs/SPEC-005-billing.md` in repo `Augustas11/macprovider`
  (branch `spec/005-v0-4-quarantine-resolution`, commit `b8afc03`).
- R2 — R1 produced findings in `specs/SPEC-005-v0-4-r1-audit.md`.
- The R1 SECURITY findings to verify-as-closed:
  - S-H1: Settlement sweep ordering is ambiguous
  - S-M1: Audit attribution is self-asserted
  - S-M2: Audit-log poisoning gap for Unicode display controls
  - S-L1: Operator-keyed ID enumeration is explicit
  - S-L2: POST-rate-limit accounting is underspecified

# Audit scope (SECURITY lens)

Same scope as R1 — auth/authz, input validation, logging /
audit poisoning, money-path correctness, race/TOCTOU, DoS,
information disclosure, audit-log invariants, settlement-window
race, immutable-resolution policy.

ALSO: any NEW exposure created by the R1 fix-pass. Specifically:
- The new §11.6.6.4 runbook expects operators to PAUSE settlement
  + payout runners. Is the runbook achievable without leaving the
  system in a corrupt state if interrupted? Are there race windows
  during pause/resume?
- The expanded §11.6.4 reject list closes Unicode bidi / zero-
  width. Are there remaining display-mangling classes (e.g.,
  combining diacritics that produce visual confusables; tag
  characters U+E0000–U+E007F; private-use area)?
- The §11.6.5 caveat says the audit proves only operator-key use.
  Does that caveat surface clearly enough in the audit-row format
  itself (i.e., a forensic reader of the audit_log table would
  know this)?
- §11.6.6.1 settlement snapshot ordering is normative under
  `BEGIN IMMEDIATE`. Does this break any composability claim with
  the broader settlement-runner pause semantics named in
  §11.6.6.4?

# Severity

- **CRITICAL** = exploitable, money loss or auth bypass.
- **HIGH** = significant security gap.
- **MEDIUM** = hardening item the SPEC should explicitly name.
- **LOW** = wording that opens a mistake class.

# Output format

```
[SEVERITY] <short title>

Location: <§ anchor>
Concern: <what is wrong>
Evidence: <quote>
Fix: <one-sentence>
```

End: `Tally: <C>/<H>/<M>/<L>` or `Tally: 0/0/0/0 ACCEPT`.

If an R1 finding is closed, do NOT re-list it; only list NEW
issues OR issues NOT actually closed.

Audit the v0.4 R2 text AS WRITTEN. Don't propose unrelated features.
