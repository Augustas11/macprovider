# Product Build 5 test and benchmark specification

Date: 2026-09-11

Specification revision: `build5-benchmark-r5`

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
   fence deadline. R5 chooses a separate inference-worker process: the provider
   controller owns admission, durable request dispositions, receipts, and the
   generation record; the worker exclusively owns the loaded MLX model, Metal
   context, scheduler, paged pool, and execution leases. A launchd-owned
   `InferenceWorkerSupervisor`, separate from both, owns the worker PID/process
   group and is the only lifecycle authority. Versioned bounded local IPC
   carries request IDs, frozen served-snapshot identity, token frames,
   cancellation, terminal outcome, and quiescence acknowledgements. On a fence,
   the controller closes admission and asks the supervisor to terminate; the
   supervisor sends graceful termination, SIGKILL by ten seconds, and waits for
   `waitpid` before acknowledging exit. On controller EOF/crash it performs the
   same fence and writes a generation-failed marker; the relaunched controller
   reconciles unresolved accepted IDs from its durable request log before any
   new generation. Only observed worker exit plus complete durable dispositions
   permits replacement or publication. Supervisor loss, worker EOF, IPC
   corruption, or an unmatched generation token fails closed. The worker never
   self-publishes readiness, its sandbox forbids spawning descendants, and the
   provider never reuses its in-process model
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
pre-output recovery, scheduler failure, warm swap, drain timeout, and executor
that ignores cancellation temporarily. A real-runtime mixed-ingress cell logs
`serial_forward_active * batch_forward_active == 0` at every 100 ms sample and
fails on any violation. Separate watchdog fixtures exceed the 120-second
forward, 900-second request execution, 250 ms queued-cancel and admission-
preemption, 5-second active-cancel,
1-second quiescent handoff, 30-second quiescent-drain, 900-second waiter
disposition, and 915-second old-accepted-work reconciliation
bounds using a virtual monotonic clock. They prove terminal reason codes, no
lease reuse, no late output, no publication of a replacement generation, and
actual worker PID exit observed by `waitpid`, complete durable terminal
dispositions, and no worker or lease reuse. A fence-callback observation alone
fails. Queue-depth fixtures cover `2 * slots_total` at Entry 110 depths one
through four, simultaneous old-mode grants, migrated accepted-queued entries,
and controller restart during fencing. A real-runtime test exercises the same
failure path with shortened preregistered test-only deadlines, a real child
process, and observed process exit; it cannot qualify the production values.

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
| C11 arbiter | The same resident generation never has a serial forward and shared forward active concurrently; terminating or fenced work obeys the 120 s forward, 900 s queue-inclusive request/waiter disposition, 250 ms admission-preemption/queued-cancel, 5 s active-cancel, 1 s post-quiescence handoff, 30 s quiescent drain, 10 s process fence, and 915 s old-accepted-work reconciliation bounds, with actual worker exit observed before reuse/publication. |
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

