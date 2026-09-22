# Product Build 4 plan v2 — independent adversarial review (Sol)

## Review integrity and disposition

- Repository `HEAD`: `1d2c930bad81704dd0acc0322226725d8b64aceb`.
- `merge-base(HEAD, origin/main)`: `1d2c930bad81704dd0acc0322226725d8b64aceb`.
- `implementation-plan-v2.md` SHA-256: `ca2508bd6a75df8b07620bccb159f1c5dea128c50f9f94cb7b127e301260c050` — matches the review input.
- `test-spec-v2.md` SHA-256: `dfd151990058d9e4941269763758a30839cd64d1124391d131bcf781c3e142c3` — matches the review input.
- Scope: planning/assessment only. No runtime implementation is requested or credited while the accepted Product Build 2 identity/private-client contracts and Product Build 3 production-observation/stable-identity/economics contracts are absent.

**Disposition: FAIL.** The revision closes four of the eight v1 High/Medium findings, but H2, H3, M4, and M5 remain open. The runtime gate correctly remains closed.

## Findings

### HIGH H2 — The request-start receipt-key identity is pinned, but the verification key and emergency-revocation rule are still not closed

**Evidence.** `PrivatePoolRouteAuthorityV1`, the reservation, AAD, and successor receipt now bind receipt-key authority/source, id, digest, generation, validity, and revocation high-water mark (`docs/product-roadmap/build-4/implementation-plan-v2.md:147`, `:171`, `:192-193`, `:253-254`). That closes the identity-binding half of v1 H2. It does not define the immutable source from which the verifier obtains the exact raw Ed25519 public key after provider reconnect, coordinator restart, routine rotation, or removal of the previous key from the live registry. The retention table retains a “receipt-key snapshot” but the defined snapshot contains a public-key or key-record **digest**, not the verification material or a durable resolver record (`implementation-plan-v2.md:147`, `:318`). The current verifier requires raw `ProviderReceiptPubkey` bytes and verifies both their derived id and the signature (`phase4-coordinator/internal/billing/settlement_verifier.go:179-184`), while current provider state keeps current/previous raw keys in the in-memory registry and drops the previous key after its grace window (`phase4-coordinator/internal/pool/provider.go:213-223`, `:1091-1107`). The plan separately defers postcommit emergency revocation to “the owning SPEC's explicit finality rule” without choosing that rule (`implementation-plan-v2.md:228`), and T66 repeats the deferral rather than asserting an outcome (`docs/product-roadmap/build-4/test-spec-v2.md:349-351`).

**Consequence.** A valid receipt can become unverifiable after restart or rotation even though its key identity is correctly pinned, or an implementation can fall back to a current/provider-supplied key to recover. A compromised key revoked after `dispatch_committed` has no defined debit, credit, quarantine, payout-readiness, or finality result. Both failures sit on the positive-settlement trust boundary.

**Required correction.** Define in the successor SPEC-015/SPEC-022 contract a durable receipt-key authority record that retains or deterministically resolves the exact accepted raw public key (or complete authenticated key record) by authority/source/id/generation, verifies its digest on every load, survives restart/rotation for the full settlement/reconciliation/dispute horizon, and is never sourced from receipt input. Define the exhaustive precommit and postcommit routine-rotation/emergency-revocation money/finality table before Phase A begins. Extend T66 with restart after live-key eviction, resolver corruption/unavailability, archived-key digest mismatch, and every postcommit emergency-revocation ordering.

### HIGH H3 — The proposed shared dispatch fence does not serialize gateway-owned authorization and quota state with coordinator enqueue

**Evidence.** The plan assigns credential/wallet authorization to SPEC-040 (`implementation-plan-v2.md:71`) but requires every buyer-authorization mutation to enter a coordinator `private_dispatch_fence` before becoming effective (`implementation-plan-v2.md:232`). SPEC-040 instead makes the gateway SQLite admission transaction the wallet authorization/dispatch linearization point and expressly allows an already `dispatch_armed` request to proceed after wallet revocation (`specs/SPEC-040-wallet-native-buyer-sessions.md:158`, `:230-232`). The plan defines no cross-service commit, durable authorization lease, generation acknowledgement, or failure protocol that can make a gateway transaction and a coordinator in-process fence one serialization domain.

