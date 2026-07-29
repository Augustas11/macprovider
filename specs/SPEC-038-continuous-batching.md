# SPEC-038 — Continuous batching for concurrent provider inference

> **⚠ SUPERSEDED — pending v0.2 paged rewrite (do NOT implement this version).** v0.1 was written on the original RESEARCH_232 memo's now-**falsified** framing: Approach-A "pin a reviewed upstream `mlx-swift-lm` batch API" (FR-CB10) and dense/contiguous KV. Upstream will never deliver that API (PR #263 abandoned), and the strategic engine is **paged** (memory-servability), built **in-house** — proven additively feasible with no `mlx` fork (spikes `e5ded571` + `acc30b1e`). The serving-safety/correctness half (feature flag, serial-fallback-identical, per-request usage/receipt isolation, actor isolation, admission, spec-decode exclusion, telemetry) **survives**; the upstream-pin spine and dense-KV assumption do **not**. Rewrite path: reframe activation to *locally-owned capability* + split the paged-KV/paged-attention engine into its own spec. See `docs/research/RESEARCH_232_ADDENDUM_PAGED_REDECISION_2026-07-29.md`. PR #804 (scaffold) is held pending this reframe.

Version: v0.1 (SUPERSEDED)
Status: draft (normative design; no IMPL in this SPEC — implementation is a separate PR behind a disabled-by-default flag)
Owner: provider runtime / inference scheduler
Decision source: `docs/research/RESEARCH_232_MULTISTREAM_BATCHING_MEMO.md` (landed decision memo, commit `8d80f6c4`)
Audit history: three-lane codex SPEC audit (code / security / architect). Convergence and any carried LOW/INFO findings recorded in the SPEC PR body and `audits/2026-07-29/SPEC-038-rN-audit.md`.

## 1. Purpose and scope

Raise provider aggregate throughput — and therefore provider earnings — by
moving the shared-model decode step from today's **parallel single-stream
decode** (each admitted request runs an independent `TokenIterator` under an
`AsyncSemaphore` permit) to **continuous batching**: active decode rows share
one model forward and join or leave the batch dynamically between decode
steps. The chosen path is RESEARCH_232 **Approach A** — contribute, review,
and pin an upstream `mlx-swift-lm` batch API modeled on Python `mlx-lm`'s
`BatchGenerator`, integrated behind a macprovider feature flag — with
**Approach B** (a narrow macprovider-owned Swift batch scheduler) as the
declared fallback if the upstream path misses a calendar or correctness gate.

This is a **money-path** change. Under one shared forward, per-request token
usage, stop conditions, cancellation, and the receipt each request emits are
no longer isolated by separate iterators; correctness of that per-request
accounting is the load-bearing invariant of this SPEC (FR-CB6). A single
mis-attributed token is a billing and provider-earnings defect, not merely a
serving glitch.

The feature is **disabled by default** and enables nothing on merge of either
this SPEC or its IMPL. When the flag is off, the provider MUST behave
byte-for-byte as it does today (FR-CB9). Turning it on for real traffic is
gated on the acceptance criteria of §7 and, decisively, on the
real-hardware enable gate of FR-CB15 — a green CI/audit/unit-test pass is
**not** the enable gate for this runtime feature.

In scope for v0.1:

- An actor-isolated batch scheduler behind the existing generation path
  (`ModelRuntime`), with FCFS admission, bounded queues, separate
  prompt-processing and decode batches, one shared decode forward, dense
  contiguous batch-aware KV caches, and dynamic per-row insert/remove
  (FR-CB1..FR-CB5).
- Per-request sampling, stop, cancellation, usage, and receipt state that is
  provably isolated under the shared forward (FR-CB6), owned by a single
  actor (FR-CB7).
- Explicit, observable rejection of unsupported cache classes and `kv_bits`
  modes — never a silent downgrade (FR-CB8).
- A serial fallback path identical to today's behavior when the flag is off,
  and as a safe mode after scheduler failure or for unsupported models
  (FR-CB9).
- A version-pin policy to a reviewed upstream tag/revision, and the
  Approach-B fallback trigger (FR-CB10).
- Exact Entry 110 capacity mapping: the active-row cap equals the persisted
  `max_concurrency_override`; queued work never inflates advertised capacity
  (FR-CB11).
- SPEC-028 speculative decoding remains single-slot and mutually exclusive
  with batching in this release (FR-CB12).
- Warm-swap drain semantics and served-model-snapshot binding for accepted
  and queued work (FR-CB13).
- The MSB-01–05 throughput-replication gate: no throughput number ships
  unless it was measured on real macprovider catalog models (FR-CB14).
