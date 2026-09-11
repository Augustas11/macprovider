# Product Build 5 test and benchmark specification

Date: 2026-09-11

Specification revision: `build5-benchmark-r6`

Repository source base: `1d2c930bad81704dd0acc0322226725d8b64aceb`

## Purpose and change control

This specification defines future evidence for paged KV and continuous
batching. It authorizes neither implementation nor activation. Freeze the
commit, this document's SHA-256, a campaign manifest, and every workload file
before a benchmark begins. A post-result change to thresholds, generators,
sample sizes, exclusions, memory arithmetic, or supported tuples creates a new
campaign and cannot retroactively promote an earlier result.

Every result records code commit and dirty state; model repository, declared
snapshot revision, canonical artifact manifest, tokenizer/config hashes; exact
MLX locks; metallib and executable hashes; package identity; macOS build, chip,
RAM, power and thermal states; Entry 110 value; workload/corpus digest; random
seed; start/end time; selected, passed, failed, skipped, timed-out, and crashed
counts; raw sanitized log digest; and result-schema version. A skip, timeout,
crash, zero-selected run, fixture, historical report, or manually repaired
SwiftPM bundle is never release or hardware qualification.

## Authority and prerequisite gates

- SPEC-038 and SPEC-039 conformance entries must be reconciled before a bridge
  claims conformance. At this base, both are pending and SPEC-039-R001 through
  R014 contain no accepted implementation/test/evidence mappings.
- The exact requested tuple must be present in the SPEC-039 descriptor. The
  harness derives descriptor hashes from verified bytes and rejects zero,
  dummy, caller-asserted, ambiguous, or mismatched identities.
- Active accepted/runnable work never exceeds the persisted Entry 110 value.
  Current code yields one row for base chips, two for Max with at least 48 GiB,
  three for Ultra with at least 96 GiB, and four for Ultra with at least 128
  GiB. Pool admission may reduce usable rows; it may never raise them.
- A single same-generation execution arbiter must cover both shared-batch and
  independent serial forwards before mixed fallback tests can pass.
- A protected-toolchain release candidate is mandatory for release evidence.

## Required runtime execution arbiter

The future `ModelRuntime` bridge owns one `ResidentModelExecutionArbiter` per
loaded generation. The arbiter is the sole issuer of generation-scoped model
execution leases. The batch scheduler owns batch internals, while the arbiter
owns whether the resident model is executing batch or serial forwards.

States and permitted transitions are:

```text
idle --serial request--> serialRunning(n)
idle --eligible batch--> batchRunning(generation, scheduler)
serialRunning --last serial exits--> idle
batchRunning --quiescent drain--> idle
idle|serialRunning|batchRunning --swap/fatal failure--> draining
draining --all leases and accepted work resolved--> idle(new generation) or failed
failed --explicit reconstructed generation--> idle
```

Rules:

1. `serialRunning` and `batchRunning` are mutually exclusive for one resident
   generation. Serial concurrency may retain the existing semaphore limit only
   within `serialRunning`; it never overlaps a shared forward.
2. Unsupported permissive/canary work queues for a serial lease. It does not
   bypass the arbiter. The future bridge uses one bounded pre-admission queue of
   exactly `2 * slots_total`, matching the SPEC-038 benchmark default, with the
   current `maxQueuedTokens=1,048,576` as an independent byte-growth guard, and
   a mode epoch identified by a monotonic actor-owned sequence. FCFS holds within
   an open epoch and among mode-change waiters. A request remains pre-admission,
   unbound to a snapshot, until the arbiter can fund and grant a lease; the
   bridge does not create an accepted-but-not-granted backlog. Assigning the
   first opposite-mode sequence atomically closes the current epoch. Every
   unaccepted current-mode entry, including an older pre-admission entry, is
   terminally retryably rejected in enqueue order within 250 ms; none is
   overtaken and later admitted. New work for the closing mode is retryably
   rejected before acceptance. Any historical
   accepted-queued entry encountered during migration is terminally failed
   under its bound old snapshot within 250 ms, before output or receipt input;
   it is never moved to another mode or generation. At most `slots_total`
   already granted current-mode requests drain. The head opposite-mode waiter
   starts at the first handoff after those grants terminate or the worker is
   fenced. This is the selected SPEC-038 FR-CB13 policy and must be made
   normative before implementation.
3. Strict unsupported work rejects before acquiring a lease. Cancellation of
   queued serial or batch work removes it without changing execution mode.
   Cancellation of active work releases the lease only after the executor has
   acknowledged a safe boundary and exited.
4. A scheduler failure moves the generation to `draining`. A request may retry
   serial only if no buyer-visible frame, receipt, request-log terminal effect,
   or reusable paged state exists. The retry reacquires a new serial lease for
   the same served snapshot. Any visible output makes retry illegal.
5. Warm swap enters `draining`, rejects new old-generation admission, resolves
   queued/active work under the old generation, validates quiescence, and only
   then installs the new generation and arbiter. Catching a drain timeout grants
   no swap authority.
6. An arbiter lease is not held by an actor across arbitrary re-entrant calls;
   it is a generation/mode capability whose issuance, cancellation, completion,
   and drain accounting remain actor-owned. Every exit path returns it exactly
   once.
7. Every model forward has a 120-second deadline and every granted request has
   a 900-second queue-inclusive enqueue-to-terminal deadline. Lease grant does
   not reset or extend it. A queued
   cancellation is acknowledged within 250 ms. An active cancellation is
   acknowledged at a safe boundary within 5 seconds; after acknowledgement no
   output is emitted.
   Crossing a forward, request, or cancellation deadline marks the generation
   `failed`, revokes logical lease authority, and starts a 10-second process-
   fence deadline. R6 chooses a separate inference-worker process: the provider
   controller owns admission, durable request dispositions, receipts, and the
   generation record; the worker exclusively owns the loaded MLX model, Metal
   context, scheduler, paged pool, and execution leases. A launchd job owns an
   `InferenceWorkerSupervisor` and its direct worker child in one process group;
   the frozen profile sets `AbandonProcessGroup=false`, the worker sandbox
   forbids `fork`, `posix_spawn`, `exec`, and `setsid`, and the supervisor records
   boot UUID, launchd label, job-instance nonce, process-group ID, PID, process
   start time, audit token, and generation token before admission. Versioned
   bounded local IPC carries request IDs, frozen served-snapshot identity, token
   frames, cancellation, terminal outcome, and quiescence acknowledgements.

   On the normal fence, the controller closes admission and asks the supervisor
   to terminate; the supervisor sends graceful termination, SIGKILL by ten
   seconds, obtains child `waitpid` exit, and durably acknowledges the matching
   generation. On controller EOF/crash the live supervisor performs that same
   child fence and writes a generation-failed marker. On supervisor EOF/crash,
   the controller detects EOF within 250 ms, atomically closes admission, marks
   every unresolved accepted ID `generation_orphaned` within five seconds, and
   asks launchd to stop the exact job. Parent `waitpid` is not claimed on this
   path. Launchd job-instance termination and kernel empty-process-group
   observations are retained, but neither grants same-boot recovery authority.
   Supervisor loss unconditionally creates a durable orphan fence that forbids
   worker restart, lease reuse, and generation publication until the boot UUID
   changes. A relaunched controller reads the fence before contacting launchd
   and follows the same order. The claim is therefore bounded detection and fail-
   closed orphaning, not impossible post-parent `waitpid` evidence. Worker escape,
   late IPC, unmatched identity, or launchd-profile drift retains the orphan
   state. This three-process boundary requires a reviewed normative contract
   and protected-package identity before implementation.
