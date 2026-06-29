# AUDIT — ISS-211 R6 — CODE lens

## Task

R6 code re-audit. R5 surfaced 1 MEDIUM that triggered a conceptual
rewrite: I had been conflating `external_request_id` (buyer-supplied
X-Request-ID, the real #211 attack surface) with internal `request_id`
(server-minted UUID, doesn't naturally collide). R6 reframes the
SPEC narrative around defense-in-depth instead of a load-bearing
ledger-PK collision concern.

Branch: `spec/iss-211-coordinator-account-scope`.

## R6 deltas (relative to R5)

- **DELETED** `TestWriteHotPath_SameProviderCrossAccountCollisionBehavior`.
  The scenario it pinned (two accounts sharing the same internal
  `request_id`) is artificial — internal `request_id` is minted via
  `requestIDForBuyerRequest() = uuid.NewString()` per buyer call,
  so two accounts cannot naturally collide there. (`strings` import
  removed from `store_test.go` since this was its only use.)
- `specs/SPEC-002-coordinator.md` §11 "Money-path: AttemptN
  derivation" rewritten as defense-in-depth narrative; it clarifies
  internal `request_id` (server-minted) vs `external_request_id`
  (buyer-supplied) and points out the real #211 collision class is
  on `external_request_id`.
- `specs/SPEC-002-coordinator.md` §11 "same-provider cross-account
  collision" subsection **deleted** (described a non-existent attack
  class).
- `specs/SPEC-006-buyer-api.md` §906 + §2323 reworded: `X-Request-ID`
  is a correlation value, not a unique row identity; the composite
  `(account_id, request_id)` is the physical PK on the gateway side
  and `(account_id, external_request_id)` is the reconciliation key.
- `specs/SPEC-006-buyer-api.md` §305 v1.1.5 stale dep updated to
  v1.5.0 with §1.5 wording.
- `specs/SPEC-002-coordinator.md` AC-FR-B9-MULTI updated to
  `(account_id, request_id)` grouping.
- `specs/SPEC-005-billing.md` AC-MULTIHOP and AC-ATTEMPT-FALLBACK
  updated to `(account_id, request_id)` grouping with IS-clustering
  caveat for legacy NULL fixtures.

## What to audit

1. Does the deleted test leave any orphaned references in
   SPEC-002 §11, audit-findings file, or commit message context?
2. Does the rewritten SPEC-002 §11 "Money-path: AttemptN derivation"
   subsection accurately describe what hotpath.go / recovery.go /
   endpoints.go actually do? Specifically: the queries scope by
   `(account_id, request_id)` regardless of whether collisions
   are realistic.
3. Do any remaining SPEC text claims describe a same-internal-
   request_id cross-account scenario as a real attack class?
   (Sweep for "cross-account collision" + "request_id" — the
   acceptable phrasing is "defense-in-depth" / "should the same
   internal request_id ever recur".)
4. The strengthened existing tests still pass after R6's deletion
   of the artificial test?

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
