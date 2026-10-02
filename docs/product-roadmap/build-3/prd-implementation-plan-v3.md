# Product Build 3 — PRD and Implementation Plan

Plan revision: `build3-plan-v3`
Plan status: awaiting independent adversarial approval
Repository/base: `Augustas11/macprovider@1d2c930bad81704dd0acc0322226725d8b64aceb`
Scope: production compute observations and first-job visibility for one covered key; no enforcement, economic activation, payment execution, or deployment

## Decision and gate boundary

If approved, this revision authorizes only the bounded feasibility work and precommitted evidence protocol described below. It does **not** authorize the durable runtime source, reward projection, app, or portal implementation. No physical reference or calibration measurement may begin until Gate A0 approves the exact immutable profile and numeric calibration protocol. Slices 1–7 remain blocked until Gate B approves the resulting evidence bundle. Positive availability remains blocked until a built release and its qualification manifest pass Gate C. Every gate requires an independent GPT-5.6 Sol review with zero Critical, High, and Medium findings on exact committed digests.

The candidate locator for hook feasibility is:

| Dimension | Exact candidate value |
| --- | --- |
| Canonical model key | `meta-llama/llama-3.2-3b-instruct` |
| MLX artifact repository | `mlx-community/Llama-3.2-3B-Instruct-4bit` |
| Artifact revision | `7f0dc925e0d0afb0322d96f9255cfddf2ba5636e` |
| Artifact manifest SHA-256 | `e7e5bff4248768b4db7a53afb3b514ba5867b800f63d1abd0330eaf08e54aa90` |
| CLI build under inspection | `1.8.123` at repository commit `1d2c930bad81704dd0acc0322226725d8b64aceb` |
| `mlx-swift-lm` | `3.31.4`, revision `bd4b7434e6bdb588c7ef55706ff8904cb7fd4c57` |
| `mlx-swift` | `0.31.4`, revision `dc43e62d7055353c7f99fa071a4e71d29dfddc44` |
| `swift-transformers` | `1.3.4`, revision `c21fdcde390313a6d98d8e33a346f2c3486c3ab0` |
| Sampler stage | `post_sampler_probabilities` |
| Profile ID | `build3_llama32_3b_post_sampler_v1` |

The repository suffix `4bit` is not quantization identity. Gate A0 rejects any null, wildcard, inferred, or `TBD` load-bearing field.

### Acyclic artifact construction

Authority is built in one direction. No artifact contains its own digest or the digest of an artifact that depends on it.

1. `compute_observation_profile.v1` freezes the candidate values above, closed quantization descriptor, tokenizer/chat-template/prompt corpus, context and seed semantics, sampler processor order, positions, probability encoding and normalization, limits, protocol/schema versions, and one exact predeclared hardware/runtime class predicate. Its `profile_digest` is computed last.
2. `compute_calibration_protocol.v1` binds `profile_digest` and freezes all cohort, sample, statistical, threshold-selection, stopping, exclusion, expiry, and failure rules before evidence. Its `protocol_digest` is computed last. Gate A0 reviews these two antecedent manifests plus the feasibility result.
3. Signed `compute_reference_event.v1`, `compute_golden_validation.v1`, and `compute_calibration_result.v1` records bind both antecedent digests. They never bind the later bundle or release.
4. `compute_observation_evidence_bundle.v1` binds the antecedent digests and the resulting reference, golden, calibration-result, threshold, policy, and revocation-list digests. Gate B reviews the bundle and the revised implementation plan. The bundle contains no production release digest.
5. After implementation and signing, `compute_observation_release_candidate.v1` binds the evidence-bundle digest, implementation commit, production package digest, executable digest, code-signing identity, and schema fixture digests. Qualification-run leases and results bind its `release_candidate_digest` and are marked `prequalification_evidence`; they cannot create a positive state.
6. `compute_observation_release_qualification.v1` binds the release-candidate digest and the resulting fresh hook/probe/physical/Xcode/browser qualification-record digests. Gate C reviews it. Only this final `qualification_digest` can name a positive production observation key.

