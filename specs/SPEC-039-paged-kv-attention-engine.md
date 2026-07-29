# SPEC-039 — Paged KV / paged-attention engine

Version: v0.1
Status: draft (normative design; no IMPL in this SPEC)
Owner: provider runtime / inference engine
Decision source: `docs/research/RESEARCH_232_ADDENDUM_PAGED_REDECISION_2026-07-29.md` plus the verified spike sequence `SPIKE_PAGED_ATTN_PHASE0_RESULT_2026-07-29.md` (`e5ded571`), `SPIKE_PAGED_ATTN_PHASE2_RESULT_2026-07-29.md` (`acc30b1e`), and `SPIKE_PAGED_ATTN_PHASE3_MOE_RESULT_2026-07-29.md` (`da21af53`).
Audit history: three-lane codex SPEC audit (code / security / architect). Convergence and any carried LOW/INFO findings are recorded in the SPEC PR body and `audits/2026-07-29/SPEC-039-rN-audit.md`.

## 1. Purpose and scope

Define the provider-local paged KV cache and paged-attention engine that gives
a Mac a **correctness-preserving paged KV residency** layout for its inference
engine. This is **memory-servability** infrastructure: it changes KV residency
and memory layout inside the provider inference engine, not buyer-visible
billing, receipts, request schemas, model identity, or settlement.

**Scope of the v0.1 claim (proven vs deferred).** v0.1 claims only
correctness-preserving paged *residency*: KV is stored in non-contiguous
physical blocks and gathered back into logical order before attention. The
v0.1 default **gather-feeds-SDPA** mode (FR-PKV3) materializes a transient
**contiguous** K/V copy per attention op before calling stock SDPA, so v0.1
does **not** claim an attention-time peak-memory reduction; that peak-memory
win requires the fully-fused paged-attention op, which is deferred (out of
scope below; FR-PKV3). Framed honestly: **fp16 KV at batch size 1 is the
correctness-proven foundation of this engine, not its servability payoff.** The
throughput payoff comes from continuous batching (SPEC-038) sharing one paged
pool across rows; the peak-memory payoff comes from quantized KV (future). Both
are built on top of the exact-parity correctness this SPEC proves. The
servability envelope this residency layout unlocks over the stock contiguous
path — which model/context sizes fit on the 32 GB live-30B envelope that stock
cannot — is a normative define-and-record obligation (FR-PKV13), not a v0.1
performance claim.

The v0.1 engine is additive on macprovider's pinned production stack,
`mlx-swift-lm 3.31.4` -> `mlx-swift 0.31.4`. It MUST NOT require a fork of
`mlx` or `mlx-swift` for the default path. The verified non-forking injection
surface is a `PagedKVCache` conforming to `mlx-swift-lm`'s public `KVCache`
protocol and passed through `model(_:cache:)`, so the existing model attention
modules continue to apply RoPE, GQA/MQA grouping, and causal masking.

This SPEC stands alone. It is useful at batch size 1 because paging changes KV
residency and gives the provider an explicit, hard-bounded KV pool plus the
consumer-facing block-table primitives (FR-PKV10) that SPEC-024 cross-turn
cache reuse and SPEC-038 continuous batching consume. SPEC-038 continuous
batching is a consumer of this engine, not a prerequisite.

In scope for v0.1:

- A provider-owned `PagedKVCache` for the production fp16 KV path.
- Fixed-size physical KV blocks, per-sequence block tables, and a Swift block
  allocator with allocation, free-list, eviction, and reclaim semantics.
- A custom Metal kernel registered through public `MLXFast.metalKernel`,
  used by default to gather paged, non-contiguous KV into logical order before
  feeding stock `MLXFast.scaledDotProductAttention`.
- Exact greedy-argmax parity gates against the stock contiguous fp16 path on
  dense and MoE models.
- Default-off, provider-local activation with fail-safe fallback to the stock
  contiguous cache path.
- Deliberate packaging of the MLX `default.metallib` resource required by
  Metal-backed MLX execution.

Out of scope for v0.1:

- Any change to LOCKED SPEC-015 receipts, SPEC-024 cache billing semantics,
  SPEC-005 billing arithmetic, buyer API response schemas, or settlement.
- Any buyer-visible receipt, usage, or model identity field identifying paged
  KV, block tables, kernel mode, or allocator state.
- Paged **quantized** KV. `kvBits` is a distinct numerical surface and needs
  its own path targeting `QuantizedKVCacheProtocol` /
  `quantizedScaledDotProductAttention`.
- A fully-fused paged-attention op replacing SDPA. The spike proved numerical
  feasibility at production dimensions, but installing it requires a light
  `mlx-swift-lm` fork of internal attention/helper code and is optional
  future work.
