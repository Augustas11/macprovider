# BUILD: SPEC-039 paged KV / paged-attention engine — IMPL

Author: operator (a11) + Claude session 2026-07-29
Status: IMPLEMENTATION HANDOFF — SPEC-039 v0.1 is LOCKED on `origin/main` (landed
with SPEC-038 v0.2 at `61369ec6`). This prompt drives the engine implementation.
It is the **first** of two IMPL builds; SPEC-038 v0.2 (the scheduler) is the
second and consumes what this build produces. Build them in that order — the
scheduler cannot exist until the engine's descriptor, block-table handle, and
extraction primitive are real.

## 1. Mission

Implement the provider-local **paged KV / paged-attention engine** defined by
`specs/SPEC-039-paged-kv-attention-engine.md` (requirements `SPEC-039-R001..R014`,
acceptance `AC-1..AC-17`). This is **memory-servability** infrastructure: it
changes KV residency and physical memory layout inside the provider inference
engine. It is **default-off**, provider-local, and adds **no** buyer-visible
receipt / usage / model-identity / billing / settlement surface.

The engine is additive on the pinned production stack `mlx-swift-lm 3.31.4` →
`mlx-swift 0.31.4`, and the default gather-feeds-SDPA path **MUST NOT fork** `mlx`
or `mlx-swift`. The verified non-forking injection seam is a `PagedKVCache`
conforming to `mlx-swift-lm`'s public `KVCache` protocol, passed through
`model(_:cache:)` — proven exact-parity across dense Llama, dense Qwen, and live
MoE Qwen3-Coder-30B-A3B in the three landed spikes:

- `docs/research/SPIKE_PAGED_ATTN_PHASE0_RESULT_2026-07-29.md` (`e5ded571`) — kernel registers beside the pinned tag, no `mlx` fork ("3a").
- `docs/research/SPIKE_PAGED_ATTN_PHASE2_RESULT_2026-07-29.md` (`acc30b1e`) — injection via the `KVCache` seam, exact 40/40 parity, fp16, architecture-general.
- `docs/research/SPIKE_PAGED_ATTN_PHASE3_MOE_RESULT_2026-07-29.md` (`da21af53`) — MoE Qwen3-Coder-30B-A3B (48 layers, 128 experts) exact 40/40 parity, same unchanged `PagedKVCache`.

Frame the deliverable honestly per SPEC §1: **v0.1 claims correctness-preserving
paged *residency*, not an attention-time peak-memory reduction and not a
throughput number.** The default mode materializes a transient contiguous K/V
copy per op before stock SDPA. The throughput payoff comes later from SPEC-038
batching; the peak-memory payoff comes later from quantized KV. This build proves
the exact-parity foundation both sit on.

## 2. Non-goals (SPEC §1 "out of scope" + no-go list §7)

- No `mlx` / `mlx-swift` fork for the default gather-feeds-SDPA path.
- No fully-fused paged-attention op (numerically de-risked in the spikes at
  9.3e-4, but installing it needs a light `mlx-swift-lm` fork — deferred).
- No paged **quantized** KV. `kv_bits` is a distinct numerical surface; when set
  with no paged-quantized path, route to stock or fail preflight
  (`paged_fallback_quantized`) — never silent fp16 reinterpretation.
- No continuous-batching scheduler, admission, row lifecycle, per-request
  accounting under a shared forward, or throughput claim (that is the SPEC-038
  build). The engine MUST be complete and correct **at batch size 1** alone.
- No cross-conversation / global / buyer-visible block sharing.
  Same-conversation retain-and-reattach IS in scope (FR-PKV10).
- No change to LOCKED SPEC-015 receipts, SPEC-024 cache billing, SPEC-005 billing
  arithmetic, buyer API schemas, model identity, or settlement.
- **No `d-inference` / `Layr-Labs/*` source consultation** (NOASSERTION,
  strict clean-room). Build only from `ml-explore` upstream (MIT/Apache), public
  `mlx-lm` `BatchGenerator` (MIT), vLLM (Apache), and the PagedAttention paper.
  This constraint is knowledge-flow, not session-scoped — do not read their
  source in any session and carry it here.

## 3. Ground rules (repo conventions — non-negotiable)

- **Fresh worktree off `origin/main`.** Do not edit the canonical checkout.
  ```bash
  git fetch origin
  git worktree add ../macprovider-spec039-impl -b impl/039-paged-engine origin/main
  cd ../macprovider-spec039-impl
  ```
