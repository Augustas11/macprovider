# SPEC-047 - Network Model Admission

**Version:** 0.1.2

```json
{
  "spec_id": "SPEC-047",
  "title": "Network Model Admission",
  "version": "0.1.2",
  "path": "specs/SPEC-047-network-model-admission.md",
  "status": "draft",
  "owner": "@Augustas11",
  "authority_domains": ["network-model-admission"],
  "supersedes": [],
  "depends_on": ["SPEC-001", "SPEC-002", "SPEC-005", "SPEC-006", "SPEC-010", "SPEC-011", "SPEC-015", "SPEC-018", "SPEC-019", "SPEC-022", "SPEC-023", "SPEC-032", "SPEC-033", "SPEC-046"],
  "implementation_status": "pending-reconciliation",
  "production_status": "not-deployed",
  "last_reconciled_commit": null,
  "last_reconciled_at": null,
  "evidence": [],
  "requirement_id_migration": "complete",
  "gap": {
    "verdict": "DECISION_REQUIRED",
    "owner": "@Augustas11",
    "issue": "https://github.com/Augustas11/macprovider/issues/1240",
    "rationale": "Issue #1240 requires a self-service path from provider-local BYOM candidates to network offer/admission states without weakening signed catalog economics, route-time verification, receipt, billing, or payout gates."
  }
}
```

## 1. Purpose and scope

SPEC-047 defines how a provider-local candidate discovered under SPEC-046 may be offered to the Malibu network and, after explicit checks, become eligible for network visibility, synthetic probes, buyer routing, catalog pricing, and settlement-capable paid traffic. Any synthetic probe is routed through the authenticated provider wire protocol or an admitted provider session; the coordinator MUST NOT dereference provider-submitted endpoint URLs, origins, sockets, or local paths.

The user outcome is a self-service path for providers to discover, evaluate, offer, probe, and explicitly disclose more models without making Malibu the manual gatekeeper for every possible model. In v0.1, genuinely novel non-catalog candidates can become visible or probeable only under explicit non-earning disclosure; an earning path for non-catalog models requires a later billing-owner pricing conversion spec. The settlement outcome is equally important: positive provider credit still requires a route-time admitted snapshot and settlement-capable receipt profile governed by the money-path specs.

SPEC-047 is CLI-first and coordinator-backed. The native Malibu app may later present admission state, but it must not mint or infer admission locally.

Accepted journey id: `JOURNEY-NETWORK-MODEL-ADMISSION`.

### Explicit non-goals

SPEC-047 does not replace SPEC-005 billing formulas, SPEC-006 buyer API compatibility, SPEC-010 signed catalog identity, SPEC-015 receipt wire ownership, or SPEC-022 verified settlement.

SPEC-047 does not allow a discovered model, opaque endpoint, provider-proposed price, local evaluation result, or runtime-reported identity to create positive provider credit by itself.

SPEC-047 does not define open public submission from arbitrary internet endpoints. v0.1 admission starts from an authenticated provider and a SPEC-046 candidate.

SPEC-047 does not make unsupported model quality, malicious output, privacy, or model honesty guarantees beyond the explicit admission and disclosure state.

## 2. Dependencies and authority

SPEC-047 owns `network-model-admission`: candidate offer packages, coordinator admission state, state transitions, disclosure classes, revocation, and the boundary between local discovery and network eligibility.

SPEC-001 owns the provider CLI and provider wire-protocol surfaces that submit, advertise, and refresh admitted model state.

SPEC-002 owns coordinator admission/routing and remains authoritative for whether a provider/model pair is routable for a buyer request.

SPEC-005 owns billing formulas, rate math, provider rewards, settlement, and payout-ready ledger behavior.

SPEC-006 owns public buyer API model visibility, error semantics, and buyer-facing disclosure.

SPEC-010 owns canonical signed catalog identity. SPEC-047 may create network offer state for non-catalog candidates, but only SPEC-010-compatible or catalog-derived identities can satisfy catalog-verified settlement.

SPEC-011 owns loaded-model state and warm-swap model-hash emission required before settlement-capable routing.

