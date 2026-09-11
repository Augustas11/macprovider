# Product Build 5 staged feasibility assessment

Date: 2026-09-11

Assessment revision: `build5-assessment-r5`

Repository base: `1d2c930bad81704dd0acc0322226725d8b64aceb`

## Decision

Development can safely continue before a 64 GB+ Mac is available, but only on
the contracts, allocator/scheduler correctness, fail-closed runtime bridge,
unsupported-feature routing, deterministic accounting, packaging, fixtures,
and small-model real-inference lanes defined below. The production backend and
capacity advertisement must remain disabled until its exact
model/artifact/runtime/OS/hardware tuple passes the representative-hardware
gate.

Sixty-four gigabytes is not a universal prerequisite. It is unnecessary for
deterministic scheduler tests, allocator failure tests, simulated memory
pressure, serial fallback, packaging checks, or small 3B/8B real inference. It
is required, or may still be insufficient, when the claim concerns a target
large model at long context and useful concurrency with operating-system,
activation, gather, queue, and thermal headroom. The target tuple determines
the hardware requirement.

## User journeys and ownership boundaries

The covered operator journey is:

1. The operator installs a release candidate with batching off.
2. Startup verifies the exact model, tokenizer, MLX revisions, metallib,
   paged-engine descriptor, Entry 110 row cap, and memory-pool configuration.
3. Unsupported tuples remain on the unchanged serial path or fail closed under
   explicitly selected strict mode before output.
4. A supported canary accepts bounded work into one scheduler shared by HTTP
   and relay ingress, binds each request to its served snapshot, and reserves
   only its governed initial block footprint. One generation-scoped execution
   arbiter grants either serial leases or the shared-batch lease; the two modes
   never overlap on the resident model.
5. Per-request sampling, cancellation, token delivery, usage, receipt, and
   block release remain isolated during shared forwards.
6. Failure drains or reason-codes affected work without cross-request output or
   accounting, and the next eligible request safely uses the serial path.
7. Capacity is advertised only after the exact production tuple passes the
   separately authorized enable gate.

Authority remains divided as follows:

| Owner | Boundary |
|---|---|
| SPEC-039 paged engine | Physical blocks, free list, table validation, gather kernel, descriptor, extraction/retention primitive, bounded pool. |
| SPEC-038 scheduler | FCFS queue, active rows, request-to-handle lifecycle, shared forward, cancellation, output/accounting isolation, failure drain. |
| `ModelRuntime` and its future resident-model arbiter | Loaded artifact and generation snapshots, feature classification, one mutually exclusive serial/batch execution authority, warm swap, recovery, and HTTP/relay common admission. |
| SPEC-023 Entry 110 | Maximum active-row recommendation. It is an upper bound, not evidence that memory can fund every row. |
| SPEC-015/SPEC-005/SPEC-024 | Receipt, billing, and prefix-cache semantics. Build 5 must preserve them and cannot add a batch identity to money-path authority. |
| Release/tooling | Exact dependency and metallib packaging, candidate identity, reproducible evidence bundle. |
| Operator enable gate | Decides whether one prequalified tuple may serve canary traffic. Code merge alone cannot activate it. |

## Dependency graph

```text
SPEC-039 accepted conformance + allocator/cache/descriptor/gather parity
        |                         |
        |                         +--> packaged metallib proof
        v
SPEC-038 accepted conformance + scheduler/shared-forward executor
        |             |                   |
        |             |                   +--> per-request usage/receipt isolation
        |             +--> HTTP and relay common queue
        v
ModelRuntime fail-closed bridge + supported-feature classifier
        |
resident-model execution arbiter (serial XOR batch for one generation)
        |
        +--> SPEC-023 Entry 110 cap and pool admission
        +--> SPEC-024 same-conversation handling
        +--> SPEC-028 mutual exclusion
        +--> serial fallback and warm-swap drain
        v
release-candidate integration -> representative hardware gate -> separate enable decision
```