- Cross-provider or **cross-conversation** block sharing, global
  content-addressed KV deduplication, or buyer-controlled block residency.
  This exclusion is scoped to sharing blocks *between distinct conversations*
  and to buyer-directed residency control. It does **not** exclude
  **same-conversation** retain-and-reattach of a sequence's own blocks across
  turns, nor materializing a sequence's own block table into a standalone
  contiguous cache: those are the normative FR-PKV10 consumer primitives that
  keep SPEC-024 cross-turn cache reuse eligible and are explicitly in scope.
- Continuous-batching scheduling, admission, row lifecycle, per-request
  accounting under a shared forward, and MoE expert dispatch under batching
  (SPEC-038 territory).

## 2. Dependencies and authority

- **SPEC-001** — provider binary/config surface. This SPEC consumes provider
  configuration and packaging authority without changing the wire protocol.
- **SPEC-010** — model catalog identity. Paged residency MUST preserve the
  served `model_sha256`, tokenizer identity, and model/cache compatibility
  envelope.
- **SPEC-015** — LOCKED receipts. Untouched; paged KV MUST NOT add or alter
  any receipt field.
- **SPEC-024** — provider prefix-cache billing isolation. Untouched; paged KV
  changes residency/layout only and MUST preserve `cached_prompt_tokens`
  computation wherever SPEC-024 reuse is otherwise eligible.
- **SPEC-037** — KV survival across restarts. SPEC-039 **exposes** paged
  layout metadata that a SPEC-037 implementation **MAY** consume if paged KV
  becomes the resident in-memory layout; the decision whether SPEC-037 MUST
  consume the paged layout (vs. keeping its serial layout flag-isolated from
  persistence, SPEC-037 §8) belongs to the SPEC-037 owner, not to this SPEC
  (FR-PKV9).
- **SPEC-038** — continuous batching. SPEC-038 consumes this engine when it
  needs per-sequence block tables under a shared scheduler; SPEC-039 MUST NOT
  depend on SPEC-038.

SPEC-039 owns the authority domain `paged-kv-attention`: the provider-local
paged KV layout, block-table contract and validation, physical-block allocator
semantics, the machine-readable capability descriptor and cache-class
allowlist, the consumer-facing cache-extraction / same-conversation retention
primitive, paged-gather kernel mode, optional fused-op boundary, fp16
correctness gate, quantized-KV scope boundary, fail-safe fallback, operator
config surface, servability/sizing obligation, and metallib packaging
invariant.

## 3. Terms

| Term | Meaning |
|---|---|
| Stock contiguous path | The existing `KVCacheSimple` / contiguous cache path feeding stock `scaledDotProductAttention`. |
| Paged KV cache | A provider-owned `KVCache` implementation whose logical per-sequence K/V tensors are stored in fixed-size physical blocks. |
| Physical block | A fixed-capacity K/V storage unit in the provider-local KV pool. |
| Block table | Per-sequence logical-block-index to physical-block-id map, with a valid-token count for the tail block. |
| Logical KV order | The token order the model would observe if all KV were contiguous. |
| Gather-feeds-SDPA mode | The v0.1 default: a custom Metal gather restores logical KV order and stock SDPA computes attention. |
| Fully-fused mode | Optional future path where one paged-attention op gathers, masks, softmaxes, and accumulates values without feeding stock SDPA. |
| fp16 KV path | The production/default provider KV dtype path when `kv_bits` is unset. |
| Quantized KV path | A `kvBits` cache path using quantized weights/scales/biases and quantized SDPA. |
| Residency optimization | A provider-local memory/layout optimization that may change which contexts fit but not receipt, usage, billing, or settlement semantics. |
| Capability descriptor | The engine's machine-readable advertisement of what it can serve: block size, supported model families, allowed cache classes, KV dtype, and MoE-dispatch support (FR-PKV11). |
| Cache extraction | The engine operation that materializes one sequence's paged block table into a standalone contiguous `KVCache` in logical token order (FR-PKV10). |
| Same-conversation retention | Retaining a sequence's own physical blocks between its turns and reattaching them to a new decode, preserving SPEC-024 token-granular LCP/trim, without sharing blocks across conversations (FR-PKV10). |
| Block-table handle | The engine-issued reference a consumer holds for one sequence's block table; the engine allocates the physical blocks, the consumer binds/extends/releases through the handle (FR-PKV2, FR-PKV10). |

## 4. Normative requirements

Requirement IDs `SPEC-039-R001`..`R014` are the conformance units; FR labels
below are the prose anchors. MUST / MUST NOT / SHOULD are RFC-2119 normative.

### FR-PKV1 — public KVCache injection seam (SPEC-039-R001)

The v0.1 default path MUST inject paged KV by providing a `PagedKVCache` that
conforms to `mlx-swift-lm`'s public `KVCache` protocol and is passed to
`model(_:cache:)`. It MUST NOT require subclassing or replacing internal
attention modules, forking `mlx`, or forking `mlx-swift` for the default
gather-feeds-SDPA path.