8. Assigning an opposite-mode enqueue sequence atomically closes current-mode
   admission, and the enqueue/preemption acknowledgement returns within 250 ms;
   this does not interrupt a physical Metal command. The maximum prior work is
   `slots_total` granted requests, each with a queue-inclusive 900-second
   deadline origin no later than the opposite-mode enqueue. No new
   grant is issued in the closing epoch. The opposite-mode waiter is granted
   within 1 second after physical quiescence only if its own 900-second
   enqueue-to-terminal budget has not expired; otherwise it is terminally
   rejected with `mode_wait_timeout` no later than its 900-second deadline.
   The contract does not promise a healthy grant after a long prior epoch.
   If one old accepted request overruns, the generation fails by 900 seconds
   after the waiter enqueues, and the supervisor completes the 10-second exit
   fence plus durable accepted-request reconciliation within a further 5-second
   scheduling margin: all old accepted work is disposed by 915 seconds. The
   unaccepted waiter still receives its own terminal timeout by 900 seconds.
   Cancellation has the tighter 250 ms queued or 5-second active bound.
   These bounds hold at queue depth `2 * slots_total` and Entry 110 depths one,
   two, three, and four because queued entries are pre-admission and the active
   grants drain concurrently under one epoch deadline. A drain with no active
   model
   call completes within 30 seconds. Warm-swap publication requires old-worker
   exit plus zero leases/rows/blocks/delivery tasks; a timeout leaves the new
   generation unpublished.

Required structural and deterministic tests prove no overlap with instrumented
serial and batch forwards, including unsupported mixed ingress, cancellation,
pre-output recovery, scheduler failure, warm swap, drain timeout, and an
executor that ignores cancellation temporarily. A real-runtime mixed-ingress
cell logs `serial_forward_active * batch_forward_active == 0` at every 100 ms
sample and fails on any violation. Separate watchdog fixtures exceed the 120-
second forward, 900-second request execution, 250 ms queued-cancel/admission-
preemption/supervisor-EOF detection, 5-second active-cancel/orphan-disposition,
1-second quiescent handoff, 30-second quiescent-drain, 900-second waiter
disposition, and 915-second old-accepted-work reconciliation bounds using a
virtual monotonic clock.

Normal-path real-process fixtures prove matching-generation child `waitpid`
exit. Supervisor-loss fixtures crash the real parent at each worker lifecycle
phase and prove exact launchd profile/process-group membership, no descendant or
session escape, controller EOF detection, durable `generation_orphaned`
outcomes, exact-job stop attempts, empty-group observation, PID-reuse rejection,
restart order, and no same-boot reuse/publication. A second fixture withholds
launchd or group-empty observation and proves the same durable fence survives
both controller and supervisor restart until a simulated boot-UUID change. A
real-runtime test exercises both
paths with shortened preregistered test-only deadlines. A fence callback or a
new supervisor attempting `waitpid` on the orphan is a failed test. Queue-depth
fixtures cover `2 * slots_total` at Entry 110 depths one through four,
simultaneous old-mode grants, migrated accepted-queued entries, and controller
restart during fencing. These tests cannot qualify production deadline values.

## Correctness gates

Every applicable gate is mandatory for the exact tuple.

| Gate | Required result |
|---|---|
| C1 greedy parity | Exact generated token IDs, order, finish reason, terminal event, prompt/completion/cached counts, and receipt inputs match the locked serial computation. |
| C2 isolation | Zero cross-request token, sampling, stop, usage, receipt, handle, cache, or delivery state in at least 100 seeded interleavings per deterministic scenario. |
| C3 accounting | Completed, stopped, cancelled, failed, and retried requests match serial accounting with no duplicate settlement-eligible terminal. |
| C4 lifecycle | Rows, queue payloads, continuations, execution leases, and allocator blocks return to the declared generation baseline after every terminal path. |
| C5 bounds | Invalid table/descriptor/identity, unsupported tuple, or failed initial reservation dispatches no model work. Allocation remains within the declared byte/block pool. |
| C6 cancellation | Queued cancellation prevents prefill. Active cancellation is observed at the next safe boundary, emits nothing after acknowledgement, and releases all request state. |
| C7 common ingress | HTTP and relay share the same queue, row counter, pool authority, and execution arbiter. Their sum never exceeds Entry 110 or memory admission. |
| C8 recovery | Whole-batch failure drains deterministically. Only an invisible, idempotent, snapshot-bound request may retry serial; visible output can never be stitched. |
| C9 compatibility | Flag-off API, streaming, receipt, billing, SPEC-024, SPEC-028, SPEC-037, warm-swap, and generation behavior stays byte/semantics compatible. |
| C10 release identity | Protected-toolchain final packages satisfy the full dual-artifact release gate below. |
| C11 arbiter | The same resident generation never has a serial forward and shared forward active concurrently. Normal fencing proves child `waitpid`; supervisor loss proves 250 ms detection and unconditional durable boot-scoped orphaning. No path reuses or publishes while worker exit is unproved. Other 120 s forward, 900 s queue-inclusive request/waiter disposition, 250 ms admission-preemption/queued-cancel, 5 s active-cancel, 1 s post-quiescence handoff, 30 s quiescent drain, 10 s process fence, and 915 s old-work reconciliation bounds remain mandatory. |
| C12 MoE | For live MoE and deterministic MoE fixtures, candidate and serial paths produce identical greedy token IDs and terminal/accounting results for each row. No after-the-fact output tolerance is permitted. |

Raw-logit comparisons are optional diagnostics. They do not replace C1 or C12.
If later added, their comparison points, dtype-specific absolute/relative
tolerances, reduction rule, and failure interpretation require a new frozen
revision before results exist.

## Negative and failure coverage