SPEC-015 and SPEC-022 own receipt and verified-settlement conditions. SPEC-047 adds admission state; it does not by itself make a receipt settlement-capable.

SPEC-018 and SPEC-019 own feature semantics for tool-calling and structured output. Admission may record support levels but cannot redefine those protocols.

SPEC-023 owns signed static feed and rate-card trust. SPEC-047 may consume feed identity, but cannot make unsigned provider price proposals trusted catalog economics.

SPEC-032 and SPEC-033 own hardware evidence and verifier semantics. SPEC-047 consumes hardware evidence only through those owner specs.

SPEC-044 consumes SPEC-047 admission state for Malibu economics UX when the app presents network-eligible or catalog-priced rows. SPEC-047 supplies admission state and does not depend on app presentation to enforce routing or settlement.

SPEC-046 owns discovery/evaluation inventory. SPEC-047 consumes its candidate and evaluation envelopes.

SPEC-001 §6.14a owns the model command taxonomy and legacy command
compatibility oracle. SPEC-047 owns only the offer, status, withdrawal,
state-machine, and network admission contracts for BYOM candidates after local
discovery/evaluation.

## 3. Normative requirements

**SPEC-047-R001 - Admission state machine.** Coordinator-backed admission MUST use a closed per-provider/per-candidate state machine with these v0.1 states: `not_offered`, `offer_submitted`, `offer_rejected`, `sandbox_probe_only`, `network_visible_unpriced`, `network_admitted_unsettled`, `catalog_priced`, `settlement_capable`, `withdrawn`, and `revoked`. SPEC-047 does not own SPEC-046 local states `local_only` or `offerable`; those states are CLI-only provider inventory states until a provider-signed offer enters the coordinator machine. State transitions MUST be append-only auditable events with actor, reason code, previous state, next state, provider id, candidate id, served model reference, evidence digests, timestamp, and request id. `settlement_capable` MUST NOT be reachable unless SPEC-022 verified-settlement preconditions are satisfiable for that provider/model pair at route time. No state transition outside this table is valid:

| Current state | Provider-facing meaning | Provider next action | Authorized actor | Allowed next states |
|---|---|---|---|---|
| `not_offered` | The coordinator has no active offer for this provider candidate; the provider may dry-run or submit an offer. | Run offer dry-run or submit a refreshed offer if local checks still pass. | coordinator readback or provider withdrawal reconciliation | `offer_submitted` |
| `offer_submitted` | The provider submitted a signed offer and the coordinator has not admitted it for any network use. | Wait for status readback or withdraw if the offer was mistaken. | provider submit path, coordinator validator | `offer_rejected`, `sandbox_probe_only`, `network_visible_unpriced`, `network_admitted_unsettled`, `catalog_priced`, `withdrawn`, `revoked` |
| `offer_rejected` | The submitted package failed policy, identity, safety, pricing, or evidence checks; it is not earning-eligible. | Fix the reason code, re-evaluate if needed, and submit a new signed offer. | coordinator validator | `offer_submitted`, `revoked` |
| `sandbox_probe_only` | The candidate may receive only bounded authenticated probes; it is not buyer-routable or earning-eligible. | Wait for probe outcome, improve local health/evidence, or withdraw. | coordinator admission policy | `network_visible_unpriced`, `network_admitted_unsettled`, `catalog_priced`, `withdrawn`, `revoked` |
| `network_visible_unpriced` | The candidate may appear only through explicit experimental disclosure with null economics; it is not earning-eligible. | Wait for pricing/admission policy, provide refreshed evidence if requested, or withdraw. | coordinator admission policy | `network_admitted_unsettled`, `catalog_priced`, `withdrawn`, `revoked` |
| `network_admitted_unsettled` | The candidate satisfies limited network admission checks but lacks trusted catalog economics or settlement prerequisites. | Keep the runtime healthy, satisfy requested catalog/receipt evidence, or withdraw. | coordinator admission policy | `catalog_priced`, `settlement_capable`, `withdrawn`, `revoked` |
| `catalog_priced` | The candidate has trusted signed catalog economics for display, but it is not settlement-capable. | Keep the admitted model loaded and wait for receipt/route-time settlement prerequisites, or withdraw. | coordinator admission policy with SPEC-023/SPEC-044 trust inputs | `network_admitted_unsettled`, `settlement_capable`, `withdrawn`, `revoked` |
| `settlement_capable` | The candidate may participate in positive provider settlement only for request attempts satisfying SPEC-022 route-time snapshot and receipt verification. | Keep the loaded model, receipts, and health predicates current, or withdraw. | coordinator admission policy with SPEC-022 preconditions | `network_admitted_unsettled`, `catalog_priced`, `withdrawn`, `revoked` |
| `withdrawn` | The provider withdrew the candidate; local artifacts remain untouched and the candidate is not earning-eligible. | Submit a new signed offer if the provider wants to re-enter admission. | provider CLI withdrawal path | `offer_submitted` |
| `revoked` | The coordinator removed admission because policy, identity, artifact, health, sanctions, or settlement prerequisites failed. | Resolve the reason code and submit a new signed offer with refreshed evidence if policy allows. | coordinator policy, trust, or sanctions path | `offer_submitted` |

