# SPEC-022 implementation deliverable 13

Status: automatic gateway settlement reconciliation implemented and locally
validated.

## Result

D13 closes the D12 retained gap where held enforce-mode gateway reservations
could be reconciled only by an operator-triggered admin sweep.

- Gateway config exposes settlement reconcile enablement, interval, batch
  limit, and request timeout.
- Config validation fails closed for enabled reconciliation with zero interval,
  invalid batch limit, or zero request timeout.
- Gateway startup launches the settlement reconciler when
  `settlement.reconcile_enabled` is true.
- The reconciler runs once immediately at startup, then again on each
  configured interval until gateway shutdown context cancellation.
- Each worker run wraps the shared reconciliation call in the configured
  timeout and batch limit.
- The admin `/admin/settlement/reconcile` endpoint and the background worker
  share `ReconcileSettlementHolds`, so verified, refund, hold,
  coordinator-missing, and terminal-race behavior stays identical across manual
  and automatic paths.
- Coordinator 404 finality for an already marked settlement hold refunds the
  reservation instead of leaving an unbounded active hold.
- Worker logging emits structured reconciliation counts when it scans held
  reservations or encounters errors.

## Acceptance movement

- **AC-022-14:** stronger movement. Pending or missing receipt finality no
  longer requires an operator to revisit held gateway reservations after the
  coordinator reaches a terminal verdict.
- **AC-022-31:** stronger movement. The automatic worker reuses the same
  idempotent terminal-reservation handling as the admin sweep.
- **AC-022-33:** stronger movement. Internal verified finality can finalize
  buyer debit through a continuously running gateway path instead of an
  operator-only endpoint.
- **AC-022-39:** stronger movement. Buyer-debit reconciliation is automatic and
  still reads coordinator receipt finality, while provider payout remains gated
  by `spec022_payable_request_credits`.
- **AC-022-47 / AC-022-52:** partial movement. The worker proves bounded
  automatic settlement/refund/hold processing, but full multi-worker and
  payout-sweep race harnesses remain separate acceptance coverage.

## Tests

Validated with:

```bash
cd phase5-gateway && go test -count=1 ./cmd/gateway -run 'TestRunSettlementReconcilerRunsImmediately|TestRunSettlementReconcilerRunsOnInterval|TestNewHTTPServerAppliesTimeouts'
cd phase5-gateway && go test -count=1 ./internal/config -run 'TestSettlementReconcileDefaults|TestSettlementReconcileConfigValidation'
cd phase5-gateway && go test -count=1 ./internal/router -run 'TestSPEC022GatewaySettlementReconcile|TestSPEC022GatewayStreamingSettlementTrailersControlBuyerDebit|TestSPEC022GatewayStreamingNonOKFinalityBoundsHold'
cd phase4-coordinator && go test -count=1 ./internal/billing -run 'TestSPEC022|TestRequestSettlementFinality|TestSettlementReceiptPendingCanCloseWithValidReceiptBeforeDeadline|TestRecordMissingSettlementReceiptQuarantinesAfterDeadlineAndLateReceiptNoops'
```

## Remaining gap

D13 does not claim the final SPEC-022 release gate. The remaining closure work
is the full race harness for stream completion, receipt arrival, settlement
sweep, and payout sweep, plus any still-open AC-022 rows in the acceptance
coverage table.
