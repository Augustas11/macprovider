# SPEC-038 — Continuous batching for concurrent provider inference

Version: v0.2
Status: draft (normative design; no IMPL in this SPEC - implementation is a separate PR behind a disabled-by-default flag)
Owner: provider runtime / inference scheduler
Decision source: `docs/research/RESEARCH_232_MULTISTREAM_BATCHING_MEMO.md` (original memo, commit `8d80f6c4`), `docs/research/RESEARCH_232_ADDENDUM_PAGED_REDECISION_2026-07-29.md`, `docs/research/SPIKE_PAGED_ATTN_PHASE0_RESULT_2026-07-29.md` (commit `e5ded571`), `docs/research/SPIKE_PAGED_ATTN_PHASE2_RESULT_2026-07-29.md` (commit `acc30b1e`), and `docs/research/SPIKE_PAGED_ATTN_PHASE3_MOE_RESULT_2026-07-29.md` (commit `da21af53`).
Audit history: v0.2 is subject to three-lane codex SPEC audit (code / security / architect). Convergence and any carried LOW/INFO findings are recorded in the SPEC PR body and `audits/2026-07-29/SPEC-038-v0_2-rN-audit.md`.

## 1. Purpose and scope

Build the provider's **multi-slot throughput axis** — the ability to serve
several concurrent decode streams from one shared model forward — **ahead of
deliberately-recruited multi-slot (Ultra) demand**, on the SPEC-039 servability
flywheel. This SPEC moves the shared-model decode step from today's **parallel
single-stream decode** (each admitted request runs an independent
`TokenIterator` under an `AsyncSemaphore` permit) to **continuous batching**:
active decode rows share one model forward and join or leave the batch
dynamically between decode steps.

