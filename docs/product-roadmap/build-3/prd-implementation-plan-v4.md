# Product Build 3 — PRD and Implementation Plan

Plan revision: `build3-plan-v4`
Plan status: awaiting independent adversarial approval
Repository/base: `Augustas11/macprovider@1d2c930bad81704dd0acc0322226725d8b64aceb`
Scope: production compute observations and first-job visibility for one covered key; no enforcement, economic activation, payment execution, or deployment

## Decision and gate boundary

If approved, this revision authorizes only the structural hook feasibility work, antecedent manifests, and bounded pre-implementation evidence packages described below. It does **not** authorize the durable runtime source, reward projection, app, or portal implementation. Gate A0 approves the exact immutable profile, complete numeric calibration protocol, independent decision unit, held-out partition, and positive-control power rule before any real post-sampler probability value is acquired, persisted, displayed, logged, summarized, or made available to a protocol author or reviewer. Slices 1–7 remain blocked until Gate B approves the resulting evidence and feasibility bundle. Positive availability remains blocked until a built release and its qualification manifest pass Gate C. Every gate requires an independent GPT-5.6 Sol review with zero Critical, High, and Medium findings on exact committed digests.

The candidate locator for structural hook feasibility is:

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

1. Pre-Gate-A0 `compute_hook_structural_feasibility.v1` may prove only exact API/stage reachability, tensor shape/dtype, synchronization entry points, cancellation entry points, resource upper bounds from allocation metadata, and output-token parity. A sealed hook discards and zeroizes governed values inside the process and emits no value, vector, extrema, aggregate, hash of values, repeat count, or timing correlated with a governed value. It may use synthetic tensors for serialization tests. Repeated real-model numeric acquisitions are prohibited.
2. `compute_observation_profile.v1` freezes the candidate values above, closed quantization descriptor, tokenizer/chat-template/prompt corpus, context and seed semantics, sampler processor order, positions, probability encoding and normalization, limits, protocol/schema versions, and one exact predeclared hardware/runtime class predicate. Its `profile_digest` is computed last.
3. `compute_calibration_protocol.v1` binds `profile_digest` and freezes every cohort, reference, decision-unit, cluster, held-out, positive-control, statistic, threshold-selection, stopping, exclusion, expiry, custody, and failure rule. Gate A0 reviews these antecedents and the nonnumeric structural result. A Gate-A0 acquisition ledger starts at approval; every governed acquisition must have a later monotonically allocated custody sequence.
4. Signed `compute_reference_event.v1`, `compute_golden_validation.v1`, and `compute_calibration_result.v1` records bind both antecedent digests. They never bind the later bundle or release.
5. `compute_preimplementation_contract.v1` binds closed candidate schemas for `billing_projection_event.v1`, `billing_lineage_prepare.v1`, route-token lifecycle events, `provider_reward_status_inputs.v2`, `provider_reward_status.v2`, the exhaustive money-mutation inventory, deterministic workload mix, exact local/witness durability protocol, and one supported storage/topology profile. Gate B0 independently approves this package before any hot-path or recovery benchmark.
6. `compute_observation_evidence_bundle.v1` binds the antecedent digests, reference/golden/calibration results, threshold, policy, revocation list, preimplementation-contract digest, and Gate-B0-bound capacity/recovery results. Gate B reviews the bundle and the revised implementation plan. The bundle contains no production release digest.
7. After implementation and signing, `compute_observation_release_candidate.v1` binds the evidence-bundle digest, implementation commit, production package digest, executable digest, code-signing identity, and schema fixture digests. Candidate-bound runs remain nonpositive `prequalification_evidence`.
8. `compute_observation_release_qualification.v1` binds the release-candidate digest and fresh hook/probe/physical/Xcode/browser qualification records. Gate C reviews it. Only this final `qualification_digest` can name a positive local qualification key; production rollout is still separate.

