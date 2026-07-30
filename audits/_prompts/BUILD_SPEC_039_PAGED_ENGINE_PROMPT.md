# AUTHOR SPEC-039 — Paged KV / Paged-Attention Engine (provider-local, additive on the pinned MLX tag)

**For a fresh codex session.** Author a new normative spec, `specs/SPEC-039-paged-kv-attention-engine.md`, then drive it through the three-lane codex SPEC-audit to 0 C/H/M and open the PR. This is a **SPEC only — no IMPL** (the build is a separate effort). The design below is **already empirically verified** by three spikes on real models — you are writing the normative contract for a proven design, not exploring feasibility.

## What this spec defines
A provider-local **paged KV cache + paged-attention Metal kernel** that lets a Mac serve **bigger models and longer contexts** more memory-efficiently — the **memory-servability** infrastructure. It attaches **additively** to macprovider's pinned `mlx-swift` (no fork of `mlx` or `mlx-swift`), is **architecture-general** (dense + MoE), and is **default-off / provider-local** (no receipt, billing, or buyer-visible change — same posture as SPEC-037). It is the engine the SPEC-038 continuous-batching scheduler will sit on, **but it is valuable independently of batching** (paged KV helps even a single stream / 1-slot Mac — that is the servability axis; do not couple this spec to concurrency).

## Verified design inputs (ground the normative content in these — they are proven)
Read all before writing:
- `docs/research/SPIKE_PAGED_ATTN_PHASE0_RESULT_2026-07-29.md` (`e5ded571`) — **3a**: a custom paged-attention Metal kernel registers + dispatches via the **public `MLXFast.metalKernel`** API beside the pinned tag; paged gather == SDPA at float epsilon. No `mlx` fork.
- `docs/research/SPIKE_PAGED_ATTN_PHASE2_RESULT_2026-07-29.md` (`acc30b1e`) — **injection via the public `KVCache` protocol seam** (`MLXLMCommon.attentionWithCacheUpdate`), **architecture-general**, **exact** greedy parity on dense Llama-3.2-3B + Qwen2.5-7B, on the **production fp16 KV** path, no fork. Fused-op numerically de-risked at prod dims (hq32/hkv8/d128, 9.3e-4).
- `docs/research/SPIKE_PAGED_ATTN_PHASE3_MOE_RESULT_2026-07-29.md` (`da21af53`) — **MoE PASS on the LIVE model** `Qwen3-Coder-30B-A3B` (48 layers, 128 experts), same unchanged `PagedKVCache`, exact parity; model uses plain `{KVCacheSimple:48}` — MoE routing is orthogonal to attention paging.
- `docs/research/RESEARCH_232_ADDENDUM_PAGED_REDECISION_2026-07-29.md` — strategic framing (paged = servability infrastructure for the network being built).
- Stack of record: `mlx-swift-lm 3.31.4` → `mlx-swift 0.31.4` (production-accurate; NOT 0.31.6).

