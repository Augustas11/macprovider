# Product Build 4 implementation plan v2

Status: planning and contract assessment only  
Repository base: `1d2c930bad81704dd0acc0322226725d8b64aceb` (`origin/main`, inspected 2026-09-11)  
Historical roadmap baseline: `422fc2f13fc62c1ff8987522f822d9ef856e4a96`  
Implementation gate: **closed** pending accepted Product Build 2 and Product Build 3 contracts
Plan-v1 review disposition: **failed** with 0 Critical, 3 High, and 5 Medium findings; every High and Medium correction is incorporated in this revision

## 1. Product outcome

An authorized buyer can select an eligible provider in a Trusted Pool before encryption, submit one relay-blind request bound to that provider, model, pool policy, and pool generation, and receive a settlement result only when the request has both a compatible cryptographic receipt and independently valid evidence required by the covered Product Build 3 observation profile.

The selected provider reads plaintext. The gateway and coordinator do not read request content, but they continue to see authentication, routing bindings, ciphertext size, response content, usage, settlement metadata, and pool identity. The product must describe this as relay-blind request encryption within a Trusted Pool. It must not call the result confidential compute, anonymity, unlinkable settlement, end-to-end encryption, or privacy from the provider.

There is a normative wording conflict that must be resolved before implementation. SPEC-041 defines Layer 3 relay-blind scope as hiding request content from gateway/coordinator while the selected provider reads it and response content remains visible to relays. SPEC-042 R009 currently requires language saying both prompt and response content are visible to coordinator and provider even under Layer 3. The SPEC-042 amendment must align its Layer 3 disclosure with SPEC-041: request content hidden from gateway/coordinator; selected provider reads request plaintext; relays may see response content and metadata. No amendment may broaden the privacy claim beyond that boundary.

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
3. The client asks for a pool-scoped reservation, naming canonical model `M`, endpoint, stream mode, caps, and the authenticated acceptable-provider object from Build 2: either the actual sorted fingerprint set or an authenticated coordinator-resolvable handle. No request content is sent.
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

An old client, gateway, coordinator settlement backend, or provider that lacks the successor private-pool capability fails before quota. An incompatible offline verifier cannot authorize settlement and makes coordinator settlement readiness false. Existing global relay-blind v1, plaintext global, plaintext Trusted Pool, and SPEC-015 v0.4 settlement journeys continue unchanged.

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
| Product Build 3 / SPEC-036 successor | Covered compute observation key, generation, reference/calibration, expiry/revocation, independently accepted stable provider identity/Sybil-resistance authority and cost model, and governed reward mapping | Provider terminal evidence cannot substitute for independent observation. |
| SPEC-005 | Usage arithmetic and ordinary accounting | No formula or economic-policy changes. |
| SPEC-021/rewards | Useful-work reward eligibility | Remains excluded unless Build 3 explicitly authorizes the exact covered private request. |

## 5. Dependency graph and implementation gate

