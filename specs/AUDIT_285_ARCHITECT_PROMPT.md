# AUDIT PROMPT - Issue #285 Architect Lane

Audit the implementation for issue #285 from a reconciler architecture and semantics perspective.

Scope:

- `test/network-harness/internal/reconcile/ledger.go`
- `test/network-harness/internal/reconcile/ledger_test.go`
- Audit prompt files under `specs/`

Semantic questions:

1. Does the harness reconciler now agree with SPEC-006 section 17.7 settlement outcome semantics for fallback outcomes?
2. Is it correct for fallback gateway rows to attach exact coordinator 2xx rows when the provider completed cleanly enough for coord to write a 2xx request_log row?
3. Is it still correct for fallback gateway rows without coord rows to avoid `MatchedCoordMissing`, because provider death before coord logging is legitimate?
4. Is the gateway-vs-coordinator drift guard the right shape: signed net always accumulates, but overbill/mismatch I1 signals only count `"ok"` pairs?
5. Would this behavior be better represented as a separate per-outcome decision, or is the existing `isGatewayOKOutcome` guard appropriate for the current issue scope?
6. Did the change avoid widening matching semantics or changing gateway/coordinator behavior outside the harness reconciler?

Implementation details to verify:

- `attachCoord` uses `isSettlementComplete` for the initial coord attachment gate.
- Fallback exact-id coord attachment is allowed; fallback fuzzy coord attachment is not.
- `MatchedCoordMissing` remains gated on `isGatewayOKOutcome`.
- `collectUnmatchedCoord2xx` remains a leftover-pool orphan signal.
- `isSettlementComplete` and `isGatewayOKOutcome` remain unchanged.

Report:

- PASS only if there are 0 CRITICAL, 0 HIGH, and 0 MEDIUM findings.
- LOW findings may ship; list them clearly.
- Include concrete file/line references for every finding.