Required deterministic coverage includes invalid/duplicate/missing/out-of-range
and stale-generation tables; descriptor and artifact substitution; zero and
overflow pool arithmetic; initial and mid-decode exhaustion; heterogeneous
rows; EOS/stop/output ceilings; streaming backpressure and disconnect;
cancellation queued, prefill, decode, delivery, and terminal races; scheduler,
model, Metal, metallib, delivery, persistence, and receipt failures; warm swap;
idempotent replay in every state; unsupported tools/structured output/logprobs/
logit bias/sticky reuse/quantized KV/speculative decode/model family/cache class;
and mixed HTTP/relay admission. Unsupported work must reason-code to the serial
arbiter in permissive/canary mode or reject before output in strict mode.

R6-specific fail-closed fixtures are mandatory: a missing preload or target
allocation site, wrong overlap edge, source-plus-expanded coexistence,
decompression/conversion scratch, tied-weight duplication, output staging,
malformed metadata, opaque plugin allocation, and integer overflow; an
`RLIMIT_AS` probe that appears to fail causally but cumulative forced-synchronous
Metal allocations cross it; footprint-watcher overshoot and missing samples;
queue depth `2 * slots_total` plus the token cap at every Entry 110 depth; older
pre-admission rejection order, migrated accepted-queued disposition, active
deadline overrun, controller loss, supervisor loss at every lifecycle phase,
process-group escape, withheld launchd/group-empty proof, PID reuse, late worker
IPC, boot-scoped orphan persistence, and restart reconciliation; added/deleted
runtime/campaign files, a non-platform audit-entrypoint dependency, transient
early-constructor `dlopen` then unload, missing synchronous event ack, evidence-
channel backpressure/controller loss, external plugin/rpath, unmanifested
metallib, source-compiled Metal library, writable backing descriptor, second
attachment, and broker loss; saturation oracle count/reason mismatches, boundary
admission before its funded lease/queue precondition, early/short/coalesced
client reads, missing queue watermark, prefill chunk coalescing, cancellation
before or after its exact boundary; and statistical fixtures in which point or
request-level estimates pass while the required paired hierarchical confidence
bound fails. Each fixture must fail the relevant gate and retain its reason
code.

## Deterministic artifact selection and immutable loader closure

The harness input names an exact repository and snapshot revision. Before a
campaign is frozen, an adoption tool creates a dedicated APFS disk image with
`/model`, `/runtime`, and `/campaign` trees. It recursively copies the entire
exact model snapshot, extracted signed runtime package, and frozen campaign
directory with no caller path allowlist, then closes and fsyncs every file and
directory and mounts the image
read-only. The executable is launched from `/runtime`; model, tokenizer,
template, metallib, resources, harness inputs, and result schema are opened only
from this mounted image. The harness opens
the mount root with `O_DIRECTORY|O_NOFOLLOW`, verifies `MNT_RDONLY`, and resolves
only the canonical `<mount>/model` path. It rejects symlinks, hard links with
link count other than one, sockets/devices/FIFOs, path escape, case-fold or
Unicode-normalization collisions, and any mount/device change.

The loader-byte manifest is exhaustive, not declaration-selected. Using
descriptor-relative POSIX paths normalized to Unicode NFC, it recursively
enumerates every regular file under all three adopted trees, `/model`,
`/runtime`, and `/campaign`, in bytewise UTF-8 lexicographic order. This
necessarily includes every model/tokenizer/template file, the full extracted
signed runtime package and resource/metallib bundles, CLI/test executable,
exact `Package.resolved`, checkout records, harness inputs, fixtures, result
schema, and campaign selectors. Canonical runtime-selection inputs include the
complete argument vector, an explicit environment allowlist, feature flags,
model-family/quantization selector, locale, and working directory. An
undeclared selector or a regular file omitted from any adopted tree fails the
cell.

Static closure recursively resolves `otool -L` and `LC_RPATH` from every Mach-O
file in `/runtime`, not only the entry executable. Static closure and ordinary
post-main image snapshots are necessary but cannot qualify the loader history.
R6 defines a prerequisite runtime-audit boundary and leaves qualification
blocked until it is implemented and passes the protected release gate.

The audit entrypoint is a minimal native launcher whose static closure contains
only Apple sealed platform images. It opens a predeclared bounded evidence
channel and installs dyld add/remove-image capture before it loads any
manifest-bound non-platform inference or runtime image. The inference worker,
Swift/MLX runtime, plugins, and their non-platform dependencies are packaged as
manifest-bound libraries loaded only through that entrypoint. Static inspection
rejects a non-platform launcher dependency or initializer. Each add/remove event
records monotonically increasing sequence, canonical path, device/inode/size/
mtime/ctime, Mach-O UUID, and content hash; loading cannot proceed past the
callback until the controller durably persists and acknowledges that sequence.
The channel has no drop mode: timeout, capacity exhaustion, controller loss,
sequence gap, or callback reentrancy failure terminates the worker and fails the
cell. The package freezes launcher bytes, entitlements, environment, sandbox,
IPC schema, and load API. An early constructor that loads and unloads another
manifested library before returning is a mandatory proof fixture. If this
ordering cannot be demonstrated under final signing, hardened runtime, and the
protected toolchain, C10 and every runtime/capacity qualification remain
blocked; R6 makes no exhaustive actual-loader claim from later callbacks.

At every captured boundary and after model load, plugin registration, and
unload, the worker also records `_dyld_image_count` and the same identities.
Every dynamically loaded Mach-O, bundle, metallib, or plugin must canonicalize
under `/runtime` and match a manifest record. Apple sealed platform images are
the only exception and are represented by OS build, dyld shared-cache UUID,
image UUID, and canonical platform path. A resolved or loaded non-platform
image outside the read-only mount, a deleted loaded image, an unmanifested
plugin, or an identity/hash mismatch fails. All Metal library creation is
routed through one audited wrapper accepting only a manifest-bound `/runtime`
file descriptor, hashing immediately before `MTLDevice.makeLibrary`; source-
string/default-library compilation is forbidden. The inference worker has
network access denied and a read policy limited to the read-only image,
required Apple platform paths, and an empty controller-owned output channel; an
attempted outside read or network fallback is retained as a failed cell.

Every model regular file is included, including all weight shards, index JSON,
config/generation config, tokenizer data/config, special-token maps, chat
templates, and any repository code file. Every transitive shard path named by
an index must canonicalize under `model`, exist exactly once, and appear in the
manifest; an unreferenced weight shard, missing reference, duplicate normalized
path, or remote/custom-code selection fails closed. Qualification forbids
network loading and `trust_remote_code`; if a later runtime executes repository
code, that capability needs a new reviewed cell and the code bytes remain in
the manifest.