## Required normative content (FRs — adapt/number in house style)
1. **Injection seam.** A `PagedKVCache` conforming to `mlx-swift-lm`'s public `KVCache` protocol, injected via `model(_:cache:)`; MUST NOT require subclassing internal attention modules or forking `mlx-swift-lm` for the default (gather-feeds-SDPA) path. MUST be architecture-general (one cache, all dense + MoE models that funnel through `attentionWithCacheUpdate`).
2. **Paged storage + block allocator.** Fixed-size KV blocks in a physical pool addressed by per-sequence **block tables**; a block allocator (free list, allocation, eviction/reclaim). Define block size, allocation/eviction semantics, and the block-table contract. Pure-Swift; no kernel risk.
3. **Paged-attention kernel.** A custom Metal kernel via `MLXFast.metalKernel` that gathers non-contiguous KV blocks into logical order feeding stock `scaledDotProductAttention` (the no-fork default). Define the two modes: **(a) gather-feeds-SDPA** (default, no fork) and **(b) fully-fused paged-attention op** that replaces SDPA (OPTIONAL, max-perf only, requires a *light `mlx-swift-lm` fork* — NOT `mlx` core; already numerically de-risked). v1 normative surface = mode (a); mode (b) is a documented optional extension.
4. **Correctness invariant (the gate).** Paged output MUST be **numerically exact** vs the stock contiguous path on the fp16 KV path — the acceptance bar is **exact greedy-argmax token parity** vs stock, KV exercised every layer every step (as the spikes proved). RoPE, GQA/MQA, and causal masking are applied by the unmodified model; the cache only reshuffles KV.
5. **KV dtype scope.** **fp16 is the production/normative path** (it is what the provider runs, `kv_bits` unset). **Quantized (`kvBits`) KV is a distinct numerical surface** (it diverges from fp16 immediately) — declare it **out of scope for v1** (or a clearly-separated future FR): a paged-quantized cache MUST target the quantized SDPA path (`QuantizedKVCacheProtocol` / `quantizedScaledDotProductAttention`) and gather `(wq, scales, biases)` block tuples, not a plain tensor.
6. **Provider-local invariants (mirror SPEC-037).** Default-OFF; **no** new SPEC-015 receipt field, no billing/usage/buyer-visible change; MUST preserve `model_sha256` / tokenizer / cache-class identity; a miss falls back to the stock contiguous path (fail-safe). It is a residency/efficiency optimization, not a settlement change.
7. **Packaging.** The paged kernel requires the MLX `default.metallib`; the provider build MUST wire the metallib resource bundle deliberately (plain `swift build` does not regenerate it — Phase-0 gotcha).
8. **SPEC-037 interaction.** SPEC-037 (KV survival / disk tier) serializes the current per-conversation KV layout. State the interaction: if the paged layout becomes the resident format, SPEC-037 persistence becomes a **consumer of the paged layout** (the RESEARCH_233 "LAYOUT-BOUND" pivot). Define the boundary so the two specs compose.
9. **Relationship to SPEC-038.** SPEC-039 is the engine; SPEC-038 (continuous batching) is a **consumer**. SPEC-039 MUST stand alone (usable at batch=1 for servability) and MUST NOT depend on the batching scheduler.

## Acceptance criteria (as fixtures)
Exact-parity fixtures on **dense (Llama) + MoE (Qwen3-MoE)**; block-allocator unit tests (alloc/evict/free-list, block-table correctness); the fp16-path correctness floor; a fail-safe-to-contiguous test; a metallib-packaging check; and a test proving no SPEC-015 receipt/usage field is added.

## House rules
- **Fresh worktree off `origin/main`** (`git worktree add ../macprovider-spec039 -b spec/039-paged-engine origin/main`); never edit the canonical checkout.
- **Claim SPEC-039** (verified free; `ls specs/SPEC-*.md` to confirm, bump if taken — but 038 is max). House filename `SPEC-039-paged-kv-attention-engine.md`, house header/style like existing specs.
- **Governance:** add a `SPEC-GOVERNANCE-DECLARATION` (schema `spec-pr-governance-v1`) to the PR body; add the new authority domain (e.g. `paged-kv-attention`) + requirement IDs `SPEC-039-R0NN` to `specs/CONFORMANCE.json` + `specs/AUTHORITY.json`. The `spec-index/check` is advisory; merge gate is `ci-required` + 1 approval.
- **Three-lane codex SPEC-audit** (code/security/architect) to **0 C/H/M**; lane prompts under `audits/2026-07-29/` (never `specs/`). Findings in `specs/SPEC-039-rN-audit.md` (fold LOW-only rounds into the PR body).
- **Sensitive path (touches serving correctness):** treat the security/correctness lane weight on the exact-parity invariant + fail-safe + no-receipt-drift.
- **Merge:** author as `Augustas11`; `antfleet-ops` approves; `Augustas11` squash-merges (`GH_TOKEN=$(gh auth token -u Augustas11) gh pr merge --squash --admin`). Classifier may gate — surface the commands if blocked.
- **Decision-log:** leave `beta/DECISION_CRITERIA.md` for the IMPL (SPEC-037 pattern: entry lands at IMPL, not SPEC).
- **Clean-room:** the design is from macprovider's own verified spikes + public MLX (MIT) + the PagedAttention paper. **NEVER** consult `Layr-Labs/*` / `d-inference`.

## Definition of done
SPEC-039 authored (proven design as normative contract), FRs 1–9 covered, acceptance criteria as fixtures, fp16-normative/quantized-out-of-scope, SPEC-037 + SPEC-038 relationships defined; three-lane audit 0 C/H/M; governance-declared PR merged via `ci-required`. **No IMPL.**
