# Product Build 3 — Independent Adversarial Plan Review, Revision 3

Review status: **FAIL — revision required before Gate A0 work**  
Reviewer: native Codex subagent, `gpt-5.6-sol`, high reasoning  
Repository/base: `Augustas11/macprovider@1d2c930bad81704dd0acc0322226725d8b64aceb`  
Reviewed plan commit: `711ced3e88742146c6b8a6cd19238e639a7df42f`  
Plan: `docs/product-roadmap/build-3/prd-implementation-plan-v3.md`  
Plan SHA-256: `3cde3d3c1396bb552a69cfcb5ea5daeb910445b5814880421322d3bf6a681efc`  
Test specification: `docs/product-roadmap/build-3/test-spec-v3.md`  
Test-spec SHA-256: `d6b8ecb7b5af6e5b00c32668a15c9da20e44ab3e30a6cee8a6d7ef2019ffeaaf`  
Disposition record SHA-256: `43c9a1144eddad2e8b606a872b7dacef9345a153e87cce1b5e42f55e20b4c9bf`  
Source failed review SHA-256: `a87f6a418c7e9009160abf80f1ba62d2a4ee5a942a92e6a853d193c21bb60a22`

## Verdict

Revision 3 removes the digest cycle, separates the pre-implementation and post-build qualification artifacts, adds a concrete WS/session tuple, changes the rollback detector to PREPARE-before-SQLite, sets measurable capacity targets, defines MLX quiescence states, and names SPEC-022 and SPEC-036 separately. Those are substantive corrections.

The gate still cannot pass. Quantitative feasibility vectors may be inspected before the calibration protocol is frozen, so Gate A0 does not prove a pre-data threshold. The proposed false-quarantine result has no independent decision unit or minimum detection-power gate. The route token serializes an undefined monotonic deadline and has no crash recovery between durable capture and its in-memory post-commit claim. The external journal detects one rollback class but supplies no safe recovery or failover authority after an ambiguous prepare or loss of the local journal. The exact journal benchmark is required before the schema and mutation inventory that define its workload are authorized. The reward contract collapses multi-scope ledger dispositions and can label qualification-only shadow activity as current earning. The scheduler also omits an existing independent MLX background-work owner from its aggregate exclusion proof.

Finding counts: **0 Critical, 7 High, 1 Medium, 0 Low**.

## Findings

### H1 — Quantitative feasibility evidence is visible before the numeric protocol is frozen

**Severity:** High

**Evidence:** The plan says Gate A0 approves the profile and calibration protocol before reference or calibration measurement (`prd-implementation-plan-v3.md:10,33-35,121-132`). However, B3-F003 explicitly repeats warm/cold executions and serializes probability vectors before Gate A0 (`test-spec-v3.md:30`). Those are the same quantitative post-sampler observations from which variance, tail feasibility, hardware boundaries, and plausible thresholds can be inferred. The only control is the unenforceable statement that no threshold/class conclusion is inferred. B3-F008 proves only that named reference/cohort acquisitions postdate approval (`test-spec-v3.md:35`); it does not blind protocol authors from the F003 vectors.

**Consequence:** Maintainers can inspect the candidate's numeric variance and tail behavior, then choose the hardware predicate, safety ceiling, statistic, bootstrap rule, or sampling matrix that makes that observed behavior pass. The artifact timestamps remain formally ordered while the calibration is still post hoc. This does not close prior H2.

**Required correction:** Put the immutable profile and complete numeric calibration protocol through Gate A0 before any real probability vector or repeated numeric output is disclosed to protocol authors. Pre-Gate-A0 feasibility must be limited to API/stage availability, shape/type/resource facts, and output-parity evidence that does not reveal governed values, or use a separately controlled blind-custody process whose operators cannot author/review the protocol. Add a test/history proof that every governed numeric acquisition, including feasibility repeats, occurred after the approved protocol digest.

### H2 — The calibration rule does not define independent decisions or minimum detection power

**Severity:** High

**Evidence:** The plan proposes three hosts, repeated warm/cold prompt runs and positions, then applies a one-sided Clopper-Pearson bound to at least 600 “decisions” (`prd-implementation-plan-v3.md:123-130`). Neither the plan nor B3-CAL001–CAL003 defines whether a decision is a position, prompt, process launch, host/reference comparison, or final observation window (`test-spec-v3.md:51-53`). Positions and warm repetitions within one process and host are correlated, while Clopper-Pearson's binomial interpretation requires a justified Bernoulli trial unit. The plan also gates only known-good false quarantine. It has no predeclared positive controls, minimum detectable divergence, power/recall target, or rejection rule showing that the selected threshold detects a meaningful changed runtime/model/profile rather than accepting every input. Cohort hosts may also overlap the two reference hosts or the provider under test; only reference-host/provider-under-test overlap is forbidden (`prd-implementation-plan-v3.md:124,138`).

