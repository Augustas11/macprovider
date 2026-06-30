# AUDIT PROMPT - Issue #285 Security Lane

Audit the implementation for issue #285 from a security/adversarial perspective.

Scope:

- `test/network-harness/internal/reconcile/ledger.go`
- `test/network-harness/internal/reconcile/ledger_test.go`
- Audit prompt files under `specs/`

Threat questions:

1. Can a hostile or unrelated network actor cause a fallback gateway pair to attach an unrelated coordinator 2xx row?
2. Does the relaxed fallback coord attachment rely on exact `external_request_id` matching, or can it use fuzzy token/timestamp matching?
3. Are account-id consensus checks preserved for coordinator matching?
4. Is `exactPickAmbiguous` still surfaced through `AmbiguousExactCoordIDs` rather than falling through to a fuzzy match?
5. Can fallback coord rows evade `UnmatchedCoordinator2xxRows` only when they are genuinely consumed by the matched harness pair?
6. Do orphan coord 2xx rows with no matching gateway/harness row still remain in the leftover coord pool and get reported?

Implementation details to verify:

- `attachCoord` permits coord matching for settlement-complete fallback outcomes, but fuzzy coord matching remains gateway-`"ok"` only.
- `pickExactCoordByRequestID` remains the exact coord join and still requires:
  - non-empty harness request id
  - coord 2xx status
  - `coord.external_request_id == harness.RequestID`
  - exact settlement window
  - account-id guard through `rowAccountIDMatches`
- `rowAccountIDMatches` behavior is unchanged.
- `isSettlementComplete` and `isGatewayOKOutcome` are unchanged.

Report:

- PASS only if there are 0 CRITICAL, 0 HIGH, and 0 MEDIUM findings.
- LOW findings may ship; list them clearly.
- Include concrete file/line references and exploitability reasoning for every finding.
