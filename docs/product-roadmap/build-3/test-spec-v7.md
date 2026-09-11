# Product Build 3 — Test Specification

Test-spec revision: `build3-test-v7`
Plan pairing: `build3-plan-v7`
Repository/base: `Augustas11/macprovider@1d2c930bad81704dd0acc0322226725d8b64aceb`
Status: awaiting independent adversarial approval

## Evidence classes and pass rules

| Class | Meaning |
| --- | --- |
| U | Unit/property/schema test with deterministic inputs |
| I | Local multi-component integration with real databases/services; compute may be a fixture |
| S | Swift package/CLI runtime test on Apple Silicon |
| X | Xcode Malibu app test/run |
| B | Real-browser provider portal test |
| M | Actual MLX inference with exact artifact/runtime/hardware/profile record |
| P | Physical provider-to-services end-to-end journey |
| Q | Operator-approved production qualification/deployed evidence |
| G | Independent native GPT-5.6 Sol adversarial gate over exact committed artifacts |

Skipped, timed-out, zero-selected, interrupted, historical, unavailable-Docker, or fixture-only execution never passes a stronger evidence class. Every record includes command/runner revision, base/head, timestamps, selected/passed/failed/skipped counts, topology, hardware/runtime/model/profile/evidence/qualification context, artifacts and SHA-256 digests, and a pass/fail/blocked result.

## Gate H0, H1, A0, B0D, B0E, B, and C acceptance

| ID | Class | Scenario | Required proof |
| --- | --- | --- | --- |
| B3-F001 | U/G | Review `compute_hook_design.v1` plus `compute_acquisition_authority.v1` at Gate H0 | Exact two Swift target paths, tap location, processor order, synchronization, cancellation, zeroization, serialization bounds, one value-access function, approval key/quorum/public root, capsule/job/grant schemas, online sequence authority, anti-rollback/recovery, build inputs, nonshipment boundary and tests have no TBD; zero C/H/M before Collector Slice H0. |
| B3-F002 | U/S | Implement Collector Slice H0 and inspect complete diff | Only named paths change; production CLI/app/provider/release/deploy import and command graphs contain no collector surface, credential, coordinator, settlement or reward dependency. |
| B3-F003 | S/M | Load exact candidate and reach implemented sampler hook before Gate A0 | Emit only artifact/package/collector identity, stage reachability, shape/dtype, synchronization/cancellation entry points and allocation bounds. The hook reads metadata only and never reads/indexes/reduces/hashes/transfers/copies/serializes value storage; no vector, scalar, extrema, aggregate, value hash or value-correlated timing is emitted. |
| B3-F004 | S/M | Compare normal generation with structurally instrumented collector using identical inputs | Generated token IDs and output bytes match. Evidence contains output parity only and cannot disclose governed values. |
| B3-F005 | U/S | Audit hook, logs, crash reports, artifacts and process outputs before Gate A0; cancel at load/tap/sync/serialize | Every real-tensor value read/copy and every debug/value sink are absent; resources release; synthetic tensors alone exercise encoding. Any leak invalidates profile/protocol/custody. |
| B3-F006 | S | Unsupported API/runtime/stage or existing staged-forward test skips | Typed blocker. A skip is not a pass; no numeric evidence, downstream implementation or availability claim. |
| B3-F007 | U/S/G | Gate H1 over Collector Slice H0 | Zero C/H/M code/security/architecture findings; manifest binds commit, dependency lock, compiler/SDK, unsigned/signed executable and signing identity, separately emitted module object bytes/digest, command schema and nonshipment proof. |
| B3-F008 | U | Build profile/protocol after H1 | Reject null/TBD/wildcard, nominal `4bit`, unapproved collector, unfrozen class/decision/partition/statistic/refresh/power/custody rule, self/forward digest, approval signed before durable Gate A0, or acquisition job outside the approved capsule. |
| B3-F009 | G | Gate A0 reviews exact collector/profile/protocol and issues approval | Zero C/H/M precedes the first capsule signature. Capsule binds exact collector/profile/protocol/reference policy, authority incarnation/sequence root, approval decision, not-before and expiry; logs are supporting evidence only. |
| B3-F010 | M/P | Collect blinded reference/development/held-out/refresh results after Gate A0 | Every acquisition binds a fresh job, monotonically reserved custody sequence, live single-use consumption grant, execution nonce, physical unit/partition/destination and exact signed collector; labels/raw values remain unavailable to threshold authors until threshold digest freezes. |
| B3-F011 | U/G | Gate B0D over preimplementation/tooling design | Closed schemas, mutation inventory, exact durability/storage/witness/archive topology, seeded workload, package interfaces, exact B0I paths and nondeployability controls are digest-bound; zero C/H/M before tooling source work. |
| B3-F012 | U/I | Build Feasibility Tooling Slice B0I | Only allowed Go paths change; command needs qualification tag/compile marker; production import/symbol/command/container/package/installer/workflow/deploy graphs exclude it. Synthetic disposable money data only. |
| B3-F013 | U/I/G | Gate B0E audits and freezes tooling | Zero C/H/M code/security/architecture findings; exact core/adapter/command source, dependency, compiler and executable digests match; any production reachability fails. |
| B3-F014 | I/G | Run frozen benchmarks/recovery/continuation matrix and construct evidence bundle | Measurements match every B0D/B0E digest; Gate B reaches zero C/H/M before Product Slices 1–7. Any source/workload/schema/profile drift invalidates results. |
| B3-F015 | U/S/G | Construct release candidate and qualification | Production embeds byte-identical Gate-H1 measurement-module object under the same compiler/dependency ABI; mismatch returns to H0/H1/A0 and recollects. Prequalification stays nonpositive; Gate C reaches zero C/H/M before a positive local key. |
| B3-F016 | U | Change each artifact, collector/module or bound profile dimension | Downstream digest changes, prior evidence cannot rebind, and production key returns unknown. |
| B3-F017 | U/S/M | Instrument first value-storage access in collector CLI and production-runtime harness; present missing, pre-approval, wrong-digest/policy/profile, replayed, expired, revoked, rolled-back, wrong-unit/partition/destination, cached, consumed or offline authority | Access sentinel count stays zero, result is a typed pre-value blocker, sequence state changes only where specified, and no value-correlated output/timing is emitted. Valid live authority reaches the sentinel exactly once. |
| B3-F018 | U/I | Crash authority or collector at reserve, consume, first access, encryption, upload and completion; restore authority from old/current snapshots and rotate incarnation/public key | Consumed sequence is burned and never reusable; only quorum-verified checkpoint+log at or beyond witnessed head resumes; rollback/ambiguous fork blocks; retired namespace cannot sign or consume. |
| B3-F019 | U/S | Inspect compiler call graph/link map and attempt alternate CLI/runtime tensor reads, copied handles, test hooks and adapters | The raw value handle is private to `withAuthorizedPostSamplerValues`; every numeric path passes the same authorization check immediately before value access; any alternate reachability fails Gate H1/C. |
| B3-F020 | U/G | Evaluate gate graph with numeric lane blocked and Gate-B0 lane passing, then reverse | Gate B0D/B0I/B0E and synthetic benchmarks can complete without numeric imports; neither lane alone can construct the evidence bundle, unlock Product Slices 1–7 or produce positive/economic authority. |
| B3-F021 | U/S/I | Request calibration, reference, release-qualification and production-observation jobs at every preceding/following gate state | Authority issues only the exact mode whose antecedents are durable: Gate-A0 capsule for calibration/reference, admitted candidate for release qualification, and Gate-C qualification plus rollout authorization for production observation. Wrong-mode reuse fails before value access. |

