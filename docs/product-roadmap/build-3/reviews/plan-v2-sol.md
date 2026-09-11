# Product Build 3 — Independent Adversarial Plan Review, Revision 2

Review status: **FAIL — revision required before Gate A work**  
Reviewer: native Codex subagent, `gpt-5.6-sol`, high reasoning  
Repository/base: `Augustas11/macprovider@1d2c930bad81704dd0acc0322226725d8b64aceb`  
Reviewed plan commit: `8cf1b41eacca0d79dea5721103a9147e175a40b7`  
Plan: `docs/product-roadmap/build-3/prd-implementation-plan-v2.md`  
Plan SHA-256: `040df8c74d1123353e57dc75772248b36966ca1c7d2f443a2deb7b22ca1485d8`  
Test specification: `docs/product-roadmap/build-3/test-spec-v2.md`  
Test-spec SHA-256: `519cecb3987de893c1da916ca0438c984b118053bd3f692554c035b2125d61a5`  
Disposition record SHA-256: `434fcd67f92849c79958a418913718b536e6f1829abe84927d3503e8814ec062`  
Source failed review SHA-256: `4c2900708c8ce7ce6a1f999ac7b3b5c6054798f1aa12b7cb92eb19d5ab2eae44`

## Verdict

Revision 2 correctly narrows the immediate authorization to feasibility/evidence work, makes Gate B unconditional, co-locates observation authority with request captures, specifies immutable event payload consumption, preserves the three SPEC-036 reference-independence axes, and separates provider reward projections. Those are material corrections.

The revision is not executable as written. Its pilot/evidence dependency graph is circular, and it requires a final release artifact identity before the production hook that would create that artifact may be implemented. The calibration criteria can still be selected after evidence is observed. Request-start SQLite serialization does not serialize the in-memory provider session/model generation that the capture claims to bind. The external anchor also cannot detect a committed suffix that is lost by a restore during its acknowledged post-commit/pre-anchor window. The reward and scheduler contracts remain incomplete enough for incompatible implementations to satisfy the named tests.

Finding counts: **0 Critical, 5 High, 3 Medium, 0 Low**.

## Findings

### H1 — The pilot, reference, calibration, and release identities form an impossible dependency cycle

**Severity:** High

**Evidence:** Gate B requires a closed `compute_observation_pilot.v1` containing the production release artifact digest and code-signing identity plus the two reference-event, golden-fixture, calibration, threshold, and policy digests (`prd-implementation-plan-v2.md:29-37`). Reference admission must bind exact pilot equality (`:130-134`; `test-spec-v2.md:B3-REF001-B3-REF002`), while calibration freezes the hardware class that is itself a load-bearing pilot field (`prd-implementation-plan-v2.md:27,33,133`; `test-spec-v2.md:B3-CAL001`). Production runtime implementation, including the exact Swift profile hook, is prohibited until Gate B (`prd-implementation-plan-v2.md:10,104-119,248-257`). Therefore a reference event cannot bind the final pilot until the pilot contains that event's digest, and the final signed production release cannot exist until implementation that Gate B refuses to authorize.

**Consequence:** No finite artifact construction order can satisfy F007/F008 and REF/CAL exact-equality acceptance. The team must either use placeholders despite the closed-manifest rule or bypass Gate B to build the release. A digest fixed point is not a valid construction or verification mechanism.

**Required correction:** Define an acyclic hierarchy. Freeze and gate a `pilot_profile` or covered-key manifest containing only antecedent runtime/profile/artifact/class/schema inputs. Reference events, golden validation, calibration, and threshold records bind that profile digest. A separately constructed activation/evidence bundle binds the profile and their resulting digests. Gate B reviews the exact profile, evidence bundle, schema, and implementation plan. Bind the eventual production release digest in a post-implementation qualification manifest and require another zero-C/H/M gate before any positive availability; do not require a nonexistent production binary at the pre-implementation gate. Specify which digest each request, result, window, capture, and UI status carries.

### H2 — Calibration evidence can be collected before its numeric acceptance rule is frozen

**Severity:** High