No throughput work may depend on draft PR #894 being merged. Its useful pieces
must first be rebased onto current main, reconciled with later request/privacy
changes, and reviewed as a new complete diff. Its current failed governance
check and merge conflict are blockers, not waivers.

## Evidence matrix

| Work or claim | Designable now | Testable on current 32 GB Mac | Fixture or CI evidence | Representative 64 GB+ evidence | Current disposition |
|---|---:|---:|---:|---:|---|
| Allocator invariants, table validation, reclaim, exhaustion | Yes | Yes | Yes | No | Proceed now. |
| FCFS, bounded queue, row lifecycle, idempotency, cancellation, request isolation | Yes | Yes | Yes | No | Proceed now. |
| Simulated block pressure and exact recovery | Yes | Yes, using a deliberately small pool | Yes | No | Proceed now; never label it OS-memory evidence. |
| Fail-closed runtime capability and reason-coded serial routing | Yes | Yes | Yes | No | Proceed now. |
| HTTP and relay using one queue/accounting authority | Yes | Yes with deterministic executor | Yes in cross-service harness | Yes for performance | Build and test before backend enable. |
| Real paged gather parity on Llama 3B | Yes | Yes; one exact-byte-inventoried 40-token run exists | CI only if it has MLX artifact and metallib | No | Exploratory only: current harness scans the first snapshot and inserts dummy descriptor hashes. |
| Real paged gather parity on local Qwen3 8B | Yes | Likely, in a maintenance window | Usually no due artifact/hardware | No | Unproved; define and run a separate cell. |
| Real shared-forward correctness on 3B/8B | Yes | Yes after the runtime bridge exists | Fixture executor can prove orchestration, not MLX numerical behavior | No | Feature-gated until implementation and real test. |
| Relative 3B/8B throughput on this M5 Air | Yes | Yes with a clean, thermally controlled window | No | No | Useful development signal; not fleet or large-model evidence. |
| 30B MoE or dense 32B long-context concurrency | Yes | Not safely/representatively on this active 32 GB host | Fixtures cannot prove it | Yes, on selected target hardware | Blocked on host, verified artifact, and legal Entry 110 row authority. |
| Large-model memory-servability improvement | Yes | No | Analytical/simulated data cannot prove it | Yes | Unproven. Gather-feeds-SDPA may increase transient peak. |
| Fleet-wide capacity or earnings improvement | No, without workload/fleet study | No | No | One host is still insufficient | Out of scope and unproven. |
| Production scheduling or capacity advertisement | Can design gate | Must remain off | CI cannot authorize it | Required but not sufficient | Deferred to separate reviewed activation. |

## Hardware-conditioned workload decision

The current Entry 110 mapping in `AutotuneRecommendHardware.recommendedMaxBatch`
is one row for a base chip, two for a Max with at least 48 GiB, three for an
Ultra with at least 96 GiB, and four for an Ultra with at least 128 GiB. SPEC-038
FR-CB11 makes that persisted value the exact active accepted/runnable cap; a
benchmark cannot synthesize a larger serving tier.

This resolves the conflict between the historical M4 Max 64 GiB MSB-01 target
and the four-row MSB-02/03 workload:

| Lane | Legal work | Result scope |
|---|---|---|
| Current M5 Air 32 GiB | Real 3B/8B single-row parity, memory instrumentation, serial fallback, fixtures at artificial depths | Development evidence; concurrency 2/4 is fixture-only and never a live-serving qualification. |
| Max >=48 GiB | Depth-two development workloads and MSB-04/MSB-05 only when the exact artifact passes preflight | Tuple-specific depth-two evidence. It cannot claim MSB-02/03 replication. |
| Ultra >=128 GiB | Same-host MSB-01 serial baseline followed by candidate MSB-02/03 at four rows, provided the declared memory manifest passes | The first currently legal path to the frozen four-row dense qualification. |
| Other Ultra tiers | At most the persisted one/three-row value | New development IDs; no four-row MSB substitution. |

