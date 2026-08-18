# JOURNEY-BUYER-CRASH-RECOVERY

Status: isolated harness; no signed promotion
Owner: billing crash recovery
Specs: SPEC-005
Requirements: SPEC-005-R003
Authority domains: billing-settlement-formula
Issue: https://github.com/Augustas11/macprovider/issues/1043
Evidence owner: https://github.com/Augustas11/macprovider/issues/1043
Harness: `test/integration/buyer_crash_recovery_journey_test.go` (`TestJourneyBuyerCrashRecoveryIsolatedCandidate`); capture with `MACPROVIDER_CAPTURE_BUYER_CRASH_RECOVERY=1`. A passing harness is not a signed journey-result.

## Purpose

This journey is the physical evidence contract for SPEC-005-R003: crash
recovery of in-flight ledger rows. `JOURNEY-BUYER-PAID-PATH` cannot promote
this requirement because crash recovery is not one of its eleven steps.

The run reconstructs the durable identity-fallback state that
`WriteRequestLogWithIdentity` leaves after a failed `WriteHotPath`
(request_log + provider identity snapshot, no `ledger_request_credits`
row), then restarts the real coordinator binary against the same SQLite
file so `StartStartupScan` / `RecoverLedger` must recover it.

## Out of scope

- Promoting SPEC-005-R003 from a local test without a signed journey-result.
- Gateway quota crashes (SPEC-006).
- Settlement windows, payout-ready mutation, or SPEC-022 enforce.
- Production Pearl.

## Preconditions

- Isolated candidate environment: temp coordinator/gateway SQLite, loopback
  binaries, `settlement.job_enabled: false`,
  `settlement.verified_model_settlement_mode: observe`.
- Do not target production coordinator, gateway, or ledger.
- Record `recovery_grace_seconds` (default 30). Planted rows MUST be older
  than that grace so startup scan includes them.

## Physical steps

1. `step-01-capture-config` — Isolated candidate, observe mode, job
   disabled, coordinator SQLite identity recorded.
2. `step-02-stop-coordinator` — Stop the coordinator process. Gateway and
   fake provider may remain; they are not required after this step.
3. `step-03-plant-identity-fallback` — Insert the identity-fallback shape:
   `request_log` + `ledger_provider_identity_snapshots` for one request,
   timestamped older than `recovery_grace_seconds`, with no credit row.
4. `step-04-plant-orphan-credit` — Insert a `ledger_request_credits` row
   whose `request_id` has no matching request_log evidence, same window.
5. `step-05-startup-scan-recover` — Start the coordinator on the same DB.
   Require exactly one non-quarantined credit for the planted request with
   `recovery_source=startup_scan`, and a complete `startup_scan`
   reconciliation run that created that missing credit.
6. `step-06-orphan-quarantine` — The planted orphan credit is quarantined
   `missing_request_log`.
7. `step-07-idempotent-rescan` — Restart the coordinator again. The
   recovered request still has exactly one credit. No double credit.
8. `step-08-no-payout` — `ledger_payout_ready` remains empty.
   `job_enabled` stayed false. Mode stayed observe.

## Pass criteria

Mapped SPEC-005-R003 may be proposed for promotion only from a signed
journey-result against a named candidate. This isolated harness is the
physical step contract, not the promotion evidence.
