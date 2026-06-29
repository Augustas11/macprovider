# AUDIT — ISS-211 R7 — ARCHITECT lens

## Task

R7 architect re-audit. R6 surfaced 1 HIGH + 3 MEDIUM. The HIGH
and 2 of the 3 MEDIUMs are in SPEC-007 which is owned by PR #221
and intentionally deferred from #224. The third MEDIUM (SPEC-005
fixture appendix at line 2423) is addressed.

Branch: `spec/iss-211-coordinator-account-scope`.

## R7 deltas

- `specs/SPEC-005-billing.md` AC-MULTIHOP fixture-detail
  appendix and AC-ATTEMPT-FALLBACK fixture-detail appendix
  updated to `(account_id, request_id)` grouping language
  matching the main AC body at lines 1299-1311.

## Explicit deferrals to PR #221

- SPEC-007 §1241 / §1591 (gateway session-detail account-blind
  text) — addressed by PR #221's §6.4 v0.2.1 addendum.
- SPEC-007 AC-7 — to be picked up by PR #221 audit loop.

## What to audit

1. Is the SPEC-002 + SPEC-005 + SPEC-006 corpus fully internally
   consistent on the v1.5.0 model, with no remaining stale
   text claiming `request_id` alone is the row key, reconciliation
   key, or grouping key for cross-account queries?
2. Do the deferrals to PR #221 leave any #224-internal gap?
   (i.e., does ANYTHING in SPEC-002 / SPEC-005 / SPEC-006 depend
   on SPEC-007 v0.2.1 text that won't exist until #221 merges?)
3. After the R6 conceptual reframe, is the SPEC narrative
   actually a tighter and more accurate description of what
   the IMPL does, or did the reframe expose anywhere the IMPL
   should be reconsidered?

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

- SPEC-007 (owned by PR #221).