The sequence is also internally inconsistent: the supported journey and lifecycle tests burn consume before quota (`implementation-plan-v2.md:49`; `test-spec-v2.md:130`), matching current SPEC-041 (`specs/SPEC-041-relay-blind-request-encryption.md:146`, `:152`) and the current gateway flow (`phase5-gateway/internal/router/relay_blind_success.go:175-213`), but section 6.7 creates the quota reservation first and consumes second (`implementation-plan-v2.md:236-238`). T67 instructs tests to mutate authority “under the shared dispatch fence” (`test-spec-v2.md:353-355`), which assumes away the gateway/coordinator boundary and its crash, timeout, and lost-ack cases.

**Consequence.** Wallet/account revocation or quota cancellation can commit in the gateway while a stale coordinator enqueue still wins, despite the plan's claim that the mutation prevents all provider bytes. Conversely, ambiguous ordering can burn single-use material without a recoverable quota effect or leave a quota hold whose coordinator attempt never reached the defined state. The claimed final authorization linearization and failure recovery are therefore not implementable or proven as written.

**Required correction.** Choose one exact consume/quota/dispatch-arm order and reconcile it with SPEC-040 and SPEC-041. For every gateway-owned authority, define a concrete cross-service protocol: immutable authorization generation in the signed reservation/outbox, who issues and durably records the dispatch lease, which transaction is the authorization cutoff, how revocation waits for or invalidates outstanding leases, and exact behavior for request/response loss and crashes on both sides. If SPEC-040's gateway `dispatch_armed` cutoff remains authoritative, narrow the coordinator fence claim accordingly; if revocation must win until provider enqueue, amend SPEC-040 with a durable two-party fencing protocol. T67 must drive the real gateway and coordinator stores across these barriers rather than injecting all mutations inside one mocked fence.

### MEDIUM M4 — The mixed-version matrix still omits non-adjacent and multi-old combinations

**Evidence.** Section 6.10 calls the rollout matrix “bounded” and requires all-new, all-old, every single-old component, and each adjacent old pair (`implementation-plan-v2.md:296`). T71 repeats only those combinations plus readiness/cache cases (`test-spec-v2.md:369-371`). It does not require non-adjacent old pairs, three-or-more-old combinations, or the Cartesian interaction between component versions and each independently migrated/unmigrated store. The plan's universal claim is stronger: any unsupported client, gateway, coordinator settlement backend, provider, or store must fail before quota (`implementation-plan-v2.md:65`, `:127-129`). The offline verifier correction is sound—it is not a request hop—but that does not make the request-path matrix exhaustive.

**Consequence.** A false-positive capability intersection caused by two non-adjacent legacy components, mixed store readiness, or a stale capability cache can remain untested and admit a successor request through quota before failing. Single-old tests do not prove that independently cached/generated capability sets compose monotonically under every mixed rollout state.

**Required correction.** Require a generated exhaustive matrix over the supported-version bits of client, gateway, coordinator/settlement backend, and provider, crossed with every relevant store schema/readiness generation and cache reconnect/downgrade state. Alternatively, define and property-test a monotone intersection invariant that proves every unsupported bit forces the same prequota terminal outcome, then retain representative end-to-end combinations. Assert zero reservation consumption, quota, provider bytes/inference, settlement, and reward mutation for every rejected row.

### MEDIUM M5 — Retention is not bound to the pool policy and has no rule for privacy-max versus recovery-min conflicts

**Evidence.** SPEC-042 requires every pool to bind a `retention-policy id` whose normative matrix specifies field-by-field permission, retention, aggregation, and viewer class, and it requires tighter pool-specific overrides for such data as buyer IP and request logs (`specs/SPEC-042-pool-control-plane.md:188-192`). The proposed route authority does not capture a retention-policy id/version or resolved matrix digest (`implementation-plan-v2.md:135-151`). Section 6.12 instead sets a shared attempt duration to the maximum of replay, execution, settlement, reconciliation, dispute, and audit windows “with an explicit privacy maximum” (`implementation-plan-v2.md:313`). A privacy maximum is an upper bound, so treating it as another operand of a maximum does not define what happens when a pool promises deletion sooner than mandatory recovery evidence may be deleted. The record table applies broad record-level categories rather than SPEC-042's field-level rules (`implementation-plan-v2.md:315-324`). T72 tests time boundaries and dependency order, but not pool-policy resolution, field-level redaction/deletion, viewer restrictions, or rejection of an unsatisfiable retention promise (`test-spec-v2.md:373-375`).

