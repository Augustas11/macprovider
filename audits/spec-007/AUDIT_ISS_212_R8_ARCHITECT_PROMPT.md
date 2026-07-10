# AUDIT — ISS-212 R8 — ARCHITECT lens

## Task

R8 architect re-audit. R7 surfaced 1 MEDIUM (design-doc §4.2
still described coordinator path-segment as accepting
`?account_id=` and returning 409 — the pre-v0.3 path-segment-
overload model). Fixed in R8.

R7 code and R5 security both returned ZERO FINDINGS, so only
architect is re-run.

Branch: `spec/iss-212-explorer-composite-pk`.

## R8 deltas

- `specs/SPEC-007-explorer-design.md` §4.2 Sessions block
  rewritten:
  - Path-segment description: coordinator-internal id only;
    external-id lookup deferred to v0.4 with direct-SQL
    workaround called out.
  - Gateway-proxy description: both-or-nothing rule, with
    `gateway_identity_unavailable` as the documented
    incomplete-identity outcome.
  - Returns list noted that gateway rows appear only when the
    proxy fires.

## What to audit

1. Is the design-doc §4.2 now consistent with SPEC-007.md
   §5.6 v0.3?
2. Any other place in SPEC-007-explorer-design.md that still
   describes coordinator session-detail as accepting an
   external-id or returning 409?
3. Cross-corpus check: is the entire SPEC-007 v0.3 narrative
   self-consistent end-to-end?

## Severity bar

Report ONLY CRITICAL / HIGH / MEDIUM.

If zero findings, respond exactly: `ZERO FINDINGS`.
