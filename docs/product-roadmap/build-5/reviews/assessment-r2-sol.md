# Product Build 5 assessment r2 — independent adversarial review

Date: 2026-09-11

Reviewer lane: native GPT-5.6 Sol, high reasoning

Repository base: `1d2c930bad81704dd0acc0322226725d8b64aceb`

Reviewed commit: `11e618eada1bd16e5c350fb6a0a15820f0b089cd`

Scope: assessment and benchmark planning only. No throughput-engine implementation,
production activation, hardware procurement/provisioning, or private-data transfer was
reviewed or authorized.

## Exact reviewed artifacts

| Artifact | SHA-256 |
|---|---|
| `current-state-evidence.md` | `72b7eb53f8f70c2e8c70522ebac776bae659d838d7af2ea4e3ccfb56dd0d5d1b` |
| `feasibility-assessment.md` | `a58a1468bec8c17a1ca9ddca7d6057f331e547eba6465b542dd401b88928edd2` |
| `test-benchmark-spec.md` | `b02f8012c8d1c260de051b2aacb693895dbb4b2af8b83e5adf8913ace4daddb2` |
| `resume-checkpoint.md` | `fd82ddb13ddade41bbc70c8dda37fca45c36f51afed411f049220d069e9bc694` |

All four digests matched the files in the reviewed commit.

## Review method

I independently inspected the runtime and test seams in `ModelRuntime.swift`,
`ContinuousBatching.swift`, `ContinuousBatchScheduler.swift`, `PagedKVCache.swift`, and
`PagedKVEngine.swift`; SPEC-023, SPEC-038, SPEC-039, `CONFORMANCE.json`, the batching
enable runbook, and RESEARCH_232's frozen MSB workloads. I also checked the live GitHub
state of draft PR #894 without treating it as merged evidence, recalculated every KV
table value, and independently re-ran:

```text
cd phase3-binary
swift test --filter 'PagedKVEngineTests|ContinuousBatchSchedulerTests|PagedKVParityTests'
```

The fresh run exited 0 with 73 executable tests passing and all three selected real-model
parity tests explicitly skipped. The current host inventory independently matched an
Apple M5 MacBook Air with 32 GB memory, macOS 26.5 (25F71), Xcode 26.6 (17F113), and
Swift 6.3.3. Multiple Malibu/provider processes were present, confirming that this was
not a clean sustained-load benchmark host.

The KV arithmetic is correct for the stated geometries: 112, 144, and 96 KiB/token,
respectively, and the listed binary-GiB examples follow from those values. The result is
still a partial budget because the non-KV terms have not been quantified.

## Verdict

**FAIL — revision r2 is not approved for implementation or qualification use.**

Finding counts: **0 Critical, 4 High, 5 Medium, 0 Low**.

The assessment is strong in its claim boundaries, fixture-versus-real distinction,
default-off posture, remote-data safeguards, and narrow description of the 3B gather
result. The findings below prevent the required zero-Critical/High/Medium gate.

## Findings

### H1 — The required MSB workloads exceed Entry 110 on their specified hosts

**Severity:** High

**Evidence:** `test-benchmark-spec.md:108-112` requires real 3B execution at concurrency
1, 2, and 4 on the current M5 Air. Lines 169-171 bind MSB-01 to an M4 Max 64 GB and then
require four simultaneous rows for MSB-02 and MSB-03. Lines 145-147 separately say the
campaign proceeds only to the highest Entry 110 row cap. Current authority returns one
row for a base M5 and two rows for any Max with at least 48 GB
(`AutotuneRecommend.swift:198-213`). SPEC-038 FR-CB11 requires the active-row maximum to
equal that persisted Entry 110 recommendation and forbids synthesizing a larger tier
(`SPEC-038-continuous-batching.md:361-372`). The frozen historical MSB-02 workload asks
for four rows on the MSB-01 M4 Max host, but the later normative capacity contract permits
only two.

**Consequence:** The required campaign cannot pass as written. Running four live rows on
either named host violates the normative cap; moving MSB-02/03 to another host without a
same-host MSB-01 changes the throughput denominator and invalidates the comparison. An
implementation could otherwise be pressured to bypass the admission authority merely to
satisfy the benchmark.

**Required correction:** Make this conflict an explicit normative prerequisite. Amend or
clarify SPEC-038 before implementation so each MSB comparison has a legal same-host,
same-artifact baseline. A viable plan can place MSB-01/02/03 on a four-slot Entry 110 Ultra
tuple and record the deviation from the historical M4 Max setup, or define a separately
governed non-serving benchmark mode that cannot advertise capacity or serve buyer traffic.
Until that decision lands, mark four-row real cells blocked. Restrict the M5 Air's
production-shaped real runtime qualification to its authoritative cap; concurrency 2/4
may remain deterministic executor work, not a qualified live-serving result.

### H2 — The plan omits arbitration between batched work and serial fallback

**Severity:** High