## Independent references and calibration

These are physical qualification requirements. The current session does not satisfy them by fixtures or by a smaller cohort.

| ID | Class | Scenario | Required proof |
| --- | --- | --- | --- |
| B3-REF001 | M/P | Reference source A admission/refresh | Approved operator authority, signing key, physical host/fault domain, independent runtime-build/kernel provenance, antecedent/artifact/catalog/tokenizer equality, golden pass, times and event digest. |
| B3-REF002 | M/P | Reference source B admission/refresh | Same fields and simultaneous inequality from A on operator, physical/power/network domain and runtime-build/kernel provenance. |
| B3-REF003 | U/I | Correlate/remove any independence axis or overlap reference with calibration/provider host/fault domain | Quorum inadmissible; no positive state. |
| B3-REF004 | U/I/M | Invalid signature/antecedent, stale/revoked source, failed golden, disagreement | Rejected/reference fault without incorrectly advancing provider drift counters. |
| B3-REF005 | U/I/M | Valid A and B successors name exact source predecessors and common prior epoch within movement/divergence/skew envelope | One atomic new reference epoch; qualification remains valid only while all other expiries hold; new observations bind new epoch and old captures stay immutable. |
| B3-REF006 | U/I | A advances alone; B is late; source clocks exceed skew; A/B disagree | New positive observations suspend with exact refresh reason; no mixed epoch, implicit qualification extension or provider drift increment. |
| B3-REF007 | U/I | Source fork, gap, replay, late old event, changed root/provenance/profile or wrong prior epoch | Reject without moving either accepted source head or epoch; dependent state stays nonpositive where freshness expires. |
| B3-REF008 | U/I/M | Successor outside numeric envelope, calibration/qualification expiry, reference revocation during in-flight request | Prospective state becomes nonpositive at one authority revision; in-flight capture remains exact; recovery requires the closed new-epoch or full-requalification path. |
| B3-CAL001 | U/G | Freeze protocol before numeric acquisition | Exact 20-development/60-held-out independent unit partition, unit/cluster definition, full prompt/repetition matrix, JS statistic, ceiling/formula, blind custody, false-quarantine rule, positive-control effect/power, exclusions/stopping/expiry are approved. |
| B3-CAL002 | M/P | Execute 80 disjoint host/fault-domain campaigns | Each host contributes one decision; positions/prompts/repetitions never increase `n`; partitions meet operator/runtime-provenance diversity and exclude references/provider. |
| B3-CAL003 | M/P | Freeze threshold using development/reference data, then unseal held-out labels | Threshold digest predates every held-out read. Zero of 60 good units quarantine; exact-binomial one-sided 95% upper bound <=5.0%. |
| B3-CAL004 | M/P | Execute paired blinded minimum-effect positive controls on held-out units | At least 59/60 host-level controls detected and one-sided 95% lower bound >=90%; both runtime perturbation and hook-boundary transform strata pass. Structural mismatch rejection does not count. |
| B3-CAL005 | U/I | Count positions/repetitions as trials; reuse host/fault domain; reveal label/vector early; change effect/statistic/threshold/exclusion after data | Result and bundle inadmissible; new protocol digest and Gate A0 required. |
| B3-CAL006 | U/I | Missing unit/sample, failed tail, expired result, or hardware field outside predicate | Qualification blocks or returns uncovered; no parameter widening or discretionary exclusion. |
| B3-CAL007 | M/P | Blind held-out known-good daily successor campaigns | Zero of 60 host units falsely suspend; one-sided 95% upper bound <=5.0%; positions/days/repetitions do not increase `n`. |
| B3-CAL008 | M/P | Blind single-source and correlated two-source meaningful successor-drift controls | Each fixed stratum detects >=59/60 and one-sided 95% lower bound >=90%; post-hoc movement/divergence/skew widening rejects the protocol. |

