# SPEC-039 — Paged KV / paged-attention engine

Version: v0.1
Status: draft (normative design; no IMPL in this SPEC)
Owner: provider runtime / inference engine
Decision source: `docs/research/RESEARCH_232_ADDENDUM_PAGED_REDECISION_2026-07-29.md` plus the verified spike sequence `SPIKE_PAGED_ATTN_PHASE0_RESULT_2026-07-29.md` (`e5ded571`), `SPIKE_PAGED_ATTN_PHASE2_RESULT_2026-07-29.md` (`acc30b1e`), and `SPIKE_PAGED_ATTN_PHASE3_MOE_RESULT_2026-07-29.md` (`da21af53`).
Audit history: three-lane codex SPEC audit (code / security / architect). Convergence and any carried LOW/INFO findings are recorded in the SPEC PR body and `audits/2026-07-29/SPEC-039-rN-audit.md`.

## 1. Purpose and scope

Define the provider-local paged KV cache and paged-attention engine that lets
a Mac serve larger models and longer contexts more memory-efficiently. This
is **memory-servability** infrastructure: it changes residency and memory
layout inside the provider inference engine, not buyer-visible billing,
receipts, request schemas, model identity, or settlement.

The v0.1 engine is additive on macprovider's pinned production stack,
`mlx-swift-lm 3.31.4` -> `mlx-swift 0.31.4`. It MUST NOT require a fork of
`mlx` or `mlx-swift` for the default path. The verified non-forking injection
surface is a `PagedKVCache` conforming to `mlx-swift-lm`'s public `KVCache`
protocol and passed through `model(_:cache:)`, so the existing model attention
modules continue to apply RoPE, GQA/MQA grouping, and causal masking.

This SPEC stands alone. It is useful at batch size 1 because paging improves
KV residency and context/model servability for a single stream. SPEC-038
continuous batching is a consumer of this engine, not a prerequisite.

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
- Cross-provider or cross-conversation block sharing, global content-addressed
  KV deduplication, or buyer-controlled block residency.
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
- **SPEC-037** — KV survival across restarts. If paged KV becomes the
  resident in-memory layout, SPEC-037 persistence becomes a consumer of the
  paged layout rather than an independent dense layout owner (§8).
- **SPEC-038** — continuous batching. SPEC-038 consumes this engine when it
  needs per-sequence block tables under a shared scheduler; SPEC-039 MUST NOT
  depend on SPEC-038.

SPEC-039 owns the authority domain `paged-kv-attention`: the provider-local
paged KV layout, block-table contract, allocator semantics, paged-gather
kernel mode, optional fused-op boundary, fp16 correctness gate, quantized-KV
scope boundary, fail-safe fallback, and metallib packaging invariant.

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

## 4. Normative requirements

Requirement IDs `SPEC-039-R001`..`R009` are the conformance units; FR labels
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
after no live sequence table references them. Eviction MUST be
policy-controlled and sequence-scoped unless a future SPEC defines safe
subsequence or shared-prefix ownership. A failed allocation MUST either
trigger a reason-coded fallback to the stock contiguous path before paged
state becomes visible, or fail preflight with a reason-coded error; it MUST
NOT produce partial paged state.

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

Fallback MUST preserve cache isolation: paged physical blocks that were
allocated for a rejected or fallback-routed sequence MUST be reclaimed before
the sequence can be admitted again.

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

Paged KV is the resident memory layout authority for paged-mode inference. If
that resident layout becomes the source of truth for conversation KV state,
SPEC-037 persistence MUST consume this layout rather than inventing an
independent dense serialization for the same resident state. Any persisted
paged format MUST record at least the block size, logical length, per-layer
shape/dtype metadata, block-table version, allocator/pool compatibility
epoch, source MLX/MLXLM revision identities, served model identity, tokenizer
identity, cache class, and quantization scope. A SPEC-037 implementation MAY
choose to materialize paged state into its existing opaque record only when
doing so preserves SPEC-037's validation, promotion, purge, and rollback
invariants exactly.

SPEC-038 continuous batching is a consumer of SPEC-039. A continuous-batching
scheduler MAY allocate and reclaim per-sequence paged blocks through this
engine, but SPEC-039 MUST remain usable without SPEC-038 at batch size 1.
SPEC-039 MUST NOT include batch admission, row lifecycle, per-request usage
under a shared forward, or scheduler throughput claims. Those remain SPEC-038
authority.

## 5. Outcome tables

| Configuration | Required result |
|---|---|
| Paged flag off | Stock contiguous path; no buyer-visible behavior change. |
| Paged flag on, fp16 KV, compatible cache class, gates pass | Paged KV may serve; exact greedy parity with stock is required. |
| Paged flag on, allocator or block-table invalid | Reason-coded stock fallback or preflight failure before paged serving. |
| Paged flag on, `kvBits` configured and no paged-quantized path exists | Reason-coded stock fallback or preflight failure; no silent quantization downgrade. |
| Metal kernel or `default.metallib` unavailable | Reason-coded stock fallback or preflight failure before paged serving. |
| Fully-fused op configured | Explicit mode-gated extension; must pass all fp16 parity fixtures before use. |

## 6. Acceptance criteria (fixtures)

The implementation PR for this SPEC MUST include fixtures that prove:

- **AC-1 dense exact parity:** paged fp16 KV produces exact greedy-token
  parity against stock contiguous KV for a Llama-family model over at least
  32 generated tokens, with every layer and step exercising paged K and V.
- **AC-2 second dense exact parity:** the same cache implementation produces
  exact parity on a second dense architecture, preferably Qwen-family, with
  paged K and V exercised every layer and step.
- **AC-3 MoE exact parity:** the same cache implementation produces exact
  parity on a Qwen3 MoE model matching the production attention/cache shape,
  with paged K and V exercised every layer and step.
- **AC-4 allocator/block-table correctness:** allocation, free-list reuse,
  eviction/reclaim, out-of-range block IDs, duplicate writable blocks,
  missing blocks, invalid tail lengths, and logical ordering are covered by
  unit tests.
- **AC-5 pool capacity fail-safe:** exhausting the configured paged pool
  produces reason-coded stock fallback or preflight failure without process
  OOM, leaked blocks, partial buyer-visible output, usage accounting, or
  receipt side effects.
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

## 7. No-go list

- No `mlx` or `mlx-swift` fork for v0.1 gather-feeds-SDPA.
- No `d-inference` / `Layr-Labs/*` source consultation.
- No receipt, usage, billing, buyer API, or settlement field changes.
- No silent fallback from configured paged mode.
- No `kvBits` support claim until a quantized paged path targets quantized
  SDPA directly.
- No batching throughput claim from this SPEC alone.
- No global or buyer-visible KV block sharing.

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