Pre-Gate-B probe leases/results bind `profile_digest` and `protocol_digest` and are `evidence_only`. Reference and calibration records additionally bind their own record IDs and predecessor digests. Post-build pre-Gate-C qualification runs bind `release_candidate_digest` and are `prequalification_evidence`; they cannot publish positive availability or enter request/reward capture. After Gate C, production leases, results, observation windows, request captures, status, and reward shadow decisions bind `qualification_digest`, `release_candidate_digest`, `evidence_bundle_digest`, `profile_digest`, and the exact reference/calibration/policy digests. Changing any constituent yields a new qualification digest and returns the key to `unknown`.

## Product result

For the one Gate-C-approved qualification, a provider can see a sanitized, narrowly scoped observation state and trace a real request through immutable request-start capture, receipt persistence, billing projection, local qualification-only shadow accrual, app presentation, and portal presentation. Every surface separates observation, historical request evidence, ledger balance, withdrawal eligibility, payment availability, and freshness.

Missing, stale, revoked, mismatched, unreadable, incomplete, or uncovered evidence produces a conservative state. It never becomes confirmed idleness, current earning, broad provider integrity, or physical-computation proof by inference.

## Code-grounded starting point

| Outcome | Status at base | Evidence and implication |
| --- | --- | --- |
| Production observation owner | Missing | `internal/ws/compute_integrity_status.go` defines an injected read seam; `cmd/coordinator/main.go` does not inject it. `computeintegrity.Store` is in-memory. |
| Probe primitives | Partial | `internal/computeintegrity/probe.go` validates DTOs. There is no SPEC-036 scheduler/result ingestion or Swift probability extraction. Existing `LosslessnessProbeRuntime.providerInconclusiveForUnavailableSampler` returns unsupported. |
| Exact MLX hook | Blocked pending feasibility | `Tests/mlx-stage-spikeTests` proves staged Llama forward/argmax only. It may skip without a model and does not expose the post-sampler distribution. |
| Request-start compute capture | Partial | `billing/settlement_compute_integrity.go` stores immutable enforce-mode captures, but insertion is not linearized with live WS session/model authority and is not projected to rewards. `internal/buyer/route_snapshot.go` currently writes `ProviderGenerationID: nil`. |
| Mirror completeness | Missing | `stats/billingmirror/mirror.go` mirrors mutable credits by overlap/sweep and lacks an immutable payload, lineage chain, and completeness watermark. |
| Reward mapping | Partial | Current reward code hardcodes compute unknown and has no payment projection or total cross-client mapping. |
| App/portal presentation | Partial | Swift preserves some independent freshness; portal still collapses states, uses misleading withdrawal language, and lacks complete pagination. |

## User journeys

### Provider becomes observable

1. The provider serves the exact Gate-C-qualified key through an authenticated session with a unique session-instance UUID and model-generation tuple.
2. The shared provider-work scheduler issues a bounded, overt, non-billable lease through the negotiated carrier.
3. Swift executes the exact profile without changing buyer output and returns only bounded governed data.
4. Coordinator validates session, generation, qualification, nonce, replay key, limits, references, calibration, and policy before a durable event.
5. Sanitized status shows state, key digest, evidence time, expiry, freshness, limitation, and recovery action without raw prompts, vectors, thresholds, secrets, or buyer data.

### First job is traceable

1. WS authority mints a route-admission token for the exact live session/model tuple.
2. The money writer stores that token, route, and request observation capture atomically; a post-commit WS claim must succeed before dispatch.
3. Receipt, verdict, finality, and exclusion changes append complete immutable billing snapshots.
4. Mirror verifies event lineage and consumes event payloads without reconstructing old facts.
5. A qualification-only shadow sink consumes an eligible request once. It cannot mutate the production reward ledger or enable emission/payment.
6. App and portal show matching request stage and independent earning, balance, withdrawal, payment, and freshness states.

### Evidence degrades

Reference, calibration, policy, artifact, runtime, profile, hardware class, session, or operator revocation advances the durable revision. New requests cannot capture the prior positive state. Historical captures remain immutable; prospective holds require separate governed ledger events. UI reports the closed reason and recovery action.

## Ownership and trust boundaries