**Consequence.** The system can accept a pool whose published retention promise cannot coexist with replay, settlement, or dispute recovery, then either delete authority needed to prevent duplicate execution/money effects or retain buyer/provider metadata longer than the signed pool policy permits. Product privacy/status surfaces can therefore be truthful at display time but false in storage behavior.

**Required correction.** Bind the accepted retention-policy id, version, and canonical matrix digest in the request-start route authority. Define per-field minima and maxima, redaction/aggregation transitions, viewer classes, and tombstone contents. At admission, compute whether every mandatory recovery minimum fits within the pool's privacy maximum; reject with a closed non-enumerating policy-unsatisfied result when it does not. Extend T72 across two pools with different policies, every governed field/viewer class, unsatisfiable min/max combinations, policy rotation, partial purge/restart, and proof that tombstones contain no field the pool policy forbids retaining.

## Plan-v1 finding closure assessment

| v1 finding | v2 assessment | Evidence |
|---|---|---|
| H1 — observation trust failure could become `zero_settled` | **Closed** | The plan mandates pending-to-`quarantined`, refund/release, zero provider credit, reward exclusion, payout-readiness false, and terminal finality; `zero_settled` is limited to fully verified non-creditable terminals (`implementation-plan-v2.md:267-275`; `test-spec-v2.md:208-217`, `:219-253`, `:279-281`). |
| H2 — receipt key not pinned | **Open — HIGH** | Identity is now pinned throughout, but immutable verification material and the emergency-revocation money/finality rule remain undefined. See H2 above. |
| H3 — no dispatch linearization contract | **Open — HIGH** | The coordinator-local fence does not compose with gateway-owned wallet/auth/quota transactions, and consume/quota ordering conflicts. See H3 above. |
| M1 — observation digest producer undefined | **Closed** | The coordinator exclusively captures and persists the full accepted Build 3 request-start state, derives two-stage digests, sends only the authenticated digest to the provider, and settles from the persisted capture (`implementation-plan-v2.md:197-212`; `test-spec-v2.md:357-359`). |
| M2 — migration/rollback vague | **Closed** | The component/store matrix specifies new/old startup, disabled-mode behavior, snapshot restrictions, drain/reconciliation owners, fail-closed downgrade, and roll-forward; T69-T70 exercise those cases (`implementation-plan-v2.md:298-309`, `:362-370`; `test-spec-v2.md:361-367`). |
| M3 — protected evidence contract absent | **Closed** | The plan defines the artifact domain/signature authority, ancestry and dirty-tree binding, command/output hashes, freshness, immutable joins, semantic validator, rejection cases, and local-vs-conformance signer boundary; T63-T65 exercise them (`implementation-plan-v2.md:391-397`; `test-spec-v2.md:317-345`). |
| M4 — mixed-version matrix incomplete | **Open — MEDIUM** | Singles and adjacent pairs are specified, but non-adjacent/multi-old and component/store Cartesian combinations remain absent. See M4 above. |
| M5 — retention/pruning absent | **Open — MEDIUM** | Attempt-level dependency ordering is added, but the signed pool retention matrix and privacy-max conflict rule are absent. See M5 above. |

## Required restrictions and gate checks

- **Pool-scoped global relay-blind rejection is preserved.** The current restriction remains explicit (`implementation-plan-v2.md:27`, `:125`, `:342`); no pool object may be normalized into global v1.
- **Relay-blind plus coordinator-wide enforce rejection is preserved.** The current global restriction is retained and may be replaced only by the separately versioned, request-scoped successor after normative approval (`implementation-plan-v2.md:28`, `:370`).
- **Positive verification and rewards exclusions are preserved.** Existing global relay-blind v1 remains excluded; the successor can clear positive-verification exclusion only after all successor verification gates pass, while rewards remain excluded unless Build 3 explicitly maps the exact request, and payout execution remains disabled (`implementation-plan-v2.md:29`, `:281`, `:287`; `test-spec-v2.md:267-273`, `:297-315`).
- **Dependency gate remains correctly closed.** Exact accepted Build 2 identity/client fields and Build 3 observation/stable-identity/economics fields must replace provisional fields before Phase A or runtime work, followed by another zero-Critical/High/Medium review (`implementation-plan-v2.md:109`, `:332`, `:464`). This review does not demand runtime implementation while those prerequisites are absent.

## Counts and verdict

- Critical: **0**
- High: **2**
- Medium: **2**
- Low: **0**
- Info: **0**

**FAIL.** The plan-review gate remains closed because High and Medium findings are present. Runtime implementation remains dependency-blocked and must not begin from plan v2.
