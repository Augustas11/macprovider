# Product Build 5 test and benchmark specification

Date: 2026-09-11

Specification revision: `build5-benchmark-r2`

Repository base: `1d2c930bad81704dd0acc0322226725d8b64aceb`

## Purpose and change control

This specification defines the evidence required to implement and qualify
paged KV plus continuous batching. It does not authorize implementation or
activation. Record this document's commit and SHA-256 digest before starting a
benchmark campaign. Any change to a threshold, workload, accounting contract,
or supported feature after results are visible creates a new revision and
invalidates comparison to the prior gate unless both revisions are reported.

Every result must record the code commit, dirty state, model repository and
artifact hash, tokenizer/config hash, MLX package revisions, metallib hash,
binary/package identity, macOS build, chip, unified memory, power state,
thermal state, configuration, random seed, prompt corpus digest, start/end
times, selected test count, pass/fail/skip counts, and raw sanitized evidence
location. A timeout, crash, skip, zero-selected run, fixture-only run, or
historical result is not a pass.

## Correctness gates

The following are hard go/no-go gates. One violation fails the tuple.

| Gate | Required result |
|---|---|
| C1 greedy parity | Exact generated token IDs, finish reason, completion-token count, and output order between serial and paged/batched paths for every deterministic parity cell. |
| C2 isolation | Zero cross-request tokens, logits/sampling state, stop state, usage, receipt data, block handles, or delivery events under at least 100 seeded interleavings per deterministic scenario. |
| C3 accounting | Prompt, cached-prompt, completion, and accepted-token counts equal the locked serial/reference computation for every completed, stopped, cancelled, and failed request. |
| C4 lifecycle | Allocator live blocks, rows, continuations, and queued payloads return to the declared baseline after completion, cancellation, failure, drain, and warm swap. |
| C5 bounds | No dispatch occurs after an invalid table, unsupported tuple, or failed initial pool reservation. Pool allocation never exceeds its declared block/byte bound. |
| C6 cancellation | Queued cancellation removes the request before prefill. Active cancellation is observed by the next safe scheduler boundary, emits no token after acknowledgement, and releases state without a receipt for ungenerated work. |
| C7 ingress parity | Local HTTP and relay ingress share one bounded queue, active-row counter, and admission policy; their mixed-load sum never exceeds the Entry 110 cap or pool gate. |
| C8 recovery | Scheduler failure reason-codes and drains affected requests. Only requests with no buyer-visible output and an explicitly valid idempotent recovery state may restart on serial. |
| C9 compatibility | With batching disabled, golden API, streaming, receipt, usage, SPEC-024, SPEC-028, warm-swap, and serial-generation tests remain unchanged. |
| C10 release identity | The release-candidate executable loads its packaged pinned metallib and exact dependency tuple; a manually repaired SwiftPM bundle is not release proof. |

Stochastic tests supplement rather than replace greedy parity. For stochastic
cells, use identical seeds and verify the defined sampler equivalence when the
backend guarantees deterministic ordering. Otherwise compare distributional
properties only after all accounting and isolation gates pass; never treat a
statistical match as proof of request identity.

## Negative and failure tests

Required deterministic scenarios include:

- invalid, duplicated, missing, out-of-range, stale-generation, and
  wrong-descriptor block tables;
- zero/overflow block size and pool arithmetic; exhaustion before first output
  and extension failure during a multi-row decode;
- heterogeneous short/long prompts and output ceilings, simultaneous stop
  conditions, EOS, backpressure, a slow streaming consumer, and delivery
  disconnect;
- cancellation while queued, in chunked prefill, between decode steps, during
  delivery, and after completion races;
- scheduler actor/executor failure, model load failure, Metal/kernel failure,
  metallib missing/mismatch, memory-pressure signal, and serial fallback;
- warm swap while work is queued/active, stale generation handles, and a model
  profile or Entry 110 change;
- duplicate idempotency keys before and after visible output;
- structured output, tools/tool choice, logit bias, logprobs/top-logprobs,
  sticky conversation reuse without its bridge, `kv_bits`, draft/speculative
  decoding, unsupported model family, unadvertised block size/cache class/KV
  dtype, and MoE without promotion evidence;