The alternative is a future normative SPEC-038 amendment for an isolated
non-serving benchmark mode that cannot advertise capacity or accept buyer
traffic. No such mode exists. Until one lands, four-row work on M4 Max is
blocked. All comparisons use the same host and exact artifact; cross-host
baselines are invalid.

## Analytical memory budget

For fp16 K/V, a decoder layer's logical KV bytes per token are:

```text
KV_bytes_per_token = 2(K,V) * layers * kv_heads * head_dim * 2 bytes
KV_bytes(row, tokens) = KV_bytes_per_token * tokens
```

Weight quantization does not quantize KV. Current batching rejects `kv_bits`,
so fp16 is the only valid planning basis. Every future measured cell freezes a
`memory-budget-v1` manifest before promotion runs. It contains exact installed
RAM and OS reserve; verified artifact bytes; loaded-idle process physical
footprint; an exact-shape calibrated total peak delta with separate
activation/gather/KV diagnostics; prompt plus
output plus holdback tokens per row; block fragmentation; queue/delivery
allowance; MLX limits; one 10% measurement allowance; sampling periods; and
post-drain bounds.

The non-duplicating envelope is:

```text
M_process_subtotal = M_loaded_idle_physical_footprint
        + M_calibrated_target_peak_delta
        + M_delivery_and_queues
M_process_envelope = M_process_subtotal + ceil(10% * M_process_subtotal)
M_hard = min(floor(85% * installed_RAM), installed_RAM - M_OS_reserve)
```

Loaded idle already includes resident weights, runtime, and MLX caches, so
those values are never added again. The calibrated target delta is the larger
of observed exact-shape process growth and analytical KV pool bytes; it already
contains activation, KV, executor, and transient gather effects, so those
diagnostics are not summed again. The planned cell
must satisfy `M_process_envelope <= M_hard`; sampled
`proc_pid_rusage(RUSAGE_INFO_V4).ri_phys_footprint` must remain under both.
`MLX.Memory.activeMemory/cacheMemory/peakMemory` are sampled as diagnostic
subsets and are never added to process footprint. Exact algorithms, 100 ms
sampling, pressure/thermal/swap aborts, and 120-second recovery tolerances are
fixed in `test-benchmark-spec.md`.

Current gather-feeds-SDPA restores contiguous K/V before stock attention, so
its transient gather term must be measured. It cannot support a peak-memory-
reduction claim.

The calibration algorithm is executable and frozen only after an independent
pre-calibration gate passes. A signed `precalibration-budget-v1` uses the
measured loaded-idle footprint, analytical full-pool KV, bounded queues, an
overflow-checked maximum-live allocation ledger for every activation, gather,
logit, staging, command-buffer, and cache site, a `max(4 GiB, 25%)` runtime
reserve, and a separate 25% bootstrap allowance. It never consumes the future
calibrated peak. An opaque or unbounded allocation fails closed. The target
must fit both 70% of RAM and the final hard limit before target-shaped work.
Loaded idle is itself admitted by an immutable-weight-metadata pre-load ledger
with dtype expansion, loader/runtime/tokenizer bounds, fixed reserves, and the
same process hard-stop; unknown conversion or allocation forbids model load.
Three fresh-worker ramps at 25%, 50%, and 75% precede five exact-shape dry runs.
The exact-shape runs use five clean worker starts. Each start first records ten
unloaded host minutes,
then loads the adopted read-only artifact, performs five fixed warm-ups, holds
nominal/fair thermal state for 60 seconds, and captures exactly 600 paired
loaded-idle samples at 100 ms. Per-start loaded idle is the sample maximum;
the manifest uses the maximum across starts. Each target delta subtracts its
own start's loaded-idle maximum from the maximum of sampled physical footprint
and the process lifetime physical-footprint high-water; the campaign uses the
maximum of all five deltas and analytical KV pool bytes. No failed calibration
run is replaced. A platform without the lifetime high-water counter adds the
separate frozen polling-gap allowance defined in the test specification and
remains development-only. The unloaded window diagnoses ambient host state; it
never substitutes for the post-load baseline in the envelope. Calibration
executes in a separate MLX worker. A lifecycle supervisor sets and first proves an
exact-OS `RLIMIT_AS`/Metal allocation hard-stop, applies the MLX cache bound,
watches physical footprint and memory pressure at 10 ms, kills the worker at
the frozen stop, and observes exit. If the hard-stop probe does not cover CPU
and Metal unified-memory allocations, the host cannot run target-shaped
calibration.