Any pre-Gate-A0 acquisition or disclosure of a governed numeric value invalidates the antecedent custody claim. The profile/protocol must receive a new digest and Gate A0 must be rerun without authors who saw the values, or collection moves to an independently controlled blind-custody team whose members cannot author or approve the protocol. No disclaimer can cure leaked data.

## Product result

For the one Gate-C-approved qualification, a provider can see a sanitized, narrowly scoped observation state and trace a real request through immutable request-start capture, receipt persistence, billing projection, and app/portal presentation. An isolated qualification-only shadow decision is operator/test evidence and is structurally absent from provider APIs, balances, reward activity, and clients. Provider-visible `earning` requires a production-ledger accrual plus a separately authorized production reward capability. Because Build 3 cannot enable that capability, its earning projection remains explicitly unavailable while historical ledger balance and withdrawal eligibility remain independently truthful.

Missing, stale, revoked, mismatched, unreadable, incomplete, or uncovered evidence produces a conservative state. It never becomes confirmed idleness, current earning, broad provider integrity, or physical-computation proof by inference.

## Code-grounded starting point

| Outcome | Status at base | Evidence and implication |
| --- | --- | --- |
| Production observation owner | Missing | `internal/ws/compute_integrity_status.go` defines an injected read seam; `cmd/coordinator/main.go` does not inject it. `computeintegrity.Store` is in-memory. |
| Probe primitives | Partial | `internal/computeintegrity/probe.go` validates DTOs. There is no SPEC-036 scheduler/result ingestion or Swift probability extraction. Existing `LosslessnessProbeRuntime.providerInconclusiveForUnavailableSampler` returns unsupported. |
| Exact MLX hook | Blocked pending feasibility | `Tests/mlx-stage-spikeTests` proves staged Llama forward/argmax only. It may skip without a model and does not expose the post-sampler distribution. Pre-Gate-A0 work may prove only the nonnumeric structural contract above. |
| MLX work ownership | Partial | Buyer generation and warmup run through `ModelRuntime`; `IdlePrewarmer` starts independent `runInternalWarmup` work after observing `requestsInFlight`; `ProviderPreWarmer` and control-socket model adoption/load/swap also touch the runtime. Standalone decode/SPEC-028/autotune commands have separate process/lifecycle paths. A probe-only semaphore would not prove device quiescence. |
| Request-start compute capture | Partial | `billing/settlement_compute_integrity.go` stores immutable enforce-mode captures, but insertion is not linearized with live WS session/model authority and is not projected to rewards. `internal/buyer/route_snapshot.go` currently writes `ProviderGenerationID: nil`. |
| Mirror completeness | Missing | `stats/billingmirror/mirror.go` mirrors mutable credits by overlap/sweep and lacks an immutable payload, lineage chain, and completeness watermark. |
| Reward mapping | Partial | Current reward code hardcodes compute unknown. The canonical SPEC-021 query applies simultaneous hold, exclude, burn and retire facts across ledger-row, useful-work source, provider, wallet, cohort, duplicate-class, and epoch scopes; collapsing those facts to one disposition is unsafe. |
| App/portal presentation | Partial | Swift preserves some independent freshness; portal still collapses states, uses misleading withdrawal language, and lacks complete pagination. |

## User journeys

### Provider becomes observable

1. The provider serves the exact Gate-C-qualified key through an authenticated session with a unique session-instance UUID and model-generation tuple.
2. The shared MLX resource arbiter issues a bounded, overt, non-billable lease through the negotiated carrier only after all other MLX owners are quiescent.
3. Swift executes the exact profile without changing buyer output and returns only bounded governed data to the coordinator evidence ingress.
4. Coordinator validates session, generation, qualification, nonce, replay key, limits, references, calibration, and policy before a durable event.
5. Sanitized status shows state, key digest, evidence time, expiry, freshness, limitation, and recovery action without raw prompts, vectors, thresholds, secrets, or buyer data.

### First job is traceable