- The real-hardware enable gate (FR-CB15) and independence from
  SPEC-037 / RESEARCH_233 (FR-CB16).

Out of scope for v0.1 (recorded, not silently dropped):

- Any change to LOCKED SPEC-015 receipts, or to the SPEC-024
  `cached_prompt_tokens` / prefix-reuse wire semantics, the reuse predicate,
  or SPEC-005 billing arithmetic. The scheduler preserves these; it does not
  re-own them.
- A paged-attention kernel or shared paged-KV allocator (no-go, §9).
- Combined speculative decoding and continuous batching — deferred to a
  future research memo and SPEC (FR-CB12, §9).
- Batch-aware **quantized** KV. `kv_bits` batching is a separate future
  promotion gate; in v0.1 unsupported quantized-KV configurations are rejected
  at preflight, or reason-coded serial-routed only when the operator explicitly
  selects permissive behavior (FR-CB8).
- Mixed-phase (prefill-plus-decode in one heterogeneous model call)
  batching; v0.1 keeps prompt and decode phases separate (FR-CB2).
- Priority, deadline, or buyer-class scheduling economics; v0.1 is FCFS
  (FR-CB1).
- Advertising capacity above the persisted Entry 110 recommendation
  (FR-CB11, §9).

## 2. Dependencies and authority

- **SPEC-023 v0.8.1 installer autotune / Entry 110** — the persisted
  `max_concurrency_override` recommendation pipeline. This SPEC's scheduler
  **consumes** that capacity policy; it MUST NOT synthesize new hardware
  tiers or advertise capacity above it. Authority domain
  `installer-autotune-policy` is preserved, not re-owned.
- **SPEC-028** — speculative decoding. Preserved single-slot; the
  `effective_max_batch = 1` and `draft_model_capacity_shortfall` preflight
  are unchanged (FR-CB12). Authority domain `speculative-decoding` untouched.
- **SPEC-015** — LOCKED receipts. Untouched; the scheduler preserves the
  locked per-request receipt tuple and adds no batch identifier to receipt
  identity (FR-CB6, FR-CB13).
- **SPEC-024** — provider prefix-cache billing isolation. The
  `cached_prompt_tokens` wire/mirror semantics, the reuse predicate, the
  `conv:` key-validation rules, and the TTL eligibility bound are unchanged;
  the scheduler converts per-conversation cache state into and out of
  supported batch rows without changing eligibility (FR-CB6, FR-CB4).
- **SPEC-005** — billing arithmetic/eligibility. Untouched.
- **SPEC-010** — model catalog identity; the served `model_sha256` / model
  hash the scheduler must bind to each accepted request's snapshot (FR-CB13).
- **SPEC-037** — KV survival across restarts (`kv-cache-persistence`). This
  SPEC registers as a **consumer** of that domain: its dense/contiguous
  batch-aware KV layout MUST either retain SPEC-037's v1 opaque-record
  round-trip for unchanged layouts, or keep any layout change flag-isolated
  from persistence so SPEC-037's serial path is unaffected (FR-CB16). The two
  tracks are architecturally **INDEPENDENT** per the RESEARCH_232 reciprocal
  verdict; no shared paged allocator is introduced.

SPEC-038 owns the new authority domain `continuous-batching-serving`: the
batch admission/scheduling contract, the shared-forward per-request isolation
invariants, the batch-aware cache-class support matrix and its rejection
rules, the Entry 110 capacity mapping for batched serving, and the batching
throughput-replication and enable gates.

## 3. Terms

| Term | Meaning |
|---|---|
| Serial path | Today's shipped behavior: one `AsyncSemaphore` permit per request, each running an independent `TokenIterator`. The flag-off fallback. |
| Batch scheduler | The single-owner actor that owns admission, the prompt-processing set, the active decode batch, and per-row lifecycle. |
| Shared forward | One model call whose input carries one current token for every active decode row (conceptually `[B, 1]`), producing per-row logits in one pass. |
| Decode row | An admitted request that has completed prefill and is participating in the shared decode forward. |
| Prompt-processing batch | The bounded set of newly admitted requests undergoing prefill before they become decode rows. |
| Active rows | Requests currently consuming inference capacity (prefill or decode). Capped by Entry 110 (FR-CB11). |
| Waiting queue | Received work not yet admitted to an active phase; entries are either **pre-admission queued** or **accepted queued** per FR-CB13 (only accepted queued work is snapshot-bound and drain-obligated). Bounded (FR-CB1); never counted as capacity. |
| Batch-aware KV cache | A dense, contiguous, per-request-extractable cache representation (mlx-lm `BatchKVCache`-style), padded to the longest active row. Not a paged allocator. |
| Served snapshot | The `(model artifact, model hash, weights generation)` bound to a request when it is accepted, immutable across a later warm swap (FR-CB13). |
| Entry 110 capacity | The persisted `max_concurrency_override` from the SPEC-023 autotune pipeline; the exact active-row cap (FR-CB11). |
| Enable gate | The FR-CB15 real-hardware exercise required before the flag may serve real traffic; distinct from a green CI/audit pass. |
| MSB-01..05 | The five throughput-replication scenarios of RESEARCH_232 Part 3, measured on real catalog models (FR-CB14). |

