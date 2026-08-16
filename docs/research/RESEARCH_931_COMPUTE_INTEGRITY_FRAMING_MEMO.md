# RESEARCH 931 - Compute-Integrity Framing Memo

**Date:** 2026-08-16
**Issue:** https://github.com/Augustas11/macprovider/issues/931
**Status:** Recommendation plus near-term disclosure surface implemented in this branch.

## Recommendation

Use **settlement integrity** for the near-term buyer-facing primitive.

Reason: that name matches the shipped settlement boundary without claiming more
than enforce mode can prove. The gateway can explain that, for covered paid
entrypoints under SPEC-022 enforce mode, MacProvider finalizes buyer debit and
provider settlement only after a settlement-capable receipt matches the
route-time catalog snapshot; in observe mode, the same label is disclosure-only
and does not change buyer debit or provider payout. It does not invite the
stronger and currently false inference that the product proves honest
computation or hardware/runtime integrity.

Use **compute integrity** as the SPEC-036 technical primitive: sampled, overt
distribution-drift detection against approved references, with observe,
warn-only, and enforce-mode logic. After the #1007-#1009 follow-up slices,
request-start capture, gate calls, observe/warn telemetry, and buyer-visible
unavailable status exist, but buyer surfaces must still say compute-integrity
settlement effect is unavailable until live policy activation, conformance
reconciliation, and production verification explicitly make it available.

Near-term surface:

- `/v1/models`: `tier1_disclosure.verified_model_settlement.settlement_integrity`
- `/v1/usage`: `settlement_disclosure.settlement_integrity`
- Single-page docs, account page, and console Tier 1 disclosure copy

## Current implementation state

What is shipped:

- SPEC-015 receipts bind prompt hash, output hash, provider receipt key,
  catalog-resolved/request-start model identity, usage, and terminal state.
- SPEC-022 verified model settlement uses receipt finality to decide buyer debit
  and provider settlement on covered paid entrypoints under enforce mode;
  observe mode records diagnostics without changing debit or payout.
- Gateway/API disclosure already exposes `pending`, `verified`, `quarantined`,
  and `zero_settled` settlement labels.

What is wired but not yet buyer-available as settlement effect:

- SPEC-036 is a complete draft spec and the coordinator package
  `phase4-coordinator/internal/computeintegrity` implements the gate logic,
  state machine, probe framing, disclosure checks, audit bundle shapes, and AC
  fixtures.
- PR #1007 wired request-start capture and gate calls into settlement
  verification, and PR #1008 added observe/warn status telemetry.
- PR #1009 deliberately exposes buyer-visible per-model compute-integrity status
  as `unavailable` until a trusted live source can back the buyer models
  surface and policy activation makes settlement effect explicit.
- `specs/CONFORMANCE.json` still records SPEC-036 requirements as pending and
  production status pending verification.

## Claims Matrix

| Claim class | Allowed wording | Required qualifier | Prohibited wording |
|---|---|---|---|
| Receipt binding | "Signed inference receipts bind the request/response settlement tuple and provider receipt key." | Say this proves a provider key signed the tuple; it does not prove honest local computation. | "The receipt proves the model was honestly run." |
| Settlement integrity | "Verified settlement means a settlement-capable receipt matched the route-time catalog snapshot and can finalize buyer debit/provider settlement for covered paid entrypoints under SPEC-022 enforce mode." | Say observe mode is disclosure-only and does not change buyer debit/provider payout. Scope to covered paid entrypoints and finality state. | "Fully verified inference" for mixed pools, observe mode, or excluded paths. |
| Model hash | "The provider-reported request-start model hash matched the route-time catalog snapshot." | Say the hash is provider-reported. | "Detected falsified loaded-model measurement." |
| SPEC-036 compute integrity | "Sampled distribution-drift detection against approved references." | Say probes are overt and buyer-visible settlement effect remains unavailable until live policy activation, conformance reconciliation, and production verification explicitly make it available. | "Cryptographic compute proof" or "proof of honest computation." |
| Hardware/runtime | "No hardware attestation or runtime binary attestation in Tier 1." | If Tier 2 metadata appears, describe its specific state separately. | "Hardware integrity," "binary integrity," or "trusted runtime" for Tier 1. |
| Privacy | "Prompts and responses are processed as plaintext on provider hardware." | Use only for cooperative workloads where that is acceptable. | "Private inference" or "provider-private prompts." |
| Malicious providers | "Settlement labels reduce creditability for receipt/model-integrity failures." | Keep the threat model limited to settlement/refund effects. | "Malicious-provider resistant" or "prevents malicious output." |

## Buyer-Facing Labels

Use these labels consistently:

- `pending`: receipt verification is incomplete; reservation is not final usage.
- `verified`: receipt-bound settlement finality for covered paid work under
  SPEC-022 enforce mode.
- `quarantined`: not charged because receipt/model-integrity settlement failed;
  not labeled as buyer fault.
- `zero_settled`: not charged because no billable verified work was produced.
- `settlement_integrity`: umbrella disclosure for receipt-bound settlement and
  SPEC-036 compute-integrity limits.

Avoid these labels for the near-term product:

- `honest_inference_receipt`
- `proof_of_compute`
- `hardware_verified`
- `fully_verified_model`
- `private_inference`

## Source Anchors

- `specs/SPEC-015-receipts.md`: receipt tuple and strict usage shape.
- `specs/SPEC-022-verified-model-settlement.md`: verified/pending/quarantined/
  zero_settled settlement outcomes.
- `specs/SPEC-036-compute-integrity-receipt.md`: compute-integrity drift gate,
  threat model, out-of-scope cryptographic/hardware/binary attestation claims.
- `phase4-coordinator/internal/computeintegrity`: SPEC-036 package-level gate
  implementation.
- `README.md`, `docs/using-macprovider-with-openai-sdk.md`, and
  `phase5-gateway/internal/router/templates/docs.md`: existing conservative
  buyer-facing receipt/model-identity caveats.

## Follow-Up Slices Created From This Memo

1. #1007 - Complete: live-wired SPEC-036 request-start capture and gate
   composition into the coordinator settlement verifier.
2. #1008 - Complete: added provider/operator status telemetry for
   compute-integrity observe/warn states.
3. #1009 - Complete: exposed buyer-visible per-model compute-integrity status
   as explicitly unavailable until backed by a trusted live buyer-status source.
4. #1010 - Open: revisit receipt binding in a future SPEC-015 version only if
   request-start compute-integrity state digests become part of the receipt
   contract.