1. WS authority mints a single-boot route token for the exact live session/model tuple.
2. The money writer stores the token, route, and request observation capture atomically. A WS reservation and a durable dispatch-attempt event must both succeed before network send.
3. Receipt, verdict, finality, and exclusion changes append complete immutable billing snapshots.
4. Mirror verifies event lineage and consumes event payloads without reconstructing old facts.
5. An operator-only qualification sink may record the request’s shadow decision. The sink cannot enter provider status, balances, reward activity, emission, withdrawal, or payment.
6. App and portal show matching request stage, observation state, existing production-ledger balance/withdrawal facts, `earning unavailable` while reward capability is disabled, payment unavailability, and independent freshness.

### Evidence degrades

Reference, calibration, policy, artifact, runtime, profile, hardware class, session, or operator revocation advances the durable revision. New requests cannot capture the prior positive state. Historical captures remain immutable; prospective holds require separate governed ledger events. UI reports the closed reason and recovery action.

## Ownership and trust boundaries

| Owner | Authority | Boundary |
| --- | --- | --- |
| SPEC-036 observation package | Profile, protocol, evidence, qualification, evaluation lifecycle, sanitized status | Narrow drift observation only; no settlement or economic authority. |
| Independent calibration custodian | Hold blinded host assignments and governed numeric acquisitions after Gate A0 | Cannot author protocol, select thresholds, approve references, operate provider under test, or publish product state. |
| WS session/model actor | Unique session identity, live generation tuple, route-token mint/reserve/revoke, actual encrypted dispatch | Cannot create observation, pricing, receipt, or reward authority. |
| Shared MLX resource arbiter | Buyer-first admission, probe/warmup/model-transition leases, cancellation, quiescence, limits and carrier selection | Cannot create evidence or economic state. |
| Swift runtime | Execute one exact profile and report bounded measurement/inconclusive result | Cannot choose identity, references, thresholds, state, price, or rewards. |
| Money SQLite | Observation order, request captures, dispatch-attempt states, receipts/verdicts/credits, immutable projection journal | One writer protocol owns durable ordering. Provider assertions are inputs only. |
| Local lineage journal plus independent witness | Prove prepared/committed/superseded mutation lineage across host/volume loss | Neither copy alone grants reward state; disagreement fails unavailable. |
| Postgres mirror | Verify/apply immutable payloads and source completeness | Cannot reconstruct history from mutable SQLite rows. |
| SPEC-021 rewards | Produce canonical effective withdrawal/accrual projection from every scoped ledger fact | Build 3 cannot activate emission, withdrawal execution, payment, or reward capability. |
| Qualification shadow sink | Operator/test-only non-economic decision evidence | No provider API/client dependency, balance, reward activity, or production feature flag. |
| App/portal | Present server projections and recovery actions | Cannot recompute policy, consume shadow records, or merge freshness domains. |

## Dependency graph and gates

```text
nonnumeric structural hook feasibility
  -> exact profile + complete numeric calibration protocol
  -> Gate A0 (zero C/H/M; no governed numeric acquisition/disclosure before approval)
  -> blinded reference/development/held-out acquisitions + calibration result
  -> closed preimplementation schemas + mutation inventory + durability/storage/workload profile
  -> Gate B0 (zero C/H/M on exact pre-benchmark contract digests)
  -> exact capacity, crash, restore and witness benchmarks
  -> evidence bundle
  -> Gate B (zero C/H/M)
  -> SPEC/schema and Slices 1–7
  -> built and signed release-candidate manifest
  -> candidate-bound prequalification evidence
  -> final release-qualification manifest
  -> Gate C (zero C/H/M)
  -> positive local qualification state only
  -> separately authorized production qualification/rollout
```

A numeric leak, failed hook, missing independent unit, failed precommitted held-out or power rule, missing independent reference, unsupported witness/storage profile, infeasible hot path, incomplete mutation inventory, or failed gate blocks downstream work. Evidence is never recollected under altered rules without a new protocol digest and Gate A0.

## Normative contracts required before implementation

### Precommitted calibration protocol

`compute_calibration_protocol.v1` is committed and independently approved before any real governed numeric value is acquired. It freezes:

- one exact hardware predicate over allowlisted `hw.model`, chip family/name, physical memory, GPU core count, OS build range, Metal feature-set/runtime and MLX revisions; equality is fieldwise and one out-of-range field is uncovered;
- 80 physical calibration units, where one decision unit is one independently adjudicated host plus its operator authority, power/network failure domain, and runtime-build/kernel provenance campaign. Positions, prompts, warm repetitions and process launches are correlated measurements inside that unit and never increase the decision count;
- an immutable partition selected before acquisition: 20 threshold-development units and 60 sealed held-out units. Every unit, both counted reference sources, and the provider under test use distinct physical hosts and distinct power/network failure domains. Each partition spans at least four operator authorities and four independently produced runtime-build/kernel provenance groups. No held-out result is opened until the threshold and its digest are frozen from development/reference data;
- for each unit, 8 fixed prompts, 32 fixed positions, `K=32`, 3 cold process launches and 10 warm repetitions, deterministic seed `0`, exact processor order, float32 little-endian probability encoding after device synchronization, and JCS metadata;
- the host-level statistic: a protocol-fixed aggregate of the base-2 Jensen-Shannon divergence over the top-32 probabilities plus a remainder bucket against both admitted references. The exact aggregation, bootstrap strata, safety ceiling and threshold formula are immutable before collection;
- a host-level known-good decision formed only after the complete matrix. The 60 held-out good units must have zero false quarantines; the one-sided 95% exact binomial upper bound is reported and must be at most 5.0%. No position or repetition is a Bernoulli trial;
- a paired, blinded positive-control campaign on all 60 held-out units. The protocol fixes a minimum meaningful divergence of at least `0.010` base-2 Jensen-Shannon at at least 10% of governed positions and a signed transform/runtime-control digest before collection. At least 59 of 60 host-level controls must be detected and the one-sided 95% exact-binomial lower bound must be at least 90%. Controls cover both an end-to-end controlled runtime perturbation and a separately signed hook-boundary transform; structural mismatches are reported separately and do not count toward numeric power;
- blind custody: custodian-assigned good/control labels and raw vectors are withheld from threshold authors/reviewers until the threshold digest is committed. The analysis executable accepts sealed inputs and produces a signed per-unit verdict. Custodians cannot author/approve the protocol, references, threshold, or product state;
- tail feasibility at the unit level, fixed exclusions, retries/missing-data treatment, zero early stopping, 30-day result expiry, 24-hour reference refresh, two-hour observation window, 90-day protocol expiry, and a failure outcome that blocks rather than changes any parameter.

The counts above are qualification prerequisites, not an assertion that this session has the hardware or operators. Until all 80 independent units, two disjoint references, custody roles, and held-out/power gates exist, calibration and positive observation remain blocked. The result supports observation-only qualification. It cannot support SPEC-036 warn/enforce, verified settlement, production reward eligibility, or economic activation.

### Independent reference admission

The two counted reference sources differ simultaneously in approved operator authority, physical host plus power/network failure domain, and independently produced runtime-build/kernel provenance. They are disjoint from all calibration units and the provider under test. Admission records bind signed identity, attested physical/fault-domain evidence, build/kernel provenance, exact profile/protocol/artifact/catalog/tokenizer equality, production/expiry/revocation times, predecessor digest, and custody digest.

Each source independently passes the same signed golden-distribution fixture at admission and refresh. Golden validation never replaces an independence dimension, held-out discrimination, or calibration. Invalid signature, stale/revoked event, changed antecedent, correlation, failed golden check, or source disagreement removes that source from quorum without advancing provider drift counters. Raw vectors remain controlled evidence and never enter public status.

### Observation authority and restart-safe request-start linearization

Observation tables live in the money SQLite database. Append-only events, current materialization, immutable request captures, revocation tombstones, route-token lifecycle events, and audit metadata bind qualification and evidence digests.

