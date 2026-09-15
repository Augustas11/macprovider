# Product Build 5 assessment R4 independent adversarial review

Date: 2026-09-11

Reviewer lane: independent GPT-5.6 Sol, high reasoning

Reviewed commit: `53809884e0bd64a6d4847293bd49c72dc862d666`

Repository source base: `1d2c930bad81704dd0acc0322226725d8b64aceb`

Scope: assessment and planning only. This review authorizes no throughput-engine
implementation, scheduler activation, production traffic, hardware procurement,
remote transfer, or economic action.

## Frozen inputs

| Artifact | SHA-256 |
|---|---|
| `feasibility-assessment.md` | `e44e9d8ca0e44fc5fc23b152e99833143eb28bce49ca30e7394bde890c426c77` |
| `test-benchmark-spec.md` | `d527ac9e26f9a83543324d69162a7c15f93135433076d774d0951ec093eeedef` |
| `current-state-evidence.md` | `0ab34821f52e1c2e56623d29923d1847e67ac56a689f5bd3fa4c194d4c50f0c6` |
| `assessment-r3-dispositions-r4.md` | `60904cb2307bf0d97d8d65d61701f757461b712c6581eece9697b7bda7c72cf9` |
| `assessment-r3-sol.md` | `a58ae2d50e854221fbba61b9bc5905b8b05b4585d43db7f4e8c5146430134267` |
| `real-mlx-3b-exploratory-r3.log` | `b7bc70a4b7f89b9620b08d1ffa7941a3c49e0fd6b1032f4440dd93dd9089dd95` |

All six digests matched the committed tree. The reviewed commit was clean before
this review artifact was created, and `git diff --check HEAD^ HEAD` passed.

## Independent inspection

The review inspected the merged-source runtime and authority surfaces rather
than relying on the assessment's classification. In particular:

- `ModelRuntime.continuousBatchingCapability` still supplies no requested tuple
  and explicitly passes `schedulerBackendAvailable: false`;
- `ModelRuntime.enforcePagedKVPreflight` still rejects an attached paged-KV
  decision because no runtime lifecycle owner exists;
- serving still creates independent `TokenIterator` instances behind the
  existing `AsyncSemaphore`;
- `AutotuneRecommendHardware.recommendedMaxBatch` independently confirms row
  caps of one for base chips, two for Max at 48 GiB or more, three for Ultra at
  96-127 GiB, and four for Ultra at 128 GiB or more;
- SPEC-038 and SPEC-039 remain draft, pending reconciliation, and not deployed;
  SPEC-039-R001 through R014 remain pending without accepted mappings;
- the three analytical KV values recalculate to 112, 144, and 96 KiB/token, and
  the listed binary-GiB examples are arithmetically correct;
- the committed exploratory log and `Package.resolved` hashes match the R4
  evidence record, while the current parity harness still selects the first
  snapshot containing `config.json` and does not establish authoritative
  descriptor hashes;
- draft PR #894 remains open, draft, merge-conflicting, and red on
  `spec-index / check`; it is not merged evidence.

No implementation or inference tests were rerun for this documentation-only
gate. The previously recorded 73 executable deterministic passes and three
explicit skips remain historical evidence for this review, and the 3B MLX run
remains correctly labeled exploratory.

## Verdict

**FAIL — R4 is not approved for implementation or qualification use.**

Finding counts: **0 Critical, 2 High, 3 Medium, 0 Low**.

R4 closes much of the prior review: it fixes the five-start loaded-idle
aggregation, requires a process lifetime high-water counter for promotion,
names the previously missing reference and disturbance cells, restores the
MSB-01 CV gate, and gives the arbiter explicit wall-clock values. The remaining
findings below keep the mandatory zero-Critical/High/Medium gate closed.

## Findings

### H1 — The calibration safety gate is circular before the first exact-shape run

**Severity:** High

**Evidence:** `test-benchmark-spec.md:400-448` defines the promotion envelope as
`loaded_idle_phys_footprint + calibrated_target_peak_delta + allowances`.
Lines 455-479 correctly define the five clean starts, 600 paired samples per
start, per-start subtraction, lifetime physical-footprint high-water, and the
maximum across starts. But lines 481-487 then require those same exact-shape
calibration runs to be admitted under a preliminary manifest whose *planned
envelope* is at most 75% of RAM. The preliminary manifest has no separate
schema or algorithm for the not-yet-observed activation/gather/process delta.
The only specified planned-envelope formula consumes
`calibrated_target_peak_delta`, which those runs exist to discover. The 80% sampled
stop is not a substitute for a pre-admission bound: a unified-memory transient
can cross the limit between 100 ms samples, and the lifetime high-water read
afterward is evidentiary rather than preventive.