**Evidence:** SPEC-038 FR-CB7 states that supported batched rows and unsupported serial
iterators must not run concurrently against the same resident model without a proof of
thread safety (`SPEC-038-continuous-batching.md:289-298`), and AC-18 requires a structural
and concurrency fixture for that property (lines 699-703). The assessment's Stage A
defines one batch scheduler but no owner or state machine arbitrating the existing
`AsyncSemaphore` serial path against it. `test-benchmark-spec.md:67-73` tests unsupported
routing, and lines 155-156 deliberately inject ten percent unsupported traffic, but no
gate asserts mutual exclusion, drain ordering, or an independently reviewed thread-safety
proof. Current production still creates independent `TokenIterator` instances under the
semaphore (`ModelRuntime.swift:2502-2594`).

**Consequence:** A reason-coded fallback may be functionally correct yet overlap a shared
forward on the same model. That can corrupt model/KV state, invalidate memory accounting,
or cause a Metal failure. A common queue/counter alone does not establish safe model
execution ownership.

**Required correction:** Add a single runtime execution arbiter covering both batch and
serial paths. Define its states and transitions for ordinary unsupported requests,
scheduler failure, pre-output retry, warm swap, cancellation, and drain. Specify whether
serial work waits for batch quiescence or vice versa. Add deterministic and real-runtime
tests proving no overlap, or name the exact thread-safety evidence that authorizes it.
The ten-percent mixed ingress cell must assert this invariant as well as queue accounting.

### H3 — The benchmark method assigns the frozen MSB IDs to the wrong executors

**Severity:** High

**Evidence:** `test-benchmark-spec.md:183-187` calls MSB-02 “current multi-iterator
behavior,” MSB-03 the “supported shared forward,” and MSB-05 a “scale/concurrency sweep.”
That contradicts both the table immediately above and RESEARCH_232: MSB-02 is the
four-identical-prompt batching workload, MSB-03 is the four-ragged-prompt batching
workload, MSB-04 is the MoE batching workload, and MSB-05 specifically compares current
two-iterator native Swift against pinned oMLX (`RESEARCH_232...md:1255-1429`). SPEC-038
AC-13 requires the harness to preserve all five frozen scenarios and their memo fields
(`SPEC-038-continuous-batching.md:664-671`).

**Consequence:** The plan can apply the MSB-02 uplift threshold to the old parallel path,
apply MSB-03 to a different executor, and omit the actual MSB-05 oracle comparison. Such
results are not comparable to the normative thresholds and could falsely promote a tuple.

**Required correction:** Replace the method mapping with an explicit arm matrix. MSB-01
is the same-host single-stream reference; MSB-02 and MSB-03 run the candidate shared
forward on their exact prompt shapes; MSB-04 uses the independent MoE baseline and
candidate; MSB-05 retains the frozen native-two-iterator versus pinned-oMLX paired arms.
If the new shared-forward prototype is also compared with oMLX, give that experiment a
new ID and threshold rather than overloading MSB-05.

### H4 — The memory and pressure go/no-go gate is not executable yet

**Severity:** High

**Evidence:** The assessment lists `M_OS_reserve`, weights, activations, KV pool,
transient gather, delivery/queues, and headroom, but quantifies only logical KV. The test
gate requires peak process/MLX memory to be below both 85 percent of RAM and “the
precomputed envelope plus 10 percent measurement allowance”
(`test-benchmark-spec.md:237-242`) without defining the envelope artifact, whether its
headroom already includes that allowance, or how process physical footprint and MLX
active/peak memory are combined without double counting. “Critical VM pressure,” “swap
storm,” “fixed cadence,” “drain/recovery window,” and return to baseline have no concrete
instrument, duration, threshold, or tolerance. The real-model grid likewise does not
require prompt plus generated-token total when selecting each block reservation bound.

**Consequence:** Two operators can reach opposite pass/fail decisions from the same run.
The stop boundary can be detected too late on unified memory, and a tuple may be declared
within budget using only KV while ignoring gather/activation peaks. This defeats the core
capacity-feasibility gate.

**Required correction:** Define a versioned per-cell memory-budget manifest, frozen before
measurement, containing installed RAM, OS/system reserve, verified resident weight bytes,
activation and gather peaks, queue/delivery allowance, KV bytes including prompt plus
output headroom and block fragmentation, and one non-duplicated measurement allowance.
Name the authoritative metric(s), units, sampling cadence, aggregation, and checked
arithmetic. Define macOS pressure/thermal states, swap delta, abort thresholds, post-drain
window, and baseline-return tolerance. Values that require the future host may be filled
in a preregistered campaign manifest, but the schema and pass algorithm must be fixed now.

### M1 — SPEC-039's pending conformance state is missing from the blockers

**Severity:** Medium

**Evidence:** `current-state-evidence.md` and the qualification blockers call out pending
SPEC-038 conformance, but not SPEC-039. At the reviewed base, `CONFORMANCE.json` records
all `SPEC-039-R001` through `SPEC-039-R014` as `pending` with empty implementation, test,
and evidence arrays, and SPEC-039 itself remains draft/pending-reconciliation.

