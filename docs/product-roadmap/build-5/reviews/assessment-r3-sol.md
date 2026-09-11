# Product Build 5 assessment R3 independent adversarial review

Date: 2026-09-11

Reviewer lane: independent GPT-5.6 Sol, high reasoning

Reviewed repository commit: `30d187fc1b07f270373afa30bd83690292b599c8`

Repository source base: `1d2c930bad81704dd0acc0322226725d8b64aceb`

## Frozen inputs

| Artifact | SHA-256 |
|---|---|
| `feasibility-assessment.md` | `4c9f2e3a9562603efa26a3dfff3a4ce6cd9cdc123099bd441e4ee5ae578e2eeb` |
| `test-benchmark-spec.md` | `bd2c6f3044960671de19a7033422239c6b2691dae71aa52a16cb0e99f7fc0c96` |
| `current-state-evidence.md` | `11a0039bb8201f434e6c20f3fdf043e2209b38a5171813ff60ccfc12d24cb77a` |
| `assessment-r2-dispositions-r3.md` | `a87cab5340c22fe03d96934ceaf7d9825b55411399b658ab8977f04cd3bcf8d6` |
| `assessment-r2-sol.md` | `9c7a211bce4dffd64a821fab94b6203b0faa6708aa1c7e188d112686bc2684af` |
| `real-mlx-3b-exploratory-r3.log` | `b7bc70a4b7f89b9620b08d1ffa7941a3c49e0fd6b1032f4440dd93dd9089dd95` |

The frozen document digests matched the committed tree. The review inspected
the implementation and authority sources independently, including
`AutotuneRecommendHardware.recommendedMaxBatch`, `ModelRuntime`, the scheduler
and paged-engine sources and tests, SPEC-038, SPEC-039, `CONFORMANCE.json`, the
continuous-batching enable runbook, RESEARCH_232's MSB definitions, the release
toolchain and package-verification scripts, and the exact local 3B inventory.
It did not inspect `d-inference`.

The Entry 110 mapping was independently confirmed as 1 for base chips, 2 for a
Max with at least 48 GiB, 3 for an Ultra with at least 96 GiB, and 4 for an
Ultra with at least 128 GiB. The three KV calculations are also correct at 112,
144, and 96 KiB/token. The six-file 3B manifest, prompt, harness, package lock,
and raw-log hashes were recomputed and matched the R3 record. The result remains
correctly classified as exploratory. Live PR #894 was independently observed
open, draft, merge-conflicting, and with a failed `spec-index / check`; it is
not merged evidence.

## Verdict

**FAIL — R3 is not approved for implementation or qualification use.**

Finding counts: **0 Critical, 1 High, 3 Medium, 0 Low**.

R3 closes the prior impossible-hardware matrix, the core serial/batch ownership
split, the MSB executor mapping, SPEC-039 status, MoE token-parity rule, and full
protected release-package boundary. The findings below prevent the required
zero-Critical/High/Medium plan gate.

## Findings

### H1 — Memory promotion still depends on an under-specified calibration

**Severity:** High

**Evidence:** `test-benchmark-spec.md:279-342` defines the fields and envelope
arithmetic, but it never defines how `loaded_idle_phys_footprint_bytes` and
`loaded_idle_mlx_active_cache_bytes` are selected from the sampled pre-window,
how many calibration dry runs are required, how their process starts and arm
order are controlled, or the minimum valid samples needed before taking the
maximum target delta. Lines 329-338 permit an unspecified number of dry runs,
then freeze their maximum. Lines 344-350 sample every 100 ms but do not define
whether the process peak is the maximum of those samples or supplement it with
an authoritative high-water source. The warm-up procedure at lines 261-265
records an idle baseline before loading, while the memory formula requires a
loaded-idle baseline; the relationship is not fixed. The assessment nevertheless
calls the algorithms exact at `feasibility-assessment.md:168-170`.

**Consequence:** Two conforming operators can select different baselines and
calibration counts, producing different envelopes for the same tuple. A low
sample or transient missed between polls can understate the admission bound and
allow a promotion run closer to unified-memory failure than the declared gate.
Because this value controls whether a real large-model cell may start, the
remaining ambiguity is a safety and qualification blocker rather than merely a
reporting detail.

**Required correction:** Freeze a calibration protocol before any result:
define loaded-idle as a specified aggregation over a post-load, post-warm-up
window; require a fixed minimum number of exact-shape dry runs across fixed
clean starts and retain failures; define the aggregation across runs; bind
process-start state and cache-reset rules; and state exactly how 100 ms samples
and any process/MLX high-water counters form the recorded peak. Reconcile the
ten-minute host-idle baseline with the loaded-model pre-window. If a platform
cannot provide a trustworthy process high-water measure, add a conservative
sampling allowance justified before the campaign rather than silently treating
polling as a continuous maximum.

### M1 — Future artifact identity does not bind the complete bytes consumed by the loader

**Severity:** Medium

**Evidence:** `test-benchmark-spec.md:138-152` hashes every *declared* relative
file and later loads from the snapshot path. It does not require the declaration
to cover every regular file or every transitive file named by a weight index,
tokenizer/config/template reference, nor does it reject undeclared loadable
files. It also does not specify immutable staging, open-handle binding, or a
post-run identity recapture between verification and the loader reopening the
path. `current-state-evidence.md:108-114` repeats exact-revision selection and
hash verification but leaves these closure and time-of-check/time-of-use rules
open.