| Owner | Authority | Boundary |
| --- | --- | --- |
| SPEC-036 observation package | Profile, protocol, evidence, qualification, evaluation lifecycle, sanitized status | Narrow drift observation only; no settlement or economic authority. |
| WS session/model actor | Unique session identity, live generation tuple, route-token mint/claim/revoke, actual encrypted dispatch | Cannot create observation, pricing, receipt, or reward authority. |
| Shared provider-work scheduler | Buyer-first ordering, probe leases, quiescence, limits and carrier selection | Cannot create evidence or economic state. |
| Swift runtime | Execute one exact profile and report bounded measurement/inconclusive result | Cannot choose identity, references, thresholds, state, price, or rewards. |
| Money SQLite | Observation order, request captures, receipts/verdicts/credits, immutable projection journal | One writer protocol owns durable ordering. Provider assertions are inputs only. |
| External prepare journal | Non-restored proof that a next money mutation was intended before SQLite commit | Contains no secret and grants no reward state; ambiguity fails unavailable. |
| Postgres mirror | Verify/apply immutable payloads and source completeness | Cannot reconstruct history from mutable SQLite rows. |
| SPEC-021 rewards | Production ledger state plus isolated qualification-only shadow projection | Build 3 cannot activate emission, withdrawal, or payment. |
| App/portal | Present server projections and recovery actions | Cannot recompute policy or merge freshness domains. |

## Dependency graph and gates

```text
hook feasibility
  -> exact profile + precommitted calibration protocol
  -> Gate A0 (zero C/H/M; no evidence existed before approval)
  -> references + golden validation + calibration result
  -> evidence bundle + migration/feasibility inventory
  -> Gate B (zero C/H/M)
  -> SPEC/schema and Slices 1–7
  -> built and signed release-candidate manifest
  -> prequalification physical evidence bound to candidate
  -> final release-qualification manifest
  -> Gate C (zero C/H/M)
  -> positive local qualification state only
  -> separately authorized production qualification/rollout
```

A failed hook, missing independent source, failed precommitted threshold, missing representative hardware, infeasible hot path, incomplete mutation inventory, or failed gate blocks downstream work. Evidence is never recollected under altered rules without a new protocol digest and Gate A0.

## Normative contracts required before implementation

### Precommitted calibration protocol

`compute_calibration_protocol.v1` is committed and independently approved before reference/cohort data is opened. It freezes:

- one exact hardware predicate expressed over allowlisted `hw.model`, chip family/name, physical memory, GPU core count, OS build range, Metal feature-set/runtime and MLX revisions; equality is fieldwise and one out-of-range field is uncovered;
- exactly 3 known-good physical cohort hosts, each manually adjudicated before measurement, with at least 2 operator authorities and 2 power/network failure domains; neither counted reference host may also be the provider-under-test;
- 8 fixed prompts, 32 fixed token positions per prompt, top-K `K=32`, 3 cold process launches and 10 warm repetitions per host: 24 cold and 80 warm prompt executions per host, 768 cold and 2,560 warm measured positions per host;
- deterministic seed `0`, exact processor order, float32 little-endian probability encoding after device synchronization, and JCS metadata;
- tail feasibility: at least 99.0% of preselected positions across every host/repetition must expose all 32 governed entries without non-finite values, and no host may fall below 98.0%; otherwise the profile fails;
- threshold selection: compute the predeclared divergence statistic for every cohort/reference pair and set the observation threshold to the smaller of the fixed safety ceiling recorded in the protocol and the one-sided 99% tolerance bound using the protocol-specified bootstrap code/seed; neither formula nor safety ceiling may change after data is visible;
- false-quarantine budget: one-sided 95% Clopper-Pearson upper bound must be at most 1.0% across at least 600 predeclared known-good decisions, with zero stopping before the full matrix; a failure blocks the qualification rather than widening the threshold;
- exclusions limited to a pre-enumerated signed list of machine outages or corrupted acquisitions; exclusions, retries, and missing samples count in the failure report; no discretionary outlier removal;
- result expiry of 30 days, reference refresh every 24 hours, observation window at most 2 hours, and protocol expiry at 90 days;
- signed protocol publication time, repository commit, digest, reviewers, collection start time, raw-evidence custody digest, fixed analysis code digest, and failure outcome.

SPEC-036 warn/enforce floors of 30 warn-only days, 100 eligible canaries, and 10 stable identities do **not** apply to this observation-only calibration. The narrower result may support sanitized observation and isolated qualification shadow tests only. It cannot be reused as warn/enforce evidence, verified settlement, production reward eligibility, or economic activation. Those stronger uses retain every SPEC-036 prerequisite.