Re-entry from `offer_rejected`, `withdrawn`, or `revoked` to `offer_submitted` MUST require a new provider-signed offer with a fresh nonce or idempotency key and refreshed evidence digests. Demotion from `settlement_capable` or `catalog_priced` takes effect for routing and settlement before any later request attempt can be admitted under the older state.

For rows whose allowed next state is `offer_submitted`, the outbound transition is provider-driven through the signed offer path even when the current state was established by the coordinator, sanctions policy, or a prior provider withdrawal.

Any allowed next state that depends on trusted catalog economics, catalog identity, receipt capability, or route-time settlement evidence remains conditional on the owner spec for that prerequisite; the table lists legal edges, not a guarantee that every candidate can traverse every edge.

**SPEC-047-R002 - Offer package schema.** `malibu-cli models offer <candidate> --dry-run --json` MUST produce a local preflight result and MUST NOT submit state. `malibu-cli models offer <candidate> --json` MUST submit a provider-signed offer package only after the operator confirms the candidate, runtime source, served model reference, disclosure class, and non-earning states. The recommended provider workflow is `models discover --json`, `models evaluate <candidate> --json`, `models offer <candidate> --dry-run --json`, and then `models offer <candidate> --json`. Offer dry-run output MUST use a closed JSON envelope with `schema: "model_admission_offer_dry_run.v1"` and MUST include `generated_at`, `cli_version`, `candidate_id`, `served_model_ref`, nullable `catalog_model_key`, `would_submit`, `likely_admission_state`, `likely_admission_state_source`, `provider_guidance`, nullable `reason_code`, and `warnings`; `likely_admission_state_source` MUST be `local_default` or `coordinator`; when it is `local_default`, `likely_admission_state` MUST be `local_only`, `not_offered`, or `offerable`; when it is `coordinator`, `likely_admission_state` MUST be one of the SPEC-047-R001 coordinator states; `provider_guidance` MUST reuse the SPEC-046-R003 object shape and closed enums. This is the sole v0.1 dry-run schema; it is not a submission receipt, admission status response, catalog-economics row, or legacy `models_browse.v1` row, and v0.1 decoders MUST reject unknown fields before treating the result as actionable. Offer submission MAY omit the evaluation digest only when the dry-run response explicitly labels the offer as more likely to be rejected or confined to non-earning states. The CLI MUST reserve `models admission status <candidate> --json` for provider status readback and `models admission withdraw <candidate> --json` for provider-initiated withdrawal. `models admission status <candidate> --json` MUST emit a closed JSON envelope with `schema: "model_admission_status.v1"`, `generated_at`, `cli_version`, `provider_id`, `candidate_id`, `served_model_ref`, nullable `catalog_model_key`, `admission_state`, `admission_state_source`, nullable `coordinator_event_id`, nullable `state_observed_at`, `provider_guidance`, `allowed_next_states`, and `warnings`. `admission_state_source` MUST be `local_default` or `coordinator`; when it is `local_default`, `admission_state` MUST be `local_only`, `not_offered`, or `offerable`; when it is `coordinator`, `admission_state` MUST be one of the SPEC-047-R001 coordinator states. `provider_guidance` MUST reuse the SPEC-046-R003 object shape and closed enums; for status output, `provider_guidance.next_action` MUST be appropriate to the transition table and `provider_guidance.earning_path_class` MUST be `not_earning_yet_catalog_or_receipt_path_exists`, `no_earning_path_in_v0_1`, `settlement_capable`, or `local_inventory_only`. `allowed_next_states` MUST contain only states allowed by SPEC-047-R001 for coordinator-sourced states and MUST be empty for `local_default` states that have not entered coordinator admission. Revocation, rejection, sanction, withdrawal, and demotion states MUST include a non-null `provider_guidance.transition_reason_code`. The v0.1 offer package MUST be a closed schema; unknown fields MUST be rejected before persistence, state transition, probing, or routing. The v0.1 offer package MUST include schema id, provider id, candidate id, SPEC-046 discovery digest, optional SPEC-046 evaluation digest, runtime source enum, served model reference, catalog match if any, artifact/hash evidence if available, advisory capabilities, fit evidence source, local readiness, requested disclosure class, timestamp, nonce, and provider signature. It MUST NOT include raw prompts, raw completions, endpoint URLs, endpoint origins, hostnames, IP addresses, ports, Unix-domain socket paths, local file paths, raw endpoint credentials, buyer credentials, wallet secrets, or unredacted adapter error bodies. Runtime source and served model reference are identity descriptors only; they MUST NOT be interpreted as network locations for coordinator-side dereference.