R5-specific fail-closed fixtures are mandatory: a missing static allocation
site, overlapping-lifetime undercount, dtype expansion, malformed weight
metadata, opaque plugin allocation, failed CPU/Metal cap probe, ramp hard-stop,
and sampled-pressure race; queue depth `2 * slots_total` plus the token cap at
every Entry 110 depth, older pre-admission rejection order, migrated accepted-
queued disposition, active deadline overrun, controller loss, supervisor loss,
PID reuse, late worker IPC, and restart reconciliation; added/deleted
runtime/campaign files, transient `dlopen` then unload, external plugin/rpath,
unmanifested metallib, source-compiled Metal library, writable backing
descriptor, second attachment, and broker loss; early/short/coalesced client
reads, missing queue watermark, prefill chunk coalescing, cancellation before
or after its exact boundary; and a statistics fixture whose request-level CI
passes while the hierarchical clean-start/batch-cluster CI fails. Each fixture
must fail the relevant gate and retain its reason code.

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
file in `/runtime`, not only the entry executable. Runtime closure records
`_dyld_image_count`, canonical path, device/inode/size/mtime/ctime, Mach-O UUID,
and content hash before model load, after load, after every plugin registration,
and after unload. It also installs dyld add/remove-image callbacks before any
runtime initialization; every callback appends a sequence-numbered identity to
the controller-owned evidence stream, so a transient load/unload cannot evade
the snapshots. Any dynamically loaded Mach-O, bundle, metallib, or plugin
must canonicalize under `/runtime` and match a manifest record. Apple sealed
platform images are the only exception and are represented by OS build, dyld
shared-cache UUID, image UUID, and canonical platform path. A resolved or
actually loaded non-platform image outside the read-only mount, a deleted
loaded image, an unmanifested plugin, or an identity/hash mismatch fails before
a result is eligible. All Metal library creation is routed through one audited
wrapper that accepts only a manifest-bound `/runtime` file descriptor, hashes
the bytes immediately before `MTLDevice.makeLibrary`, and records the result;
source-string/default-library compilation is forbidden in qualification. The
inference worker has network access denied and a
read policy limited to the read-only image, required Apple platform paths, and
an empty controller-owned output channel; an attempted outside read or network
fallback is a retained failed cell.

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
manifest must equal the preregistered digest before any model load. R5 does not
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
same-artifact MSB-01 baseline. This R5 uses the latter qualification design.
Cross-host baselines are forbidden. Smaller or more quantized models never
qualify a larger target.

## Normative MSB arm mapping

| ID | Executor arms and workload | Threshold and qualification constraint |
|---|---|---|
| MSB-01 | Current macprovider single-stream serial `TokenIterator`; exact catalog Qwen3-32B-4bit or governed replacement; pp1024/tg256, greedy, cold conversation cache | Same host/artifact baseline for MSB-02/03; >=20 valid runs is the historical floor, while R5 statistics below require 100 repetitions and ten clean-start clusters for promotion tails |
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

- MSB-01 through MSB-04 promotion campaigns require 100 valid randomized
  repetitions per arm across exactly ten valid clean process starts, ten
  valid repetitions per start. Report per-repetition aggregate TG and
  per-request latency. The historical >=20 floor is necessary but insufficient
  for R5 promotion.
- MSB-05 requires 100 valid paired repetitions across exactly ten valid clean
  starts, with ten valid pairs per start. Pair by start and randomized arm
  order. Compute the estimator as the
  median of paired `native_aggregate_TG / oMLX_aggregate_TG` ratios. Generate
  50,000 hierarchical paired bootstrap resamples with PCG64 seed
  `0x4d53423035523301`, sampling clean starts and then complete paired
  repetitions within each sampled start; take the percentile 2.5th and 97.5th
  quantiles. CI width
  is upper minus lower in ratio units and must be <=0.20. Report the interval,
  median, resample count, seed, and all pair values.
- p50 uses the nearest-rank empirical quantile. p95 is promotable only with
  >=100 request observations and at least ten independent clean-start clusters
  for that scenario/arm. p99 is promotable only with >=1,000 observations and
  at least ten independent clean-start clusters; otherwise label it
  `descriptive_unqualified` with both counts and do not use it in a gate.
  Cancellation acknowledgement p99 requires 1,000 cancellations across at
  least ten clean starts.
- A clean process start is the independent decision unit. A shared-forward
  repetition is an indivisible within-start cluster: all rows retain their
  common batch ID, start ID, thermal history, allocator state, and disturbance
  assignment. Point p50/p95/p99 values use all retained request observations,
  but row count never increases the reported independent-cluster count.
  Promotion intervals use exactly 50,000 hierarchical resamples with the
  campaign PCG64 seed: sample clean-start IDs with replacement; within each
  selected start sample complete repetition IDs with replacement; retain every
  row of each selected repetition together; then recompute the full statistic.
  Serial repetitions are one-row clusters. Paired arm comparisons resample a
  start and then its complete paired repetition IDs, preserving arm order and
  pairing. Report the point estimate, hierarchical interval, start count,
  repetition count, request count, batch sizes, seed, and resampling algorithm
  version. A request-level bootstrap may be reported only as
  `descriptive_nondecision` and cannot support go/no-go. Never discard a
  completed valid repetition because it worsens a result.

