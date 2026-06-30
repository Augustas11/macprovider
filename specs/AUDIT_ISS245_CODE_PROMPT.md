# AUDIT — Issue #245 — CODE lane

## Goal
CODE-quality audit on commit `2743679` (branch `fix/iss245-spec007-v05-untyped-400`). Bar: 0 CRITICAL, 0 HIGH, 0 MEDIUM. LOW + INFO allowed.

## Scope (read these files only — do NOT propose changes outside)

- `specs/SPEC-007-explorer.md` — change-log row (v0.5), §5.6 path-segment paragraph, §6.4 path-segment paragraph
- `phase5-gateway/internal/router/explorer.go` — `handleExplorerSessionDetail` (lines ~94-145)
- `phase4-coordinator/internal/explorer/handlers.go` — `handleSessionDetail` (lines ~180-195); confirm `logPathSegmentUntyped` deleted
- `phase4-coordinator/internal/explorer/static/js/dashboard.js` — `linkFor` (line ~115, 119)
- `phase5-gateway/internal/router/iss231_test.go` — TestExplorerSessionDetail_409CapAndTruncationFlag, TestExplorerSessionDetail_ExtPrefixIsParsed, new TestExplorerSessionDetail_UntypedReturns400, new TestExplorerSessionDetail_EmptyExtPrefixReturns400
- `phase4-coordinator/internal/explorer/iss231_test.go` — TestSessionDetail_IntPrefixIsStripped, new TestSessionDetail_UntypedReturns400, new TestSessionDetail_EmptyIntPrefixReturns400
- `phase4-coordinator/internal/explorer/handlers_test.go` — TestAC07_SessionDetailIncludesLocalAndGatewayData, TestSessionDetailGatewayProxyUsesExternalRequestIDAndAccountID, TestSessionDetailGatewayProxySkippedOnIncompleteIdentity, TestSessionDetailNoCoordinatorRowReturns404, TestDashboardCrossViewLinkWiring, TestAC25_CoreExplorerRoutesTraverseSuccessfully

## Context

SPEC-007 v0.4 (#231) shipped path-segment typing in deprecation-window mode: `int_<request_id>` (coordinator) and `ext_<external_request_id>` (gateway) prefixes are typed, untyped (bare-id) calls were still accepted but emitted a `payout_explorer_path_segment_untyped` WARN audit row. v0.4 SPEC §5.6 + §6.4 normatively committed that v0.5 would reject untyped with `400 session_id_untyped`.

v0.5 (#245) implements that break:
- Both handlers return 400 invalid_request_error + code=session_id_untyped on `!typed` (gateway) or `!ok || stripped==""` (coordinator).
- The v0.4 audit/log emits are deleted (no longer reachable).
- The coordinator's dashboard.js now emits `int_`-prefixed URLs so coordinator-side navigations don't hit the new 400 gate.

## Lens — CODE

- Style consistency with house conventions
- Dead code: is anything left over from the deleted `logPathSegmentUntyped` / `payout_explorer_path_segment_untyped` emit path (unused imports, unused fields, vestigial test fixtures)?
- Symmetry: does the gateway 400 envelope shape match the coordinator's? Both should produce the `session_id_untyped` code; differing keys (`error.code` vs `error.message`) are a CODE finding.
- Test inversion completeness: do the new tests cover (a) untyped rejected, (b) empty-prefix rejected, AND (c) typed prefix still passes? The latter is the regression guard.
- dashboard.js migration: are there other static-asset callers of `/admin/explorer/sessions/` that emit untyped URLs (forms, HTMX targets, deep-link templates)?
- Old test renames vs new test additions — were the v0.4 deprecation-emit tests genuinely replaced (not just commented out)?

## Out of scope

- Security (SECURITY lane) — bypass paths, injection, error-leakage
- SPEC-alignment (ARCHITECT lane) — invariant ownership, migration plan

## Output format

```
SEVERITY-N (CRITICAL|HIGH|MEDIUM|LOW|INFO) — <one-line title>
File: <path>:<line>
Finding: <what>
Risk: <why>
Recommendation: <concrete fix>
```

At the end: `C/H/M/L/INFO = a/b/c/d/e`. If 0 C/H/M everywhere: `ACCEPT — 0 C/H/M`.
