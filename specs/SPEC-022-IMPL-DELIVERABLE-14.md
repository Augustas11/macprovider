# SPEC-022 implementation deliverable 14

Status: settlement and payout idempotency hardening implemented and locally
validated.

## Result

D14 closes the highest-value remaining race/idempotency gap in the coordinator
money path: a provider payout claim now revalidates that every ready payout row
is backed by current SPEC-022 payable source rows, and that the ready payout
amounts still match those source rows, immediately before consumption.

- Duplicate verified receipts after settlement remain terminal no-ops and do
  not create a second payout row, provider credit, or settled source row.
- Concurrent settlement workers settle the same verified source row once and
  produce one payout-ready row with one settlement id.
- Manually inserted `ledger_payout_ready` rows with no verified source rows are
  deleted and audited as failed claims.
- Ready payout rows whose gross/provider/operator totals were manually inflated
  are recomputed from `spec022_payable_request_credits`, audited as failed, and
  must be claimed again with the corrected verified total.
- Existing post-ready source revalidation still releases source rows that later
  become non-payable or below the minimum payout threshold.

## Acceptance movement

- **AC-022-27:** stronger movement. The coordinator now has deterministic
  receipt-after-settlement and concurrent-settlement ordering coverage for the
  settlement/payout path.
- **AC-022-31:** covered for coordinator settlement/payout. Duplicate verified
  receipt replay after settlement is a terminal no-op and does not double buyer
  debit/provider payout eligibility.
- **AC-022-39:** covered for payout-ready bypass. Manual money-positive payout
  rows cannot be consumed without verified payable sources, and inflated ready
  rows are corrected from the verified source rows before any payout claim can
  succeed.
- **AC-022-52:** stronger movement. Concurrent settlement workers produce one
  final settlement id and one payout-ready insertion for one verified row.
- **AC-022-63:** stronger movement. Successful payout claims now depend on the
  same receipt-bound payable source rows that settlement created.

## Tests

Validated with:

```bash
cd phase4-coordinator && go test -count=1 ./internal/billing -run 'TestSPEC022(DuplicateVerifiedReceiptAfterSettlementDoesNotDoublePay|ConcurrentSettlementWorkersSettleVerifiedRowOnce|PayoutClaimRejectsManualReadyRowWithoutVerifiedSources|PayoutClaimRevalidatesReadyRowTotals|PayoutClaimRevalidatesSourceRows|PayoutClaimRecomputesMixedSources|PayoutClaimReleasesRemainderBelowMinimum)'
cd phase4-coordinator && go test -count=1 ./internal/billing
cd phase4-coordinator && go test -count=1 ./...
git diff --check
```

## Remaining gap

D14 does not replace the final full-network e2e pass. The remaining closure work
is to run a cross-service stream completion, receipt arrival, gateway
reservation, settlement worker, and payout claim scenario after the SPEC-022 PR
is packaged.