```text
Build 2 accepted acceptable-identity contract
  -> coordinator receives the actual authenticated acceptable-fingerprint set, or an authenticated handle it can resolve authoritatively
  -> pool-scoped reservation can filter and select before encryption
  -> client can verify provider/pool binding

Build 3 accepted covered observation contract
  -> stable provider identity/Sybil-resistance authority and economics assumptions are accepted
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

The runtime implementation gate opens only when the exact accepted Build 2 acceptable-identity fields, Build 2 supported-client artifact/API contract, Build 3 covered-observation fields, and Build 3 stable-identity/economics prerequisites are copied into a revised plan and the adversarial plan review again reports zero Critical, High, and Medium findings. Phase A normative edits and source implementation remain blocked until then; review of this provisional contract can proceed now.

## 6. Proposed normative contracts for review

These identifiers are provisional until the owning SPEC amendments land. Field sets are intentionally explicit so review can challenge them before code exists.

### 6.1 Protocol generation and capability negotiation

Keep all global relay-blind v1 objects byte-for-byte compatible. Introduce a separate generation for pool-scoped private requests:

- reservation: `relay-blind-pool-reservation-v1`;
- envelope/body encoding: `relay-blind-pool-request-v1`;
- consume/status: matching `relay-blind-pool-*-v1` objects;
- receipt contract: a new SPEC-015 receipt version, provisionally `receipt_version: "5"`;
- positive capabilities advertised by the buyer client, gateway, coordinator settlement backend, and the authenticated provider session.

An object from one generation cannot be parsed or normalized into the other. A v1 global reservation cannot accept pool fields. A pool request cannot fall back to global v1.

The supported-version intersection is computed before reservation issuance and repeated before quota. The client sends its supported closed protocol and receipt versions. The gateway uses its local version set plus a fresh, authenticated coordinator capability response. The coordinator response is derived from the exact loaded reservation parser, migrated store schema, receipt parser/key registry, accepted observation-profile registry, and settlement implementation; this is the runtime settlement-backend/verifier readiness capability. The standalone `phase7-verify` tool is an offline consumer and is not treated as a request-path capability hop. The provider capability is bound to its authenticated WebSocket session and release/admission generation.

Each capability record includes producer identity, protocol set, receipt-version set, schema generation, issued time, expiry, and monotonic connection/config generation. Hop authentication uses the existing authenticated channel or a contract-approved signature. Gateway caches expire no later than the record expiry and are invalidated on coordinator reconnect, provider reconnect, config reload, downgrade, or store migration-generation change. An empty intersection, stale record, unknown future version, unmigrated store, or unavailable settlement backend returns a typed unsupported result before reservation consumption, quota hold, provider bytes, inference, or settlement/reward mutation.

### 6.2 Authoritative pool-policy snapshot

Add one immutable `PrivatePoolRouteAuthorityV1` record captured at request start under the dispatch-fence serialization boundary described in section 6.6. Its canonical `route_basis_digest` covers every field below except `observation_capture_digest`; the final `route_snapshot_digest` covers the canonical route basis plus the coordinator-owned `observation_capture_digest`. This two-stage construction avoids a circular digest while linking both records.

- `pool_id`;
- `manifest_version`;
- `manifest_core_digest`;
- `pool_generation`;
- `pool_state_epoch_hash`;
- `policy_not_before_unix` and `policy_expires_at_unix`;
- `buyer_authorization_generation` and a non-secret authorization-record digest;
- acceptable-provider authorization source/handle, set generation, sorted unique accepted relay-identity fingerprints, and canonical acceptable-set digest;
- selected provider relay-identity fingerprint and stable internal provider/session binding;
- `model_allowlist_digest`;
- effective settlement mode and receipt contract;
- required Build 3 observation profile id/version/generation;
- accepted SPEC-015 receipt-key authority/source, key id, public-key or key-record digest, key generation, validity interval, and revocation high-water mark;
- provider membership/admission record digest;
- policy predicate digest;
- observation capture digest;
- capture timestamp and bounded freshness deadline.

The hot registry projection must carry all fields from the accepted durable manifest/lifecycle record. Recomputing part of the record from a newer policy at settlement is forbidden. `pool_state_epoch_hash` must be a domain-separated digest of the stable pool id, accepted manifest digest, lifecycle state, generation, and the exact membership/revocation high-water mark. It cannot be a hash of a mutable in-memory map iteration.

### 6.3 Pool-scoped reservation

The closed reservation request must include the normal endpoint/model/stream/cap/size fields plus:

- canonical `pool_id` selected from authenticated credential scope;
- the final Build 2 authenticated acceptable-provider object: either the sorted unique relay-identity fingerprint set and its generation, or an authenticated opaque handle that the coordinator resolves to that complete set before filtering; a client-supplied digest alone is never selection authority;
- supported private-pool protocol and receipt-contract versions;
- the buyer-observed pool-policy digest when the client has one.

The successful reservation must bind:

- every existing global v1 reservation field;
- the complete `PrivatePoolRouteAuthorityV1` digest and its buyer-safe constituent fields;
- selected provider relay identity fingerprint and signed request-encryption key record;
- acceptable-set digest/generation and proof that the selected relay identity is in the actual coordinator-authorized set;
- canonical requested model, provider model selector, and authoritative model/artifact admission digest;
- receipt contract, accepted receipt-key source/id/digest/generation/validity/revocation snapshot, and Build 3 observation requirement;
- `failover_policy: disabled`.

Reservation creation must happen only after buyer authorization and selection against one consistent pool snapshot. The public response identifies only the selected relay identity and accepted receipt-key identity needed for buyer verification; it must not expose unrelated candidates, stable internal provider ids, or pool membership. Internally, the route snapshot binds the selected relay identity to the stable provider/session authority used by dispatch and settlement.

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
11. acceptable-set digest/generation and selected relay-identity fingerprint;
12. model/artifact admission digest;
13. receipt contract and accepted receipt-key source/id/digest/generation/validity/revocation high-water mark;
14. required observation profile id/version/generation and coordinator-owned observation-capture digest.

The SPEC-040 semantic signature must cover the exact same authority fields plus the canonical envelope digest and route. The gateway must strip buyer-supplied internal authority headers and regenerate them only from authenticated state.

### 6.5 Coordinator-owned observation capture and audit artifact

After Product Build 3 accepts one production observation scope, the coordinator captures one immutable `ComputeObservationCaptureV1` at request start, before quota and dispatch, from the authoritative Build 3 observation store. This is the exact accepted SPEC-036 closed request-start capture, wrapped with Build 4 attempt/route linkage; Build 4 does not define a reduced parallel observation schema. The provider cannot submit or select this record. Its canonical content includes every accepted load-bearing field, grouped here for review:

- account scope, request id, attempt id, selected internal provider/session binding, and selected relay identity;
- `route_basis_digest`, canonical model id, model hash, artifact/admission digest, runtime/profile id and version;
- full covered key: stable provider identity, provider/assigned id, model and target hash, tokenizer identity, sampler stage/profile/coverage-set digest, corpus, threshold, hardware-runtime class/digest, target generation, and signed-catalog digest;
- complete composite SPEC-022 and SPEC-036 policy versions/modes/digests/coverage/effective-enforce binding and linked route-basis digest;
- captured state/expiry/adjudication origin, window id, circuit-breaker state/scope, capture time, observation expiry and revocation high-water mark;
- complete reference-set admissibility record/digest/status/quorum/fault-check version, every sorted reference event/source/failure-domain identity, source-independence evidence, runtime-build provenance, golden-fixture validation, and refresh timestamp;
- accepted calibration record/digest and stable provider identity/Sybil-resistance authority generation/cost-model version required by the Build 3 activation contract;
- a closed availability/outcome code that decides whether positive-verification-required dispatch is allowed. Missing or unreadable load-bearing fields fail closed.

The capture is persisted transactionally with the route snapshot before dispatch. Its domain-separated digest becomes `observation_capture_digest` in the final route snapshot, reservation, AAD, wallet signature, durable consume state, and authenticated provider dispatch. The provider only echoes and signs this coordinator-supplied digest. Settlement compares the receipt reference to the persisted capture and never substitutes current observation state, a provider-chosen value, or a later looser profile.

After the provider receipt arrives, the coordinator creates a separate canonical `ComputeSettlementAuditArtifactV1` binding account/request/attempt/provider, final route-snapshot digest, observation-capture digest, receipt-tuple digest, verifier version, and outcome/reason. This coordinator-owned artifact is the authoritative audit object. A provider signature over an observation-capture or audit-artifact reference proves only that it signed the reference; it does not prove that the referenced observation is true. If the owning SPEC later requires the provider receipt to reference a complete audit artifact, that artifact must be frozen before signing without a circular digest.

### 6.6 Lifecycle authorization rechecks

Perform one coherent recheck at reservation, consume, quota hold, durable outbox preparation, and the final fenced committed enqueue defined in section 6.7. Each recheck must cover:

- buyer credential/session validity and pool authorization generation;
- acceptable provider identity and pin validity;
- pool routeability, policy validity, manifest identity, generation, and epoch;
- provider membership/revocation and required pool capability;
- provider authenticated session and relay-blind key validity/revocation;
- accepted receipt-key id/digest/generation/validity and revocation high-water mark;
- canonical model allowlist and authoritative model/artifact admission;
- settlement mode/receipt-key capability;
- Build 3 observation profile availability when policy requires positive verified settlement.

Any mismatch before dispatch burns the reservation and releases/refunds a held quota reservation. The client creates a fresh transaction. After dispatch, no mismatch authorizes rerouting or re-encryption. Receipt verification uses the immutable accepted request-start receipt key even if a routine rotation occurs after dispatch; an emergency revocation follows the owning SPEC's explicit finality rule and cannot silently select a new key. A policy update cannot retroactively weaken or rewrite the captured settlement contract. Restrictive revocation may cancel according to existing SPEC-042 semantics, but settlement still uses the immutable request-start authority.

### 6.7 Dispatch linearization and encrypted binding

The coordinator owns the only dispatch linearization point. All mutations that can invalidate a private request—buyer authorization, acceptable-set generation, pool lifecycle/manifest/membership, provider session or encryption key, receipt-key registry, model/admission generation, and Build 3 observation availability/revocation—must enter a coordinator `private_dispatch_fence` serialization domain before becoming effective. Each subsystem retains its own durable source of truth, but mutation publication advances a named epoch under this fence and cancels registered predispatch leases before returning.

For one attempt the dispatch sequence is closed:

1. The gateway proves a fresh capability intersection and creates a quota reservation, but does not final-debit it.
2. Coordinator consume atomically burns the reservation and persists the route snapshot, observation capture, and attempt state.
3. Coordinator storage uses a compare-and-swap from `consumed` to `dispatch_prepared` and writes a durable outbox record containing every authority epoch and the complete authenticated first provider frame.
4. Under `private_dispatch_fence`, the coordinator rereads every authoritative generation/revocation state, verifies it equals the outbox snapshot, registers a one-use `PrivateDispatchLease`, and performs a bounded nonblocking enqueue of the complete authenticated first frame to the exact authenticated provider session.
5. The successful enqueue is `dispatch_committed`: the first point at which any request byte is eligible to leave the coordinator. It and a revocation mutation serialize under the same fence. If revocation wins, enqueue is forbidden, the outbox becomes `predispatch_rejected`, and zero provider bytes are sent. If enqueue wins, later revocation is postdispatch and follows cancellation/settlement rules without failover.
6. After enqueue, the coordinator marks the outbox `dispatched`. A crash after enqueue but before that mark becomes `dispatch_uncertain`; recovery never enqueues again. Provider at-most-once claim and status reconciliation determine the terminal result.

No network I/O may block while holding the fence: the per-session queue must accept the already bounded frame immediately or reject it. The transport can write only frames carrying a committed lease id/MAC bound to provider session, request, attempt, envelope, route snapshot, and authority epochs. It cannot synthesize or retry a frame from `dispatch_prepared`. Queue rejection, failed final validation, or quota cancellation before commit burns the attempt, marks an exact predispatch failure, and releases/refunds the quota reservation. Failure or uncertainty after commit never permits ciphertext reuse or provider substitution.

The authenticated outer dispatch context must carry digests for the envelope, selected provider/session, private-pool route authority, model/artifact admission, receipt contract, accepted receipt-key snapshot, observation capture, and required observation profile. These fields live inside SPEC-008 protection when that leg is enabled and otherwise rely on the authenticated WebSocket session. HTTP transport remains forbidden.

The provider journal execution identity must add the private-pool authority digest and receipt contract to its domain-separated filename/preimage. A global v1 claim and pool v1 claim must never collide. The provider validates every clear binding before decryption and validates inner request/model/caps after decryption. It must pin one runtime handle for tokenization, inference, and receipt production.

### 6.8 Successor receipt and verifier

SPEC-015 v0.4 remains exact and unchanged. Define a new closed receipt tuple for pool-scoped relay-blind settlement. At minimum it must bind:

- `receipt_version`, signature algorithm, and the exact accepted request-start receipt-key source/id/public-key-or-record digest/generation/validity/revocation snapshot;
- account scope, request id, and attempt number;
- selected relay-identity fingerprint and internal stable provider/session binding checked from the private route snapshot; no unrelated candidate identity is disclosed;
- canonical model id, loaded model hash, and artifact/admission digest;
- route snapshot digest and private-pool route-authority digest;
- pool id, manifest version/digest, generation, and state-epoch hash;
- envelope digest and AEAD transcript digest, not a fabricated relay-visible plaintext prompt hash;
- provider validation digest and terminal-evidence digest;
- output hash/prefix range and terminal state/timestamps;
- strict usage object;
- Build 3 observation profile id/version/generation and coordinator-owned request-start observation-capture digest.

Whether a buyer-only plaintext-content digest is included must be decided by the owning SPEC after privacy analysis. Relays must not require or persist a plaintext prompt hash merely to reproduce v0.4 semantics.

Verifier outcomes remain `pending`, `verified`, `quarantined`, and `zero_settled`. Cryptographic validity is necessary but not sufficient. `verified` additionally requires:

- exact route, pool, envelope, provider, model/artifact, terminal, output, and usage matches;
- no replay, overlap, version, or timing failure;
- signature verification against the exact accepted request-start receipt key and provenance, with no settlement-time key substitution;
- independently valid Build 3 observation evidence for the exact covered model/runtime/profile/generation and request window;
- policy mapping that permits positive settlement.

Provider validation, a provider signature, an artifact assertion, or observation availability alone cannot produce `verified` or reward eligibility. Missing, expired, revoked, mismatched, or otherwise untrusted observation evidence yields `pending` only until the bounded evidence deadline and then **must become `quarantined`**. The buyer reservation is released/refunded, provider credit stays zero, rewards stay excluded, and payout readiness stays false. `zero_settled` is reserved for a fully verified, non-creditable terminal outcome; it is never used for receipt or observation trust failure. No later receipt or evidence can change a terminal quarantine.

### 6.9 Settlement and rewards

Use the existing gateway quota journal, coordinator settlement tables, request log, and reconciliation flow. Add immutable private-pool fields and a supported receipt-version discriminator. Do not create another ledger.

`PositiveVerificationExcluded` may become false only on the dedicated successor path after successful verification. `RewardsExcluded` remains true by default. Clearing it requires the Build 3 governed reward-state mapping to name the exact covered request profile; it is not implied by settlement verification. Payout execution remains disabled and out of scope.

### 6.10 Compatibility rules

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

The bounded rollout matrix covers the client, gateway, coordinator/settlement backend, provider, and stores. Each single-old-component case, each adjacent pair of old components, all-old, all-new, unknown-future versions, reconnect/downgrade, stale capability cache, settlement-backend unavailability, and migrated/unmigrated store combinations must have an explicit outcome. Unsupported combinations fail before reservation consumption and quota. Because the offline verifier is not a dispatch hop, its compatibility is represented by the coordinator's authenticated settlement-backend readiness capability derived from the loaded parser, receipt-key registry, observation registry, and schema generation.

### 6.11 Component and store migration/rollback matrix

| Component/store | New binary with old store | Old binary with migrated store | Disabled-mode read/write | In-flight and rollback rule |
|---|---|---|---|---|
| Gateway quota/reservation database | Startup applies additive migration transactionally before advertising support; no private admission until complete | Fail startup closed after any successor row or irreversible schema generation exists; snapshot restore allowed only if no post-snapshot traffic occurred | May read/reconcile known rows; cannot create successor rows | Post-traffic rollback drains/reconciles with the new binary; old binary is not started against successor traffic |
| Coordinator relay-blind/outbox store | Add closed protocol, authority, observation, lease, and dispatch state columns/tables idempotently | Fail startup closed if successor rows exist or schema is not explicitly legacy-readable | New admissions off; status/reconciliation remain on | `dispatch_prepared`, `dispatch_committed`, `dispatch_uncertain`, and terminal rows are preserved; uncertain rows never redispatch |
| Coordinator settlement/receipt stores | Add receipt-version, accepted-key, observation-capture/audit, pool authority, and finality fields without backfill invention | Fail startup closed for successor rows; never parse v5 as v4 | Parse/reconcile existing successor rows, no new private admission | Pending rows reach exact deadline outcome; verified/quarantined/zero-settled finality is immutable |
| Request logs/audit artifacts | Add versioned bounded metadata and linked attempt ids | Old readers ignore only fields whose omission cannot change authorization or money; otherwise startup/export fails closed | Read-only export allowed with redaction | Records required by active reconciliation/dispute cannot be pruned during rollback |
| Provider journal | New provider creates a separate generation namespace; legacy entries remain legacy | Old provider must refuse a journal containing successor namespace/marker | May recover/finish existing successor claims; cannot accept new claims | Claim and terminal evidence survive restart; no conversion to global v1 and no second execution |
| Offline verifier inputs/tools | New parser rejects unknown old/new mismatches explicitly | Old parser returns unknown version and cannot authorize settlement | Read-only | Coordinator readiness remains false until the deployed settlement parser supports the version |

Every migration has a schema marker, precondition check, transactional application, idempotent rerun, and postcondition. A zero-traffic rollback may restore a pre-deploy snapshot only when gateway and coordinator attest no post-snapshot reservation, quota, dispatch, settlement, or journal activity. After any traffic, rollback means disable admission, drain/reconcile with compatible binaries, preserve evidence, and roll forward if an old binary cannot safely open the stores. The reconciliation owner is coordinator settlement for receipt/outbox state, gateway quota reconciliation for buyer reservations, and provider recovery for journal claims.

### 6.12 Retention and pruning contract

All stores share a non-secret canonical `attempt_id`. Retention duration is the maximum of the accepted SPEC-041 replay/key-expiry window, active execution, SPEC-022 pending deadline, settlement reconciliation window, supported buyer dispute/appeal window, and operator audit requirement, with an explicit privacy maximum approved in the owning SPEC. Configuration cannot shorten an already captured attempt's deadline.

| Record | Minimum retention/tombstone | Purge dependency |
|---|---|---|
| Reservation, replay nonce, acceptable-set and encryption-key revocation | Through signed expiry plus replay retention; tombstone through the same bound | Never before provider journal/outbox can no longer accept or recover the attempt |
| Route authority, receipt-key snapshot, observation capture | Through terminal settlement plus reconciliation and dispute windows | Never while receipt, settlement, quota, audit, or appeal is active/pending/uncertain |
| Dispatch outbox/lease and provider journal | Through terminal provider claim plus replay/recovery window | Tombstone survives deletion of bulky frame/ciphertext metadata; purge only after coordinator/provider states agree |
| Receipt and compute settlement audit artifact | Through settlement finality, retrieval, reconciliation, and dispute windows | Purge after quota and provider-credit effects are durable and no appeal is open |
| Gateway quota row and coordinator settlement row | Per accounting/audit authority | Retain linkage or tombstone to prevent duplicate debit/credit after related privacy-bounded records are purged |
| Sanitized request log/status | Bounded by approved operational/privacy policy | Prune only after authoritative money/replay records no longer depend on it |

Dependency-aware pruning runs from bulky nonauthoritative payload metadata toward tombstones, then authority/evidence records, never the reverse. Partial purge, clock movement, restart, delayed receipts, configuration cycling, and a dispute cannot remove a linked record while the attempt is active, pending, uncertain, appealable, or unreconciled. Pruning must eventually remove privacy-bounded records after all minima and dependencies expire.

## 7. Phased changes after dependencies land

### Phase A: normative amendments and vectors

Amend SPEC-040, SPEC-041, SPEC-042, SPEC-015, SPEC-022, and the applicable SPEC-036/Build 3 contract. Update `AUTHORITY.json`, `CONFORMANCE.json`, generated indexes, and requirement mappings. Freeze closed schemas, binary framing, digest domains, error mapping, capability versions, and cross-language positive/negative golden vectors.

Acceptance for this phase: the dependency contracts have landed, their exact fields have replaced the provisional fields here, and an independent adversarial plan/contract review has zero Critical, High, or Medium findings. No Phase A normative edit or runtime feature flag may begin before that gate.

### Phase B: authoritative snapshot and durable migrations

Extend durable trust-pool reconstruction and hot registry projection with manifest identity and epoch binding. Add immutable pool/private fields to relay-blind reservation state, route snapshots, settlement receipts, request logs, gateway reservation/replay metadata, and provider journal records. Migrations follow the exact component/store matrix in section 6.11, are transactional and idempotent, and retain old rows with an explicit protocol generation. Unsafe downgrade is fail-closed rather than best effort.

Old rows must never be upgraded by inference. A missing protocol generation means legacy global v1/plaintext semantics.

### Phase C: reservation and client binding

Consume Build 2's accepted identity selection contract. Implement pool-scoped authenticated reservation before encryption, successor client verification, pin rotation/revocation handling, and SPEC-040 wallet/API authorization. Retain the existing pool-rejection guard for global v1 objects.

### Phase D: lifecycle-safe opaque dispatch

Implement coherent rechecks, successor opaque dispatch, provider journal namespace, decryption/inner validation, cancellation, and crash recovery. Keep cross-provider failover impossible.

### Phase E: receipt verification and settlement

Implement the successor receipt producer/parser/verifier, Build 3 evidence lookup, bounded pending deadline, immutable outcome finality, and exactly-once quota/settlement reconciliation. Preserve reward exclusion unless separately governed.

### Phase F: product surfaces and observability

Expose separate encryption, pool authorization, receipt, observation, settlement, and rewards states with last-updated/freshness. Add operator metrics and bounded audit reason codes without content, keys, raw pins, raw account/session credentials, candidate membership, or per-provider pool health leakage.

The accepted Product Build 2 handoff must name the supported client artifact, repository, commit/version, and response/status schema. Repository-local CLI fixtures prove only that client. The deployed buyer console in `MalibuAI/malibu` is a separate integration owner and qualification surface; the historical local frontdoor is not accepted as its substitute. Owner-approved client/UI fixtures must cover every independent state, stale/last-known timestamps, privacy wording, and recovery action.

### Phase G: qualification

Run local services, deterministic cross-language fixtures, actual MLX inference on at least one physical supported Mac, protected journey capture, and the complete independent code/security/architecture/adversarial/product review gate. Deterministic tests exercise two independently pinned provider identities; a second physical provider is stronger evidence but is not required to prove the one-real-model Build 4 journey. Production qualification and activation remain a later explicit decision.

## 8. Migration, rollout, and rollback

- Use new protocol/version discriminators and the per-store schema markers in section 6.11. Nullable columns are permitted only when loaders require an explicit legacy protocol generation; absence never implies successor authority.
- Backfill nothing that would invent pool, observation, or receipt authority. Legacy rows remain legacy.
- Deploy read support and capability reporting before write/admission support.
- Enable successor admission only when the buyer, gateway, coordinator settlement backend, and authenticated provider session establish a fresh compatible intersection and stores are migrated.
- Keep the feature default off. Pool-scoped relay-blind requests continue to fail closed during partial rollout.
- Rollback follows section 6.11: disable admission first; use snapshot restore only with a proved zero-traffic boundary; otherwise drain/reconcile on compatible binaries and roll forward when old binaries cannot safely read the stores. It does not delete state or reopen burned reservations. Dispatched/uncertain rows continue through status/reconciliation and never redispatch.
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

The public observable set for unknown/unauthorized/disabled pools and unapproved identities is exactly HTTP status, closed error code, response byte-length class, retryability, and recovery action. The implementation uses the same authentication work, bounded dummy lookup, response serializer, and deterministic minimum response floor for those cases; tests use a fake clock to prove identical floor behavior. Local microbenchmarks additionally compare warmed p50/p95/p99 over at least 1,000 samples per class with fixed CPU/load and require each quantile difference to stay within the larger of 10% or 250 microseconds. Network measurements are qualification evidence only and use separately stated topology and thresholds; noisy CI timing does not gate correctness when the deterministic floor invariant passes.

### 9.1 Protected journey evidence contract

Local physical-hardware qualification requires a protected `private_pool_journey_v1` artifact; conformance promotion requires the same schema signed by a separately governed conformance signer. The canonical artifact is strict canonical JSON with a domain-separated Ed25519 signature over all bytes except the signature field. The trusted signer registry, signer purpose, custody, rotation, and revocation are operator-governed and never sourced from the provider under test.

The artifact includes repository remote, commit, required ancestry to the reviewed implementation commit, submodule/package locks, dirty-tree status and patch digest when an explicitly approved instrumented tree is used; capture start/end and expiry; host hardware/OS/runtime; exact commands and exit statuses; component versions; sanitized raw-output file hashes; and immutable joins for account scope, request id, attempt id, acceptable-set digest, selected relay identity, internal provider/session binding, route basis/snapshot, observation capture, envelope/transcript, dispatch lease/outbox, provider claim/runtime/model/artifact, receipt tuple/signature, compute audit artifact, coordinator settlement row, gateway quota row, and buyer response/status.

A semantic validator checks canonical bytes, signer trust/purpose/time, artifact expiry, commit ancestry, dirty-tree declaration, command allowlist, successful fresh execution, every join/digest, raw-output hashes, distinct request ids, expected physical MLX runtime evidence, and absence of secrets/plaintext. It rejects missing joins, mismatched hashes, reused attempts/evidence, untrusted/revoked signers, expired captures, unexplained dirty state, fixture backend substitution, or a separate MLX selftest that is not joined to the settled request. Protected evidence proves only the stated local run; deployment and Trusted Pool production qualification remain separate.

## 10. Acceptance criteria

Implementation acceptance requires all of the following:

1. One authorized private-pool nonstream request and one streaming request complete through actual MLX inference on a supported physical Mac and settle under the successor verified contract.
2. Evidence records exact model id/hash, artifact/admission digest, runtime/profile, observation generation, Mac hardware/OS/runtime, selected relay identity, internal provider/session binding, accepted receipt-key source/id/digest/generation, pool manifest/generation, and receipt version without recording request plaintext or secrets.
3. An unauthorized buyer, nonmember provider, disallowed model, stale policy, stale generation, revoked member, revoked buyer authorization, revoked/expired pin/encryption key/receipt key, unsupported observation profile, and incompatible receipt all fail closed.
4. Digest substitution for pool, manifest, generation/epoch, model/artifact, envelope/transcript, provider identity, output, usage, observation, or receipt is detected and cannot settle.
5. Concurrent consume/replay dispatches at most once. No existing ciphertext is sent to a second provider.
6. Revocation at every lifecycle cut, including a deterministic barrier immediately before the `dispatch_committed` enqueue, serializes against the common dispatch fence. When revocation wins, provider bytes and inference are zero, the attempt is burned, and quota is released/refunded. Postcommit revocation follows immutable settlement/recovery rules without replay.
7. Existing plaintext global, plaintext Trusted Pool, global relay-blind v1, wallet, SPEC-008, and v0.4 settlement regression suites remain green.
8. Reward eligibility remains excluded unless the Build 3 governed mapping explicitly covers and accepts the request. No payout or production flag changes occur.
9. Local success is reported separately from physical-Mac qualification, signed evidence, deployed-service evidence, and Trusted Pool production qualification.

## 11. Hardware and external prerequisites

- A supported physical Apple Silicon Mac capable of running the chosen covered MLX model/runtime/profile.
- The exact trusted model artifact and Build 1 network admission identity.
- Product Build 2 supported client/pin provisioning and two independently pinned provider identities for deterministic selection coverage. The physical journey requires at least one actual supported Mac; a second physical Mac is optional stronger evidence.
- Product Build 3 reference/calibration inputs, active covered observation profile, generation-aware evidence, expiry/revocation controls, independently accepted stable provider identity/Sybil-resistance authority and cost model, and governed settlement mapping.
- Local Docker runtime for Docker-dependent cross-service/PostgreSQL tests.
- A trusted local qualification signer for physical-run evidence. Conformance promotion later requires its separately governed signer/environment.
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
| Establish receipt versions and digest binding before runtime work | Phase A; sections 6.1, 6.4, 6.8 | Closed-schema/golden-vector tests T01-T10 in the Build 4 test spec; governance checks; independent plan audit |
| Pool-scoped reservations and lifecycle authorization rechecks | Phases B-D; sections 6.2, 6.3, 6.6-6.7 | T11-T27, including deterministic dispatch-fence barriers at every revocation source |
| Encrypted dispatch bound to request/provider/model/pool | Sections 6.4 and 6.7 | T28-T38; digest-substitution matrix; no-next-provider assertions |
| Explicitly supported verification/settlement | Phase E; sections 6.5 and 6.8-6.9 | T39-T55; real settlement journey; replay/finality tests |
| Preserve plaintext and protected evidence | Compatibility matrix and Phase G | T56-T63 broad regressions and protected evidence validation |
| Do not infer physical compute from signatures | Sections 6.5 and 6.8-6.9 | T39-T51 observation negative matrix |
| Authorized private pool request settles correctly | Acceptance criteria 1-2 | T64 physical MLX protected journey, reported as hardware-qualified only when actually run |
| Production qualification remains separate | Sections 8, 11, 12 | Acceptance report explicitly marks deployment/activation blocked |

## 14. Plan-v1 finding resolutions

| Finding | Resolution in v2 |
|---|---|
| H1 observation trust failure could become `zero_settled` | Section 6.8 now mandates pending-to-quarantined, buyer release/refund, zero provider credit/reward/payout readiness, and reserves `zero_settled` for fully verified non-creditable terminals. |
| H2 receipt key not pinned | Sections 6.2-6.8 bind exact request-start receipt-key authority/id/digest/generation/validity/revocation through reservation, AAD, lifecycle, dispatch, receipt, and settlement. |
| H3 dispatch race lacked a linearization point | Section 6.7 defines the shared mutation fence, durable outbox, one-use lease, exact successful enqueue commit, quota effects, crash uncertainty, and deterministic revocation ordering. |
| M1 observation digest producer undefined | Section 6.5 defines the coordinator-owned two-stage route/capture construction, authenticated provider delivery, immutable settlement lookup, and separate audit artifact. |
| M2 migration/rollback vague | Sections 6.11 and 8 define component/store startup, read/write, snapshot, drain, reconciliation, downgrade, and roll-forward rules. |
| M3 physical evidence contract absent | Section 9.1 defines canonical signed artifact fields, joins, custody, freshness, dirty-tree handling, and semantic rejection rules. |
| M4 mixed-version matrix incomplete | Sections 6.1 and 6.10 define authenticated capability sources/freshness, coordinator settlement-backend readiness, and bounded old/new/store combinations with prequota failure. |
| M5 retention/pruning absent | Section 6.12 defines shared attempt linkage, minimum and maximum windows, tombstones, dependency order, recoverability, and eventual bounded deletion. |
| L1 timing oracle unmeasurable | Section 9 defines a deterministic response-floor invariant and a reproducible local distribution check. |
| L2 buyer-visible owner ambiguous | Phase F names the Build 2 handoff fields and separates repository-local client evidence from `MalibuAI/malibu` deployed-console qualification. |

## 15. Current disposition

This plan is reviewable now, but runtime implementation is blocked. The exact Build 2 acceptable-identity contract and Build 3 observation covered-key/generation contract are not accepted on this branch. When they land, revise sections 6.3-6.8 with their exact normative fields and digests, re-run the independent plan gate, and only then begin Phase A or source implementation.