## Closed schema and compatibility

| ID | Class | Scenario | Required result |
| --- | --- | --- | --- |
| B3-C001 | U | Valid profile/protocol/evidence/policy/reference/calibration/qualification chain | Stable canonical digests, acyclic direction and exact cross-binding. |
| B3-C002 | U | Unknown field/enum, duplicate key, trailing JSON, invalid UTF-8/numeric, NaN/Inf, oversized field | Typed rejection before state transition. |
| B3-C003 | U | Change each load-bearing dimension | New downstream digest/key; no inherited observation window. |
| B3-C004 | U | Sanitized status | Only allowlisted state/digests/times/disclosure/action; no prompts, logits, probabilities, thresholds, secrets, buyer or other-provider data. |
| B3-C005 | U | Old client receives additive response | Conservative and functional for declared window. |
| B3-C006 | U | New client receives unknown schema/state/reason/action in one projection | Only affected projection unavailable; independent projections remain intact. |

## Observation authority and restart-safe request-start linearization

| ID | Class | Scenario | Required result |
| --- | --- | --- | --- |
| B3-O001 | I | Install/replay observation events and restart | Same head/state; freshness never extends. |
| B3-O002 | I | Same idempotency/body versus changed body | Exact replay is one event; changed body conflicts/audits. |
| B3-O003 | I | Evaluator/revocation/profile races | One predecessor CAS wins; stale evaluator cannot resurrect. |
| B3-O004 | I | Request commits before/after revocation | Deterministic immutable capture of prior or nonpositive new state. |
| B3-O005 | I | Token mint sequence, signed UTC bounds and live monotonic deadline | Sequence increases inside one boot epoch; wall-clock forward/backward movement never extends live deadline; old boot/key epoch rejects. |
| B3-O006 | I | Disconnect/reconnect/generation reuse/model/catalog/rate/BYOM movement at every mint/capture/claim/attempt/send boundary | Exact tuple either sends once or journals terminal orphan/failed state; no stale paid receipt, settlement or reward. |
| B3-O007 | I | Kill coordinator after mint, PREPARE, SQLite capture commit, claim reserve, durable attempt, immediately before/after send and result commit | Startup lineage recovery terminalizes every committed-but-unclaimed token. Old-epoch late result rejects. Accepted committed receipt remains; uncertain sent attempt is nonrewardable and reservation is released/refunded. |
| B3-O008 | I | Rotate MAC key at each lifecycle state | New key epoch; minted/reserved work terminalizes; no old-key validation after restart/rotation. |
| B3-O009 | I | Nil generation/tuple field, forged token, reused token/claim nonce | Uncovered/rejected with no dispatch or economic record. |
| B3-O010 | I | Reverse lock acquisition or hold WS lock across lineage/SQLite | Static/runtime assertion fails. Canonical order and no-cross-owner-lock invariant hold. |
| B3-O011 | I | Observation versus existing settlement-enforcement capture schemas | Separate, non-substitutable fields and authority. |

## Carrier, in-process arbiter, and process lifecycle coordinator

| ID | Class | Scenario | Required result |
| --- | --- | --- | --- |
| B3-P001 | U/I | Plain SPEC-036 frame on Tier-2 or encrypted frame without exact session/domain | Rejected; replay identity enforced. |
| B3-P002 | U/I | Older provider lacks capability/returns unsupported NAK | No retry storm/disconnect; buyer serving remains available. |
| B3-P003 | U/I | Compute and losslessness due simultaneously inside serving process | Compute first, one aggregate probe slot, bounded wait/fairness under buyer priority. |
| B3-P004 | U/I/P | Buyer races compute, losslessness or `IdlePrewarmer` at load/prefill/sampler/sync/serialization | In-process background work cancels/quiesces; no buyer Metal buffer starts before synchronization; no late state/economic event. |
| B3-P005 | U/I/P | Buyer/probe races control-socket beginSwap, prepared adoption, load, finalize, unload and shutdown | Exclusive transition lease drains lower-priority work, synchronizes, advances generation, then exposes new runtime. Old-runtime callbacks reject. |
| B3-P006 | U/I | Three-way buyer + probe + `IdlePrewarmer` or model transition race | Exactly one permitted in-process device owner, deterministic priority, bounded cancellation, all leases/counters released. |
| B3-P007 | U | Add new MLX/Metal call or process-launch site without registry classification | Static ownership test fails. |
| B3-P008 | U/I | `ProviderPreWarmer`, decode bench, SPEC-028 or autotune attempts launch while serving lifecycle lease exists | Rejected before `spawn`; no second MLX process or readiness claim. |
| B3-P009 | U/I | Queue/cap/size/NaN/expiry/disconnect/profile/policy pressure | Exact limits and typed rejection; no leaked slots or persisted/economic result. |
| B3-P010 | S/M/P | In-process work exceeds two-second quiescence budget | Provider drains from routing until proved device quiescence; buyer reroutes/fails safely; late completion fenced. |
| B3-P011 | S/M | Exact qualified real-MLX probe | Bound distribution and context within approved limits. |
| B3-P012 | I | Probe attempts paid receipt/debit/credit/reward path | Rejected; zero economic records. |
| B3-P013 | U/I | Prewarm-to-serving transition with no incumbent | Supervisor retains one lifecycle lease from pre-spawn through child readiness and routable promotion; child readiness alone grants no routing. |
| B3-P014 | U/I | Two parents concurrently start `ProviderPreWarmer`/candidate | Exactly one acquires; loser never spawns. Owner record binds boot, nonce, supervisor/child PID-start identity and process group. |
| B3-P015 | U/I | Parent exits or heartbeat/liveness pipe closes during child load/prefill/ready | Child stops admission, cancels/quiesces and exits; bounded TERM/KILL plus `waitpid` leaves no orphan MLX process. |
| B3-P016 | U/I | Crash/restart with orphan record, PID reuse, mismatched start identity or unkillable group | Recovery kills/reaps only verified orphan before clearing; ambiguous/reused/unkillable identity fails closed and no child starts. |
| B3-P017 | U/I | Incumbent serving process transitions to candidate | Incumbent drains, synchronizes, exits and releases before contender acquires; no overlap exists at any sampled process/device boundary. |
| B3-P018 | S/I | Start foreground `macprovider-cli serve` and race every candidate/decode/SPEC-028/autotune launcher before model initialization | Direct serve owns the common lease first; every contender rejects before `spawn` or Metal/model initialization. |
| B3-P019 | S/I | Start two direct serves, Malibu.app versus direct serve, launchd-direct versus launchd-supervisor, and wrapper recursion | Exactly one explicit owner mode acquires; losers do not initialize MLX; no wrapper double-acquires or bypasses the registry. |
| B3-P020 | S/I | Signal direct serve during load, request, probe, swap and serialization | Admission stops, work drains/cancels, device synchronizes, runtime is destroyed, owner record clears and only then does the lock release. Timeout keeps routing off and ownership unavailable. |
| B3-P021 | S/I | SIGKILL direct serve; restart with stale owner, reused PID/start identity, live ambiguous process or unkillable orphan | Kernel lock release alone is insufficient: registry scan and bounded device-quiescence barrier precede clearing; ambiguity/reuse/unkillable state fails closed. |
| B3-P022 | S/I | Attempt live re-exec, upgrade and supervisor/direct lease handoff | Live handoff/re-exec is rejected; supported upgrade drains, exits, releases and then starts a new owner with a new nonce and no overlap. |

