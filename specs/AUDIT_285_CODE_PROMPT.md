# AUDIT PROMPT - Issue #285 Code Lane

Audit the implementation for issue #285:

- Scope should be limited to:
  - `test/network-harness/internal/reconcile/ledger.go`
  - `test/network-harness/internal/reconcile/ledger_test.go`
  - this audit prompt file and sibling audit prompt files under `specs/`
- The change is harness-only. No gateway, coordinator, or normative SPEC changes are in scope.

Build intent:

1. `attachCoord` must attach coordinator 2xx rows to settlement-complete fallback gateway pairs when the coord row exact-matches the harness request id via `external_request_id`.
2. Fallback pairs without coord rows must not be reported in `MatchedCoordMissing`.
3. Gateway-vs-coordinator overbill and absolute mismatch signals must be guarded to gateway outcome `"ok"` only, while `NetGatewayMinusCoordinatorTokens` still accumulates for all matched coord pairs.
4. Existing `MatchedCoordMissing` behavior for `"ok"` pairs with no coord row must remain intact.
5. `collectUnmatchedCoord2xx` must remain unchanged and still flag genuinely orphan coord 2xx rows.

Implementation details to verify:

- `attachCoord` now checks `isSettlementComplete(pair.GatewayOutcome)` before attempting coord attachment.
- Exact-id coord attachment still uses `pickExactCoordByRequestID` and preserves the `exactPickAmbiguous` path.
- Fuzzy coord matching remains restricted to gateway `"ok"` outcomes so fallback rows cannot steal unrelated coord rows by token/timestamp proximity.
- `isSettlementComplete` and `isGatewayOKOutcome` are unchanged.
- No matching strategy functions (`matchPairs`, `pickExactGwByRequestID`, `pickClosestGw`) were changed.
- `computePerPairDrift` still always accumulates `NetGatewayMinusCoordinatorTokens`, but only updates `GatewayOverbillVsCoordinatorTokens`, `AbsGatewayCoordinatorMismatchTokens`, and `GatewayCoordMismatchedPairs` for `"ok"` pairs.

Required tests to verify:

- `TestAttachCoord_PairsFallbackOutcomeWithCoord2xx`
- `TestAttachCoord_FallbackWithoutCoord_NotFlaggedAsMissing`
- `TestAttachCoord_OKOutcomeWithoutCoord_FlaggedAsMissing`
- `TestAttachCoord_OKOutcomeOverbillStillCounted`
- Existing reconciler tests still pass with `go test -count=1 ./internal/reconcile/...` from `test/network-harness`.

Report:

- PASS only if there are 0 CRITICAL, 0 HIGH, and 0 MEDIUM findings.
- LOW findings may ship; list them clearly.
- Include concrete file/line references for every finding.