### Independent reference admission

The two counted reference sources must differ simultaneously in all three existing SPEC-036 dimensions: approved operator authority; physical host plus power/network failure domain; and independently produced runtime-build/kernel provenance within the precommitted numeric-equivalence class. Neither provider assertion, key count, cloud account count, nor host label proves independence. Admission records bind signed source identity, attested physical/fault-domain evidence, build/kernel provenance, exact profile/protocol/artifact/catalog/tokenizer equality, production/expiry/revocation times, predecessor event digest, and custody digest.

Each source independently passes the same signed golden-distribution fixture at admission and refresh. Golden validation is an additional integrity check and never replaces an independence dimension or calibration. Invalid signature, stale/revoked event, changed antecedent, correlation on any dimension, failed golden check, or source disagreement removes that source from quorum without advancing provider drift counters. Raw vectors remain controlled evidence and never enter public status.

### Observation authority and live request-start linearization

The observation tables live in the money SQLite database. Append-only events, current materialization, immutable request captures, revocation tombstones, and audit metadata bind the qualification and evidence digests.

Every routable WS session receives a random 128-bit `session_instance_id` that is never reused. The live tuple is `(stable_provider_id, assigned_session_id, session_instance_id, target_generation, release_generation, admission_binding_epoch, canonical_model_key, artifact_digest, catalog_digest, rate_card_digest)`. For covered requests `ProviderGenerationID` and every tuple field are mandatory and non-null; legacy nil is an explicit uncovered/ineligible reason.

The cross-owner protocol is:

1. Under the canonical WS lock order `provider-pool -> session actor -> model admission`, mint a single-use signed/MACed coordinator route token containing the tuple, request ID/attempt, observation predecessor revision/digest, issued/expiry monotonic deadlines, and random token ID. Register it as `minted`; release all WS locks.
2. Acquire external-lineage `flock`, durably PREPARE the exact billing event, then `BEGIN IMMEDIATE`. Re-read the observation under one captured UTC time, validate the token contents/expiry, and atomically insert route snapshot, immutable token bytes/digest, observation capture, and billing event. Commit under the external protocol.
3. Reacquire the same WS locks and compare every tuple field. Atomically change `minted -> dispatch_claimed` only if the session actor is live, the model binding remains current, and the token is unused. A mismatch changes the request to `dispatch_blocked_orphan` through a subsequent journaled money transaction; the immutable capture remains historical but is never receipt-, settlement-, or reward-eligible.
4. The session actor performs the encrypted network send only for an exact `dispatch_claimed` token. Disconnect, reconnect, generation reuse, model swap, release/catalog/rate rotation, or BYOM binding movement revokes minted tokens. A claimed token that cannot send becomes a journaled failed attempt and cannot yield a paid receipt.

No WS lock is held while acquiring `flock` or SQLite. Lifecycle transitions need not wait for SQLite; the post-commit claim is the linearization fence. Session UUID prevents generation-number reuse. Late results bind token ID and tuple and are rejected after revocation. Every observation and billing mutation uses predecessor CAS; restart validation never extends freshness.

### Immutable billing projection journal and restore protocol

`billing_projection_event.v1` is a canonical complete snapshot appended in the same SQLite transaction as every reward-projectable route, capture, receipt, verification, finality, exclusion, quarantine, credit, reversal, and void mutation. The closed payload includes identities, route/model/artifact/catalog/rate, token tuple/digest, receipt/verdict/finality, exclusions, token/credit values, exact observation capture, schema, request revision, and authoritative times. Absent fields are explicit. Mirror consumes payload bytes only; changed replay, chain gap/fork, lower request revision, or changed incarnation fails completeness.

The external authority is an append-only, hash-chained `billing_lineage_prepare.v1` journal outside SQLite and backup bundles, mode `0600`, protected by a separate `flock` file. Records are length-delimited canonical bytes with version, incarnation, sequence, previous committed digest, proposed event digest, payload digest, request revision, state (`prepare|commit|abort`), and record digest. File creation/rotation and every append are file-fsynced; directory entries are fsynced before the SQLite transaction may begin.