## 4. Normative requirements

Requirement IDs `SPEC-038-R001`..`R016` are the conformance units; the
`FR-CB*` labels below are the human-readable anchors. MUST / MUST NOT / SHOULD
are RFC-2119 normative.

### FR-CB1 — FCFS admission with bounded queues (SPEC-038-R001)

The scheduler MUST admit requests in first-come-first-served order. It MUST
NOT implement paid priority, deadline, or buyer-class ordering in v0.1. It
MUST maintain a **bounded** waiting queue; when the queue is full, further
work MUST be rejected with an explicit, client-visible backpressure signal
before unbounded prompt payloads or relay state accumulate. The queue limit
MUST be a bounded configured value (benchmark default `2 × slots_total`, not
a permanent policy). Relay and local HTTP admission MUST share one admission
policy and one capacity accounting; they MUST NOT maintain independent
unbounded queues.

### FR-CB2 — separate prompt and decode batches, decode-first (SPEC-038-R002)

The scheduler MUST keep prompt processing (prefill) and decode as **separate
phases**; it MUST NOT combine arbitrary prefill and one-token decode work into
one heterogeneous model call in v0.1. A request joins the shared decode batch
only after its prompt prefill completes. Scheduling MUST be decode-first: each
iteration advances the current decode batch by one token, applies per-row
sampling and stop conditions, emits tokens, removes terminal rows, processes
cancellation at a safe boundary, and only then admits and prefills new prompt
work into free capacity. Prefill MUST be bounded or chunked so a long prompt
cannot block existing decode rows for an unbounded interval.

### FR-CB3 — one shared forward for active decode rows (SPEC-038-R003)

Each decode iteration MUST invoke the model **once** for all active decode
rows together (one shared `[B, 1]`-shaped forward), not as `B` independent
model calls. This shared forward is the defining behavior of the feature; a
configuration that merely runs multiple concurrent iterators is the serial
path, not batching, and MUST NOT be reported as continuous batching in
telemetry (FR-CB14).

### FR-CB4 — dense, contiguous, batch-aware KV caches (SPEC-038-R004)

Batched KV state MUST use a **dense, contiguous, batch-aware** cache
representation (mlx-lm `BatchKVCache` / `BatchRotatingKVCache` shape), rows
aligned to the longest active cache length, growing in contiguous token
increments, supporting extend / filter-completed-rows / concatenate /
extract-row-to-standalone. It MUST NOT introduce a shared paged-KV allocator,
per-request block tables, copy-on-write prefix sharing, or a
PagedAttention-style attention kernel (§9, FR-CB16). Per-request extraction
back into standalone `[KVCache]` conversation-cache state MUST preserve exact
SPEC-024 LCP/trim semantics.

### FR-CB5 — dynamic insertion and removal between decode steps (SPEC-038-R005)

The scheduler MUST support inserting a newly prefilled row into, and removing
a terminal/cancelled row from, the active decode batch **between** decode
steps, without disturbing the token stream, sampler state, stop state, or
cache of any other row. A request leaves when it reaches a stop sequence, its
output-token limit, is cancelled, or hits a request-local error. A
request-local failure MUST NOT terminate healthy rows when isolation is
possible; a model-forward failure affecting the whole batch MAY fail every
participating request, and that batch-level failure path MUST perform
deterministic cleanup (FR-CB7).

### FR-CB6 — per-request isolation under the shared forward (SPEC-038-R006)

This is the load-bearing invariant. Under one shared forward the scheduler
MUST guarantee, per request:

- exactly one terminal result per accepted request;
- no token attributed to the wrong request;
- no cross-request sampler state, stop-sequence state, or logit-processor
  state;
- no cross-request conversation-cache exposure;
- per-request `prompt_tokens`, `output_tokens`, `cached_prompt_tokens`, and
  terminal status computed exactly as on the serial path;
- the receipt built for each request preserving the LOCKED SPEC-015
  per-request field set and computation rules, with **no batch identifier**
  in the receipt identity tuple.