- relay plus HTTP concurrency proving no second queue or capacity counter;
- receipt persistence delay/failure and client cancellation proving generated
  work is neither lost nor double-attributed.

Unsupported features must be serial-routed in the configured permissive/canary
mode with the exact reason code, or rejected before output in strict mode. They
must never silently enter the batched executor.

## Evidence tiers and test matrix

### Tier 0 — static and analytical

- SPEC authority and conformance mapping;
- dependency/API inspection against exact pinned revisions;
- checked integer arithmetic for pool sizing and memory budget;
- unsupported-feature and recovery state tables;
- release/metallib packaging inspection;
- complete diff review by code, security, and architecture lanes.

Tier 0 proves design consistency only.

### Tier 1 — deterministic unit and simulated pressure

Run allocator, gather-shape, capability, scheduler, row lifecycle, accounting,
cancellation, warm-swap, and failure tests. Use tiny configured pools to force
every boundary. Run Swift concurrency/race diagnostics supported by the
toolchain and repeat seeded interleavings. CI may own this tier.

Simulated exhaustion proves the control path. It does not prove unified-memory
behavior, MLX allocation peaks, or performance.

### Tier 2 — small-model real MLX on 32 GB

Required cells after the runtime bridge exists:

| Cell | Model | Context/output | Concurrency | Required evidence |
|---|---|---|---:|---|
| S1 | Llama 3.2 3B, exact local artifact | 128/40 greedy | 1 | Stock vs paged exact parity, non-identity blocks, real gather calls. |
| S2 | Llama 3.2 3B | 2K/256 | 1, 2, 4 | Serial/paged/batched correctness, memory, cancellation. |
| S3 | selected Qwen3 8B artifact | 128/64 greedy | 1 | Architecture parity before concurrency. |
| S4 | selected Qwen3 8B artifact | 2K and 8K prompts, 256 output | 1, 2, 4 where preflight permits | Mixed row lengths, memory envelope, serial recovery. |
| S5 | Llama 3B plus Qwen 8B as separate loaded generations | bounded requests across warm swap | applicable cap | Snapshot binding; never mix models in one shared forward. |

Run on AC power in a reserved maintenance window with no provider traffic.
Record at least 10 minutes of idle baseline and 15 minutes of thermal warm-up
for each model before measured repetitions. These timings may be revised only
before results are collected if host telemetry demonstrates a longer
stabilization need.

Tier 2 proves only the recorded 32 GB small-model tuples.

### Tier 3 — ingress, fixtures, and release candidate

Use a deterministic scheduler executor in cross-service tests to cover HTTP
and relay streaming/non-streaming, queue saturation, reconnect, cancellation,
idempotency, receipt/accounting, and model-swap state. Then repeat supported
happy/cancellation paths with real MLX on the release candidate. Verify the
packaged executable and metallib identities rather than substituting `swift
build` output.

Fixtures may prove orchestration and failure recovery. They cannot prove MLX
numerics, GPU memory, throughput, Metal availability, or large-model fit.

### Tier 4 — representative large hardware

Run on the exact target tuples, with separate reports for dense and MoE:

| Matrix ID | Hardware | Candidate model/workload | Claims it may support |
|---|---|---|---|
| H32 | Current 32 GB M5 Air | 3B and 8B small-model cells | Functional/parity and local development performance only. |
| HCI | 16-32 GB Apple Silicon CI | No private weights; fixtures or approved public small artifact | Unit, packaging, and fixture integration only. |
| H64/128 | Selected 64 or 128 GB Max-class Mac | Exact 30B MoE and dense 32B catalog candidates at declared contexts/concurrency | Tuple-specific throughput and memory-servability if all gates pass. |
| H192+ | Selected Ultra-class Mac | Only catalog targets whose analytical budget requires it, such as future 70B/120B cells | Tuple-specific large-tier claims; no automatic inheritance from smaller tiers. |

For each hardware row, first run concurrency 1 serial and paged baselines,
then concurrency 2 and 4, then the highest Entry 110 row cap that fits the
predeclared memory envelope. Context/output grid:

