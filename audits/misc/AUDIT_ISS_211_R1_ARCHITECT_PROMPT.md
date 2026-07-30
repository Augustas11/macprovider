# AUDIT — ISS-211 R1 — ARCHITECT lens

## Task

Architect-lens audit of the SPEC + IMPL bundle for issue #211.

Branch: `spec/iss-211-coordinator-account-scope`.

### Focus areas

1. **SPEC corpus coherence.** Do SPEC-002 v1.5.0, SPEC-006 v0.9.1,
   and the unchanged SPEC-007 v0.2.1 (already in flight on PR
   #221 / spec/iss-212-explorer-composite-pk) tell one consistent
   story about `(account_id, request_id)` as a physical reconciliation
   identity on both sides? Specifically:
   - SPEC-007 v0.2.1 §2.8 (in PR #221) carries the line "Coordinator
     request_log still keys reconciliation by buyer-supplied
     external_request_id alone (no account_id scope). Tracked in
     issue #211." If both PRs merge in either order, what is the
     stale-pointer outcome and is it acceptable?
   - SPEC-002 v1.5.0 references "SPEC-007 §6.4 v0.2.1 addendum (#196)"
     which only exists once PR #221 merges. Should the dependency
     line note this?

2. **Deploy ordering.** SPEC-002 v1.5.0 mandates "coordinator
   first, then gateway". Is the ordering robust to:
   - A coordinator that has the column but no live index yet
     (post-deploy / pre-migrate-indexes window)?
   - A gateway that sends the header before the column landed
     (the header is silently ignored)?
   - A rollback: what happens if v1.5.0 coordinator rolls back to
     v1.4.x with the new column already in place?

3. **Version-bump shape.** This is the first normative MUST added
   to the gateway-coordinator forward contract since v1.4.2 R-2
   shipped without a change-log entry (referenced as "v1.4.2 R-2"
   in code but absent from the SPEC body — subject of ISS-197).
   Is `v1.5.0` correct or should this be `v1.4.3` to match #197's
   in-flight numbering? Argue from the corpus convention
   (substantive normative change → minor bump; clarification →
   patch bump).

4. **Money-path scoping.** Are there OTHER coordinator queries
   over `request_log` that should also be account-scoped to
   preserve the audit-trail integrity SPEC-002 v1.5.0 claims?
   Specifically check:
   - `phase4-coordinator/internal/explorer/store.go`
     `SessionDetail` / `RecentSessions`.
   - `phase4-coordinator/internal/billing/store.go` reconciliation
     queries that join request_log by request_id.
   - SPEC-005 v0.3 attempt-attribution paths (if discoverable from
     the spec).
   If any are NOT being scoped here, is the deferral documented
   (e.g. the explorer is explicitly deferred to follow-up)?

5. **Cross-spec touch-ups missing.** Does this PR miss any of:
   - SPEC-005 (billing) reconciliation contracts?
   - SPEC-004 (retry) attempt-ordinal docs?
   - SPEC-002 §10 D-entries (D11 cross-service request
     correlation)?

### Severity bar

Report ONLY CRITICAL / HIGH / MEDIUM. Each finding:
```
SEVERITY: ...
TITLE: ...
FILE: <path:line>
DETAIL: ...
SUGGESTED FIX: <minimal>
```

If zero findings, respond exactly: `ZERO FINDINGS`.

### Out of scope
- Re-evaluating the Option A vs B vs C choice from the issue.
- Demo-IP exposure (covered by security lens).
- Sanitizer character allowlist (covered by security lens).