Every coordinator process creates a random 128-bit `coordinator_boot_epoch`, loads one route-MAC `key_epoch`, and starts an in-memory monotonically increasing 64-bit `mint_sequence`. Every routable WS session receives a random 128-bit nonreused `session_instance_id`. The live tuple is `(stable_provider_id, assigned_session_id, session_instance_id, target_generation, release_generation, admission_binding_epoch, canonical_model_key, artifact_digest, catalog_digest, rate_card_digest)`. A token serializes this tuple, boot/key epochs, mint sequence, request ID/attempt, observation predecessor revision/digest, bounded signed UTC issue/expiry times, and random token ID. Its live deadline is derived from the process monotonic clock at mint and is never reconstructed from serialized wall time. Tokens are valid only in the same boot/key epoch; wall-clock movement cannot extend the monotonic deadline. Nil generation or tuple fields are uncovered/ineligible.

The cross-owner protocol is:

1. Under lock order `provider-pool -> session actor -> model admission`, mint and register `minted` with the live monotonic deadline; release WS locks.
2. Under lineage `flock` and the local+witness PREPARE protocol, `BEGIN IMMEDIATE`, validate the same boot/key epoch, signed UTC bounds, and current monotonic deadline, then atomically insert route snapshot, token bytes/digest, observation capture, and durable `capture_committed` event. Release money locks.
3. Reacquire WS locks, compare the full tuple, and CAS `minted -> claim_reserved` with a fresh claim nonce. This reserves authority but cannot send.
4. Release WS locks and append durable `dispatch_attempt_authorized` under the money lineage, binding token, claim nonce, boot/key epochs, and full tuple. Failure journals `dispatch_blocked_orphan` and cannot send.
5. Reacquire WS locks, verify the same live `claim_reserved`, tuple, deadline, boot/key epochs and durable attempt digest, then CAS to `send_lease`. The session actor sends only under that lease. A send failure or lifecycle mismatch appends a terminal failed/orphan event. A result is accepted only for that token/attempt/tuple and an already durable attempt event.

Startup completes lineage recovery before routing. Every `capture_committed` token without `dispatch_attempt_authorized` becomes terminal `restart_orphan_nonrewardable`. Every authorized attempt without a persisted accepted result becomes `dispatch_outcome_unknown_nonrewardable`, releases/refunds the buyer reservation through the existing authoritative money path, and rejects old-epoch late results. Exact accepted receipts already committed remain immutable. MAC-key rotation creates a new key epoch and performs the same orphan reconciliation. No WS lock is held while acquiring lineage or SQLite locks. No durable state is inferred from an in-memory claim after restart.

### Immutable billing projection journal and safe restoration

`billing_projection_event.v1` is a canonical complete snapshot appended in the same SQLite transaction as every inventoried route, capture, dispatch attempt, receipt, verification, finality, exclusion, quarantine, credit, reversal, refund, and void mutation. Mirror consumes payload bytes only; changed replay, chain gap/fork, lower request revision, or changed incarnation fails completeness.

Lineage uses two fault-domain-separated authorities: a local append-only `billing_lineage_prepare.v1` journal outside SQLite/backup bundles and an independently durable witness implementing conditional append by `(incarnation, sequence, predecessor_digest, record_digest)`. Both contain canonical PREPARE/COMMIT/ABORT/SUPERSEDE records and neither contains secrets. A mutation may enter SQLite only after identical PREPARE bytes are fsynced locally and acknowledged durable by the witness. It is not acknowledged, dispatched, mirrored, or published until identical COMMIT is durable in both. Build 3 production qualification is blocked unless the witness is deployed on an independently failed host/volume with authenticated transport, bounded records, retention at least equal to the source, tested restore access, and an approved RPO of zero for acknowledged lineage.

Recovery runs offline with money writes, routing, projection, and status unavailable. It compares local journal, witness, SQLite, Postgres applied head, buyer reservation/credit records, and acknowledgement audit:

| State | Required resolution |
| --- | --- |
| Exact PREPARE plus exact SQLite event, no COMMIT on one/both lineage copies | Verify predecessor/event bytes and no conflicting descendant; append/repair the identical COMMIT on both, then resume from that committed head. |
| Exact PREPARE on both, SQLite event absent, no COMMIT/mirror apply/acknowledgement/dispatch | Two authorized operators sign a `supersede_abort` record binding all inspected heads and evidence. Conservatively void the attempt and release/refund its reservation; never reapply the proposed mutation. |
| PREPARE present but any DB/mirror/ack/dispatch evidence is incomplete or contradictory | Remain unavailable. Restore missing authority from the intact copy or committed target evidence; no operator vote may guess the outcome. |
| Local journal lost/corrupt, witness intact | Rebuild a byte-identical local copy through the witness committed head, verify every digest and SQLite/mirror equality, then dual-control reopen. |
| Witness lost/corrupt, local intact | Provision a replacement independent witness, replicate/verify the complete lineage and heads, then dual-control reopen. |
| Both lineage authorities lost without a target carrying a fully verified committed head | Permanent qualification blocker. No new incarnation may claim continuity. |

A new incarnation is permitted only under dual control after every prior PREPARE is committed or superseded, every outstanding request/reservation/credit is restored exactly or terminally voided/refunded, and local/witness/SQLite/Postgres heads agree. Its genesis binds the prior incarnation/head, recovery-bundle digest, operator approvals, terminalization manifest, and global idempotency namespace. Sequence numbers never repeat across the `(incarnation, sequence)` key, and external references remain globally unique, so mirror or reward application cannot duplicate. Compensating events reference prior event IDs; history is never rewritten. Failure to prove any precondition keeps service unavailable.

### Pre-Gate-B exact schema and feasibility contract

After Gate A0 and before any hot-path benchmark, a docs/fixture-only prototype package must commit:

- closed JSON schemas and canonical encodings for event, lineage, route lifecycle, reward inputs/outputs and recovery bundle, including maximum byte length for every field and explicit absent values;
- an exhaustive symbol/SQL mutation inventory with owner, transaction entry point, lock order, request-revision effect, complete snapshot fields and failure behavior;
- exact SQLite pragmas, WAL checkpoint/fsync mode, APFS device model/media, filesystem/container/mount/file-protection settings, provisioned capacity/free reserve, coordinator CPU/RAM/OS, witness implementation/storage/fault domain/network latency envelope, and recovery topology;
- a deterministic seeded workload file listing mutation proportions, payload-size distribution, concurrency schedule, request-revision chains, witness latency/fault schedule and baseline protocol;
- exact benchmark binary/source digest and acceptance formulas.

Gate B0 binds every file digest before measurement. The benchmark then executes the exact `local PREPARE fsync -> witness PREPARE durable ack -> SQLite transaction/WAL fsync -> local COMMIT fsync -> witness COMMIT durable ack` protocol at 10k/1M/10M events and concurrency 1/8/32. It must sustain at least 100 complete mutations/s for 10 minutes; added p50/p95/p99 route-start latency at most 5/15/30 ms and p99 no more than 15% over the bound baseline; p99 lineage-lock wait at most 20 ms and hard 50 ms deadline; 1,024-entry bounded queue; 64 KiB hard event limit and p99 at most 16 KiB; bootstrap/recovery/storage/RSS/reserve gates in the paired test spec. Any implemented payload, mutation path, durability setting, witness/storage profile, or workload outside the bound package invalidates results and reopens Gate B0/B.

No compaction/deletion is authorized. One-year retained local+witness capacity must be below 20% of each provisioned volume. Failure is an architecture blocker, not grounds to relax a budget.

### Shared MLX resource arbiter

The arbiter owns every in-process action that can load a model or submit MLX/Metal work: buyer inference; compute observation; losslessness probe; `IdlePrewarmer.runInternalWarmup`; `ProviderPreWarmer` startup probing; control-socket `beginSwap` and prepared-adoption load/swap/finalize; model unload/shutdown; and any enabled autotune/maintenance action. `DecodeBenchCommand`, SPEC-028 benchmark/canary, and isolated autotune candidates must hold a mutually exclusive process lifecycle lease and cannot coexist with a serving process. New MLX call sites fail a static owner-registry test until classified.

