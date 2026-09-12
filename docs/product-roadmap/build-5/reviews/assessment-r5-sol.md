# Product Build 5 assessment R5 independent adversarial review

Date: 2026-09-11

Reviewer lane: independent GPT-5.6 Sol, high reasoning

Reviewed commit: `e97ab6deb5b9fda14e3500fbb064aabd1522aba3`

Repository source base: `1d2c930bad81704dd0acc0322226725d8b64aceb`

Scope: assessment and planning only. This review authorizes no throughput-engine
implementation, scheduler activation, production traffic, hardware procurement,
remote transfer, or economic action.

## Frozen inputs

| Artifact | SHA-256 |
|---|---|
| `feasibility-assessment.md` | `3418a419ea2123cd2196078e2c6fc9e2c51be405bfa65ed53e53607656bfbb60` |
| `test-benchmark-spec.md` | `1d437557b9f05ccd03bab44183bcd08160f1010d5a4fd9d45f4e425bb4b564d5` |
| `current-state-evidence.md` | `cd070f8cae3f9507b53bfba0faf351ca60c98e1b2976ebe61e9b782d91705c0d` |
| `assessment-r4-dispositions-r5.md` | `c74237ce9e933e84d3f7e6032e72e2c1c53e16dbfa7d8fef8a7c072e2ba22df9` |
| `assessment-r4-sol.md` | `c9a77095519882d6200cb768a34d2e233fade860739f955269bf484fae3add5d` |
| `real-mlx-3b-exploratory-r3.log` | `b7bc70a4b7f89b9620b08d1ffa7941a3c49e0fd6b1032f4440dd93dd9089dd95` |

At the original review, all six then-recorded digests matched the reviewed
commit. The two predecessor-review rows now record the normalized current bytes
described in `artifact-normalization-r7.md`; the other four rows remain the
original frozen inputs. The normalized review chain requires fresh independent
revalidation. The branch changes only durable Build 5 assessment artifacts
relative to its stated source base. The reviewed commit was clean before this
review artifact was created.

## Independent inspection

The review inspected the source and governing documents independently:

- `ModelRuntime.continuousBatchingCapability` still supplies no requested tuple
  and passes `schedulerBackendAvailable: false`;
- `ModelRuntime.enforcePagedKVPreflight` still rejects an attached paged-KV
  decision because no runtime lifecycle owner exists;
- serving still constructs independent `TokenIterator` instances behind the
  existing `AsyncSemaphore`;
- `AutotuneRecommendHardware.recommendedMaxBatch` still caps base chips at one,
  Max with at least 48 GiB at two, Ultra with 96--127 GiB at three, and Ultra
  with at least 128 GiB at four;
- SPEC-038 and SPEC-039 conformance remain pending; and
- local Darwin documentation identifies `RLIMIT_AS` as the `RLIMIT_RSS` alias.
  The `setrlimit(2)` manual describes that limit as influencing which processes
  receive physical memory when memory is tight, not as an unconditional
  allocation-failure boundary. The same local documentation says `waitpid`
  waits for child processes, while `launchd.plist(5)` documents process-group
  killing after a launchd job dies unless `AbandonProcessGroup` is enabled.

No implementation or inference test was rerun for this documentation-only
gate. The recorded deterministic passes and real-MLX run remain historical
evidence with the limitations stated by R5.

## Verdict

**FAIL -- R5 is not approved for implementation or qualification use.**

Finding counts: **0 Critical, 3 High, 3 Medium, 0 Low**.

R5 materially improves the prior revision: it separates pre-load,
pre-calibration, and final budgets; bounds accepted work by queue-inclusive
epochs; selects a worker-process topology; closes the regular-file manifest;
fixes cancellation markers; and uses clean-start/batch-cluster resampling. The
remaining findings below prevent the mandatory zero-Critical/High/Medium gate.

## Findings

### H1 -- The claimed CPU/Metal hard stop is not established by the specified `RLIMIT_AS` probe

**Severity:** High

