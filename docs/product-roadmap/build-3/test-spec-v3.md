# Product Build 3 — Test Specification

Test-spec revision: `build3-test-v3`
Plan pairing: `build3-plan-v3`
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

## Gate A0, Gate B, and Gate C acceptance

| ID | Class | Scenario | Required proof |
| --- | --- | --- | --- |
| B3-F001 | S/M | Load exact candidate revision/hash with CLI `1.8.123` and pinned MLX packages; extract proposed post-sampler distribution | Record exact artifact files, quantization descriptor/digest, tokenizer/template, tensor stage/shape/dtype, processor order, normalization, probability encoding, package/runtime/OS/hardware identity. No alternate Llama fallback is allowed. |
| B3-F002 | S/M | Compare normal generation with observation hook using identical inputs | Generated token IDs and output bytes match under declared semantics; the hook cannot alter output. |
| B3-F003 | S/M | Repeat warm/cold feasibility executions and serialize vectors before Gate A0 | Numeric and synchronization behavior are hook feasibility only; no reference/calibration data is opened and no threshold/class conclusion is inferred. |
| B3-F004 | S/M | Cancel during load, prefill, observation, and serialization; run proposed maximum bounds beside paid work | Resources release within declared limit; peak memory/time/copy cost recorded; paid work remains stable. |
| B3-F005 | S | Unsupported API/runtime/stage | Typed blocker; no downstream observation implementation or availability claim. |
| B3-F006 | U/S | Existing `StageForwardParityTests` passes or skips | Recorded only as staged-forward evidence. A pass does not satisfy F001–F004; a skip is not passing evidence. |
| B3-F007 | U | Build antecedent `compute_observation_profile.v1` and `compute_calibration_protocol.v1` | Reject null/TBD/wildcard, nominal `4bit`, unfrozen class predicate, missing numeric/statistical/stopping rule, or any self/forward digest. Stable JCS digests recorded. |
| B3-F008 | G | Gate A0 reviews exact antecedent manifests before evidence | Repository history, signed publication times, custody log, and acquisition timestamps prove no reference/cohort measurement preceded approval; zero C/H/M required. |
| B3-F009 | U | Construct references, golden validation, calibration result, and evidence bundle after Gate A0 | Every result binds only antecedent digests; bundle binds result digests; graph is acyclic and digest recomputation is exact. |
| B3-F010 | G | Gate B reviews exact bundle, capacity evidence, migration inventory, revised plan/test | No Slice 1–7 implementation begins before zero C/H/M. |
| B3-F011 | U/G | Construct release candidate, run prequalification, then construct final qualification | Candidate binds bundle/commit/package/executable/signing/schema; prequalification results bind candidate and remain nonpositive; final qualification binds candidate plus result digests; Gate C reaches zero C/H/M before positive availability. |
| B3-F012 | U | Change each artifact at each phase | Downstream digest changes, prior result cannot be rebound, and production key returns unknown; no digest fixed-point or placeholder is accepted. |

## Independent references and calibration

These are physical evidence requirements, not parser fixtures.

| ID | Class | Scenario | Required proof |
| --- | --- | --- | --- |
| B3-REF001 | M/P | Reference source A admission and refresh | Approved operator authority, signing key verification, exact physical host, power/network fault domain, independently produced runtime build/kernel provenance, exact antecedent profile/protocol/artifact/catalog/tokenizer equality, signed golden-fixture pass, produced/expiry times, and event digest. |
| B3-REF002 | M/P | Reference source B admission and refresh | Same fields as REF001 and inequality from A on operator identity, physical host plus power/network domain, and runtime-build/kernel provenance simultaneously. |
| B3-REF003 | U/I | Remove or correlate each independence axis one at a time | Reference quorum becomes inadmissible; no positive state. Golden-fixture success cannot compensate. |
| B3-REF004 | U/I/M | Invalid key/signature, wrong antecedent field, stale/revoked source, golden fixture missing/failing, source disagreement | Rejected or reference-fault state; provider drift counters are not incorrectly advanced. |
| B3-CAL001 | U/G | Freeze protocol before evidence | Exact 3-host cohort, class predicate, 8 prompts, 32 positions, K=32, 3 cold/10 warm repetitions, seed/encoding, 99%/98% tail gates, fixed threshold formula/ceiling, 600-decision false-quarantine test, 1% one-sided 95% bound, exclusions, stopping and expiry are Gate-A0 approved. |
| B3-CAL002 | M/P | Execute predeclared matrix without early stopping | Per host record exactly 24 cold and 80 warm prompt executions and 768/2,560 measured positions; missing/retry/exclusion facts remain in signed custody evidence. |
| B3-CAL003 | M/P | Run fixed analysis code once | Tail gates pass, threshold uses the precommitted formula/ceiling, at least 600 decisions complete, and one-sided 95% Clopper-Pearson upper bound is <=1.0%; failure blocks rather than adjusts. |
| B3-CAL004 | U/I | Data predates approval; missing cohort/sample/position; post-hoc exclusion; altered code/seed/ceiling; failed tail/budget; expired result | Bundle is inadmissible; recollection requires a new protocol digest and Gate A0. |
| B3-CAL005 | U/I | Hardware/runtime at every class boundary and one field outside it | Only exact predicate members match; boundary ambiguity returns uncovered. |

