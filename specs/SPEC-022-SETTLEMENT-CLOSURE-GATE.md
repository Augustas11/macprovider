# SPEC-022 Settlement Closure Gate

Status: implemented and locally validated
Scope: SPEC-022 verified model settlement

## Objective

Close the trust-critical money path by making settlement finality automatic:
buyer debits and provider payout eligibility must depend on coordinator
settlement finality backed by signed, catalog-matching receipt verdicts.

## In Scope

- Gateway-held `settlement_hold` reservations are reconciled automatically by a
  background worker, not only by the operator admin endpoint.
- The worker calls the coordinator internal settlement finality endpoint with a
  bounded interval, batch limit, and request timeout.
- Closed verified finality may settle exactly one held gateway reservation using
  coordinator-observed token totals.
- Closed quarantined, zero, missing, invalid, or deadline-elapsed finality must
  refund the held reservation.
- Open pending finality must keep the reservation held and clamp expiry to the
  coordinator-provided pending deadline.
- Coordinator payout and revenue surfaces must continue to read from
  `spec022_payable_request_credits`, which excludes enforce-mode rows without a
  closed verified receipt verdict and excludes overlapping output claims.
- Payout claim consumption must revalidate settled, provider-matching
  payout-ready source rows and totals against `spec022_payable_request_credits`
  immediately before marking a payout consumed.
- Settled request-credit money fields must be immutable so claim-time
  recomputation cannot be inflated after settlement.

## Out of Scope

- Broad buyer-facing receipt UI and dashboard polish.
- Full observability dashboards beyond structured worker logging and existing
  reconciliation counters.
- Re-running Claude auditors before the full SPEC-022 implementation is ready.

## Acceptance Gate

- Gateway config exposes settlement reconcile enablement, interval, batch limit,
  and request timeout with fail-closed validation.
- Gateway startup launches the settlement reconciler when enabled.
- The reconciler runs once immediately on startup and then on its interval.
- The admin `/admin/settlement/reconcile` endpoint and the worker share one
  settlement reconciliation implementation.
- Tests cover config defaults/validation, immediate worker execution, and the
  existing verified/refund/hold/terminal-race reconciliation cases.
- Existing coordinator money-gate tests continue to prove payout eligibility is
  receipt-bound.
- Coordinator tests cover duplicate receipt replay after settlement,
  same-process settlement workers for one verified source row, manual
  source-less payout rows, forged source links, settled-source immutability, and
  inflated ready payout totals.
- Before closure, run the gateway targeted tests plus the coordinator SPEC-022
  money-gate tests, then run the three Codex auditor lanes and resolve all
  critical/high/medium findings.

## Implementation Evidence

- `phase5-gateway/internal/config/config.go` exposes
  `settlement.reconcile_enabled`, `settlement.reconcile_interval_s`,
  `settlement.reconcile_batch_limit`, and
  `settlement.reconcile_request_timeout_s`, and validates enabled
  configurations fail closed.
- `phase5-gateway/cmd/gateway/main.go` starts `runSettlementReconciler` when
  enabled, using the configured interval, batch limit, and per-run request
  timeout.
- `runSettlementReconciler` runs once immediately, then on each interval until
  gateway shutdown context cancellation.
- `phase5-gateway/internal/router/settlement_reconcile.go` keeps the admin
  endpoint and background worker on the shared `ReconcileSettlementHolds`
  implementation.
- `phase5-gateway/internal/router/server_test.go` keeps the verified, refund,
  hold, and terminal-race reconciliation cases covered.
- `phase4-coordinator/internal/billing/payout.go` revalidates ready payout rows
  against settled provider-matching sources in `spec022_payable_request_credits`
  before consumption.
- `phase4-coordinator/internal/billing/store.go` rejects money-field mutation
  after a request credit is settled.
- `phase4-coordinator/internal/billing/spec022_money_gate_test.go` covers
  duplicate receipt replay, same-process settlement-worker idempotency,
  source-less manual payout rejection, forged source rejection, settled-source
  immutability, and payout total recomputation.