`PagedKVCache` MUST be architecture-general for model families that funnel
attention through `MLXLMCommon.attentionWithCacheUpdate` and the `KVCache`
protocol. The same cache implementation MUST cover dense Llama/Qwen-family
models and MoE models whose attention path uses ordinary per-layer
`KVCacheSimple`-equivalent caches. Architecture-specific code MAY exist only
as an explicit compatibility adapter for a model family with a different
public cache contract; it MUST NOT be the default injection mechanism.

The cache MAY reshape or gather K/V internally, but it MUST leave RoPE,
GQA/MQA mapping, causal masks, and logits computation to the unmodified model
path in v0.1.

### FR-PKV2 — paged storage and block allocator (SPEC-039-R002)

The engine MUST store K/V in fixed-size physical blocks managed by a
provider-local allocator. A v0.1 implementation MUST define one configured
`block_size_tokens` for a resident cache pool at activation time; all
sequences in that pool use the same block size until the pool is recreated.
The block size MUST be a positive integer selected before serving begins and
recorded in compatibility metadata for tests, telemetry, and any persistence
consumer.

Each resident paged pool MUST also have a hard configured capacity, expressed
as `max_physical_blocks`, `max_pool_bytes`, or an equivalent bound from which
both are derivable. The capacity MUST be selected before serving begins,
recorded in diagnostics and acceptance fixtures, and enforced before request
admission or GPU dispatch. The allocator MUST reserve the blocks needed for a
sequence extension before that extension can become buyer-visible. Capacity
exhaustion MUST produce a reason-coded preflight failure or stock-contiguous
fallback before any partial response, usage accounting, receipt construction,
or unreclaimable paged state is emitted. It MUST NOT rely on Swift, MLX, or
Metal out-of-memory failure as the capacity-control mechanism.

For every active sequence, the block table MUST map logical block indices
`0..<ceil(sequence_kv_tokens / block_size_tokens)` to physical block IDs in
logical order. The last logical block MUST carry the count of valid tokens.
Attention code MUST treat bytes beyond that valid-token count as unreadable
padding. A block table with a missing physical block, duplicated physical
block for writable sequence state, out-of-range block ID, negative logical
length, or valid-token count outside `1...block_size_tokens` for a non-empty
tail MUST be rejected before GPU dispatch.

The allocator MUST maintain an explicit free list or equivalent exact free
set, allocate whole physical blocks, and reclaim whole physical blocks only
after no live sequence table references them. Reclaim is **mechanism only**:
the engine MUST NOT reclaim any physical block that is referenced by an
in-flight decode step, and the eviction/reclaim **policy** (which sequence's
blocks to reclaim under pressure, and when) is deferred to the consumer —
SPEC-038 owns it under batching. The engine exposes eviction as a
sequence-scoped mechanism only, unless a future SPEC defines safe subsequence
or shared-prefix ownership. A failed allocation MUST either trigger a
reason-coded fallback to the stock contiguous path before paged state becomes
visible, or fail preflight with a reason-coded error; it MUST NOT produce
partial paged state.

**Ownership boundary (engine vs. consumer).** The engine owns physical-block
allocation, the free list, block-table validation, and issues block IDs and a
per-sequence block-table handle; the verb **"allocate"** is reserved for the
engine. A consumer (e.g. the SPEC-038 scheduler) owns the per-request
logical→physical mapping *lifecycle* — request allocation, bind, extend,
release — through the engine-issued handle; it MUST NOT reach past the handle
into free-list or block-storage internals.

**Concurrency model.** All allocator state transitions (allocate, free,
reclaim, block-table validation) MUST be serialized by a single-driver
isolation domain (a single Swift actor or equivalent single-owner domain), so
no two callers mutate the free list or a block table concurrently.

**Batch-size-1 pool sizing (mid-stream exhaustion structurally impossible).**
At batch size 1 the resident paged pool capacity MUST be `>=` the worst-case
single-sequence context the request may reach: admission MUST reject at
preflight (reason-coded) when the request's `max_tokens` (prompt + generated
ceiling) cannot be guaranteed to fit within the pool for that lone sequence.
Because the whole worst-case footprint is reserved at preflight, a batch-1
sequence can never run out of blocks mid-decode; block-pool exhaustion is a
preflight/pre-first-token condition, not a mid-stream one (FR-PKV7). Behavior
of block-extension failure under a *shared* pool with multiple rows is a
SPEC-038 scheduler concern (admission back-pressure plus request-local
failure), not an engine mid-stream partial-response path.

### FR-PKV3 — paged-attention kernel modes (SPEC-039-R003)

The v0.1 normative mode is **gather-feeds-SDPA**. The implementation MUST
register a custom Metal kernel through public `MLXFast.metalKernel` that
reads K/V from non-contiguous physical blocks via block tables and emits
logical contiguous K/V tensors for stock
`MLXFast.scaledDotProductAttention`. The kernel inputs MUST include enough
shape, block-size, and valid-length information to prevent reading invalid
tail padding or unassigned blocks. The gather output dtype MUST match the
stock fp16 KV path.

