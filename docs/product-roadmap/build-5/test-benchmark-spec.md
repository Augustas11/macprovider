# Product Build 5 test and benchmark specification

Date: 2026-09-11

Specification revision: `build5-benchmark-r3`

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
   bypass the arbiter. New batch admission stops while serial work is selected;
   serial work starts only after accepted batch work drains. Conversely, a
   batch starts only after all serial leases exit. A bounded, FCFS mode-change
   queue prevents either class starving the other. Once an opposite-mode
   waiter exists, no new current-mode lease is issued; the waiter starts on the
   first handoff after current-mode quiescence. Tests bound this in arbiter
   transitions rather than wall time.
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

Required structural and deterministic tests prove no overlap with instrumented
serial and batch forwards, including unsupported mixed ingress, cancellation,
pre-output recovery, scheduler failure, warm swap, drain timeout, and executor
that ignores cancellation temporarily. A real-runtime mixed-ingress cell logs
`serial_forward_active * batch_forward_active == 0` at every 100 ms sample and
fails on any violation.

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
| C11 arbiter | The same resident generation never has a serial forward and shared forward active concurrently; queued mode changes are bounded and starvation-free. |
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

## Deterministic artifact selection

The harness input names an exact repository and snapshot revision. It resolves
only `<cache>/<repo>/snapshots/<declared-revision>`, checks that the resolved
path remains under the cache root, rejects symlink escape and missing required
files, hashes every declared relative file by content, and recomputes a
canonical manifest. Each lexicographically sorted record is encoded as
`relative_path NUL decimal_byte_count NUL lowercase_sha256 LF`; its SHA-256 is
the artifact-manifest identity. The observed manifest
must equal the preregistered digest before load. Ambiguous directory scanning,
"first snapshot" selection, all-zero hashes, and caller-provided descriptor
hashes without byte verification fail before inference.

The harness likewise hashes the executable, dependency lock, packaged
metallib, tokenizer/template, prompt corpus, workload generator, and result
schema. It places the verified artifact and metallib hashes into the SPEC-039
descriptor, reads them back from the active runtime, and rejects any mismatch.
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
same-artifact MSB-01 baseline. This R3 uses the latter qualification design.
Cross-host baselines are forbidden. Smaller or more quantized models never
qualify a larger target.

## Normative MSB arm mapping

| ID | Executor arms and workload | Threshold and qualification constraint |
|---|---|---|
| MSB-01 | Current macprovider single-stream serial `TokenIterator`; exact catalog Qwen3-32B-4bit or governed replacement; pp1024/tg256, greedy, cold conversation cache | Same host/artifact baseline for MSB-02/03; >=20 valid runs is the historical floor, while R3 statistics below require 100 for promotion tails |
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
  repetitions per arm across at least five clean process starts, at least 20
  repetitions per start. Report per-repetition aggregate TG and per-request
  latency. The historical >=20 floor is necessary but insufficient for R3
  p95 promotion.
- MSB-05 requires 100 valid paired repetitions across at least five clean
  starts. Pair by start and randomized arm order. Compute the estimator as the
  median of paired `native_aggregate_TG / oMLX_aggregate_TG` ratios. Generate
  50,000 paired bootstrap resamples with PCG64 seed
  `0x4d53423035523301`; take the percentile 2.5th and 97.5th quantiles. CI width
  is upper minus lower in ratio units and must be <=0.20. Report the interval,
  median, resample count, seed, and all pair values.
- p50 uses the nearest-rank empirical quantile. p95 is promotable only with
  >=100 independent request observations for that scenario/arm. p99 is
  promotable only with >=1,000; otherwise label it `descriptive_unqualified`
  with the sample count and do not use it in a gate. Cancellation acknowledgement
  p99 requires 1,000 cancellations across at least five clean starts.
- Report median and a 95% percentile bootstrap interval for aggregate TG using
  50,000 repetition-level resamples and the campaign seed. Report the same
  interval construction for each eligible p50/p95/p99 latency statistic,
  resampling complete requests within the scenario/arm. Never discard a
  completed valid repetition because it worsens a result.