**Evidence:** Gate A authorizes “evidence-production” and requires independent reference and calibration evidence before Gate B (`prd-implementation-plan-v2.md:10,105-122`). The plan says the future record will contain exact sample/position counts and a predeclared false-quarantine budget, but supplies no values or independently approved pre-run protocol (`:128-134`). CAL002 says only “meet exact sample and position minima,” and CAL003 says only “evaluate predeclared false-quarantine budget” (`test-spec-v2.md:47-50`). Current SPEC-036 has concrete enforce floors—at least 30 warn-only days, 100 eligible canaries, and 10 stable provider identities—while also acknowledging those floors are not presently reachable (`SPEC-036-compute-integrity-receipt.md:2040-2063,2072-2087`). Revision 2 neither adopts those floors for this observation pilot nor defines a separate observation-only calibration rule.

**Consequence:** The team can inspect the measurements, then choose the class boundary, sample/position minimum, tail feasibility threshold, false-quarantine budget, or expiry that makes the observed data pass. Gate B would review a post-hoc success rather than an independently justified calibration design. The resulting positive observation claim would not be reproducible or statistically defensible.

**Required correction:** Before any reference or cohort measurements are collected, add a separately reviewed calibration protocol with exact cohort diversity/adjudication rules, hardware-class boundary candidates, warm/cold matrix, prompt/position/sample minima, tail-feasibility go/no-go threshold, false-quarantine budget, confidence method, exclusions, stopping rule, expiry, and failure outcome. State whether SPEC-036's 30-day/100-canary/10-identity floors apply. If Build 3 uses a narrower observation-only standard, define its honest claim and prohibit reuse for warn/enforce or economic eligibility. Add evidence proving protocol publication preceded data collection.

### H3 — Money-SQLite serialization does not linearize the live provider session and model generation

**Severity:** High

**Evidence:** The plan says a request-start transaction re-evaluates generation and atomically binds the exact request observation (`prd-implementation-plan-v2.md:140-154`). In current code, provider session assignment, release generation, BYOM binding generation, and model state are owned by the WS server and in-memory pool. The route path checks them around a separate SQLite insert under WS locks (`internal/ws/model_admission_operator.go:938-993`). `billing.RouteSnapshot` has a generation field, but the buyer route currently writes `ProviderGenerationID: nil` (`internal/buyer/route_snapshot.go:131-175`). The proposed SQLite schema stores an observation generation but defines no durable projection, route token, lock order, or compare protocol that binds it to the WS-owned `AssignedID`, target generation, release generation, and binding epoch. O010 tests only a generic expiry/catalog/profile/generation boundary, and A006 groups generation change with several unrelated physical paths (`test-spec-v2.md:77,170`).

**Consequence:** A disconnect/re-onboard, same-number generation reuse, warm model swap, release publication, or BYOM binding change can occur between the WS route decision and the SQLite capture. The transaction can then persist an internally consistent but already stale positive observation for a different live session/model generation. SQLite ordering against observation revocation alone does not close that trust boundary.

**Required correction:** Define the cross-owner request-start protocol. It must carry a coordinator-issued route admission token binding stable provider identity, assigned session ID, target model generation, release generation, admission binding generation/epoch, exact model/artifact/pilot key, and observation predecessor. Specify lock order and pre/post-commit comparisons, or persist WS lifecycle generations through the same durable writer before they become routable. A stale post-check must prevent dispatch and make the immutable orphan snapshot non-rewardable. Add deterministic races for both commit orders around disconnect, reconnect with generation-number reuse, model swap, catalog/release rotation, BYOM binding movement, and observation revocation.

### H4 — The external anchor has an undetectable committed-suffix rollback window

**Severity:** High

**Evidence:** The proposed writer commits SQLite first and advances the external anchor afterward; a crash in between is explicitly accepted and startup may advance the anchor from the database descendant (`prd-implementation-plan-v2.md:174-178`; B3-O008 and B3-M012). If SQLite commits event N, the process crashes before advancing an anchor at N-1, and an older database image at exactly N-1 is restored before startup while Postgres has not applied N, every surviving authority agrees on N-1. No record says N ever committed. M010/M011 test restores when the external anchor or target is ahead, but no test covers this exact commit-crash-restore ordering (`test-spec-v2.md:113-116`).

**Consequence:** The plan's restore-resistant completeness claim is false for a money-path event committed in this window. A receipt, exclusion, reversal, observation revocation, or credit mutation can disappear, after which the source can report ready and complete at the prior head.

**Required correction:** Use a recoverable external prepare/commit protocol or another non-restored monotonic authority that records the intended next sequence/digest before SQLite commit and resolves committed versus aborted intent after restart. Define durability/fsync order, uncertain-write recovery, abandoned-intent handling, and how the database proves the prepared payload. Add fault injection for restore at every point before/after external prepare, SQLite commit, external commit, target apply, and directory fsync, including the exact case where neither current anchor nor target reached the committed SQLite suffix.