Each record is encoded as
`domain NUL relative_path NUL decimal_byte_count NUL lowercase_sha256 LF`.
The manifest records, for each regular file, device, inode, byte count,
nanosecond mtime and ctime, and content SHA-256; those identity fields are
evidence but the canonical content digest uses the record above. The observed
manifest must equal the preregistered digest before any model load. R6 does not
treat an advisory lock as immutability. The local-writer threat boundary covers
every unprivileged process, including another process running as the benchmark
account; kernel, root compromise, and physical attacks remain out of scope and
are recorded as such. A privilege-separated adoption broker creates the image
inside a mode-0700 directory inaccessible to the worker, retains sole custody
while writing it, fsyncs it, closes every writable descriptor, opens one
read-only descriptor, attaches exactly one read-only device, unlinks the
backing pathname, fsyncs the parent, and only then launches the unprivileged
worker. Before launch, the broker must prove no writable backing descriptor and
no writable attachment exists; inability to enumerate or prove sole custody
fails closed. The worker receives neither the broker descriptor nor a backing
path and cannot invoke attachment tools. Broker exit, an extra attachment, a
writable descriptor, mount flag change, or loss of the custody descriptor
invalidates the cell. Image identity and SHA-256, attachment identity, mount
device/read-only flags, every file identity, the complete content manifest,
and actual loaded-image closure are recaptured after unload. Any
mutation, replacement, added/deleted file, identity change, or post-run digest
mismatch is a valid failed cell. No result is emitted as qualifying until this
recapture passes. Ambiguous directory scanning, "first snapshot" selection,
all-zero hashes, and caller-provided descriptor hashes without byte
verification fail before inference.

The harness places the verified closed-manifest and metallib hashes into the
SPEC-039 descriptor, reads them back from the active runtime, and rejects any
mismatch.
Every deterministic result also records the serial and candidate generated-
token arrays or their canonical SHA-256 plus the count; an equality assertion
without retained output identity is insufficient qualification evidence.

## Evidence tiers and feasible workload matrix

| Tier | Available now | What it can prove | What remains unavailable |
|---|---|---|---|
| T0 static/analytical | Yes | Contracts, integer arithmetic, descriptor/release design | Runtime correctness or capacity |
| T1 unit/simulated | Yes on 32 GiB and CI | Allocator, scheduler, arbiter, failure paths, tiny-pool exhaustion | MLX numerics, OS pressure, performance |
| T2 small-model MLX | After bridge, maintenance window, deterministic artifact harness | Exact 3B/8B tuple parity and local functional behavior | Large-model or fleet claims |
| T3 integration/RC | After bridge and protected build | HTTP/relay, receipts, fallback, package identity | Representative capacity unless host is representative |
| T4 representative hardware | No current host | Exact large tuple performance/memory qualification | Production activation remains separate |

Production-shaped cells obey Entry 110:

| Cell | Host authority | Model/workload | Legal rows | Claim boundary |
|---|---|---|---:|---|
| DEV-M5-3B | Current base M5, 32 GiB | declared 3B artifact; 128/40 and 2K/256 | 1 | Real parity/memory for this tuple only |
| DEV-M5-8B | Current base M5, 32 GiB | declared 8B artifact; 128/64 then 2K/256 | 1 | Architecture and single-row behavior only |
| DEV-MAX-D2 | Max with >=48 GiB | dense candidate, identical and ragged depth-2 variants | 2 | Development signal under legal capacity; new IDs, not MSB-02/03 replication |
| QUAL-U128-D4 | Ultra with >=128 GiB | exact catalog dense 32B; MSB-01/02/03 | 1 baseline, then 4 | May support tuple-specific dense qualification |
| QUAL-MOE-D2 | Max >=48 GiB or Ultra whose preflight funds the tuple | exact catalog 30B-A3B MoE; MSB-04 | 1 baseline, then 2 | May support tuple-specific MoE qualification |
| QUAL-ORACLE-D2 | Same qualifying host/artifact across paired arms | native two-iterator and pinned oMLX; MSB-05 | 2 | Oracle comparison only |

The historical RESEARCH_232 M4 Max 64 GiB target cannot legally execute the
four-row MSB-02/03 serving workload because current Entry 110 permits two rows
on that class. Those cells are blocked until a normative SPEC-038 change
defines a non-serving benchmark mode that cannot advertise capacity or serve
buyers, or until they run on a four-row Ultra >=128 GiB with a same-host,
same-artifact MSB-01 baseline. This R6 uses the latter qualification design.
Cross-host baselines are forbidden. Smaller or more quantized models never
qualify a larger target.

## Normative MSB arm mapping

| ID | Executor arms and workload | Threshold and qualification constraint |
|---|---|---|
| MSB-01 | Current macprovider single-stream serial `TokenIterator`; exact catalog Qwen3-32B-4bit or governed replacement; pp1024/tg256, greedy, cold conversation cache | Same host/artifact baseline for MSB-02/03; >=20 valid runs is the historical floor, while R6 statistics below require 100 repetitions and ten clean-start clusters for promotion tails |
| MSB-02 | Candidate shared-forward executor; four simultaneous identical tokenized prompts, distinct conversation IDs; pp1024/tg256 each | >1.5x MSB-01 aggregate TG; only QUAL-U128-D4 or later legal four-row authority |
| MSB-03 | Candidate shared-forward executor; four unrelated 512/1024/1536/2048 prompts; tg256 each | >1.2x MSB-01 and short-request TTFT gate; only legal four-row authority |
| MSB-04 | Same live MoE artifact: serial one-row baseline versus candidate two-row shared forward; two distinct pp1024/tg256 requests | >1.3x MoE serial aggregate, each row >=45% of serial TG, exact greedy tokens and accounting |
| MSB-05 | Current native `max_batch=2` with two independent `TokenIterator`s versus pinned oMLX v0.4.4 `BatchGenerator`; paired randomized arms, two pp1024/tg256 requests | Equal accepted counts; frozen bootstrap gate; benchmark oracle only |

The shared-forward candidate is not an MSB-05 arm. Any later candidate versus
oMLX study is `MSB-X1`, with its own preregistered threshold, and cannot replace
the frozen MSB-05 native-two-iterator comparison.

## Frozen workload and statistics protocol

All token counts refer to tokenized input plus generated-token limit. Prompt
fixtures are canonical UTF-8 JSON with sorted keys, LF line endings, exact
token IDs recorded after the declared tokenizer, and a committed SHA-256.
Greedy means temperature zero with draft and prefix reuse disabled.
Unless a cell fixes a literal seed below, derive its unsigned 64-bit seed from
the first eight bytes, big-endian, of
`SHA256(spec_digest || NUL || campaign_id || NUL || cell_id)`. The frozen
campaign manifest records the resulting integer and randomized schedule.

### Run counts and estimators

- MSB-01 through MSB-04 promotion campaigns use ten preregistered matched
  clean-start blocks. Each block contains one baseline start and one candidate
  start on the same host/artifact tuple; randomized arm order is fixed by the
  campaign seed. Each arm has ten valid repetitions per block, for 100 per arm.
  A completed failed repetition is retained and cannot be replaced. Report
  per-repetition aggregate TG and per-request latency.
