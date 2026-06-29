# AUDIT — ISS-212 R2 — ARCHITECT lens

## Task

R2 architect re-audit of the SPEC-007 v0.2.1 composite-PK addendum.

R1 surfaced 2 MEDIUMs (A1: §6.1 envelope-shape exception note;
A2: SPEC-007-explorer-design.md §4.2 / §2.8 paired update). Both
fixed in R1. The related #211 work merged in PR #224 with the
SPEC-002 v1.5.0 contract; the #224 R6 architect lane flagged some
SPEC-007 text that this PR was expected to address:
- SPEC-007 §1241: "GET /admin/explorer/sessions/{request_id}" with
  "Query parameters: None" — this PR's §6.4 rewrite IS the fix.
- SPEC-007 §1591 area: cross-component join-key text. This PR
  does NOT yet update §1591 / §7.5.
- SPEC-007 AC-7: account-scoped fixture instructions. This PR
  does NOT yet update AC-7.

Branch: `spec/iss-212-explorer-composite-pk`.

## What to audit

1. **Cross-corpus coherence after #224 merged.** With SPEC-002
   v1.5.0, SPEC-005 v0.3.1, SPEC-006 v0.9.1 now in main, does
   SPEC-007 v0.2.1 form a consistent end-to-end story about
   `(account_id, request_id)` as the physical reconciliation
   identity? Any text still claiming `request_id` alone is the
   join/row key?
2. **SPEC-007 §1591 — cross-component join key text.** Per #224
   R6 architect HIGH, this text still describes the gateway join
   as `request_id` only. Should this PR update §1591 / §7.5 to
   describe the composite key (gateway side: composite PK
   `(account_id, request_id)`; coordinator side: composite
   reconciliation key `(account_id, external_request_id)`)?
3. **SPEC-007 AC-7 fixture instructions.** Per #224 R6
   architect MEDIUM, AC-7 still teaches `request_id`-only join
   fixtures. Should this PR update AC-7 to seed two accounts
   sharing the same `request_id` and assert account-scoped
   disambiguation?
4. **§2.8 GAP-closed pointer accuracy.** Does the pointer to
   SPEC-002 v1.5.0 / #211 describe what actually landed (the
   composite `(account_id, external_request_id)` reconciliation
   key + NULL-account fallback)?
5. **Version bump correctness.** Is v0.2.1 still appropriate
   given the addendum scope, or does this PR also need to
   absorb the §1591/AC-7 updates and bump to v0.3?

## Severity bar

Report ONLY CRITICAL / HIGH / MEDIUM. Each finding:
```
SEVERITY: ...
TITLE: ...
FILE: <path:line>
DETAIL: ...
SUGGESTED FIX: <minimal>
```

If zero findings, respond exactly: `ZERO FINDINGS`.

## Out of scope

- Re-litigating the v0.2.1 vs v0.3 minor/patch boundary unless
  the scope question genuinely warrants a bump.
- Locked decisions D1-D14.