## Immutable billing journal, witness, and restoration

| ID | Class | Scenario | Required result |
| --- | --- | --- | --- |
| B3-M001 | I | Every Gate-B0 inventoried mutation | Exact PREPARE manifest becomes durable on both authorities before a dedicated SQLite transaction authorization exists; the same transaction exhausts that manifest and appends the complete event. Unlisted production mutation fails inventory/static gate. |
| B3-M002 | I | Local or witness PREPARE fails before SQLite | No source mutation or acknowledgement. |
| B3-M003 | I | SQLite commits then local/witness COMMIT fails | Routing/projection/status freeze; recovery uses exact event and commits identical head before resume. |
| B3-M004 | I | Restore older SQLite at every local/witness/DB/mirror boundary | Surviving authority detects rollback; no freshness/cursor reuse. |
| B3-M005 | I | PREPARE exists, exact SQLite event exists, COMMIT missing | Verify and repair identical COMMIT to both authorities exactly once. |
| B3-M006 | I | PREPARE exists, DB event absent, and no mirror/ack/dispatch evidence | Two distinct authorized operators sign `supersede_abort`; attempt voided and reservation released/refunded; proposed mutation never reapplied. |
| B3-M007 | I | Ambiguous or contradictory PREPARE evidence | Remains unavailable; operator vote cannot guess or mint continuity. |
| B3-M008 | I | Lose/corrupt local journal only | Rebuild byte-identically from witness, verify SQLite/mirror heads, dual-control reopen. |
| B3-M009 | I | Lose/corrupt witness only | Provision independent replacement, copy/verify full lineage, dual-control reopen. |
| B3-M010 | I | Lose both authorities without complete verified target head | Qualification remains blocked; new incarnation rejected. |
| B3-M011 | I | New incarnation with nonterminal PREPARE, outstanding reservation/credit, head disagreement or reused idempotency | Rejected. With all terminal, exact/refunded obligations and agreeing heads, genesis binds prior head/recovery approvals/manifest. |
| B3-M012 | I | Reapply prior mutation, replay compensating event, duplicate external reference across incarnation | Unique constraints/idempotency prevent duplicate economic application. |
| B3-M013 | I | Bootstrap/recovery crash and concurrent writer at every phase | Deterministic resume; writes excluded; no ready state before local/witness/SQLite/Postgres convergence. |
| B3-M014 | I | Mirror snapshot/range/replay/gap/fork/revision races | Complete only through exact matching incarnation/sequence/digest/time; payload-only idempotent convergence. |
| B3-M015 | I | Fresh USDC with stale/incomplete rewards mirror | Freshness stays independent in API/UI. |
| B3-M016 | I | Race activation phases; after protocol 2 start each supported old coordinator or run every legacy/direct SQL mutation | Offline supervisor fence precedes PREPARE/SQLite/COMMIT; any crash stays unavailable. Durable SQLite triggers reject old/unregistered connections and protocol-2 connections without the exact transaction authorization before mutation; local/witness/DB heads and money rows remain byte-identical. |
| B3-M017 | I | Restore pre-activation SQLite after external activation or restore post-activation SQLite to older head | Supervisor/witness epoch or retained trigger blocks startup/write; no old binary receives money-directory access. |
| B3-M018 | I | Start forward recovery build after activation | Protocol-2 writers/recovery remain; probes/readers/UI disabled; activation/min-writer epoch cannot decrease. |
| B3-M019 | I | Seal at 1 GiB/7 days and checkpoint at 30 days/4 segments; hit obligation-count/checkpoint-byte bound | Local and witness produce identical seals/checkpoints binding sequence range, chain root, applied heads, obligations, archive catalog and prior checkpoint. Admission stops before either checkpoint bound and resumes only after authoritative terminalization. |
| B3-M020 | I | Crash at each seal/checkpoint/archive-copy/readback/catalog-CAS/hot-eviction boundary | Deterministic resume has two retrievable copies, no head rollback, gap, duplicate, lost obligation or early eviction. |
| B3-M021 | I | Five-year synthetic continuation, two archive-volume replacements, checkpoint startup and full restore | Logical chain/external IDs remain complete; restore from validated checkpoint plus later segments equals genesis replay; bounded startup/resource gates hold. |
| B3-M022 | I | Archive copy corrupt/missing, catalogs disagree, obligation depends on old payload, retention unmet or archive shares fault domain | Relocation/eviction and new money work stop conservatively; dual control cannot override evidence. |
| B3-M023 | I | Projected exhaustion crosses 365/270/210/180-day thresholds or renewal lacks restore/growth/health proof | Alerts at 365/270; no renewal at 210; no new PREPARE at 180; history is never deleted or head-reset to recover capacity. |
| B3-M024 | U/I | From an approved process/registered-function connection, execute every legacy/direct helper without PREPARE-derived authorization | BEFORE trigger rejects before any governed row commits; SQLite, projection event and both lineage heads remain unchanged. |
| B3-M025 | U/I | After dual PREPARE, change table, operation, key, before/after body, event digest, multiplicity or statement order | Manifest comparison rejects and transaction rolls back; authorization cannot be widened or copied. |
| B3-M026 | U/I | Omit the projection event, omit an expected mutation, add an extra mutation, split across transactions or issue COMMIT without finalize | Driver commit hook rolls back the complete transaction; no partial money state exists. |
| B3-M027 | U/I | Reuse authorization after commit/rollback, install on another connection, race setup with cancellation/rollback, or return connection to pool | Rejected; context is connection+transaction bound, single use and cleared; durable PREPARE remains for specified recovery only. |
| B3-M028 | I | Crash after local PREPARE, witness PREPARE, authorization install, each SQLite statement, finalize, SQLite commit and each COMMIT append | Recovery reaches exactly one specified state; no mutation precedes dual PREPARE, no ambiguous state serves/routes/projects, and token reuse never completes a second mutation. |