| Model/config assumption | fp16 KV/token | 8K row | 32K row | 64K row | 128K row |
|---|---:|---:|---:|---:|---:|
| Llama 3.2 3B: 28 layers, 8 KV heads, head dim 128 | 112 KiB | 0.875 GiB | 3.5 GiB | 7 GiB | 14 GiB |
| Qwen3 8B: 36 layers, 8 KV heads, head dim 128 | 144 KiB | 1.125 GiB | 4.5 GiB | outside local 40,960-token declaration | outside local declaration |
| Qwen3-Coder-30B-A3B planning tuple: 48 layers, 4 KV heads, head dim 128 | 96 KiB | 0.75 GiB | 3 GiB | 6 GiB | must verify artifact limit |

The first two configurations were read from the available local MLX snapshots.
The 30B configuration is a planning input from the repository's prior research
and must be revalidated against the exact benchmark artifact before use.

For block size `B`, each active row allocates
`ceil(tokens / B) * B` token capacity. Internal fragmentation is less than one
block per row, but allocator metadata, per-layer arrays, snapshots, and
transient gathers add memory beyond logical KV. A shared-pool design must model
heterogeneous row lengths; multiplying one average row by concurrency hides
the tail risk.

Example implications, before weights and overhead:

- Four 32K Llama 3B rows require about 14 GiB of logical KV.
- Four 32K Qwen3 8B rows require about 18 GiB of logical KV.
- Eight 64K rows for the stated 30B MoE geometry require about 48 GiB of
  logical KV alone.

These are sizing calculations, not claims that the models, contexts, or row
counts run. The exact tokenizer limits, RoPE configuration, weight residency,
activation peak, gather peak, and operating-system reserve must be measured on
the candidate artifact and host.

## Safe implementation stages before larger hardware

### Stage A — contracts and deterministic implementation

Work that can proceed now:

- reconcile every pending SPEC-038 and SPEC-039 requirement and conformance
  entry with the actual bridge design before writing runtime code;
- implement one single-owner runtime bridge behind the existing default-off
  capability, with no second HTTP/relay queue;
- implement one generation-scoped execution arbiter as the sole issuer of
  resident-model leases. Its modes are idle, serial-running, batch-running,
  draining, and failed. A bounded pre-admission queue is exactly twice Entry
  110 and independently capped at 1,048,576 queued tokens; acceptance occurs
  only with a funded lease, so no accepted backlog can
  add sequential 900-second waits. Opposite-mode selection closes the current
  epoch, retryably rejects every current-mode pre-admission entry in enqueue
  order plus new same-mode work before acceptance, resolves any migrated
  accepted-queued entry under its old snapshot within 250 ms, and drains at
  most Entry 110 already granted requests under their original queue-inclusive
  deadline. Cancellation releases only after executor exit; failure and warm
  swap drain before a new generation. The contract fixes 120-second forward
  and 900-second enqueue-to-terminal deadlines, atomic opposite-mode admission
  closure with 250 ms acknowledgement,
  250 ms queued cancellation,
  5-second active cancellation acknowledgement, 1-second post-
  quiescence handoff, 30-second quiescent drain, 10-second process fencing,
  900-second waiter disposition, and 915-second old-accepted-work
  reconciliation. A waiter is granted within one second after quiescence only
  while its queue-inclusive deadline remains; otherwise it receives a truthful
  `mode_wait_timeout`. The selected architecture is a controller-owned admission
  and
  durable-disposition process plus a separate MLX inference worker. The worker
  alone owns model/Metal/scheduler state; replacement or publication requires
  supervisor-observed `waitpid` exit, not a logical fence callback. A launchd-
  owned lifecycle supervisor owns the worker PID/process group and fences it
  even if the controller exits; the relaunched controller reconciles its durable
  accepted-request log before publishing a generation;
