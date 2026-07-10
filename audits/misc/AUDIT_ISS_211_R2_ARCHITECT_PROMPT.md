# AUDIT — ISS-211 R2 — ARCHITECT lens

## Task

R2 architect re-audit. R1 surfaced 1 HIGH + 4 MEDIUM. R2 fixed all
five and added new structural code (recovery.go SQL scope, bearer
hoist). Re-check whether R2 introduced new architectural issues
or whether the original deferrals are still defensible.

Branch: `spec/iss-211-coordinator-account-scope`.

## R2 architect deltas

- `recovery.go` orphan-detection + prior + same_request_count
  subqueries scope by `(account_id, request_id)` via SQLite `IS`.
- SPEC-002 v1.5.0 explorer-deferral bullet explicitly added.
- SPEC-002 v1.5.0 §10 D11 refreshed with the v1.5.0 contract.
- SPEC-002 v1.5.0 rollback-row-level-gate language added.
- SPEC-002 v1.5.0 + SPEC-006 v0.9.1 both record the new bearer-
  pairing requirement.
- `specs/SPEC-002-v1-5-0-audit.md` consolidates findings.

## Focus areas

1. **More request_log scans missed.** R1 caught hotpath.go +
   recovery.go. Are there other coordinator queries over
   `request_log` (billing/store.go, ws/, explorer/store.go,
   stats/, or anywhere else) that join or count by
   `request_id` and would be vulnerable to the same
   cross-account collision class on the money-path or
   audit-trail surface? R1 architect identified explorer/store.go
   and explicitly deferred. Are there others NOT in the
   deferral note that should be in scope here?

2. **Defense in depth on the bearer pairing.** R1 fixed S1 by
   pairing the bearer. R2 SPEC-006 v0.9.1 records this. But
   the underlying root cause is that the coordinator uses one
   header (`X-MacProvider-Account`) for two semantically-distinct
   purposes:
   - INTERNAL ROUTING (sticky / conversation routing — requires
     bearer auth).
   - RECONCILIATION TAG (audit-trail, no special routing
     intent).
   Is bundling both purposes under one header the right
   long-term architecture, or should v2 introduce a separate
   `X-MacProvider-Audit-Account` header that doesn't require
   bearer pairing? If long-term we want separation, is the
   v1.5.0 bearer-pairing a permanent workaround or a transitional
   shim? Recommend the right architectural shape.

3. **SPEC-005 / SPEC-004 sub-contracts.** SPEC-002 v1.5.0
   touches §11 / §7.2 / §10 D11. Does SPEC-005 (billing
   reconciliation) or SPEC-004 (retry attempts) have any text
   that now contradicts the new composite identity, that this
   PR should also touch? (R1 deferred explorer — does that
   blanket apply, or does SPEC-005 require independent action?)

4. **D-CROSS-3 / SPEC-CROSS-006 audit doc.** §10 D11 cites
   SPEC-CROSS-006-audit.md as the source. Does that audit doc
   also need updating, or is the SPEC-002 §10 entry the
   single source of truth?

5. **Version coupling.** SPEC-006 v0.9.1's
   `Depends on: SPEC-002 v1.5.0` is now strict. SPEC-007
   v0.2.1 (PR #221) doesn't bump its SPEC-002 dependency.
   Should it? Is the cross-PR dependency story coherent?

6. **Rollback path completeness.** The R2 rollback note says
   auditors use `account_id IS NOT NULL` per-row gate. But
   does the SPEC also need to specify what the gateway should
   do if it detects a coordinator that has rolled back (e.g.,
   the gateway sees a `400 invalid_request` on the
   X-MacProvider-Account header because the rollback target
   never had the column)? Today's fallback would be the
   coordinator's pre-existing behavior; is that documented?

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

- Re-evaluating Option A vs B vs C.
- The R1 findings (assume R2 disposition unless R2 broke them).
- Demo abuse rate-limiting.
