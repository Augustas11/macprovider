# SPEC-022 implementation deliverable 12

Status: held gateway reservations can now be reconciled against coordinator
settlement receipt finality after streaming or non-streaming completion. The
path is operator-triggered through an internal admin sweep, not an automatic
background worker.

## Result

D12 closes the D11 retained gap where an enforce-mode gateway hold could be
bounded to the coordinator receipt deadline but could not later become a
verified buyer debit if the coordinator verified the receipt before expiry.

- The coordinator exposes an internal bearer-protected finality lookup by
  `(account_id, request_id)`.
- The finality lookup aggregates persisted `settlement_receipt_verdicts` rows
  for the request, closes expired open pending rows with the existing
  missing-receipt quarantine path, and returns a redacted aggregate outcome.
- Verified finality is settlement-capable only when rows are closed,
  `receipt_result=valid`, and canonical usage can be loaded from the matching
  coordinator-observed settlement attempt output.
- The aggregate excludes overlapping or duplicate attempt outputs from the
  debit total.
- Terminal `quarantined` and `zero_settled` outcomes are exposed as closed
  refund finality with no raw prompts, raw outputs, receipt signatures, or
  provider receipt keys.
- Gateway receipt-finality holds are now explicitly marked on quota
  reservations, so ordinary active in-flight reservations are not swept by
  reconciliation.
- The gateway adds `POST /admin/settlement/reconcile`, protected by operator
  auth, to scan marked settlement holds and query coordinator finality.
- The gateway converts closed verified finality into a single
  `spec022_verified` buyer usage row using `token_source=coordinator_observed`.
- The gateway refunds closed quarantined or zero-settled finality.
- The gateway preserves pending/open finality as a bounded hold using the
  coordinator pending deadline policy from D11.
- Missing coordinator state is skipped rather than locally debited.
- Gateway SQLite schema version v5 now accepts `coordinator_observed` usage
  rows and migrates existing v4 `usage_events` CHECK constraints in place.
- Gateway SQLite schema version v6 adds the `quota_reservations.settlement_hold`
  marker used to keep reconciliation scoped to SPEC-022 held reservations.

## Acceptance movement

- **AC-022-14:** stronger movement. A missing receipt can now move from pending
  to coordinator quarantine at deadline and then release/refund the gateway
  reservation through reconciliation.
- **AC-022-31:** partial movement. Gateway reconciliation treats already
  terminal reservations idempotently, but the full duplicate verified receipt
  plus payout-ready idempotency proof remains outside D12.
- **AC-022-33:** partial movement. Internal verified settlement can finalize
  buyer debit with buyer receipt retrieval still disabled, but D12 does not add
  a full provider-credit end-to-end assertion.
- **AC-022-39:** partial movement. Buyer debit now depends on the same
  coordinator receipt-verdict source used by provider-positive settlement, but
  payout-ingestion rejection tests for manually inserted money-positive rows
  remain separate.
- **AC-022-47:** partial movement. Reconciliation clears/refunds/holds active
  reservations deterministically, but concurrent agentic reservation and
  terminal-row race coverage remains separate.
- **AC-022-52:** partial movement. Gateway reservation settlement/refund is
  idempotent for terminal rows, but two settlement-worker/payout-ready
  concurrency remains unproven.
- **AC-022-63:** partial movement. Verified buyer debit uses coordinator
  canonical observed usage instead of provider-reported or gateway-estimated
  usage, but full normal-completion buyer-debit/provider-credit parity remains
  an end-to-end test gap.

## Tests

Validated with:

```bash
cd phase4-coordinator && go test -count=1 ./internal/billing -run 'TestRequestSettlementFinality|TestSettlementReceiptPendingCanCloseWithValidReceiptBeforeDeadline|TestRecordMissingSettlementReceiptQuarantinesAfterDeadlineAndLateReceiptNoops'
cd phase5-gateway && go test -count=1 ./internal/router -run 'TestSPEC022GatewaySettlementReconcile|TestSPEC022GatewayStreamingSettlementTrailersControlBuyerDebit|TestSPEC022GatewayStreamingNonOKFinalityBoundsHold'
cd phase5-gateway && go test -count=1 ./internal/storage/sqlite -run 'TestQuotaSettlementHoldColumnMigration|TestListSettlementHeldReservationsSkipsOrdinaryActive|TestClampReservationExpiryBoundsActiveHold|TestReservationErrorBranches|TestUsageEventsCoordinatorObservedSourceMigration|TestUsageEventsSqliteMasterByteIdenticalAcrossPaths|TestUsageEventsCompositePKAndSchemaV2CommitAtomically'
cd phase4-coordinator && go test -count=1 ./...
cd phase5-gateway && go test -count=1 ./...
```

## Remaining gap

D12 is an explicit operator/admin reconciliation sweep, not a continuously
scheduled background settlement worker. It does not yet provide the full
stream-completion, receipt-arrival, settlement-sweep, and payout-sweep race
harness required to close all SPEC-022 acceptance criteria for automatic
network operation.