**Consequence:** The assessment can be read as if the paged engine's normative
implementation/conformance is reconciled while only the scheduler remains pending. That
is materially broader than the repository's authority record.

**Required correction:** Add SPEC-039's exact pending requirements to the current-state
classification, dependency graph, Stage A prerequisites, and qualification blockers.
Separate “foundation code exists” from “SPEC-039 implementation/conformance is accepted.”

### M2 — The fresh 3B result is not bound to a reproducible artifact tuple

**Severity:** Medium

**Evidence:** The current-state artifact reports a real 3B gather result but records no
snapshot revision/path digest, weights/config/tokenizer hashes, prompt digest, dirty state,
metallib hash, or raw evidence location. The harness chooses the first snapshot directory
returned by the filesystem and its descriptor uses all-zero model and metallib hashes
(`PagedKVParityTests.swift:40-48,84-107`). This falls short of the assessment's own future
result contract in `test-benchmark-spec.md:18-24`.

**Consequence:** The pass is credible evidence that one locally loaded model executed the
gather seam, but it cannot be reproduced as, or attributed to, an exact model/artifact/
metallib tuple. A later cache change could silently select a different snapshot.

**Required correction:** Either relabel the run as exploratory, non-tuple-qualified
evidence or add a sanitized immutable evidence manifest with the actual snapshot revision
and file/config/tokenizer/metallib hashes, prompt digest, binary/commit/dirty state, and raw
log digest. A future harness must select the snapshot by declared revision and reject
ambiguous candidates rather than accepting the first directory entry.

### M3 — Statistical and workload protocols leave promotion results under-specified

**Severity:** Medium

**Evidence:** The method requires only 20 repetitions for MSB-01 through MSB-04 while also
requiring p95/p99 metrics, and it gives no minimum completed-request count for cancellation
p99. MSB-05 requires a bootstrap-CI width but does not define the estimator, resampling
unit, resample count, random seed, interval method, or whether width is absolute ratio
units. Mixed ingress, slow-consumer, and cancellation-churn cells lack arrival process,
request count/duration, slow-consumer rate, and cancellation timing. Exclusion labels such
as unrelated load and thermal emergency lack predeclared numeric/state criteria.

**Consequence:** Tail metrics and the oracle comparison are not reproducible and are open
to post-result choices. The heterogeneous/failure cells can exercise materially different
loads while sharing one label.

**Required correction:** Freeze each workload generator, sample unit, minimum sample size,
arrival schedule, consumer delay, cancellation distribution, warm-up/exclusion rule, and
tail-estimation method. Specify the MSB-05 bootstrap algorithm and seed. Require enough
observations for each reported percentile and report uncertainty; otherwise mark that
percentile descriptive and unavailable for promotion.

### M4 — The MoE deterministic parity tolerance is undefined

**Severity:** Medium

**Evidence:** C1 requires exact generated token IDs for every deterministic parity cell,
but MSB-04 requires only that an “accepted deterministic output tolerance” pass
(`test-benchmark-spec.md:32,172`). Neither document fixes that tolerance or identifies a
raw-logit comparison whose numerical threshold would justify it. SPEC-038 AC-6 permits a
numerical tolerance only for an explicitly defined raw-logit fixture and otherwise requires
identical greedy tokens (`SPEC-038-continuous-batching.md:622-627`).

**Consequence:** The tolerance can be chosen after observing divergence, weakening a
money-path correctness gate.

**Required correction:** Require identical greedy token IDs and terminal/accounting output
for MSB-04. If a raw-logit diagnostic is retained, preregister its dtype-aware absolute/
relative tolerance, comparison points, and failure interpretation; it must not replace
token parity.

### M5 — Release-candidate identity does not cover the repository's full release contract

**Severity:** Medium

**Evidence:** C10 requires one release-candidate executable and packaged metallib, while
the repository release policy requires byte identity between the standalone and Malibu.app
embedded CLI after final signing, notarization, stapling, and packaging when both are
shipped. The local evidence was produced with Xcode 26.6/Swift 6.3.3, whereas the current
throughput runbook identifies Xcode 16.4/Swift 6.1 as the protected release toolchain.
Stage C says only “signed/noted” and does not define the dual-artifact/toolchain matrix.

**Consequence:** A locally valid paged executable could pass C10 while the shipped app
contains different bytes or the protected release toolchain cannot build the bridge.

**Required correction:** Extend C10 and Stage C to require the protected release-toolchain
build, final standalone/Malibu embedded CLI byte-identity proof when both artifacts ship,
metallib/dependency identity from both packages, codesign/notarization/stapling verification,
and updater coverage from the previous stable version. Keep current SwiftPM evidence
classified as development-only.

## Disposition

The plan gate remains closed. The next revision must resolve every High and Medium finding
without weakening the frozen correctness or evidence boundaries, then obtain a fresh
independent review against new exact digests. No larger-hardware absence is treated as a
test pass: representative capacity, throughput, memory-servability, and production
activation remain unproven and feature-gated.
