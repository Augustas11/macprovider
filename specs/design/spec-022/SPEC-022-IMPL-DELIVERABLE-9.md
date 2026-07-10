# SPEC-022 implementation deliverable 9

Status: coordinator provider-credit settlement gate implemented and locally
validated. Full buyer-debit finality remains open because the gateway still
settles quota/usage from coordinator response completion rather than consuming
a verified/quarantined/zero-settled coordinator receipt outcome.

## Result

D9 adds the first money-path enforcement primitive for SPEC-022 enforce-mode
route-snapshot rows:

- `spec022_payable_request_credits` is now the coordinator's payable-credit
  view.
- The production buyer route-snapshot and ledger writers now derive their
  mode from `settlement.verified_model_settlement_mode`, which defaults to
  `enforce`; operators can explicitly set `observe` to keep the non-money-
  affecting observation path.
- In enforce mode, route-snapshot prerequisite failures such as missing
  provider receipt keys, invalid model hashes, missing catalog material, or
  unverified catalog/hash state fail closed before provider dispatch instead
  of falling through to legacy payable credit.
- Legacy and observe-mode rows keep the existing SPEC-005 payout path; observe
  mode remains non-money-affecting.
- Enforce-mode rows become payable only when the ledger row's account-scope
  hash and policy version match a terminal `verified`
  `settlement_receipt_verdicts` row, the matching route snapshot is
  enforce-mode with the same policy version, and the matching
  `settlement_attempt_outputs` row is not overlapping or duplicate.
- Startup/nightly recovery preserves enforce/observe mode from the persisted
  route snapshot when it recreates a missing ledger credit, rather than
  downgrading covered rows to legacy.
- Settlement sweeps aggregate and mark settled only through that payable view.
- Admin/provider credit summaries and provider earnings read provider-positive
  credit from the payable view, so pending/quarantined/overlap rows do not
  appear as earned provider compensation.
- Payout claim revalidates source rows before consumption and recomputes a
  mixed payout when some source credits are no longer payable; non-payable
  sources are released, and remaining valid sources stay claimable.

## Acceptance movement

- **AC-022-16 / AC-022-23 / AC-022-52:** partial movement from
  blocked toward covered on the coordinator provider-credit side. Pending,
  quarantined, account-mismatched, missing-snapshot, and overlap-blocked
  enforce-mode rows do not enter payout-ready aggregation or provider-credit
  summary surfaces. Recovery preserves the route snapshot's enforce policy.
- **AC-022-39:** partial movement only for coordinator payout-ready generation
  and claim-time source revalidation. Full acceptance still needs the gateway
  buyer-debit outcome contract before this can be marked covered.
- **AC-022-31:** duplicate receipt resubmission remains idempotent against the
  provider payout path; a terminal verified row cannot create a second payout
  after rerun.
- **AC-022-8 / AC-022-13 / AC-022-15 / AC-022-33 / AC-022-63:** still blocked
  for full-product closure until the gateway buyer-debit path consumes
  coordinator receipt outcomes instead of settling independently.

## Tests

Validated with:

```bash
cd phase4-coordinator && go test -count=1 ./internal/billing -run 'TestSPEC022PayableCreditGate|TestSettlement_Idempotency|TestSettlement_RollsForwardBelowThresholdCredits|TestBillingSummary|TestProvider'
cd phase4-coordinator && go test -count=1 ./internal/billing -run 'TestSPEC022PayoutClaim'
cd phase4-coordinator && go test -count=1 ./internal/billing
cd phase4-coordinator && go test -count=1 ./...
cd phase5-gateway && go test -count=1 ./...
```

## Remaining gap

The coordinator now blocks provider-positive money movement for covered rows
until receipt verification succeeds. The gateway still needs a durable
settlement-outcome contract for buyer quota finality: pending should hold the
reservation, verified should finalize debit, and quarantined/zero-settled
should release or refund. D9 does not claim that buyer-side gate is closed.