Lease states are `queued -> dispatching -> running_load -> running_prefill -> running_sampler -> serializing -> cancelling -> quiescing -> quiesced -> terminal`. Buyer inference has absolute admission priority. Model load/swap/adoption takes an exclusive transition lease, blocks probes and prewarm, drains/cancels lower-priority work, synchronizes the device, changes generation, and only then exposes the new runtime. Idle/startup prewarm and maintenance use cancellable background leases. No buyer Metal buffer starts until all conflicting work is quiesced. A two-second quiescence miss drains the provider from routing until device synchronization proves quiescence. Lease generation fences late callbacks and old-runtime results.

### Canonical reward inputs, seven-scope dispositions, and shadow boundary

Before Gate B, SPEC-021 and SPEC-014 must commit machine-readable `provider_reward_status_inputs.v2`, `provider_reward_status.v2`, and generated vectors. The reward owner, not status handlers or clients, produces an effective projection byte-for-byte equivalent to the canonical SQL predicate. The input preserves every simultaneous disposition at these seven closed scopes: `ledger_row`, `useful_work_source`, `provider`, `wallet`, `cohort`, `duplicate_class`, and `epoch`.

Each projected ledger row carries bounded amount, source/accrual ID, scope memberships, and a canonically sorted disposition array `(scope, scope_key_digest, kind=hold|exclude|burn|retire, lifecycle=active|released|terminal, effective_event_id, effective_at, release_at?)`. Active holds are nonwithdrawable until an authoritative release; active/terminal exclude, burn, or retire facts are nonwithdrawable and cannot be overridden by another scope. Released facts remain activity only. The projection also carries provider-day and wallet-day cap states, withheld amounts, `cap_replay_pending`, ledger source head/completeness/freshness, and exact aggregates for withdrawable, held, capped, excluded, burned, and retired amounts. Unknown scope, multiplicity/order violation, disagreement with SQL, or pending cap replay makes withdrawal unavailable; it can never map to `withdrawable`.

Earning input additionally requires `projection_environment=production`, `reward_capability=enabled`, and an authoritative production-ledger accrual ID for the displayed recent request. Build 3 fixes `reward_capability=disabled`; therefore provider-visible earning is `unavailable/reward_capability_disabled` even when an operator shadow decision passes. `eligible_idle` is also unavailable while capability is disabled. Shadow records use a separate qualification schema, database/sink and dependency graph; provider APIs cannot query it, reward activity excludes it, and Swift/portal schemas have no shadow identifier or state. Balances and withdrawal eligibility continue to reflect only canonical production ledger facts. Payment remains `unavailable/malibu_payment_execution_unavailable`.

The exact precedence and all output enums are committed in the schema package. Tests enumerate all seven scopes, simultaneous facts, release/terminal transitions, cap replay, amount aggregation, unknowns, production capability/accrual requirements, and cross-client vectors. One blocked canonical row is sufficient to prevent its amount from entering withdrawable aggregation.

### SPEC-022 and SPEC-036 mode separation

The immutable request payload uses separate `settlement_verification_mode=spec022_observe|spec022_enforce` and `compute_observation_mode=spec036_observe` fields. SPEC-022 observe is economically excluded under all compute states. A final SPEC-022-enforce receipt may carry positive SPEC-036-observe capture, but the capture authorizes only observation display and operator-only qualification analysis. It cannot create a production accrual, provider-visible earning, withdrawal, or payment.

## Data changes, compatibility, rollback, and observability

All migrations are additive. V1 clients receive conservative legacy fields for 90 days after separately authorized v2 rollout or through the next provider-app stable release, whichever is later. New clients fail only the affected projection closed. Observation/journal/scheduler consumers default disabled. Rollback disables probes, consumers and v2 UI while preserving immutable evidence/schema. Shadow artifacts remain outside provider dependencies. Rollback never deletes history, rewrites captures, resumes an uncertain cursor, or restores misleading language.

