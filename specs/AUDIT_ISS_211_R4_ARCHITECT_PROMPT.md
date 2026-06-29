# AUDIT — ISS-211 R4 — ARCHITECT lens

## Task

R4 architect re-audit. R3 surfaced 1 MEDIUM (SPEC-005 stale
references); R4 swept §1.4 cross-spec boundaries to v1.5.0/v0.9.1
and aligned the live SPEC-005 §4.2/§8.2/§15.2/AC-D10/OQ-1 to
NULL-with-NULL clustering language.

Branch: `spec/iss-211-coordinator-account-scope`.

## R4 deltas (relative to R3)

- SPEC-002 v1.5.0 change-log bullet "Money-path scope" expanded
  to name all three IMPL sites (hotpath, recovery, endpoints
  admin reconcile) and IS-NULL clustering semantics.
- SPEC-002 v1.5.0 §11 "Money-path: AttemptN derivation"
  rewritten to call out all three sites and IS-NULL clustering.
- SPEC-005 v0.3.1 §1.4 "Cross-spec boundaries" SPEC-002 and
  SPEC-006 sub-blocks updated to current versions + IS-NULL
  clustering note.
- SPEC-005 v0.3.1 lines 520, 593, 956, 1032, 1213, 1270, 2323,
  2388 updated to SPEC-002 v1.5.0 / SPEC-006 v0.9.1 (live body
  references; changelog references intentionally left at
  v1.3.4/v0.8.2).
- SPEC-005 v0.3.1 §4.2, §8.2, §15.2, AC-D10, OQ-1 all reworded
  to NULL-with-NULL clustering language.
- `hotpath.go` aligned with recovery.go / endpoints.go.

## What to audit

1. Is the SPEC-002 + SPEC-005 + SPEC-006 corpus now telling a
   single coherent story about the v1.5.0 grouping rule and
   NULL-with-NULL semantics? Cross-check every live body claim
   about attempt-ordinal grouping, request_log scanning, or
   reconciliation.
2. Does the SPEC-002 v1.5.0 "Deploy ordering" / "rollback row-
   level gate" guidance still hold after the R4 NULL-with-NULL
   change? Specifically: pre-v1.5.0 rows have NULL account_id;
   under IS-NULL clustering they cluster together. Post-v1.5.0
   gateway rows have non-NULL account_id; they cluster within
   their account. The boundary between these populations is
   the gateway upgrade event. Is the deploy ordering text
   still safe for a coordinator that has the column but no
   live gateway sending the header yet?
3. Are there remaining SPEC-005 stale references the architect
   should still flag (e.g., changelog entries vs live body)?
4. The R4 wording "all three sites MUST use identical NULL
   semantics" is a normative MUST. Is this enforceable via
   tests, or does the SPEC need to enumerate the three sites
   by name so future maintainers can verify?

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