**Consequence:** A statistically invalid 600-count inflation can make the stated 1% confidence claim appear satisfied, and a threshold with poor or zero useful sensitivity can still create `verified` observation states. Self-comparison or cohort/reference reuse can further bias results toward success. The resulting status is not independently justified even as a narrow observation.

**Required correction:** Before Gate A0, define the observation-level Bernoulli decision, dependence/cluster treatment, host-level acceptance, and confidence calculation; prohibit calibration-provider/reference/cohort overlap unless a predeclared analysis accounts for it; and add blinded positive controls with a minimum effect size, detection-rate/power floor, and failure outcome. CAL tests must prove both the false-quarantine bound and useful discrimination on independent held-out hosts/runs without counting correlated positions as independent decisions.

### H3 — The route-token time and crash model is not implementable as written

**Severity:** High

**Evidence:** The route token is serialized and MACed/signed with “issued/expiry monotonic deadlines,” persisted in SQLite, and validated after all WS locks have been released (`prd-implementation-plan-v3.md:146-155`). A process monotonic clock has no portable serialized epoch and does not survive coordinator restart. The plan names a session UUID but no coordinator boot/authority epoch, wall-clock bounds, MAC-key generation, or restart rejection rule. It also has no recovery transition for a crash after the route/capture event commits but before the in-memory `minted -> dispatch_claimed` transition. B3-O008 tests journal crashes, while O011–O013 test live races; none tests coordinator restart at mint, durable commit, claim, and send boundaries (`test-spec-v3.md:79,82-84`). This crosses a real current boundary: the route writer stores `ProviderGenerationID: nil` (`phase4-coordinator/internal/buyer/route_snapshot.go:131-138`), while generation/admission state is in the WS/pool path and compared around an out-of-lock SQLite insert (`phase4-coordinator/internal/ws/model_admission_operator.go:938-993`).

**Consequence:** Different implementations can treat a restarted token as unexpired, expired, or unverifiable. A durable capture can remain without a durable terminal claim/orphan state, and late results or mirror projections cannot determine whether dispatch was authorized. This undermines the claimed request-start linearization and deterministic recovery.

**Required correction:** Define a token clock/epoch contract that can be encoded and checked: for example, a random coordinator boot epoch plus live monotonic ticks for in-process claim, bounded signed UTC times for durable audit, and unconditional rejection after boot/key epoch change. Define whether claim success is durably journaled before send or which later durable event proves it, and specify startup reconciliation of every committed-but-unclaimed capture to a terminal nonrewardable state. Add process-kill/restart tests at every mint/PREPARE/SQLite/COMMIT/claim/send boundary, including MAC-key rotation and wall-clock movement.

### H4 — Ambiguous PREPARE and journal loss have no safe service-restoration protocol

**Severity:** High

**Evidence:** The journal correctly makes SQLite-commit/crash/restore-to-predecessor detectable, but an unmatched PREPARE after a crash is intentionally left ambiguous and delegated to an “audited operator reconciliation or new incarnation” (`prd-implementation-plan-v3.md:161-173`). Neither operation has an algorithm, admissible evidence, authorization/quorum, treatment of outstanding buyer reservations/credits, target-mirror reconciliation, or rule preventing a possibly committed event from being applied twice. The journal is local, outside SQLite and backup bundles, and the plan defines no replication, independent durable copy, recovery-point objective, or response to loss of the APFS host/volume. B3-M010–M020 prove detection and unavailability but never prove safe return to service (`test-spec-v3.md:122-132`).

**Consequence:** A routine crash after PREPARE can require indefinite manual outage, and loss of the local journal can make every SQLite/mirror lineage permanently unauthoritative. An improvised new incarnation can omit or duplicate a receipt, reversal, exclusion, or credit. The design detects ambiguity but does not satisfy failure recovery for a production money path.

**Required correction:** Specify and gate the complete recovery state machine. It must define evidence and dual-control needed to resolve or supersede an ambiguous prepare, how unresolved requests/reservations/credits are conservatively finalized, how a new incarnation binds the prior SQLite/journal/Postgres heads, how duplicate economic application is impossible, and how journal authority survives host/volume loss through an approved independent durable copy or an explicitly accepted qualification blocker. Add destructive crash/restore/failover tests that end in a proved safe service state, not merely `unavailable`.

