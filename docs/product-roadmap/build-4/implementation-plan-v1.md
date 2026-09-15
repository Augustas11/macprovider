# Product Build 4 implementation plan v1

Status: planning and contract assessment only  
Repository base: `1d2c930bad81704dd0acc0322226725d8b64aceb` (`origin/main`, inspected 2026-09-11)  
Historical roadmap baseline: `422fc2f13fc62c1ff8987522f822d9ef856e4a96`  
Implementation gate: **closed** pending accepted Product Build 2 and Product Build 3 contracts

## 1. Product outcome

An authorized buyer can select an eligible provider in a Trusted Pool before encryption, submit one relay-blind request bound to that provider, model, pool policy, and pool generation, and receive a settlement result only when the request has both a compatible cryptographic receipt and independently valid evidence required by the covered Product Build 3 observation profile.

The selected provider reads plaintext. The gateway and coordinator do not read request content, but they continue to see authentication, routing bindings, ciphertext size, response content, usage, settlement metadata, and pool identity. The product must describe this as relay-blind request encryption within a Trusted Pool. It must not call the result confidential compute, anonymity, unlinkable settlement, end-to-end encryption, or privacy from the provider.

This plan does not authorize production activation, pool promotion, settlement enforcement, rewards, payouts, or economic policy changes.

## 2. Current implementation classification

The table classifies the requested outcomes against the exact base above. “Landed” means source and tests exist on this base; it does not mean deployed or production-qualified.

| Requested outcome | State | Code-grounded evidence | Remaining work |
|---|---|---|---|
| Trusted Pool membership, buyer authorization, route isolation, policy gates, and generation fencing for plaintext requests | **Partial** | `trustpool.Registry.AuthorizeAndSnapshot`, `Snapshot`, `BeginPoolDeliveryAtGeneration`, and `WatchProviderRevoked` in `phase4-coordinator/internal/trustpool/registry.go`; ordinary request selection in `phase4-coordinator/internal/buyer/server.go`; route-path tests in `spec042_pool_isolation_test.go`, `spec042_pool_model_allowlist_test.go`, and `spec042_pool_predicate_errors_test.go` | The hot snapshot contains `PoolID`, members, predicates, and numeric generation, but not the accepted `manifest_version`, `manifest_core_digest`, or a cryptographic `pool_state_epoch_hash`. Relay-blind paths do not consume it. Production qualification remains absent. |
| Relay-blind provider selection, reservation, encrypted dispatch, at-most-once execution, and ordinary usage settlement in the global pool | **Partial** | `handleRelayBlindReservation`, `handleRelayBlindConsume`, and `handleRelayBlindChat` in `phase4-coordinator/internal/buyer/relay_blind.go`; `relayblind.Reservation`, `Envelope`, and durable state in `phase4-coordinator/internal/relayblind`; gateway flow in `phase5-gateway/internal/router/relay_blind*.go`; cross-service tests in `test/integration/relay_blind_integration_test.go` | Product Build 2 must first finish the buyer-approved acceptable-provider-identity selection contract and supported buyer journey. Current request/reservation/AAD schemas have no pool or settlement-contract binding. Real-model encrypted qualification is not credited here. |
| Rejection of pool-scoped relay-blind intent | **Landed deliberate restriction** | `relayBlindPoolSelected` and reservation/consume rejection in `phase5-gateway/internal/router/relay_blind_success.go`; pool-header rejection in `handleRelayBlindReservation` and `handleRelayBlindConsume`; `TestRelayBlindReservationRejectsPoolSelectionBeforeQuota` | Preserve until the successor contracts, capability negotiation, migrations, tests, and gates described here are complete. Do not delete the guard as an implementation shortcut. |
| Rejection of relay-blind plus verified-settlement enforce mode | **Landed deliberate restriction** | `Config.Validate` rejects `relay_blind.enabled` with `settlement.verified_model_settlement_mode=enforce` in `phase4-coordinator/internal/config/config.go` | Replace only with a new, explicitly supported request-scoped contract. Do not weaken the global settlement gate. |
| Positive verification and useful-work rewards excluded for relay-blind traffic | **Landed deliberate restriction** | `billingRecorder.logProviderRowWithEstimateAndOutput` sets `PositiveVerificationExcluded` and `RewardsExcluded`; billing schema persists both; `rewards/useful_work.go` filters excluded rows | A future private-settlement path may clear positive-verification exclusion only after all receipt and independent-observation gates pass. Reward eligibility remains a separate governed mapping owned by Product Build 3 and must stay excluded unless that mapping explicitly covers the request. |
| Existing SPEC-015 v0.4 verified settlement | **Landed for plaintext; incompatible with relay-blind** | Exact 23-field v0.4 parser and `VerifySettlementReceipt` in `phase4-coordinator/internal/billing/settlement_verifier.go`; route snapshot in `route_snapshot.go`; receipts in `settlement_receipts.go` | SPEC-015 v0.4 binds plaintext `prompt_hash` and has a closed tuple. It cannot gain optional pool or encrypted-request fields and cannot be relabeled as private-request evidence. A successor receipt version is required. |
| Pool identity in ordinary route snapshots and request logs | **Partial** | `billing.RouteSnapshot.PoolID`, conditional digest binding, settlement reload, and `requestlog.Row.PoolID` | SPEC-042 also requires `manifest_version` and `manifest_core_digest`; the current hot route snapshot and settlement record bind only `pool_id`. The private contract additionally needs generation/epoch and encrypted-request bindings. |
| Receipt/version/digest contract for private pool settlement | **Missing** | SPEC-041 explicitly excludes v0.4 positive settlement; SPEC-042 R009 blocks non-default privacy mode until SPEC-041/SPEC-040 amendments | Establish the normative successor described in section 6 before runtime edits. |
| Independently valid compute evidence for private positive settlement | **Blocked** | Current settlement verifier has a `ComputeIntegrityCapture` gate, while the roadmap records production observation scope as unknown | Product Build 3 must publish an accepted covered-key/profile/generation contract and governed settlement mapping. Provider signatures and relay-blind validation are insufficient. |
| Correctly settled authorized private-pool real-model request | **Blocked** | No composed runtime path or acceptance evidence exists | Depends on accepted Build 2 identity selection, Build 3 observation scope, the new receipt contract, real MLX inference, and representative Mac evidence. |