## Closed schema and compatibility

| ID | Class | Scenario | Required result |
| --- | --- | --- | --- |
| B3-C001 | U | Valid profile/protocol/evidence/policy/reference/calibration/threshold/qualification chain | Accepted with stable canonical digests, acyclic direction, and exact cross-binding. |
| B3-C002 | U | Unknown field/enum, duplicate key, trailing JSON, invalid UTF-8/numeric, NaN/Inf, oversized field | Typed rejection before state transition. |
| B3-C003 | U | Change each load-bearing profile/evidence/qualification dimension independently | New downstream digest/key; no inherited observation window. |
| B3-C004 | U | Sanitized status | Only allowlisted state/digests/times/disclosure/action; no prompts, logits, probabilities, secrets, thresholds, buyer data, or other-provider data. |
| B3-C005 | U | Old client receives additive response | Remains conservative and functional for declared compatibility window. |
| B3-C006 | U | New client receives unknown schema/state/reason/action in one projection | Only affected projection becomes unavailable/contact-support; independent fresh projections remain intact. |

## Observation authority and request-start linearization

| ID | Class | Scenario | Required result |
| --- | --- | --- | --- |
| B3-O001 | I | Install events/materialization, restart and replay | Same revision/head/state; freshness is not extended. |
| B3-O002 | I | Same idempotency key/body and same key/different body | Exact replay is one logical event; changed body conflicts and audits. |
| B3-O003 | I | Two evaluators target same predecessor | Exactly one CAS advances; loser cannot overwrite/retry as the same event. |
| B3-O004 | I | Stale evaluator races revocation/expiry/profile rotation | Tombstone/new revision wins once committed; stale evaluator cannot resurrect. |
| B3-O005 | I | Request start commits before revocation | Route and capture atomically preserve prior revision; later revocation does not rewrite it. |
| B3-O006 | I | Revocation commits before request start | Request captures revoked/expired/unknown according to closed rule; never prior positive state. |
| B3-O007 | I | Fault before append, after append, after materialization, before commit | Rollback leaves no partial event/current/capture. |
| B3-O008 | I | PREPARE fsynced; crash before SQLite, during SQLite, after SQLite commit, or before COMMIT fsync | Matching event permits COMMIT recovery; proven live-process pre-commit failure may ABORT; crash with absent event is ambiguous/unavailable and never auto-aborted. |
| B3-O009 | I | Materialized current row changed/corrupt or event chain broken | Replay/digest check fails unavailable; no in-memory verified fallback. |
| B3-O010 | I | Request-start expiry/catalog/profile/generation check crosses exact boundary | One transaction time plus mandatory route-token tuple produces deterministic capture; nil `ProviderGenerationID` is uncovered/ineligible. |
| B3-O011 | I | Route token around disconnect and reconnect with reused numeric generation | Unique session-instance UUID and post-commit WS claim reject old token; orphan capture is journaled dispatch-blocked and nonrewardable. |
| B3-O012 | I | Both commit orders around model swap, release/catalog/rate rotation, BYOM binding movement, and observation revocation | Exact tuple claim either dispatches the bound request or blocks it; no stale send, paid receipt, settlement or shadow accrual. |
| B3-O013 | I | Lifecycle changes after claim but before/during network send; late result arrives | Session actor validates claimed token at send; failure becomes journaled failed attempt; late tuple/token result is rejected. |
| B3-O014 | I | Observation versus settlement-enforcement capture schemas | SPEC-036 observe capture and existing SPEC-036 settlement capture remain separate and cannot substitute. |