**Evidence:** `test-benchmark-spec.md:677-701` derives `rlimit_as_bytes` by
mixing loaded virtual size with a physical-RAM limit, calls `RLIMIT_AS` a hard
boundary, and deems the cap proved when one 768 MiB allocation fails with 512
MiB of nominal headroom in each of two sacrificial workers. It does not require
a below-limit success control, a no-limit control, cumulative smaller
allocations through the candidate lifetime graph, synchronization of lazy Metal
work, or proof that the observed failure was caused by the resource limit. On
this host's SDK, `RLIMIT_AS` is the `RLIMIT_RSS` alias. The local
`setrlimit(2)` manual describes `RLIMIT_RSS` as a resident-set limit under which
the system *prefers* to deprioritize an exceeding process when memory is tight;
it does not promise that a CPU or Metal allocation crossing the value fails.
A 10 ms physical-footprint sampler can observe and kill after a transient has
already crossed the stop, so it is not a synchronous cap either.

**Consequence:** A worker can pass the probe because the one large allocation
failed for an unrelated API, fragmentation, or lazy-evaluation reason, then
cross the planned boundary using multiple smaller or asynchronously committed
CPU/Metal allocations. R5 can therefore label a host hard-stop-capable without
evidence that the hard stop exists, reopening the first-run host-disruption
risk that R4 H1 required the revision to close.

**Required correction:** Stop treating `RLIMIT_AS` as a portable hard memory
cap. Name an authoritative exact-OS mechanism that synchronously constrains
both CPU and Metal committed memory, or explicitly classify the host as lacking
such a mechanism and define the resulting non-promoting boundary. Any empirical
cap qualification must include successful below-limit controls, a successful
unlimited/control-worker allocation, cumulative sub-limit allocations that
cross the cap, forced Metal synchronization, causal reason codes, and repeated
clean starts. Keep the a-priori ledgers, ramps, pressure monitoring, and worker
kill as independent defenses; none may be weakened to fix this finding.

### H2 -- Supervisor loss has no fence that can satisfy the required exit proof

**Severity:** High

**Evidence:** `test-benchmark-spec.md:111-130` makes the lifecycle supervisor
the worker's parent, sole PID/process-group owner, SIGKILL issuer, and
`waitpid` observer, but handles supervisor loss only with the phrase "fails
closed." Lines 155-173 require supervisor-loss/PID-reuse fixtures and actual
worker exit before reuse or publication, without specifying who kills,
identifies, and reaps the worker after that sole owner dies. The local
`waitpid(2)` manual confirms that a surviving worker is reparented to PID 1
when its parent exits and that `waitpid` observes children; a relaunched
supervisor cannot `waitpid` the orphaned old worker. `launchd.plist(5)` can kill
remaining members of a dead job's process group by default, but R5 does not
freeze the job/process-group membership, `AbandonProcessGroup=false`, worker
subprocess creation/exec protocol, launchd completion observation, or a durable
generation identity that excludes PID reuse.

**Consequence:** A supervisor crash can leave an old MLX/Metal worker alive
while the controller merely records a logical failure. A restarted supervisor
cannot produce the promised `waitpid` evidence, and a reused PID can be
mistaken for the old generation. The system then either deadlocks permanently
or publishes/reuses while physical computation from the failed generation may
still exist.

**Required correction:** Define one executable supervisor-loss protocol. For
example, make the worker and supervisor one launchd-owned process group with
the relevant launchd keys frozen, prohibit group escape, require launchd to
terminate the complete group, and specify how the controller receives durable,
generation-bound proof that the old job is gone before restart. If `waitpid`
cannot be observed after parent loss, replace that universal requirement with
an equally authoritative launchd/job-instance proof for this path while
retaining parent `waitpid` for normal fencing. Freeze boot/session-qualified
process identity, PID-reuse handling, controller and supervisor restart order,
durable request reconciliation, and real-process crash tests for every owner.

### H3 -- The pre-load envelope does not bound simultaneous stored, converted, and loader allocations

**Severity:** High