No relevant open pull request was found during this inspection. Changes after the historical roadmap baseline affect BYOM settlement identity, not the SPEC-041/SPEC-042 composition contract.

## 3. User journeys

### 3.1 Supported success journey

1. An authenticated buyer credential or wallet session is provisioned for pool `P` and an acceptable provider-identity set defined by Product Build 2.
2. The buyer client fetches fresh pool policy/status and the applicable provider pin set through authenticated channels. It displays that the provider reads plaintext and responses remain visible to relays.
3. The client asks for a pool-scoped reservation, naming canonical model `M`, endpoint, stream mode, caps, and the acceptable identity-set commitment. No request content is sent.
4. The gateway authenticates the buyer and narrows pool selection to a pool in the credential scope. It requires positive successor-capability advertisement from gateway, coordinator, and provider.
5. The coordinator atomically reads current buyer authorization, routeable policy, membership, revocation state, predicates, generation, and accepted manifest identity. It selects provider `A` only if `A` is both pool-eligible and buyer-acceptable.
6. The reservation response commits to `A`'s relay-blind identity/key record and to pool `P`, manifest version/digest, generation/epoch, model mapping, caps, and receipt contract. The public response need expose only the buyer-approved relay identity, never an unrelated stable provider identifier.
7. The buyer verifies all bindings before encryption, then creates a fresh ephemeral key, nonce, request ID, and ciphertext. The successor AEAD transcript binds the complete reservation context.
8. Consume burns the reservation before quota or dispatch. Reservation, buyer authorization, acceptable identity, pool lifecycle/policy/generation, provider membership/session/key, model/admission, and settlement prerequisites are rechecked.
9. Immediately before the single WebSocket dispatch, the coordinator repeats the same lifecycle and generation checks. A stale result burns the transaction and cannot be re-encrypted or failed over.
10. The provider claims the bound execution, validates the successor transcript, decrypts, validates the inner request, pins the model runtime handle, and executes once.
11. The provider returns bound validation/terminal evidence and the successor receipt. The coordinator independently checks the response/output material, route snapshot, request-envelope digest, pool binding, model/artifact identity, terminal state, receipt version, and the Build 3 observation evidence required for the exact covered key.
12. The gateway finalizes the existing buyer quota journal and coordinator settlement row exactly once. The app reports independently: encryption outcome, pool-authorization outcome, receipt verification, observation coverage, settlement state, and reward eligibility.