Batch metadata (row index, batch depth, mean fill, cohort) MAY appear only in
non-receipt diagnostic telemetry (FR-CB14) and MUST NOT alter buyer-visible
token accounting. Deterministic (temperature-0) output for a request under
batching MUST match its serial-path output within the accepted numerical
tolerance.

### FR-CB7 — single-owner actor isolation (SPEC-038-R007)

All mutable batch state (queue, prompt set, decode batch, per-row lifecycle,
cache handles) MUST be owned by a single Swift actor (or an equivalently
single-owner isolation domain). Supported batched rows and unsupported
independent serial iterators MUST NOT run against the same resident model
concurrently without a proof of thread safety. Cancellation MUST be observed
at a bounded scheduler boundary. Cleanup after a batch-level failure MUST be
deterministic.

### FR-CB8 — explicit rejection of unsupported cache / kv_bits modes (SPEC-038-R008)

The scheduler MUST declare its supported cache classes and `kv_bits` modes.
For an unsupported cache class (e.g. a `newCache`-overriding model family or a
cache subclass the pinned batch API does not implement) or an unsupported
quantized-KV (`kv_bits`) configuration, the runtime MUST **either** route the
request to the serial path when policy permits, **or** fail preflight with an
observable, reason-coded error. It MUST NOT silently disable configured KV
quantization, silently reinterpret a quantized conversation cache as ordinary
KV, or silently downgrade the request. A requested batching mode MUST NOT
silently fall back to serial unless the operator has explicitly selected
permissive behavior; otherwise the unsupported combination fails preflight
with a named reason. **Both** branches MUST be observable and reason-coded:
a permissive-mode serial route MUST emit an observable
`batching_unsupported(serial_routed, <reason>)` signal, and a preflight
rejection MUST emit an observable reason-coded error. Neither may be a silent
no-op.

### FR-CB9 — serial fallback identical to today (SPEC-038-R009)

When the feature flag is off (the default), provider behavior MUST be
identical to the current serial path in every observable respect: response
schemas, receipt fields and computation, per-request accounting,
`slots_total`/`slots_free`, telemetry field set, and — under greedy decoding
with no cache-residency difference — byte-identical response bodies. The
existing `AsyncSemaphore` serial path MUST be retained as (a) the flag-off
default, (b) a preflight-guarded fallback for unsupported models, and (c) a
safe mode after scheduler failure. Enabling the flag MUST NOT be a
precondition for correct serving.

Scheduler-failure fallback MUST NOT stitch batched and serial output for one
request. It MAY apply (a) to subsequent requests, or (b) to an individual
in-flight request **only before** any buyer-visible token, SSE frame, receipt
state, or request-log terminal state has been emitted for that request — in
which case the retry MUST reuse the request's served snapshot (FR-CB13) and
carry over no partial batched cache state. If a scheduler failure occurs
**after** any such visible/receipt/request-log side effect, the request MUST
fail closed through the existing SPEC-001 error/streaming terminal path and
MUST NOT emit a settlement receipt for output assembled across the batched and
serial paths (mirroring the SPEC-028 §fallback boundary).

### FR-CB10 — version pin and Approach-B fallback (SPEC-038-R010)

The IMPL MUST pin a **reviewed** upstream `mlx-swift-lm` tag or revision for
the batch API (Approach A); it MUST NOT float an unreviewed batch API into the
serve path. If no acceptable upstream merge, stable branch, or pin-ready
revision satisfying the API-viability gate (RESEARCH_232 Gate A0) exists by
the RESEARCH_232 upstream-calendar gate (Gate A4, end of Q3 2026), the IMPL
MUST activate **Approach B** — a narrow macprovider-owned Swift scheduler kept
close to upstream semantics — rather than defaulting to a sidecar (Approach C)
or runtime swap (Approach D), both of which are production no-go (§9). The
pinned revision and the supported cache/model matrix MUST be recorded in the
IMPL. A **correctness or lifecycle** gate failure is equally binding: if a
pin-ready upstream batch API fails the Gate A1 correctness or Gate A3
lifecycle gate (§8) and the defect is an unavoidable upstream API limitation
rather than fixable macprovider integration overhead, the IMPL MUST either
activate Approach B or invoke the no-go stop condition; it MUST NOT ship the
failing upstream API into the serve path. "Misses a calendar **or**
correctness gate" is the fallback trigger, not calendar alone.

### FR-CB11 — Entry 110 capacity mapping (SPEC-038-R011)