Fault injection exercises all lock orders and asserts lineage `flock` precedes `BEGIN IMMEDIATE`; reverse acquisition fails tests/static checks.

## Carrier and shared scheduler

| ID | Class | Scenario | Required result |
| --- | --- | --- | --- |
| B3-P001 | U/I | Plain SPEC-036 frame on active Tier-2 session | Rejected; no evaluation/state transition. |
| B3-P002 | U/I | Encrypted frame without matching Tier-2 session, wrong request/probe ID, wrong direction/domain nonce | Rejected and replay-marked as appropriate. |
| B3-P003 | U/I | Correct Tier-2 encrypted `inference_request` carrier and correct plaintext non-Tier-2 carrier | Accepted only for negotiated exact protocol/profile version. |
| B3-P004 | U/I | Older provider lacks capability or sends typed unsupported NAK | No scheduling/retry storm/disconnect; serving remains available. |
| B3-P005 | U/I | Cross-carrier/session/provider replay and nonce collision | Rejected by domain-separated replay identity. |
| B3-P006 | U/I | Compute and losslessness become due simultaneously | Compute runs first; one aggregate active slot; losslessness subsequently runs within declared maximum wait when buyer work permits. |
| B3-P007 | U/I | Continuous compute due plus queued losslessness | Age promotion prevents losslessness starvation while preserving buyer priority. |
| B3-P008 | U/I/P | Buyer arrives in queued, dispatching, load, prefill, sampler, device-sync, serialization, and result-send states | Queued work cancels; running work quiesces; no buyer Metal buffer starts before synchronization and buffer release; no cancelled observation/economic event. |
| B3-P009 | U/I | Per-profile, aggregate provider, and global cap pressure | Exact caps hold; bounded queue rejects excess with typed reason and releases counters. |
| B3-P010 | U/I | Disconnect, generation/profile/policy change, lease expiry, shutdown | All affected work cancels; late result rejected; slots recovered. |
| B3-P011 | U/I | Oversized prompts/positions/K/vector/bytes/duration or NaN/Inf | Rejected before persistence/evaluation. |
| B3-P012 | S/M | Exact qualified profile real MLX probe | Correctly bound distribution within approved resource limits; exact evidence context recorded. |
| B3-P013 | I | Probe attempts paid receipt/debit/credit/reward path | Rejected; zero economic records. |
| B3-P014 | S/M/P | In-flight MLX work exceeds 2-second quiescence budget | Provider enters typed draining state and leaves routing; buyer reroutes/fails safely; late completion is fenced; return requires proven device quiescence. |
| B3-P015 | U/I | Cancellation races generation/profile/policy change and shutdown | One terminal transition, all counters/leases release, and late callbacks cannot mutate observation or billing state. |

## Immutable billing journal and restore-safe mirror

