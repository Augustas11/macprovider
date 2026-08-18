# JOURNEY-BUYER-ENFORCE

Status: isolated harness; no signed promotion; does not flip production Pearl
Owner: verified-model settlement
Specs: SPEC-022
Requirements: SPEC-022-R007, SPEC-022-R008, SPEC-022-R009, SPEC-022-R011
Authority domains: verified-model-settlement
Issue: https://github.com/Augustas11/macprovider/issues/1044
Evidence owner: https://github.com/Augustas11/macprovider/issues/1044
Harness: `test/integration/buyer_enforce_journey_test.go` (`TestJourneyBuyerEnforceIsolatedCandidate`); capture with `MACPROVIDER_CAPTURE_BUYER_ENFORCE=1`. A passing harness is not a signed journey-result.

## Purpose

This journey is the physical evidence contract for SPEC-022 enforce-mode
money-gate requirements that `JOURNEY-BUYER-PAID-PATH` must not promote
from observe mode:

- reservation-first buyer debit; final debit only after a verified receipt
  (SPEC-022-R008);
- quarantine / pending-deadline releases the reservation and keeps payout
  exclusion (SPEC-022-R007);
- request-start policy pinning; rollback to observe does not rewrite
  already-enforced rows (SPEC-022-R009);
- structured per-attempt settlement audit without raw prompt, output, or
  receipt material (SPEC-022-R011).

Isolated YAML may set `verified_model_settlement_mode: enforce` with
`settlement.job_enabled: false`. This is not Pearl / production activation.

## Out of scope

- Promoting SPEC-022-R007 / R008 / R009 / R011 from a local test without a
  signed journey-result.
- Flipping production Pearl or any live `verified_model_settlement_mode`.
- Running the settlement job (`job_enabled: true`) or inserting
  `ledger_payout_ready` rows.
- Observe-mode paid-path evidence (`JOURNEY-BUYER-PAID-PATH`).
- Crash recovery (`JOURNEY-BUYER-CRASH-RECOVERY`).

## Preconditions

- Isolated candidate environment: temp coordinator/gateway SQLite, loopback
  binaries, API-key subject, `settlement.job_enabled: false`,
  `settlement.verified_model_settlement_mode: enforce`.
- Do not target production coordinator, gateway, or ledger.
- Record `pending_deadline_seconds` (this harness uses 1s so the missing-
  receipt path can close without a 300s wait).

## Physical steps

1. `step-01-capture-config` — Isolated candidate, enforce mode, job
   disabled, short pending deadline, API-key subject.
2. `step-02-verified-debit` — Streaming `POST /v1/chat/completions` with a
   settlement-capable receipt. Gateway reservation settles only after
   coordinator `receipt_verification_outcome == verified` (R008).
3. `step-03-payout-exclusion` — `ledger_payout_ready` remains empty.
   `job_enabled` stayed false. Verified rows are not payout-ready from this
   harness (R007).
4. `step-04-missing-receipt-quarantine` — A second streaming request omits
   the settlement receipt. After `pending_deadline_seconds` the attempt is
   `quarantined`, the gateway reservation is refunded, and provider credit
   stays excluded from payout (R007 / R008).
5. `step-05-policy-pinning` — Rewrite coordinator YAML to observe and
   restart. Already-enforced ledger rows retain
   `settlement_policy_mode=enforce`; verdict rows retain
   `route_snapshot_mode=enforce` (R009).
6. `step-06-audit` — `audit_log` settlement-verdict events contain
   structured policy/outcome fields and do not contain raw prompts,
   outputs, receipt signatures, or receipt public keys (R011).
7. `step-07-restore-config` — Confirm the harness did not enable the
   settlement job and produced no payout-ready rows. Production Pearl was
   not touched.

## Pass criteria

Mapped SPEC-022-R007 / R008 / R009 / R011 may be proposed for promotion
only from a signed journey-result against a named candidate. This isolated
harness is the physical step contract, not the promotion evidence.