The gather kernel MUST NOT change attention math. It reorders storage only:
RoPE'd keys, grouped heads, causal masking, scale, softmax, and value
accumulation remain owned by the existing model/SDPA path.

A **fully-fused paged-attention op** MAY be added later for maximum
performance. That extension MAY require a light `mlx-swift-lm` fork because
the relevant attention modules/helpers are internal. It MUST NOT require an
`mlx` core fork. A fused-op implementation MUST pass the same acceptance
fixtures as gather-feeds-SDPA and MUST be explicitly mode-gated; it MUST NOT
silently replace the v0.1 default.

### FR-PKV4 — fp16 exactness invariant (SPEC-039-R004)

For the fp16 KV path, paged KV MUST be numerically exact against the stock
contiguous path for deterministic greedy generation. The acceptance gate is
exact greedy-argmax token parity over at least 32 generated tokens, with KV
exercised on every layer and every decode step. A passing test MUST prove the
paged kernel ran for every K and V cache update under test; a test that
bypasses paged gather is invalid.

The parity fixtures MUST exercise a **non-degenerate** paged layout, not a
single-block identity case: the context under test MUST span at least two
physical blocks (`>= N` blocks where `N >= 2` for the configured
`block_size_tokens`), the block table MUST use a **non-identity permutation**
(physical block IDs not in ascending logical order), and the 32+ token decode
MUST cross at least one block boundary (a tail block filling and a new block
being allocated mid-decode). A parity pass on a layout that never leaves the
first block, or whose block table is the identity permutation, does not
satisfy this gate.

The parity fixture set MUST include at least:

1. a dense Llama-family model;
2. a dense Qwen-family model or documented equivalent second dense
   architecture; and
3. a MoE Qwen3-family model matching the production attention/cache shape.

The implementation MUST fail closed if parity is not established for a model
or cache class selected for paged mode. Tolerance-based tensor comparison MAY
be used as a diagnostic, but it is not a substitute for exact greedy token
parity in the acceptance gate.

### FR-PKV5 — KV dtype scope and quantized-KV boundary (SPEC-039-R005)

The v0.1 normative and production path is fp16 KV, matching provider behavior
when `kv_bits` is unset. Paged fp16 KV MUST target fp16 stock SDPA parity.

Quantized KV is out of scope for v0.1. A future paged-quantized cache MUST
target the quantized numerical surface, not fp16. It MUST conform to the
relevant quantized cache protocol, feed `quantizedScaledDotProductAttention`,
and gather quantized block tuples `(wq, scales, biases)` or their exact
library-equivalent representation. It MUST NOT reinterpret quantized K/V as
plain fp16 tensors, silently disable requested `kvBits`, or claim fp16 parity
as proof of quantized correctness.

If an operator enables paged KV while `kvBits` is configured before a
quantized paged path exists, the provider MUST route to the stock contiguous
path or fail preflight with an observable reason-coded result. Silent
quantization downgrade is forbidden.

### FR-PKV6 — provider-local default-off invariants (SPEC-039-R006)

Paged KV MUST be disabled by default. When disabled, provider behavior MUST
match the stock contiguous path in request schemas, response schemas, receipt
field set, usage computation, billing arithmetic, advertised model identity,
and observable buyer semantics.

When enabled, paged KV remains provider-local. It MUST NOT add a SPEC-015
receipt field, alter any existing SPEC-015 field computation, add a usage
field, change SPEC-024 `cached_prompt_tokens` semantics, alter SPEC-005
billing arithmetic, or expose block-table/kernel/cache-mode identity to
buyers. Non-receipt operator diagnostics MAY expose paged-mode status,
allocator capacity, fallback counts, and parity/packaging gate state.

The implementation MUST preserve served model identity: `model_sha256`,
served model ID, tokenizer identity, chat-template identity, and cache-class
compatibility metadata used by SPEC-010/SPEC-024/SPEC-037 gates. If paged
activation misses any compatibility or correctness gate, the provider MUST
fall back to the stock contiguous path or fail preflight before serving the
request in paged mode.

### FR-PKV7 — fail-safe fallback and observability (SPEC-039-R007)

Paged mode MUST be fail-safe. Any paged allocator, block-table validation,
kernel registration, kernel dispatch, metallib loading, model compatibility,
pool-capacity, or parity-gate failure MUST NOT corrupt resident stock cache
state and MUST NOT emit a buyer-visible partial response that mixes paged and
stock state.

For permissive policy, the runtime MAY route the affected request or resident
model to the stock contiguous path. For strict policy, it MAY fail preflight.
Both branches MUST emit an operator-observable, reason-coded result. A
configured paged mode MUST NOT silently become stock contiguous without such
operator observability.

