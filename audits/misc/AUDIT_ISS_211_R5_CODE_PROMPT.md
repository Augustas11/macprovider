# AUDIT — ISS-211 R5 — CODE lens

## Task

R5 code re-audit. R4 surfaced 1 MEDIUM on the code lens (SPEC-005
changelog still described NULL rows as "unscoped"). R5 fixed the
wording.

Branch: `spec/iss-211-coordinator-account-scope`.

## R5 deltas

- `specs/SPEC-005-billing.md` v0.3.1 change-log bullet rewritten:
  no longer says legacy NULL rows preserve "unscoped grouping";
  now says "intra-NULL grouping" with SQLite `IS` matching
  NULL with NULL only.
- New tests: `TestWriteHotPath_SameProviderCrossAccountCollisionBehavior`
  and `TestReconcileEndpoint_AccountScopedRequestIDCollisionCleanDelta`.

## What to audit

1. Does the SPEC-005 changelog rewording match the body of §4.2 /
   §8.2 / §15.2 / AC-D10 / OQ-1 IS-NULL clustering language?
2. Any remaining SPEC-005 reference that says NULL rows are
   "unscoped" or "fall back to same-request_id"?
3. Does `TestWriteHotPath_SameProviderCrossAccount...` accurately
   reflect the documented SPEC-002 §11 known limitation? (i.e.,
   would future drift in hotpath.go's transactional rollback
   semantics break this assertion?)
4. Does `TestReconcileEndpoint_AccountScoped...` actually exercise
   the endpoints.go scoping path (not the hotpath.go path)?

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