The scheduler's maximum active decode rows MUST equal the persisted Entry 110
`max_concurrency_override` for the detected hardware class; it MUST NOT
synthesize new tiers or advertise capacity above it. The three quantities —
advertised slots, active batch rows, and waiting-queue depth — MUST remain
distinct: `slots_total` equals the validated persisted Entry 110 concurrency,
active accepted/runnable work MUST be `≤ slots_total`, and queued work MUST
NOT inflate `slots_total`. `slots_free` MUST be derived from validated active
capacity minus active accepted/runnable work. Internal prompt-batch,
decode-batch, microbatch, and queue limits MAY differ but MUST NOT change
`slots_total`.

### FR-CB12 — SPEC-028 mutual exclusion (SPEC-038-R012)

Speculative decoding (SPEC-028) MUST remain single-slot and mutually
exclusive with continuous batching in this release. A draft-enabled provider
MUST keep `effective_max_batch = 1` and the existing
`draft_model_capacity_shortfall` preflight failure for an explicit
`max_concurrency_override > 1`; continuous batching MUST NOT be engaged for
draft-enabled requests. Combined speculative continuous batching is
**deferred** to a future research memo and SPEC; it MUST NOT be silently
enabled and MUST NOT be included in any advertised throughput multiplier
(FR-CB14).

### FR-CB13 — warm-swap drain and model-snapshot binding (SPEC-038-R013)

Waiting-queue work has exactly two normative states, and no request may exist
in between:

- **Pre-admission queued** — not yet bound to a served snapshot. It has made
  no receipt or settlement attempt and MUST make none. At warm-swap drain
  start it MAY be rejected without side effect.
- **Accepted** — bound to a served snapshot. It MUST capture its served
  snapshot (model artifact, model hash, weights generation) **at the instant
  of acceptance**, and from that instant is subject to the drain guarantees
  below.

The transition from pre-admission to accepted is the single point of snapshot
capture; a scheduler delay MUST NOT permit executing an accepted request
against later warm-swapped weights while retaining the old hash, and
pre-admission work MUST NOT be assigned a snapshot retroactively.

Warm-swap drain MUST include active prompt rows, active decode rows, accepted
queued requests, cache commits, and terminal receipt work; once draining
begins, new admission MUST be rejected and every request bound to the old
served snapshot MUST finish or be cancelled before weights are replaced,
subject to a drain timeout that cancels or fails the remainder. No decode row
may survive across model generations. The IMPL MUST choose explicitly between
(a) binding accepted queued work to the resident generation and draining it,
and (b) rejecting queued work at drain start; the receipt's model hash MUST
always match the weight snapshot that served the request.

**Relay/HTTP reconnect and retry MUST be idempotent.** A reconnect or retry of
a request that is already queued, in prefill, in decode, or draining MUST NOT
produce duplicate accepted work, a duplicate terminal result, or a duplicate
settlement receipt; the scheduler MUST either reattach to the existing request
or reject the duplicate, deterministically, at every lifecycle state.

### FR-CB14 — throughput-replication gate MSB-01..05 (SPEC-038-R014)

No throughput multiplier or aggregate-TG claim may be advertised, persisted as
a capacity signal, or used in OPoI/drift comparison unless it was **measured
on real macprovider catalog models** per the RESEARCH_232 Part 3 measurement
contract. Every advertised vendor/maintainer multiplier (oMLX 4.14×,
vllm-mlx ~2.38×, LM Studio ~2.2×, etc.) is an **unreplicated hypothesis** and
MUST NOT be shipped as a macprovider number. Aggregate throughput MUST be
computed as total decoded tokens over the common wall-clock interval, never as
a sum of per-request elapsed durations. OPoI/drift MUST NOT compare batched
aggregate TG against a single-stream per-stream baseline; per-stream and
aggregate throughput MUST be reported as distinct values. The Gate A2
performance thresholds (MSB-02 > 1.5× MSB-01, MSB-03 > 1.2× MSB-01, at least
one Entry 110 multi-slot tier > 1.3× aggregate TG, within the memory bound)
are the promotion thresholds; failing them triggers profiling or pivot, not a
shipped number.

### FR-CB15 — real-hardware enable gate (SPEC-038-R015)

Continuous batching is a runtime feature; a green audit, CI, or unit-test pass
is **not** its enable gate. Before the flag may serve real traffic on a given
hardware/model/quantization/KV-mode/runtime-revision tuple, the operator MUST
complete a **real-Mac** exercise on that tuple demonstrating, at minimum:

- aggregate-TG measurement meeting the FR-CB14 / Gate A2 thresholds for that
  Entry 110 tier;
