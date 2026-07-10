# AUDIT — ISS-212 R2 — SECURITY lens

## Task

R2 security re-audit of the SPEC-007 v0.2.1 composite-PK addendum.

R1 surfaced 3 MEDIUMs on the security lens:
- **S3 (fixed in R1):** §6.4 forbidden-fields block added per
  §6.3 convention.
- **S1 (deferred to tracking issue):** bounded `matched_account_ids`
  (max 10 + `truncated`) and a SPEC MUST on operator workflow
  discipline for untrusted-input `request_id` flows.
- **S2 (deferred to tracking issue):** extend the ambiguity union
  to `feedback_events` and `audit_events`.

Both deferrals are documented in
`specs/SPEC-007-r0-2-1-audit.md`. The question for R2 is whether
those deferrals are still defensible given the merged #211 state.

Branch: `spec/iss-212-explorer-composite-pk`.

## What to audit

1. **S1 re-evaluation.** SPEC-002 v1.5.0 / #211 now formalizes
   the account-scoped reconciliation model. Does this change
   the security calculus for unbounded `matched_account_ids`
   disclosure?
2. **S2 re-evaluation.** With #211 merged, is the
   `feedback_events` / `audit_events` ambiguity-union gap a
   live exploit, a residual papercut, or fully closed by the
   composite reconciliation key on the coordinator side?
3. **Cross-PR check.** The §2.8 GAP-closed pointer now references
   SPEC-002 v1.5.0 / PR #224. Does it accurately describe the
   landed contract, or does it overstate what was actually
   shipped?
4. **Any new security surface introduced by the R1 doc-only
   addendum that hasn't already been considered?**

## Severity bar

Report ONLY CRITICAL / HIGH / MEDIUM. Each finding:
```
SEVERITY: ...
TITLE: ...
FILE: <path:line>
DETAIL: ...
SUGGESTED FIX: <minimal SPEC edit>
```

If zero findings, respond exactly: `ZERO FINDINGS`.

## Out of scope

- Composite-PK gateway IMPL (#196, already shipped).
- Coordinator-side bearer/auth (#211 / PR #224 territory).