Metrics cover probe/arbiter leases, queue/cancel/quiescence, model transitions, evaluation reason, CAS/revocation, token boot/key epoch and orphan reconciliation, lineage local/witness heads, recovery states, SQLite/lock/ack latency, bootstrap, seven-scope reward reasons, cap replay, freshness, pagination and redaction. Labels exclude raw prompts, vectors, tokens, secrets, buyer identity, scope keys and unbounded provider strings. Ambiguity, chain disagreement, stale observations, reference disagreement and unknown contracts fail closed and alert.

## Phased implementation after Gate B

1. Governance/schema updates and closed fixtures exactly matching the Gate-B0 package.
2. Local+witness lineage, SQLite observation authority, restart-safe route-token lifecycle, and recovery state machine.
3. Shared MLX arbiter, carrier negotiation, Swift profile hook, all-owner cancellation and quiescence.
4. Reference/calibration evaluation and sanitized status.
5. Immutable billing projection journal, bootstrap, mirror and completeness watermark.
6. Canonical seven-scope reward projection, operator-only shadow sink, and paginated production reward activity.
7. App/portal parity, last-known data, truthful disabled earning/payment copy and accessibility.
8. Built release qualification, Gate C, targeted/broad/physical verification, and three independent complete-diff audit lanes.

Material architecture, contract, scope, schema, mutation inventory, storage/witness profile, workload, or test changes reopen the applicable gate.

## Acceptance and hardware qualification

`test-spec-v4` maps every claim. Local implementation, local tests, actual MLX, physical end-to-end, signed release qualification, and production qualification are distinct. Positive qualification needs exact manifests, two independent reference environments, 80 disjoint calibration units, blind custody, held-out power evidence, supported witness/storage topology, physical Apple Silicon, actual MLX, Xcode app, real browser, and service topology evidence. These are current named qualification blockers until freshly executed. A fixture, skipped test, spike, one host, provider assertion, status adapter, shadow decision, or mirror freshness cannot substitute.

The roadmap's full provider-visible real-job accrual criterion additionally requires an already authorized production reward capability and an authoritative production-ledger accrual. This task cannot activate either. If no such capability and accrual exist at qualification time, implementation may prove receipt/mirror behavior and operator-only shadow evaluation, but provider-visible accrual acceptance remains blocked and must not be reported as passed.

## Explicit non-goals

- SPEC-036 warn/enforce activation or settlement-policy changes.
- MALIBU emission activation, reward-capability activation, withdrawal/payment execution, epochs, payout work, or economic policy changes.
- Production deployment, pool authorization, trusted-pool activation, release publication, hardware procurement, or operator-secret changes.
- Provider-wide integrity, confidential compute, anonymity, physical-computation proof, or malicious-provider honesty claims.
- Inspection of `d-inference` source or a new dependency without approval.
- A second supported model/runtime/profile/hardware class.

## Roadmap outcome mapping

| Roadmap outcome | Implementation step | Verification |
| --- | --- | --- |
| One covered model/runtime/profile | Nonnumeric feasibility and acyclic profile/evidence/release gates | B3-F/G/C/REF/CAL |
| Actual probes and justified references | Shared arbiter/runtime/evaluation | Actual-MLX, disjoint-reference, held-out and power tests |
| Generation validity, expiry, revocation | Boot-bound token lifecycle and observation authority | Crash/restart/key/time/session/generation race matrix |
| Sanitized status | Evaluation/status | Schema/redaction/auth tests |
| Governed reward mapping | Immutable journal plus canonical seven-scope projection | SQL equivalence, cap replay and exhaustive cross-client vectors |
| Portal/app parity | Presentation slice | Xcode/browser state matrix with shadow exclusion |
| Request → receipt → reward visibility | All upstream slices | Correlated physical trace plus separately authorized production-accrual evidence; otherwise report provider-visible accrual acceptance blocked |
| No overclaim/activation | Every slice | Default-off, production accrual requirement, shadow API absence, negative economics and copy tests |