`models admission withdraw <candidate> --json` MUST submit a closed coordinator request with `schema: "model_admission_withdraw_request.v1"` and emit the coordinator-derived response with `schema: "model_admission_withdraw.v1"`. The request MUST include `generated_at`, `cli_version`, `provider_id`, `candidate_id`, `served_model_ref`, nullable `catalog_model_key`, `idempotency_key`, `nonce`, `timestamp`, `reason_code`, `signing_key_id` or `signing_key_digest`, `signature_algorithm`, and `provider_signature`; it MUST NOT include client-provided `previous_admission_state`, `coordinator_event_id`, `accepted_at`, or `resulting_admission_state`. `reason_code` MUST be a closed enum; v0.1 values are `provider_requested`, `wrong_model`, `runtime_unavailable`, `identity_mismatch`, `policy_uncertain`, and `other_operator_reason`. The withdrawal signature MUST use the same provider admission identity class as offers, over a canonical domain-separated preimage with domain `macprovider.model_admission.withdraw.v1`, and MUST bind `provider_id`, `candidate_id`, `served_model_ref`, nullable `catalog_model_key`, `idempotency_key`, `nonce`, `timestamp`, and `reason_code`. Bearer-token authentication may authenticate the transport, but a bearer token alone is never the withdrawal-signing root. Payout keys, wallet private keys, buyer keys, receipt-signing keys, endpoint credentials, and local discovery namespace secrets MUST NOT sign withdrawals or appear in withdrawal payloads. The coordinator MUST reject unknown request fields, stale/unknown/bearer-only/receipt-key-only/payout-key/wallet-key/buyer-key signatures, mismatched provider/candidate/served-model tuples, withdrawals for another provider, replayed nonces, and idempotency-key reuse whose canonical request digest differs from the first request stored for that provider and candidate before appending any event. Exact idempotent retries for the same provider, candidate, idempotency key, and canonical request digest MAY return the original `model_admission_withdraw.v1` response, but MUST NOT append a second state transition or delete local model artifacts. The response MUST include `generated_at`, `cli_version`, `provider_id`, `candidate_id`, `served_model_ref`, nullable `catalog_model_key`, `idempotency_key`, `reason_code`, `previous_admission_state`, `coordinator_event_id`, `accepted_at`, `resulting_admission_state`, `provider_guidance`, and `warnings`; the coordinator MUST derive previous state, event id, acceptance timestamp, and resulting state atomically from durable coordinator state. A later re-entry from `withdrawn` MUST use a fresh provider-signed offer with refreshed evidence digests.