- MSB-05 uses the same 100 valid matched pairs across ten clean-start blocks,
  with ten valid pairs per block. Its primary estimator is the median of paired
  `native_aggregate_TG / oMLX_aggregate_TG` ratios.
- Every distributional decision interval uses exactly 50,000 PCG64 hierarchical
  bootstrap resamples. Baseline/candidate comparisons sample matched start-block
  IDs with replacement, then complete paired repetition IDs within each block,
  retaining every row of both arms and their batch IDs. Single-arm CV, latency,
  footprint, and recovery statistics sample clean-start IDs, then complete
  repetitions within each selected start, retaining all rows. Recompute the
  complete statistic for each resample. Serial repetitions remain one-row
  clusters. Seeds are derived from the frozen campaign seed and statistic ID;
  MSB-05 retains `0x4d53423035523301`. Report the point estimate, 2.5th and
  97.5th percentile endpoints, seed, algorithm version, start/repetition/
  request counts, batch sizes, and all matched values.
- p50 uses nearest-rank empirical quantiles. p95 requires at least 100 boundary-
  reached request observations across all ten matched start blocks; p99
  requires at least 1,000 boundary-reached observations across ten blocks.
  Smaller samples are `descriptive_unqualified`. Row count does not increase
  the independent start-block count. Request-level or unpaired resampling is
  `descriptive_nondecision` and cannot support go/no-go.
- Every uplift threshold is passed only when the lower 95% hierarchical bound
  is strictly greater than the threshold. Every latency-ratio or variability
  ceiling is passed only when the upper bound is at or below the threshold.
  Equality follows the threshold's stated strictness. MSB-05 additionally
  requires interval width <=0.20. There is no generic width exception: a wide
  interval whose required endpoint does not clear the gate is `inconclusive`
  and the tuple remains disabled. Point estimates are report-only.
- A clean start block is invalid only under the preregistered pre-admission
  host/artifact exclusion rules. Once either arm admits work, every outcome in
  both arms is retained; no worsening block is discarded.

### Arrival and disturbance schedules

`SATURATION-ORACLE-R1` is the only open-loop count oracle. It uses the
deterministic executor and virtual monotonic clock, exact Entry 110 depth `D`,
a queue of `2*D`, one arrival every 100 ms for 60 seconds (600 sent), and an
exact 1,000 ms service time with completion processed before same-timestamp
arrival. The reference state machine, committed as campaign input, freezes these exact
post-drain counts: for `D=1,2,3,4`, accepted/started/terminal are respectively
62/124/186/248 and `queue_capacity` rejected are 538/476/414/352. The harness
must match every count and request ID. Accepted plus rejected equals 600, all
accepted reach terminal, and no other reason code is permitted. A separate real-runtime open-loop characterization
uses the same cadence but is non-promoting and reports, without predicting,
sent = accepted + reason-coded rejected and accepted = terminal + unresolved.
It never supplies boundary sample counts.

All real-runtime boundary campaigns are closed-loop. The controller exposes a
read-only, generation-bound harness event stream for queue depth, funded lease,
row state, token boundary, delivery occupancy, and terminal outcome. The
harness sends the next candidate only after the cell-specific precondition and
waits for the required marker/terminal before advancing. It keeps at most the
explicit anchor requests plus one disturbance candidate, so saturation cannot
silently reduce observations. A precondition or marker timeout is a retained
cell failure; it is never replaced by an index assumption.

- Identical/ragged MSB starts use a barrier: all requests are admitted within
  10 ms, measured from first to last admission.
- `MIX-INGRESS-15M-R1` remains an open-loop compatibility characterization:
  exactly 3,600 sent, one every 250 ms, alternating HTTP/relay; every tenth is
  unsupported and rotates tools, structured output, logprobs, logit bias, and
  sticky reuse. It reports sent, accepted, reason-coded rejected, boundary,
  terminal, and unresolved counts and cannot supply a fixed performance sample.
- `REF-TTFT-512-R1` runs 100 independent greedy serial requests across ten
  clean starts, ten per start. The next request is sent only after prior
  terminal. It fixes the canonical 512-token prompt, output 256, and cold
  conversation/prefix state.
- `SLOW-CONSUMER-1000-R2` produces exactly 1,000 accepted slow-path requests,
  100 per clean start. The next candidate is admitted only with one funded
  lease and no other disturbance candidate. It requires exactly 1,000 accepted,
  occupancy-16, blocked-frame-17, cancellation/terminal, and reconciled
  outcomes; rejected=0. The client verifies campaign-frozen `SO_RCVBUF=4096`,
  reads nothing for 500 ms after headers, then performs exactly 256-byte
  `recv(MSG_WAITALL)` calls every 100 ms. The server queue is 16 frames. A short
  or early read, >10 ms cadence error, buffer mismatch, changed capacity, or
  missing marker fails the cell.
- `CANCEL-6000-R2` has six subcells: queued, exact prefill token 512 before
  scheduling 256-token chunk three, first decode boundary, exact 25% generated-
  token index, exact 75% index, and delivery occupancy 16 with producer blocked
  on frame 17. Each subcell produces exactly 1,000 boundary-reached
  cancellations, 100 per clean start, for 6,000 total. The five active
  subcells each require sent=accepted=boundary=acknowledged=terminal=1,000 and
  rejected=0. The queued subcell requires sent=queued-boundary=acknowledged=
  preadmission-terminal=1,000, accepted=0, and rejected=0. It first occupies all
  `D` funded leases with deterministic anchor requests, observes the candidate
  in pre-admission position one, then cancels it; anchors drain before the next
  trial. Other subcells wait for a funded lease and exact marker. Delivery uses the verified slow-client
  settings. Queued acknowledgement is <=250 ms, active <=5 s, and no later
  token or receipt input is allowed.
- `WARM-SWAP-25-R2`, `WARM-SWAP-50-R2`, and `WARM-SWAP-75-R2` each produce
  exactly 100 accepted swap-trigger candidates across ten clean starts. Within
  each trial, a deterministic finite set of funded requests is admitted, the
  trigger candidate reaches respectively 25%, 50%, or 75% of its generated-
  token limit, and only then is swap requested. Each trial records exact
  accepted, boundary, old-generation terminal, rejected, and new-generation
  publication counts. Rejected is zero before admission closure; any later
  probe is exactly one `generation_draining` rejection. Publication requires
  zero old leases/rows/blocks/queues/delivery tasks and the applicable normal or
  orphan fence proof.
- `BATCH-FAIL-D1-R1`, `BATCH-FAIL-D8-R1`, and `BATCH-FAIL-D32-R1` run 100
  repetitions across ten clean starts. Each barrier-admits legal Entry 110 rows
  and injects one whole-batch failure before decode step 1, 8, or 32.
  `ROW-EXT-FAIL-*` uses the same workload but faults the lowest request ID's
  extension. The canonical prompt makes unused final-block slots equal
  `(d-1) mod block_size_tokens`; the fault is armed only for the extension
  immediately before token `d`.

