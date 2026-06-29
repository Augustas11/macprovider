# AUDIT — ISS-212 R5 — ARCHITECT lens

## Task

R5 architect re-audit. R4 surfaced 1 MEDIUM (§5.6 internal
inconsistency: path-param desc still claimed internal-OR-external
while identity-model said v0.4 deferral). R5 fixed both.

Branch: `spec/iss-212-explorer-composite-pk`.

## R5 deltas

- §5.6 path-parameter description tightened to "v0.3:
  coordinator-internal billing id only".
- §5.6 identity-model reworded as "both-or-nothing" — gateway
  proxy fires only when external_request_id AND account_id are
  both non-empty.
- AC-7 reworded to match the v0.3 coordinator-internal-id-only
  contract; the path-segment-overload + external-id 409 cases
  moved under an explicit "Deferred to v0.4" subsection.

## What to audit

1. Is the SPEC-007 v0.3 contract now internally consistent across
   §5.6 (identity model + path params + ambiguity + window) and
   AC-7?
2. The new "gateway_identity_unavailable" response shape — is it
   documented anywhere (other than inline in §5.6)? Should it be
   in §6.1 or §6.4 as a new error code?
3. Operator UX consideration: when the coordinator shows a
   legacy session that ALWAYS gets `gateway_identity_unavailable`,
   how does the operator know to widen the lookup? Does §5.6
   tell the implementer this is a known constraint of legacy
   rows, not an error?

## Severity bar

Report ONLY CRITICAL / HIGH / MEDIUM.

If zero findings, respond exactly: `ZERO FINDINGS`.
