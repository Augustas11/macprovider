# Product Build 3 — Test Specification

Test-spec revision: `build3-test-v4`
Plan pairing: `build3-plan-v4`
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

## Gate A0, Gate B0, Gate B, and Gate C acceptance

| ID | Class | Scenario | Required proof |
| --- | --- | --- | --- |
| B3-F001 | S/M | Load exact candidate and reach proposed sampler hook before Gate A0 | Emit only artifact/package identity, stage reachability, shape/dtype, synchronization/cancellation entry points and allocation bounds. Governed values are discarded/zeroized in process; no vector, scalar, extrema, aggregate, value hash or value-correlated timing is emitted. |
| B3-F002 | S/M | Compare normal generation with structurally instrumented hook using identical inputs | Generated token IDs and output bytes match. Evidence contains output parity only and cannot disclose governed values. |
| B3-F003 | U/S | Audit pre-Gate-A0 hook, logs, artifacts and process outputs | Repeated real numeric acquisition is impossible in the approved path; debug/value sinks are absent; synthetic tensors alone exercise encoding. Any leak invalidates the profile/protocol and gate. |
| B3-F004 | S | Cancel structural hook during load/stage entry/synchronization and test declared allocation bound | Resources release; no governed numeric artifact or availability state is created. Performance distributions wait until Gate A0. |
| B3-F005 | S | Unsupported API/runtime/stage | Typed blocker; no numeric evidence, downstream implementation or availability claim. |
| B3-F006 | U/S | Existing `StageForwardParityTests` passes or skips | Staged-forward evidence only; skip is not a pass and no numeric claim follows. |
| B3-F007 | U | Build antecedent profile/protocol | Reject null/TBD/wildcard, nominal `4bit`, unfrozen class/decision/partition/statistic/power/custody rule, self/forward digest, or numeric acquisition predating approval. |
| B3-F008 | G | Gate A0 reviews exact antecedents before governed values | Repository/process logs, signed custody sequence allocation, artifact timestamps and access records prove no governed numeric acquisition/disclosure preceded approval; zero C/H/M. |
| B3-F009 | M/P | Collect blinded reference/development/held-out results after Gate A0 | Every acquisition has a post-approval custody sequence and binds antecedents; labels/raw values remain unavailable to threshold authors until threshold digest freezes. |
| B3-F010 | U/G | Commit exact preimplementation contract and run Gate B0 before benchmarks | Closed schemas, mutation inventory, durability/storage/witness topology, seeded workload and benchmark binary are digest-bound; zero C/H/M. |
| B3-F011 | I/G | Run bound benchmarks/recovery matrix and construct evidence bundle | Measurements match every B0 digest; Gate B reaches zero C/H/M before Slice 1–7 work. Any workload/schema/profile drift invalidates results. |
| B3-F012 | U/G | Construct release candidate, candidate-bound prequalification and final qualification | Prequalification remains nonpositive; Gate C reaches zero C/H/M before a positive local qualification key. |
| B3-F013 | U | Change each artifact or bound profile dimension | Downstream digest changes, prior evidence cannot rebind, and production key returns unknown. |

## Independent references and calibration

These are physical qualification requirements. The current session does not satisfy them by fixtures or by a smaller cohort.

| ID | Class | Scenario | Required proof |
| --- | --- | --- | --- |
| B3-REF001 | M/P | Reference source A admission/refresh | Approved operator authority, signing key, physical host/fault domain, independent runtime-build/kernel provenance, antecedent/artifact/catalog/tokenizer equality, golden pass, times and event digest. |
| B3-REF002 | M/P | Reference source B admission/refresh | Same fields and simultaneous inequality from A on operator, physical/power/network domain and runtime-build/kernel provenance. |
| B3-REF003 | U/I | Correlate/remove any independence axis or overlap reference with calibration/provider host/fault domain | Quorum inadmissible; no positive state. |
| B3-REF004 | U/I/M | Invalid signature/antecedent, stale/revoked source, failed golden, disagreement | Rejected/reference fault without incorrectly advancing provider drift counters. |
| B3-CAL001 | U/G | Freeze protocol before numeric acquisition | Exact 20-development/60-held-out independent unit partition, unit/cluster definition, full prompt/repetition matrix, JS statistic, ceiling/formula, blind custody, false-quarantine rule, positive-control effect/power, exclusions/stopping/expiry are approved. |
| B3-CAL002 | M/P | Execute 80 disjoint host/fault-domain campaigns | Each host contributes one decision; positions/prompts/repetitions never increase `n`; partitions meet operator/runtime-provenance diversity and exclude references/provider. |
| B3-CAL003 | M/P | Freeze threshold using development/reference data, then unseal held-out labels | Threshold digest predates every held-out read. Zero of 60 good units quarantine; exact-binomial one-sided 95% upper bound <=5.0%. |
| B3-CAL004 | M/P | Execute paired blinded minimum-effect positive controls on held-out units | At least 59/60 host-level controls detected and one-sided 95% lower bound >=90%; both runtime perturbation and hook-boundary transform strata pass. Structural mismatch rejection does not count. |
| B3-CAL005 | U/I | Count positions/repetitions as trials; reuse host/fault domain; reveal label/vector early; change effect/statistic/threshold/exclusion after data | Result and bundle inadmissible; new protocol digest and Gate A0 required. |
| B3-CAL006 | U/I | Missing unit/sample, failed tail, expired result, or hardware field outside predicate | Qualification blocks or returns uncovered; no parameter widening or discretionary exclusion. |

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