**Evidence:** The target pre-calibration ledger at
`test-benchmark-spec.md:612-630` correctly requires maximum-live allocation
sites and a lifetime-overlap graph. The separate first-load calculation at
lines 632-655 instead chooses the **maximum** of stored tensor bytes and runtime
dtype-expanded tensor bytes and adds one undifferentiated static loader bound.
It has no per-site lifetime graph for file-backed weight residency, converted
tensors, conversion scratch, staging, decompression, command buffers, or
temporary duplicate/tied-weight materialization. "Unknown conversion" fails
closed, but a known conversion in which source pages and expanded output coexist
is still represented by `max(stored, expanded)` rather than the maximum live
sum. Fixed percentage reserves are not a proof of that overlap.

**Consequence:** The very load-only runs needed to measure loaded idle can be
admitted below 70% on paper while their known conversion/load peak exceeds the
envelope. The later, stronger target ledger cannot protect this earlier step,
and H1's non-authoritative resource limit does not repair the undercount.

**Required correction:** Give `preload-budget-v1` its own generated
maximum-live ledger and overlap graph. It must separately enumerate source
mapping residency, expanded/converted tensors, scratch, tokenizer/config,
loader/runtime, Metal command/staging, caches, and duplicate/tied-weight
lifetimes, then compute the overflow-checked maximum live sum. A known
conversion requires a manifest-bound formula and coexistence interval; an
unprovable one fails closed. Define the unloaded-worker baseline sampling and
the exact pre-load manifest fields and arithmetic independently from the
post-load pre-calibration ledger.

### M1 -- The fixed-rate disturbance campaigns cannot guarantee their declared observation counts

**Severity:** Medium

**Evidence:** `SLOW-CONSUMER-500-R1` admits a request every 100 ms at the Entry
110 cap (`test-benchmark-spec.md:435-453`), while every fifth request must hold a
16-frame delivery queue long enough to block frame 17. `CANCEL-2000-R1` also
claims one admission every 100 ms and says its modulo assignment "yields 1,200
cancellation observations" (`:454-472`). At legal Entry 110 depths one through
four, however, the common pre-admission queue holds only `2 * slots_total` and
acceptance occurs only with a funded lease (`:67-86`). A fixed 10 requests/sec
arrival rate therefore does not imply acceptance, much less arrival at prefill,
decode, 25%/75% generation, or delivery-block boundaries. The 2K prompts and
up-to-256-token completions deliberately retain rows longer than the admission
interval. Warm-swap cells use the same fixed-rate wording and trigger by the
10th/20th/30th *admitted* request without defining what happens when saturation
rejects an arrival.

**Consequence:** A conforming implementation can correctly reject saturation
and still fail to produce the 1,000 cancellations required for promotable p99,
or two harnesses can count sent, queued, accepted, and boundary-reached requests
differently. The boundary fixes from R4 M2 are reproducible only after a request
reaches them; R5 does not make that precondition feasible or deterministic.

**Required correction:** Separate an open-loop saturation cell from
boundary-coverage cells. Freeze sent/accepted/rejected/boundary-reached counts
and expected reason codes for the open-loop cell. For cancellation,
slow-consumer, and warm-swap boundary evidence, use a deterministic
lease/queue-state-driven admission schedule or a preregistered rate proven
feasible for the exact tuple, while retaining the exact socket, queue, token,
and timing triggers. Require the full promotable observation count per boundary
class and ten clean starts; do not infer it from request indices.

### M2 -- Hierarchical intervals are computed but do not govern most promotion decisions

**Severity:** Medium

**Evidence:** `test-benchmark-spec.md:380-417` now freezes ten clean starts,
batch-preserving hierarchical resampling, and 50,000 resamples. But the actual
go/no-go rules at lines 761-776 compare only point medians and point p95 values
for MSB-02, MSB-03, the generic 1.3x uplift, and MSB-04. Except for the MSB-05
CI-width rule, R5 does not state which interval endpoint must clear which
threshold or set a maximum interval width. A campaign may therefore have an
arbitrarily wide cluster-aware interval while a favorable point estimate
promotes it.

**Consequence:** R5 fixes the pseudo-replication mechanics from R4 M3 but does
not make uncertainty decision-relevant. Ten highly variable starts can produce
the same promotion verdict as ten stable starts despite the newly required
interval showing that the uplift or tail bound is unsupported.