Each boundary candidate retains sent, accepted, rejected with exact reason,
precondition sequence, boundary sequence, acknowledgement, terminal outcome,
and clean-start ID. Per-request timeout is 900 seconds. Slow and warm-swap
cells have 12-hour limits; each cancellation subcell and failure cell has a
12-hour limit. The campaign digest freezes all counts, schedules, fixtures,
timeouts, Entry 110 depth, and event-schema version. A timeout is a retained
failure after admission and is never extended.

### Warm-up and exclusions

Before each clean process start, connect AC power, stop the benchmark worker,
reset its private runtime/cache directory, and record the unloaded host for 10
minutes. Then launch a new worker, mount and verify the exact immutable artifact,
load it once, reset MLX peak counters, run five unmeasured pp1024/tg256 requests,
and wait until thermal state is nominal/fair for 60 consecutive seconds. MSB measurements then alternate arms
according to a preregistered seeded permutation. The five warm-ups are always
excluded and retained in logs.

A repetition is invalid only for: artifact/toolchain hash mismatch; harness
failure before admission; OS update/reboot; power loss; thermal state serious/
critical before admission; memory-pressure critical before admission; or a
non-harness process outside the frozen allowlist consuming >5% CPU for three
consecutive one-second samples. Runtime OOM, Metal failure, thermal/pressure
transition after admission, swap growth, timeout, wrong output, or cancellation
failure is a valid failed observation. All exclusions and failed observations
remain in the evidence bundle. A campaign with >5% invalid repetitions restarts
under a new campaign ID; exclusions never count toward required samples.

## Executable memory budget and pressure protocol

Each cell has a signed/versioned `memory-budget-v2` manifest frozen before its
promotion runs. All values are unsigned byte integers. Required fields are:

```text
installed_ram_bytes
os_reserve_bytes
artifact_file_bytes and artifact_manifest_sha256
verified_resident_weight_bytes
loaded_idle_phys_footprint_bytes
loaded_idle_mlx_active_cache_bytes
calibration_clean_starts
loaded_idle_sample_count_per_start
calibrated_target_peak_delta_bytes
calibrated_mlx_peak_delta_bytes
calibrated_activation_high_water_bytes
calibrated_gather_high_water_bytes
kv_bytes_per_token
block_size_tokens
rows[{prompt_tokens, output_limit_tokens, holdback_tokens,
      reserved_blocks, reserved_kv_bytes}]
queue_delivery_allowance_bytes
polling_gap_allowance_bytes
measurement_allowance_bytes
planned_process_envelope_bytes
planning_process_limit_bytes
mlx_memory_limit_bytes and mlx_cache_limit_bytes
sample_period_ms, unloaded_host_window_s, loaded_idle_window_s,
post_drain_window_s
precalibration_manifest_sha256
```

`os_reserve_bytes` is fixed as
`max(8 * 2^30, ceil(installed_ram_bytes * 20 / 100))`; this conservative
planning assumption may change only in a new reviewed benchmark revision.
Arithmetic is checked with overflow-trapping integers:

```text
row_reserved_tokens = prompt_tokens + output_limit_tokens + holdback_tokens
row_reserved_blocks = ceil(row_reserved_tokens / block_size_tokens)
row_reserved_kv_bytes = row_reserved_blocks * block_size_tokens * kv_bytes_per_token
kv_pool_bytes = sum(row_reserved_kv_bytes)
component_subtotal = loaded_idle_phys_footprint_bytes
                   + calibrated_target_peak_delta_bytes
                   + queue_delivery_allowance_bytes
                   + polling_gap_allowance_bytes
measurement_allowance_bytes = ceil(component_subtotal * 10 / 100)
planned_process_envelope_bytes = component_subtotal + measurement_allowance_bytes
planning_process_limit_bytes = min(floor(installed_ram_bytes * 85 / 100),
                               installed_ram_bytes - os_reserve_bytes)
```

`loaded_idle_phys_footprint` already includes resident weights, MLX/runtime
baseline, and caches; those terms are not added again.
`verified_resident_weight_bytes` is the checked sum of loaded parameter element
counts times their runtime dtype byte widths and is cross-bound to the verified
artifact manifest; it is a diagnostic already contained in loaded idle.
Calibration is exactly five non-promoting exact-shape dry runs, one in each of
five clean process starts. A clean start uses the warm-up sequence above and a
new worker PID; no model, tokenizer, Metal, or MLX cache survives from the
prior start. After warm-up and 60 seconds of nominal/fair thermal state, sample
loaded idle at monotonic offsets 0.0, 0.1, ... 59.9 seconds with at most 25 ms
absolute scheduling error. A start is valid only with all 600 paired physical-
footprint and MLX active+cache samples; a missing or late sample invalidates the
calibration campaign.
`loaded_idle_phys_footprint_i` and `loaded_idle_mlx_active_cache_i` are the
maxima of those 600 samples.
Campaign values are `max_i` across all five starts.

Immediately after each loaded-idle window, run exactly one dry repetition of
the target cell without restarting or resetting caches. Record process peak as
the maximum of every 100 ms `ri_phys_footprint` sample and
`ri_lifetime_max_phys_footprint` read immediately after the target and after
drain. The per-start target delta is saturating
`max(0, process_peak_i - loaded_idle_phys_footprint_i)`;
`calibrated_target_peak_delta` is
`max(kv_pool_bytes, max_i(target_delta_i))`. For start `i`, MLX peak is the
maximum of sampled `activeMemory + cacheMemory` and reset-per-start
`peakMemory`; its saturating delta subtracts `loaded_idle_mlx_active_cache_i`.
`calibrated_mlx_peak_delta` is the maximum of those five deltas. Activation, gather, and
allocator high-waters are maxima across the five runs and remain non-added
diagnostics because target delta contains them.

Before any model load, the campaign freezes `preload-budget-v2`. The adoption
broker parses immutable container metadata without materializing tensors and
generates an event-indexed maximum-live ledger. Each row records stable site ID,
phase start/end events, dimensions, source and destination dtype, alignment,
multiplicity, residency rule, tied/duplicate policy, overflow-checked formula,
and bytes. Required incremental rows cover file-backed source mapping residency; compressed source; decompression and conversion
scratch; dtype-expanded destination tensor; duplicate/tied-weight
materialization; tokenizer/config/template; loader and Swift/MLX runtime;
CPU/Metal staging; command buffers; caches; logits/sampling; and output/IPC
buffers. Edges state coexistence. For each ordered lifecycle event, the
calculator sums every live row; `preload_max_live_bytes` is the maximum sum,
not the maximum row or `max(stored, expanded)`. Source mapping and converted
output coexist from first destination allocation through forced Metal
synchronization and source-release evidence. An unknown row, edge, release,
compression ratio, conversion formula, dynamic allocation, or overflow is
`preload_unbounded` and forbids load.