The v0.1 offer package MUST be a closed schema; unknown fields MUST be rejected before persistence, state transition, probing, or routing. The v0.1 offer package MUST include schema id, provider id, candidate id, SPEC-046 discovery digest, optional SPEC-046 evaluation digest, runtime source enum, served model reference, catalog match if any, artifact/hash evidence if available, advisory capabilities, fit evidence source, local readiness, requested disclosure class, timestamp, nonce, signing key id or digest, provider signature, and signature algorithm. The signing key MUST be the provider's CLI-owned Ed25519 admission identity accepted through SPEC-001/SPEC-026 as the coordinator-authoritative current `provider_admission_public_key` for that `provider_id` at mutation time. Pending or recovery keys qualify for mutating BYOM offers or withdrawals only after the SPEC-026 compare-and-swap or recovery transaction has succeeded and the coordinator now identifies that key as the current admission key. Previous keys are valid only for the rollback/readback compatibility role explicitly allowed by SPEC-026 and MUST NOT authorize mutating BYOM offer or withdrawal requests. The signed payload MUST bind `provider_id`, `candidate_id`, `served_model_ref`, discovery digest, optional evaluation digest, timestamp, nonce/idempotency key, requested disclosure class, and catalog/hash evidence. Bearer-token authentication may be required to authenticate the transport, but a bearer token alone is never the offer-signing root. Payout keys, wallet private keys, buyer keys, receipt-signing keys, endpoint credentials, and local discovery namespace secrets MUST NOT sign BYOM offers or appear in offer payloads. It MUST NOT include raw prompts, raw completions, endpoint URLs, endpoint origins, hostnames, IP addresses, ports, Unix-domain socket paths, local file paths, raw endpoint credentials, buyer credentials, wallet secrets, payout secrets, or unredacted adapter error bodies. Runtime source and served model reference are identity descriptors only; they MUST NOT be interpreted as network locations for coordinator-side dereference.

**SPEC-047-R003 - Settlement boundary.** A model in any state other than `settlement_capable`, including `not_offered`, `offer_submitted`, `offer_rejected`, `sandbox_probe_only`, `network_visible_unpriced`, `network_admitted_unsettled`, `catalog_priced`, `withdrawn`, or `revoked`, MUST NOT create buyer-final debit, default paid buyer routing, positive provider credit, earnings visibility, payout-ready rows, settlement ledger rows, or "verified" buyer-facing claims. `catalog_priced` MAY show signed rate-card economics only when SPEC-023 and SPEC-044 trust rules are satisfied, but it still MUST NOT create buyer-final debit, default paid buyer routing, positive provider settlement, or settlement ledger rows unless SPEC-022 receipt and route-time verification requirements are also satisfied and the state becomes `settlement_capable`. `catalog_priced` and `settlement_capable` require a trusted catalog identity/hash binding: the coordinator MUST bind the candidate to a trusted signed catalog row by catalog identity, exact catalog body digest, signing key identity, `catalog_model_key`, expected `model_hash`/algorithm, and route-time snapshot evidence under SPEC-010 and SPEC-022. A release-manifest digest MAY be recorded as additional provenance only when its owner spec defines the field, but it is never an alternative to the exact catalog body digest required for settlement-capable route snapshots. Provider-asserted `catalog_model_key`, `served_model_ref`, display name, runtime-reported model name, or local artifact label is advisory only and is never sufficient for catalog economics or settlement capability. `settlement_capable` is the only v0.1 BYOM admission state that may participate in buyer-final debit, default paid buyer routing, positive provider settlement, and payout-ready ledger behavior, and only for request attempts whose route-time snapshot and receipt verification satisfy SPEC-022.