**Fallback is a preflight / pre-first-token decision.** Reason-coded
stock-contiguous fallback and preflight rejection apply **before any
buyer-visible token, SSE frame, usage accounting, or receipt state** is
emitted for the request. There is no mid-stream fallback: once a request has
emitted its first token in paged mode, a subsequent engine failure MUST fail
the request closed through the normal terminal path and MUST NOT stitch paged
and stock output for one request. Because batch-1 pool footprint is fully
reserved at preflight (FR-PKV2), block-pool exhaustion cannot arise mid-stream
at batch size 1; multi-row shared-pool pressure is a SPEC-038 scheduler
concern.

Fallback MUST preserve cache isolation: paged physical blocks that were
allocated for a rejected or fallback-routed sequence MUST be reclaimed before
the sequence can be admitted again.

**Closed reason-code enum (exhaustive, normative — like SPEC-037 FR-KVP12).**
Every paged-mode fail-safe or fallback outcome MUST map to exactly one code in
this closed list; the IMPL MUST NOT invent additional codes without a SPEC
revision:

- `paged_fallback_cache_class` — cache class / `kv_bits` not on the paged
  allowlist (FR-PKV12);
- `paged_fallback_allocator` — allocation/block-table validation failure or
  pool exhaustion at preflight (FR-PKV2);
- `paged_fallback_kernel` — Metal kernel registration or dispatch failure
  (FR-PKV3);
- `paged_fallback_metallib` — `default.metallib` missing, version-mismatched,
  or undiscoverable (FR-PKV8);
- `paged_fallback_parity` — a required parity gate is not established for the
  selected model/cache class (FR-PKV4);
- `paged_fallback_identity` — a required served-model/cache compatibility
  identity input is unavailable or mismatched (FR-PKV6);
- `paged_fallback_quantized` — `kv_bits` configured with no paged-quantized
  path (FR-PKV5);
- `paged_preflight_reject` — strict-policy preflight rejection for any of the
  above (the strict-mode counterpart of a permissive fallback).

### FR-PKV8 — metallib packaging invariant (SPEC-039-R008)

The provider build and release path MUST package the MLX `default.metallib`
resource required by the pinned MLX stack deliberately. A plain `swift build`
artifact MUST NOT be assumed to have regenerated or bundled that resource.

The acceptance suite MUST include a packaging check that exercises a
Metal-backed MLX operation in the packaged provider artifact, not only in an
Xcode or local development build. If `default.metallib` is absent,
version-mismatched, or not discoverable at runtime, paged mode MUST fail
closed before serving in paged mode.

### FR-PKV9 — SPEC-037 and SPEC-038 composition (SPEC-039-R009)

Paged KV is the resident memory layout authority for paged-mode inference.
SPEC-039 **exposes** the layout metadata a persistence consumer would need to
serialize paged resident state: at least the block size, logical length,
per-layer shape/dtype metadata, block-table version, allocator/pool
compatibility epoch, source MLX/MLXLM revision identities, served model
identity, tokenizer identity, cache class, and quantization scope. SPEC-039
does **not** mandate that SPEC-037 consume the paged layout. Whether SPEC-037
**MUST** consume this layout (materializing paged state into its opaque record)
or instead keep its serial layout **flag-isolated from persistence** — the
alternative SPEC-037 §8 already permits — is a decision reserved to the
SPEC-037 owner. If a SPEC-037 implementation does choose to consume the paged
layout, it MAY materialize paged state into its existing opaque record only
when doing so preserves SPEC-037's validation, promotion, purge, and rollback
invariants exactly, and any resulting break in SPEC-037 v1 round-trip
compatibility requires a new payload codec ID plus an ABI-epoch bump (never a
silent format change), consistent with SPEC-037 §8.

SPEC-038 continuous batching is a consumer of SPEC-039. A continuous-batching
scheduler MAY request allocation of, bind, extend, and release per-sequence
paged blocks through the engine-issued block-table handle (the engine performs
the underlying physical-block allocation and reclaim, FR-PKV2), but SPEC-039
MUST remain usable without SPEC-038 at batch size 1. SPEC-039 MUST NOT include
batch admission, row lifecycle, per-request usage under a shared forward, or
scheduler throughput claims. Those remain SPEC-038 authority.

### FR-PKV10 — cache-extraction / same-conversation retention primitive (SPEC-039-R010)

The engine MUST expose two **normative consumer-facing operations** over a
sequence's own block table, so a consumer (SPEC-038 scheduler for cross-turn
continuation, or the SPEC-024 conversation-cache path directly) can keep
cross-turn cache reuse eligible:

1. **Cache extraction (materialize).** Given a sequence's block-table handle,
   the engine MUST materialize that sequence's paged K/V into a **standalone
   contiguous** `KVCache` in exact logical token order, suitable for handoff to
   the stock contiguous conversation-cache path. The materialized cache MUST be
   byte-exact (fp16) against what the stock contiguous path would hold for the
   same token sequence.