## Gate-B0 design, executable tooling, and feasibility contract

| ID | Class | Scenario | Required result |
| --- | --- | --- | --- |
| B3-H001 | U/G | Gate B0D package inspection | Closed schemas/field bounds, exhaustive mutation inventory, exact SQLite/APFS/witness/archive settings, transaction authorization/commit-hook mechanism, segment/checkpoint state machine, capacity, seeded synthetic workload, core interface, allowed paths and nondeployability controls contain no TBD; zero C/H/M. |
| B3-H002 | U/I | Compile B0I without qualification tag/marker or inspect production artifacts/graphs | Feasibility command is unavailable; no coordinator/provider/app/release binary has its symbols, route, command, config, image or deploy reference. |
| B3-H003 | U/I/G | Gate B0E complete tooling audit | Exact allowed diff, synthetic disposable inputs, core protocol conformance and exclusion tests pass; zero C/H/M; source/dependency/compiler/executable digests freeze. |
| B3-H004 | I | Bound protocol at 10k/1M/10M events, concurrency 1/8/32, exact mix for ten minutes | >=100 complete mutations/s; added p50/p95/p99 <=5/15/30 ms; p99 regression <=15%; p99 lock wait <=20 ms; zero errors. |
| B3-H005 | U/I | 64 KiB event/+1, queue 1,024/+1, 50 ms lock deadline | Boundary accepted; overflow rejected before PREPARE/DB/dispatch/debit. |
| B3-H006 | I | 1M bootstrap, 10M startup/recovery, checkpoint-based startup and genesis-equivalent restore | <=15 minutes bootstrap, <=60 seconds startup verification, <=512 MiB RSS increase; exact local/witness/archive/DB/mirror heads. |
| B3-H007 | I | Free capacity below `max(10 GiB, 180-day p99 growth)`, ENOSPC/fsync/network/archive fault at every write | New work stops conservatively; post-DB ambiguity freezes until specified recovery. |
| B3-H008 | I | Five-year event distribution, segmentation/checkpointing, hot-tier relocation and archive migration | p99 event <=16 KiB; growth <=2 GiB/day; two durable retrievable copies always exist; hot use bounded; chain and obligations preserved. |
| B3-H009 | U/I | Change core source, payload, mutation path, durability mode, hardware/filesystem/archive/witness profile or workload after B0D/B0E | Benchmark invalid; B0D/B0E/B reopen. |
| B3-H010 | U/I | Rewrite event, omit segment, trust checkpoint without validated prior root, evict before two-copy proof, emergency-delete or reset head | Rejected; qualification blocks and logical lineage remains complete. |
| B3-H011 | U | Search Gate-B0 schemas, sources, fixtures, dependency graph and executable bytes for collector/profile/reference/calibration/probability/threshold inputs | None exist; only generated synthetic money mutations and fixed nonnumeric protocol parameters are accepted. |
| B3-H012 | I/G | Complete B0D, B0I, B0E and synthetic benchmarks while Gate A0/physical campaign is deliberately absent | Feasibility evidence can pass its own gates and is labeled nonnumeric/nonproduction; Product Slices, qualification, status, settlement and economics remain blocked. |
| B3-H013 | U/I | Run direct SQLite mutation and incomplete-transaction cases under the exact selected driver/version | Native connection identity, authorizer scalar functions and commit hook enforce the paired mutation-authorization matrix; unavailable driver support or bypass fails B0D/B0E rather than weakening the contract. |