**SPEC-047-R004 - Pricing and economics.** Provider-proposed prices, local benchmark estimates, runtime-reported model names, and demand labels are advisory until converted into a signed MacProvider rate-card entry or a later billing-owner spec defines another trusted price source. The coordinator and Malibu MUST NOT display provider payout rates, expected earnings, higher-paying labels, or catalog economics for `not_offered`, `offer_submitted`, `offer_rejected`, `sandbox_probe_only`, `network_visible_unpriced`, `network_admitted_unsettled`, `withdrawn`, or `revoked` states. `catalog_priced` MAY display signed catalog economics under SPEC-044 while still hiding earning-eligible or settlement-ready claims until the state becomes `settlement_capable`. If an offer has no trusted price, buyer-visible surfaces MAY label it only as unpriced or experimental when explicitly opted in; provider-facing surfaces MUST state that the model is not earning-eligible. Provider-facing status MUST distinguish "not earning-eligible yet; catalog/receipt path exists" from "no earning path exists in this release because the model lacks a trusted price-conversion/catalog path."

**SPEC-047-R005 - Buyer visibility and routing.** Default public buyer `/v1/models` and default buyer routing MUST include only models that are allowed by SPEC-006 and the active routing policy. Non-settlement BYOM states MUST be hidden from default paid routing. Experimental or unpriced visibility, if enabled, MUST require an explicit account, request, or operator policy opt-in and MUST return disclosure fields that distinguish provider-reported identity from catalog-verified identity. A sole-provider or low-supply condition MUST NOT relax catalog, admission, route-time snapshot, or settlement requirements.

**SPEC-047-R006 - Drift, revocation, and withdrawal.** Providers MUST be able to withdraw an offered candidate through a CLI-owned command. The coordinator MUST revoke or demote an admitted candidate when required identity, artifact/hash, runtime health, hardware fit, policy, or receipt preconditions become stale, mismatched, expired, or unavailable. A provider heartbeat, warm-swap event, loaded-model hash, adapter identity, or runtime source that no longer matches the admitted route-time predicate MUST fail closed for buyer routing and settlement. Revocation MUST be visible in provider-facing status with a reason code and MUST NOT require deleting local model artifacts.

**SPEC-047-R007 - Abuse and privacy controls.** Offer submission and withdrawal MUST be authenticated as the provider, signed with the SPEC-047-R002 current provider admission identity, rate-limited per provider identity, bounded by payload size and parser work, replay-protected by nonce or idempotency key, and audited. The coordinator MUST verify that the signing public key is the current coordinator-authoritative `provider_admission_public_key` for the `provider_id` at mutation time; pending or recovery keys can authorize BYOM mutation only after the SPEC-026 transaction has made them current, and previous keys remain limited to SPEC-026 rollback/readback compatibility. Stale, unknown, bearer-only, receipt-key-only, payout-key, wallet-key, buyer-key, pending-key-not-current, recovery-key-not-current, or previous-key-mutating signatures MUST fail closed. The coordinator MUST reject offers containing endpoint URLs, endpoint origins, hostnames, IP addresses, port values, Unix-domain socket paths, public/LAN/loopback/private/link-local/multicast address material, redirect targets, encoded network locations, secret-bearing fields, raw local absolute paths, HTML/script-bearing display names, control characters, ambiguous Unicode identifiers, or model identifiers that cannot be normalized under the chosen identity class. Offer state MUST be sanction-aware: a provider under a route, trust, payout, or registration sanction MUST NOT use BYOM admission to bypass that sanction.

**SPEC-047-R008 - Release evidence.** Promotion beyond draft MUST include automated tests for offer dry-run non-submission, provider signature verification, replay rejection, closed-schema unknown-field rejection, endpoint/origin/socket/path rejection including loopback, localhost, IPv6 loopback, encoded IP, redirect, Unix-socket, and local-path variants, state-machine transition validity including rejected/withdrawn/revoked re-offer freshness, `models admission status` presentation of provider-facing state meaning, next action, and earning-path disclosure, synthetic probes using the provider wire protocol rather than coordinator dereference, settlement-boundary enforcement, default buyer invisibility for non-settlement states, explicit experimental disclosure if implemented, pricing trust nullability, revocation on drift, withdrawal, sanction interaction, payload redaction, parser/resource bounds, and SPEC-044 economics gating. Production promotion MUST include a signed journey result covering one rejected opaque endpoint, one sandbox-probe-only offer, one network-visible unpriced offer, one catalog-matched offer that is not yet settlement-capable, one novel non-catalog offer whose status says no earning path exists in v0.1, one rejected-offer re-entry requiring fresh evidence, one revoked drift case, one withdrawn re-entry requiring fresh evidence, and one settlement-capable catalog-verified case.