**Required correction:** Freeze decision statistics for each threshold. For an
uplift, require the hierarchical lower confidence bound to exceed the target;
for a latency ceiling, require the upper bound to remain below it, or define an
independently justified interval-width rule and an explicit inconclusive
outcome. Specify paired versus unpaired start handling for every baseline and
candidate comparison. Retain the point estimates for reporting only.

### M3 -- The loader event closure assumes an unimplemented pre-runtime callback boundary

**Severity:** Medium

**Evidence:** `test-benchmark-spec.md:256-276` requires dyld add/remove-image
callbacks to be installed "before any runtime initialization" and treats them
as proof that no transient load/unload can evade capture. Yet the reviewed
package is a Swift/MLX process whose executable dependencies and initializers
begin loading before ordinary program control can install such a callback. R5
does not name a pre-main audit shim, dyld insertion mechanism compatible with
the signed/sandboxed release, synchronous callback-to-controller durability
protocol, or behavior when the bounded evidence IPC is unavailable. Static
`otool` closure does not cover a transient `dlopen` performed by an initializer,
which R5 itself lists as a mandatory negative case.

**Consequence:** The promised actual-loaded-image history may have an
unobservable startup interval or lose the final event on worker/controller
failure. The exhaustive immutable tree still binds all adopted bytes, but the
stronger claim that the result proves every non-platform image actually loaded
and unloaded is not executable as written.

**Required correction:** Define the earliest executable capture owner and prove
it precedes every non-platform initializer, or narrow the claim and use a
launch-time interposition/audit helper whose bytes, entitlements, environment,
and package identity are themselves in the protected closure. Require
synchronous sequence/ack persistence before plugin code proceeds, define IPC
backpressure/controller-loss behavior, and add an early-constructor transient
load/unload fixture in addition to the later plugin-registration fixture.

## Prior-finding closure and retained strengths

| Prior area | R5 result |
|---|---|
| Entry 110 legality and hardware claims | Closed. The four-row dense path is limited to a same-host Ultra >=128 GiB tuple, and all larger-model/fleet extrapolation remains prohibited. |
| Workload and executor mapping | Closed. MSB-01 through MSB-05 preserve the reviewed serial, candidate shared-forward, MoE, and oracle roles. |
| SPEC status and activation boundary | Closed. SPEC-038/039 remain pending and the feature, capacity advertisement, release, and production activation remain outside this assessment. |
| Queue-inclusive epoch arithmetic | Closed for a healthy supervisor. Accepted work is limited to concurrent grants whose deadlines predate the opposite waiter; there is no sequential accepted backlog. Supervisor loss remains H2. |
| First-run memory admission | Partially closed. The target ledger and staged ramps are materially stronger, but the OS cap proof and pre-load overlap bound remain H1 and H3. |
| Loader custody | Substantially closed. Exhaustive regular-file manifests, broker-only writable custody, read-only attach, unlink, and post-run recapture close the prior backing-byte substitution issue. Runtime event capture remains M3. |
| Cancellation/backpressure triggers | Partially closed. Exact in-request markers are now frozen, but the arrival/admission schedule cannot guarantee those markers or counts, leaving M1. |
| Cluster-aware inference | Partially closed. Resampling preserves clean starts and whole batches, but most go/no-go decisions ignore the resulting intervals, leaving M2. |
| Correctness, rollback, observability, and claim boundaries | Closed at assessment level. Exact-token MoE parity, protected release identity, failure cleanup, truthful unknown state, remote-data safeguards, and no-activation boundaries remain explicit. |

## Disposition

Build 5 remains an assessment-only lane. The current 32 GiB host can support
contract work, deterministic scheduler/allocator tests, fixtures, and exact
small-model development evidence after the bridge and immutable harness exist.
Paged KV and continuous batching remain disabled. Representative capacity,
large-model memory/performance, release qualification, and production rollout
remain unproved.

Revise the assessment and benchmark specification to close H1-H3 and M1-M3,
freeze new digests, and rerun an independent GPT-5.6 Sol gate. Do not implement
or qualify the throughput engine from R5.