## Canonical reward-state contract and shadow exclusion

The same generated production fixtures drive SQL, Go, Swift and portal. Qualification fixtures are separate and never enter provider APIs.

| ID | Class | Scenario | Required result |
| --- | --- | --- | --- |
| B3-R001 | U/property | Enumerate closed source states/reasons/unknowns | Exactly one output per projection; unknown affects only its domain conservatively. |
| B3-R002 | U/I | Compare canonical SPEC-021 SQL with projected input bytes | Byte-for-byte equivalent rows, dispositions, caps, heads and aggregates. Any disagreement is unavailable. |
| B3-R003 | U/property | Each of seven disposition scopes independently and all simultaneous combinations | Active/terminal exclude/burn/retire and active holds prevent affected amount from withdrawable; released facts remain activity only. |
| B3-R004 | U/I | One row has simultaneous hold, exclude and retire at different scopes | Closed ordering preserved; terminal state wins eligibility without dropping other activity facts. |
| B3-R005 | U/I | Provider-day/wallet-day caps, withheld amounts and `cap_replay_pending` | Pending replay is unavailable; caps/amounts aggregate exactly; never withdrawable early. |
| B3-R006 | U/I | Release hold, terminalize exclusion/burn/retire, replay same events | Monotonic/idempotent transition; exact aggregates and activity. |
| B3-R007 | U/I | Compute unknown/stale with eligible production balance | Earning unavailable; withdrawal remains truthful from canonical ledger; payment unavailable. |
| B3-R008 | U/I | Missing/mismatched wallet with eligible balance | Add-wallet or contact-support action; balances/activity preserved. |
| B3-R009 | U/I | Fresh USDC, stale reward ledger | USDC fresh; rewards last-known/stale. |
| B3-R010 | U/I | `reward_capability=disabled` with positive observation, eligible request and qualification shadow decision | Provider earning and eligible-idle remain unavailable with `reward_capability_disabled`; balances unchanged. |
| B3-R011 | U/I | Capability enabled fixture without production accrual ID, qualification environment, or shadow ID supplied to provider mapper | Earning rejected/unavailable. Only production environment plus authoritative accrual can select earning. |
| B3-R012 | U/I | Qualification shadow decision passes/replays | Operator sink idempotent; production ledger/emission/payment/provider-status/activity tables byte-identical. |
| B3-R013 | U/X/B | Inspect API schemas/routes, generated clients, app and portal for shadow fields/IDs/states | None exist; shadow row cannot appear as earning, balance or activity. |
| B3-R014 | U/property | Exhaust valid partitions, reasons, simultaneous conditions and unknown enum per domain | Total deterministic precedence/secondary ordering; no optimistic fallthrough. |
| B3-R015 | U/X/B | Replay canonical production vectors | Go/Swift/portal outputs identical state/reason/action/freshness. |
| B3-R016 | I | Production emission/reward-capability/payment/withdrawal execution gates | Remain off; observation or shadow availability changes no gate. |
| B3-R017 | U/I | Inventory every governed Postgres writer and attempt direct/legacy mutation without transaction revision token | Revoked DML/sequence privileges, SECURITY DEFINER entry points, server-only token and DB trigger reject; no ledger/disposition/cap/activity/completeness/applied-wallet-head fact can commit outside one source revision. |
| B3-R018 | I | Race joined projection with ledger insert, disposition add/release/terminalize, membership change, wallet event/mirror apply, cap update and cap replay start/clear/end | Returned summary and first page equal one Postgres snapshot plus an exactly matching authoritative SQLite wallet head; no optimistic/nonexistent cross-database combination. |
| B3-R019 | I | Race joined projection with activity append, billing head advancement and payout-wallet source advancement before/after each snapshot | Result binds `(reward_revision,wallet_head,wallet_checkpoint)` and distinct PG/mutation/checkpoint/observation/verification/generated times. Head mismatch returns `wallet_projection_pending`; unrelated balance/compute/payment domains preserve truthful states. |
| B3-R020 | U/I | Paginate composite-version activity while new Postgres and wallet events commit | Cursor returns stable as-of rows/order under original `(R,H,C)` without claiming a new live observation; observation age becomes stale truthfully. Explicit summary refresh uses a new challenge and joined version. |
| B3-R021 | U/I | Tamper cursor/provider/filter/page size/reward revision/wallet head/checkpoint sequence or digest, or expire any required as-of history | MAC/composite-version check rejects or returns `snapshot_expired`; never silently substitutes current data. |
| B3-R022 | U/property | Postgres revision gaps, aborted writer transaction, attempted revision reuse or fact without committed revision | Gaps accepted; aborted/reused/orphan facts invisible or rejected; Postgres revision remains monotonic and authoritative for its domain. |
| B3-R023 | U/I | Add, replace, revoke, disable and remove payout address through every supported SPEC-016 writer | Dual wallet-lineage PREPARE precedes one authorized SQLite transaction that appends the canonical event and advances source head; acknowledgement follows dual COMMIT. Direct mutation without exact authority rejects. |
| B3-R024 | I | Delay/omit mirror; crash wallet mutation or poll after each PREPARE/SQLite/COMMIT/range-read/apply/revision boundary; advance wallet head after Postgres snapshot | SQLite event without dual COMMIT is recovery-pending and cannot mirror. Wallet/withdrawal is pending/unavailable with last-known mutation/checkpoint/observation times; no old wallet is stamped current/eligible; retry applies each contiguous committed event once. |
| B3-R025 | I | Replay same wallet event, changed replay, SQLite/local/witness gap or fork, lower-head source restore, authority disagreement or source-incarnation transition | Exact replay is idempotent; all other cases fail wallet completeness closed and cannot erase last-known facts or advance joined version. |
| B3-R026 | I | SQLite unavailable/stale while rewards fresh; rewards stale while wallet head current; fresh USDC/payment status under both | Each domain reports its own source time/freshness. Mutation, checkpoint, live observation, reward, payment and USDC clocks remain separate. Wallet failure affects wallet-bound/withdrawal only; balances, compute, payment and USDC are not collapsed. |
| B3-R027 | U/I | Endpoint or client attempts direct payout-row read or joins wallet content outside reward owner | Static dependency/API test fails; returned wallet facts come only from the versioned Postgres projection plus authoritative-head equality check. |
| B3-R028 | I | Wallet changes immediately after all three challenge assertions read the authoritative head and before response serialization | Response remains linearizable before that later mutation, binds old `(R,H,C)` and independent mutation/checkpoint/observation times, and the next explicit refresh returns the new head or pending state. |
| B3-R029 | I | Leave a valid wallet unchanged for ten five-minute freshness windows while the source, local journal and witness remain reachable | On-demand checkpoints advance only `C`; `H`, wallet event sequence, payout rows and `source_committed_at` remain byte-identical. Every new challenge returns current wallet binding and truthful withdrawal eligibility when ledger policy permits. |
| B3-R030 | I | Restart coordinator between challenges and replay the complete pre-restart assertion set | New boot identifier and absent in-flight nonce reject replay. A newly issued authenticated challenge against unchanged `(H,C)` succeeds and does not mutate wallet provenance. |
| B3-R031 | I | Restart wallet owner, local authority and witness singly and together across freshness-window boundaries | Each new serving incarnation verifies durable `(H,C)` before responding. Fresh separately signed assertions succeed only after verification; old-incarnation assertions reject. Quiet valid wallet remains available after recovery. |
| B3-R032 | U/I | Replay a consumed assertion or nonce; substitute provider, endpoint audience, requested head, authority, key epoch, serving incarnation, checkpoint or challenge digest | Atomic single-use and exact binding reject with `wallet_observation_replayed` or `wallet_observation_unauthenticated`; no new view/cursor is emitted. |
| B3-R033 | U/I | Delay an assertion beyond five seconds; future-date an assertion/checkpoint; regress checkpoint or assertion time; step any authority clock backward beyond two seconds; roll coordinator wall clock while monotonic time advances | Expired/future/rollback inputs return `wallet_observation_stale` or `wallet_observation_clock_invalid`; no checkpoint commit or freshness extension. Recovery requires valid clock/new verified serving incarnation as specified. |
| B3-R034 | I | Stop local authority or witness before checkpoint PREPARE, COMMIT, challenge assertion or restart verification | Wallet binding/withdrawal alone becomes unavailable with exact checkpoint/observation reason and last-known facts; balances, compute, payment and USDC retain independent states. No one-authority observation passes. |
| B3-R035 | I | Crash checkpoint renewal after each local PREPARE, witness PREPARE, SQLite CAS, local COMMIT and witness COMMIT boundary | Startup/recovery either completes one identical `C` at all authorities or reports `wallet_checkpoint_pending`; it never advances `H` or `source_committed_at`, skips/duplicates `C`, or serves partial checkpoint authority. |
| B3-R036 | I | Commit wallet mutation immediately before checkpoint CAS, after a still-young checkpoint for the prior head, during challenge fanout, immediately after all assertion reads, and immediately before response serialization | Any `C` whose record does not bind current `H` is renewed. CAS retries from the new head or boundedly returns `wallet_observation_raced`; exact old-head linearization or Postgres/head pending is allowed, mixed heads/currentness are not. |
| B3-R037 | U/I | Paginate at `(R,H,C)` after observation freshness expires and after newer checkpoints/mutations exist | Original activity snapshot stays stable if retained, carries the original observation interval and is labeled stale; it cannot renew eligibility. Missing retained `H` or `C` returns `snapshot_expired`; explicit refresh creates a new challenge. |
| B3-R038 | U/I/X/B | Exercise every wallet observation failure reason with eligible balance and fresh compute/payment/USDC fixtures | Go, Swift and portal preserve last-known wallet value and mutation/checkpoint/observation timestamps, set only wallet binding/withdrawal unavailable, and show the closed recovery action without saying current, idle, earning or operational withdrawal. |
| B3-R039 | U/I | Flood concurrent and cross-provider summary refreshes at the closed Gate-B0D limit while `H` is quiet, then mutate `H` at the maximum admitted lifecycle rate | Quiet challenges share at most one fully committed checkpoint per 150 seconds but use distinct single-use assertions. Head-change renewals remain bounded, checkpoint proof retention stays within the measured budget, and excess work returns wallet-only unavailable without stale success or lineage exhaustion. |

