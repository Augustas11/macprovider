# Product Build 3 — Independent Adversarial Plan Review, Revision 4

Review status: **FAIL — revision required before Gate A0 work**  
Reviewer: native Codex subagent, `gpt-5.6-sol`, high reasoning  
Repository/base inspected: `Augustas11/macprovider@1d2c930bad81704dd0acc0322226725d8b64aceb`  
Reviewed plan commit: `883a26d79ab2fbd01a225b8a23fa43050882742b`  
Plan: `docs/product-roadmap/build-3/prd-implementation-plan-v4.md`  
Plan SHA-256: `681d05f0d3d51a58d7fc69de540f6cf6d4a0f9d9e380869c2a2e460dea0c6fdb`  
Test specification: `docs/product-roadmap/build-3/test-spec-v4.md`  
Test-spec SHA-256: `09e30e91cef81cf955c808c2706bf53c6ac1803781707aa6d87ae349b32b0c7b`  
Disposition record SHA-256: `37000e260c206c11e512e2c8a240b951ce2d6c6a056147cb3595fc139cafc4ab`  
Source failed review SHA-256: `4c3d5a70345413bc90ae09907fe78806370cd44440d9c147d7e4a8637088db41`

## Verdict

Revision 4 makes substantial corrections. It prevents protocol authors from seeing governed probability values before Gate A0, counts physical hosts rather than correlated positions as calibration decisions, precommits held-out false-positive and meaningful-effect power gates, defines same-boot route tokens and crash terminalization, adds an independent zero-RPO lineage witness, moves closed schemas and workloads before their benchmark, preserves all seven reward-disposition scopes, structurally excludes qualification shadow evidence from provider products, and names the previously omitted Swift runtime owners.

The plan still cannot pass. Its profile freezes the current CLI build even though that build has no full-distribution sampler hook and the hook is scheduled only after the calibration-dependent Gate B. The reward projection lacks an atomic source-revision protocol while current code performs separate reads across mutable ledger, cap, wallet, and activity state. A binary rollback after lineage activation can let an old writer bypass the journal. Daily reference successors have no defined relationship to the immutable evidence and qualification chain. The Gate-B0 package is described as docs/fixtures-only while also requiring an executable exact-protocol benchmark. `ProviderPreWarmer` is classified as an in-process arbiter owner although it launches a separate provider process. Finally, the no-deletion journal has only a one-year capacity gate and no bounded qualification lifetime or chain-preserving continuation rule.

Finding counts: **0 Critical, 4 High, 3 Medium, 0 Low**.

## Findings

### H1 — Calibration is ordered before the executable that must collect it, and the frozen CLI identity cannot survive implementation

**Severity:** High

**Evidence:** The candidate table freezes CLI build `1.8.123` at base commit `1d2c930b`, and the profile freezes every candidate value above it (`prd-implementation-plan-v4.md:14-27,33`). Numeric reference/development/held-out acquisition and calibration precede Gate B (`:102-113`), while the shared-arbiter/Swift profile hook is Slice 3 after Gate B (`:224-229`). At the inspected base, `LosslessnessProbeRuntime.providerInconclusiveForUnavailableSampler` explicitly reports that the full-distribution MLX sampler hook is unavailable (`phase3-binary/Sources/macprovider-cli/LosslessnessProbeProtocol.swift:255-270`). The only staged-forward spike is acknowledged as staged Llama forward/argmax rather than post-sampler distribution access (`prd-implementation-plan-v4.md:56`). B3-F001/F009 require the missing hook before Gate A0 and before Gate B, but the plan neither authorizes nor binds a qualification-only collection executable between those gates (`test-spec-v4.md:28-36`).

**Consequence:** The team cannot collect the required 80-host numeric calibration under the frozen profile without changing code that the plan says is implemented later. If it adds the hook after Gate A0, the executable no longer matches the frozen CLI build. If it calibrates a separate spike, Gate C has no proof that the production hook is the same measurement kernel. Either path allows unreviewed implementation drift between calibration and product qualification or forces the full hardware campaign to be discarded.

**Required correction:** Define and authorize a bounded qualification-harness slice before Gate A0. Bind its source, executable, code-signing identity, dependency lock, sampler-stage implementation, processor order, serialization kernel, and hardware/runtime tuple in the profile. Do not freeze a base CLI build that cannot perform the acquisition. Specify the exact equivalence relation between that harness and the later production release (preferably the same signed measurement module bytes); any measurement-semantic or dependency change must require a new profile, Gate A0, and full calibration. Add history and binary-equivalence tests that prove every governed result came from the approved collector and that Gate C cannot inherit calibration from a different collector.

