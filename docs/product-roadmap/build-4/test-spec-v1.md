# Product Build 4 test specification v1

Status: pre-implementation, planning-only  
Repository base: `1d2c930bad81704dd0acc0322226725d8b64aceb`  
Companion plan: `docs/product-roadmap/build-4/implementation-plan-v1.md`

## 1. Test principles

1. A passing fixture proves only the boundary it exercises. Deterministic Swift fixtures are not actual MLX inference; local services are not deployed services; local Mac execution is not production qualification.
2. Every command must select at least one test and finish successfully. Skipped, timed-out, interrupted, zero-selected, or historical runs are not fresh passing evidence.
3. No positive-settlement assertion is valid unless cryptographic receipt checks, immutable route/pool/envelope/model bindings, and the applicable Product Build 3 independent-observation gate all pass.
4. Provider assertion, signature, decryption success, artifact preparation, status publication, or a single probe never suffices for physical-compute or reward claims.
5. Every private request is single-provider after encryption. Tests must count selection/dispatch calls and fail if a second provider receives the same ciphertext.
6. Plaintext, global relay-blind v1, SPEC-008, wallet, and existing v0.4 settlement protections are regression contracts.
7. Production activation, rewards/payout activation, and operator-secret use are prohibited in this task.

## 2. Evidence classes

| Class | Meaning | May prove |
|---|---|---|
| S | Static/source and schema checks | Contract shape, owner boundaries, forbidden code paths |
| U | Unit tests with in-memory/temp durable stores | Parsers, state transitions, exact digest and authorization rules |
| X | Cross-language golden vectors | Go/Swift byte-for-byte framing, signing, AEAD, and receipt parity |
| I | Local multi-service integration | Gateway/coordinator/provider orchestration and durable recovery |
| M | Actual MLX inference on a physical supported Mac | Real model/runtime execution for the recorded hardware/profile |
| P | Protected signed journey evidence | Reproducible evidence artifact and governance mapping |
| D | Deployed-service qualification | Production configuration/rollout behavior; out of scope here |

## 3. Required fixtures and harness controls

- Two buyer-approved relay identities `A` and `B`, with independently provisioned pins.
- One unrelated/unapproved relay identity `C`.
- Two Trusted Pools `P` and `Q`, distinct identity cores and manifest chains.
- Pool `P` authorizes buyer `buyer-P`, admits `A` and `B`, and allowlists model `M`.
- Pool `Q` does not authorize `buyer-P` and uses overlapping provider/model labels to expose cross-pool substitution.
- A canonical admitted model `M`, disallowed model `N`, and one alias/class case.
- Successor and legacy gateway/coordinator/provider/verifier versions.
- Build 3 observation fixtures for valid, missing, stale, revoked, wrong profile, wrong model/runtime, wrong generation, and reference/calibration failure.
- Fault injection at every durable transition: before/after reservation write, consume burn, quota hold, dispatch arm, provider claim, validation evidence, first byte, terminal evidence, receipt persist, settlement effect, and seal.
- Counters for provider selection, dispatch, decryption, inference entry, receipt creation, settlement effect, and reward projection.

## 4. Contract and compatibility tests

### T01 — Global v1 byte compatibility

Class: X/U. Freeze existing global relay-blind reservation, AAD, envelope, consume, status, and provider-claim vectors. Successor code must produce identical bytes and digests for legacy inputs.

### T02 — Protocol generations are disjoint

Class: U/X. A global parser rejects every pool-generation object and every pool parser rejects global v1, including objects with appended fields, omitted discriminator, duplicate discriminator, nulls, wrong types, trailing JSON, and mixed domain tags.

### T03 — Closed pool reservation schema

Class: U. Accept exactly the approved fields. Reject duplicate, unknown, missing, null, noncanonical pool id, unsorted/duplicate acceptable identities, over-limit arrays/strings, fractional/exponent/overflow integers, cap overflow, and trailing values.

### T04 — Pool route-authority canonical digest

Class: X. Go and Swift produce the same digest for the complete authoritative snapshot. Each field mutation changes the digest. Reordered maps or membership iteration cannot affect canonical bytes.

### T05 — Successor AAD/transcript golden vectors

Class: X. Go and Swift agree on exact bytes/key/nonce/ciphertext/tag. Mutate each pool, provider, identity-set, model/artifact, cap, observation, and receipt-contract field independently and require decryption/authentication failure.

### T06 — Wallet semantic-signature binding

Class: U/X. Wallet/API authorization covers pool id, manifest/digest, generation/epoch, route-authority digest, acceptable identities, envelope digest, model/artifact, caps, receipt contract, and observation generation. Replay into another pool/provider/model/generation fails before quota.

