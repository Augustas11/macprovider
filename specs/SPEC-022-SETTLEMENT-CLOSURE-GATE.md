# SPEC-022 Settlement Closure Gate

Status: implementation gate
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
- Before closure, run the gateway targeted tests plus the coordinator SPEC-022
  money-gate tests, then run the three Codex auditor lanes and resolve all
  critical/high/medium findings.