### H2 — The seven-scope reward projection has no atomic source revision or concurrent-read contract

**Severity:** High

**Evidence:** The plan requires a byte-equivalent effective projection with seven-scope dispositions, cap facts, aggregates, source head, completeness, and freshness (`prd-implementation-plan-v4.md:204-212`), but it never defines how those facts are read at one Postgres snapshot or how a source head binds that snapshot. The current implementation reads balance, trust, wallet, payout wallet, and recent work in separate calls (`phase4-coordinator/internal/rewards/projection.go:55-118`); wallet status subsequently reads wallet-day usage and audit activity in more calls (`phase4-coordinator/internal/rewards/wallet_status.go:167-206`). Concurrent writers insert ledger rows and update provider/wallet cap state in one transaction (`phase4-coordinator/internal/rewards/emission.go:168-215`), clear held rows and `cap_replay_pending` during replay (`:335-406`), and update wallet projection/replay state (`phase4-coordinator/internal/rewards/wallet_mirror.go:65-114`). B3-R002–R006 test static equivalence and replay results but do not race the projection read across the writer transaction or define which source revision `generated_at`, activity pagination, and aggregates share (`test-spec-v4.md:143-147`).

**Consequence:** A conforming implementation can read ledger totals before a cap replay and cap/activity facts after it, or the reverse, while still stamping the result fresh. SQL, Go, Swift, and portal can agree on a generated vector that never existed at an authoritative database revision. This can temporarily overstate withdrawable value or lose a hold/activity fact despite the seven-scope schema being complete.

**Required correction:** Define one reward-owner snapshot protocol. All balance, disposition, membership, provider/wallet cap, wallet binding, production-accrual, completeness, and first-page activity facts must be read in one explicitly isolated Postgres transaction or from one transactionally materialized projection. Bind the response to an authoritative monotonic source revision/LSN and transaction time; pagination cursors must bind the same revision or explicitly expose a new snapshot. Allocate `generated_at` only after the coherent read succeeds. Inventory every reward writer and add concurrency/serialization tests at ledger insert, disposition add/release, wallet rotation, cap-replay start/row-clear/end, activity append, and source-mirror advancement; no interleaving may yield an optimistic or nonexistent state.

### H3 — The rollback contract permits pre-journal binaries to break lineage after activation

**Severity:** High

**Evidence:** The plan says all migrations are additive and that rollback disables probes, consumers, and v2 UI while preserving immutable evidence (`prd-implementation-plan-v4.md:218-220`). Once Slice 2 activates the mandatory local+witness PREPARE/SQLite/COMMIT protocol, however, an older coordinator binary still knows the existing SQLite tables and mutation paths but not the new journal (`:165-182,224-230`). No schema-level writer epoch, startup compatibility check, database write fence, or forward-only rollback rule prevents that binary from starting and modifying source rows without an event or witness record. B3-M004/M013 test restore and recovery races, while B3-H007 invalidates benchmark evidence after implementation drift, but neither rejects an old writer before its first mutation (`test-spec-v4.md:110,119,133`).

**Consequence:** An ordinary operational rollback can create an unjournaled receipt, credit, refund, or finality change and permanently invalidate the source/mirror completeness chain. Disabling the new consumers afterward does not restore the missing lineage, and a later re-upgrade cannot distinguish the unjournaled write from rollback or tampering.

**Required correction:** Make post-activation writers version-fenced. Define a durable lineage-activation epoch and minimum writer protocol in SQLite plus startup checks that older binaries cannot satisfy, or explicitly prohibit binary rollback and ship a forward recovery build that retains all writers while disabling only readers/probes/UI. The fence must be acquired before any money mutation and remain effective across restore/new incarnation. Add downgrade/startup tests for every supported previous release and direct legacy mutation entry point, proving rejection before mutation and a safe forward recovery path.

### H4 — Reference refresh is not bound to calibration and qualification validity

**Severity:** High