| ID | Class | Scenario | Required result |
| --- | --- | --- | --- |
| B3-M001 | I | Each inventoried route/capture/receipt/verdict/finality/exclusion/quarantine/credit/reversal mutation | Same transaction appends a new complete `billing_projection_event.v1`; missing event aborts mutation. |
| B3-M002 | I | Transaction rollback | Neither source mutation nor event remains. |
| B3-M003 | I | Capture-before-credit, receipt-after-credit, finality-after-receipt, revocation-after-capture | Each event is a complete point-in-time snapshot with monotonic request revision; historical capture is stable. |
| B3-M004 | I | Multiple source mutations occur after mirror observes max but before fetch | Mirror consumes only payloads for its snapshot/range, later events remain tail; no reconstruction from current rows. |
| B3-M005 | I | Same sequence/digest replay | Idempotent. Same sequence changed body/digest or lower request revision fails unavailable. |
| B3-M006 | I | Broken previous digest, missing sequence, forked chain | Mirror rejects chain and clears completeness. |
| B3-M007 | I | Crash before/after target apply and before/after checkpoint | Retry converges to identical target projection and applied sequence/digest. |
| B3-M008 | I | Source snapshot returns max sequence/digest/time and target reaches it | `complete_through=true` only for matching incarnation and digest; claim is bounded to that source time. |
| B3-M009 | I | Event occurs after source snapshot | UI retains prior complete-through time and never claims current idleness. |
| B3-M010 | I | Restore older SQLite at every PREPARE/SQLite-COMMIT/COMMIT/target boundary | Surviving external record or target detects rollback; SQLite-commit/crash/restore-to-predecessor leaves PREPARE and stays unavailable. |
| B3-M011 | I | In-place restore, sequence reuse, unknown incarnation, and divergent fork | Detected without clocks; explicit audited new-incarnation workflow required. |
| B3-M012 | I | PREPARE fsync, directory fsync, DB/WAL fsync, COMMIT append/fsync each fail or tear | No unprepared DB event is accepted; matching prepared descendant commits once; absent/mismatch after crash is ambiguous and operator-gated. |
| B3-M013 | I | Bootstrap crash/restart at every phase 1–7 | Resume/rollback rule is deterministic; no ready state before count/identity/chain/schema digests and tail converge. |
| B3-M014 | I | Concurrent write at every bootstrap boundary | Writer is excluded or produces a tail event after journal authority; no unjournaled gap. |
| B3-M015 | I | Backfill count, ordered identity digest, or source/event projection mismatch | Bootstrap rolls back/fails unavailable. |
| B3-M016 | I | Two mirror workers | Target single-writer/advisory lock prevents split checkpoint; convergence proved. |
| B3-M017 | I | Bounded legacy sweep disagrees with journal target | Alert/unavailable; repair is audited and cannot silently change lineage. |
| B3-M018 | I | Fresh USDC source with stale/incomplete rewards mirror | Freshness remains independent through API and UI. |
| B3-M019 | I | Live transaction fails before commit with DB head unchanged | Writer appends ABORT under the same lock; restart proves it cannot hide a committed suffix. |
| B3-M020 | I | DB event without PREPARE, COMMIT ahead of DB, changed bytes, missing frame, CRC/hash/sequence/incarnation fault | Source, mirror, status and shadow projection stay unavailable; no cursor reuse. |

## Hot-path, storage, and lock feasibility

| ID | Class | Scenario | Required result |
| --- | --- | --- | --- |
| B3-H001 | I | Exact protocol at 10k/1M/10M events, concurrency 1/8/32, representative mix for 10 minutes | >=100 mutations/s; added p50/p95/p99 <=5/15/30 ms; p99 regression <=15%; p99 lock wait <=20 ms; zero errors. |
| B3-H002 | U/I | 64 KiB event, 64 KiB+1 event, 1,024 queue, queue+1, 50 ms lock wait | Boundary accepted; overflow rejected before dispatch/debit with typed busy/oversize and no partial PREPARE/DB mutation. |
| B3-H003 | I | 1M bootstrap and 10M startup verification | <=15 minutes bootstrap, <=60 seconds verification, <=512 MiB RSS increase; count/identity/schema/chain exact. |
| B3-H004 | I | Disk reserve below `max(10 GiB, 7-day growth)`, ENOSPC and fsync error at every write | New work stops conservatively; post-DB ambiguity freezes projection/dispatch until recovery. |
| B3-H005 | I | Measured event-size/rate distribution and one-year retention projection | p99 <=16 KiB, growth <=2 GiB/day and one-year <=20% provisioned volume; otherwise Gate B fails pending new archival architecture. |
| B3-H006 | U/I | Attempt compaction/deletion under Build 3 | Rejected; all event and external records remain chain-verifiable. |

## Total reward-state contract

The same checked-in vectors drive Go, Swift, and portal tests.