## Carrier and shared MLX resource arbiter

| ID | Class | Scenario | Required result |
| --- | --- | --- | --- |
| B3-P001 | U/I | Plain SPEC-036 frame on Tier-2 or encrypted frame without exact session/domain | Rejected; replay identity enforced. |
| B3-P002 | U/I | Older provider lacks capability/returns unsupported NAK | No retry storm/disconnect; buyer serving remains available. |
| B3-P003 | U/I | Compute and losslessness due simultaneously | Compute first, one aggregate probe slot, bounded wait/fairness under buyer priority. |
| B3-P004 | U/I/P | Buyer arrival races compute probe, losslessness, idle prewarm and provider startup prewarm at every load/prefill/sampler/sync/serialization boundary | Background work cancels/quiesces; no buyer Metal buffer starts before device synchronization; no late state/economic event. |
| B3-P005 | U/I/P | Buyer/probe races control-socket beginSwap, prepared adoption, load, finalize, unload and shutdown | Exclusive transition lease drains lower-priority work, synchronizes, advances generation, then exposes new runtime. Old-runtime callbacks reject. |
| B3-P006 | U/I | Three-way buyer + probe + `IdlePrewarmer` or model transition race | Exactly one permitted device owner, deterministic priority, bounded cancellation, all leases/counters released. |
| B3-P007 | U | Add a new `ModelRuntime`/MLX/Metal call site without owner-registry classification | Static ownership test fails. |
| B3-P008 | U/I | Launch decode bench, SPEC-028 canary/benchmark or isolated autotune while provider serving lease exists | Mutually exclusive process lifecycle lease rejects coexistence; standalone path cannot bypass arbiter. |
| B3-P009 | U/I | Queue/cap/size/NaN/expiry/disconnect/profile/policy pressure | Exact limits and typed rejection; no leaked slots or persisted/economic result. |
| B3-P010 | S/M/P | In-flight work exceeds two-second quiescence budget | Provider drains from routing until proved device quiescence; buyer reroutes/fails safely; late completion fenced. |
| B3-P011 | S/M | Exact qualified real-MLX probe | Bound distribution and context within approved limits. |
| B3-P012 | I | Probe attempts paid receipt/debit/credit/reward path | Rejected; zero economic records. |

## Immutable billing journal, witness, and restoration

| ID | Class | Scenario | Required result |
| --- | --- | --- | --- |
| B3-M001 | I | Every Gate-B0 inventoried mutation | Same transaction appends complete event; unlisted production mutation fails inventory/static gate. |
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

## Pre-Gate-B schema and feasibility contract

| ID | Class | Scenario | Required result |
| --- | --- | --- | --- |
| B3-H001 | U/G | Gate B0 package inspection | Closed schemas, field bounds, exhaustive symbol/SQL mutation inventory, exact SQLite/APFS/witness/topology settings, capacity, seeded workload and benchmark digest contain no TBD/wildcards; zero C/H/M. |
| B3-H002 | I | Bound protocol at 10k/1M/10M events, concurrency 1/8/32, exact mix for ten minutes | >=100 complete mutations/s; added p50/p95/p99 <=5/15/30 ms; p99 regression <=15%; p99 lock wait <=20 ms; zero errors. |
| B3-H003 | U/I | 64 KiB event/+1, queue 1,024/+1, 50 ms lock deadline | Boundary accepted; overflow rejected before PREPARE/DB/dispatch/debit. |
| B3-H004 | I | 1M bootstrap, 10M startup/recovery verification | <=15 minutes bootstrap, <=60 seconds startup verification, <=512 MiB RSS increase; exact local/witness/DB/mirror heads. |
| B3-H005 | I | Reserve below `max(10 GiB, 7-day growth)`, ENOSPC/fsync/network-ack fault at every write | New work stops conservatively; post-DB ambiguity freezes until specified recovery. |
| B3-H006 | I | Event distribution and one-year local+witness retention | p99 <=16 KiB, growth <=2 GiB/day and each volume <=20% provisioned capacity. |
| B3-H007 | U/I | Change payload, mutation path, durability mode, hardware/filesystem, witness latency/profile or workload after B0 | Benchmark is invalid and Gate B0/B reopens. |
| B3-H008 | U/I | Attempt compaction/deletion | Rejected; lineage remains complete. |

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
cd frontdoor/provider-portal && node --test mining-health.test.mjs
make test-integration
make test-dist
python3 scripts/validate_spec_index.py
```

The final implementation diff also requires independent GPT-5.6 Sol code, security, and architecture audits with zero Critical, High, and Medium findings. Docker-dependent, actual-MLX, Xcode, browser, physical, deployed and production evidence are reported independently and never substituted.