### T07 — Successor receipt closed tuple

Class: U/X. Parser accepts exactly the new receipt field set and strict usage object. Missing/extra/duplicate/null/wrong-type/noncanonical/overflow/trailing data is invalid. No parser coerces v4 to the successor version.

### T08 — Receipt signing preimage parity

Class: X. Provider and verifier agree on canonical bytes and signature. Mutation of every tuple/usage field invalidates the signature or later authoritative comparison.

### T09 — Unknown receipt version

Class: U/I. Old and successor verifiers return `inconclusive: unknown_receipt_version`; gateway/coordinator do not debit, positively settle, reward, or reinterpret it as v4.

### T10 — Existing v0.4 immutability

Class: U/I. Existing v0.4 vectors and plaintext settlement tests remain byte-identical. A v0.4 receipt attached to pool-scoped relay-blind traffic is rejected as contract-incompatible and cannot settle positively.

## 5. Selection and authorization tests

### T11 — A-only pin when B sorts first

Pool `P` admits A and B; routing order puts B first; buyer accepts only A. Reservation selects A or returns no acceptable candidate. B is never returned or dispatched.

### T12 — A+B selection

Buyer accepts A+B. Selection may choose either eligible provider according to normal policy, and the response proves the chosen relay identity belongs to the committed acceptable set.

### T13 — No acceptable candidate

P has healthy B, buyer accepts only A, and A is unavailable. Return a non-enumerating typed unavailable result before encryption/quota. Do not silently use B.

### T14 — Unapproved identity rejection

Provider C is globally healthy and pool-member-shaped but absent from the buyer set. It cannot appear in reservation, response, dispatch, or recovery.

### T15 — Unauthorized pool does not enumerate

Unknown pool, known-but-unauthorized pool, disabled pool, and removed buyer authorization return the same public error shape and timing class before registry predicate evaluation.

### T16 — Pool selection source precedence

Credential/session scope is authoritative. Explicit input may narrow only. Conflicting sources reject; an input cannot widen scope or substitute Q for P.

### T17 — Wallet pool authorization

An accepted Build 2/040 wallet session selects P only when the session scope and signature cover P and the current manifest digest. Stale scope or changed manifest fails before quota.

### T18 — Pool membership and capability

Selected identity must map to the exact authenticated provider identity/session, be a nonrevoked P member, advertise the successor capability, and satisfy all P predicates. Global admission alone is insufficient.

### T19 — Model allowlist and authoritative identity

M succeeds only with matching canonical/provider model and Build 1 admission/artifact identity. N, partial class allowlist, alias drift, model hash drift, artifact drift, and provider assertion without authority fail before dispatch.

### T20 — Policy settlement requirement

Pool observe policy cannot be silently upgraded to verified settlement. Pool verified policy routes only if the successor receipt/observation prerequisites exist. A missing prerequisite returns `pool_settlement_mode_unsatisfied` or the approved successor equivalent.

## 6. Lifecycle and race tests

For T21-T27, exercise each change at four cuts: after reservation/before consume, after consume/before quota, after quota/before dispatch arm, and after arm/before WebSocket commit. Each predispatch case must burn the old transaction, prevent charge, and record zero dispatch. Repeat relevant cuts concurrently with 100+ attempts under race detection.

### T21 — Provider membership revocation

Both graceful and immediate revocation prevent new dispatch at T+epsilon. The old generation/epoch cannot pass a later recheck.

### T22 — Buyer authorization removal

Removing buyer-P authorization advances an authority generation/epoch and invalidates uncommitted P reservations.

### T23 — Pin/relay identity rotation and revocation

Old pin, acceptable-set commitment, key id, or key record cannot survive replacement/revocation/expiry. New transaction material succeeds only after independent provisioning.

### T24 — Manifest/policy transition

New manifest version, policy expiry, pause, drain, retire, and restrictive model/settlement change invalidate uncommitted work. A loosening change does not rewrite an already captured contract.

### T25 — Provider session/release/admission drift

Reconnect with a new assigned session, binary/admission generation, model hash, or artifact digest invalidates the old reservation.

### T26 — Observation profile drift

Profile generation change, expiry, revocation, missing reference/calibration, or wrong model/runtime causes predispatch failure when positive verified settlement is required. It cannot be represented as fresh positive evidence.

### T27 — Restart/failover reconstruction

Gateway, coordinator, and provider restart between every state transition. Durable reconstruction preserves pool authority, burned reservations, provider claims, and settlement finality. Unknown state never becomes available or retryable.

## 7. Dispatch, privacy, and replay tests

### T28 — Exact provider/session dispatch

The ciphertext is dispatched only to the provider/session named by the reservation. Session substitution fails before provider decryption.