| ID | Class | Scenario | Required result |
| --- | --- | --- | --- |
| B3-R001 | U/property | Enumerate every closed source state/reason and unknown value | Exactly one output per projection; unknown affects only its projection and is conservative. |
| B3-R002 | U/property | All pairwise simultaneous conditions | Published precedence is identical in Go/Swift/portal; no arbitrary `primary_reason` divergence. |
| B3-R003 | U/I | Qualification build, SPEC-022 enforce, positive SPEC-036-observe capture, verified final receipt, complete mirror and all predicates | Recent request eligible and isolated shadow accrual is idempotent; production ledger/emission/payment tables remain byte-identical and production binary has no sink/flag. |
| B3-R004 | U/I | Compute unknown/stale with eligible historical balance | Earning unavailable; withdrawal remains withdrawable if canonical ledger predicate passes; payment unavailable; balance preserved. |
| B3-R005 | U/I | Current compute verified but request capture unknown/stale versus revoked/uncovered | Unknown/stale historical request is unavailable; revoked/uncovered is excluded; neither is upgraded by current state. |
| B3-R006 | U/I | Compute revoked after request capture | Immutable historical evidence remains; only explicit prospective/hold event changes economic projection. |
| B3-R007 | U/I | Active and cleared historical hold/cap combinations | Active condition maps held/capped; cleared condition appears only in activity and does not control current state. |
| B3-R008 | U/I | Stale ledger, fresh observation, fresh USDC | Withdrawal unavailable/last-known; observation and USDC remain fresh. |
| B3-R009 | U/I | Missing wallet with eligible balance | Withdrawal ineligible with `add_wallet`; earning unchanged; payment unavailable. |
| B3-R010 | U/I | Payment service absent/unhealthy under every other state | `payment_state=unavailable` with exact fixed reason; no withdraw action. |
| B3-R011 | U/I | No recent row with fresh complete mirror vs incomplete mirror | First yields eligible-idle; second yields unavailable, never confirmed idle. |
| B3-R012 | I | Invalid/missing/mismatched receipt, quarantine, reward exclusion, SPEC-022 observe, or unknown/uncovered SPEC-036 capture | No shadow accrual; exact recent-request reason and audit event. |
| B3-R013 | I | Duplicate/replayed source event and accrual | Unique external reference prevents duplicate reward or cap advancement. |
| B3-R014 | I | Production emission/payment/withdrawal gates | Remain default off; observation availability creates no economic action. |
| B3-R015 | U/property | Exhaust valid closed input partitions and every reason | Exactly one state/primary/action per projection; every true secondary is sorted by normative order then enum ordinal; no unreachable or duplicate reason. |
| B3-R016 | U/property | Unknown enum/schema in each input domain one at a time | Only the dependent projection becomes unavailable/contract-unknown; independent projections and last-known values remain stable. |
| B3-R017 | U/X/B | Replay generated canonical vectors in Go, Swift, and portal | Byte-identical corpus yields identical state, primary, secondary, action, and freshness. |
| B3-R018 | U | App attestation, hardware evidence, runtime telemetry, trust/demotion, wallet/caps/disposition, and verified-receipt inputs vary independently | Every authoritative input selects its named reason at declared precedence and never falls through optimistically. |
| B3-R019 | U/I | Mismatched wallet with eligible balance | Withdrawal ineligible with `wallet_mismatch`/`contact_support`; earning and balance remain unchanged; payment unavailable. |

## SPEC-022 settlement versus SPEC-036 observation

| ID | Class | Scenario | Required result |
| --- | --- | --- | --- |
| B3-D001 | U/I | SPEC-022 observe + positive SPEC-036-observe capture | Economically excluded; zero production or shadow accrual. |
| B3-D002 | U/I | SPEC-022 observe + SPEC-036 unknown/stale/revoked/uncovered | Economically excluded with deterministic reasons; zero accrual. |
| B3-D003 | U/I | SPEC-022 enforce + positive SPEC-036-observe capture in qualification binary | Shadow decision only when every receipt/mirror/identity predicate passes; production ledger untouched. |
| B3-D004 | U/I | SPEC-022 enforce + nonpositive/missing/mismatched SPEC-036 capture | No shadow decision; existing settlement rules continue without observation substitution. |
| B3-D005 | U | Inspect production dependency graph, binary strings/config schema, and release fixtures | Qualification sink and enabling feature flag are absent; configuration cannot activate it in production. |
| B3-D006 | U/I | Positive observation without valid price/model/identity/finality or provider signature alone | Cannot authorize settlement, shadow accrual, reward, or payment. |