### H5 — Gate B requires an “exact” journal benchmark before its exact workload contract exists

**Severity:** High

**Evidence:** Before Gate B, the plan requires a production-shaped prototype of the exact fsync/SQLite/COMMIT protocol at 10k/1M/10M events using representative mutation payloads (`prd-implementation-plan-v3.md:175-186`; `test-spec-v3.md:138-143`). But Gate B precedes Slice 1, where governance, schemas, and closed fixtures are created, and it precedes Slice 2's journal implementation (`prd-implementation-plan-v3.md:99-112,263-270`). The current revision does not contain `billing_projection_event.v1` or journal schemas, a complete enumerated mutation inventory, an APFS device/filesystem/durability profile, a provisioned-volume size, or the synthetic mix needed when counters are unavailable. Yet H001/H005 require exact payload distributions and percentage comparisons.

**Consequence:** The team cannot reproduce the mandatory benchmark or prove it represents the eventual schema. A small prototype payload can pass and then expand after Gate B, or authoring the real schema/journal before Gate B violates the plan's implementation gate. The 2 GiB/day and one-year/20% gates also have no denominator until a supported volume is named.

**Required correction:** Move the closed event/journal schemas, exhaustive mutation inventory, exact durability settings, storage hardware/filesystem profile, provisioned capacity, baseline method, and deterministic representative mix into a bounded pre-Gate-B prototype artifact explicitly authorized by the plan. Gate B must bind their digests. H001–H005 must rerun or reopen the architecture gate if any implemented payload, mutation path, durability mode, or supported storage profile differs.

### H6 — The reward input contract can lose authoritative multi-scope dispositions

**Severity:** High

**Evidence:** The proposed input prose reduces withdrawal disposition to one value `active|excluded|burned|retired|unknown` plus a generic releasable hold (`prd-implementation-plan-v3.md:198-206`), and its table decides from that single value (`:237-246`). The existing canonical SPEC-021 predicate applies simultaneous `hold|exclude|burn|retire` facts at ledger-row, useful-work source, provider, wallet, cohort, duplicate-class, and epoch scopes (`specs/SPEC-021-malibu-emission-ledger.md:250-278`). Current integration coverage enumerates those seven scopes (`phase4-coordinator/internal/rewards/emission_integration_test.go:215-224`). The new plan omits disposition scope/membership, concurrent dispositions, terminal-versus-releasable status, `cap_replay_pending`, wallet-day cap state, and the relationship between the effective balance and each blocked row. No actual machine-readable `provider_reward_status_inputs.v2` schema exists at the reviewed commit, although the disposition claims one was added. B3-R015 cannot exhaust states that are absent from the input model (`test-spec-v3.md:165`).

**Consequence:** An excluded cohort or duplicate class, a terminal disposition concurrent with a releasable hold, or pending wallet-cap replay can be collapsed into an optimistic single input and presented as withdrawable. Go, Swift, and portal can all agree on the same unsafe vector while diverging from the authoritative ledger and future withdrawal selector.

**Required correction:** Commit the actual normative input/output schemas before implementation review. Either consume a reward-owner effective withdrawal projection that is proved byte-for-byte equivalent to the canonical multi-scope query or represent every scoped active/terminal disposition and cap-replay fact with closed multiplicity and ordering. Add exhaustive SQL-to-vector-to-Go/Swift/portal tests for all seven scopes, simultaneous facts, releases, terminal facts, cap replay, and amount aggregation; a canonical blocked row must never map to `withdrawable`.

### H7 — Shadow-only qualification activity can be presented as real earning

**Severity:** High

**Evidence:** Build 3 explicitly keeps the sink local/qualification-only and absent from production artifacts (`prd-implementation-plan-v3.md:253-255`). Nevertheless, the mapping labels any eligible recent request as `earning` (`:224-236`), and the product journey sends the shadow result to app and portal presentation (`:70-77`). B3-R003 proves only an isolated shadow row while production ledger/emission/payment remain unchanged, yet B3-R017 and B3-A005 ask clients to render the common mapping (`test-spec-v3.md:153,167,207`). There is no `reward_capability`, `projection_environment`, production-ledger accrual identifier, or `shadow_only` output state that prevents a qualification result from reaching provider-visible “earning” copy. B3-R014 checks that production gates are off but not that UI earning remains unavailable when only shadow evidence exists (`:164`).

**Consequence:** A provider can be told it is earning MALIBU even though no production reward ledger row exists and economic activation is explicitly prohibited. This violates the requested separation of earning, withdrawal, and payment states and turns a test signal into an economic product claim.