2. **Same-conversation retain-and-reattach.** The engine MUST allow a
   sequence's own physical blocks to be **retained** past a decode's end and
   **reattached** to a subsequent decode of the *same conversation*, without
   copying through a contiguous cache.

Both operations MUST preserve **SPEC-024 token-granular LCP/trim semantics
exactly**: an extracted or reattached cache MUST support token-granular trim
where every KV layer trims exactly the requested count (a shortfall is a miss,
SPEC-024 FR-CI2/FR-CI3), including a trim at a **mid-block** boundary (the tail
block's valid-token count is adjusted, no whole-block rounding). These
operations are **same-conversation only**: they MUST NOT share, expose, or
reattach one conversation's blocks to a different conversation (the
cross-conversation exclusion in §1 stands), and they grant no buyer-controlled
residency.

### FR-PKV11 — capability descriptor handshake (SPEC-039-R011)

The engine MUST advertise a **machine-readable capability descriptor** that a
consumer reads to decide whether a requested tuple can be served in paged mode.
The descriptor MUST include at least: `block_size_tokens`, supported model
families, the **allowed cache classes** (the FR-PKV12 allowlist), KV dtype
(fp16 in v0.1), and whether MoE expert-dispatch-shaped models are supported by
the paged path. The descriptor is the single source of truth for paged
capability: a consumer's activation predicate MUST be `requested tuple ∈
engine-advertised descriptor`, never a separately self-declared support matrix
that could drift from what the engine actually serves. The descriptor MUST be
derivable at attach time and MUST reflect the FR-PKV12 attach-time allowlist
result for the resident model.

### FR-PKV12 — cache-class allowlist and attach-time admission gate (SPEC-039-R012)

At model attach, the engine MUST inspect the runtime `newCache()` class and the
`kv_bits` setting against a **paged allowlist**. The v1 allowlist is:
**non-rotating contiguous `KVCacheSimple`-equivalent, fp16, `kv_bits` unset.**
A model whose runtime cache class is **not** on the allowlist — enumerated
non-allowlisted classes include `RotatingKVCache` (sliding-window),
`CacheList` (hybrid), and `QuantizedKVCache` — MUST **fail safe to the stock
contiguous path** with an **observable reason code** (`paged_fallback_cache_class`,
FR-PKV7), logged **once at attach**. Paged mode MUST NOT be advertised in the
FR-PKV11 descriptor for a non-allowlisted class.

This gate is correctness-load-bearing, not merely an optimization guard: the
v0.1 gather-feeds-SDPA path assumes the stock full-context causal mask. Paging
a **sliding-window** (`RotatingKVCache`) model through it would silently defeat
the model's own windowed masking and produce **wrong tokens billed as
correct** — so a non-allowlisted cache class MUST never be served in paged
mode, exactly as SPEC-037 AC-10 fails a non-`KVCacheSimple` family safe to a
miss with an observable skip.

### FR-PKV13 — servability / sizing obligation and overhead ceiling (SPEC-039-R013)

The v0.1 engine claims correctness-preserving residency, not a measured
performance win (§1). To keep the servability rationale honest, the IMPL PR
MUST define and record — the **obligation to define is normative even though
the values are IMPL-set**, exactly as FR-PKV2's capacity bound is:

- a **sizing table** for the live production 30B model, apportioning the
  **32 GB** unified-memory envelope across model weights, per-request
  activation, and the paged block pool, showing the block-pool capacity that
  fits alongside weights and activation;
- the **minimum model/context envelope the paged path serves that the stock
  contiguous path cannot** — the differentiated servability the layout buys —
  recorded with real model/context memory evidence (an obligation to define
  and record, not a fixed v0.1 number). Consistent with §1, this delta **MAY be
  recorded as null or negligible for the v0.1 batch-1 fp16 path** (the payoff
  arrives with batching and quantized KV); the obligation is to record the
  measured value honestly, not to manufacture a positive envelope;
- a **paged-attention overhead ceiling**: a bound on the per-op gather (and,
  for the fused path when it exists, per-op attention) overhead versus the
  stock contiguous path, enforced as an **IMPL gate** — paged mode that
  exceeds the recorded ceiling fails the gate rather than shipping a
  regression.

These are normative define-and-record obligations; the specific byte and
percentage values are chosen by the IMPL against real evidence and recorded in
diagnostics and acceptance fixtures.

### FR-PKV14 — operator configuration surface (SPEC-039-R014)

Paged KV MUST expose an operator configuration surface mirroring the SPEC-037
FR-KVP11 pattern: a triple-source (YAML file → environment → CLI override)
precedence with a **default-off** enable flag. The surface MUST include at
least:

| YAML `paged_kv:` key | Env var | CLI flag | Default | Rule |
|---|---|---|---|---|
| `enabled` | `MACPROVIDER_PAGED_KV_ENABLED` | `--paged-kv-enabled` | `false` | bool; invalid ⇒ paged disabled, error logged |
| `block_size_tokens` | `MACPROVIDER_PAGED_KV_BLOCK_SIZE_TOKENS` | `--paged-kv-block-size-tokens` | IMPL-set | positive integer, fixed per pool (FR-PKV2); invalid ⇒ disabled |
| `max_physical_blocks` | `MACPROVIDER_PAGED_KV_MAX_PHYSICAL_BLOCKS` | `--paged-kv-max-physical-blocks` | IMPL-set | pool capacity bound (FR-PKV2), or an equivalent `max_pool_bytes`; > 0; invalid ⇒ disabled |
| `fallback_policy` | `MACPROVIDER_PAGED_KV_FALLBACK_POLICY` | `--paged-kv-fallback-policy` | `permissive` | `permissive` (stock-route) or `strict` (fail preflight) (FR-PKV7); invalid ⇒ disabled |

Default-off invariants are FR-PKV6; the fallback-policy values select the
FR-PKV7 branch. Invalid configuration MUST disable paged mode with a logged
error, never a silent partial enable.

## 5. Outcome tables

| Configuration | Required result |
|---|---|
| Paged flag off | Stock contiguous path; no buyer-visible behavior change. |
| Paged flag on, fp16 KV, allowlisted cache class, gates pass | Paged KV may serve; exact greedy parity with stock is required. |
| Paged flag on, non-allowlisted cache class at attach (`RotatingKVCache`/sliding-window, `CacheList`/hybrid, `QuantizedKVCache`) | Fail safe to stock contiguous with `paged_fallback_cache_class`, logged once at attach; paged not advertised in descriptor (FR-PKV12). |
| Paged flag on, batch=1, `max_tokens` cannot fit the worst-case single-sequence context in the pool | Reason-coded preflight rejection (`paged_fallback_allocator`); no mid-stream exhaustion (FR-PKV2). |
| Paged flag on, allocator or block-table invalid | Reason-coded stock fallback or preflight failure before paged serving. |
| Paged flag on, `kvBits` configured and no paged-quantized path exists | Reason-coded stock fallback or preflight failure; no silent quantization downgrade. |
| Metal kernel or `default.metallib` unavailable | Reason-coded stock fallback or preflight failure before paged serving. |
| Fully-fused op configured | Explicit mode-gated extension; must pass all fp16 parity fixtures before use. |

## 6. Acceptance criteria (fixtures)

The implementation PR for this SPEC MUST include fixtures that prove:

- **AC-1 dense exact parity:** paged fp16 KV produces exact greedy-token
  parity against stock contiguous KV for a Llama-family model over at least
  32 generated tokens, with every layer and step exercising paged K and V.
  The fixture MUST use a **non-degenerate** layout (FR-PKV4): the context spans
  `>= 2` physical blocks, the block table is a **non-identity permutation**,
  and the decode **crosses at least one block boundary** (a new block allocated
  mid-decode).
- **AC-2 second dense exact parity:** the same cache implementation produces
  exact parity on a second dense architecture, preferably Qwen-family, with
  paged K and V exercised every layer and step, under the same non-degenerate
  multi-block / non-identity-permutation / boundary-crossing layout as AC-1.
- **AC-3 MoE exact parity:** the same cache implementation produces exact
  parity on a Qwen3 MoE model matching the production attention/cache shape,
  with paged K and V exercised every layer and step, under the same
  non-degenerate multi-block / non-identity-permutation / boundary-crossing
  layout as AC-1.
- **AC-4 allocator/block-table correctness:** allocation, free-list reuse,
  eviction/reclaim, out-of-range block IDs, duplicate writable blocks,
  missing blocks, invalid tail lengths, and logical ordering are covered by
  unit tests.
- **AC-5 pool capacity fail-safe (preflight arm):** exhausting the configured
  paged pool produces reason-coded stock fallback or preflight failure without
  process OOM, leaked blocks, partial buyer-visible output, usage accounting,
  or receipt side effects. The fixture MUST include the **batch-1 preflight
  arm**: a request whose `max_tokens` worst-case single-sequence context
  exceeds the pool is **rejected at preflight** (`paged_fallback_allocator`),
  proving mid-stream exhaustion is structurally impossible at batch size 1
  (FR-PKV2). No fallback occurs after a first token is emitted.
- **AC-6 fp16 floor:** fp16 KV is the normative path and passes all exactness
  gates before paged mode can be enabled.
- **AC-7 quantized boundary:** a `kvBits` configuration without a
  paged-quantized implementation is reason-coded stock fallback or preflight
  failure, never a silent fp16 reinterpretation or quantization disable.
- **AC-8 fail-safe fallback:** kernel registration/dispatch failure,
  allocator exhaustion, block-table validation failure, and model
  compatibility miss leave stock contiguous serving intact and reclaim paged
  blocks.
- **AC-9 metallib packaging:** the packaged provider artifact can load the
  pinned MLX `default.metallib` and execute a Metal-backed MLX operation; a
  missing/mismatched resource fails closed before paged serving.
- **AC-10 receipt and usage invariance:** enabling paged mode adds no
  SPEC-015 receipt field, no usage field, and no buyer-visible cache-mode
  field; SPEC-024 `cached_prompt_tokens` and SPEC-005 billing arithmetic are
  unchanged.
- **AC-11 SPEC-037 composition:** if persistence consumes paged resident
  state, its format records the paged layout identity and preserves
  validation, promotion, purge, and rollback invariants.
- **AC-12 SPEC-038 independence:** paged KV passes batch-size-1 parity and
  fallback tests without the continuous-batching scheduler enabled.
- **AC-13 cache-class allowlist attach gate (FR-PKV12):** attaching a model
  whose runtime cache class is off the paged allowlist — a `RotatingKVCache`
  (sliding-window), a `CacheList` (hybrid), and a `QuantizedKVCache` are each
  exercised — fails safe to the stock contiguous path with an observable
  `paged_fallback_cache_class`, logged once at attach, and paged mode is not
  advertised in the FR-PKV11 descriptor; an allowlisted fp16 `KVCacheSimple`
  attaches to paged mode. This mirrors SPEC-037 AC-10.
- **AC-14 capability descriptor handshake (FR-PKV11):** the engine advertises a
  machine-readable descriptor (block size, model families, allowed cache
  classes, KV dtype, MoE-dispatch support) that reflects the attach-time
  allowlist result; a fixture asserts a consumer admitting `requested tuple ∈
  descriptor` and rejecting/fallback-routing a tuple outside it, never from a
  separate self-declared matrix.
- **AC-15 cache-extraction / same-conversation retention + token-granular trim
  (FR-PKV10):** materializing a paged sequence's block table into a standalone
  contiguous `KVCache` is byte-exact (fp16) against the stock contiguous cache
  for the same tokens; retain-and-reattach continues the *same* conversation
  without a contiguous round-trip; both preserve SPEC-024 token-granular
  LCP/trim, including a **mid-block** LCP prefix-reuse where the tail block's
  valid-token count is trimmed with no whole-block rounding. Cross-conversation
  reattach is rejected.
- **AC-16 servability / sizing obligation (FR-PKV13):** the IMPL records the
  32 GB live-30B sizing table (weights + activation + block pool), the minimum
  model/context envelope paged serves that stock cannot (which **MAY be recorded
  as null/negligible for the batch-1 fp16 path**), and enforces the
  paged-attention overhead ceiling as an IMPL gate (paged mode exceeding the
  recorded ceiling fails the gate).
- **AC-17 operator config surface (FR-PKV14):** the triple-source
  (YAML/env/CLI) precedence resolves `enabled` (default `false`),
  `block_size_tokens`, pool capacity, and `fallback_policy`
  (`permissive`/`strict`); invalid values disable paged mode with a logged
  error and never a silent partial enable.

## 7. No-go list

- No `mlx` or `mlx-swift` fork for v0.1 gather-feeds-SDPA.
- No `d-inference` / `Layr-Labs/*` source consultation.
- No receipt, usage, billing, buyer API, or settlement field changes.
- No silent fallback from configured paged mode.
- No `kvBits` support claim until a quantized paged path targets quantized
  SDPA directly.
- No batching throughput claim from this SPEC alone.
- No attention-time peak-memory-reduction claim from the v0.1
  gather-feeds-SDPA path (it materializes a transient contiguous copy per op).
- No serving a non-allowlisted cache class (`RotatingKVCache`/sliding-window,
  `CacheList`/hybrid, `QuantizedKVCache`) in paged mode; attach fails safe to
  stock contiguous.
- No global, cross-conversation, or buyer-visible KV block sharing
  (same-conversation retain/reattach is in scope, FR-PKV10).

## 8. Open questions carried

- Production block size and pool capacity values are implementation
  parameters, but the existence of a hard capacity bound is normative. The
  implementation must choose the values with real model/context memory evidence
  and record them in diagnostics and test fixtures.
- Fully-fused paged attention is numerically de-risked but remains a future
  performance extension because its installation surface requires a light
  `mlx-swift-lm` fork.
- Paged quantized KV remains a future numerical surface if the provider later
  enables `kvBits` in production.
- Catalog / autotune product-surface interaction: how the paged servability
  envelope (FR-PKV13 — the larger model/context classes a Mac can serve under
  paging) should surface in the SPEC-010 model catalog and the SPEC-023
  installer-autotune recommendation (which models/contexts a given hardware
  tier advertises) is an open product-surface question, deferred to those
  specs' owners. This SPEC defines only the provider-local engine, not the
  catalog/autotune advertisement.