The framing is deliberate and matches the RESEARCH_232 addendum decision:
throughput is the **secondary axis, built ahead of the demand it serves**, the
way datacenter batching was built before 50-stream demand existed — not behind
it. Higher provider aggregate throughput (and therefore provider **earnings**)
is the **downstream payoff once multi-slot demand is manufactured** by the
deliberate Ultra-provider strategy that SPEC-039 memory-servability enables; it
is not the standalone justification, and today's mostly-1-slot fleet is not an
argument against building the capability (gating demand-enabling infrastructure
on current demand is the addendum's rejected melting-ice-cream circularity).

v0.2 replaces v0.1's falsified activation theory. v0.1 depended on a reviewed
upstream `mlx-swift-lm` batch API and a dense contiguous KV layout. The
2026-07-29 re-decision found that upstream path permanently unsatisfiable and
proved the strategic engine should be locally owned and paged. This SPEC now
defines the **scheduler and serving layer**. The companion forward reference
`SPEC-039` owns the paged KV storage and paged-attention engine. This SPEC
consumes that capability; it does not redefine the engine.

This is a **money-path** change. Under one shared forward, per-request token
usage, stop conditions, cancellation, and the receipt each request emits are
no longer isolated by separate iterators. Correctness of that per-request
accounting is the load-bearing invariant of this SPEC (FR-CB6). A single
mis-attributed token is a billing and provider-earnings defect, not merely a
serving glitch.

The feature is **disabled by default** and enables nothing on merge of either
this SPEC or its IMPL. When the flag is off, the provider MUST behave
byte-for-byte as it does today (FR-CB9). Turning it on for real traffic is
gated on the acceptance criteria of §7 and, decisively, on the real-hardware
enable gate of FR-CB15. A green CI/audit/unit-test pass is not the enable gate
for this runtime feature.

In scope for v0.2:

- An actor-isolated batch scheduler behind the existing generation path
  (`ModelRuntime`), with FCFS admission, bounded queues, prefill/decode phase
  separation, one shared decode forward, and dynamic per-row insert/remove
  (FR-CB1..FR-CB5).
- Scheduler-owned per-request block tables over the `SPEC-039` paged engine.
  `SPEC-039` owns paged KV storage, block allocation internals, and the
  attention kernel; `SPEC-038` owns which request maps to which blocks and
  when those mappings enter or leave a batch (FR-CB4).
- Per-request sampling, stop, cancellation, usage, and receipt state that is
  provably isolated under the shared forward (FR-CB6), owned by a single actor
  (FR-CB7).
- Explicit, observable rejection of unsupported cache classes, paged-engine
  capabilities, and `kv_bits` modes - never a silent downgrade (FR-CB8,
  FR-CB10).
- A serial fallback path identical to today's behavior when the flag is off,
  and as a safe mode after scheduler failure or for unsupported models
  (FR-CB9).
- Exact Entry 110 capacity mapping: the active-row cap equals the persisted
  `max_concurrency_override`; queued work never inflates advertised capacity
  (FR-CB11).
- SPEC-028 speculative decoding remains single-slot and mutually exclusive
  with batching in this release (FR-CB12).
- Warm-swap drain semantics and served-model-snapshot binding for accepted
  and queued work (FR-CB13).
- The MSB-01..05 throughput-replication gate: no throughput number ships
  unless it was measured on real macprovider catalog models (FR-CB14).
- The real-hardware enable gate (FR-CB15) and the scheduler/engine boundary
  with `SPEC-039` (FR-CB16).

Out of scope for v0.2:

- Any change to LOCKED SPEC-015 receipts, or to the SPEC-024
  `cached_prompt_tokens` / prefix-reuse wire semantics, the reuse predicate,
  or SPEC-005 billing arithmetic. The scheduler preserves these; it does not
  re-own them.
- Implementing the `SPEC-039` paged KV / paged-attention engine in this SPEC
  PR. This SPEC states scheduler obligations over that engine.
- Combined speculative decoding and continuous batching. This is deferred to a
  future research memo and SPEC (FR-CB12).
- Batch-aware quantized KV. `kv_bits` batching is a separate future promotion
  gate; unsupported quantized-KV configurations are rejected at preflight, or
  reason-coded serial-routed only when the operator explicitly selects
  permissive behavior (FR-CB8).
- Mixed-phase (prefill-plus-decode in one heterogeneous model call) batching;
  v0.2 keeps prompt and decode phases separate (FR-CB2).
- Priority, deadline, or buyer-class scheduling economics; v0.2 is FCFS
  (FR-CB1).
- Advertising capacity above the persisted Entry 110 recommendation
  (FR-CB11).

## 2. Dependencies and authority

- **SPEC-023 installer autotune / Entry 110** - the persisted
  `max_concurrency_override` recommendation pipeline. This SPEC's scheduler
  consumes that capacity policy; it MUST NOT synthesize new hardware tiers or
  advertise capacity above it. Authority domain `installer-autotune-policy` is
  preserved, not re-owned.
- **SPEC-028** - speculative decoding. Preserved single-slot; the
  `effective_max_batch = 1` and `draft_model_capacity_shortfall` preflight are
  unchanged (FR-CB12). Authority domain `speculative-decoding` untouched.
- **SPEC-015** - LOCKED receipts. Untouched; the scheduler preserves the
  locked per-request receipt tuple and adds no batch identifier to receipt
  identity (FR-CB6, FR-CB13).
- **SPEC-024** - provider prefix-cache billing isolation. The
  `cached_prompt_tokens` wire/mirror semantics, the reuse predicate, the
  `conv:` key-validation rules, and the TTL eligibility bound are unchanged;
  the scheduler converts per-conversation cache state into and out of batched
  rows without changing eligibility (FR-CB6, FR-CB4).
- **SPEC-005** - billing arithmetic/eligibility. Untouched.
- **SPEC-010** - model catalog identity; the served `model_sha256` / model
  hash the scheduler must bind to each accepted request's snapshot (FR-CB13).
- **SPEC-037** - KV survival across restarts. This SPEC registers as a
  consumer of that domain: batched state must either preserve SPEC-037's v1
  opaque-record round-trip at scheduler boundaries or remain flag-isolated
  from persistence so SPEC-037's serial path is unaffected (FR-CB16). Any
  persisted batched or paged layout that breaks the SPEC-037 v1 round-trip
  MUST require an explicit **payload codec-ID plus ABI-epoch bump and MUST NOT
  be a silent format change** (SPEC-037 §8), cross-referencing SPEC-039
  FR-PKV9's exposed layout metadata.
- **SPEC-039** - locally owned paged KV / paged-attention engine, the
  companion spec landing alongside this v0.2. It owns the paged engine
  authority domain (`paged-kv-attention`) and `SPEC-038` is its
  scheduler/serving consumer. The scheduler consumes SPEC-039 through two
  named surfaces: the **capability descriptor** (SPEC-039 FR-PKV11) that this
  spec's activation predicate matches against (FR-CB8, FR-CB10), and the
  **cache-extraction / same-conversation retention primitive** (SPEC-039
  FR-PKV10) that this spec's per-request block-table lifecycle uses to keep
  SPEC-024 cross-turn reuse eligible (FR-CB4). The engine owns physical-block
  allocation; the scheduler holds an engine-issued block-table handle and
  drives request allocation/bind/extend/release through it (SPEC-039 FR-PKV2).

SPEC-038 owns the authority domain `continuous-batching-serving`: the batch
admission/scheduling contract, shared-forward per-request isolation
invariants, scheduler-owned request-to-block-table lifecycle, support-matrix
and rejection rules, Entry 110 capacity mapping for batched serving, MoE
batching scheduler obligations, and the batching throughput-replication and
enable gates.

## 3. Terms

| Term | Meaning |
|---|---|
| Serial path | Today's shipped behavior: one `AsyncSemaphore` permit per request, each running an independent `TokenIterator`. The flag-off fallback. |
| Batch scheduler | The single-owner actor that owns admission, the prompt-processing set, the active decode batch, per-row lifecycle, and request-to-block-table mappings. |
| Shared forward | One model call whose input carries one current token for every active decode row (conceptually `[B, 1]`), producing per-row logits in one pass. |
| Decode row | An admitted request that has completed prefill and is participating in the shared decode forward. |
| Prompt-processing batch | The bounded set of newly admitted requests undergoing prefill before they become decode rows. |
| Active rows | Requests currently consuming inference capacity (prefill or decode). Capped by Entry 110 (FR-CB11). |
| Waiting queue | Received work not yet admitted to an active phase; entries are either pre-admission queued or accepted queued per FR-CB13. Only accepted queued work is snapshot-bound and drain-obligated. Bounded (FR-CB1); never counted as capacity. |
| Paged engine | The locally owned `SPEC-039` capability that stores KV in blocks and provides the paged-attention execution surface consumed by this scheduler. |
| Per-request block table | The scheduler-owned mapping from one request's logical token positions to `SPEC-039` KV blocks. It is request-private and leaves the batch only through explicit scheduler lifecycle transitions. |
| Served snapshot | The `(model artifact, model hash, weights generation)` bound to a request when it is accepted, immutable across a later warm swap (FR-CB13). |
| Entry 110 capacity | The persisted `max_concurrency_override` from the SPEC-023 autotune pipeline; the exact active-row cap (FR-CB11). |
| Local batching capability | The runtime-proved in-repo capability composed of the scheduler plus the `SPEC-039` paged engine, where support for a requested model/cache/KV tuple is determined by membership in the SPEC-039 capability descriptor plus acceptance coverage. It replaces v0.1's upstream revision gate. |
| Capability descriptor | The machine-readable advertisement the `SPEC-039` engine exposes (block size, model families, allowed cache classes, KV dtype, MoE-dispatch support); the scheduler's activation predicate is `requested tuple ∈ descriptor` (SPEC-039 FR-PKV11, FR-CB8/FR-CB10). |
| Cache-extraction / retention primitive | The `SPEC-039` operation (FR-PKV10) that materializes one sequence's block table into a standalone contiguous `KVCache`, or retains-and-reattaches its own blocks across turns of the same conversation, preserving SPEC-024 token-granular LCP/trim; the scheduler uses it for cross-turn cache continuity (FR-CB4). |
| Block-table handle | The engine-issued reference the scheduler holds for one request's block table; the engine allocates the physical blocks, the scheduler requests allocation/binds/extends/releases through the handle (SPEC-039 FR-PKV2, FR-CB4). |
| Enable gate | The FR-CB15 real-hardware exercise required before the flag may serve real traffic; distinct from a green CI/audit pass. |
| MSB-01..05 | The five throughput-replication scenarios of RESEARCH_232 Part 3, measured on real catalog models (FR-CB14). |

## 4. Normative requirements

Requirement IDs `SPEC-038-R001`..`R017` are the conformance units; the
`FR-CB*` labels below are the human-readable anchors. MUST / MUST NOT / SHOULD
are RFC-2119 normative.

### FR-CB1 - FCFS admission with bounded queues (SPEC-038-R001)

The scheduler MUST admit requests in first-come-first-served order. It MUST
NOT implement paid priority, deadline, or buyer-class ordering in v0.2. It
MUST maintain a bounded waiting queue; when the queue is full, further work
MUST be rejected with an explicit, client-visible backpressure signal before
unbounded prompt payloads or relay state accumulate. The queue limit MUST be a
bounded configured value (benchmark default `2 x slots_total`, not a permanent
policy). Relay and local HTTP admission MUST share one admission policy and
one capacity accounting; they MUST NOT maintain independent unbounded queues.

Admission MUST be gated by **paged-block-pool availability, not slot count
alone.** A request MUST NOT be admitted to prefill/decode unless the SPEC-039
engine can reserve the blocks its worst-case footprint requires within the
shared pool; when the pool cannot fund a new row, admission applies
back-pressure (holds the request in the bounded queue or rejects at the bound)
rather than admitting a row that would later fail to extend mid-decode. This
reconciles the Entry-110 active-row cap (FR-CB11) with real pool state: the cap
is an upper bound on rows, and pool availability is the admission-time gate
underneath it (FR-CB17).

### FR-CB2 - separate prompt and decode batches, decode-first (SPEC-038-R002)

The scheduler MUST keep prompt processing (prefill) and decode as separate
phases; it MUST NOT combine arbitrary prefill and one-token decode work into
one heterogeneous model call in v0.2. A request joins the shared decode batch
only after its prompt prefill completes and its request-private block table is
initialized over `SPEC-039` blocks. Scheduling MUST be decode-first: each
iteration advances the current decode batch by one token, applies per-row
sampling and stop conditions, emits tokens, removes terminal rows, processes
cancellation at a safe boundary, and only then admits and prefills new prompt
work into free capacity. Prefill MUST be bounded or chunked so a long prompt
cannot block existing decode rows for an unbounded interval.

### FR-CB3 - one shared forward for active decode rows (SPEC-038-R003)

Each decode iteration MUST invoke the model once for all active decode rows
together (one shared `[B, 1]`-shaped forward), not as `B` independent model
calls. This shared forward is the defining behavior of the feature; a
configuration that merely runs multiple concurrent iterators is the serial
path, not batching, and MUST NOT be reported as continuous batching in
telemetry (FR-CB14).

### FR-CB4 - scheduler ownership of per-request block tables (SPEC-038-R004)

The scheduler MUST own each request's block table lifecycle over the
`SPEC-039` paged engine through the **engine-issued block-table handle**
(SPEC-039 FR-PKV2). The verb **"allocate" is reserved for the engine**: the
scheduler MUST **request allocation of, bind, extend, release-completed-rows,
detach, and release** request block-table mappings only at scheduler-owned
lifecycle boundaries: admission, prefill completion, decode-step completion,
cancellation, terminal stop, request-local failure, batch-level failure, cache
commit, and warm-swap drain. The scheduler MUST NOT expose one request's block
table, cache handle, or logical token positions to another request. The
scheduler MUST NOT redefine `SPEC-039` storage layout, block size,
paged-attention kernel semantics, or allocator internals; it consumes only the
capability the engine advertises in its **capability descriptor** (SPEC-039
FR-PKV11). Per-request extraction back into standalone conversation-cache state
MUST use the SPEC-039 **cache-extraction / same-conversation retention
primitive** (SPEC-039 FR-PKV10) and MUST preserve exact SPEC-024 LCP/trim
semantics (including a mid-block LCP boundary).

### FR-CB5 - dynamic insertion and removal between decode steps (SPEC-038-R005)

The scheduler MUST support inserting a newly prefilled row into, and removing
a terminal/cancelled row from, the active decode batch between decode steps,
without disturbing the token stream, sampler state, stop state, or block table
of any other row. A request leaves when it reaches a stop sequence, its
output-token limit, is cancelled, or hits a request-local error. A
request-local failure MUST NOT terminate healthy rows when isolation is
possible; a model-forward failure affecting the whole batch MAY fail every
participating request, and that batch-level failure path MUST perform
deterministic cleanup (FR-CB7).

A **mid-decode block-extension failure** — an active decode row cannot extend
its block table because the shared paged pool is exhausted — is a
**request-local, deterministic failure of that row only** (FR-CB17): it fails
that row through the request-local terminal path, releases the row's blocks,
and leaves every other row's stream, sampler, stop state, and block table
intact. It is **not** a whole-batch failure and **not** true preemption
(evict-and-recompute); v0.2 does not preempt (FR-CB16, FR-CB17). Admission
back-pressure (FR-CB1) is the primary defense that makes this path rare.

### FR-CB6 - per-request isolation under the shared forward (SPEC-038-R006)

This is the load-bearing invariant. Under one shared forward the scheduler
MUST guarantee, per request:

- exactly one terminal result per accepted request;
- no token attributed to the wrong request;
- no cross-request sampler state, stop-sequence state, or logit-processor
  state;
- no cross-request conversation-cache or block-table exposure;
- per-request `prompt_tokens`, `output_tokens`, `cached_prompt_tokens`, and
  terminal status computed exactly as on the serial path;
- the receipt built for each request preserving the LOCKED SPEC-015
  per-request field set and computation rules, with no batch identifier in
  the receipt identity tuple.

Batch metadata (row index, batch depth, mean fill, cohort) MAY appear only in
non-receipt diagnostic telemetry (FR-CB14) and MUST NOT alter buyer-visible
token accounting. Deterministic (temperature-0) output for a request under
batching MUST match its serial-path output within the accepted numerical
tolerance.

### FR-CB7 - single-owner actor isolation (SPEC-038-R007)

All mutable batch state (queue, prompt set, decode batch, per-row lifecycle,
request block tables, cache handles, admission reservations, and terminal
bookkeeping) MUST be owned by a single Swift actor or an equivalently
single-owner isolation domain. Supported batched rows and unsupported
independent serial iterators MUST NOT run against the same resident model
concurrently without a proof of thread safety. Cancellation MUST be observed
at a bounded scheduler boundary. Cleanup after a batch-level failure MUST be
deterministic.

### FR-CB8 - explicit rejection of unsupported cache / kv_bits modes (SPEC-038-R008)

The scheduler's support determination MUST be `requested tuple ∈
engine-advertised descriptor`: it reads the **SPEC-039 capability descriptor**
(FR-PKV11 — block size, supported model families, allowed cache classes, KV
dtype, MoE-dispatch support) and admits a tuple to batching only when the
descriptor advertises it. The scheduler MUST NOT maintain a separately
self-declared support matrix that could drift from what the engine actually
serves. For a cache class, `SPEC-039` capability, MoE/expert-dispatch surface,
or quantized-KV (`kv_bits`) configuration **outside** the engine-advertised
descriptor, the runtime MUST either route the request to the serial path when
policy permits, or fail preflight with an observable, reason-coded error. It MUST NOT silently disable
configured KV quantization, silently reinterpret a quantized conversation
cache as ordinary KV, or silently downgrade the request. A requested batching
mode MUST NOT silently fall back to serial unless the operator has explicitly
selected permissive behavior; otherwise the unsupported combination fails
preflight with a named reason. Both branches MUST be observable and
reason-coded: a permissive-mode serial route MUST emit an observable
`batching_unsupported(serial_routed, <reason>)` signal, and a preflight
rejection MUST emit an observable reason-coded error.

### FR-CB9 - serial fallback identical to today (SPEC-038-R009)

When the feature flag is off (the default), provider behavior MUST be
identical to the current serial path in every observable respect: response
schemas, receipt fields and computation, per-request accounting,
`slots_total`/`slots_free`, telemetry field set, and - under greedy decoding
with no cache-residency difference - byte-identical response bodies. The
existing `AsyncSemaphore` serial path MUST be retained as (a) the flag-off
default, (b) a preflight-guarded fallback for unsupported models, and (c) a
safe mode after scheduler failure. Enabling the flag MUST NOT be a precondition
for correct serving.

Scheduler-failure fallback MUST NOT stitch batched and serial output for one
request. It MAY apply (a) to subsequent requests, or (b) to an individual
in-flight request only before any buyer-visible token, SSE frame, receipt
state, or request-log terminal state has been emitted for that request - in
which case the retry MUST reuse the request's served snapshot (FR-CB13) and
carry over no partial batched cache state. If a scheduler failure occurs after
any such visible/receipt/request-log side effect, the request MUST fail closed
through the existing SPEC-001 error/streaming terminal path and MUST NOT emit
a settlement receipt for output assembled across the batched and serial paths
(mirroring the SPEC-028 fallback boundary).

### FR-CB10 - locally owned activation capability (SPEC-038-R010)

The IMPL MUST NOT gate activation on a reviewed upstream `mlx-swift-lm` batch
API, upstream revision, or calendar fallback. The upstream pin path is removed
from this SPEC. The continuous-batching `on` state MUST activate only when a
locally owned batching capability exists for the requested
hardware/model/cache/KV/runtime tuple: the scheduler defined here plus the
`SPEC-039` paged engine capability, where support is determined by
**membership of the requested tuple in the SPEC-039 engine-advertised
capability descriptor** (FR-PKV11, FR-CB8) plus acceptance coverage for that
tuple — not a self-declared matrix. Until that local capability exists,
strict `on` MUST fail closed with an observable reason naming the missing
local capability; permissive/canary modes MAY route to serial only with
explicit operator policy and reason-coded telemetry. The activation reason
MUST reference the local capability and MUST NOT cite a missing upstream pin
as the path to success.

### FR-CB11 - Entry 110 capacity mapping (SPEC-038-R011)

The scheduler's maximum active decode rows MUST equal the persisted Entry 110
`max_concurrency_override` for the detected hardware class; it MUST NOT
synthesize new tiers or advertise capacity above it. The three quantities -
advertised slots, active batch rows, and waiting-queue depth - MUST remain
distinct: `slots_total` equals the validated persisted Entry 110 concurrency,
active accepted/runnable work MUST be `<= slots_total`, and queued work MUST
NOT inflate `slots_total`. `slots_free` MUST be derived from validated active
capacity minus active accepted/runnable work. Internal prompt-batch,
decode-batch, microbatch, paged-engine, and queue limits MAY differ but MUST
NOT change `slots_total`.

### FR-CB12 - SPEC-028 mutual exclusion (SPEC-038-R012)

Speculative decoding (SPEC-028) MUST remain single-slot and mutually exclusive
with continuous batching in this release. A draft-enabled provider MUST keep
`effective_max_batch = 1` and the existing `draft_model_capacity_shortfall`
preflight failure for an explicit `max_concurrency_override > 1`; continuous
batching MUST NOT be engaged for draft-enabled requests. Combined speculative
continuous batching is deferred to a future research memo and SPEC; it MUST
NOT be silently enabled and MUST NOT be included in any advertised throughput
multiplier (FR-CB14).

### FR-CB13 - warm-swap drain and model-snapshot binding (SPEC-038-R013)

Waiting-queue work has exactly two normative states, and no request may exist
in between:

- **Pre-admission queued** - not yet bound to a served snapshot. It has made
  no receipt or settlement attempt and MUST make none. At warm-swap drain
  start it MAY be rejected without side effect.
- **Accepted** - bound to a served snapshot. It MUST capture its served
  snapshot (model artifact, model hash, weights generation) at the instant of
  acceptance, and from that instant is subject to the drain guarantees below.

The transition from pre-admission to accepted is the single point of snapshot
capture; a scheduler delay MUST NOT permit executing an accepted request
against later warm-swapped weights while retaining the old hash, and
pre-admission work MUST NOT be assigned a snapshot retroactively.

Warm-swap drain MUST include active prompt rows, active decode rows, accepted
queued requests, block-table lifecycle cleanup, cache commits, and terminal
receipt work; once draining begins, new admission MUST be rejected and every
request bound to the old served snapshot MUST finish or be cancelled before
weights are replaced, subject to a drain timeout that cancels or fails the
remainder. No decode row may survive across model generations. The IMPL MUST
choose explicitly between (a) binding accepted queued work to the resident
generation and draining it, and (b) rejecting queued work at drain start; the
receipt's model hash MUST always match the weight snapshot that served the
request. **Operator disable-while-serving** (flipping the flag off on a live
provider) MUST drain in-flight batched work through this same drain machinery —
new admission rejected, active rows finished or cancelled under the bounded
drain timeout — before the provider reverts to the serial path; it MUST NOT
drop in-flight rows abruptly.

Relay/HTTP reconnect and retry MUST be idempotent. A reconnect or retry of a
request that is already queued, in prefill, in decode, or draining MUST NOT
produce duplicate accepted work, a duplicate terminal result, or a duplicate
settlement receipt; the scheduler MUST either reattach to the existing request
or reject the duplicate, deterministically, at every lifecycle state.

### FR-CB14 - throughput-replication gate MSB-01..05 (SPEC-038-R014)

No throughput multiplier or aggregate-TG claim may be advertised, persisted as
a capacity signal, or used in OPoI/drift comparison unless it was measured on
real macprovider catalog models per the RESEARCH_232 Part 3 measurement
contract. Every advertised vendor/maintainer multiplier is an unreplicated
hypothesis and MUST NOT be shipped as a macprovider number. Aggregate
throughput MUST be computed as total decoded tokens over the common wall-clock
interval, never as a sum of per-request elapsed durations. OPoI/drift MUST NOT
compare batched aggregate TG against a single-stream per-stream baseline;
per-stream and aggregate throughput MUST be reported as distinct values. The
Gate A2 performance thresholds (MSB-02 > 1.5x MSB-01, MSB-03 > 1.2x MSB-01,
at least one Entry 110 multi-slot tier > 1.3x aggregate TG, within the memory
bound) are the promotion thresholds; failing them triggers profiling or pivot,
not a shipped number.

**MoE throughput risk (gating expectation-setter).** On the live 128-expert /
8-active MoE (`Qwen3-Coder-30B-A3B`), a batch of 2-4 rows routes to largely
**disjoint** experts, so per-step weight-load amortization - the main source of
dense batching's uplift - is **weak**. Aggregate-TG on this MoE may therefore
**trail the dense uplift** and could fall **below the MSB-04 floor**. MSB-04 is
the **gating expectation-setter** for the MoE tuple: it MUST be measured on the
live MoE model (not extrapolated from dense MSB-02/03), and a MoE tuple that
fails MSB-04 does not ship a throughput number and remains unsupported for
batching (FR-CB16, AC-23). This is a real risk to quantify, not a promise of
dense-equivalent MoE speedup.

### FR-CB15 - real-hardware enable gate (SPEC-038-R015)

Continuous batching is a runtime feature; a green audit, CI, or unit-test pass
is not its enable gate. Before the flag may serve real traffic on a given
hardware/model/quantization/KV-mode/runtime-revision tuple, the operator MUST
complete a real-Mac exercise on that tuple demonstrating, at minimum:

- aggregate-TG measurement meeting the FR-CB14 / Gate A2 thresholds for that
  Entry 110 tier;
- per-request usage-correctness under the shared forward (per-request
  `prompt_tokens` / `output_tokens` / `cached_prompt_tokens` and receipt
  fields correct, zero cross-request attribution failure) - FR-CB6 exercised
  on real hardware, not only in unit fixtures;
- no cross-request state leak, no Metal command-buffer regression, peak RSS
  within the defined bound, warm-swap/receipt/model-hash parity (FR-CB13), and
  `SPEC-039` paged-engine support for the tuple.

Absent this evidence the flag MUST remain off for real traffic. This mirrors
the Entry-199 lesson: a dormant, default-off feature with green gates is not a
production-enabled feature. The step-by-step enable-gate procedure for
operators is captured in a provider runbook (forward reference:
`docs/runbooks/continuous-batching-enable-gate.md`, authored with the IMPL PR),
analogous to the SPEC-037 KVS graduation runbook.

Promotion of continuous batching to a production default for a tier (as
distinct from an operator-enabled canary above) additionally requires the Gate
A5 production-economics conditions (§8) to hold on measured evidence:
`sku-econ` green, material sustained provider upside (not a short burst),
acceptable tail latency and rejection rate, and an OPoI false-positive rate
below 5%. A tier failing any A5 condition MUST remain opt-in.

### FR-CB16 - SPEC-039 boundary and MoE scheduler obligations (SPEC-038-R016)

This SPEC MUST maintain a clean boundary with `SPEC-039`: `SPEC-038` owns
admission, decode-step ordering, dynamic insert/remove, per-request
block-table lifecycle over the engine-issued handle, per-request accounting,
receipt bookkeeping, fallback, and serving telemetry; `SPEC-039` owns paged KV
storage, physical-block allocation, and paged-attention execution. The
scheduler MUST NOT duplicate `SPEC-039` kernel/storage requirements in this
spec or create an alternate engine authority path.

**No true preemption in v0.2.** v0.2 does **not** perform true preemption
(evict-and-recompute of an in-flight row's KV) at the Entry-110 batch depths in
scope (`<= 4`). Under pool pressure the scheduler applies admission
back-pressure (FR-CB1) and, if an active row still cannot extend mid-decode,
fails that row request-locally (FR-CB5, FR-CB17) — it does not evict a healthy
row's blocks to recompute later. Preemption is therefore not an FR-CB16
ownership item; if a future revision adds evict-and-recompute it must specify
it explicitly.

**MoE — scheduler obligation is per-row input isolation, not expert routing.**
The scheduler does **NOT** select or route experts; expert selection is
**model-internal** (the model's own router runs inside the shared forward). For
MoE models, including the live `Qwen3-Coder-30B-A3B`, the scheduler's
obligation is to feed **each row's correct current token** into the shared
`[B, 1]` forward so the model's router sees the correct per-row input, and to
keep the **per-row expert-affected outputs, load-balancing telemetry, and
terminal/cancel accounting request-isolated** under that shared forward.
Attention paging is orthogonal to MoE per the Phase-3 spike, but continuous
batching MUST NOT treat MoE as automatically supported until the batched
shared-forward path is exercised on the live MoE tuple, meets the MSB-04 floor
(FR-CB14), and is admitted by the SPEC-039 capability descriptor (FR-CB8,
FR-CB10, FR-CB15).

### FR-CB17 - paged-pool pressure: back-pressure, not preemption (SPEC-038-R017)

Block-pool pressure under a shared paged pool MUST be handled by
**admission-time back-pressure plus deterministic request-local failure**, not
by preemption:

- **Admission-time back-pressure (FR-CB1).** A request MUST NOT be admitted
  unless the SPEC-039 engine can reserve its worst-case block footprint in the
  shared pool. Admission is gated by **pool availability**, not by Entry-110
  slot count alone (FR-CB11); when the pool cannot fund a new row, the request
  is held in the bounded queue or rejected at the bound with the FR-CB1
  client-visible backpressure signal.
- **Deterministic request-local failure (FR-CB5).** If an already-admitted
  decode row cannot extend its block table mid-decode, that **row alone** fails
  deterministically through the request-local terminal path and releases its
  blocks; healthy rows are undisturbed. This is not a whole-batch failure.
- **No true preemption (FR-CB16).** v0.2 MUST NOT evict a healthy row's KV to
  recompute it later at the Entry-110 depths in scope (`<= 4`). The active-row
  cap and admission back-pressure together make the mid-decode extension
  failure the rare, bounded fallback rather than the design's steady state.

Both the admission-time and the mid-decode paths MUST be observable and
reason-coded, and MUST NOT emit a settlement receipt for output stitched across
a failed and a retried path (mirroring FR-CB9).

## 5. Outcome table - mode matrix

The flag has the three states carried by the PR #804 scaffold: **`off`**
(default, inert serial-identical), **`canary`** (operator-enabled above serial,
reason-coded, not a production default until Gate A5 / FR-CB15), and **`on`**
(the production-default state a tier reaches only after Gate A5). `canary` and
`on` share the same serving path; they differ only in whether the tier has met
the A5 production-economics conditions (FR-CB15, §8).

| Draft model (SPEC-028) | Flag | Entry 110 depth | Local batching capability | Result |
|---|---|---:|---|---|
| Disabled | off (default) | any | any | Serial path - today's behavior, unchanged (FR-CB9) |
| Disabled | canary or on | 1 | present | Serial path (single slot); batching is a no-op at depth 1 |
| Disabled | canary or on | 2-4 (validated) | present for tuple | Continuous batch path - shared forward over `SPEC-039` paged blocks (FR-CB3, FR-CB4, FR-CB10); `on` additionally requires Gate A5 (FR-CB15) |
| Disabled | canary or on | 2-4 (validated) | absent or unsupported | Strict mode fails closed, or explicit permissive mode serial-routes with reason-coded telemetry (FR-CB8, FR-CB10) |
| Enabled | any | 1 | any | Existing SPEC-028 single-slot path (FR-CB12) |
| Enabled | any | > 1 | any | Preflight failure `draft_model_capacity_shortfall` - unchanged (FR-CB12) |
| Any | canary or on | any | unsupported cache/`kv_bits`/MoE dispatch | Serial path or reason-coded preflight rejection - never silent downgrade (FR-CB8) |

## 6. Capacity, telemetry, and OPoI boundary

- `slots_total` MUST publish the validated persisted Entry 110
  recommendation; `slots_free` is derived from validated active capacity minus
  active work; queued work is reported separately and never inflates capacity
  (FR-CB11).
- Heartbeat MAY add diagnostic fields (scheduler mode, active prompt rows,
  active decode rows, waiting-queue depth, mean batch fill, recent aggregate
  TG, recent per-stream TG, local capability state, support-matrix reason, and
  paged-engine tuple id). These are diagnostic only; they MUST NOT silently
  alter coordinator routing or allocation semantics until a later protocol
  decision (FR-CB14).
- OPoI/drift MUST keep the single-stream verified baseline for per-stream
  drift and MUST NOT feed batched aggregate TG into the existing single-stream
  drift decision until a separately-verified aggregate baseline exists
  (FR-CB14). OPoI probes remain observability-only and MUST NOT be attributed
  to a request's usage.

## 7. Acceptance criteria (fixtures)

All are required tests in `phase3-binary/Tests/` unless marked as a
hardware-capability run or a static-review obligation. Every
`SPEC-038-R0xx` requirement is exercised by at least one AC below.

- **AC-1 per-request usage correctness under shared forward (FR-CB6):** N
  concurrent requests (N up to the tier's validated depth) with distinct
  conversation identities and distinct prompts run through one shared decode
  forward; each yields exactly one terminal result, correct per-request
  `prompt_tokens` / `output_tokens` / `cached_prompt_tokens`, and a receipt
  whose LOCKED SPEC-015 field set and computation match the serial path. Zero
  tokens are attributed to the wrong request.
- **AC-2 per-request stop correctness (FR-CB6):** distinct per-row stop
  sequences and distinct output-token limits; each row stops on its own
  condition only, emits no token past its stop, and does not affect any other
  row's stream or length.
- **AC-3 per-request cancellation (FR-CB5, FR-CB7):** cancelling one row
  mid-decode removes it at a bounded boundary, produces no duplicate terminal
  output for it, and leaves every other row's stream, sampler state, stop
  state, and block table intact; the cancelled row commits cache only per
  existing semantics and releases every reservation.
- **AC-4 join/leave mid-decode + shared-forward invocation count (FR-CB5,
  FR-CB3):** a request admitted while a batch is already decoding joins after
  prefill without disturbing in-flight rows; a row that terminates is filtered
  out and its freed capacity admits queued work; the shared forward shape
  tracks the live row set. The fixture MUST assert the shared-forward
  invariant: `B` active decode rows produce exactly one model forward per
  decode step, not `B` independent forwards.
- **AC-5 serial-fallback parity (FR-CB9):** flag-off vs flag-on-at-depth-1
  produce identical response/receipt schemas, field sets, computation rules,
  and `slots_total`/`slots_free`; under greedy (temperature-0) decoding with
  no cache-residency difference, response bodies are byte-identical; the only
  permitted difference where batching legitimately overlaps requests is
  aggregate timing, never a field or accounting difference. The parity fixture
  MUST also cover the other two serial-path entries of FR-CB9 -
  permissive-mode unsupported-capability serial routing, and
  post-scheduler-failure safe-mode for subsequent requests - asserting
  unchanged buyer-visible response/receipt/accounting/`slots_total`/
  `slots_free`/greedy bytes, with only reason-coded non-receipt telemetry
  permitted to differ.
- **AC-6 deterministic output equivalence (FR-CB6):** for a fixed
  temperature-0 request, the batched-path output matches the serial-path
  output, both as a lone row and as one row among a full batch. Under greedy
  decoding the sampled token sequence MUST be identical (byte/token-identical);
  a numerical tolerance applies only where the fixture explicitly compares raw
  logits, and then the exact threshold MUST be stated in the fixture.
- **AC-7 unsupported cache/`kv_bits`/local capability rejection (FR-CB8,
  FR-CB10):** a `newCache`-overriding model family, an unsupported
  `SPEC-039` tuple, an unsupported MoE expert-dispatch surface, and an
  unsupported quantized-KV (`kv_bits`) configuration each either route to the
  serial path (permissive mode) or fail preflight with a named, observable
  reason code; none silently downgrade KV quantization, reinterpret a
  quantized cache as ordinary KV, cite a missing upstream pin, or silently
  run serial.
- **AC-8 Entry 110 capacity mapping (FR-CB11):** `slots_total` equals the
  persisted `max_concurrency_override` across each hardware tier fixture;
  active rows never exceed it; a scheduler with `slots_total` active rows and
  a full waiting queue still advertises `slots_total`, not
  `slots_total + queue`.
- **AC-9 SPEC-028 exclusion (FR-CB12):** a draft-enabled provider keeps
  `effective_max_batch = 1`; an explicit `max_concurrency_override > 1` with a
  draft model fails preflight `draft_model_capacity_shortfall`; a
  speculative-routed request acquires no batch row and triggers no shared
  forward.
- **AC-10 warm-swap drain + snapshot binding (FR-CB13):** a warm swap with
  active prompt rows, active decode rows, and accepted queued work: accepted
  queued work (snapshot-bound) drains, cancels, or fails under the old snapshot
  before weights change, while pre-admission queued work may be rejected at
  drain start per the IMPL's declared policy; no row executes against new
  weights under the old hash; each receipt's model hash matches the serving
  weights; drain timeout cancels/fails the remainder deterministically.
- **AC-11 batch-level failure cleanup (FR-CB5, FR-CB7):** an injected
  whole-batch model-forward failure fails every participating request with
  deterministic cleanup (no leaked rows, block tables, caches, or busy keys),
  while a request-local error fails only its row when isolation is possible.
- **AC-12 SPEC-037 round-trip preservation (FR-CB16):** with the batching
  flag on, an eligible conversation entry serialized/restored through the
  SPEC-037 v1 opaque-record path round-trips identically, or all batched
  scheduler/engine state is proven flag-isolated from persistence
  (SPEC-037 serial path unaffected); no scheduler-owned block table is
  persisted through the serial opaque-record path unless `SPEC-039` declares
  that representation and its ABI compatibility.
- **AC-13 aggregate-TG measurement harness + full MSB-01..05 coverage
  (FR-CB14):** the MSB harness computes aggregate TG as total decoded tokens
  over common wall-clock, reports per-stream and aggregate TG as distinct
  values, excludes warm-up, and records the full RESEARCH_232 §3.1 measurement
  fields; it refuses to sum per-request elapsed durations. The harness MUST be
  able to run all five RESEARCH_232 scenarios with their memo thresholds and
  fields: MSB-01 single-stream baseline, MSB-02, MSB-03, MSB-04, and MSB-05.
  No throughput number outside these measured scenarios may be advertised.
- **AC-14 real-hardware enable gate (FR-CB15) - hardware-capability run, not
  a CI test:** on a real Mac of the target tuple, MSB-02/MSB-03 (and the
  tier's MSB-04 where applicable) meet the Gate A2 thresholds with zero
  cross-request attribution failure, no Metal regression, peak RSS within
  bound, warm-swap/receipt/model-hash parity, and `SPEC-039` local capability
  evidence. This run is the precondition for enabling the flag on that tuple
  for real traffic; a green CI/audit pass is explicitly insufficient.
- **AC-15 FCFS admission + bounded-queue backpressure + shared admission
  (FR-CB1):** requests are admitted in arrival order; when the waiting queue
  is at its bound, further work is rejected with an explicit client-visible
  backpressure signal (no unbounded payload/relay-state growth); the relay and
  local-HTTP paths exercise the same admission policy and capacity accounting
  (a fixture drives both surfaces and asserts one shared queue, not two
  independent ones).
- **AC-16 decode-first scheduling + bounded/chunked prefill (FR-CB2):** a
  long-prompt request admitted alongside active decode rows does not block
  those rows for an unbounded interval (its prefill is bounded/chunked and
  interleaves with decode steps); prefill and decode never merge into one
  heterogeneous model call.
- **AC-17 request block-table lifecycle over SPEC-039 blocks (FR-CB4):**
  request-allocation, bind, extension, release-completed-rows, cancellation
  cleanup, extract-to-standalone (via the SPEC-039 FR-PKV10 primitive), and
  release each preserve the target request's logical token positions and never
  expose or mutate another request's block table. The fixture uses a
  `SPEC-039`-compatible fake or real paged engine interface (its capability
  descriptor and block-table handle) rather than redefining the engine
  internals in scheduler tests.
- **AC-18 single-owner actor isolation (FR-CB7):** a structural/static check
  plus a concurrency fixture proves all mutable batch state is owned by one
  actor and that supported batched rows and unsupported serial iterators are
  never run against the same resident model concurrently without a proof of
  thread safety; cancellation is observed at a bounded boundary.
- **AC-19 batched cache-billing parity (FR-CB6, SPEC-024/SPEC-005):** under
  batching, cache-billing eligibility matches the serial path across:
  a positive sticky-hit reuse (positive `cached_prompt_tokens`, correct
  discount, and matching settlement arithmetic), a non-sticky/ambiguous hit
  (`ambiguous_cache`, no discount, full-rate settlement), retry behavior
  (null/full-rate, no duplicate discount or receipt), an invalid-range
  quarantine (no discount and no cache-state exposure), and two concurrent
  distinct conversation keys with zero cross-key reuse or interference in one
  shared batch.
- **AC-20 relay/HTTP reconnect idempotence (FR-CB13):** reconnect or retry of
  a request that is queued, in prefill, in decode, and draining each yields no
  duplicate accepted work, no duplicate terminal result, and no duplicate
  settlement receipt; the scheduler deterministically reattaches or rejects.
- **AC-21 mid-request scheduler-failure boundary (FR-CB9):** a scheduler
  failure before any visible/receipt/request-log side effect may retry the
  request on the serial path reusing its served snapshot with no carried
  batched cache state; a failure after a buyer-visible token/frame/receipt
  state fails closed through the SPEC-001 terminal path and emits no
  settlement receipt for stitched batched+serial output; queued pre-admission
  work carries no snapshot and makes no settlement attempt, while accepted
  queued work binds its snapshot at acceptance (FR-CB13 two-state fixture).
- **AC-22 local capability activation gate (FR-CB10) - static-review
  obligation plus fixture:** strict `on` fails closed before the local
  scheduler-plus-`SPEC-039` capability exists; permissive mode serial-routes
  only with explicit operator policy and reason-coded telemetry; once the
  capability is registered, activation is tied to the local support matrix for
  the requested tuple. No activation code path or error text names a reviewed
  upstream batch API or missing upstream revision as the path to success.
- **AC-23 MoE batched per-row input isolation + MSB-04 (FR-CB16, FR-CB14):**
  for a MoE model fixture representative of `Qwen3-Coder-30B-A3B`, batched
  decode feeds each row's **correct current token** into the shared `[B, 1]`
  forward (the model's own router sees correct per-row input — the scheduler
  does not select experts), and the resulting **per-row expert-affected
  outputs, load-balancing telemetry, stop/cancel lifecycle, output-token
  accounting, and receipt state are request-isolated** with zero cross-row
  attribution. This is a **required correctness fixture, not a placeholder**;
  additionally, the MoE tuple's **MSB-04** aggregate-TG MUST be measured on the
  live model (FR-CB14). Until this fixture passes and MSB-04 is measured on the
  live MoE tuple, that tuple remains unsupported for continuous batching even
  though attention paging is separately proven orthogonal.
- **AC-24 paged-pool pressure: back-pressure + request-local failure, no
  preemption (FR-CB17, FR-CB1, FR-CB5):** with a batch actively decoding,
  admission of a further row that the shared paged pool cannot fund is held or
  rejected with the FR-CB1 client-visible backpressure signal (never admitted
  into a row that would fail to extend); and an injected mid-decode
  block-extension failure against **an active batched row** fails **only that
  row** deterministically, releasing its blocks, while every other row's
  stream, sampler, stop state, and block table stay intact — no healthy row's
  KV is evicted/recomputed (no preemption), and no settlement receipt is
  emitted for stitched failed+retried output.

## 8. Go/no-go gates

- **G0 local capability existence** - a locally owned batching capability is
  present for the target tuple: scheduler plus `SPEC-039` paged engine,
  support matrix, reason-coded unsupported handling, and fixture coverage
  (FR-CB8, FR-CB10).
- **G1 correctness** - deterministic parity with the serial path, no
  cross-request state, per-row cancel/stop, correct conversation-cache
  continuation, unchanged receipt fields (FR-CB6). No-go on any
  cross-request state leak.
- **G2 performance** - the FR-CB14 thresholds, measured on real catalog models
  and computed as aggregate decoded tokens over a common wall-clock interval.
- **G3 lifecycle** - warm-swap drain, no relay-reconnect duplication, model
  hash bound to the served snapshot, deterministic batch-failure cleanup
  (FR-CB13).
- **G4 unsupported-mode honesty** - unsupported cache classes, quantized KV,
  missing paged-engine capabilities, and unsupported MoE dispatch surfaces are
  rejected or serial-routed only through explicit operator policy and
  reason-coded telemetry (FR-CB8, FR-CB10).
- **G5 production economics** - `sku-econ` green, material provider upside,
  acceptable tail latency and rejection rate, OPoI false-positive rate < 5%.

## 9. No-go list

- A reviewed upstream `mlx-swift-lm` batch API or upstream revision as the
  activation authority for this feature.
- Approach C (out-of-process oMLX / mlx-lm sidecar) as production serving
  under the current receipt/attestation model.
- Approach D (llama.cpp parallel runtime) as a batching-only change.
- Combined SPEC-028 speculative decoding and continuous batching in the first
  implementation (FR-CB12).
- Advertising higher capacity than Entry 110 recommends (FR-CB11).
- Enabling unsupported `kv_bits` modes by silently changing cache policy
  (FR-CB8).
- Shipping any throughput number not measured on real macprovider catalog
  models (FR-CB14).
- Enabling the flag for real traffic on green CI/audit alone, without the
  FR-CB15 real-hardware exercise.
- Inlining or redefining the `SPEC-039` paged KV / paged-attention engine in
  scheduler code or in this scheduler spec (FR-CB16).

## 10. Open questions carried (non-blocking for v0.2)

These questions must be resolved before a production default but do not block
this SPEC:

1. *(Resolved in v0.2)* The `SPEC-039` capability interface the scheduler
   consumes is now normative, not an open question: the scheduler matches
   `requested tuple ∈ engine-advertised capability descriptor` (SPEC-039
   FR-PKV11) for activation (FR-CB8, FR-CB10) and uses the SPEC-039
   cache-extraction / same-conversation retention primitive (FR-PKV10) for
   cross-turn cache continuity (FR-CB4). The remaining open item is only the
   concrete Swift signature, settled with the IMPL.
2. Actor boundary satisfying Swift Sendability without unnecessary KV copies.
3. Cancellation removal latency for a decode row.
4. Which `kv_bits` configurations must initially be rejected vs serial-routed.
5. Queue limit best matching coordinator retry behavior.
6. Whether M-Ultra depth four outperforms depth three after tail-latency
   penalties.
7. How aggregate-TG baselines are versioned for OPoI drift.
8. The first MoE **per-row input-isolation** fixture shape for
   `Qwen3-Coder-30B-A3B` (AC-23 defines the required correctness properties;
   the concrete fixture and the live-hardware MSB-04 run remain to be built).
9. The promotion sequencing between the `SPEC-039` engine PR and the
   `SPEC-038` scheduler IMPL PR.