**Consequence:** A manifest may remain stable while the loader consumes an
omitted or replaced file, or while a cache symlink/target changes after hashing.
The active SPEC-039 descriptor could then attest to bytes other than those that
produced parity or performance evidence.

**Required correction:** Define an exhaustive loader dependency closure and
reject undeclared loadable files, including every shard referenced by an index
and all tokenizer/template/config inputs. Canonicalize and validate relative
paths before hashing. Load only from an immutable adopted/staged snapshot bound
to that manifest, or recapture file identity and content after the run with an
explicit no-mutation invariant. The descriptor and result must bind that exact
closed manifest.

### M2 — Several promotion workloads and reference gates remain non-reproducible

**Severity:** Medium

**Evidence:** The R3 protocol defines fixed counts for MSB repetitions and
several disturbance schedules, but `test-benchmark-spec.md:246-257` gives no
prompt/output/concurrency/arrival schedule for `SLOW-CONSUMER-500`, no
prompt/output/arrival schedule for `CANCEL-2000`, and no exact workload shape
for the three warm-swap and failure-injection cells. No per-request or per-cell
timeout is fixed. The MSB-03 short-request gate at lines 193 and 378-379 depends
on a same-host 512-token single-request baseline that is not a named cell and
has no required repetitions. The MSB-01 stability criterion from
RESEARCH_232 — TG coefficient of variation at most 10% — is absent from the
go/no-go list at lines 372-393 even though an unstable baseline can decide every
dense uplift ratio.

**Consequence:** Different harnesses can run materially different load while
using the same cell ID, and an unstable or sparsely measured baseline can
promote MSB-02/03. A hung cell also has no deterministic terminal
classification deadline. This leaves the prior statistical/workload finding
only partially resolved.

**Required correction:** Give every disturbance and reference workload a
versioned cell ID with exact prompt bins, output ceilings, arrival/concurrency
schedule, timeout, repetition/request count, and retained terminal outcomes.
Define and sample the 512-token single-request TTFT reference on the same
host/artifact. Restore the MSB-01 CV stability gate or replace it through a
reviewed normative change with a preregistered equivalent that prevents an
unstable denominator from promoting a tuple.

### M3 — The arbiter's starvation-free claim has no bounded execution-liveness contract

**Severity:** Medium

**Evidence:** `test-benchmark-spec.md:67-74` claims a bounded, FCFS mode-change
queue and starvation freedom, but explicitly proves the handoff only in
transition counts rather than time. Lines 75-97 require cancellation safety and
test an executor that temporarily ignores cancellation, yet no model-forward,
request, cancellation-acknowledgement, or drain deadline defines when
`serialRunning`, `batchRunning`, or `draining` must leave the active state. The
go/no-go section measures cancellation p99 but supplies no acceptable bound.

**Consequence:** Mutual exclusion can be correct while an active forward or
cancellation-insensitive executor permanently prevents the opposite mode,
recovery, or warm swap. A transition-count assertion never fires when the next
transition never occurs, so it cannot prove the stated starvation-free user
journey.

**Required correction:** Scope starvation freedom to terminating forwards and
add explicit forward/request/cancellation/drain deadlines with a fail-closed
terminal transition for non-termination. Freeze the cancellation-acknowledgement
and mode-handoff thresholds used for promotion, then test an executor that
exceeds each deadline and prove no lease reuse, late output, or unsafe swap.

## Closure status of the R2 findings

| R2 finding | R3 result |
|---|---|
| H1 Entry 110 legality | Closed. The M5 and Max lanes stay within 1/2 rows; the frozen four-row dense campaign uses a same-host Ultra >=128 GiB baseline and candidate. |
| H2 missing arbiter | Core ownership and mutual exclusion closed; bounded execution liveness remains M3 above. |
| H3 MSB arm mapping | Closed. MSB-01/02/03/04/05 map to the correct executors and workloads; candidate-versus-oMLX uses a new ID. |
| H4 memory gate | Partially closed. Fields, checked arithmetic, pressure signals, and recovery tolerance are strong; calibration selection remains H1 above. |
| M1 SPEC-039 status | Closed. Draft, pending reconciliation, and R001-R014 unmapped are stated throughout. |
| M2 3B evidence | The current result is honestly exploratory and its observed bytes match; future authoritative loader binding remains M1 above. |
| M3 statistics/workloads | Partially closed; the remaining cells and reference gates are M2 above. |
| M4 MoE tolerance | Closed. Exact greedy tokens and terminal/accounting equality are mandatory; raw logits are diagnostic only. |
| M5 release identity | Closed. Protected toolchain, final dual-package binary/resource identity, signing/notarization/stapling/Gatekeeper, and previous-stable updater coverage are required. |

## Disposition

The assessment remains a useful and conservative feasibility framework, and
its current claim boundary is truthful: no runtime bridge, representative
capacity, throughput uplift, release qualification, or production activation
is proved. No engine, configuration, scheduler, release, procurement, remote
transfer, or economic action is authorized by this review.

Revise the assessment/test specification to resolve H1 and M1-M3, freeze new
exact digests, and obtain another independent GPT-5.6 Sol gate. Larger-hardware
absence, the exploratory 3B pass, fixtures, and historical runs remain named
blockers rather than passing qualification evidence.
