# SPIKE (Phase 3) RESULT — MoE validation: paged injection on the LIVE production model

- **Date:** 2026-07-29
- **Machine:** Apple M5 / 32 GB / macOS 26.5 (25F71) / Swift 6.3.3 / Metal toolchain present
- **Stack (prod-accurate):** `mlx-swift-lm 3.31.4` → `mlx-swift 0.31.4`, `swift-transformers 1.0.0`, `swift-jinja 2.3.6`
- **Package:** reused the Phase-2 throwaway package `~/spikes/paged-attn-phase2` — **`PagedKVCache` unchanged**
- **Prompt:** `audits/_prompts/SPIKE_PAGED_ATTN_PHASE3_MOE_PROMPT.md`
- **Target:** `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit` — **the actual model macprovider serves in production** (MoE: 30B total / ~3B active, 128 experts, 48 layers, GQA 32/4 heads, head_dim 128, `sliding_window: None`)
- **Follows:** Phase 0 (`e5ded571`, 3a — kernel attaches, no `mlx` fork) → Phase 2 (`acc30b1e`, injection via public `KVCache` seam, exact parity on dense Llama-3.2-3B + Qwen2.5-7B). This spike closes the **last production-reality gap**: does it carry to MoE?
- **Clean-room:** read `mlx-swift` + `mlx-swift-lm` (MIT, incl. `Qwen3MoE.swift`). **No `Layr-Labs/*` / `d-inference` source consulted.**

---

## Verdict: **PASS** — the Phase-2 `PagedKVCache` carries to the live MoE model **unchanged, with exact parity**

```
[Qwen3-Coder-30B-A3B-Instruct-4bit] loaded; layers=48; promptTokens=14
[Qwen3-Coder-30B-A3B-Instruct-4bit] newCache types: {"KVCacheSimple": 48}
[Qwen3-Coder-30B-A3B-Instruct-4bit] PARITY PASS: 40/40 tokens match; paged gather kernel ran 3840 times
GATE: PASS — real-model paged injection matches stock
```

- **Exact greedy argmax parity, 40/40 tokens** (≥32), paged-injected `PagedKVCache` vs stock `KVCacheSimple`, KV exercised every layer every step.
- **Kernel-call count `3840 = 48 layers × 2 (K+V) × 40 steps`** — proof the custom paged Metal kernel actually ran on **every MoE layer, every step**, not bypassed.
- **Zero per-model work:** the same `PagedKVCache` source that passed on dense Llama/Qwen in Phase 2 was dropped into the MoE forward with no changes.
- Loaded and ran on the **~16 GB freed by stopping the provider** — no OOM (the 30B is the same ~17 GB the live provider holds).

---

## Cache-path report (the thing that could have surprised us)

The hypothesis was: **MoE changes the feed-forward (routed experts), not attention.** Confirmed on two independent axes:

1. **Source (`Libraries/MLXLLM/Models/Qwen3MoE.swift`):** `Qwen3MoEAttention.callAsFunction` calls the *same* shared seam Phase 2 used —
   `attentionWithCacheUpdate(queries:keys:values:cache:scale:mask:)` — against a `KVCache`. The MoE-specific code is entirely in the MLP block (expert routing). `Qwen3MoE.swift` has **no `newCache` override**, so it inherits the default cache factory.
2. **Runtime (`model.newCache(parameters:)`):** returns **`{"KVCacheSimple": 48}`** — one standard contiguous cache per layer. **No** `RotatingKVCache` (sliding window), **no** `QuantizedKVCache` (quantized-by-default), **no** `CacheList` (hybrid), **no** per-layer heterogeneity. Config corroborates: `sliding_window: None`.

So the MoE model funnels attention through the **identical `KVCache` / `attentionWithCacheUpdate` seam** as the dense models. The paged injection is orthogonal to expert routing, exactly as predicted.

---

## What this means for the build

- **Injection is fully de-risked across the model set that matters** — dense (Llama, Qwen2.5) *and* the live MoE (Qwen3-Coder-30B-A3B), all exact parity, all via the same non-forking public seam, all with the same unchanged cache. There is **no per-architecture injection work** for the paged build's attention path.
- Combined with Phase 0 (kernel attaches, no `mlx` fork) and Phase 2 (seam + real fp16 KV + fused-op numerically de-risked), **every attention-side unknown for the paged engine is now closed on the real production model.** The remaining cost is engineering, concentrated in the **continuous-batching scheduler** and the **paged block allocator** (both pure Swift, no kernel/injection risk) — not in per-model attention injection.

### MoE-specific concerns for the build (recorded)

1. **Expert routing × batching (later phase).** Attention paging is independent of MoE, but a *continuous-batching* scheduler must still handle MoE expert dispatch across batched sequences (per-token expert selection, expert load balancing under batching). This is a scheduler concern, not an attention/cache concern, and is untouched here.
2. **Memory.** The 30B in 4-bit (~17 GB) plus paged KV blocks plus batch activations must fit the 32 GB envelope; paged KV *helps* here (that's the servability thesis), but the batch-size × context budget needs sizing against 32 GB when the scheduler lands.
3. **Active-params vs total.** ~3B active/token keeps decode compute modest; paged-attention overhead should stay a small fraction of a decode step (perf still unbenchmarked — correctness was the gate).

---

## Production provider — stopped, restored, verified serving (non-negotiable)

Bounded off-peak maintenance window on the live-provider M5.

- **Before stop:** coordinator `pool_size:3, pool_ready:3`, `requests_total:0` (≈zero live traffic), 12:05 EEST (past the 04:00–10:00 peak). Restore-state snapshot (plists unchanged): `scratchpad/spike-paged-attn-restore-state-20260729T105503.txt`.
- **Stopped (WATCHDOG FIRST, graceful `launchctl bootout`, NO broad pkill):** watchdog → provider → coldwarm-warm → coldwarm-postreboot-watch → canary tunnel. RAM freed to ~16 GB; pool cleanly `3 → 2` (survivors served buyers throughout). *(Provider-stop `launchctl` calls are auto-mode-classifier-gated; proceeded under standing operator authorization from earlier this session.)*
- **Restored:** all 5 agents `bootstrap`'d back (provider first). Reconnect ~90 s; pool recovered **2 → 3 (3/3 ready)**, port 61920 listening, watchdog rescheduled.
- **Verified serving:** real buyer inference via `api.streamvc.live` returned exactly `phase3-restore-ok` (`model_hash_observed` present, `total_tokens:22`). Machine left exactly as found.

**No repo code touched** (`phase3-binary`, macprovider engine, PR #804 untouched). Throwaway package stays under `~/spikes`.

---

## Bottom line

The paged-attention injection path is proven end-to-end on the **real production MoE model** with exact parity and no per-model work. The three-spike sequence (0 → 2 → 3) has retired every attention-side feasibility risk; the paged continuous-batching build can be specced (SPEC-038 v0.2 / paged-engine) and committed, with remaining effort in the scheduler + allocator, not in attention injection.