**Evidence:** Reference events refresh every 24 hours, calibration results expire after 30 days, and the protocol expires after 90 days (`prd-implementation-plan-v4.md:139`). The immutable evidence bundle binds specific reference/golden/calibration results and Gate C binds that bundle (`:31-47`), while reference admission permits refreshed successor events with predecessor digests (`:143-147`). The plan does not say whether a new 24-hour reference event is covered by the existing bundle/qualification, requires a new bundle/Gate B/Gate C, or invalidates the current positive key until requalification. B3-REF001/REF002 combine admission and refresh, but no test covers a valid changed successor, a predecessor fork/gap, a late old event, or calibration compatibility across a refresh (`test-spec-v4.md:48-51`).

**Consequence:** One implementation can keep a positive qualification while evaluating against unreviewed successor reference data; another must rerun the entire evidence and release gate every day. A forked, delayed, or numerically shifted but structurally valid successor can therefore either bypass the calibrated authority or cause an undefined availability transition.

**Required correction:** Define a reference-series contract. State exactly what the qualification binds (source key/series root, event digest, or approved successor policy), the allowed numeric relationship between a successor and the calibrated reference, who evaluates it, and when a refresh advances, suspends, or invalidates qualification. If successors may inherit calibration, precommit the bound acceptance rule and prove it in held-out/power analysis; otherwise make daily requalification explicit. Add chain-fork/gap/replay, one-source advance, two-source skew/disagreement, calibration-expiry, and in-flight observation tests with deterministic positive-to-nonpositive transitions.

### M1 — The Gate-B0 package is simultaneously docs-only and executable

**Severity:** Medium

**Evidence:** The plan authorizes a “docs/fixture-only prototype package” before Gate B but requires that package to bind an exact benchmark binary/source digest, after which the benchmark executes the real two-fsync/two-witness-ack/SQLite protocol (`prd-implementation-plan-v4.md:184-194`). Product Slices 1–7 remain blocked until Gate B (`:10,224-233`). The artifact paths, permitted source ownership, dependency boundary, and proof that the benchmark cannot enter a production runtime are absent.

**Consequence:** Reviewers cannot tell whether executable prototype code is authorized before the implementation gate or whether a docs-only package can ever satisfy B3-H002–H006. A throwaway simulator can pass without exercising the eventual protocol, while a production-shaped prototype violates the stated gate boundary.

**Required correction:** Name a bounded, non-production benchmark-harness slice and its exact repository paths, owners, interfaces, build inputs, and non-deployability controls, or move the executable protocol implementation into an explicitly reviewed feasibility slice. Require the production implementation either to reuse the same protocol module bytes or reopen Gate B0/B. Add packaging/dependency/config tests proving the harness cannot be invoked, shipped, or enabled by coordinator/provider production artifacts.

### M2 — `ProviderPreWarmer` is an out-of-process owner, not an in-process arbiter client

**Severity:** Medium

**Evidence:** The plan lists `ProviderPreWarmer` startup probing among actions owned by the in-process shared MLX arbiter, while separately assigning isolated autotune candidates a mutually exclusive process lifecycle lease (`prd-implementation-plan-v4.md:198-202`). Current `ProviderPreWarmer.prewarmAndProbe` calls `CandidateProviderRunner.start` and waits for that child provider process to become ready (`phase3-binary/Sources/macprovider-cli/ProviderPreWarmer.swift:92-133`); its Stage 1 conformance explicitly requires that concrete runner (`phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift:91-119`). B3-P004 expects buyer work to race and cancel/quiesce provider startup prewarm through the background-work contract, whereas B3-P008 expects isolated autotune to be excluded by the process lease (`test-spec-v4.md:93,97`).

**Consequence:** The implementation can put an API call around the parent process without controlling Metal work in the child, or write mutually contradictory tests where serving and startup candidate processes both exist even though the lifecycle lease should prevent coexistence. The all-owner quiescence claim remains incomplete across the process boundary.

**Required correction:** Classify `ProviderPreWarmer` and every `CandidateProviderRunner` path under the process lifecycle lease, including child birth, readiness, termination, kill timeout, PID reuse, and orphan recovery. Limit the in-process arbiter to work submitted by the serving process's `ModelRuntime`. Rewrite P004/P008 so an incumbent serving lease either blocks the candidate before process start or is explicitly drained/released; add orphan-child and concurrent-start tests proving no second MLX process survives the lease boundary.

### M3 — The append-only lineage has no sustainable lifetime contract

**Severity:** Medium

