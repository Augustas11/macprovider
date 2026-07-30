# AUDIT — ISS-212 R4 — ARCHITECT lens

## Task

R4 architect re-audit. R3 surfaced 1 MEDIUM (SPEC-007-explorer-design.md
stale §2.8 lead bullet + line 189). R4 rewrote both.

Branch: `spec/iss-212-explorer-composite-pk`.

## R4 deltas

- `specs/SPEC-007-explorer-design.md` §2.7 explorer-uses bullet
  reworded (ledger joins on internal `request_id`; gateway joins
  on composite `(account_id, external_request_id)` ⇔
  `(account_id, request_id)`; legacy NULL fallback noted).
- `specs/SPEC-007-explorer-design.md` §2.8 "Available joins"
  bullet list reordered: intra-coordinator FIRST, cross-service
  SECOND with the composite key, legacy NULL fallback THIRD.
- Gap list deduplicated: kept `session_id` + demo-stable-account
  gaps; folded "No coordinator-side buyer identity" into a
  "Closed by SPEC-002 v1.5.0 / #211" note.

## What to audit

1. Does the SPEC-007 corpus (explorer.md + explorer-design.md)
   now tell a consistent end-to-end story matching SPEC-002
   v1.5.0 + SPEC-006 v0.9.1?
2. Is the path-segment-overload deferral to v0.4 documented
   well enough that a future implementer can resume the work
   without re-deriving the security rationale?
3. The §5.6 fallback "forward internal id when external is
   empty" — is this acceptable for the v0.3 contract or does
   it warrant an explicit defer to a follow-up?

## Severity bar

Report ONLY CRITICAL / HIGH / MEDIUM.

If zero findings, respond exactly: `ZERO FINDINGS`.
