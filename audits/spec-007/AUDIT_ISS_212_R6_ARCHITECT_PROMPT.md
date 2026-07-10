# AUDIT — ISS-212 R6 — ARCHITECT lens

## Task

R6 architect re-audit. R5 surfaced 3 MEDIUMs (§5.6 fallback
contradiction, `gateway_identity_unavailable` not integrated into
error contract, operator UX under-specified). All three fixed in R6.

Branch: `spec/iss-212-explorer-composite-pk`.

## R6 deltas

- §5.6 ambiguity contract reworded — no more "fall back to
  forwarding internal id" claim; explicit "no proxy →
  `gateway_identity_unavailable`" outcome.
- §5.6 underlying gateway-endpoint paragraph reworded similarly.
- AC-7 legacy NULL-account sub-case rewritten to assert
  `gateway_identity_unavailable`, not unscoped proxy.
- §5.6 response-schema block expanded with explicit
  "Gateway-section error shapes" documenting null,
  `gateway_unavailable`, and `gateway_identity_unavailable`,
  including the operator UX guidance that the latter is an
  expected legacy-identity-limit, NOT a gateway failure, and
  UI rendering SHOULD distinguish them.

## What to audit

1. Is SPEC-007 v0.3 now internally consistent across §5.6
   (identity model + path params + ambiguity + response schema)
   and AC-7?
2. Should `gateway_identity_unavailable` be referenced in §14
   (partial/error handling)? §14 lists error codes — does the
   omission leave a gap?
3. Is the operator UX guidance ("UI rendering SHOULD
   distinguish") strong enough? Should it be MUST?
4. The R5 architect's question about operator widening the
   lookup: SPEC §5.6 still doesn't tell the implementer HOW to
   widen — operators have to manually run a SQL query for
   legacy rows. Is this acceptable for v0.3?

## Severity bar

Report ONLY CRITICAL / HIGH / MEDIUM.

If zero findings, respond exactly: `ZERO FINDINGS`.
