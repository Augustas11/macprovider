# JOURNEY-BUYER-PAID-PATH

Status: signed observe-mode promotion for SPEC-005-R001/R002, SPEC-006-R001..R003, SPEC-015-R001, SPEC-022-R001..R006, and SPEC-022-R010; no enforce promotion
Owner: buyer/billing/settlement conformance
Specs: SPEC-005, SPEC-006, SPEC-015, SPEC-022
Requirements: SPEC-006-R001, SPEC-006-R002, SPEC-006-R003, SPEC-005-R001, SPEC-005-R002, SPEC-005-R003, SPEC-015-R001, SPEC-022-R001, SPEC-022-R002, SPEC-022-R003, SPEC-022-R004, SPEC-022-R005, SPEC-022-R006, SPEC-022-R007, SPEC-022-R008, SPEC-022-R010
Authority domains: buyer-api-error-contract, billing-settlement-formula, inference-receipts, verified-model-settlement
Issue: https://github.com/Augustas11/macprovider/issues/614
Evidence owner: https://github.com/Augustas11/macprovider/issues/1022
Retrieval evidence owner: https://github.com/Augustas11/macprovider/issues/1042
Signed envelope: `journeys/evidence/buyer-paid-path-20260817T045519Z.spec-005-r001-spec-005-r002-spec-006-r001-spec-006-r002-spec-006-r003-spec-015-r001-spec-022-r001-spec-022-r002-spec-022-r003-spec-022-r004-spec-022-r005-spec-022-r010.journey-result.signed.json` (workflow [31996627496](https://github.com/Augustas11/macprovider/actions/runs/31996627496))
R006 signed envelope: `journeys/evidence/buyer-paid-path-20260818T051813Z.spec-022-r006.journey-result.signed.json` (workflow [32104641658](https://github.com/Augustas11/macprovider/actions/runs/32104641658))
Execution mode: isolated-candidate-paid-path
Harness: `test/integration/buyer_paid_path_journey_test.go` (`TestJourneyBuyerPaidPathIsolatedCandidate`); capture with `MACPROVIDER_CAPTURE_BUYER_PAID_PATH=1`. A passing harness is not a signed journey-result.

## Purpose

This journey defines the physical evidence required to reconcile the
authenticated API-key paid path: chat admission, quota reservation and
refund/settlement, ledger credit, v0.4 receipt issuance/ingestion, and
SPEC-022 settlement outcome under the current observe-mode posture.

This document is a test contract. It is not evidence that the journey has
passed, that SPEC-022 enforce is permitted, or that any mapped requirement is
conformant.

## Out of scope

- Provider install, referral, autotune, hardware admission, or serving smoke
  used only to prove an onboarded provider is routable
  (`JOURNEY-PROVIDER-PREBETA-ADMISSION`).
- Payout-address registration, cooling-off, runner, hot-wallet funding, or
  on-chain USDC (`JOURNEY-SPEC-016-PAYOUT-ADDRESS-REGISTRATION` / SPEC-016
  execution).
- Wallet-session inference (`JOURNEY-WALLET-SESSION-*` / SPEC-040).
- Demo-token traffic as a substitute for a paid API key.
- SPEC-002-R002 trusted-provider quota (provider admission, not buyer debit).
- Exhaustive remaining SPEC-005/006/015 clause coverage (issue #1023).
- Crash recovery / SPEC-005-R003: not one of the eleven physical steps;
  this harness cannot promote it.
- Promoting SPEC-022-R007 or SPEC-022-R008 from this observe-mode run.
  Enforce money-gate evidence is `JOURNEY-BUYER-ENFORCE` (issue #1044).

## Preconditions

- Run against a named candidate commit or release artifact, with the exact
  commit recorded in the result.
- Execute against an isolated candidate environment with its own coordinator
  and gateway databases. The run MUST NOT target the production coordinator,
  production gateway, or the production ledger, even through a namespaced
  view. The settlement runner MUST NOT be constructed, and no settlement
  window may be executed over the journey's request window. If this isolation
  cannot be established from the named candidate, mark the run blocked and
  produce no passing evidence.
- Use an isolated test buyer account with a disposable API key and a known
  starting quota. Do not spend a production operator wallet.
- Capture the effective settlement policy before and after the journey:
  `settlement.verified_model_settlement_mode` must remain `observe` and
  `settlement.job_enabled` must remain false. Ledger
  `settlement_policy_mode` on payable rows must also stay `observe`.
- Note: `settlement.mode: observe` does not prevent money movement.
  Observe-mode ledger credits remain payable and can settle into
  `ledger_payout_ready`. Environment isolation, not observe mode, is what
  prevents payout obligation from this journey.
- Use a short-lived buyer API key through the approved secret-injection
  mechanism. Do not place bearer tokens, private keys, or raw prompt/output
  material in logs, screenshots, result JSON, or uploaded artifacts.
- Record the candidate gateway and coordinator identities, rate-card digest,
  and active signed catalog identity from the system under test.
- If the run cannot distinguish a paid API-key subject from demo or wallet
  session, mark the run blocked and produce no passing evidence.

## Physical steps

1. `step-01-capture-config` — Capture the candidate version, effective
   gateway/coordinator configuration, settlement mode/version, starting buyer
   quota, and clean request identity. Confirm the buyer authenticates with an
   API key and that demo/wallet-session credentials are not in use.
2. `step-02-nonstream-chat` — `POST /v1/chat/completions` non-streaming with a
   tiny billed prompt against a currently routable catalog model. Require HTTP
   200, OpenAI-compatible `usage`, and a coordinator request id. Record
   redacted account/request fingerprints only.
3. `step-03-quota-settlement` — Confirm gateway quota: reservation was taken
   at request start and settled (not leaked) after the 200. Record
   before/after quota and the settlement journal outcome. This observe-mode
   settlement is not evidence that final debit waited for
   `receipt_verification_outcome == verified` (SPEC-022-R008).
4. `step-04-ledger-credit` — Confirm coordinator ledger: a
   `ledger_request_credits` row exists for the request/attempt, credits match
   SPEC-005 closed-form arithmetic for the persisted token fields and
   rate-card entry, and a 503/no-dispatch control would not have written a
   payable row. Do not run a settlement window.
5. `step-05-receipt-ingest` — Confirm a provider-issued SPEC-015 v0.4
   settlement-capable receipt was ingested for the attempt, or record missing
   honestly; verifier outcome is one of `pending`, `verified`, `quarantined`,
   or `zero_settled`; raw prompt/output bytes are absent from buyer-visible
   and uploaded artifacts.
6. `step-06-streaming-chat` — Repeat steps 2-5 for a streaming
   `POST /v1/chat/completions` request. Require the stream to terminate
   cleanly and the settled completion tokens to equal the delivered
   fixture prefix, not an unbounded byte estimate.
7. `step-07-failure-refund` — Exercise a no-provider or pre-dispatch failure
   (or a recorded equivalent fixture against the named candidate). Require the
   buyer-visible error envelope (`error.code`, `error.retryable`) and a quota
   refund with no provider credit.
8. `step-08-disclosure` — `GET /v1/models` (or the candidate's buyer models
   surface) and record `tier1_disclosure.verified_model_settlement` /
   model-verification-limit text. Require observe-mode disclosure not to
   claim enforce.
9. `step-09-receipt-retrieval` — `GET /v1/receipts/{id}` for the owning
   API key after step 05 ingest. Require HTTP 200 with
   `schema_version=macprovider.buyer-receipt-view.v1`, `surface=metadata`,
   `pending_quarantined_visible=true`, and no raw prompt/output material.
   Unauthenticated GET MUST return 401. Unknown `request_id` MUST return
   404. Record `buyer_receipt_retrieval_exposed=true`. SPEC-022-R006
   promotion requires a signed journey-result against this step, not a
   local 200.
10. `step-10-redaction` — Inspect logs, ledger rows, receipt state,
    screenshots, callback captures, and exported artifacts for bearer tokens,
    private keys, raw prompts/outputs, or unintended production identifiers.
    Hash the redacted evidence set.
11. `step-11-restore-config` — Re-check effective settlement configuration.
    Confirm mode is unchanged from step 1, that this journey produced no
    payout-ready mutation, and that no enforce-mode flag was flipped.

## Required journey-result contract

The run must produce a redacted, signed result envelope containing:

- schema_version, journey_id `JOURNEY-BUYER-PAID-PATH`,
  requirement_ids, run_id, candidate commit/release, operator, environment
  class, and UTC timestamps;
- execution_mode `isolated-candidate-paid-path`;
- one result entry for every physical step above, using the `step-NN-...`
  identifiers, with pass/fail status, assertion identifiers, and SHA-256
  references to retained artifacts;
- starting and ending quota, ledger credit id fingerprints, receipt outcome,
  and rate-card/catalog identities sufficient to recompute the billed row
  without secrets, recorded in the redacted evidence artifact the signed
  envelope hashes;
- `requirement_ids` naming every requirement this run may promote; a single
  `spec_id` is not used because the journey spans SPEC-005/006/015/022;
- `observations.settlement_mode` (`observe`),
  `observations.enforce_activated` (false),
  `observations.payout_ready_mutated` (false),
  `observations.production_side_effects` (false),
  `observations.isolated_environment` (true),
  `observations.buyer_receipt_retrieval_exposed` (boolean),
  `observations.raw_prompt_output_redacted` (true),
  `observations.bearer_tokens_redacted` (true);
- signer identity and signature metadata, plus the verification result;
- final result, failure details when applicable, and the authorized
  journey-result signature.

Promotion tooling must verify the final result schema, candidate identity,
artifact hashes, signature, isolation attestations, and absence of secret
material before adding a journey evidence SHA to `specs/CONFORMANCE.json`.

This journey-result may not promote SPEC-022-R007 or SPEC-022-R008.
It may not promote SPEC-022-R006 while
`observations.buyer_receipt_retrieval_exposed` is false.

## Pass criteria

Mapped requirements may be proposed for promotion only when every in-scope
step passes, the signed result is reproducible against the named candidate,
all required artifacts are retained and redacted, and the release gate accepts
the evidence as fresh. A passing local test or observe-mode production sample
does not by itself authorize promotion or SPEC-022 enforce activation.

SPEC-022-R006 is promoted from the signed journey-result that records
`buyer_receipt_retrieval_exposed=true` against this reviewed contract.
SPEC-022-R001 cannot promote from an enforce-mode claim; this journey
requires captured mode `observe`.
SPEC-005-R003 cannot promote from this harness; crash recovery is not an
in-scope physical step.
SPEC-022-R007 and SPEC-022-R008 cannot promote from this observe-mode run,
because their money assertions apply to covered enforce traffic. Step 3's
settled reservation is observe behavior, not evidence for R-8.1.