### Arrival and disturbance schedules

- Identical/ragged MSB starts use a barrier: all requests are admitted within
  10 ms, measured from the first to last admission timestamp.
- `MIX-INGRESS-15M` lasts 15 minutes after warm-up. It emits one request every
  250 ms using a fixed alternating HTTP/relay sequence. Exactly every tenth
  request is unsupported; unsupported types rotate tools, structured output,
  logprobs, logit bias, and sticky reuse. Supported prompt bins rotate 128,
  512, 1024, and 2048 tokens; output limits rotate 32, 64, 128, and 256.
- `SLOW-CONSUMER-500` runs 500 streaming requests. Every fifth request delays
  each read by 100 ms; others drain immediately. The client buffer is fixed at
  the declared transport default. Any buffer/default change creates a new cell.
- `CANCEL-2000` runs 2,000 requests. Requests indexed modulo ten cancel at:
  queued (0), 25% prefill (1), first decode boundary (2), 25% output (3), 75%
  output (4), and delivery backpressure (5); indices 6-9 complete. This yields
  1,200 cancellation observations, enough for the declared p99 gate. The
  harness seed fixes prompt/arrival assignment and records actual boundary
  timestamps.
- Warm swap is injected after 25%, 50%, and 75% of the declared active work in
  separate cells. Whole-batch forward failure is injected at decode steps 1,
  8, and 32. Request-local extension failure targets one row at the same steps.

### Warm-up and exclusions

Before measured work, connect AC power, record 10 minutes idle baseline, load the exact artifact,
run five unmeasured pp1024/tg256 requests, and wait until thermal state is
nominal/fair for 60 consecutive seconds. MSB measurements then alternate arms
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
calibrated_target_peak_delta_bytes
calibrated_mlx_peak_delta_bytes
calibrated_activation_high_water_bytes
calibrated_gather_high_water_bytes
kv_bytes_per_token
block_size_tokens
rows[{prompt_tokens, output_limit_tokens, holdback_tokens,
      reserved_blocks, reserved_kv_bytes}]
queue_delivery_allowance_bytes
measurement_allowance_bytes
planned_process_envelope_bytes
hard_process_limit_bytes
mlx_memory_limit_bytes and mlx_cache_limit_bytes
sample_period_ms, pre_window_s, post_drain_window_s
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
`calibrated_target_peak_delta` is
`max(peak_phys_footprint - loaded_idle_phys_footprint, kv_pool_bytes)` over non-promoting dry
runs of the exact target row/context shape, so it already contains resident KV,
activation, executor, and transient gather effects; those components are
recorded separately but are not summed into the envelope again. Calibration
uses a preliminary manifest capped at 75% of RAM, stops admission at 80%, and
follows the same pressure/thermal/swap rules; it never promotes a tuple. The
maximum target delta, MLX peak delta, gather instrumentation high-water, and
activation instrumentation high-water and allocator KV high-water are frozen
in the promotion manifest. Queue allowance
comes from the maximum retained payload/event sizes times the bounded queue.
The 10% measurement allowance appears exactly once. A promotion cell may start only when
`planned_process_envelope <= hard_process_limit`. Runtime passes only when
sampled physical footprint never exceeds either value.

The authoritative process total is `proc_pid_rusage(RUSAGE_INFO_V4)`
`ri_phys_footprint`, sampled every 100 ms from 60 seconds before admission
through a 120-second post-drain window. `MLX.Memory.activeMemory`,
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
  have zero correctness failures. Unsupported routing is 100% as expected.

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
   metallib content hash.
3. After final nested signing, outer signing, notarization, stapling, and
   packaging, extract both deliverables and prove SHA-256 byte identity of the
   standalone and Malibu-embedded `macprovider-cli`. Verify metallib hashes and
   required resource-bundle identities in both packages.
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