## SPEC-022 settlement versus SPEC-036 observation

| ID | Class | Scenario | Required result |
| --- | --- | --- | --- |
| B3-D001 | U/I | SPEC-022 observe under every SPEC-036 state | Economically excluded; zero production or shadow accrual. |
| B3-D002 | U/I | SPEC-022 enforce + positive SPEC-036 observation in qualification target | Operator-only shadow decision may pass; provider earning remains disabled and production ledger untouched. |
| B3-D003 | U/I | SPEC-022 enforce + nonpositive/missing/mismatched observation | No shadow decision; existing settlement rules continue without substitution. |
| B3-D004 | U | Inspect production dependency graph/config/release fixtures | Qualification sink and enabling flag absent; configuration cannot activate it. |
| B3-D005 | U/I | Positive observation without valid price/model/identity/finality, or provider signature alone | Cannot authorize settlement, accrual, earning, withdrawal or payment. |

## App and portal parity

| ID | Class | Scenario | Required result |
| --- | --- | --- | --- |
| B3-U001 | X/B | Fresh USDC, stale rewards | Independent freshness and last-known values. |
| B3-U002 | X/B | Unknown compute plus eligible historical balance | Earning unavailable; withdrawal can remain eligible; no “earning now.” |
| B3-U003 | X/B | Positive local qualification/shadow decision with capability disabled | Explicit non-economic observation copy and `earning unavailable`; no shadow activity. |
| B3-U004 | X/B | Withdrawable balance and payment unavailable | “MALIBU balance is eligible for withdrawal; payment execution is unavailable.” No withdraw CTA. |
| B3-U005 | X/B | Missing/mismatched wallet | Correct action; balances/activity preserved. |
| B3-U006 | X/B | Historical released/terminal dispositions and current caps/holds | Timestamped activity preserves every scope; only current authoritative fact controls status. |
| B3-U007 | X/B | Complete fresh mirror has no recent production accrual while capability disabled | Earning remains unavailable, never confirmed earning or eligible-idle. |
| B3-U008 | X/B | Stale/revoked/profile-changed observation | Narrow coverage, evidence time, reason/action; no broad claim. |
| B3-U009 | X/B | Paginated activity, duplicate cursor, empty final page and partial failure | Stable order/dedupe/cursor; summary and activity fail independently with last-known retention. |
| B3-U010 | X/B | Unknown v2 value in one projection | Affected card unavailable; others remain valid. |
| B3-U011 | X/B | Keyboard/screen reader/narrow layout | State/time/reason/action/disclosure/pagination perceivable. |