For each mutation while holding `flock`:

1. Construct the exact next SQLite event bytes and digest from the current committed head.
2. Append PREPARE and fsync the journal and parent directory.
3. Begin SQLite, assert the same predecessor, apply source mutation and exact prepared event, commit, and fsync SQLite/WAL according to the supported durability mode.
4. Append COMMIT for the prepared digest and fsync before releasing `flock`, dispatching a request, or publishing availability.
5. The target mirror applies only through committed external heads and records incarnation/sequence/digest.

If SQLite fails before commit in the same live process and the writer proves the DB head remains the predecessor, it may append ABORT. After a crash, PREPARE without COMMIT is never auto-aborted: matching SQLite event permits COMMIT recovery; absent/mismatched SQLite event is ambiguous and keeps source/mirror/status unavailable pending an audited operator reconciliation or new incarnation. COMMIT ahead of a restored DB, DB event without PREPARE, divergent prepared bytes, missing record, sequence reuse, or unknown incarnation fails closed. Thus SQLite-commit/crash/restore-to-predecessor remains detectable through the surviving PREPARE.

Bootstrap enters bounded maintenance, freezes money writes, creates a prepared genesis, backfills complete snapshots under one locked database snapshot, verifies count/ordered identity/schema/chain digests, commits SQLite, commits the external record, then releases writes. Postgres reaches ready only at an observed committed source head. Intentional restore/new incarnation is offline, explicit, and audited. No cursor or last-known freshness crosses an uncertain lineage.

### Hot-path, storage, and lock feasibility gate

Before Gate B, a production-shaped prototype must benchmark the exact `flock -> PREPARE fsync -> SQLite transaction/WAL fsync -> COMMIT fsync` protocol on the supported APFS storage profile, at concurrency 1/8/32 and database sizes 10k/1M/10M events. It must pass all gates:

- canonical event hard limit 64 KiB, p99 event at most 16 KiB, retained growth at measured peak at most 2 GiB/day;
- sustained at least 100 complete mutations/second for 10 minutes without errors; p50/p95/p99 added route-start latency at most 5/15/30 ms and p99 no more than 15% over matched baseline;
- p99 lineage-lock wait at most 20 ms; 50 ms hard acquisition deadline; bounded queue at 1,024 entries with typed `billing_authority_busy` before dispatch/debit and no silent drop;
- bootstrap of 1M complete request projections at most 15 minutes, startup verification at 10M events at most 60 seconds, peak coordinator RSS increase at most 512 MiB;
- disk reserve always at least `max(10 GiB, 7 days measured growth)`; PREPARE/fsync/disk-full failure occurs before SQLite mutation; a post-SQLite COMMIT-fsync failure freezes dispatch and projection availability until exact recovery;
- no compaction or deletion is authorized in Build 3. All events and external records are retained. Gate B must show one-year capacity below 20% of the provisioned volume; otherwise an independently reviewed archival/chain-bridging design is required before implementation or production qualification.

Representative mutation rates/payload distributions come from sanitized counters over at least 7 days or, if production counters are unavailable, a declared conservative synthetic mix at 4x the documented peak. A failed gate reopens architecture review; budgets may not be relaxed after results.

### Tier-2 carrier and shared scheduler

SPEC-036 carrier isolation remains unchanged: Tier-2 uses encrypted `inference_request`; plain frames on Tier-2 and encrypted frames without an exact session are rejected. Replay identity is domain-separated by protocol, direction, provider, session, probe ID, and qualification digest. Capability negotiation is exact; unsupported NAK suppresses retries without disconnecting buyer service.

Probe lease states are `queued -> dispatching -> running_load -> running_prefill -> running_sampler -> serializing -> cancelling -> quiescing -> quiesced -> terminal`. Buyer inference has absolute admission priority. Queued probes cancel immediately. If buyer work arrives during running work, no buyer Metal command buffer starts until the probe reaches `quiesced`: cooperative cancellation is checked between stages, all issued MLX work is synchronized, result buffers are fenced/released, and the lease generation is invalidated. The quiescence budget is 2 seconds from buyer arrival. If an in-flight kernel cannot quiesce, the provider enters typed `draining_probe_quiescence_timeout`, is removed from new buyer routing, and returns only after device synchronization proves quiescence; buyer work is rerouted or fails with its existing typed availability error.