- prompt: 128, 2K, 8K, 32K tokens, plus 64K only when the artifact declares and
  the host budget permits it;
- output: 32, 256, and 1K tokens;
- mixes: equal short rows, one long with three short rows, staggered arrivals,
  slow consumer, cancellation churn, and alternating streaming/non-streaming;
- model classes: dense and MoE reported separately;
- unsupported-feature requests injected at 10 percent of a mixed ingress run
  to prove reason-coded serial routing does not corrupt batch capacity.

Do not extrapolate 64K from a model declaring a 40,960-token maximum. Do not
qualify a larger model with a smaller or more aggressively quantized proxy.

### Normative MSB-01 through MSB-05 cells

The representative campaign must first reproduce the frozen SPEC-038 /
RESEARCH_232 scenarios below. The wider context/concurrency grid follows only
after these cells have valid baselines.

| ID | Frozen workload | Required threshold |
|---|---|---|
| MSB-01 | One stream; exact catalog Qwen3-32B-4bit (or recorded catalog replacement); M4 Max 64 GB target; prompt 1,024, generation 256; deterministic; cold cache; no draft/prefix reuse | At least 20 valid runs, generation-throughput CV <=10%, zero correctness/early-terminal/Metal failures, peak RSS <=85% RAM, median and p95 TTFT/TG reported. This is a baseline, not an uplift claim. |
| MSB-02 | Four simultaneous identical 1,024-token prompts with distinct conversation identities; 256 generated tokens each; same artifact and settings as MSB-01 | Aggregate TG >1.5 times MSB-01; four terminal responses; zero attribution failure/starvation/Metal failure; p95 per-stream TPOT <=3 times baseline; peak RSS <=85% RAM. |
| MSB-03 | Four unrelated prompts of 512/1,024/1,536/2,048 tokens with no reusable prefix; 256 generated tokens each | Aggregate TG >1.2 times MSB-01; all requests complete; zero starvation/contamination/deadlock; 512-token request p95 TTFT <=2 times its single-request baseline; peak RSS <=85% RAM. |
| MSB-04 | Two distinct 1,024-token prompts, 256 generated tokens each; exact catalog Qwen3-Coder-30B-A3B-Instruct-4bit; deterministic; no draft/prefix reuse | Aggregate TG >1.3 times the same model's single-stream result; each stream >=45% of single-stream TG; zero OOM/swap storm; peak RSS <=85% RAM; accepted deterministic output tolerance passes. Use the smallest qualifying Entry 110 Ultra tier if 64 GB cannot meet the bound. |
| MSB-05 | Native `max_batch=2` versus pinned oMLX v0.4.4 benchmark oracle; two simultaneous 1,024-token prompts, 256 generated tokens, 30 paired randomized-arm runs | Equal accepted-request counts; zero harness failure; native/sidecar aggregate-TG-ratio 95% bootstrap-CI width <=0.20; output divergence classified; TTFT/TPOT/aggregate TG/peak RSS reported. A later native prototype promotion additionally requires >=0.80 times oracle aggregate TG and >=1.3 times native single-stream TG. |

The oMLX arm is an isolated benchmark oracle, never a production serving path
or trust authority. Use only public artifacts and synthetic prompts. If its
loader transforms bytes differently, record both digests and mark the
comparison approximate. No source or artifact from `d-inference` may be
inspected or used.

## Benchmark method

Use serial (`MSB-01`) as the same-host, same-artifact reference. Compare the
current multi-iterator behavior (`MSB-02`), supported shared forward
(`MSB-03`), MoE shared forward (`MSB-04`), and scale/concurrency sweep
(`MSB-05`) according to SPEC-038. Every variant uses identical decoded-token
work and prompt corpus where supported.

For each cell:

1. Warm the artifact and kernels; exclude warm-up observations.
2. Interleave serial and candidate runs in randomized order to limit drift.
3. Execute at least 20 valid repetitions for MSB-01 through MSB-04 and 30
   paired repetitions for MSB-05. For additional grid cells, execute at least
   30 completed requests across at least five clean process starts. Preserve
   each observation; report median and confidence interval, not only the best
   run.