- preserve the serial path and strict/canary behavior;
- bind accepted and queued work to the model/tokenizer/weights generation;
- prove per-request output, stop, usage, receipt, cancellation, and block
  release isolation with a deterministic executor;
- test heterogeneous row lengths, queue saturation, initial-reservation
  pressure, extension failure, warm swap, and scheduler failure;
- preserve reason-coded serial routing for tools, structured output,
  logprobs, logit bias, sticky cache until its bridge exists, quantized KV,
  speculative decoding, unadvertised tuples, and MoE without promotion
  evidence;
- make telemetry aggregate and sanitized: configured row cap, pool capacity,
  active/queued counts, allocator high-water mark, reason codes, scheduler
  generation, and fallback count, without prompts, tokens, buyer identity, or
  block contents.

Any architecture or contract change must reopen the plan gate and update the
normative SPEC before its implementation.

### Stage B — small-model real inference on 32 GB

After Stage A passes deterministic tests, run real 3B and selected 8B cells in
an operator-approved maintenance window at their persisted Entry 110 cap
(one row on the current M5 Air). Prove token/output/usage parity,
cancellation, request isolation, mixed-length fairness, memory-pool bounds, and
serial recovery. These results can qualify only the exact small-model tuple.

Use the packaged release-candidate path as a separate test from SwiftPM. The
fresh SwiftPM parity pass required manually placing a metallib in the test
bundle. Its source also selects the first snapshot directory and creates a
descriptor with zero model/metallib hashes. The R3 evidence inventory binds
the observed bytes, but the result remains exploratory. A qualifying harness
must require the exact snapshot revision and use only an adopted read-only APFS
image containing the entire model snapshot, signed runtime package, and frozen
campaign directory. Its closed loader manifest recursively binds every regular
file in the model, runtime, and campaign trees. A privilege-separated adoption
broker is the sole writer, closes all write descriptors, attaches read-only,
unlinks the inaccessible backing pathname, and proves no writable descriptor
or attachment remains. Static `otool` closure and actual loaded Mach-O/plugin
snapshots bind every resource, metallib, executable, dependency/runtime-
selection, and non-platform dynamic-library byte. It rejects symlinks,
unreferenced shards, custom/remote code, undeclared selectors, and any pre/post
identity or content mutation, derives non-dummy descriptor hashes, and rejects
ambiguity before load.

### Stage C — integration and release candidate

Run local HTTP and relay ingress through the same scheduler, arbiter, and
capacity accounting. Validate streaming and non-streaming output, disconnect
recovery, warm swap, idempotency, receipts, and feature fallback. Build using
the protected Xcode 16.4 (16F6), Swift 6.1.2, macOS SDK 15.5 path with locked
dependencies. After final signing, notarization, stapling, and packaging,
extract the standalone and Malibu.app deliverables and prove the two embedded
CLI binaries are byte-identical and their metallib/dependency identities
match. Run codesign/stapler/Gatekeeper and previous-stable updater gates. The
current Xcode 26.6 SwiftPM evidence is development-only. This stage may
establish release readiness for a disabled feature, not capacity
qualification.

### Stage D — representative hardware qualification