Late GPU completion or serialization observes the invalid lease generation and cannot publish a result, observation, idle event, receipt, or reward input. Per provider there is one aggregate active probe, one queued item per profile, and bounded total queue. Global concurrency is bounded. Compute goes before losslessness when simultaneously due; age promotion preserves the declared losslessness wait only when buyer work permits.

### Total reward status schema and mapping

SPEC-021 and SPEC-014 add machine-readable `provider_reward_status_inputs.v2`, `provider_reward_status.v2`, and generated canonical vector fixtures. Input fields are closed enums or bounded integers:

- common: `provider_auth=trusted|untrusted|unknown`, `trust_tier=eligible|ineligible|demoted|unknown`, `app_attestation=valid|missing|invalid|unknown`, `hardware_evidence=valid|missing|invalid|unknown`, `runtime_telemetry=healthy|battery_pressure|thermal_pressure|missing|unknown`;
- request: `row=present|absent|unreadable`, billing freshness/completeness, receipt `verified|pending|invalid|missing|unknown|not_applicable`, finality `final|pending|reversed|unknown|not_applicable`, identity `match|mismatch|unknown|not_applicable`, exclusion flags/reasons, quarantine, governed hold, SPEC-022 mode, SPEC-036 capture state, and recent-window membership;
- earning: request projection plus current observation `verified|unknown|stale|revoked|uncovered`, supported-model availability, provider/wallet cap, provisional/demotion hold;
- withdrawal: ledger freshness/readability, eligible balance, wallet `match|missing|mismatch|unknown`, disposition `active|excluded|burned|retired|unknown`, cap and releasable hold;
- payment: Build 3 capability fixed `unavailable`.

The schema closes conditional validity: `row=absent` requires every request-detail field to be `not_applicable`/false and a fresh complete mirror; `row=present` prohibits `not_applicable`; `row=unreadable` carries no trusted detail. A positive eligible balance requires an active disposition; burned/retired dispositions cannot carry an active hold; a cleared cap/hold is absent from current inputs. Any tuple violating an invariant is `projection_contract_unknown`, not a policy input. Common fields affect earning and withdrawal only; immutable request projection never rereads current provider trust, and payment ignores all other projections.

Each projection evaluates these rows top to bottom. The first true predicate supplies state, primary reason, and action. All later true predicates become secondary reasons in row order. Multiple reasons on one row use the listed left-to-right enum order.

