# AUDIT — ISS-212 R6 — CODE lens

## Task

R6 code re-audit. R5 surfaced 3 MEDIUMs (gateway-only fallback,
cross-row firstNonEmpty synthesis, stale fallback claims in SPEC).
All three fixed in R6.

Branch: `spec/iss-212-explorer-composite-pk`.

## R6 deltas (relative to R5)

- `phase4-coordinator/internal/explorer/handlers.go`
  `handleSessionDetail`: removed the pre-v0.3 gateway-only
  fallback path (`if errors.Is(err, sql.ErrNoRows) && GatewayBaseURL
  ... proxy raw path-segment`). ErrNoRows now returns 404 cleanly.
- `phase4-coordinator/internal/explorer/handlers.go`:
  `firstNonEmptyAttempt` (cross-row synthesis) replaced with
  `firstAttemptWithBothFields` which scans for a SINGLE row that
  supplies both `external_request_id` and `account_id`.
- `phase4-coordinator/internal/explorer/handlers_test.go`:
  `TestSessionDetailGatewayOnlyReturnsEmptyLocalArrays` renamed
  + rewritten to `TestSessionDetailNoCoordinatorRowReturns404`
  (asserts 404 + no gateway call).
- `specs/SPEC-007-explorer.md` §5.6 ambiguity contract + underlying
  gateway endpoint + AC-7 legacy sub-case all reworded to
  "both-or-nothing" (no fallback to internal-id forwarding;
  legacy / incomplete-identity rows return
  `gateway_identity_unavailable`).
- `specs/SPEC-007-explorer.md` §5.6 response-schema block now
  documents all three gateway-section error shapes (`null`,
  `gateway_unavailable`, `gateway_identity_unavailable`).

## What to audit

1. Does the removed gateway-only fallback now correctly return
   404 from `handleSessionDetail`? Are there other paths in the
   coordinator that would still re-introduce the path-segment-
   overload via gateway proxy?
2. Does `firstAttemptWithBothFields` actually require BOTH fields
   from one row (not synthesized)? Verify the helper logic.
3. SPEC §5.6 + AC-7: do they ALL now say the same thing about
   legacy / incomplete-identity rows (no proxy →
   `gateway_identity_unavailable`)?
4. Any orphaned imports or unused helpers from the removed
   fallback path?

## Severity bar

Report ONLY CRITICAL / HIGH / MEDIUM.

If zero findings, respond exactly: `ZERO FINDINGS`.