### 3.2 Safe pre-dispatch recovery

If reservation, consume, or final authorization fails before dispatch, the system burns the old single-use material, releases or refunds any hold according to the existing journal, and returns a typed action to create a new reservation and new ciphertext. The client must not reuse a prior envelope.

### 3.3 Safe post-dispatch recovery

Once dispatch is possible, cancellation, disconnect, timeout, restart, or uncertain terminal evidence must never trigger provider substitution or ciphertext replay. Durable status lookup and existing settlement reconciliation return the final result or an unknown/quarantined state with `do_not_resubmit`.

### 3.4 Unsupported-version journey

An old gateway, coordinator, provider, verifier, or client that lacks the successor private-pool capability fails before quota. Existing global relay-blind v1, plaintext global, plaintext Trusted Pool, and SPEC-015 v0.4 settlement journeys continue unchanged.

## 4. Ownership boundaries

| Authority | Owns in this build | Must not be overridden here |
|---|---|---|
| SPEC-040 | Credential/wallet authorization and semantic signature over pool and private-request transaction | Build 4 cannot invent unauthenticated pool intent or widen wallet scope. |
| Product Build 2 / SPEC-041 successor | Buyer-approved acceptable-provider identities, pin rotation/revocation, reservation and AEAD transcript, typed private-client recovery | Build 4 consumes the accepted identity contract; it does not define a conflicting pin format. |
| SPEC-042 | Pool identity, manifest, buyer authorization, membership, lifecycle, predicates, generation fence, pool disclosures | A `pool_id` is never a capability. |
| SPEC-002 | Provider assignment, capacity, dispatch lifecycle, cancellation, request logs | No parallel dispatcher or cross-provider ciphertext failover. |
| SPEC-010/SPEC-023/SPEC-047 | Canonical model and authoritative artifact/admission identity | Provider assertions cannot mint settlement identity. |
| SPEC-015 successor | Closed receipt version, canonical signing preimage, verifier behavior, compatibility | The v0.4 tuple remains immutable. |
| SPEC-022 | Settlement outcomes, finality, quarantine, debit/provider-credit control | Build 4 must not make “valid signature” synonymous with payable. |
| Product Build 3 / SPEC-036 successor | Covered compute observation key, generation, reference/calibration, expiry/revocation, and governed reward mapping | Provider terminal evidence cannot substitute for independent observation. |
| SPEC-005 | Usage arithmetic and ordinary accounting | No formula or economic-policy changes. |
| SPEC-021/rewards | Useful-work reward eligibility | Remains excluded unless Build 3 explicitly authorizes the exact covered private request. |

## 5. Dependency graph and implementation gate

```text
Build 2 accepted acceptable-identity contract
  -> pool-scoped reservation can select before encryption
  -> client can verify provider/pool binding

Build 3 accepted covered observation contract
  -> successor receipt can reference exact observation scope
  -> settlement verifier can distinguish signature validity from payable evidence
  -> reward mapping can remain excluded or become explicitly covered

SPEC-040 + SPEC-041 + SPEC-042 normative amendments
  -> closed successor reservation/AAD and lifecycle contract

SPEC-015 + SPEC-022 + SPEC-036 normative amendments
  -> closed receipt and verification/settlement contract

All above approved
  -> runtime implementation slices
  -> local integration
  -> real MLX/hardware acceptance
  -> separate Trusted Pool production qualification
```

The runtime implementation gate opens only when the exact accepted Build 2 acceptable-identity fields and Build 3 covered-observation fields are copied into a revised plan and the adversarial plan review again reports zero Critical, High, and Medium findings. Planning review can proceed now; source implementation cannot.

## 6. Proposed normative contracts for review

These identifiers are provisional until the owning SPEC amendments land. Field sets are intentionally explicit so review can challenge them before code exists.

### 6.1 Protocol generation and capability negotiation

Keep all global relay-blind v1 objects byte-for-byte compatible. Introduce a separate generation for pool-scoped private requests:

- reservation: `relay-blind-pool-reservation-v1`;
- envelope/body encoding: `relay-blind-pool-request-v1`;
- consume/status: matching `relay-blind-pool-*-v1` objects;
- receipt contract: a new SPEC-015 receipt version, provisionally `receipt_version: "5"`;
- positive capabilities advertised independently by gateway, coordinator, provider runtime, verifier, and buyer client.

An object from one generation cannot be parsed or normalized into the other. A v1 global reservation cannot accept pool fields. A pool request cannot fall back to global v1.

### 6.2 Authoritative pool-policy snapshot

Add one immutable `PrivatePoolRouteAuthorityV1` record captured in a single coordinator transaction/read boundary:

- `pool_id`;
- `manifest_version`;
- `manifest_core_digest`;
- `pool_generation`;
- `pool_state_epoch_hash`;
- `policy_not_before_unix` and `policy_expires_at_unix`;
- `buyer_authorization_generation` and a non-secret authorization-record digest;
- `model_allowlist_digest`;
- effective settlement mode and receipt contract;
- required Build 3 observation profile id/version/generation;
- provider membership/admission record digest;
- policy predicate digest;
- capture timestamp and bounded freshness deadline.

The hot registry projection must carry all fields from the accepted durable manifest/lifecycle record. Recomputing part of the record from a newer policy at settlement is forbidden. `pool_state_epoch_hash` must be a domain-separated digest of the stable pool id, accepted manifest digest, lifecycle state, generation, and the exact membership/revocation high-water mark. It cannot be a hash of a mutable in-memory map iteration.

### 6.3 Pool-scoped reservation

The closed reservation request must include the normal endpoint/model/stream/cap/size fields plus:

- canonical `pool_id` selected from authenticated credential scope;
- an acceptable-provider-identity commitment using the final Build 2 contract;
- supported private-pool protocol and receipt-contract versions;
- the buyer-observed pool-policy digest when the client has one.

The successful reservation must bind:

- every existing global v1 reservation field;
- the complete `PrivatePoolRouteAuthorityV1` digest and its buyer-safe constituent fields;
- selected provider relay identity fingerprint and signed key record;
- acceptable-identity-set commitment and proof that the selected identity is a member;
- canonical requested model, provider model selector, and authoritative model/artifact admission digest;
- receipt contract and Build 3 observation requirement;
- `failover_policy: disabled`.

Reservation creation must happen only after buyer authorization and selection against one consistent pool snapshot. The public response must not reveal nonselected candidates or pool membership.

### 6.4 Successor AEAD transcript and wallet signature

Create a new domain tag; never append fields to the existing v1 transcript. The successor AAD must encode, in fixed order and fixed binary types:

1. protocol/version/mode/endpoint;
2. requested and provider model;
3. stream flag, request id, caps;
4. provider and buyer one-time bindings;
5. key record digest and key id;
6. buyer ephemeral public key and replay nonce;
7. issued time and algorithm;
8. pool id, manifest version, manifest digest;
9. pool generation and state-epoch hash;
10. private-pool route-authority digest;
11. acceptable-identity commitment;
12. model/artifact admission digest;
13. receipt contract;
14. required observation profile id/version/generation.

The SPEC-040 semantic signature must cover the exact same authority fields plus the canonical envelope digest and route. The gateway must strip buyer-supplied internal authority headers and regenerate them only from authenticated state.

### 6.5 Lifecycle authorization rechecks

Perform one coherent recheck at reservation, consume, quota hold, dispatch arm, and immediately before provider WebSocket commit. Each recheck must cover:

- buyer credential/session validity and pool authorization generation;
- acceptable provider identity and pin validity;
- pool routeability, policy validity, manifest identity, generation, and epoch;
- provider membership/revocation and required pool capability;
- provider authenticated session and relay-blind key validity/revocation;
- canonical model allowlist and authoritative model/artifact admission;
- settlement mode/receipt-key capability;
- Build 3 observation profile availability when policy requires positive verified settlement.

Any mismatch before dispatch burns the reservation and prevents charge. The client creates a fresh transaction. After dispatch, no mismatch authorizes rerouting or re-encryption. A policy update cannot retroactively weaken or rewrite the captured settlement contract. Restrictive revocation may cancel according to existing SPEC-042 semantics, but settlement still uses the immutable request-start authority.