| Projection | Priority | Predicate/reason | State | Action |
| --- | ---: | --- | --- | --- |
| Request | 1 | invalid schema/enum/unhandled valid tuple → `projection_contract_unknown` | `unavailable` | `contact_support` |
| Request | 2 | row unreadable → `request_source_unreadable` | `unavailable` | `retry` |
| Request | 3 | billing stale/unavailable/incomplete → `billing_updates_unavailable` | `unavailable` | `retry` |
| Request | 4 | fresh complete source and row absent/outside window → `no_recent_request` | `none` | `none` |
| Request | 5 | receipt missing/pending → `receipt_pending` | `pending` | `retry` |
| Request | 6 | finality pending → `finality_pending` | `pending` | `retry` |
| Request | 7 | receipt invalid → `receipt_invalid`; finality reversed → `receipt_reversed`; identity mismatch → `request_identity_mismatch` | `excluded` | `contact_support` |
| Request | 8 | privacy exclusion → `privacy_excluded`; reward exclusion → `reward_excluded`; quarantine → `request_quarantined`; SPEC-022 observe → `spec022_observe_excluded` | `excluded` | `contact_support` |
| Request | 9 | SPEC-036 capture missing/unknown/stale → `request_observation_unavailable` | `unavailable` | `wait_for_probe` |
| Request | 10 | SPEC-036 capture revoked/uncovered/mismatched → `request_observation_ineligible` | `excluded` | `restore_supported_model` |
| Request | 11 | governed hold → `request_governed_hold` | `held` | `wait_for_probe` |
| Request | 12 | verified final identity-bound SPEC-022-enforce facts → `request_verified` | `eligible` | `none` |
| Earning | 1 | invalid schema/enum/unhandled valid tuple → `projection_contract_unknown` | `unavailable` | `contact_support` |
| Earning | 2 | provider auth unknown → `provider_auth_unknown`; trust tier unknown → `trust_tier_unknown` | `unavailable` | `contact_support` |
| Earning | 3 | provider untrusted → `provider_untrusted`; trust ineligible/demoted → `trust_tier_ineligible` | `ineligible` | `contact_support` |
| Earning | 4 | app attestation missing/invalid/unknown → `app_attestation_unavailable`; hardware evidence missing/invalid/unknown → `hardware_evidence_unavailable` | `unavailable` | `reconnect_provider` |
| Earning | 5 | runtime telemetry missing/unknown → `runtime_telemetry_unavailable`; billing stale/incomplete → `billing_updates_unavailable` | `unavailable` | `retry` |
| Earning | 6 | observation unknown → `observation_unknown`; stale → `observation_stale` | `unavailable` | `wait_for_probe` |
| Earning | 7 | observation revoked → `observation_revoked`; uncovered → `observation_uncovered` | `ineligible` | `restore_supported_model` |
| Earning | 8 | supported model unavailable → `supported_model_unavailable` | `ineligible` | `restore_supported_model` |
| Earning | 9 | battery pressure → `battery_pressure`; thermal pressure → `thermal_pressure` | `ineligible` | `wait_for_probe` |
| Earning | 10 | provider cap → `provider_cap_active`; wallet cap → `wallet_cap_active` | `capped` | `wait_for_probe` |
| Earning | 11 | demotion hold → `demotion_hold_active`; provisional hold → `provisional_hold_active` | `held` | `wait_for_probe` |
| Earning | 12 | recent request projection eligible → `eligible_recent_request` | `earning` | `none` |
| Earning | 13 | fresh complete mirror without eligible recent work → `eligible_no_recent_work` | `eligible_idle` | `none` |
| Withdrawal | 1 | invalid schema/enum/unhandled valid tuple → `projection_contract_unknown` | `unavailable` | `contact_support` |
| Withdrawal | 2 | ledger unreadable/unavailable → `reward_ledger_unavailable`; stale → `reward_ledger_stale` | `unavailable` | `retry` |
| Withdrawal | 3 | provider auth unknown → `provider_auth_unknown`; disposition/wallet unknown → `withdrawal_input_unknown` | `unavailable` | `contact_support` |
| Withdrawal | 4 | provider untrusted → `provider_untrusted`; disposition excluded/burned/retired → `disposition_excluded`/`disposition_burned`/`disposition_retired` | `ineligible` | `contact_support` |
| Withdrawal | 5 | wallet missing → `wallet_missing` | `ineligible` | `add_wallet` |
| Withdrawal | 6 | wallet mismatch → `wallet_mismatch` | `ineligible` | `contact_support` |
| Withdrawal | 7 | eligible balance zero → `no_eligible_balance` | `ineligible` | `none` |
| Withdrawal | 8 | provider cap → `provider_cap_active`; wallet cap → `wallet_cap_active` | `capped` | `wait_for_probe` |
| Withdrawal | 9 | active releasable hold → `active_releasable_hold` | `held` | `wait_for_probe` |
| Withdrawal | 10 | positive canonical eligible balance → `balance_withdrawable` | `withdrawable` | `none` |
| Payment | 1 | every valid input → `malibu_payment_execution_unavailable` | `unavailable` | `none` |

Unknowns are predicates above rather than implementation fallthrough. Request inputs come only from the immutable request event, current earning inputs come from current sources, and withdrawal inputs come only from the reward ledger/disposition/wallet sources. Cleared holds/caps are activity only. Current compute never changes a historical withdrawal balance. The generated exhaustive and pairwise vectors are byte-identical inputs for Go, Swift, and portal tests and prove every schema-valid tuple reaches one row.

### SPEC-022 and SPEC-036 mode separation

The immutable request payload uses two different fields: `settlement_verification_mode=spec022_observe|spec022_enforce` and `compute_observation_mode=spec036_observe` (Build 3 has no other SPEC-036 mode). A SPEC-022-observe request is economically excluded under all compute states. A SPEC-022-enforce request with final verified settlement may carry a positive SPEC-036-observe capture, but that capture authorizes only observation display and the isolated qualification shadow predicate.