4. Fix seeds and greedy decoding for correctness cells. Keep sampling cells
   separate.
5. Sample process and system memory, MLX active/peak memory if available, VM
   pressure, swap counters, power/thermal state, and scheduler metrics at a
   fixed cadence.
6. Exclude a run only by a predeclared invalidation rule such as OS update,
   unrelated process load, thermal emergency, or artifact mismatch. Retain and
   report exclusions with reasons.

Required metrics:

- aggregate generated tokens per common wall-clock second;
- per-request generation tokens/second;
- queue wait, time to first token, inter-token latency, and end-to-end latency
  at p50/p95/p99;
- success, backpressure, cancellation, fallback, and failure counts;
- active rows, batch-fill ratio, prompt/decode time, shared-forward calls, and
  serial-route reasons;
- process RSS/physical footprint, MLX active and peak memory where available,
  allocator live/high-water blocks, transient gather allocation, VM pressure,
  swap-in/out delta, and thermal/power samples;
- exact usage/receipt attribution and block/row/continuation leak count.

## Predeclared go/no-go thresholds

All correctness gates C1-C10 must pass. Performance promotion additionally
requires:

- `MSB-02` aggregate generation throughput greater than 1.5 times `MSB-01`;
- `MSB-03` greater than 1.2 times `MSB-01`;
- at least one qualified Entry 110 multislot tier greater than 1.3 times its
  `MSB-01` aggregate throughput within the memory and latency gates;
- MoE promotion only from its independent `MSB-04` result; dense evidence does
  not promote MoE;
- `MSB-02` p95 per-stream TPOT no greater than three times its baseline;
  `MSB-03` short-request p95 TTFT no greater than twice its single-request
  baseline; `MSB-04` gives each stream at least 45 percent of single-stream TG;
- `MSB-05` meets its paired-measurement gate; its optional oracle ratio is a
  prototype-promotion threshold, not production authority;
- zero critical VM-pressure samples, zero increase in swap-out count during
  the measured steady-state window, and observed peak process/MLX memory no
  greater than both 85 percent of physical RAM and the precomputed envelope
  plus 10 percent measurement allowance;
- allocator live blocks and process/MLX active memory return to the declared
  post-model baseline after the drain/recovery window;
- 100 percent of unsupported requests take their expected serial/reject path,
  and 100 percent of supported requests report the exact executor/generation
  identity in internal sanitized evidence;
- cancellation acknowledgement p99 no greater than two seconds and no output
  after acknowledgement. The scheduler-internal invariant remains the next
  safe boundary; the wall-clock threshold detects an unacceptably stalled
  boundary.

If a target fails only a performance threshold, it remains disabled; do not
weaken correctness, memory, or tail-latency gates. Optimization proposals must
name which measurement term they target and repeat the same frozen cells.

## Memory-pressure and fallback protocol

Use three distinct evidence types:

1. Tiny-pool deterministic tests exercise reservation/extension failure.
2. Small-model real tests exercise MLX allocation, gather transient, and
   cancellation on 32 GB.
3. Representative-host tests exercise actual pressure at the target tuple.

Do not create uncontrolled system-wide pressure on an actively serving Mac.
On a reserved disposable/maintenance host, increase context/concurrency only
through predeclared steps and stop before the next step when pressure becomes
critical, swap-outs begin, a memory bound is crossed, thermal emergency is
reported, or request correctness fails. The stop is a failed capacity cell,
not a reason to discard the observation.

After a scheduler or pool failure, admit no new batched work until actor,
allocator, executor, and generation state are reconciled. Canary mode may
serial-route new eligible requests. Never migrate an already-visible response
to serial continuation.

## Acceptance report shape

Each report must distinguish:

- implementation completion;
- deterministic local/CI verification;
- small-model real MLX verification;
- release-candidate integration;
- representative-hardware qualification;
- production enablement, which remains a separate decision.

List every absent artifact, host, maintenance window, skipped test, unsupported
feature, and failed threshold as a named blocker. The final claim must be no
broader than the narrowest code, model, artifact, runtime, OS, chip, memory,
and workload tuple actually tested.