- **Money-path-adjacent (serving correctness).** This goes through a **PR**, not
  direct push, and must pass the full audit loop before merge.
- **Governance declaration** in the PR body: `behavior_change: "yes"`,
  `contract_change: "none"` (SPEC-039 is a new normative doc but this IMPL adds
  no new canonical contract field), cite `SPEC-039` + a requirement +
  `authority_domains: ["paged-kv-attention"]` + tests. The `spec-index/check` is
  advisory; the real gate is `ci-required` + 1 approval.
- **Audit loop before "done":** three Codex lanes (code / security / architect)
  via `omc ask codex` against the **full IMPL diff as it will land**, bar
  **0 CRITICAL / 0 HIGH / 0 MEDIUM**; carry LOW/INFO explicitly. Then, because a
  codex loop fed the author's own framing validates narrative not correctness,
  add **two independent Claude passes**: an adversarial verificator and a product
  /correctness critic given only feature + diff (no fix-history). Reconcile any
  fix-introduced regression (the SPEC-037 IMPL taught us a fix can introduce a
  HIGH — re-verify the fix delta, don't assume).
- **Real-hardware enable gate (Entry-199 lesson — the load-bearing one):**
  green audits + green CI + passing unit tests are **NOT** the runtime-enable
  gate. SPEC-037 shipped a silent no-op while passing all of that. The engine
  ships **default-off and inert on merge**; flipping it on for any provider
  requires the packaged real-hardware proof in §7. Do not claim the feature
  "works" from CI alone.

## 4. Concrete task list

Build in dependency order. Each numbered block is a coherent unit; keep the
allocator and cache correct at batch-1 before touching the kernel.

### 4.1 Prerequisites / baseline
- [ ] Confirm the pinned stack resolves to `mlx-swift-lm 3.31.4` → `mlx-swift
      0.31.4` (constraint is `upToNextMinor(0.31.4)`; do **not** bump to 0.31.6 —
      it carries nothing macprovider-relevant, see the mlx-swift-version memory).
- [ ] Cache HuggingFace snapshots for the three parity models: a dense
      Llama-family, a dense Qwen-family, and MoE `Qwen3-Coder-30B-A3B-Instruct-4bit`.
- [ ] Re-run the Phase-2 / Phase-3 spike harnesses as the numerical baseline the
      IMPL parity fixtures must reproduce (exact 40/40 greedy-argmax).

### 4.2 Block allocator (FR-PKV2 → AC-4, AC-5) — build first, it is the foundation
- [ ] Fixed-size physical KV blocks; one configured `block_size_tokens` per
      resident pool, recorded in compatibility metadata.
- [ ] Hard pool capacity (`max_physical_blocks` / `max_pool_bytes`), enforced
      **before admission or GPU dispatch** — never rely on MLX/Metal OOM.
- [ ] Explicit free list / exact free set; whole-block allocate + reclaim;
      reclaim only after no live sequence table references a block, and **never**
      a block referenced by an in-flight decode step.
- [ ] Per-sequence block table: logical→physical map in logical order, tail block
      valid-token count, unreadable padding beyond it. Reject before GPU dispatch
      any table with a missing/duplicate-writable/out-of-range block, negative
      length, or tail count outside `1...block_size_tokens`.
- [ ] **Ownership boundary:** the engine owns allocation/free-list/validation and
      issues a per-sequence **block-table handle**; the verb "allocate" is the
      engine's. Consumers drive request-allocate/bind/extend/release **through
      the handle** and cannot reach past it. (This is the surface SPEC-038 will
      consume — get it right here.)
- [ ] **Concurrency:** serialize all allocator transitions behind a single-driver
      isolation domain (one Swift actor / single-owner domain).
- [ ] **Batch-1 sizing invariant:** pool capacity `>=` worst-case single-sequence
      context; admission rejects at preflight (`paged_fallback_allocator`) when
      `max_tokens` (prompt + generation ceiling) cannot be guaranteed to fit —
      making mid-decode exhaustion structurally impossible at batch 1.

### 4.3 `PagedKVCache` (FR-PKV1 → AC-1..AC-3, AC-12)
- [ ] Conform to `mlx-swift-lm`'s public `KVCache`; inject via `model(_:cache:)`.
      No subclassing/replacing internal attention modules; no fork.
- [ ] Architecture-general across dense Llama/Qwen and MoE whose attention funnels
      through `MLXLMCommon.attentionWithCacheUpdate` + the `KVCache` protocol.
      Any architecture-specific code is an explicit compatibility adapter only,
      never the default injection mechanism.
- [ ] Leave RoPE, GQA/MQA grouping, causal masking, and logits to the unmodified
      model path. The cache reorders storage only.

### 4.4 FR-PKV12 cache-class allowlist attach gate (→ AC-13) — the CRITICAL correctness gate
- [ ] At model attach, inspect runtime `newCache()` class **and** `kv_bits`
      against the v1 allowlist: **non-rotating contiguous `KVCacheSimple`-
      equivalent, fp16, `kv_bits` unset.**
- [ ] Non-allowlisted classes (`RotatingKVCache`/sliding-window,
      `CacheList`/hybrid, `QuantizedKVCache`) **fail safe to stock contiguous**
      with `paged_fallback_cache_class`, logged **once at attach**, and are **not
      advertised** in the FR-PKV11 descriptor.
- [ ] This is correctness-load-bearing, not an optimization guard: paging a
      sliding-window model through the full-context causal-mask gather-SDPA path
      would silently defeat windowed masking and bill **wrong tokens as correct**.
      Mirror SPEC-037 AC-10 exactly. Land this **with** the cache, before the
      kernel is wired to any real serve path.

### 4.5 Gather-feeds-SDPA Metal kernel (FR-PKV3 → AC-1..AC-3, AC-8)
- [ ] Register a custom kernel via public `MLXFast.metalKernel` that reads K/V
      from non-contiguous physical blocks via block tables and emits logical
      contiguous K/V for stock `MLXFast.scaledDotProductAttention`.
- [ ] Kernel inputs carry enough shape/block-size/valid-length info to never read
      tail padding or unassigned blocks; gather output dtype = fp16 stock path.
- [ ] Kernel changes **no** attention math — storage reorder only.
- [ ] Fully-fused op stays deferred and, if ever added, is explicitly mode-gated
      and must pass the same parity fixtures; it MUST NOT silently replace default.

### 4.6 metallib packaging invariant (FR-PKV8 → AC-9)
- [ ] Deliberately package the MLX `default.metallib` in the provider build/release
      path. A plain `swift build` artifact MUST NOT be assumed to carry it (this
      is exactly the trap that made SPEC-037's worktree run un-provable — see §7).
- [ ] Packaging check exercises a Metal-backed MLX op in the **packaged** artifact,
      not only an Xcode/dev build. Missing/mismatched/undiscoverable metallib →
      `paged_fallback_metallib`, fail closed before paged serving.

### 4.7 Fail-safe fallback + closed reason-code enum (FR-PKV7 → AC-5, AC-8)
- [ ] Every fail-safe/fallback outcome maps to exactly one code in the closed
      normative enum (do not invent codes without a SPEC revision):
      `paged_fallback_cache_class`, `paged_fallback_allocator`,
      `paged_fallback_kernel`, `paged_fallback_metallib`, `paged_fallback_parity`,
      `paged_fallback_identity`, `paged_fallback_quantized`,
      `paged_preflight_reject`.
- [ ] Fallback/rejection is a **preflight / pre-first-token** decision. No
      mid-stream fallback; once a request emits a paged first token, a later
      failure fails the request closed through the normal terminal path — never
      stitch paged+stock output. Reclaim blocks of a rejected/fallback sequence
      before it can be re-admitted.

### 4.8 Capability descriptor (FR-PKV11 → AC-14)
- [ ] Advertise a machine-readable descriptor: `block_size_tokens`, supported
      model families, allowed cache classes (the FR-PKV12 allowlist), KV dtype
      (fp16), MoE-dispatch support. Derivable at attach; reflects the attach-time
      allowlist result. It is the **single source of truth**: a consumer's
      activation predicate is `requested tuple ∈ descriptor`, never a separate
      self-declared matrix. (SPEC-038 reads exactly this.)

### 4.9 Cache-extraction / same-conversation retention (FR-PKV10 → AC-15)
- [ ] **Extraction (materialize):** given a block-table handle, materialize the
      sequence's paged K/V into a **standalone contiguous** `KVCache` in exact
      logical token order, **byte-exact (fp16)** vs. the stock contiguous cache
      for the same tokens.
- [ ] **Retain-and-reattach:** retain a sequence's own blocks past decode end and
      reattach to a subsequent decode of the **same conversation**, no contiguous
      round-trip.
- [ ] Both preserve **SPEC-024 token-granular LCP/trim exactly**, including a
      **mid-block** trim (adjust the tail block's valid-token count, no whole-block
      rounding). Same-conversation only; reject cross-conversation reattach.
      (This is what keeps SPEC-024 cross-turn cache reuse eligible under paging.)

### 4.10 Operator config surface (FR-PKV14 → AC-17)
- [ ] Triple-source precedence YAML `paged_kv:` → env → CLI, **default-off**,
      mirroring SPEC-037 FR-KVP11. Keys: `enabled`
      (`MACPROVIDER_PAGED_KV_ENABLED` / `--paged-kv-enabled`, default `false`),
      `block_size_tokens`, `max_physical_blocks` (or `max_pool_bytes`),
      `fallback_policy` (`permissive`|`strict`, default `permissive`).
- [ ] Invalid config **disables** paged mode with a logged error — never a silent
      partial enable.

### 4.11 Default-off + identity invariance (FR-PKV6 → AC-10)
- [ ] Flag off ⇒ byte-identical stock behavior: request/response schemas, receipt
      field set, usage, billing arithmetic, model identity, buyer semantics.
- [ ] Flag on ⇒ still provider-local: no SPEC-015 receipt field added/changed, no
      usage field, no SPEC-024 `cached_prompt_tokens` semantic change, no SPEC-005
      arithmetic change, no block-table/kernel/cache-mode identity to buyers.
      Non-receipt operator diagnostics MAY expose paged status/capacity/fallback
      counts/gate state. Preserve `model_sha256`, model ID, tokenizer + chat
      template identity, cache-class compatibility metadata.

### 4.12 Parity fixtures (FR-PKV4 → AC-1..AC-3, AC-6) — the acceptance heart
- [ ] Exact greedy-argmax parity over `>= 32` tokens, KV exercised **every layer,
      every step**; a test that bypasses paged gather is invalid — prove the paged
      kernel ran for every K and V update.
- [ ] **Non-degenerate layout** (this is the part easy to fake): context spans
      `>= 2` physical blocks, block table is a **non-identity permutation**
      (physical IDs not in ascending logical order), and the decode **crosses a
      block boundary** (tail fills, new block allocated mid-decode). Identity /
      single-block layouts do NOT satisfy the gate.
- [ ] Three models minimum: dense Llama, dense Qwen (or documented equivalent),
      MoE Qwen3. Fail closed if parity is not established for a selected model/
      cache class. Tolerance comparison is diagnostic only, never a substitute.

### 4.13 Servability / sizing obligation + overhead ceiling (FR-PKV13 → AC-16)
- [ ] Record a **sizing table** for the live 30B model apportioning the **32 GB**
      unified-memory envelope across weights / per-request activation / paged pool,
      showing the pool capacity that fits.
- [ ] Record the **minimum model/context envelope paged serves that stock cannot**
      — with real memory evidence. Per §1 this **MAY be null/negligible for the
      batch-1 fp16 path**; the obligation is to record the honest measured value,
      not manufacture a positive delta.
- [ ] Enforce a **paged-attention overhead ceiling** as an **IMPL gate**: paged
      mode exceeding the recorded per-op gather-overhead bound **fails the gate**,
      not ships a regression.

### 4.14 Composition hooks (FR-PKV9 → AC-11, AC-12)
- [ ] Expose the layout metadata a SPEC-037 persistence consumer *would* need
      (block size, logical length, per-layer shape/dtype, block-table version,
      allocator/pool epoch, MLX/MLXLM revision identities, model + tokenizer
      identity, cache class, quantization scope). Do **not** mandate SPEC-037
      consume it — that decision is the SPEC-037 owner's.
- [ ] Prove **AC-12 SPEC-038 independence**: batch-1 parity + fallback pass with
      no scheduler present.

## 5. Acceptance criteria → fixtures (all 17 must be green)

Map every fixture to its AC in the PR body: AC-1/2/3 parity (dense Llama / dense
Qwen / MoE), AC-4 allocator/block-table unit coverage, AC-5 pool fail-safe incl.
the **batch-1 preflight arm**, AC-6 fp16 floor, AC-7 quantized boundary, AC-8
fail-safe fallback, AC-9 metallib packaging (packaged artifact), AC-10 receipt/
usage invariance, AC-11 SPEC-037 composition, AC-12 SPEC-038 independence, AC-13
cache-class allowlist attach gate (Rotating/CacheList/Quantized each exercised),
AC-14 descriptor handshake, AC-15 extraction/retention + mid-block token-granular
trim, AC-16 servability/sizing + overhead-ceiling gate, AC-17 config surface.

## 6. Audit loop (before PR is "done")

1. Reconstruct the **full IMPL diff as it will land** (base = commit before this
   build's first commit; `git diff <base> -- <fix files>` to working tree). Never
   audit an incremental slice.
2. Three Codex lanes (code / security / architect) via `omc ask codex`; prompts
   written to `audits/<date>/` files (not `specs/`, CI gate), invoked with
   backtick-safe quoting (write prompt to file). Bar **0 C/H/M**; iterate fix →
   re-audit until clean; carry LOW/INFO with PR-body rationale.
3. Two independent Claude passes (adversarial verificator + correctness/product
   critic) on feature + diff only, no fix-history. **Re-verify the fix delta**
   for fix-introduced regressions before sealing.
4. Do not re-fire a lane that already passed 0/0/0 (strict skip-accepted).

## 7. Real-hardware enable gate (the true finish line — NOT CI)

Per Entry 199 and the SPEC-037 incident, the runtime-enable gate is a packaged
real-serve exercise, and it **cannot run in-place on the dev Mac**:

- **`serve` self-re-execs into the installed binary.** `MacProviderCLI.run()`
  PATH-repair (`ensurePathEntrypointMatchesInstallAuthority()`) `execv`s into the
  canonical install-authority binary, so a worktree `swift build` binary silently
  hands off to the OLD installed one. No env/runtime bypass exists by design.
- **A worktree `swift build` has no `mlx.metallib`** (co-located in the install);
  MLX aborts on first `MLXArray` alloc. So MLX-gated paged serving cannot run from
  a worktree binary at all.

Therefore the paged-mode enable proof comes only from a **properly packaged
release-candidate install** on a test provider:
1. Package an RC that carries `default.metallib` (FR-PKV8) and install it as the
   authority.
2. With paged enabled on a **>32 GB** Mac (the P0 #584 lab-Mac dependency — the
   32 GB live-30B envelope leaves little headroom; record the sizing table
   against whatever hardware runs it), serve the live model and prove exact
   greedy parity end-to-end plus the FR-PKV13 servability numbers.
3. Only after that real-serve proof does any provider flip `paged_kv.enabled` on.
   Merge lands the engine **inert**; do not conflate "merged" with "enabled".

**Provider-safety on the dev Mac:** it also runs the LIVE production provider.
Never broad `pkill`. Use a narrow `pgrep`; if you must stop the provider, bootout
the watchdog first (`live.malibu.provider-watchdog`), then the provider, via
graceful `launchctl bootout`, off-peak, and restore + verify serving after. Never
print the buyer token.

## 8. PR / merge protocol

- Author the PR as **Augustas11** (so antfleet-ops can review; self-approve is
  blocked). Fill the governance declaration honestly (§3).
- Green `ci-required` + 1 approval is the merge gate; `spec-index/check` advisory.
- Merge: antfleet-ops approves → `GH_TOKEN=$(gh auth token -u Augustas11) gh pr
  merge --squash --admin <n>`.
- After squash-merge: `git checkout main && git fetch origin && git reset --hard
  origin/main`, delete the PR branch, remove the worktree.
- Append a DECISION_CRITERIA.md entry capturing the engine landing and the
  merged-inert / enable-gate distinction (decision-log PRs/entries merge last).

## 9. What the SPEC-038 build inherits from you

The SPEC-038 v0.2 scheduler IMPL (next build, absorbing PR #804's scaffold)
consumes exactly three surfaces you build here — get their contracts stable:
1. the **capability descriptor** (FR-PKV11) — its activation predicate;
2. the **engine-issued block-table handle** (FR-PKV2) — allocate/bind/extend/
   release lifecycle;
3. the **cache-extraction / same-conversation retention primitive** (FR-PKV10) —
   cross-turn cache continuity.
Treat these as public API frozen at merge; scheduler correctness depends on them.