**Consequence:** Two conforming harnesses can invent different preliminary
deltas or treat the unknown term as zero. The first large exact-shape run can
therefore begin without the safety bound the document claims, potentially
driving memory pressure, OOM, or host disruption before the sampler can stop
admission. The exact five-start result algorithm is reproducible after a run,
but the safe boundary for performing that run is not executable.

**Required correction:** Define and freeze a separate pre-calibration manifest
and admission algorithm. It must derive a conservative *a priori* target bound
without using the future calibrated result, bind the exact shape and immutable
artifact, include analytical full-pool KV, queue/delivery bytes, and an explicit
activation/gather/transient reserve, and define a staged ramp or fail-closed
rule when that reserve cannot be justified. State the process isolation or
hard-stop mechanism that protects the host if the preliminary estimate is
wrong. The five non-replaceable clean starts may then produce the final
`memory-budget-v1`; do not weaken their maximum/high-water, pressure, swap,
thermal, or recovery gates.

### H2 — The mode-wait deadline excludes accepted backlog and the fence has no executable owner

**Severity:** High

**Evidence:** Arbiter rule 2 at `test-benchmark-spec.md:67-76` says an
opposite-mode waiter closes new current-mode lease issuance but must wait until
accepted current-mode batch work drains. SPEC-038 FR-CB13 explicitly permits
accepted queued requests bound to the resident snapshot. Rule 7 starts each
request's 900-second execution deadline at lease grant (`test-benchmark-spec.md:93-102`),
while rule 8 promises a healthy opposite-mode grant within 906 seconds and any
terminal disposition within 920 seconds from *its* enqueue
(`test-benchmark-spec.md:103-117`). An already accepted current-mode backlog can
contain work that has not yet received its request execution grant. Draining
those requests serially or in successive batches can consume multiple
900-second intervals, so the 906/920 promises do not follow from the stated
rules. No rule rejects, cancels, or starts a queue-residence deadline for that
backlog when the mode epoch closes.

The same section requires a failed generation's supervised worker to exit or
be terminated within a ten-second fence, but the ownership/dependency plan
still places the future arbiter inside `ModelRuntime` and does not choose
between killing the provider process and moving MLX execution into a supervised
child. Current inference is in-process. A virtual-clock assertion that a fence
callback was invoked cannot prove that the executing Metal/model context has
actually ceased or that a replacement generation is safe to publish.

**Consequence:** An implementation can satisfy mutual exclusion and every
per-granted-request deadline while starving the opposite mode past 920 seconds.
On non-termination it can also report logical fencing while the in-process
executor remains alive, defeating the no-reuse and safe-swap claims. This leaves
the R3 liveness finding open at the architecture boundary.

**Required correction:** Define one bounded mode-epoch algorithm for
pre-admission, accepted-queued, and active work. At opposite-mode selection,
state exactly which backlog is terminally rejected, which is cancelled, and
which receives a queue-inclusive deadline; prove the 906/920 arithmetic at the
maximum queue and Entry 110 depth. Preserve FCFS within the declared scope and
SPEC-038 snapshot/receipt rules. Also choose the fencing architecture: either a
separate supervised inference process with explicit IPC/ownership and verified
exit, or a whole-provider termination/restart contract with an external
supervisor and durable request disposition. Structural and real-runtime tests
must observe actual worker/process exit before lease reuse or generation
publication, not merely fence invocation.

### M1 — The immutable loader closure still omits runtime bytes and relies on a cooperative lock

**Severity:** Medium

**Evidence:** `test-benchmark-spec.md:173-185` copies the entire model, runtime,
and campaign trees into a read-only-mounted APFS image. The canonical manifest
at lines 187-208 is exhaustive for the model tree, but for `/runtime` and
`/campaign` it enumerates selected resource/metallib bundles, the executable,
`Package.resolved`, checkout revisions, the harness/result schema, selectors,
and dependencies discoverable through recursive `otool -L`. It does not require
every regular file under the copied runtime and campaign trees to appear, does
not fail when a resolved non-platform image lies outside the mounted image, and
does not bind libraries or plugins loaded dynamically outside the static
`otool -L` graph. Thus “opened only from this mounted image” is asserted but not
made a checkable closure.

Lines 210-220 hold the disk-image backing file under an exclusive *advisory*
lock and compare pre/post identities and hashes. An advisory lock prevents only
cooperating writers. A write-and-restore during the cell can feed different
bytes without leaving a final content mismatch, so the backing image is not
immutable under the document's unstated local-writer trust boundary.

**Consequence:** A qualifying result can omit a runtime/campaign byte used by
the loader, or consume an out-of-image dynamic dependency, while still matching
the declared manifest. The descriptor would then bind less than the executable
closure that produced the result.