### T29 — Pool/manifest/generation substitution

Mutate each pool authority field in public envelope, internal header, WS frame, provider evidence, receipt, route snapshot, and persisted row. Every mismatch fails closed and cannot settle.

### T30 — Model/artifact substitution

Mutate requested model, provider selector, loaded model, model hash, artifact/feed/admission digest, or runtime handle between tokenization and generation. Reject before inference or quarantine settlement; never relabel.

### T31 — Digest substitution

Independently mutate envelope digest, transcript digest, route snapshot digest, private-pool authority digest, validation digest, terminal digest, output hash, usage digest, and observation digest. No mutation reaches `verified`.

### T32 — Replay and concurrency

Concurrent consume of one envelope admits at most once. Retry after gateway/coordinator/provider restart remains replay. Rate/capacity classifiers never mask replay.

### T33 — No ciphertext failover

Queue-full, NAK, timeout, provider disconnect, pool revocation, and capability loss after encryption all produce zero calls to B/C or HTTP fallback. Recovery action is never “reuse ciphertext.”

### T34 — Cancellation before dispatch

Burn/refund safely, zero provider execution, new reservation required.

### T35 — Cancellation after dispatch

No replay/failover. Known delivered output and usage follow the approved terminal-state table; uncertainty is `do_not_resubmit`.

### T36 — Relay plaintext absence

Gateway/coordinator logs, request snapshots, audit rows, traces, errors, panic output, and metrics contain no prompt/messages/tool schemas/response schemas, plaintext prompt hash, keys, or raw pin material. Provider sees plaintext as disclosed.

### T37 — Response visibility truth

Gateway/coordinator can observe response content as the protocol states. Product metadata never claims response confidentiality, confidential compute, anonymity, unlinkability, or privacy from provider.

### T38 — Unauthorized error/timing oracle

Unknown and unauthorized pool/identity cases have equivalent public shape and bounded timing distribution. Authorized callers may receive actionable predicate codes without candidate lists or unrelated identities.

## 8. Verification and settlement tests

### T39 — Valid cryptography without observation is not payable

A perfectly signed successor receipt and valid provider evidence with missing Build 3 observation remains pending/quarantined per policy. Positive settlement and reward counters remain zero.

### T40 — Provider signature alone is insufficient

A malicious provider signs a self-consistent receipt without the independent covered observation. It cannot become verified, payable, or reward eligible.

### T41 — Observation alone is insufficient

A valid current observation with a missing/invalid receipt, wrong route binding, or mismatched output cannot settle.

### T42 — Exact covered observation

Only evidence matching model, artifact, runtime, profile, provider generation, observation generation, request-start window, reference/calibration policy, and revocation state can satisfy the independent gate.

### T43 — Stale and revoked observation

Evidence expiring or revoked before the request-start snapshot is unusable. Expiry after immutable capture follows the accepted Build 3 contract and cannot be re-evaluated inconsistently after restart.

### T44 — Observation/profile change mid-request

The request-start snapshot remains immutable, while an emergency revocation follows the accepted Build 3 finality rule. Tests prove no silent use of a later, looser profile.

### T45 — Output and usage binding

Streaming and nonstreaming delivered output hashes match coordinator-observed bytes. Provider overreported input/output is bounded or rejected per the closed terminal table. Ciphertext size is never treated as input tokens.

### T46 — Terminal-state matrix

Cover normal completion, provider pre-generation rejection, provider error, buyer cancel, gateway timeout, upstream disconnect, partial output, unknown postdispatch, receipt missing, receipt late, and contradictory terminal evidence. Assert debit, provider settlement, hold/refund, and finality separately.

### T47 — Receipt deadline

Missing evidence remains pending only through a fixed route-time deadline. Late receipts cannot overturn a terminal quarantine or settle twice.

### T48 — Exactly-once settlement

Duplicate receipt delivery, concurrent reconciler runs, gateway restart, coordinator restart, lost seal, and usage-event redrive produce one final settlement effect.

### T49 — Cross-account/request/attempt replay

A valid receipt from another account scope, request id, attempt, provider, pool, or generation cannot settle the current hold.

### T50 — Pool-label dispute

Any discrepancy among route snapshot, reservation, receipt, and settlement pool fields prevents pool attribution and positive private verification. Existing SPEC-005 handling follows the amended normative table without relabeling to global.

### T51 — Reward exclusion boundary

Verified private settlement still has `RewardsExcluded=true` unless the accepted Build 3 reward mapping explicitly covers it. Unknown/stale observation, unsupported profile, or historical hold cannot show current earning.

### T52 — No payout/economic activation

All private journey tests assert no payout-ready mutation, no withdrawal state change, no reward campaign activation, and no config enabling production enforcement.