### Arrival and disturbance schedules

- Identical/ragged MSB starts use a barrier: all requests are admitted within
  10 ms, measured from the first to last admission timestamp.
- `MIX-INGRESS-15M-R1` runs from one clean start for exactly 15 minutes after
  warm-up. It emits exactly 3,600 requests, one every 250 ms, using a fixed
  alternating HTTP/relay sequence. Exactly every tenth
  request is unsupported; unsupported types rotate tools, structured output,
  logprobs, logit bias, and sticky reuse. Supported prompt bins rotate 128,
  512, 1024, and 2048 tokens; output limits rotate 32, 64, 128, and 256.
- `REF-TTFT-512-R1` is the same-host, same-artifact native serial reference for
  MSB-03. It runs 100 independent greedy requests across ten clean starts,
  ten per start, with the canonical 512-token prompt fixture, output limit 256,
  cold conversation/prefix state, concurrency one, and the next request
  admitted only after the prior request reaches terminal. Its p95 TTFT is the
  only denominator for the MSB-03 short-request gate.
- `SLOW-CONSUMER-500-R1` runs exactly 500 streaming requests across ten clean
  starts, 50 per start, admitted every 100 ms with concurrency bounded by Entry
  110. Prompt
  bins rotate 128/512/1024/2048 tokens and output limits rotate 32/64/128/256;
  the committed fixture digest fixes the exact token arrays. Requests with
  index modulo five equal to zero use the controlled slow path; all others
  drain immediately. The slow client requests `SO_RCVBUF=4096`, verifies and
  requires the `getsockopt(SO_RCVBUF)` value frozen by the campaign preflight
  before admission, performs no body read for 500 ms after response headers,
  and then makes one `recv(MSG_WAITALL)` for exactly 256 application bytes every
  100 ms using a monotonic schedule; only a terminal EOF may return fewer. The server delivery queue capacity is
  exactly 16 token frames. Instrumentation records the first transition from
  occupancy 15 to 16 and the producer suspension while attempting frame 17;
  each slow request must reach both markers or the cell fails. A short read,
  early read, cadence error over 10 ms, kernel-buffer mismatch, queue-capacity
  change, or missing suspension marker fails the cell. The cell timeout is 2
  hours and
  each queue-inclusive request timeout is 900 seconds. Any buffer, queue,
  arrival, or fixture change creates a new cell.
- `CANCEL-2000-R1` runs exactly 2,000 requests from ten clean starts, 200 per
  start, admitted every 100 ms with the same four prompt/output rotations and
  Entry 110 cap as `SLOW-CONSUMER-500-R1`. Requests indexed modulo ten cancel at:
  queued (0), exact prefill token 512 of a canonical 2,048-token prompt (1),
  first decode boundary (2), exact generated-token indices at 25% (3) and 75%
  (4), and delivery backpressure (5); indices 6-9 complete. Prefill chunk size
  is exactly 256 tokens; case 1 records completion of chunk two and injects
  cancellation before chunk three is scheduled. Case 5 performs no client body
  reads, uses the same verified socket and 16-frame delivery queue as the slow
  cell, records occupancy 16 plus the producer blocked on frame 17, and only
  then injects cancellation. Each case records its required boundary before
  injection and fails if the boundary is skipped, coalesced, or not reached.
  This yields
  1,200 cancellation observations, enough for the declared p99 gate. The
  harness seed fixes prompt/arrival assignment and records actual boundary
  timestamps. The cell timeout is 6 hours, each queue-inclusive request
  timeout is 900 seconds,
  queued acknowledgement must be <=250 ms, active acknowledgement must be
  <=5 seconds, and no post-acknowledgement token or receipt input is allowed.
