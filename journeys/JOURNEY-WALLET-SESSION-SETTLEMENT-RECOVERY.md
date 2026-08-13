# JOURNEY-WALLET-SESSION-SETTLEMENT-RECOVERY

Mapped SPECs: SPEC-040, SPEC-005, SPEC-022
Mapped authority domains: wallet-buyer-session, billing-settlement-formula, verified-model-settlement
Issue: https://github.com/Augustas11/macprovider/issues/930
Status: local automated evidence captured; production evidence pending

## Purpose

This journey proves wallet-session settlement composes with existing account
quota, usage, settlement journal, coordinator request-log, receipt, and billing
surfaces. Local automated evidence is captured in
`journeys/evidence/JOURNEY-WALLET-SESSION-LOCAL-VALIDATION-2026-08-13.md`.

## Required capture

- Candidate commit, gateway/coordinator identities, database identities, and
  request id.
- Account reservation, session reservation, replay record, and immutable
  account/request-to-session mapping created before dispatch.
- Successful usage row joined as gateway `usage_events.(account_id,
  request_id)` to coordinator `request_log.(account_id, external_request_id)`.
- Provisional dispatch-arm records created before coordinator dispatch and
  carrying session/reservation identity without guessed final token totals.
- Failure-injection cases for provisional arm failure before dispatch, crash
  after dispatch arm before coordinator dispatch, crash after coordinator
  dispatch before first buyer byte, crash after first streaming byte before
  final usage, finalization failure, settle failure, fallback usage insertion,
  refund, hold/quarantine, and recovery.
- Proof that wallet-session traffic does not fail open to coordinator dispatch
  when provisional recovery arming fails, and that finalization failure after
  delivered bytes stops further delivery where possible while keeping
  account/session exposure held or quarantined through the provisional arm.
- Final idempotent state proving account and session effects match after
  recovery.
- Repeated admission attempts while held, quarantined, stale-held, or
  recovery-pending session effects exist proving those effects still count
  toward session exposure.