## App and portal parity

| ID | Class | Scenario | Required result |
| --- | --- | --- | --- |
| B3-U001 | X/B | Fresh USDC, stale rewards | USDC fresh; rewards last-known/stale with original time; no global collapse. |
| B3-U002 | X/B | Unknown compute plus eligible balance | Independent earning/withdrawal/payment; no “earning now.” |
| B3-U003 | X/B | Withdrawable balance and payment unavailable | Exact copy: “MALIBU balance is eligible for withdrawal; payment execution is unavailable.” No withdraw CTA. |
| B3-U004 | X/B | Missing wallet | `add_wallet` action; balances/activity preserved. |
| B3-U005 | X/B | Historical cleared hold/cap and active hold/cap | Historical event is timestamped activity; only active fact controls current state. |
| B3-U006 | X/B | Fresh complete mirror has no recent work vs unavailable mirror | Truthful eligible-idle vs updates-unavailable copy. |
| B3-U007 | X/B | Stale/revoked/profile-changed observation | Narrow coverage, evidence time, reason and recovery action; no broad integrity claim. |
| B3-U008 | X/B | Activity pages, duplicate cursor, empty final page | Stable order, dedupe by audit ID, correct cursor, independent loading. |
| B3-U009 | X/B | Activity failure after summary success | Summary stays; activity last-known/unavailable with retry. |
| B3-U010 | X/B | Summary failure after success | Last-known values/time stay; no zero reset. |
| B3-U011 | X/B | Unknown v2 value in one projection | Affected card unavailable; other cards retain valid states. |
| B3-U012 | X/B | Keyboard/screen reader/narrow layout | State, time, reason, action, disclosure, and pagination remain perceivable. |

## Correlated physical first-job acceptance

| ID | Class | Scenario | Required evidence/result |
| --- | --- | --- | --- |
| B3-A001 | M/P | Exact approved qualification executes probe | Hardware/chip/RAM/GPU/OS, CLI/app/package/release, quantization, profile/protocol/evidence/qualification/reference/calibration/policy digests, lease/result/verdict IDs, timing and resources. |
| B3-A002 | P | Real nonstreaming paid job through actual MLX | Atomic request-start capture binds exact token tuple/revision/qualification/generation; receipt persists and verifies. |
| B3-A003 | P | Delay receipt beyond first mirror pass, then settle | New complete projection event updates same request revision chain; mirror completeness and source time advance correctly. |
| B3-A004 | P | Qualification-only shadow accrual consumes event twice | One isolated shadow row/audit result and stable external reference; production ledger remains unchanged and activation absent. |
| B3-A005 | X/B/P | App and portal display same correlated job | Same states/reasons/times, independent freshness, truthful payment state, paginated activity. |
| B3-A006 | P | Cancel/reconnect, revoke reference, change generation/profile, stale rewards with fresh USDC | All negative/recovery paths meet the contracts without corrupting active model or inventing idle/earning. |

Physical completion is distinct from production qualification. Q evidence additionally requires operator approval of references, calibration, rollout controls, deployed topology, and sustained monitoring. This task does not authorize Q actions.

## Security and abuse tests

- Provider/operator/status/reward/activity authorization matrix and cross-provider isolation.
- Carrier replay, nonce collision, request smuggling, duplicate-key JSON, compression/size bombs, malformed numeric values, cancellation and reconnect abuse.
- WS/lineage/SQLite lock-order and route-token race injection; stale CAS, prepared-event chain, permissions/symlink/append/fsync/restore/fork tests.
- Bounded CPU/GPU/memory/disk/queue/raw-evidence retention; buyer priority and scheduler fairness.
- Log/metric/HTTP/evidence/app/portal redaction for prompts, probability vectors, tokens, secrets, buyer identity and unbounded strings.
- Proof that provider assertion/signature alone cannot create trusted identity, reference status, positive observation, request eligibility, price, settlement, reward, or payment.

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

The final implementation diff also requires independent GPT-5.6 Sol code, security, and architecture audits with zero Critical, High, and Medium findings. Docker-dependent, actual-MLX, Xcode, browser, physical, deployed, and production evidence are reported independently and never substituted.