### 6.6 Encrypted dispatch binding

The authenticated outer dispatch context must carry digests for the envelope, selected provider/session, private-pool route authority, model/artifact admission, receipt contract, and required observation profile. These fields live inside SPEC-008 protection when that leg is enabled and otherwise rely on the authenticated WebSocket session. HTTP transport remains forbidden.

The provider journal execution identity must add the private-pool authority digest and receipt contract to its domain-separated filename/preimage. A global v1 claim and pool v1 claim must never collide. The provider validates every clear binding before decryption and validates inner request/model/caps after decryption. It must pin one runtime handle for tokenization, inference, and receipt production.

### 6.7 Successor receipt and verifier

SPEC-015 v0.4 remains exact and unchanged. Define a new closed receipt tuple for pool-scoped relay-blind settlement. At minimum it must bind:

- `receipt_version` and signature algorithm/key id;
- account scope, request id, and attempt number;
- provider identity/session generation permitted by the receipt privacy policy;
- canonical model id, loaded model hash, and artifact/admission digest;
- route snapshot digest and private-pool route-authority digest;
- pool id, manifest version/digest, generation, and state-epoch hash;
- envelope digest and AEAD transcript digest, not a fabricated relay-visible plaintext prompt hash;
- provider validation digest and terminal-evidence digest;
- output hash/prefix range and terminal state/timestamps;
- strict usage object;
- Build 3 observation profile id/version/generation and request-start observation snapshot digest.

Whether a buyer-only plaintext-content digest is included must be decided by the owning SPEC after privacy analysis. Relays must not require or persist a plaintext prompt hash merely to reproduce v0.4 semantics.

Verifier outcomes remain `pending`, `verified`, `quarantined`, and `zero_settled`. Cryptographic validity is necessary but not sufficient. `verified` additionally requires:

- exact route, pool, envelope, provider, model/artifact, terminal, output, and usage matches;
- no replay, overlap, version, or timing failure;
- accepted provider receipt key at request start;
- independently valid Build 3 observation evidence for the exact covered model/runtime/profile/generation and request window;
- policy mapping that permits positive settlement.

Provider validation, a provider signature, an artifact assertion, or observation availability alone cannot produce `verified` or reward eligibility. Missing/expired/revoked/mismatched observation evidence yields `pending` until the bounded evidence deadline, then `quarantined` or `zero_settled` only as explicitly authorized by SPEC-022. It must never silently fall back to ordinary positive verification.

### 6.8 Settlement and rewards

Use the existing gateway quota journal, coordinator settlement tables, request log, and reconciliation flow. Add immutable private-pool fields and a supported receipt-version discriminator. Do not create another ledger.

`PositiveVerificationExcluded` may become false only on the dedicated successor path after successful verification. `RewardsExcluded` remains true by default. Clearing it requires the Build 3 governed reward-state mapping to name the exact covered request profile; it is not implied by settlement verification. Payout execution remains disabled and out of scope.

### 6.9 Compatibility rules

| Producer | Consumer | Required result |
|---|---|---|
| Existing global relay-blind v1 | Existing or successor stack | Existing behavior unchanged; still observe-only and positive-verification/reward excluded. |
| Successor pool request | Old gateway/coordinator/provider | Fail before quota from absent positive capability; no field stripping or global fallback. |
| Global or pool plaintext request | Successor stack | Existing plaintext routing, receipts, and pool protections unchanged. |
| SPEC-015 v0.4 receipt | Successor verifier | Verify only under existing plaintext contract. Reject it as a private-pool settlement receipt. |
| Successor receipt | Old verifier | `inconclusive: unknown_receipt_version`; no debit/provider-positive settlement/reward. |
| Successor receipt with missing/extra/null/wrong-type fields | Successor verifier | Invalid/quarantined; closed schema, no normalization. |
| Successor receipt with unknown observation profile generation | Successor verifier | Pending until deadline, then governed fail-closed outcome; never verified. |
| In-flight request during config rollback | Successor stack | No new private-pool admission; durable dispatched work reconciles without replay; global traffic continues. |

## 7. Phased changes after dependencies land

### Phase A: normative amendments and vectors