## Correlated physical first-job acceptance

| ID | Class | Scenario | Required evidence/result |
| --- | --- | --- | --- |
| B3-A001 | M/P | Exact approved qualification executes probe | Hardware/runtime/model/profile/reference/calibration/held-out/power/custody/release/qualification IDs and timings recorded. |
| B3-A002 | P | Real nonstreaming paid job through actual MLX | Durable boot-bound token lifecycle, request capture, dispatch attempt, receipt and verification bind exact context. |
| B3-A003 | P | Delay receipt beyond mirror pass, then settle | New complete event advances same request revision chain and completeness correctly. |
| B3-A004 | P | Operator shadow consumes correlated event twice | One isolated shadow audit result; production ledger/provider API/activity unchanged. |
| B3-A005 | X/B/P | App and portal display correlated request | Same observation/request/ledger/withdrawal/payment facts; earning explicitly unavailable under disabled capability. |
| B3-A006 | P | Cancel/reconnect/restart/key rotate/revoke reference/change generation/profile; stale rewards with fresh USDC | Contracts recover without corrupting model, duplicating economics or inventing idle/earning. |
| B3-A007 | Q | Separately authorized production reward capability and authoritative accrual for the correlated real job already exist | App/portal activity and earning may display that production accrual with exact ledger/event IDs. Without this external prerequisite, provider-visible accrual acceptance is blocked; shadow evidence cannot satisfy it. |

Physical completion is distinct from production qualification. Missing references, 80 disjoint calibration units, blind custody, witness topology, MLX/Xcode/browser evidence, operator approval or separately authorized production accrual is a named blocker, not a passed criterion.

## Security and abuse tests

- Provider/operator/status/reward/activity authorization matrix and cross-provider isolation.
- Carrier replay, nonce collision, request smuggling, duplicate-key JSON, compression/size bombs, malformed numeric values, cancellation, reconnect, clock and boot/key-epoch abuse.
- WS/lineage/SQLite lock-order races; local/witness divergence; permissions/symlink/append/fsync/network/restore/fork faults; dual-control separation.
- Bounded CPU/GPU/memory/disk/network/queue/raw-evidence retention; buyer priority and arbiter fairness.
- Log/metric/HTTP/evidence/app/portal redaction for prompts, vectors, tokens, secrets, buyer identity, scope keys and unbounded strings.
- Proof that provider assertion/signature, observation availability or qualification shadow alone cannot create identity, request eligibility, price, settlement, production accrual, earning, withdrawal or payment.

## Required verification commands after implementation

```bash
cd phase4-coordinator && go test ./internal/computeintegrity -race -count=1
cd phase4-coordinator && go test ./internal/billing -race -count=1
cd phase4-coordinator && go test ./internal/stats/billingmirror -race -count=1
cd phase4-coordinator && go test ./internal/rewards -race -count=1
cd phase4-coordinator && go test ./internal/ws -race -count=1
cd phase4-coordinator && go test ./...
cd phase4-coordinator && go vet ./...
cd phase3-binary && swift test
cd phase3-binary && swift test --filter ComputeObservationMeasurement
cd frontdoor/provider-portal && node --test mining-health.test.mjs
make test-integration
make test-dist
python3 scripts/validate_spec_index.py
```

The final implementation diff also requires independent GPT-5.6 Sol code, security, and architecture audits with zero Critical, High, and Medium findings. Docker-dependent, actual-MLX, Xcode, browser, physical, deployed and production evidence are reported independently and never substituted.