### H5 — The proposed journal/anchor hot path has no feasibility or capacity gate

**Severity:** High

**Evidence:** Every reward-projectable mutation must emit a complete denormalized snapshot, and every authoritative write holds one global lineage `flock` through SQLite commit, atomic anchor replacement, and directory fsync before the next write (`prd-implementation-plan-v2.md:147-170,174-188`). The current source already has many independent billing mutation paths and a latency-sensitive pre-dispatch route-snapshot insert (`internal/buyer/route_snapshot.go:95-199`; `internal/billing/hotpath.go`; `internal/billing/settlement_finality.go`). The 97 acceptance IDs contain no declared maximum lock wait, request-start latency regression, mutations/second floor, event-size ceiling, daily disk-growth/retention budget, bootstrap-duration ceiling, or overload/backpressure result. The generic security bullet for bounded resources is not a measurable gate (`test-spec-v2.md:174-181`).

**Consequence:** An implementation can pass every enumerated acceptance ID while serializing paid request starts behind an fsync-heavy global sidecar, growing SQLite without bound, or requiring an operationally unacceptable exclusive bootstrap. This can turn an observation feature into buyer latency, availability, and storage risk.

**Required correction:** Make hot-path feasibility part of the pre-implementation gate. Inventory mutation rates and payload sizes, declare p50/p95/p99 lock and request-start latency budgets, throughput and queue/backpressure behavior, maximum event size, retained bytes/day, retention/compaction rules that preserve audit proofs, bootstrap size/duration thresholds, and disk-full/fsync-error behavior. Benchmark representative concurrency and database sizes on the supported storage profile. A failed budget keeps the journal/anchor design blocked and requires a new architecture gate.

### M1 — The shared scheduler does not define safe preemption of a running MLX probe

**Severity:** Medium

**Evidence:** The plan gives buyer work absolute admission priority and permits preemption of queued probes, but it does not define the state transition when buyer work arrives during a running Metal operation (`prd-implementation-plan-v2.md:198-205`). P008 explicitly covers a queued **or running** probe yet requires only that the buyer be admitted first and that a queued probe be cancelled (`test-spec-v2.md:93`). F004 records cancellation behavior and paid-work stability, but no acceptance rule requires the running probe to reach a proven quiescent GPU state before buyer execution or defines a bounded fallback when MLX cancellation cannot preempt an in-flight kernel (`:31`).

**Consequence:** A superficially conforming scheduler can overlap a supposedly cancelled probe with paid inference, corrupt resource accounting, increase memory pressure/latency, or admit buyer work while probe results can still mutate state. Another implementation can block the buyer indefinitely waiting for non-preemptible work; both satisfy the current prose.

**Required correction:** Define queued, dispatching, running, cancelling, quiesced, and terminal lease states. Specify the point after which a buyer waits, the maximum quiescence budget, whether an uninterruptible probe causes typed provider draining/unavailability, and how late GPU completion is fenced. Add real-MLX tests for buyer arrival at load, prefill, sampler, device synchronization, serialization, and result-send boundaries, asserting no overlap beyond the declared resource contract and no observation/economic event from cancelled work.

### M2 — `provider_reward_status.v2` still lacks a closed reason vocabulary and total mapping

**Severity:** Medium

**Evidence:** Revision 2 closes the four output state enums and recovery actions, but never enumerates the allowed primary/secondary reasons or the complete authoritative input vocabulary (`prd-implementation-plan-v2.md:207-238`). Its precedence groups multiple non-equivalent facts at the same rank—for example terminal exclusion, wallet missing/mismatch, and no eligible balance all map to withdrawal `ineligible`, while requiring different primary reasons and actions (`:232`). The current v1 model also consumes verified-receipt count, app attestation, hardware evidence, runtime telemetry, trust tier, multiple hold types, and wallet-cap replay (`internal/rewards/read_model.go`; `internal/rewards/projection.go`; `internal/rewards/wallet_status.go`), but the v2 mapping does not state how all of those inputs map or rank. R001 cannot enumerate a closed reason set that the plan does not define, and pairwise testing cannot prove totality without a canonical input schema (`test-spec-v2.md:123-142`).