- per-request usage-correctness under the shared forward (per-request
  `prompt_tokens` / `output_tokens` / `cached_prompt_tokens` and receipt
  fields correct, zero cross-request attribution failure) — FR-CB6 exercised
  on real hardware, not only in unit fixtures;
- no cross-request state leak, no Metal command-buffer regression, peak RSS
  within the defined bound, and warm-swap/receipt/model-hash parity (FR-CB13).

Absent this evidence the flag MUST remain off for real traffic. This mirrors
the Entry-199 lesson: a dormant, default-off feature with green gates is not a
production-enabled feature.

Promotion of continuous batching to a **production default** for a tier (as
distinct from an operator-enabled canary above) additionally requires the Gate
A5 production-economics conditions (§8) to hold on measured evidence:
`sku-econ` green, material sustained provider upside (not a short burst),
acceptable tail latency and rejection rate, and an OPoI false-positive rate
below 5%. A tier failing any A5 condition MUST remain opt-in.

### FR-CB16 — independence from SPEC-037 / RESEARCH_233 (SPEC-038-R016)

This SPEC MUST NOT require a shared paged-KV allocator, and therefore proceeds
**independently** of SPEC-037 / RESEARCH_233 persistence. The batch-aware
cache layout MUST either preserve SPEC-037's v1 opaque-record round-trip for
unchanged layouts, or keep any layout change **flag-isolated** from
persistence so SPEC-037's serial persistence path is unaffected. Any
cache-class or layout change that breaks SPEC-037 v1 round-trip compatibility
requires a new payload codec ID and ABI-epoch bump on that side and MUST NOT
be introduced silently. If a future upstream batch API becomes paged-only, the
relationship becomes LAYOUT-BOUND and requires re-sequencing (RESEARCH_232
§2.2); v0.1 does not invoke that pivot.

## 5. Outcome table — mode matrix

| Draft model (SPEC-028) | Flag | Entry 110 depth | Result |
|---|---|---:|---|
| Disabled | off (default) | any | Serial path — today's behavior, unchanged (FR-CB9) |
| Disabled | on | 1 | Serial path (single slot); batching is a no-op at depth 1 |
| Disabled | on | 2–4 (validated) | Continuous batch path — shared forward (FR-CB3) |
| Enabled | any | 1 | Existing SPEC-028 single-slot path (FR-CB12) |
| Enabled | any | > 1 | Preflight failure `draft_model_capacity_shortfall` — unchanged (FR-CB12) |
| Any | on | any, unsupported cache/`kv_bits` | Serial path or reason-coded preflight rejection — never silent downgrade (FR-CB8) |

## 6. Capacity, telemetry, and OPoI boundary

- `slots_total` MUST publish the validated persisted Entry 110 recommendation;
  `slots_free` is derived from validated active capacity minus active work;
  queued work is reported separately and never inflates capacity (FR-CB11).
- Heartbeat MAY add diagnostic fields (scheduler mode, active prompt rows,
  active decode rows, waiting-queue depth, mean batch fill, recent aggregate
  TG, recent per-stream TG). These are diagnostic only; they MUST NOT silently
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
`SPEC-038-R0xx` requirement is exercised by at least one AC below; the two
proof obligations that are not runtime-testable (the version pin and the
Approach-B fallback of FR-CB10) are discharged as **static-review evidence**
in AC-22.

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
  state, and cache intact; the cancelled row commits cache only per existing
  semantics and releases every reservation.
- **AC-4 join/leave mid-decode + shared-forward invocation count (FR-CB5,
  FR-CB3):** a request admitted while a batch is already decoding joins after
  prefill without disturbing in-flight rows; a row that terminates is filtered
  out and its freed capacity admits queued work; the shared forward shape
  tracks the live row set. The fixture MUST assert the shared-forward
  invariant: `B` active decode rows produce exactly **one** model forward per
  decode step, not `B` independent forwards.
- **AC-5 serial-fallback parity (FR-CB9):** flag-off vs flag-on-at-depth-1
  produce identical response/receipt schemas, field sets, computation rules,
  and `slots_total`/`slots_free`; under greedy (temperature-0) decoding with
  no cache-residency difference, response bodies are byte-identical; the only
  permitted difference where batching legitimately overlaps requests is
  aggregate timing, never a field or accounting difference. The parity fixture
  MUST also cover the other two serial-path entries of FR-CB9 — permissive-mode
  unsupported-cache/`kv_bits` serial routing, and post-scheduler-failure
  safe-mode for subsequent requests — asserting unchanged buyer-visible
  response/receipt/accounting/`slots_total`/`slots_free`/greedy bytes, with only
  reason-coded non-receipt telemetry permitted to differ.