**Required correction:** Manifest every regular file in all three adopted
trees, reject all non-platform loads whose canonical source is outside the
read-only image, and bind actual loaded Mach-O/plugin images in addition to the
static dependency graph. Define the local-writer threat boundary and use a
non-writable/sealed backing-object procedure within it; fail if any writable
descriptor or attachment exists. Preserve the complete pre/post identity and
content recapture as defense in depth.

### M2 — Cancellation and slow-consumer cells still have nondeterministic injection boundaries

**Severity:** Medium

**Evidence:** R4 names the missing cells and fixes counts, prompt/output bins,
arrivals, and timeouts. However, `SLOW-CONSUMER-500-R1` at
`test-benchmark-spec.md:328-336` delays each client read by 100 ms without
fixing the read size, socket/stream high-water, or exact condition that marks
server delivery backpressure; a 64 KiB client buffer alone does not make the
pressure schedule reproducible. `CANCEL-2000-R1` at lines 337-347 requests
cancellation at “25% prefill” and “delivery backpressure” without fixing the
prefill chunk/token boundary or the delivery queue occupancy/event that
triggers cancellation. These boundaries can differ across harnesses and model
implementations even with identical prompts.

**Consequence:** Two implementations can use the same cell ID while exercising
materially different cancellation and backpressure paths. One may cancel
between chunks while another cancels only after a monolithic prefill or before
the delivery queue is actually constrained, so zero failures would not prove
the claimed lifecycle coverage.

**Required correction:** Freeze the prefill chunk size and exact token-index
event for the 25% case; define the delivery queue occupancy/watermark and event
sequence for backpressure cancellation; and fix client read chunk size,
receive-window behavior under harness control, first-read offset, and cadence.
Record the reached boundary before injecting cancellation and fail the cell if
the boundary is not reached.

### M3 — Latency-tail uncertainty treats correlated batched requests as independent

**Severity:** Medium

**Evidence:** `test-benchmark-spec.md:289-310` requires at least five clean
starts but calls request observations independent and constructs latency
percentile intervals by resampling complete requests within an arm. Requests in
one shared-forward repetition are correlated through the same batch, process,
thermal state, allocator state, and disturbance schedule. The MSB-02/03 rows in
particular are four observations from one simultaneous cohort. Treating them as
independent request-level bootstrap units understates uncertainty. The restored
MSB-01 CV rule at lines 536-539 is clear and remains valid, but it does not
repair candidate-arm tail inference.

**Consequence:** The point p95 can pass a promotion threshold while its reported
confidence interval is too narrow because within-batch and within-start
correlation was discarded. Different row counts also create different amounts
of pseudo-replication between the serial and candidate arms.

**Required correction:** Freeze a cluster-aware estimator and resampling unit,
such as hierarchical resampling by clean start, then complete repetition, then
row, while preserving all rows of a batch together at the repetition level.
Define the minimum independent cluster count for a promotable interval. If the
existing request-level interval is retained as descriptive only, say so and
prevent it from supporting any go/no-go claim.

## Closure status

| Prior area | R4 result |
|---|---|
| Entry 110 legality and hardware matrix | Closed. Four-row dense qualification is confined to a same-host Ultra >=128 GiB path; current M5 and Max lanes remain at one/two rows. |
| MSB executor mapping | Closed. MSB-01 through MSB-05 retain the correct serial, shared-forward, MoE, and native-versus-oMLX arms. |
| SPEC-038/SPEC-039 status | Closed. Both remain explicitly pending and non-deployed. |
| MoE correctness | Closed. Exact greedy token, terminal, and accounting equality is mandatory. |
| Protected release identity | Closed. Protected toolchain, final dual-package byte/resource identity, signing/notarization/stapling/Gatekeeper, and previous-stable update evidence are required. |
| Five-start memory result calculation | Substantially closed after admission; pre-calibration safety remains H1. |
| Loader-byte closure | Partially closed; model closure is exhaustive, while runtime/campaign/dynamic-load immutability remains M1. |
| Disturbance/reference reproducibility | Reference, warm-swap, model-failure, counts, and timeouts are closed; cancellation/backpressure injection remains M2. |
| MSB-01 stability | Closed with 100 runs and CV <=10%. Candidate latency inference remains M3. |
| Arbiter liveness | Explicit thresholds exist, but accepted backlog and executable fencing remain H2. |

## Disposition

The assessment remains truthful about what can be designed and tested on the
current 32 GiB Mac, and it correctly keeps representative capacity, large-model
performance, release qualification, and production activation unproved. The
plan gate remains closed until H1-H2 and M1-M3 are corrected without reducing
the existing correctness, hardware, memory, release, or claim boundaries and a
fresh independent GPT-5.6 Sol review reports zero Critical, High, and Medium
findings.