Exactly ten minutes of minimal audit-worker physical-footprint samples establish
`unloaded_worker_peak`; no model, Swift/MLX inference runtime, tokenizer, or
Metal payload has yet loaded. Every preload ledger row is incremental to that
frozen baseline, and duplicate site coverage is rejected. The frozen
arithmetic is:

```text
preload_runtime_reserve = max(2 * 2^30,
                              ceil(preload_max_live_bytes * 25 / 100))
preload_subtotal = unloaded_worker_peak + preload_max_live_bytes
                 + preload_runtime_reserve
preload_allowance = ceil(preload_subtotal * 25 / 100)
preload_process_envelope = preload_subtotal + preload_allowance
preload_advisory_limit = min(floor(installed_ram_bytes * 50 / 100),
                             installed_ram_bytes - os_reserve_bytes)
```

The lower 50% advisory limit is an assessment policy for unqualified Darwin,
not an OS hard cap. Model load is forbidden unless the envelope fits it. The
10 ms watcher closes admission and requests termination at 50% physical
footprint or the first warning/critical pressure event; it records detection,
signal, exit, lifetime high-water, and overshoot. Crossing is a failed run and
cannot establish safety. The watcher is asynchronous and is never described as
preventing a transient crossing.

After five successful load-only starts, the campaign freezes
`precalibration-budget-v2`. It never contains or derives from
`calibrated_target_peak_delta`. Required fields are immutable tuple and
manifest digests; installed RAM/OS reserve; five loaded-idle maxima; analytical
full-pool KV; queue/delivery bytes; MLX cache limit; preload ledger/digest;
target maximum-live ledger/digest; runtime reserve; advisory threshold; watcher
period; ramp fractions; and every derived term. The target ledger uses the same
site/phase/edge schema and separately charges activation tensors, gathered K/V,
logits/sampling, executor/Metal staging, command buffers, caches, output/IPC,
and analytical KV. A single `campaign_max_live_ledger` spans adoption, load,
warm-up, prefill, decode, delivery, drain, and unload. It therefore contains
stored/file-backed source residency, compressed bytes, expanded resident
tensors, conversion/decompression temporary bytes, KV, activations, command
and staging buffers, caches, and outputs in one event order. After the measured
loaded-idle baseline becomes authoritative, its manifest-bound resident-set row
replaces, rather than adds to, the analytical resident-weight/runtime rows for
serving phases; the replacement edge and covered site IDs are frozen. Thus no
resident byte is omitted or double counted. `campaign_max_live_bytes` is the
maximum over every phase and must equal the greater of the preload phase and
serving phase calculations. `max_live_sum` is evaluated over all ordered
events. An opaque allocation, uncovered replacement, or incomplete overlap
graph is `precalibration_unbounded`.

```text
bootstrap_non_kv_bound = max_live_sum(target_non_kv_ledger)
bootstrap_runtime_reserve = max(4 * 2^30,
                                ceil(bootstrap_non_kv_bound * 25 / 100))
bootstrap_subtotal = loaded_idle_phys_footprint + kv_pool_bytes
                   + bootstrap_non_kv_bound + bootstrap_runtime_reserve
                   + queue_delivery_allowance_bytes
bootstrap_allowance = ceil(bootstrap_subtotal * 25 / 100)
precalibration_process_envelope = bootstrap_subtotal + bootstrap_allowance
precalibration_advisory_limit = min(floor(installed_ram_bytes * 60 / 100),
                                    installed_ram_bytes - os_reserve_bytes)
```

Exact-shape work is forbidden unless the envelope fits the advisory limit and
all preload/load-only/ramp evidence passes. On Darwin, `RLIMIT_AS`/`RLIMIT_RSS`
is recorded only as diagnostic configuration. It supplies no hard-cap field,
no admission authority, and no promotion evidence. Optional causal allocator
characterization requires, on repeated clean workers, an unlimited successful
control; below-candidate success; one large and cumulative smaller allocations
crossing the candidate; identical CPU and forced-synchronous Metal operations;
and API/signal/kernel reason capture. Passing proves only the exact allocator
path tested. Until a reviewed exact-OS mechanism synchronously constrains all
CPU and forced-synchronous Metal committed memory used by the runtime,
representative target-shaped runs are non-promoting and the capacity gate stays
closed. Ledgers, ramps, pressure monitoring, and worker termination remain
independent defenses and cannot be weakened.

The watcher closes admission and sends termination at the 60% advisory
threshold or first warning/critical pressure event. The parent supervisor uses
normal `waitpid`; supervisor loss uses the launchd/orphan protocol above. Every
sample, detection latency, SIGTERM/SIGKILL time, exit path, and maximum overshoot
is retained. A missing sample, late exit, or crossing fails the cell. A watchdog
pass never converts the advisory boundary into a hard cap.

Before the five exact-shape runs, three non-promoting ramp cells execute at
25%, 50%, and 75% of each row's target token extent, rounded up to a complete
256-token prefill chunk, in three fresh workers. Each ramp has its own
conservatively recomputed pre-calibration envelope and the same advisory limit,
pressure, thermal, swap, recovery, process-exit, and retained-failure rules. A
failed or unbounded ramp forbids later stages. All five exact-shape outcomes,
including OOM, timeout, pressure, thermal, pageout, swap, advisory-stop, or
recovery failure, are retained. Any failed dry run blocks a promotion campaign; it is
not replaced. The unloaded ten-minute host window detects ambient instability
and validates exclusions; it is not substituted for the loaded-idle baseline
used by the final formula.

On qualifying macOS, `ri_lifetime_max_phys_footprint` is mandatory, so
`polling_gap_allowance_bytes` is zero. If that trustworthy lifetime high-water
counter is unavailable, the non-promoting development envelope sets
`polling_gap_allowance_bytes = max(1 GiB, ceil(sampled_target_peak_delta * 10 / 100))`;
such a result remains development-only until a new independently reviewed
revision justifies promotion on that platform. Queue allowance comes from the
maximum retained payload/event sizes times the bounded queue. The separate 10%
measurement allowance appears exactly once. A promotion cell may start only when an independently reviewed synchronous
CPU/Metal cap exists and
`planned_process_envelope <= planning_process_limit`. Runtime passes only when
the authoritative process peak never exceeds either value.

The authoritative process total is the maximum of
`proc_pid_rusage(RUSAGE_INFO_V4).ri_phys_footprint` sampled every 100 ms and
the post-window `ri_lifetime_max_phys_footprint`. Sampling starts with the
60-second loaded-idle window and ends after the 120-second post-drain window.
`MLX.Memory.activeMemory`,
`cacheMemory`, and reset-per-cell `peakMemory` are sampled at the same cadence
and checked against the manifest MLX limit; they are diagnostic subsets and
are never added to physical footprint. Allocator reserved/live/high-water
bytes are checked against `kv_pool_bytes` on every scheduler transition.