**Evidence:** The plan forbids compaction/deletion and requires only that one year of retained local and witness data consume less than 20% of each volume (`prd-implementation-plan-v4.md:194-196`). Qualification has no maximum lifetime tied to that capacity calculation, no mandatory capacity requalification point, and no authorized chain-preserving archive, segment rollover, or volume replacement protocol. B3-H005/H006 test reserve and one-year growth only; H008 rejects every compaction/deletion attempt (`test-spec-v4.md:131-134`).

**Consequence:** A qualified deployment can remain enabled after the measured horizon while the append-only authorities grow toward exhaustion. The eventual choice is an unreviewed archive/rotation, emergency deletion, or a money-path outage; none is covered by the claimed rollback/recovery model.

**Required correction:** Either cap qualification lifetime within the proven storage horizon and require renewal before the reserve threshold can be crossed, or define a digest-preserving segment/archive and local/witness volume-replacement protocol with independently durable verification. Add time/growth projection alarms, fail-closed renewal, volume migration, archive restore, and near-capacity crash tests. Do not authorize deletion merely to satisfy the correction.

## Prior-finding disposition assessment

| Revision-3 finding | Revision-4 assessment |
| --- | --- |
| H1 pre-Gate numeric disclosure | **Resolved at plan level.** Structural feasibility exposes only stage/shape/type/allocation/parity facts, prohibits governed value sinks, and invalidates the gate on leakage. H1 above is a distinct executable-identity/order problem. |
| H2 invalid decision unit and no power gate | **Resolved at plan level.** Physical host campaigns are the decision units; held-out false-positive and paired meaningful-effect detection gates use host-level counts and precommitted custody. |
| H3 route-token restart/orphan model | **Resolved at plan level.** Boot/key epochs, live monotonic deadlines, durable attempt authorization, restart terminalization, and late-result rejection are specified and tested at each boundary. |
| H4 ambiguous PREPARE and journal loss | **Resolved for the stated one-copy loss and ambiguous-PREPARE cases.** The independent zero-RPO witness, dual-control supersede rule, obligation terminalization, and new-incarnation preconditions close the prior finding. M3 separately addresses long-term capacity continuity. |
| H5 benchmark precedes schema/workload | **Substantively resolved.** Closed schemas, inventory, storage/topology, workload, and binary digest now precede measurement. M1 addresses the remaining authorization/artifact contradiction. |
| H6 multi-scope reward loss | **Structurally resolved, but not operationally complete.** The schema preserves all seven scopes, simultaneous facts, lifecycle, amounts, and cap replay. H2 addresses the missing atomic snapshot/revision protocol rather than a missing field. |
| H7 shadow can appear as earning | **Resolved at plan level.** The separate operator-only sink has no provider schema/dependency path, and provider earning requires production environment, capability, and authoritative production accrual. |
| M1 omitted MLX owners | **Partially resolved.** Idle prewarm and model transitions are now covered. The out-of-process `ProviderPreWarmer` classification remains incorrect as M2. |

No prior finding was downgraded or waived.

## Fresh verification

The supplied digests and pinned commit matched exactly. The branch diff from the inspected base contains documentation only. Fresh targeted tests passed against the unchanged conservative baseline:

```text
sha256sum prd-implementation-plan-v4.md test-spec-v4.md plan-v3-findings-disposition-r4.md plan-v3-sol.md
  PASS: 681d05f0...; 09e30e91...; 37000e26...; 4c3d5a70...

git rev-parse HEAD
  PASS before this review commit: 883a26d79ab2fbd01a225b8a23fa43050882742b

cd phase4-coordinator && go test ./internal/computeintegrity ./internal/stats/billingmirror ./internal/rewards ./internal/billing ./internal/buyer -count=1
  PASS: 5 packages, zero reported failures
```

Those tests establish only that the documentation branch did not regress the current conservative code. They do not prove the proposed hook, calibration, reference succession, atomic reward projection, route lifecycle, journal/witness protocol, rollback fence, benchmark budgets, MLX arbitration, clients, physical first-job journey, or production qualification.

## Gate decision

**FAIL.** Gate A0 work, governed numeric acquisition, preimplementation benchmark execution, Slices 1–7, positive qualification, economic activation, enforcement, and deployment remain unauthorized. Revision 5 must correct every finding above and receive a fresh independent GPT-5.6 Sol review over exact committed digests with zero Critical, High, and Medium findings.