On each candidate large-hardware tuple, run the predeclared benchmark cells in
`test-benchmark-spec.md`. Dense and MoE results are separate. A result for a
smaller or more heavily quantized model cannot qualify a larger model. A result
on 64 GB cannot qualify a 128/192/256 GB tier or a different chip generation.
MSB-01 is the current single serial iterator; MSB-02/03 are the candidate
shared-forward identical/ragged workloads; MSB-04 compares the live MoE's
serial baseline and candidate shared forward; MSB-05 compares current native
two-iterator behavior with pinned oMLX. A candidate-versus-oMLX experiment gets
a new ID and cannot overwrite MSB-05. MoE correctness requires identical
greedy token IDs and terminal/accounting results; there is no adjustable output
tolerance.

The campaign freezes generators, arrival/cancellation/slow-consumer schedules,
exclusions, and statistics before results. Promotion tails use at least 100
valid repetitions/requests for p95; p99 is promotable only at 1,000 observations.
All promotable intervals require at least ten independent clean-start clusters.
The hierarchical bootstrap selects starts and then complete repetitions while
preserving every row of a shared batch together. MSB-05 uses 100 paired runs and
a fixed-seed 50,000-resample hierarchical paired percentile bootstrap.
Request-level resampling is descriptive only. Smaller samples report
descriptive unavailable tails and cannot promote a tuple.

The versioned disturbance matrix fixes all prompt bins, output ceilings,
arrival cadence, concurrency cap, request/cell timeouts, request count, clean-
start count, and injection boundary. It includes `REF-TTFT-512-R1`,
`SLOW-CONSUMER-500-R1`, `CANCEL-2000-R1`, the three `WARM-SWAP-*-R1` cells,
three whole-batch decode-step failures, and three request-local extension
failures. Slow consumption freezes the socket receive buffer, 256-byte read
size, first-read offset, 100 ms cadence, 16-frame delivery queue, and producer-
blocked marker. Cancellation freezes 256-token prefill chunks, exact token
indices, queue occupancy 16, and the attempted seventeenth frame; a missing
boundary is a failed cell. MSB-01 additionally requires aggregate-TG
coefficient of variation
at most 10%; an unstable baseline cannot promote MSB-02/03.

### Stage E — separately authorized canary

Only after Stages A-D, audits, and applicable SPEC gates may a later task
propose an allowlisted canary for the exact qualified tuple. Enabling production
scheduling, raising advertised capacity, and making capacity claims are not
part of Product Build 5 assessment.

## Failure, rollback, and observability contract

The rollback unit is the default-off batching configuration plus the existing
serial generation path. Startup must reject an inconsistent descriptor, pool,
artifact, dependency, or metallib tuple before accepting work. Once a request
has emitted output, it cannot be replayed through a different executor as a
transparent fallback; terminate it with a reason-coded request-local error and
clean up its state. Requests with no visible output may use only the explicitly
specified idempotent recovery path.

Serial fallback is mediated by the same execution arbiter as batching. It is
not an independent escape hatch: the resident generation is always in serial
or batch execution mode, never both. The provider controller owns admission,
durable request dispositions, receipts, and generation publication. A separate
inference worker exclusively owns MLX, Metal, scheduler, pool, and leases over
versioned bounded local IPC. A launchd-owned lifecycle supervisor exclusively
owns the worker PID/process group and performs the exit fence even on controller
loss. Scheduler failure moves it to draining;
only invisible request-local work may reacquire a serial lease after full
quiescence. A deadline overrun fails the generation; the controller requests
exit, the supervisor sends SIGKILL by ten seconds and observes `waitpid`, and
the controller durably resolves all
accepted request IDs before replacement. A callback without observed process
exit grants no fencing authority. No in-process lease or resident model is
reused. Warm
swap similarly requires old-worker exit and all leases, accepted work, blocks,
queues, and delivery tasks to resolve before the generation changes. A timed-
out swap leaves the new generation unpublished.

Cancellation must be tested while queued, during prefill, during decode, and
after the delivery side disconnects. No token may be emitted after cancellation
acknowledgement; no receipt may claim ungenerated tokens; all blocks and row
state must return to the known baseline.