**Consequence:** Go, Swift, and portal can select different primary reasons/actions under simultaneous conditions while each claims to follow the prose. Unknown or newly added trust/hardware/ledger facts can silently fall through, and one client can present a more optimistic state than another.

**Required correction:** Add the actual normative machine-readable input and output schemas plus the full reason enum. Define deterministic primary and secondary ordering for every input, including verified receipts, app attestation, hardware evidence, runtime telemetry, trust/demotion, wallet mismatch, provider/wallet cap replay, active disposition, source staleness, and unknown values. Generate exhaustive vectors from that artifact, prove every valid input maps once, and prove invalid/unknown input closes only the affected projection.

### M3 — The test-accrual path is ambiguous about SPEC-022 observe versus SPEC-036 observe

**Severity:** Medium

**Evidence:** Build 3 keeps SPEC-036 in `observe` and makes its request capture informational/reward input only (`prd-implementation-plan-v2.md:136,140-145`; B3-O011). R003 nevertheless expects a captured request to become eligible and create test accrual, while R012 says an “observe-only economic exclusion” produces no accrual (`test-spec-v2.md:131,140`). The plan does not define whether that exclusion means SPEC-022 route mode `observe`, SPEC-036 observation mode, or both. Current route snapshots already use SPEC-022 `observe|enforce` independently of SPEC-036 (`internal/billing/route_snapshot.go:21-25`; `internal/buyer/route_snapshot.go:44-50,214-231`).

**Consequence:** The acceptance trace can either be impossible—all Build 3 captures are observation-only and therefore excluded—or can accidentally let observation availability become an economic authorization. Test-only behavior may then diverge from the production mapping it is intended to validate.

**Required correction:** Name the two mode dimensions separately in schemas, truth tables, and tests. Define the exact request predicate for shadow/test-only accrual, prove SPEC-022 observe requests remain excluded, and state whether a SPEC-022-enforce request with a SPEC-036-observe capture may produce only a dry-run/shadow decision or a local test ledger row. Ensure no production feature flag can consume that result, and add negative tests for every two-mode combination.

## Prior-finding disposition assessment

| Prior finding | Revision 2 assessment |
| --- | --- |
| H1 exact pilot/gate | **Not resolved:** Gate A/Gate B are explicit, but the final pilot and production release requirements are cyclic. |
| H2 durable owner/linearization | **Partially resolved:** SQLite event/revision ordering is concrete; live session/model generation remains outside the linearization protocol. |
| H3 immutable billing payload | **Resolved at plan level:** complete snapshot payload and payload-only consumption are required, subject to the feasibility finding above. |
| H4 restore/bootstrap | **Not resolved:** same-generation rollback is generally addressed, but the post-commit/pre-anchor restore window remains undetectable. |
| H5 references/calibration | **Partially resolved:** three-axis independence and golden validation are restored; calibration rules are still not frozen before evidence collection. |
| M1 carrier/shared scheduler | **Partially resolved:** carrier and aggregate priority are explicit; running-probe preemption/quiescence is not. |
| M2 total reward mapping | **Not resolved:** output states are closed, but reasons, authoritative inputs, and simultaneous-condition ordering are not total. |

No prior finding was downgraded or waived.

## Fresh verification

Artifact digests and repository identity matched the review request exactly. The branch changes through the reviewed commit are documentation-only.

```text
sha256sum prd-implementation-plan-v2.md test-spec-v2.md plan-v1-findings-disposition-r2.md plan-v1-sol.md
  PASS: 040df8c...; 519cecb3...; 434fcd67...; 4c290070...

git rev-parse HEAD
  PASS: 8cf1b41eacca0d79dea5721103a9147e175a40b7

cd phase4-coordinator && go test ./internal/computeintegrity ./internal/stats/billingmirror ./internal/rewards ./internal/billing ./internal/buyer -count=1
  PASS: 5 packages, zero reported failures
```

These tests confirm the unchanged conservative baseline. They do not prove the proposed Build 3 contracts, actual MLX behavior, reference independence, calibration, migration safety, physical acceptance, or production qualification.

## Gate decision

`build3-plan-v2` / `build3-test-v2` is **not approved**, including for Gate A evidence collection. Revise the plan and test specification to resolve all findings, commit the exact artifacts, and rerun an independent GPT-5.6 Sol high-reasoning gate. Runtime implementation, economic activation, enforcement, payment execution, deployment, and production qualification remain prohibited.