## 4. Implementation, tests, and journeys

The intended implementation sequence is:

1. Add CLI dry-run output for `models offer`.
2. Add provider-signed offer package generation.
3. Add coordinator append-only admission event storage.
4. Add state-machine validation and provider status readback through `models admission status <candidate> --json`.
5. Keep non-settlement BYOM states out of default buyer `/v1/models` and paid routing.
6. Add SPEC-044 economics gating from admission state.
7. Add revocation and withdrawal through `models admission withdraw <candidate> --json`.
8. Only then consider settlement-capable routing for catalog-verified candidates.

The first journey id is `JOURNEY-NETWORK-MODEL-ADMISSION`.

## 5. Open gaps

| Requirement/domain | Verdict | Owner | Issue | Evidence needed |
|---|---|---|---|---|
| `SPEC-047-R001..R008` | `DECISION_REQUIRED` | `@Augustas11` | `#1240` | Product/security approval of admission states, settlement boundary, disclosure model, abuse controls, and signed admission journey. |
| `network-model-admission` | `DECISION_REQUIRED` | `@Augustas11` | `#1240` | Authority acceptance that BYOM network offers may exist before they are catalog-priced or settlement-capable. |

## 6. Evidence

No implementation or production evidence exists yet.

## 7. Current contract notes

The route from local candidate to earning is intentionally multi-step: discovered locally, evaluated locally, offered to the network, admitted for limited network state, catalog-priced when a trusted rate-card source exists, and settlement-capable only when route-time verification and receipts satisfy SPEC-022. This makes model supply broad without letting arbitrary local endpoints mint provider credit.

**v0.1 product-shape decision (recorded, #1240).** The v0.1 product shape is
settled per issue #1240: BYOM offers may exist in non-settlement network states
before they are catalog-priced or settlement-capable, and a genuinely
non-catalog model has **no earning path in v0.1** — provider surfaces disclose
this honestly (`earning_path_class` = `no_earning_path_in_v0_1`), and an earning
path for non-catalog models is deferred to a later billing-owner (SPEC-005)
pricing-conversion spec per SPEC-047-R004. This decision is the arbitration
basis for the §5 `DECISION_REQUIRED` gaps; the gaps' verdicts remain **open**
because their "Evidence needed" column requires a signed admission journey
(SPEC-047-R008) and production evidence that do not exist until the admission
implementation slices land. This amendment does not flip those verdicts.

## 8. Changelog and history

- v0.1.2 - BYOM slice-1 rework for issue #1259 (#1240). Records the v0.1
  product-shape decision (#1240) as the arbitration basis for the §5
  `DECISION_REQUIRED` gaps without flipping their still-open verdicts (signed
  admission journey / production evidence still required). Rebased onto the
  shipped `malibu-cli` rebrand (#1343) and folded the sole-v0.1-dry-run-schema
  clarification into SPEC-047-R002. Complemented by SPEC-001 v1.9.4 which adds
  the earning-verdict-first human-output contract mapped from
  `provider_guidance.earning_path_class`.
- v0.1.1 - Narrow contract-lock amendment for issue #1249. Pins
  `model_admission_offer_dry_run.v1` as the sole v0.1 offer dry-run envelope,
  defines `model_admission_withdraw.v1`, binds offer signing to the CLI-owned
  Ed25519 admission identity, requires withdrawal requests to use the same
  current-key signing boundary, and requires exact catalog-body-digest evidence
  before `catalog_priced` or `settlement_capable`.
- v0.1.0 - Initial draft for issue #1240. Defines BYOM network admission state and preserves the billing/settlement gate.