Fresh telemetry must distinguish `disabled`, `eligible_serial`,
`eligible_batched`, `strict_rejected`, `fallback_after_failure`, and
`qualification_unknown`. Missing or stale measurement is `unknown`, never
evidence of spare capacity. Logs and evidence bundles contain hashes and
aggregate counters, not request content.

Memory measurements use process physical footprint as the total and MLX
active/cache/peak as non-added diagnostics. Any critical VM-pressure sample,
sustained serious/critical thermal state, swap-out increase, manifest bound
crossing, or failure to return to the frozen post-drain baseline fails the
cell. A failed load/performance run remains evidence and is never excluded as
"environmental" after admission.

## Migration and compatibility

This assessment creates no runtime or data migration. A future implementation
must keep new configuration additive, default-off, and reject invalid or
partially specified state at startup. It must not mutate receipt, billing,
request, model-identity, or persisted SPEC-037/SPEC-024 formats. If paged state
ever becomes persistent, its codec ID and ABI epoch require their own governed
compatibility change; scheduler block tables cannot silently enter today's
serial opaque-record format.

Upgrade testing must cover the previous stable binary reading unchanged
configuration and persistence, the candidate binary starting with batching
off, rollback to the previous stable binary after an unused candidate start,
and rollback after a canary drain with no live paged state. An in-flight
response is drained or terminated by its documented request-local failure
path; it is never continued across binaries or executors.

## Optional remote or rented hardware lane

This assessment does not purchase, provision, or transmit anything. If an
operator later authorizes a remote lane, it should use a dedicated temporary
Apple Silicon host and account, a reviewed commit, public model artifacts, and
synthetic prompts only. Do not transmit provider/buyer tokens, payout or
signing keys, production databases, private prompts, production configuration,
or local cache contents.

Before access, record provider, region, chip/RAM/OS, retention policy, access
list, network policy, artifact hashes, and deletion procedure. Encrypt storage
and transport, restrict outbound access to required public artifact/package
sources, use short-lived credentials, retain access logs, sanitize benchmark
logs, and verify teardown/wipe. Return only the signed evidence manifest,
aggregate metrics, sanitized logs, and hashes needed for review.

## Acceptance, rollback, and non-goals

The assessment is accepted when its current-state facts are reproducible, the
memory assumptions are explicit, every claim maps to an evidence tier, the
test specification fixes metrics and thresholds before measurement, and an
independent adversarial reviewer reports zero Critical, High, or Medium
findings after correction.

Non-goals are implementing the throughput engine, merging PR #894, enabling
production scheduling, advertising capacity, altering receipts/billing,
economic activation, procuring hardware, or claiming that 32 GB/fixture/unit
evidence qualifies a larger production tuple.

## Qualification blockers

- No merged production runtime bridge or shared MLX forward exists at the
  assessed revision.
- No single resident-model arbiter composes the serial semaphore with a batch
  executor.
- SPEC-038 conformance remains pending, and SPEC-039 is draft/pending-
  reconciliation with R001-R014 all pending and unmapped.
- Draft PR #894 is conflicting and fails its governance check.
- No 64 GB+ representative Mac is available.
- The representative large-model artifact and its verified configuration are
  unavailable locally.
- The frozen four-row MSB-02/03 workloads cannot qualify on their historical
  M4 Max target under current Entry 110. A same-host Ultra >=128 GiB baseline
  and candidate campaign, or a prior normative non-serving benchmark mode, is
  required.
- The current 3B test does not deterministically select its snapshot or bind
  real hashes into its descriptor; its exact-byte R3 manifest remains
  exploratory evidence.
- No clean maintenance window has been established for sustained benchmarks
  on the current actively serving Mac.
- No protected Xcode 16.4 release-candidate package, final standalone/Malibu
  byte-identity proof, or previous-stable updater run has exercised batching.

Until those blockers are resolved, the engine and scheduling flags remain off
and all capacity/performance claims remain unproven.