- `WARM-SWAP-25-R1`, `WARM-SWAP-50-R1`, and `WARM-SWAP-75-R1` each run 400
  mixed-ingress requests across ten clean starts, 40 per start, admitted every
  100 ms, using the
  same frozen prompt/output rotation. Within each clean start, after request
  10, 20, or 30 has been admitted respectively, the harness requests a swap at
  that request's first decode boundary. The target reloads from the same
  adopted read-only bytes
  under a distinct generation identifier and therefore has an identical closed
  loader manifest. Each cell has a 2-hour
  timeout, the 30-second quiescent-drain bound, and requires zero old-generation
  lease, row, block, queue, or delivery ownership before publication.
- `BATCH-FAIL-D1-R1`, `BATCH-FAIL-D8-R1`, and `BATCH-FAIL-D32-R1` run 100
  repetitions each across ten clean starts, ten per start. Every repetition
  barrier-admits
  the legal Entry 110 row count with distinct canonical pp1024/tg256 requests
  and injects one whole-batch forward failure immediately before decode step
  1, 8, or 32. `ROW-EXT-FAIL-D1-R1`, `ROW-EXT-FAIL-D8-R1`, and
  `ROW-EXT-FAIL-D32-R1` use the same workload but inject allocation-extension
  failure into the lowest request ID only. For target decode step `d`, its
  canonical prompt length is chosen so its unused final-block slots equal
  `(d - 1) mod block_size_tokens`; earlier extensions succeed, and the fault is
  armed only for the extension requested immediately before token `d`. Each
  queue-inclusive request timeout is 900 seconds;
  each 100-repetition cell timeout is 6 hours. Every injected failure is a
  valid observed outcome and must satisfy C2-C8 and C11.

All MSB/REF repetitions have a 900-second queue-inclusive timeout and a 12-hour
cell timeout. Every disturbance request has the same 900-second queue-inclusive
timeout
unless its cancellation deadline terminates it earlier.
`MIX-INGRESS-15M-R1` has a 30-minute cell timeout. A timeout is a retained valid
failure after admission; the harness may not extend a timeout once the campaign
digest is frozen.

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