### T53 — Incompatible receipt versions

Legacy v1-v3, v4, successor, malformed successor, and future unknown versions produce the exact compatibility outcomes. Only the successor may enter private positive verification.

### T54 — First-terminal-wins

Once verified, zero-settled, or quarantined finality is recorded, contradictory later evidence cannot change debit, provider credit, pool attribution, rewards, or payout readiness.

### T55 — Settlement observability

Metrics and status distinguish cryptographic receipt validity, observation gate, settlement outcome, pending age, and reward exclusion. Sanitized output contains no request plaintext or secret material.

## 9. Regression tests

### T56 — Plaintext global behavior

Feature disabled and enabled configurations preserve existing global plaintext selection, retry/failover, route-snapshot digest, v0.4 receipt, and settlement behavior.

### T57 — Plaintext Trusted Pool behavior

Existing authorization, membership, predicates, generation fences, model allowlist, capability negotiation, no-global-spill, and lifecycle cancellation tests remain green.

### T58 — Global relay-blind v1 behavior

Existing nonstream/stream, replay, cancellation, recovery, and explicit positive-verification/reward exclusions remain green and byte compatible.

### T59 — SPEC-008 behavior

Provider-leg encryption remains independently configurable. Successor private dispatch binds its authority inside the protected payload when enabled without changing its claim scope.

### T60 — Wallet/API authentication

Existing wallet replay, model/cap scope, API key, demo exclusion, and internal-header stripping remain green.

### T61 — Existing receipt verifier

All v0.1-v0.4 compatibility and settlement tests remain green; successor parsing is additive and closed.

### T62 — Existing rewards path

Plaintext verified work continues under current mapping. Relay-blind exclusions remain effective unless exact successor coverage is explicitly proven.

### T63 — Governance and evidence validation

SPEC indexes, authority/conformance checks, signed-journey semantic validation, and evidence expiration behavior pass. Historical or expired evidence cannot promote the new requirements.

## 10. End-to-end acceptance

### T64 — Physical Mac private-pool verified settlement journey

Class: M + I + P.

Run one nonstreaming and one streaming request through the supported buyer client, gateway, coordinator, and actual Swift/MLX provider on a physical supported Mac. The pool contains two independently pinned providers; force each provider in separate runs. Record:

- repository commit and dirty-state declaration;
- gateway/coordinator/provider/client versions;
- Mac model/chip/RAM, macOS, Swift, MLX/runtime version;
- canonical model id, loaded hash, artifact/feed/admission digests;
- provider relay identity fingerprint and session generation;
- pool id, manifest version/digest, generation/epoch;
- receipt version and route/envelope/observation digests;
- Build 3 covered profile/reference/calibration/generation and freshness;
- terminal/output/usage/settlement results;
- explicit `RewardsExcluded` result;
- no production side effects and no secrets/plaintext in the artifact.

Pass requires the coordinator's persisted receipt/settlement outcome, gateway quota finality, and buyer-visible state to agree. A fixture backend or separate MLX selftest does not satisfy T64.

### T65 — Physical Mac negative qualification

On the same setup, exercise cancellation, provider reconnect, stale/revoked relay key, pool member revocation, policy generation change, observation revocation, digest substitution, replay, and incompatible receipt version. Confirm no cross-provider ciphertext failover and no double settlement.

## 11. Suggested fresh commands after implementation

Exact test names will be finalized with implementation. The minimum command families are:

```bash
cd phase4-coordinator && go test ./internal/relayblind ./internal/trustpool ./internal/buyer ./internal/billing ./internal/rewards -race -count=1
cd phase5-gateway && go test ./internal/relayblind ./internal/router ./internal/storage -race -count=1
cd test/integration && go test -run 'RelayBlind|TrustedPool|PrivatePool|Settlement' -race -count=1
cd phase7-verify && go test ./... -race -count=1
cd phase3-binary && swift test --filter RelayBlind
cd phase3-binary && swift test
make vet
make test
```

Swift CLI tests do not replace Xcode app tests. Docker-dependent integration is counted only with a live Docker runtime. Physical MLX and protected journey commands must be captured exactly when the dependencies exist.

## 12. Acceptance report rules

The Build 4 acceptance report must use separate fields:

- implementation completion;
- local unit/cross-language verification;
- local multi-service integration;
- actual MLX physical-hardware verification;
- protected signed evidence;
- deployed-service verification;
- production qualification/activation;
- unresolved dependency or operator blockers.

No aggregate “Build 4 complete” claim is allowed while T64/T65, the independent review gate, or production qualification remain unproven. Local implementation can be complete while hardware and production qualification remain explicitly blocked.