At the same cadence record
`kern.memorystatus_vm_pressure_level` (1 normal, 2 warning, 4 critical),
`ProcessInfo.thermalState`, `vm_stat` cumulative `Pageouts`, and
`sysctl vm.swapusage` used bytes. Abort new admission immediately on one
critical pressure sample or serious/critical thermal state. The current cell
fails if any critical pressure occurs, if two consecutive serious/critical
thermal samples occur, if the pageout counter or swap-used bytes increase
between first admission and post-drain end, or if a memory bound is crossed.
On a stop, reject new work and cancel/drain accepted work at the next safe
scheduler boundary. Warning/fair samples are retained and reported.

After drain, within 120 seconds, allocator live blocks/leases/rows/queues must
equal the pre-cell baseline. Physical footprint must be <=
`loaded_idle_phys_footprint + max(64 MiB, 2% of loaded_idle_phys_footprint)`;
MLX active+cache must independently be <=
`loaded_idle_mlx_active_cache + max(64 MiB, 2% of loaded_idle_mlx_active_cache)`.
The two metrics are not summed. Failure to return is a
leak/failure, not an excluded sample. No uncontrolled pressure generator may
run on an actively serving Mac.

## Performance and go/no-go thresholds

All correctness gates pass before performance is considered. Each distributional
decision uses the cluster-aware hierarchical interval defined above, paired for
baseline/candidate comparisons and single-arm for standalone statistics. Point
estimates are report-only.

- MSB-01 baseline stability passes only when the upper 95% hierarchical bound
  for `sample_standard_deviation(aggregate_TG) / mean(aggregate_TG)` is <=0.10.
  Otherwise MSB-02/03 remain inconclusive.
- MSB-02 aggregate-TG candidate/baseline ratio passes only when its lower bound
  is >1.50. Its per-stream p95-TPOT candidate/baseline ratio passes only when
  its upper bound is <=3.00.
- MSB-03 aggregate-TG ratio passes only when its lower bound is >1.20. Its
  canonical 512-token p95-TTFT candidate/`REF-TTFT-512-R1` ratio passes only
  when its upper bound is <=2.00.
- The generic multi-row gate requires at least one legally authorized Entry 110
  tuple whose aggregate-TG ratio lower bound is >1.30 while every memory,
  correctness, and latency gate passes.
- MSB-04 live-MoE aggregate-TG ratio lower bound must be >1.30 and each stream's
  TG/single-stream-TG ratio lower bound must be >=0.45. Exact token, terminal,
  and accounting parity remains mandatory.
- MSB-05 requires its native/oMLX ratio lower bound >=0.80, native/single-serial
  ratio lower bound >=1.30, and paired interval width <=0.20. It grants no
  serving or trust authority.
- MIX, slow-consumer, cancellation, arbiter, memory, receipt, and leak gates
  require zero correctness failures and exact schedule/count-oracle agreement.
  Every individual deadline observation must meet its fixed ceiling: 250 ms
  queued cancellation/admission preemption/supervisor-loss detection; 5 s
  active cancellation/orphan request disposition; 1 s quiescent handoff; 30 s
  quiescent drain; 120 s forward; 900 s request/waiter disposition; 10 s normal
  process fence or launchd proof attempt; and 915 s old accepted-work
  reconciliation. A hard per-observation ceiling is not replaced by an
  interval. Cancellation p99 is reported only with 1,000 boundary-reached observations for
  each subcell, and its upper hierarchical bound must also be <= the
  applicable acknowledgement ceiling. Unsupported routing is 100% exact.

All distributional go/no-go quantities, including throughput ratios, latency
ratios, CV, cancellation-tail latency, per-start peak-footprint ratio, and
post-drain recovery time, use the matched-start hierarchical interval and its
required endpoint. Exact protocol invariants--token equality, zero cross-
request leakage, count-oracle equality, reason codes, fixed deadline maxima,
and no bound crossing--must hold for every observation and are not statistical
claims; an interval cannot excuse one violation. The memory gate requires both
zero observed crossing and the upper 95% bound of the per-start peak/envelope
ratio <=1.00. The recovery gate requires every observation <=120 seconds and
the upper 95% bound <=120 seconds.

A bound that crosses or touches a strict threshold is `inconclusive`; a bound
above a non-strict ceiling fails. Both leave the tuple disabled. No result is
extrapolated across chip, RAM, OS, artifact, quantization, runtime, metallib,
context/output shape, or Entry 110 value. On Darwin without a proven synchronous
CPU/Metal memory cap, satisfying these statistical gates still cannot promote a
capacity claim; the cap blocker is independent.

## Protected release-candidate gate

C10 requires all of the following in the protected release path:

1. `scripts/verify-release-toolchain.sh` proves Xcode 16.4 (16F6), Swift
   6.1.2, and macOS SDK 15.5; locked resolution leaves `Package.resolved`
   unchanged.
2. The exact candidate commit produces the standalone tarball and Malibu.app
   package. Both carry the same dependency-lock digest and version-matched
   metallib content hash. The inference worker, pre-runtime audit launcher, lifecycle supervisor,
   adoption broker, IPC schema, launchd profile, and sandbox policy are
   mandatory signed
   runtime resources, not host-installed substitutes.
3. After final nested signing, outer signing, notarization, stapling, and
   packaging, extract both deliverables and prove SHA-256 byte identity of the
   standalone and Malibu-embedded `macprovider-cli`. Verify metallib hashes and
   byte-identical worker/audit-launcher/supervisor/broker helpers, IPC schema,
   launchd profile,
   sandbox policy, entitlements, and required resource-bundle identities in
   both packages.
4. Run `codesign --verify --strict --deep`, `stapler validate`, Gatekeeper
   assessment, immutable checksum/signature verification, and the repository's
   Malibu/provider release verifier. `codesign --force --deep` is forbidden.
5. Exercise the updater from the previous stable CLI through the candidate and
   reverify binary/metallib/package identity after update. A public release is
   never patched in place.
6. Repeat supported happy, cancellation, fallback, and flag-off compatibility
   paths using the installed release candidate. A debug executable or manually
   copied metallib cannot satisfy any item above.

The current Xcode 26.6/Swift 6.3.3 SwiftPM result remains development-only.

## Acceptance report and blockers

Reports separately state implementation status, deterministic unit/CI
evidence, small-model real MLX evidence, protected RC evidence,
representative-hardware qualification, and production enablement. Missing
host, artifact, maintainer window, selected tests, conformance, package,
descriptor, or threshold is a blocker. Production enablement remains a
separate reviewed/operator decision outside Build 5.
