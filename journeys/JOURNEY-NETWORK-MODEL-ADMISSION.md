# JOURNEY-NETWORK-MODEL-ADMISSION

Status: draft journey contract; no implementation evidence
Owner: SPEC-047 network model admission conformance
Specs: SPEC-047
Requirements: SPEC-047-R001, SPEC-047-R002, SPEC-047-R003, SPEC-047-R004,
SPEC-047-R005, SPEC-047-R006, SPEC-047-R007, SPEC-047-R008
Authority domains: network-model-admission
Issue: https://github.com/Augustas11/macprovider/issues/1240
Execution mode: provider-byom-network-admission

## Purpose

This journey defines the signed evidence required to promote a provider-local
BYOM candidate into explicit network admission states without weakening billing,
receipt, catalog, routing, or payout gates.

This document is a test contract. It is not evidence that the journey has
passed, and it does not make any SPEC-047 requirement conformant by itself.

## Out Of Scope

- Positive provider settlement for non-settlement-capable states.
- Default buyer routing to unpriced, unsettled, rejected, withdrawn, or revoked
  BYOM candidates.
- Unsigned provider price proposals as trusted catalog economics.
- Public internet endpoint submission.
- Claims that opaque local endpoints are catalog-verified or model-honest.

## Required Steps

The signed result MUST contain these passing steps:

1. `step-01-offer-dry-run` - Run offer dry-run for a SPEC-046 candidate and
   confirm no coordinator admission state is submitted.
2. `step-02-submit-signed-offer` - Submit one provider-signed offer package and
   verify provider authentication, nonce/replay protection, and payload bounds.
3. `step-03-reject-opaque-endpoint` - Submit or simulate one opaque endpoint
   candidate whose identity cannot satisfy catalog or artifact/hash
   requirements for the requested admission state. Require rejection or
   confinement to a non-settlement state, with no buyer paid routing, catalog
   economics, or provider credit.
4. `step-04-sandbox-probe-only` - Admit one candidate as sandbox-probe-only and
   confirm it cannot receive default buyer paid routing or provider credit.
   Confirm any synthetic probe reaches the candidate only through the
   authenticated provider channel, not by coordinator dereference of a submitted
   endpoint URL, origin, socket, or local path.
5. `step-05-network-visible-unpriced` - Make one candidate network-visible only
   through explicit experimental disclosure and confirm economics remain null.
6. `step-06-catalog-matched-not-settlement` - Admit one catalog-matched
   candidate that may show trusted catalog economics but is not yet settlement
   capable; confirm no positive provider settlement occurs.
7. `step-07-revocation-on-drift` - Change or simulate a mismatched admitted
   predicate and confirm routing/settlement fail closed with revocation or
   demotion.
8. `step-08-withdrawal` - Withdraw one offered candidate through the CLI-owned
   provider path and confirm local artifacts are not deleted.
9. `step-09-settlement-capable-case` - Promote one catalog-verified candidate
   to settlement-capable and verify route-time snapshot plus receipt
   verification requirements remain enforced.
10. `step-10-redaction-review` - Review offer packages, coordinator events,
   status, logs, and evidence artifacts for secret, prompt, completion, path,
   and endpoint redaction.

## Required Evidence Contract

The reviewed redacted evidence artifact MUST be committed under:

```text
journeys/evidence/network-model-admission-*.redacted.json
```

It MUST use:

```json
{
  "schema_version": "macprovider.network-model-admission-evidence.v1",
  "journey_id": "JOURNEY-NETWORK-MODEL-ADMISSION"
}
```

The signer workflow converts that artifact into a generic signed journey-result
only after redaction, no-secret, settlement-boundary, buyer-visibility,
state-machine, revocation, and required-observation checks pass.

## Required Observations

The redacted evidence and signed result MUST set these booleans to `true`:

- `catalog_matched_not_settlement_verified`
- `default_buyer_invisibility_verified`
- `dry_run_did_not_submit`
- `network_visible_unpriced_disclosed`
- `provider_signature_verified`
- `rejected_opaque_endpoint_verified`
- `revocation_on_drift_verified`
- `sandbox_probe_only_blocked_from_paid_routing`
- `synthetic_probe_used_provider_channel`
- `settlement_capable_case_verified`
- `withdrawal_verified`

They MUST set these booleans to `false`:

- `non_settlement_state_created_provider_credit`
- `provider_price_treated_as_catalog_rate`
- `raw_completion_logged`
- `raw_prompt_logged`
- `secret_field_persisted`

## Completion

The journey is complete only when every required step passes for one reviewed
candidate commit or release artifact and the signed journey-result names only
SPEC-047 requirements that remain mapped to this journey in
`specs/CONFORMANCE.json`.