**Required correction:** Make shadow decisions operator/test evidence only and structurally impossible to consume through provider APIs or clients. Provider-visible `earning` must require an authoritative production-ledger accrual fact and an enabled, separately authorized reward capability; with Build 3's activation boundary it must remain unavailable or use explicit non-economic qualification copy. Add negative API/Xcode/browser tests proving shadow rows never select provider `earning`, change balances, or appear in reward activity.

### M1 — The aggregate MLX scheduler omits existing independent background work

**Severity:** Medium

**Evidence:** The scheduler contract coordinates buyer inference, compute probes, and losslessness probes (`prd-implementation-plan-v3.md:188-194`; B3-P006–P015). The current Swift runtime also launches `IdlePrewarmer` work directly against `ModelRuntime`; it independently checks `requestsInFlight`, starts a task, and cooperatively cancels it on a real request (`phase3-binary/Sources/macprovider-cli/IdlePrewarmer.swift:209-299,328-339`). The plan does not place idle prewarm, model preparation/warm swap, or other MLX maintenance work under the same lease/quiescence owner, and the tests do not race those sources with a probe and buyer work.

**Consequence:** A conforming implementation can prove probe quiescence while an existing prewarm or model-transition task still issues MLX/Metal work. Buyer latency/resource isolation and the “one aggregate active probe/no overlap” claim then depend on unreviewed parallel actors.

**Required correction:** Inventory every Swift owner that can load a model or submit MLX/Metal work and route it through the shared resource arbiter or define an explicit mutual-exclusion handoff. Extend stage/cancellation tests to idle prewarm, model load/swap, shutdown, and any enabled autotune/maintenance paths, including three-way races with buyer arrival.

## Prior-finding disposition assessment

| Revision-2 finding | Revision-3 assessment |
| --- | --- |
| H1 cyclic artifact chain | **Resolved at plan level.** The profile/protocol/results/bundle/release/qualification direction is acyclic, subject to binding the still-undefined policy/revocation artifacts in the eventual schemas. |
| H2 post-hoc calibration | **Not resolved.** Named calibration collection follows Gate A0, but pre-Gate-A0 F003 reveals governed numeric vectors; the decision unit and discrimination requirement are also missing. |
| H3 WS/session linearization | **Partially resolved.** The tuple and post-commit claim are concrete, but token time serialization and restart/orphan recovery are undefined. |
| H4 restore rollback window | **Partially resolved.** PREPARE detects the identified suffix rollback; ambiguity and loss of the sole local journal have no safe recovery protocol. |
| H5 hot-path feasibility | **Partially resolved.** Numeric budgets exist, but the exact schema/workload/profile they benchmark is gated until afterward. |
| M1 MLX quiescence | **Partially resolved.** Probe stage quiescence is specified; the arbiter does not cover all existing MLX work owners. |
| M2 total reward mapping | **Not resolved.** A table exists, but it omits canonical multi-scope economic facts and permits shadow-only work to become provider-visible earning. |
| M3 SPEC-022/SPEC-036 separation | **Resolved at mode-contract level.** The two modes and non-authority rule are explicit; H7 separately addresses the misleading shadow-to-UI mapping. |

No prior finding was downgraded or waived.

## Fresh verification

Artifact digests, repository identity, and supplied failed-review digest matched exactly. `git diff --stat 1d2c930b..711ced3e` showed documentation-only changes.

```text
sha256sum prd-implementation-plan-v3.md test-spec-v3.md plan-v2-findings-disposition-r3.md plan-v2-sol.md
  PASS: 3cde3d3c...; d6b8ecb7...; 43c9a114...; a87f6a41...

git rev-parse HEAD
  PASS before this review commit: 711ced3e88742146c6b8a6cd19238e639a7df42f

cd phase4-coordinator && go test ./internal/computeintegrity ./internal/stats/billingmirror ./internal/rewards ./internal/billing ./internal/buyer -count=1
  PASS: 5 packages, zero reported failures
```

The Go tests verify the unchanged conservative baseline. They do not prove the proposed schemas, route-token protocol, journal recovery, benchmark budgets, actual MLX behavior, calibration, client presentation, physical acceptance, or production qualification.

## Gate decision

`build3-plan-v3` / `build3-test-v3` is **not approved**, including for Gate A0 numeric feasibility/evidence work. Revise and commit the plan/test artifacts to close every finding, then rerun a fresh independent GPT-5.6 Sol high-reasoning review. Runtime implementation, calibration/reference acquisition, economic activation, enforcement, payment execution, deployment, and positive availability remain prohibited.