Each cell has a signed/versioned `memory-budget-v1` manifest frozen before its
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
hard_process_limit_bytes
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
hard_process_limit_bytes = min(floor(installed_ram_bytes * 85 / 100),
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

Before any target-shaped calibration, the campaign freezes a separate signed
`precalibration-budget-v1`; it never contains or derives from
`calibrated_target_peak_delta`. Required fields are the immutable tuple and
manifest digests; installed RAM and OS reserve; maximum measured loaded-idle
physical footprint and virtual size from exactly five clean load-only starts
with the same 600-sample window and no target work; analytical full-pool KV
bytes; bounded queue/delivery bytes; MLX cache limit; `RLIMIT_AS`; watchdog
sample period and stop threshold; ramp fractions and 256-token rounding rule;
pre-load model/runtime ledger and its digest; static target-ledger digest; every
derived bootstrap term; and a generated static allocation ledger. A failed or
incomplete load-only start forbids
pre-calibration and is not replaced. The ledger enumerates every maximum-live
non-KV allocation site in the candidate forward and gather path, with tensor
dimensions, dtype,
alignment, multiplicity, lifetime interval, and overflow-checked byte formula.
It covers activation tensors, contiguous gathered K/V, logits/sampling
workspace, executor staging, command buffers, and allocator/cache reservations.
An allocation without a finite manifest-bound formula, an opaque dynamic
plugin allocation, or an incomplete lifetime-overlap graph makes the target
`precalibration_unbounded` and forbids the run.

Loading the target to obtain loaded idle has its own a priori bound. Before any
model load, the adoption broker parses the immutable weight-container metadata
without materializing tensors and computes the maximum of stored tensor bytes
and runtime dtype-expanded tensor bytes, including alignment and duplicate/
tied-weight policy. It adds a static loader/runtime allocation ledger, bounded
tokenizer/config bytes, `max(2 GiB, 25%)` unattributed load reserve, and a
separate 25% allowance. Unknown compression, conversion, custom code, dynamic
allocation, or malformed/overflowing metadata is `preload_unbounded`. The
resulting `preload_process_envelope` must be <= the 70% pre-calibration limit;
the supervisor applies the correspondingly proven `RLIMIT_AS`, 10 ms watchdog,
pressure stop, and exit fence while producing each load-only start. Thus the
loaded-idle input is measured only after a separate immutable-byte-derived
pre-load admission decision.

```text
preload_payload_bound = tensor_runtime_bytes + tokenizer_config_bytes
                      + preload_runtime_static_bound
preload_runtime_reserve = max(2 * 2^30,
                              ceil(preload_payload_bound * 25 / 100))
preload_subtotal = unloaded_worker_phys_footprint
                 + preload_payload_bound + preload_runtime_reserve
preload_allowance = ceil(preload_subtotal * 25 / 100)
preload_process_envelope = preload_subtotal + preload_allowance
```

The independent bootstrap arithmetic is:

```text
bootstrap_non_kv_bound = max_live_sum(static_allocation_ledger)
bootstrap_runtime_reserve = max(4 * 2^30,
                                ceil(bootstrap_non_kv_bound * 25 / 100))
bootstrap_component_subtotal = loaded_idle_phys_footprint
                             + kv_pool_bytes
                             + bootstrap_non_kv_bound
                             + bootstrap_runtime_reserve
                             + queue_delivery_allowance_bytes
bootstrap_measurement_allowance = ceil(bootstrap_component_subtotal * 25 / 100)
precalibration_process_envelope = bootstrap_component_subtotal
                                + bootstrap_measurement_allowance
precalibration_limit = min(floor(installed_ram_bytes * 70 / 100),
                           hard_process_limit_bytes)
bootstrap_increment = kv_pool_bytes + bootstrap_non_kv_bound
                    + bootstrap_runtime_reserve
                    + queue_delivery_allowance_bytes
                    + bootstrap_measurement_allowance
rlimit_as_bytes = min(loaded_idle_virtual_size + bootstrap_increment,
                      precalibration_limit)
```

The exact-shape run is forbidden unless
`precalibration_process_envelope <= precalibration_limit`. The 4 GiB/25%
runtime reserve and separate 25% bootstrap allowance are conservative bootstrap
terms only; they do not replace, lower, or enter the later five-start maximum or
the final `memory-budget-v1` formula.

Calibration runs only in the separate inference-worker process selected by the
arbiter contract. Before launch, the supervisor sets `RLIMIT_AS` to the smaller
of the overflow-checked loaded-idle virtual-size-plus-bootstrap allocation bound
and `precalibration_limit`, sets the frozen MLX cache limit, and proves on the
exact OS/runtime with two sacrificial workers that CPU-backed MLX and Metal
unified-memory allocations obey it. Each probe sets headroom to 512 MiB above
its post-runtime-load virtual size, then attempts one 768 MiB allocation through
the exact candidate allocation API; the allocation must fail and the sampled
physical footprint must remain below the frozen 70% stop. A successful
over-limit allocation, signal, missing sample, or unobserved exit means the cap
is unproved and target-shaped calibration is forbidden on the host. The
supervisor samples worker physical footprint every 10 ms, subscribes to memory-
pressure events, closes admission and sends SIGKILL at 70% of
installed RAM or the first warning/critical event, and observes exit with
`waitpid`; the worker cannot terminate or corrupt the controller. These are
defense-in-depth stops behind the a priori bound, not substitutes for it.

Before the five exact-shape runs, three non-promoting ramp cells execute at
25%, 50%, and 75% of each row's target token extent, rounded up to a complete
256-token prefill chunk, in three fresh workers. Each ramp has its own
conservatively recomputed pre-calibration envelope and the same hard limit,
pressure, thermal, swap, recovery, process-exit, and retained-failure rules. A
failed or unbounded ramp forbids later stages. All five exact-shape outcomes,
including OOM, timeout, pressure, thermal, pageout, swap, hard-stop, or recovery
failure, are retained. Any failed dry run blocks a promotion campaign; it is
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
measurement allowance appears exactly once. A promotion cell may start only when
`planned_process_envelope <= hard_process_limit`. Runtime passes only when
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

All correctness gates pass before performance is considered. Then:

- MSB-01 must have 100 valid repetitions and a sample coefficient of variation
  `sample_standard_deviation(aggregate_TG) / mean(aggregate_TG) <= 0.10`.
  Otherwise its denominator is unstable and MSB-02/03 cannot promote. Report
  mean, sample standard deviation, CV, median, and the frozen bootstrap interval.
- MSB-02 median aggregate TG >1.5x the same-host MSB-01 median; per-stream p95
  TPOT <=3x the corresponding single-stream baseline.
- MSB-03 median aggregate TG >1.2x MSB-01; 512-token-request p95 TTFT <=2x its
  same-host single-request baseline.
- At least one legally authorized multi-row Entry 110 tuple exceeds 1.3x its
  same-host single-stream aggregate TG within all memory/tail gates.
- MSB-04 independently exceeds 1.3x its live-MoE serial baseline; each stream
  sustains >=45% of single-stream TG; exact token/terminal/accounting parity is
  mandatory.
- MSB-05 meets the paired CI method above. The optional prototype threshold is
  >=0.80x oMLX aggregate TG and >=1.3x native single-stream TG; it grants no
  serving or trust authority.
- MIX, slow-consumer, cancellation, arbiter, memory, receipt, and leak gates
  have zero correctness failures. Queued cancellation acknowledgement is at
  most 250 ms; opposite-mode admission preemption is at most 250 ms; active
  acknowledgement is at most 5 seconds for every request, with p99 also
  reported. Quiescent handoff is at most 1 second, quiescent drain
  at most 30 seconds, forward at most 120 seconds, request at most 900 seconds,
  process fencing at most 10 seconds, opposite-mode waiter terminal disposition
  at most 900 seconds, and old accepted-work terminal reconciliation at most
  915 seconds. A healthy grant is promised only within one second after
  quiescence and before the waiter's 900-second deadline; a long prior epoch
  may produce a truthful `mode_wait_timeout` instead.
  Actual worker exit and durable terminal dispositions precede lease reuse or
  generation publication. Unsupported routing is 100% as expected.

A failed performance threshold leaves the tuple disabled. No result is
extrapolated across chip, RAM, OS, artifact, quantization, runtime, metallib,
context/output shape, or Entry 110 value.

## Protected release-candidate gate

C10 requires all of the following in the protected release path:

1. `scripts/verify-release-toolchain.sh` proves Xcode 16.4 (16F6), Swift
   6.1.2, and macOS SDK 15.5; locked resolution leaves `Package.resolved`
   unchanged.
2. The exact candidate commit produces the standalone tarball and Malibu.app
   package. Both carry the same dependency-lock digest and version-matched
   metallib content hash. The inference worker, lifecycle supervisor, adoption
   broker, IPC schema, launchd profile, and sandbox policy are mandatory signed
   runtime resources, not host-installed substitutes.
3. After final nested signing, outer signing, notarization, stapling, and
   packaging, extract both deliverables and prove SHA-256 byte identity of the
   standalone and Malibu-embedded `macprovider-cli`. Verify metallib hashes and
   byte-identical worker/supervisor/broker helpers, IPC schema, launchd profile,
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