- **AC-6 deterministic output equivalence (FR-CB6):** for a fixed
  temperature-0 request, the batched-path output matches the serial-path
  output, both as a lone row and as one row among a full batch. Under greedy
  decoding the sampled token sequence MUST be identical (byte/token-identical);
  a numerical tolerance applies only where the fixture explicitly compares raw
  logits, and then the exact threshold MUST be stated in the fixture.
- **AC-7 unsupported cache/`kv_bits` rejection (FR-CB8):** a `newCache`-
  overriding model family (e.g. gpt-oss / gemma / nemotron) and an
  unsupported quantized-KV (`kv_bits`) configuration each either route to the
  serial path (permissive mode) or fail preflight with a named, observable
  reason code; neither silently downgrades KV quantization nor reinterprets a
  quantized cache as ordinary KV; a once-per-attach unsupported-model notice
  is logged.
- **AC-8 Entry 110 capacity mapping (FR-CB11):** `slots_total` equals the
  persisted `max_concurrency_override` across each hardware tier fixture;
  active rows never exceed it; a scheduler with `slots_total` active rows and
  a full waiting queue still advertises `slots_total`, not `slots_total + queue`.
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
  deterministic cleanup (no leaked rows, caches, or busy keys), while a
  request-local error fails only its row when isolation is possible.
- **AC-12 SPEC-037 round-trip preservation (FR-CB16):** with the batching
  flag on, an eligible conversation entry serialized/restored through the
  SPEC-037 v1 opaque-record path round-trips identically, or the layout change
  is proven flag-isolated from persistence (SPEC-037 serial path unaffected);
  no paged blocks, CoW sharing, or new attention allocator are introduced.
- **AC-13 aggregate-TG measurement harness + full MSB-01..05 coverage
  (FR-CB14):** the MSB harness computes aggregate TG as total decoded tokens
  over common wall-clock, reports per-stream and aggregate TG as distinct
  values, excludes warm-up, and records the full RESEARCH_232 §3.1 measurement
  fields; it refuses to sum per-request elapsed durations. The harness MUST be
  able to run **all five** RESEARCH_232 scenarios with their memo thresholds
  and fields: MSB-01 single-stream baseline (≥20 valid runs, CV ≤10%, zero
  correctness errors, peak RSS ≤85% RAM), MSB-02 (>1.5× MSB-01), MSB-03
  (>1.2× MSB-01), MSB-04 (>1.3× single-stream MoE), and MSB-05 (native vs
  pinned-oMLX-oracle paired comparison — ≥30 paired runs, matching accepted
  request count, aggregate-TG ratio 95% bootstrap CI width ≤0.20, and the
  prototype-promotion thresholds ≥0.80× sidecar and ≥1.3× native
  single-stream). No throughput number outside these measured scenarios may be
  advertised.