Shadow accrual requires all of: qualification build target, injected in-memory/local qualification sink, SPEC-022 enforce, verified final receipt with authoritative identity/rate/model binding, fresh complete mirror, exact positive request-start SPEC-036 capture, no exclusion/quarantine/hold/reversal, and idempotency key. The sink writes neither the production reward ledger nor emission/payment tables and is absent from production dependency injection and release artifacts. There is no runtime production feature flag that can enable it. All mode combinations are tested; SPEC-036 availability alone never authorizes settlement or reward.

## Data changes, compatibility, rollback, and observability

All migrations are additive. V1 clients receive conservative legacy fields for 90 days after the first separately authorized v2 rollout or through the next provider-app stable release, whichever is later; omission cannot authorize optimistic copy. New clients fail only the affected projection closed. Observation/journal/scheduler consumers default disabled. Rollback disables probes, consumers, v2 UI, and the qualification sink while preserving immutable evidence and additive schema; it never deletes history, rewrites captures, resumes an uncertain cursor, or restores misleading language.

Metrics cover probe lease/quiescence, queue/cancel/NAK, evaluation by qualification/reason, CAS/revocation, route-token mint/claim/orphan, SQLite/lock/PREPARE/COMMIT latency, ambiguous prepare, journal and mirror heads, bootstrap, reward reasons, freshness, pagination, and redaction. Labels exclude raw prompts, vectors, tokens, secrets, buyer identity, and unbounded provider strings. Lineage ambiguity, chain failure, stale observations, reference disagreement, and unknown contracts fail closed and alert.

## Phased implementation after Gate B

1. Governance/schema updates and closed fixtures.
2. External prepare journal, SQLite observation authority, live route-token protocol, and crash recovery.
3. Shared scheduler, carrier negotiation, Swift profile hook, cancellation and quiescence.
4. Reference/calibration evaluation and sanitized status.
5. Immutable billing projection journal, bootstrap, mirror and completeness watermark.
6. Total reward mapping, qualification-only shadow sink, paginated activity.
7. App/portal parity, last-known data, truthful payment copy and accessibility.
8. Built release qualification, Gate C, targeted/broad/physical verification, and three independent complete-diff audit lanes.

Material architecture, contract, scope, or test changes reopen the applicable gate.

## Acceptance and hardware qualification

`test-spec-v3` maps every claim. Local implementation, local tests, actual MLX, physical end-to-end, signed release qualification, and production qualification are distinct. Positive qualification needs exact manifests, two independent reference environments meeting all three SPEC-036 axes, the predeclared cohort, physical Apple Silicon, actual MLX, Xcode app, real browser, and service topology evidence. A fixture, skipped test, spike, one host, provider assertion, status adapter, or mirror freshness cannot substitute.

## Explicit non-goals

- SPEC-036 warn/enforce activation or settlement-policy changes.
- MALIBU emission activation, withdrawal/payment execution, epochs, payout work, or economic policy changes.
- Production deployment, pool authorization, trusted-pool activation, release publication, hardware procurement, or operator-secret changes.
- Provider-wide integrity, confidential compute, anonymity, physical-computation proof, or malicious-provider honesty claims.
- Inspection of `d-inference` source or a new dependency without approval.
- A second model/runtime/profile/hardware class.

## Roadmap outcome mapping

| Roadmap outcome | Implementation step | Verification |
| --- | --- | --- |
| One covered model/runtime/profile | Acyclic profile/evidence/release gates | B3-F/G/C/REF/CAL |
| Actual probes and justified references | Scheduler/runtime/evaluation | Actual-MLX, independence and precommitted calibration tests |
| Generation validity, expiry, revocation | Route-token and observation authority | Session/generation/commit-order race matrix |
| Sanitized status | Evaluation/status | Schema/redaction/auth tests |
| Governed reward mapping | Immutable journal plus total mapping | Exhaustive cross-client vectors and mode matrix |
| Portal/app parity | Presentation slice | Xcode/browser state matrix |
| Request → receipt → reward visibility | All upstream slices | Correlated physical qualification-only trace |
| No overclaim/activation | Every slice | Default-off, missing-production-sink, negative economics, and copy tests |