Amend SPEC-040, SPEC-041, SPEC-042, SPEC-015, SPEC-022, and the applicable SPEC-036/Build 3 contract. Update `AUTHORITY.json`, `CONFORMANCE.json`, generated indexes, and requirement mappings. Freeze closed schemas, binary framing, digest domains, error mapping, capability versions, and cross-language positive/negative golden vectors.

Acceptance for this phase: independent adversarial plan/contract review has zero Critical, High, or Medium findings. No runtime feature flag may expose success yet.

### Phase B: authoritative snapshot and durable migrations

Extend durable trust-pool reconstruction and hot registry projection with manifest identity and epoch binding. Add immutable pool/private fields to relay-blind reservation state, route snapshots, settlement receipts, request logs, gateway reservation/replay metadata, and provider journal records. Migrations are additive, transactional, idempotent, downgrade-readable where possible, and retain old rows with an explicit protocol generation.

Old rows must never be upgraded by inference. A missing protocol generation means legacy global v1/plaintext semantics.

### Phase C: reservation and client binding

Consume Build 2's accepted identity selection contract. Implement pool-scoped authenticated reservation before encryption, successor client verification, pin rotation/revocation handling, and SPEC-040 wallet/API authorization. Retain the existing pool-rejection guard for global v1 objects.

### Phase D: lifecycle-safe opaque dispatch

Implement coherent rechecks, successor opaque dispatch, provider journal namespace, decryption/inner validation, cancellation, and crash recovery. Keep cross-provider failover impossible.

### Phase E: receipt verification and settlement

Implement the successor receipt producer/parser/verifier, Build 3 evidence lookup, bounded pending deadline, immutable outcome finality, and exactly-once quota/settlement reconciliation. Preserve reward exclusion unless separately governed.

### Phase F: product surfaces and observability

Expose separate encryption, pool authorization, receipt, observation, settlement, and rewards states with last-updated/freshness. Add operator metrics and bounded audit reason codes without content, keys, raw pins, raw account/session credentials, candidate membership, or per-provider pool health leakage.

### Phase G: qualification

Run local services, deterministic cross-language fixtures, actual MLX inference on a physical supported Mac, signed journey capture, and the complete independent code/security/architecture/adversarial/product review gate. Production qualification and activation remain a later explicit decision.

## 8. Migration, rollout, and rollback

- Use new protocol/version discriminators and additive nullable storage columns with a non-null semantic generation resolved by loader code.
- Backfill nothing that would invent pool, observation, or receipt authority. Legacy rows remain legacy.
- Deploy read support and capability reporting before write/admission support.
- Enable successor admission only when gateway, coordinator, provider, verifier, and buyer client positively advertise compatible versions and stores are migrated.
- Keep the feature default off. Pool-scoped relay-blind requests continue to fail closed during partial rollout.
- Rollback disables new reservations first. It does not delete state or reopen burned reservations. Dispatched rows continue through status/reconciliation; unknown work remains `do_not_resubmit`.
- Never roll back by accepting a private request as global, accepting a v5 receipt as v4, clearing exclusion flags, or relaxing coordinator-wide enforce policy.

## 9. Observability contract

Metrics must separate these stages and outcomes:

- reservation requests by protocol generation and safe failure class;
- buyer/pool authorization denial without pool-existence labels;
- acceptable-identity no-candidate decisions;
- lifecycle recheck failures by stage;
- generation/epoch/policy drift;
- envelope/route/model/artifact/receipt/observation digest mismatch;
- predispatch burns, dispatch commits, cancellations, uncertain recovery;
- receipt parse/verification outcomes and pending age;
- settlement finality and duplicate suppression;
- reward exclusion reason.

Logs and audit rows may contain bounded digests, versions, generations, timestamps, and closed reason codes. They must not contain plaintext request content, ciphertext, provider private keys, identity-pin material beyond approved fingerprints, credentials, wallet signatures, or unredacted candidate membership. Unauthorized errors and timing remain non-enumerating.

## 10. Acceptance criteria

Implementation acceptance requires all of the following:

1. One authorized private-pool nonstream request and one streaming request complete through actual MLX inference on a supported physical Mac and settle under the successor verified contract.
2. Evidence records exact model id/hash, artifact/admission digest, runtime/profile, observation generation, Mac hardware/OS/runtime, provider identity fingerprint, pool manifest/generation, and receipt version without recording request plaintext or secrets.
3. An unauthorized buyer, nonmember provider, disallowed model, stale policy, stale generation, revoked member, revoked buyer authorization, revoked/expired pin/key, unsupported observation profile, and incompatible receipt all fail closed.
4. Digest substitution for pool, manifest, generation/epoch, model/artifact, envelope/transcript, provider identity, output, usage, observation, or receipt is detected and cannot settle.
5. Concurrent consume/replay dispatches at most once. No existing ciphertext is sent to a second provider.
6. Revocation between reservation and consume, consume and quota, quota and dispatch arm, and arm and WebSocket commit prevents a new dispatch. Postdispatch revocation follows immutable settlement/recovery rules without replay.
7. Existing plaintext global, plaintext Trusted Pool, global relay-blind v1, wallet, SPEC-008, and v0.4 settlement regression suites remain green.
8. Reward eligibility remains excluded unless the Build 3 governed mapping explicitly covers and accepts the request. No payout or production flag changes occur.
9. Local success is reported separately from physical-Mac qualification, signed evidence, deployed-service evidence, and Trusted Pool production qualification.

## 11. Hardware and external prerequisites

- A supported physical Apple Silicon Mac capable of running the chosen covered MLX model/runtime/profile.
- The exact trusted model artifact and Build 1 network admission identity.
- Product Build 2 supported client/pin provisioning and two independently pinned providers for the full selection journey.
- Product Build 3 reference/calibration inputs, active covered observation profile, generation-aware evidence, expiry/revocation controls, and governed settlement mapping.
- Local Docker runtime for Docker-dependent cross-service/PostgreSQL tests.
- A separate protected signing environment for journey evidence if conformance promotion is later attempted.
- Production operator credentials/configuration are not needed and must not be placed in the worktree.

## 12. Explicit non-goals

- Product Build 2 client implementation or buyer-identity contract invention.
- Product Build 3 observation/calibration implementation or provider-wide compute-integrity claims.
- Changes to billing arithmetic, epoch policy, rewards issuance, withdrawals, payouts, or economic activation.
- Creator revenue split execution.
- Confidential-compute, anonymity, unlinkability, provider blindness, or no-retention claims.
- Cross-provider ciphertext failover, automatic replay, split inference, or HTTP private dispatch.
- Production Trusted Pool promotion, release, deploy, or feature enablement.
- Treating a provider signature, status adapter, one probe, deterministic fixture, or local integration test as proof of physical computation or production qualification.

## 13. Roadmap-outcome traceability

| Roadmap outcome | Plan step | Verification |
|---|---|---|
| Establish receipt versions and digest binding before runtime work | Phase A; sections 6.1, 6.4, 6.7 | Closed-schema/golden-vector tests T01-T10 in the Build 4 test spec; governance checks; independent plan audit |
| Pool-scoped reservations and lifecycle authorization rechecks | Phases B-D; sections 6.2, 6.3, 6.5 | T11-T27, including every revocation race cut |
| Encrypted dispatch bound to request/provider/model/pool | Sections 6.4 and 6.6 | T28-T38; digest-substitution matrix; no-next-provider assertions |
| Explicitly supported verification/settlement | Phase E; sections 6.7-6.8 | T39-T55; real settlement journey; replay/finality tests |
| Preserve plaintext and protected evidence | Compatibility matrix and Phase G | T56-T63 broad regressions and protected evidence validation |
| Do not infer physical compute from signatures | Sections 6.7-6.8 | T46-T51 observation negative matrix |
| Authorized private pool request settles correctly | Acceptance criteria 1-2 | T64 physical MLX signed journey, reported as hardware-qualified only when actually run |
| Production qualification remains separate | Sections 8, 11, 12 | Acceptance report explicitly marks deployment/activation blocked |

## 14. Current disposition

This plan is reviewable now, but runtime implementation is blocked. The exact Build 2 acceptable-identity contract and Build 3 observation covered-key/generation contract are not accepted on this branch. When they land, revise sections 6.3-6.8 with their exact normative fields and digests, re-run the independent plan gate, and only then begin Phase A or source implementation.
