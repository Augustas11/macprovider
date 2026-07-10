# AUDIT — ISS-211 R7 — CODE lens

## Task

R7 code re-audit. R6 surfaced 4 MEDIUMs all stemming from a
conceptual cleanup: I had been treating internal `request_log.request_id`
collisions as the post-#196 attack class, but server-minted UUIDs
don't naturally collide. The real #211 surface is `external_request_id`.

R7 finishes the cleanup.

Branch: `spec/iss-211-coordinator-account-scope`.

## R7 deltas (relative to R6)

- `phase4-coordinator/internal/billing/hotpath.go`, `recovery.go`,
  `endpoints.go`: scope-rationale comments reworded as defense-
  in-depth, explicitly noting internal vs external request_id.
- `phase4-coordinator/internal/billing/store_test.go`: two tests
  renamed
  (`TestRecoverLedger_AccountScopedInternalRequestIDDefenseInDepth`,
  `TestWriteHotPath_AccountScopedInternalRequestIDDefenseInDepth`)
  with reframed comments.
- `phase4-coordinator/internal/billing/endpoints_test.go`: test
  renamed
  (`TestReconcileEndpoint_AccountScopedInternalRequestIDDefenseInDepth`),
  comment reworded, fixture id renamed
  (`buyer-controlled-duplicate-reconcile` →
  `synthetic-internal-uuid-collision`).
- `specs/SPEC-002-coordinator.md` §11 FR-B9 paragraph + v1.5.0
  changelog bullet 1 reworded to defense-in-depth language with
  internal/external request_id distinction.
- `specs/SPEC-002-v1-5-0-audit.md` gets an R6-conceptual-reframe
  preamble.
- `specs/SPEC-005-billing.md` AC-MULTIHOP and AC-ATTEMPT-FALLBACK
  fixture-detail appendices (~line 2420) updated to
  `(account_id, request_id)` grouping language matching the main
  AC body.

## What to audit

1. Does any remaining SPEC text or code comment still claim that
   internal `request_id` collisions across accounts are the #196
   attack class?
2. Are the test names + IDs internally consistent with the
   defense-in-depth framing?
3. The audit-findings file `specs/SPEC-002-v1-5-0-audit.md`
   preamble documents the R6 reframe. Is the preamble's
   "authoritative for current behavior" framing clear enough
   that a future reader doesn't get misled by the R1-era body
   text that follows?

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

- SPEC-007 stale text (e.g. §1241, §1591, AC-7) — owned by
  PR #221 / issue #212; that PR's audit loop will pick it up.