- **AC-14 real-hardware enable gate (FR-CB15) — hardware-capability run, not
  a CI test:** on a real Mac of the target tuple, MSB-02/MSB-03 (and the
  tier's MSB-04 where applicable) meet the Gate A2 thresholds with zero
  cross-request attribution failure, no Metal regression, peak RSS within
  bound, and warm-swap/receipt/model-hash parity. This run is the
  precondition for enabling the flag on that tuple for real traffic; a green
  CI/audit pass is explicitly insufficient.
- **AC-15 FCFS admission + bounded-queue backpressure + shared admission
  (FR-CB1):** requests are admitted in arrival order; when the waiting queue
  is at its bound, further work is rejected with an explicit client-visible
  backpressure signal (no unbounded payload/relay-state growth); the relay and
  local-HTTP paths exercise the **same** admission policy and capacity
  accounting (a fixture drives both surfaces and asserts one shared queue, not
  two independent ones).
- **AC-16 decode-first scheduling + bounded/chunked prefill (FR-CB2):** a
  long-prompt request admitted alongside active decode rows does not block
  those rows for an unbounded interval (its prefill is bounded/chunked and
  interleaves with decode steps); prefill and decode never merge into one
  heterogeneous model call.
- **AC-17 dense batch-aware cache row operations (FR-CB4):** extend,
  filter-completed-rows, concatenate, and extract-row-to-standalone each
  produce correct per-row state under mixed history lengths; a row extracted
  back to standalone `[KVCache]` preserves exact SPEC-024 LCP/trim semantics;
  no paged block table or shared paged allocator is used.
- **AC-18 single-owner actor isolation (FR-CB7):** a structural/static check
  plus a concurrency fixture proves all mutable batch state is owned by one
  actor and that supported batched rows and unsupported serial iterators are
  never run against the same resident model concurrently without a proof of
  thread safety; cancellation is observed at a bounded boundary.
- **AC-19 batched cache-billing parity (FR-CB6, SPEC-024/SPEC-005):** under
  batching, cache-billing eligibility matches the serial path across:
  a positive sticky-hit reuse (positive `cached_prompt_tokens`, correct
  discount), a non-sticky/ambiguous hit (`ambiguous_cache`, no discount),
  retry behavior (null/full-rate), an invalid-range quarantine, and two
  concurrent distinct conversation keys with zero cross-key reuse or
  interference in one shared batch.
- **AC-20 relay/HTTP reconnect idempotence (FR-CB13):** reconnect or retry of
  a request that is queued, in prefill, in decode, and draining each yields no
  duplicate accepted work, no duplicate terminal result, and no duplicate
  settlement receipt; the scheduler deterministically reattaches or rejects.
- **AC-21 mid-request scheduler-failure boundary (FR-CB9):** a scheduler
  failure before any visible/receipt/request-log side effect may retry the
  request on the serial path reusing its served snapshot with no carried
  batched cache state; a failure after a buyer-visible token/frame/receipt
  state fails closed through the SPEC-001 terminal path and emits no settlement
  receipt for stitched batched+serial output; queued pre-admission work carries
  no snapshot and makes no settlement attempt, while accepted queued work binds
  its snapshot at acceptance (FR-CB13 two-state fixture).
- **AC-22 version-pin + Approach-B fallback (FR-CB10) — static-review
  obligation, not a runtime test:** the IMPL PR records the reviewed upstream
  `mlx-swift-lm` tag/revision and the supported cache/model matrix; evidence
  shows the pin is reviewed (not floated); and a documented decision records
  that a calendar (Gate A4) **or** correctness/lifecycle (Gate A1/A3) miss
  triggers Approach B or the no-go stop, never shipping the failing upstream
  API.

## 8. Go/no-go gates (from RESEARCH_232 §4.9)

- **A0 API viability** — a pin-ready upstream batch API with reviewable
  single-owner ownership, per-row insert/filter/extract, and explicit
  unsupported-subclass rejection (FR-CB7, FR-CB8, FR-CB10).
- **A1 correctness** — deterministic parity with the serial path, no
  cross-request state, per-row cancel/stop, correct conversation-cache
  continuation, unchanged receipt fields (FR-CB6). No-go on any cross-request
  state leak.
- **A2 performance** — the FR-CB14 thresholds, measured (not borrowed).
- **A3 lifecycle** — warm-swap drain, no relay-reconnect duplication, model
  hash bound to the served snapshot, deterministic batch-failure cleanup
  (FR-CB13).
- **A4 upstream calendar** — activate Approach B if no pin-ready upstream path
  by end of Q3 2026; do not default to Approach C (FR-CB10).
- **A5 production economics** — `sku-econ` green, material provider upside,
  acceptable tail latency and rejection rate, OPoI false-positive rate < 5%.

## 9. No-go list (from RESEARCH_232 §4.7)

- Approach C (out-of-process oMLX / mlx-lm sidecar) as production serving
  under the current receipt/attestation model.
- Approach D (llama.cpp parallel runtime) as a batching-only change.
- A custom paged-attention kernel or shared paged-KV allocator in the first
  implementation (FR-CB4, FR-CB16).
- Combined SPEC-028 speculative decoding and continuous batching in the first
  implementation (FR-CB12).
- Advertising higher capacity than Entry 110 recommends (FR-CB11).
- Enabling unsupported `kv_bits` modes by silently changing cache policy
  (FR-CB8).
- Shipping any throughput number not measured on real macprovider catalog
  models (FR-CB14).
- Enabling the flag for real traffic on green CI/audit alone, without the
  FR-CB15 real-hardware exercise.

## 10. Open questions carried (non-blocking for v0.1)

These are the RESEARCH_232 Part 8 questions; they must be resolved before a
production default but do not block this SPEC:

1. Which model/cache subclasses can the pinned upstream batch API support?
2. Actor boundary satisfying Swift Sendability without unnecessary KV copies.
3. Copy cost of adding a short-history row to a long-history batch, and
   padding waste under real prompt-length distributions.
4. Cancellation removal latency for a decode row.
5. Which `kv_bits` configurations must initially be rejected vs serial-routed.
6. Queue limit best matching coordinator retry behavior.
7. Whether M-Ultra depth four outperforms depth three after tail-latency
   penalties.
8. How aggregate-TG baselines are versioned for OPoI drift.
9. Which upstream revision is stable enough to pin for a canary.
